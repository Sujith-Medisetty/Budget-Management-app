import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/format/ai_text.dart';
import '../../core/services/ai_retry.dart';
import '../models/ai_config.dart';
import '../models/parsed_transaction.dart';
import '../models/raw_notification.dart';
import '../repositories/ai_log_store.dart';

/// Sends a notification body to the user's chosen cloud AI provider and
/// parses the JSON response into a [ParsedTransaction]. Returns null if
/// the model can't extract a usable transaction.
///
/// Shared system prompt asks for strict JSON matching a tiny schema so
/// all three providers return the same shape. The user's API key is
/// pulled from [AiKeyStore] via the constructor; we never see it again
/// after that.
///
/// The `source` field is intentionally NOT asked of the model — it's
/// derived from [RawNotification.packageName] in [_extractAndValidate]
/// so a PayPal email captured via Gmail is stored as `source='gmail'`,
/// not `source='paypal'`. The model is asked for `direction` instead,
/// which is redundant with the sign of `amount` but is a much easier
/// classification for small models and acts as a self-check: if `sign`
/// and `direction` disagree we drop the row.
class CloudAiParser {
  CloudAiParser({
    required this._config,
    required this._apiKey,
    Dio? dio,
  }) : _dio = dio ??
           Dio(
             BaseOptions(
               // Connect timeout catches the case where the TCP/TLS
               // handshake itself hangs (filtered region, slow host,
               // DNS being weird). Without this, send/receive timeouts
               // never fire and the test UI waits forever.
               connectTimeout: const Duration(seconds: 8),
             ),
           );

  final AiConfig _config;
  final String _apiKey;
  final Dio _dio;

  static const _systemPrompt = r'''
You extract a single payment, investment, transfer, subscription, or
refund from a notification body and return a strict JSON object. The
user's rule is absolute: EVERY outflow of money from their account is
an expense, no exceptions. The only inflow they care about is a
MERCHANT refund, which counts as a negative expense. Cashback, rewards,
P2P receipts, and anything else incoming from a non-merchant is noise.

Return ONLY a single JSON object, no commentary, no markdown fences, no
prose before or after. If the message is not a payment notification at
all, return {"error": "not_a_payment"}.

================================================================
1. REQUIRED JSON SHAPE
================================================================

{
  "amount":    <number, no currency symbol, no commas, always > 0>,
  "merchant":  "<non-empty string, see rules below>",
  "reason":    "<string or null, see rules below>",
  "direction": "out" | "in",
  "skip":      <boolean>
}

Do NOT return any other fields. Do NOT return source — the app
derives the delivery channel from the package name and ignores
whatever you put there.

================================================================
2. SIGN CONVENTION (the budget math depends on this)
================================================================

The user has exactly one budget. The dashboard sums every row where
amount > 0 and calls it "spent". So:

  direction="out"  ->  amount is POSITIVE   (counts TOWARD budget)
  direction="in"   ->  amount is NEGATIVE   (REDUCES spent)

Even if the model writes the wrong sign in `amount`, the app forces
the sign to match `direction`. But try to get it right the first time.

================================================================
3. THE DECISION TREE (apply in order)
================================================================

Q1. Is the body a real payment, refund, or transfer?
    - No  -> return {"error": "not_a_payment"}.
    - Yes -> continue.

Q2. Which way is the money moving?
    - "out"  -> money left the account (you paid something)
    - "in"   -> money entered the account (refund, cashback, P2P, etc.)

Q3. If "in" — is it from a MERCHANT or from a PERSON / loyalty / bank?
    - MERCHANT refund  -> skip=false, keep it, amount NEGATIVE
    - PERSON (P2P, friend, family)  -> skip=true, drop it
    - Loyalty / cashback / rewards / "credit to your account" /
      interest / "statement credit" / bank bonus -> skip=true, drop it
      (only merchant refunds count as negative expenses)
    - If the source is ambiguous and looks more like a person than a
      merchant, default to skipping.

Q4. If "out" — always skip=false. Always. Whether it's a merchant,
    a subscription, an investment, a person, a charity, a bill, an
    auto-debit, a gift card, a tip, a pre-order, an in-app purchase —
    the user wants every outgoing dollar logged. There is NO "out"
    case where you should set skip=true. Never.

================================================================
4. MERCHANT FIELD RULES
================================================================

- ALWAYS populate `merchant` with a non-empty string. Never null,
  never empty.
- If the brand or recipient name is clear ("Amazon", "Flipkart",
  "Spotify", "Bob"), use it.
- If it's a person's name ("Alice", "Bob"), use the name.
- If it's a brand with extra corporate suffix ("Starbucks Corp",
  "Walmart Inc"), keep the suffix.
- If it's garbled or partial ("A.b.c.d", "??", "PSP-XYZ"), use the
  garbled string AS-IS. Don't try to clean it up.
- If there is no name at all, use the source ("PayPal", "Google Pay",
  "Bank Transfer"). Never leave the field empty.

================================================================
5. REASON FIELD RULES
================================================================

- Populate `reason` with a SHORT noun-phrase describing what the
  payment was FOR, if the body mentions one.
  Examples: "E-bike", "Coffee", "Premium subscription",
  "Birthday gift", "Bus pass", "Lunch".
- If the body doesn't say what it was for, set reason=null.
- Don't make up a reason. Don't paraphrase the merchant.

================================================================
6. CAPITALIZATION
================================================================

Merchant and reason must be Title Case the first time you write them.
The app will normalize on its end as a safety net, but do your best.

  "amazon"      -> "Amazon"
  "flipkart"    -> "Flipkart"
  "ebike"       -> "E-bike"
  "uber eats"   -> "Uber Eats"
  "spotify"     -> "Spotify"
  "starbucks"   -> "Starbucks"
  "comcast xfinity" -> "Comcast Xfinity"
  Acronyms (3+ consecutive caps) stay as-is: "USA", "USB-C", "ATM".

================================================================
7. EDGE CASE CATALOG
================================================================

Outgoing (skip=false, direction=out, amount > 0):
  - Merchant purchase          (Amazon, Walmart, etc.)
  - Subscription / auto-renew  (Spotify, Netflix, Adobe, gym)
  - Investment / asset purchase (Flipkart e-bike, brokerage buy)
  - Bill pay / utility         (Comcast, electric, water)
  - Auto-debit / scheduled     (rent, insurance, EMI)
  - P2P to a person            (you sent $20 to Bob) — STILL expense
  - Charity / donation
  - Tip / gratuity             (added to a base payment — combine if
                                the body shows both, otherwise keep
                                the tip as its own row)
  - Gift card purchase
  - In-app / digital purchase  (Play Store, App Store, game top-up)
  - Pre-order / deposit        (you paid $5 to reserve something)
  - Tax payment                (IRS, state, GST)
  - Foreign-currency spend     (assume USD value as written; do NOT
                                convert. If the body shows "EUR 40"
                                and no USD, use the number as-is and
                                still keep the row — it is outgoing.)
  - Failed payment attempt     -> skip=true. The money did not move.
                                  The user does not want phantom
                                  expenses.
  - Pre-authorization hold     -> skip=true. Money has not been
                                  captured yet; will become a real
                                  expense on capture.
  - Reversed / cancelled       -> skip=true unless the body says the
                                  reversal already happened AND
                                  money is back — in which case
                                  treat as a refund (in, negative).

Incoming (default: skip=true, DROP):
  - P2P from a person          (Alice sent you $10)     -> DROP
  - Cashback from a card       ("You earned $5 back")   -> DROP
  - Loyalty / reward points    ("Points credited")      -> DROP
  - Bank interest              ("Interest paid")        -> DROP
  - Bank bonus / promo credit  ("Welcome bonus")        -> DROP
  - Salary / paycheck          ("Salary credited")      -> DROP
  - Statement credit           ("Credit applied")       -> DROP
  - Refund from a MERCHANT     ("Refund of $15 from
                                Starbucks")             -> KEEP, negative
  - Partial refund             ("$5 refunded of your
                                $29.99 order")          -> KEEP, -5 only
  - Reversal that already
    settled (money is back)    -> treat as a refund,
                                  KEEP, negative

Non-payment (return {"error": "not_a_payment"}):
  - Marketing / promotional email
  - Login / security alert
  - "Your statement is ready"
  - "Your order has shipped"
  - "Your delivery is on the way"
  - "Available balance: $120.00" alone, with no payment
  - Receipt with no dollar amount
  - Password reset / verification code
  - Account opened / closed notice
  - Promotional coupon / offer

================================================================
8. WORKED EXAMPLES (12 cases, all expected outputs)
================================================================

  Input: "You sent $29.99 USD to Amazon. Available balance: $120.00."
  Output: {"amount": 29.99, "merchant": "Amazon", "reason": null, "direction": "out", "skip": false}

  Input: "You have invested $400 in an e-bike purchased from Flipkart."
  Output: {"amount": 400, "merchant": "Flipkart", "reason": "E-bike", "direction": "out", "skip": false}

  Input: "Spotify Premium renewed for $9.99."
  Output: {"amount": 9.99, "merchant": "Spotify", "reason": "Premium", "direction": "out", "skip": false}

  Input: "Payment of $12.50 to A.b.c.d completed."
  Output: {"amount": 12.50, "merchant": "A.b.c.d", "reason": null, "direction": "out", "skip": false}

  Input: "Refund of $15.00 from Starbucks."
  Output: {"amount": -15.00, "merchant": "Starbucks", "reason": null, "direction": "in", "skip": false}

  Input: "You sent $20.00 to Bob"
  Output: {"amount": 20.00, "merchant": "Bob", "reason": null, "direction": "out", "skip": false}

  Input: "Alice sent you $10.00"
  Output: {"amount": 10, "merchant": "Alice", "reason": null, "direction": "in", "skip": true}

  Input: "You earned $5.00 cashback on your credit card."
  Output: {"amount": 5, "merchant": "Credit Card", "reason": "Cashback", "direction": "in", "skip": true}

  Input: "Payment of $89.99 to Comcast failed. Insufficient funds."
  Output: {"amount": 0, "merchant": "Comcast", "reason": null, "direction": "out", "skip": true}

  Input: "Pre-authorization hold of $45.00 at Shell."
  Output: {"amount": 0, "merchant": "Shell", "reason": "Pre-auth hold", "direction": "out", "skip": true}

  Input: "Your weekly statement is ready. View now."
  Output: {"error": "not_a_payment"}

  Input: "Hi! Your refund of $5.00 from your Amazon order has been processed."
  Output: {"amount": -5.00, "merchant": "Amazon", "reason": null, "direction": "in", "skip": false}

================================================================
9. SELF-CHECK (run these before returning)
================================================================

1. Did I return a single JSON object with no other text?
2. Is `direction` exactly "out" or "in"?
3. If direction="out", did I set skip=false? (out is NEVER skipped)
4. If direction="in", is the source a MERCHANT refund?
   - If yes: skip=false, amount negative
   - If no (P2P / cashback / interest / salary / etc.): skip=true
5. Is `merchant` non-empty?
6. Is `amount` a positive number (the sign is forced by direction)?
7. Is the merchant Title Case?
8. Is the reason a noun phrase or null?
9. If none of the above applies, is the body actually not a payment
   and should I return {"error": "not_a_payment"} instead?

If any check fails, fix it before returning.

================================================================
10. FINAL REMINDER
================================================================

The response MUST be a single JSON object that can be parsed by
jsonDecode in one call. NO prose. NO markdown fences. NO
`<think>...</think>` or `<reasoning>...</reasoning>` blocks. NO
preamble, NO trailing commentary. ANY of those will cause the response
to be rejected and the request retried (up to 3 times) until a clean
JSON object is returned.
''';

  Future<ParsedTransaction?> parse(RawNotification n) async {
    if (_apiKey.isEmpty) return null;
    final body = await chatCompletionJson(
      systemPrompt: _systemPrompt,
      userPrompt: 'App: ${n.packageName}\nTitle: ${n.title}\nBody: ${n.text}',
      temperature: 0.1,
    );
    if (body == null) return null;
    return _extractAndValidate(n, body);
  }

  /// Like [parse] but also returns the raw text the model emitted (or
  /// null if the HTTP layer failed). Used by the connection-test UI to
  /// tell the user *what* the model said when extraction fails so they
  /// can distinguish empty responses, prose, error JSON, missing
  /// fields, or non-standard response shapes from one another. The
  /// returned `rawBody` is already stripped of think-tag blocks so the
  /// test UI never leaks model scratchpad to the user.
  Future<({ParsedTransaction? parsed, String? rawBody})> parseWithRaw(
    RawNotification n,
  ) async {
    if (_apiKey.isEmpty) {
      return (parsed: null, rawBody: null);
    }
    try {
      final body = await chatCompletionJson(
        systemPrompt: _systemPrompt,
        userPrompt:
            'App: ${n.packageName}\nTitle: ${n.title}\nBody: ${n.text}',
        temperature: 0.1,
      );
      if (body == null) return (parsed: null, rawBody: null);
      final parsed = _extractAndValidate(n, body);
      return (parsed: parsed, rawBody: stripThinkTags(body));
    } on DioException catch (e) {
      return (parsed: null, rawBody: 'DioException: ${e.message}');
    } catch (e) {
      return (parsed: null, rawBody: 'Exception: $e');
    }
  }

  ParsedTransaction? _extractAndValidate(RawNotification n, String body) {
    final json = _extractJson(body);
    if (json == null) {
      _log(n, 'reject: no JSON in AI response', body: _truncate(body, 300));
      _recordDropped(n, body: body, reason: 'no JSON in AI response');
      return null;
    }
    if (json['error'] != null) {
      final err = json['error'].toString();
      _log(n, 'reject: AI returned error=$err');
      _recordDropped(n, body: body, reason: 'AI: $err');
      return null;
    }
    if (json['skip'] == true) {
      _log(n, 'skip=true (P2P / non-payment) — dropping');
      _recordDropped(
        n,
        body: body,
        reason: 'AI: skip=true (incoming from a person or non-payment)',
      );
      return null;
    }

    final amount = (json['amount'] as num?)?.toDouble();
    final merchant = json['merchant'] as String?;
    if (amount == null) {
      _log(n, 'reject: amount missing or non-numeric', json: json);
      _recordDropped(
        n,
        body: body,
        reason: 'amount missing or non-numeric',
      );
      return null;
    }
    if (merchant == null || merchant.trim().isEmpty) {
      _log(n, 'reject: merchant missing/empty', json: json);
      _recordDropped(
        n,
        body: body,
        reason: 'merchant missing or empty',
      );
      return null;
    }

    final direction = (json['direction'] as String?)?.toLowerCase();
    final signedAmount = _enforceSign(amount, direction);
    if (signedAmount == 0) {
      _log(n, 'reject: amount is 0 after sign enforcement',
          json: json, rawAmount: amount, direction: direction);
      _recordDropped(
        n,
        body: body,
        reason: 'amount is 0 after sign enforcement',
      );
      return null;
    }

    // Self-check: the sign we computed must agree with the model's
    // direction hint. A disagreement usually means the model was
    // confused (e.g. "you sent $20 to Bob" → direction=out but
    // amount=+20 looks like a spend to the budget). Trust our sign
    // since the budget math depends on it.
    final reason = json['reason'] as String?;
    final source = _sourceFor(n.packageName);

    final result = ParsedTransaction(
      amount: signedAmount,
      merchant: _titleCase(merchant.trim()),
      reason: reason == null || reason.isEmpty
          ? null
          : _titleCase(reason.trim()),
      source: source,
      confidence: 0.85,
    );

    _log(
      n,
      'OK: source=$source amount=$signedAmount merchant="${result.merchant}"',
      json: json,
      direction: direction,
      rawAmount: amount,
      signedAmount: signedAmount,
    );
    _recordKept(n, body: body, parsed: result, reason: reason);
    return result;
  }

  void _recordKept(
    RawNotification n, {
    required String body,
    required ParsedTransaction parsed,
    String? reason,
  }) {
    unawaited(
      AiLogStore.record(
        package: n.packageName,
        sourceText: n.text,
        aiResponse: stripThinkTags(body),
        decision: 'kept',
        parsedAmount: parsed.amount,
        parsedMerchant: parsed.merchant,
        parsedSource: parsed.source,
      ),
    );
  }

  void _recordDropped(
    RawNotification n, {
    required String body,
    required String reason,
  }) {
    unawaited(
      AiLogStore.record(
        package: n.packageName,
        sourceText: n.text,
        aiResponse: stripThinkTags(body),
        decision: 'dropped',
        reason: reason,
      ),
    );
  }

  /// Title-case a merchant or reason string. Handles the common shapes
  /// the model emits — all-lower, all-upper, hyphenated, multi-word —
  /// without mangling acronyms (3+ uppercase letters in a row are kept
  /// as-is). Pairs with the system-prompt rule that the model should
  /// already return Title Case, but is the safety net.
  static String _titleCase(String s) {
    if (s.isEmpty) return s;
    final out = StringBuffer();
    var atWordStart = true;
    var upperStreak = 0;
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      final isLetter = RegExp(r'[A-Za-z]').hasMatch(c);
      if (!isLetter) {
        out.write(c);
        atWordStart = true;
        upperStreak = 0;
        continue;
      }
      if (c.toUpperCase() == c && c.toLowerCase() != c) {
        upperStreak++;
      } else {
        upperStreak = 0;
      }
      // Don't break up acronyms: "USA" stays "USA", "USB-C" stays
      // "USB-C". 3+ consecutive uppercase letters counts as an acronym.
      final isAcronym = upperStreak >= 3;
      if (atWordStart && !isAcronym) {
        out.write(c.toUpperCase());
      } else if (!atWordStart && !isAcronym && c == c.toUpperCase()) {
        out.write(c.toLowerCase());
      } else {
        out.write(c);
      }
      atWordStart = false;
    }
    return out.toString();
  }

  /// Forces `amount` to match `direction`:
  ///   direction="out" → positive
  ///   direction="in"  → negative
  ///   null / unknown  → keeps whatever the model sent
  /// Returns 0 if the enforced sign is 0 (model said direction but no
  /// amount, or model said amount=0 with a direction).
  double _enforceSign(double amount, String? direction) {
    if (direction == 'out') return amount.abs();
    if (direction == 'in') return -amount.abs();
    return amount;
  }

  /// The `source` of a transaction is the channel that delivered it
  /// (Gmail envelope vs native PayPal notification vs manual entry),
  /// NOT the payment processor mentioned in the body. A PayPal email
  /// captured via Gmail is `gmail` here and `PayPal` in the merchant
  /// label.
  String _sourceFor(String packageName) {
    final p = packageName.toLowerCase();
    if (packageName == 'manual') return 'manual';
    if (p.contains('android.gm') || p == 'com.google.android.gm') {
      return 'gmail';
    }
    if (p.contains('paypal')) return 'paypal';
    if (p.contains('google') ||
        p.contains('googlepay') ||
        p.contains('nbu.paisa') ||
        p.contains('tez')) {
      return 'google_pay';
    }
    return 'google_pay';
  }

  void _log(
    RawNotification n,
    String message, {
    Map<String, Object?>? json,
    String? body,
    double? rawAmount,
    double? signedAmount,
    String? direction,
  }) {
    if (!kDebugMode) return;
    final parts = <String>[
      '[ai] pkg=${n.packageName} key=${n.notificationKey} :: $message',
    ];
    if (json != null) {
      parts.add('json=$_shape(json)');
    }
    if (body != null) parts.add('body="$body"');
    if (rawAmount != null && signedAmount != null && rawAmount != signedAmount) {
      parts.add('raw=$rawAmount -> signed=$signedAmount');
    }
    if (direction != null) parts.add('direction=$direction');
    debugPrint(parts.join(' '));
  }

  static String _shape(Map<String, Object?> j) {
    final buf = StringBuffer('{');
    var first = true;
    for (final e in j.entries) {
      if (!first) buf.write(', ');
      first = false;
      final v = e.value;
      final t = v == null ? 'null' : '${v.runtimeType}';
      buf.write('${e.key}: <$t>');
    }
    buf.write('}');
    return buf.toString();
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// Public escape hatch used by the Agent service. Sends [userPrompt]
  /// under [systemPrompt] and returns whatever the model emitted
  /// (markdown fences, prose, etc — caller parses). Returns null on
  /// transport / auth failure.
  Future<String?> chatCompletion({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.2,
  }) async {
    if (kDebugMode) {
      debugPrint('[ai] -> ${_config.provider.name}/${_config.model} '
          'prompt=${_truncate(userPrompt, 200)}');
    }
    try {
      switch (_config.provider) {
        case CloudProvider.openai:
          return await _openaiCompat(
            url: 'https://api.openai.com/v1/chat/completions',
            model: _config.model,
            userPrompt: userPrompt,
            supportsResponseFormat: true,
            systemPrompt: systemPrompt,
            temperature: temperature,
          );
        case CloudProvider.anthropic:
          return await _anthropicRaw(
            userPrompt: userPrompt,
            systemPrompt: systemPrompt,
          );
        case CloudProvider.google:
          return await _googleRaw(
            userPrompt: userPrompt,
            systemPrompt: systemPrompt,
          );
        case CloudProvider.minimax:
          return await _openaiCompat(
            url: 'https://api.minimax.io/v1/chat/completions',
            model: _config.model,
            userPrompt: userPrompt,
            supportsResponseFormat: true,
            systemPrompt: systemPrompt,
            temperature: temperature,
          );
        case CloudProvider.custom:
          final base = (_config.baseUrl ?? '').trim();
          if (base.isEmpty) return null;
          final stripped = base.endsWith('/')
              ? base.substring(0, base.length - 1)
              : base;
          return await _openaiCompat(
            url: '$stripped/chat/completions',
            model: _config.model,
            userPrompt: userPrompt,
            // Some OpenAI-compatible hosts reject the strict json_object
            // mode — caller-side JSON extraction handles fences.
            supportsResponseFormat: false,
            systemPrompt: systemPrompt,
            temperature: temperature,
          );
      }
    } on DioException catch (e) {
      if (kDebugMode) debugPrint('[ai] HTTP error: ${e.message}');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[ai] error: $e');
      return null;
    }
  }

  /// Like [chatCompletion] but guarantees the returned body parses as
  /// a JSON object. Retries up to 3 times on null/transport errors and
  /// non-JSON replies, with exponential backoff. Returns null only on
  /// persistent transport failure. Returns a guaranteed-valid
  /// `{"skip": true, "error": "ai_no_json_after_retry"}` JSON if every
  /// attempt returned prose — so the parser path never bubbles up a
  /// "no JSON in AI response" rejection to the user.
  Future<String?> chatCompletionJson({
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.1,
  }) {
    return retryUntilJson(
      attempt: () => chatCompletion(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        temperature: temperature,
      ),
      extractJson: _extractJson,
    );
  }

  Future<String?> _openaiCompat({
    required String url,
    required String model,
    required String userPrompt,
    required bool supportsResponseFormat,
    required String systemPrompt,
    required double temperature,
  }) async {
    final messages = [
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];
    final data = <String, Object?>{
      'model': model,
      'messages': messages,
      'temperature': temperature,
    };
    if (supportsResponseFormat) {
      data['response_format'] = {'type': 'json_object'};
    }
    final r = await _dio.post(
      url,
      options: Options(
        headers: {
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
      data: data,
    );
    final content = (r.data['choices'] as List?)?.firstOrNull?['message']
        ?['content'] as String?;
    if (kDebugMode) {
      debugPrint('[ai] <- ${_truncate(content ?? '<null>', 600)}');
    }
    return content;
  }

  Future<String?> _anthropicRaw({
    required String userPrompt,
    required String systemPrompt,
  }) async {
    final r = await _dio.post(
      'https://api.anthropic.com/v1/messages',
      options: Options(
        headers: {
          'x-api-key': _apiKey,
          'anthropic-version': '2023-06-01',
          'Content-Type': 'application/json',
        },
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
      data: {
        'model': _config.model,
        'max_tokens': 1024,
        'system': systemPrompt,
        'messages': [
          {'role': 'user', 'content': userPrompt},
        ],
      },
    );
    final content = r.data['content'] as List?;
    final block = content?.firstOrNull;
    final text = block?['text'] as String?;
    if (kDebugMode) {
      debugPrint('[ai] <- ${_truncate(text ?? '<null>', 600)}');
    }
    return text;
  }

  Future<String?> _googleRaw({
    required String userPrompt,
    required String systemPrompt,
  }) async {
    final r = await _dio.post(
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '${Uri.encodeComponent(_config.model)}:generateContent',
      queryParameters: {'key': _apiKey},
      options: Options(
        headers: {'Content-Type': 'application/json'},
        responseType: ResponseType.json,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
      ),
      data: {
        'systemInstruction': {
          'parts': [
            {'text': systemPrompt},
          ],
        },
        'contents': [
          {
            'parts': [
              {'text': userPrompt},
            ],
          },
        ],
        'generationConfig': {
          'temperature': 0.2,
          'responseMimeType': 'application/json',
        },
      },
    );
    final candidates = r.data['candidates'] as List?;
    final parts = candidates?.firstOrNull?['content']?['parts'] as List?;
    final text = parts?.firstOrNull?['text'] as String?;
    if (kDebugMode) {
      debugPrint('[ai] <- ${_truncate(text ?? '<null>', 600)}');
    }
    return text;
  }

  static Map<String, Object?>? _extractJson(String body) {
    final trimmed = body.trim();
    try {
      return jsonDecode(trimmed) as Map<String, Object?>;
    } catch (_) {}
    // Some models wrap JSON in ```json fences; strip and retry.
    final fence = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
    final m = fence.firstMatch(trimmed);
    if (m != null) {
      try {
        return jsonDecode(m.group(1)!) as Map<String, Object?>;
      } catch (_) {}
    }
    // Last resort: first {...} block.
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        return jsonDecode(trimmed.substring(start, end + 1))
            as Map<String, Object?>;
      } catch (_) {}
    }
    return null;
  }
}
