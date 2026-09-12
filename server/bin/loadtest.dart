// Load test: publishes 30 synthetic envelopes to a user's FCM topic
// to verify end-to-end capture (server → FCM → phone → SQLite) under
// bursty traffic. Run from the server/ directory:
//
//   dart run bin/loadtest.dart [SUB]
//
// SUB defaults to the sub from your existing account (taken from past
// server logs). Override on the command line to test against a
// different account.
//
// All 30 messages are written to Firestore `envelopes/{messageId}` so
// the phone can pull them via /sync even if FCM topic delivery drops
// a few. 27 are <4 KB (inline FCM publish), 3 are >4 KB (truncated
// marker publish). Spacing: 1 s between messages so the burst looks
// like real Gmail traffic over ~30 s.
import 'dart:io';
import 'dart:math';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';

import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:pocket_server/fcm.dart';

import 'package:pocket_server/token_store.dart';

Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (r) => stdout.writeln('[loadtest] [${r.level.name}] ${r.message}'),
  );

  const defaultSub = '107602711769738620458';
  final sub = args.isNotEmpty ? args[0] : defaultSub;
  stdout.writeln('[loadtest] target sub = $sub');

  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);

  if (config.fcmDryRun) {
    stdout.writeln('[loadtest] FCM_DRY_RUN=1 — payloads will only be '
        'logged, NOT delivered. Unset to publish for real.');
  }

  final tokens = AccountsRepo(endpoint: pgEndpointFromEnv());
  await tokens.init();

  final envelopes = PostgresEnvelopeStore(repo: tokens);
  await envelopes.init();
  stdout.writeln('[loadtest] Postgres ready');

  final AccountRecord? account = await tokens.get(sub);
  if (account == null) {
    stdout.writeln('[loadtest] no account for sub=$sub — aborting');
    return;
  }
  if (account.fcmTokens.isEmpty) {
    stdout.writeln('[loadtest] account $sub has no FCM tokens registered — '
        'open the app and sign in first');
    return;
  }
  stdout.writeln('[loadtest] account $sub has ${account.fcmTokens.length} '
      'FCM token(s)');

  final fcm = FcmPublisher(config: config);
  await fcm.init();
  stdout.writeln('[loadtest] FCM ready');

  final rng = Random(42);
  const total = 30;
  // Last 3 envelopes are >4 KB to exercise the truncated-marker path.
  // The rest are spread 1-3 KB so the inline path is the common case.
  var published = 0;
  var failed = 0;
  final stopwatch = Stopwatch()..start();

  for (var i = 0; i < total; i++) {
    final isBig = i >= total - 3;
    final textLen = isBig ? 5500 : 1000 + rng.nextInt(2000);
    final text = _makeBody(textLen);
    final messageId = 'loadtest-${stopwatch.elapsedMilliseconds}-$i';
    final date = DateTime.now();
    final subject = isBig
        ? 'Load test $i — large receipt ($textLen chars)'
        : 'Load test $i';
    final from = isBig ? 'statements@bigbank.com' : 'noreply@merchant.com';

    try {
      await envelopes.put(
        messageId,
        {
          'from': from,
          'subject': subject,
          'text': text,
        },
        sub: sub,
        date: date,
      );

      final dataSize = _measureDataSize(
        from: from,
        subject: subject,
        date: date,
        text: text,
      );

      if (dataSize <= 3500) {
        await fcm.publishToTokens(
          sub: account.sub,
          tokens: account.fcmTokens,
          data: {
            'messageId': messageId,
            'emailFrom': from,
            'subject': subject,
            'date': date.toIso8601String(),
            'text': text,
          },
        );
      } else {
        await fcm.publishToTokens(
          sub: account.sub,
          tokens: account.fcmTokens,
          data: {
            'messageId': messageId,
            'truncated': 'true',
          },
        );
      }
      published++;
      stdout.writeln(
        '[loadtest] [$i/${total - 1}] $messageId '
        '(${isBig ? 'BIG' : 'small'}) ${textLen}B body, '
        'data=${dataSize}B path=${dataSize <= 3500 ? 'inline' : 'fallback'}',
      );
    } catch (e) {
      failed++;
      stdout.writeln('[loadtest] [$i/${total - 1}] $messageId FAILED: $e');
    }

    // Pace at ~1 msg/sec so the burst spans 30 s.
    if (i < total - 1) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  stopwatch.stop();
  stdout.writeln('');
  stdout.writeln('[loadtest] DONE — published=$published failed=$failed '
      'in ${stopwatch.elapsed.inSeconds}s');
  stdout.writeln('[loadtest] Now check the phone: pull-to-refresh on the '
      'Transactions screen, and watch `adb logcat -s flutter` for '
      'incoming FCM messages.');
}

String _makeBody(int len) {
  // Realistic-looking receipt body so the AI parser would actually
  // produce a transaction if you wanted to test that path too.
  // Repeats a varied-but-deterministic pattern to avoid compression
  // skewing the byte count.
  const phrases = <String>[
    'You sent \$',
    '.00 USD to ',
    'Merchant. Available balance: \$',
    '. Transaction ID: ',
    '. Date: ',
    '. Thank you for using ',
    ' Payments. If you did not authorize this transaction, please '
        'visit our help center immediately. Reference: ',
    '. This is an automated message; please do not reply. ',
  ];
  final rng = Random(len);
  final buf = StringBuffer('Receipt #');
  while (buf.length < len) {
    buf.write(phrases[rng.nextInt(phrases.length)]);
    buf.write(rng.nextInt(10000));
  }
  return buf.toString().substring(0, len);
}

/// Mirrors the 3500-byte threshold pubsub_handler uses — bytes of the
/// FCM data map, leaving ~500 bytes for the topic name + JSON wrapper.
int _measureDataSize({
  required String from,
  required String subject,
  required DateTime date,
  required String text,
}) {
  final s = '{"messageId":"x","emailFrom":"$from",'
      '"subject":"$subject",'
      '"date":"${date.toIso8601String()}",'
      '"text":"$text"}';
  return s.length;
}
