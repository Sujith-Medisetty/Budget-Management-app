import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// Strips chain-of-thought blocks some models wrap their answer in. The
/// model is told in the system prompt not to emit any of these, but in
/// practice DeepSeek / Qwen / a few others leak `<thinking>...</thinking>`
/// or `<think>...</think>` blocks into the response. We strip them
/// before logging AND before displaying so the user never sees raw model
/// scratchpad.
///
/// The patterns cover the four common variants we have observed:
///   - `<think>...</think>`
///   - `<thinking>...</thinking>`
///   - `<reasoning>...</reasoning>`
///   - `<reflection>...</reflection>`
///
/// Matching is case-insensitive, multiline (the inner reasoning may
/// contain newlines), and uses a non-greedy quantifier so the first
/// closing tag wins. If the model emits an unclosed tag (rare but
/// happens), the original string is returned — better than cutting the
/// user's answer in half.
String stripThinkTags(String input) {
  if (input.isEmpty) return input;
  final re = RegExp(
    r'<(?:think|thinking|reasoning|reflection)\b[^>]*>[\s\S]*?<\/(?:think|thinking|reasoning|reflection)>',
    caseSensitive: false,
  );
  var out = input.replaceAll(re, '').trim();
  // Collapse runs of blank lines left behind by the strip — three or
  // more consecutive newlines collapse to two so the rendered markdown
  // doesn't have weird big gaps.
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return out;
}

/// Markdown-aware Text replacement for AI output. Inherits the parent
/// style by default so it visually matches a plain `Text(text, ...)`
/// in the same spot, then layers markdown styling on top. The default
/// padding is zero — callers wrap with their own `Padding` if they need
/// breathing room (the activity log already does).
///
/// Falls back to a plain `Text` when the input has no markdown markers
/// at all, which keeps the common one-line answer case free of a
/// markdown layout pass.
class MarkdownText extends StatelessWidget {
  const MarkdownText(
    this.data, {
    super.key,
    this.style,
    this.padding = EdgeInsets.zero,
    this.onTapLink,
    this.shrinkWrap = false,
    this.selectable = true,
  });

  final String data;
  final TextStyle? style;
  final EdgeInsets padding;
  final void Function(String text, String? href, String title)? onTapLink;
  final bool shrinkWrap;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final cleaned = data.trim();
    if (cleaned.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final base = style ?? theme.textTheme.bodyMedium ?? const TextStyle();

    // Quick check: no markdown markers at all → just use Text. This
    // keeps simple one-line replies (which is the bulk of agent output)
    // visually identical to before and avoids paying for the markdown
    // layout pass.
    final hasMarkdown = RegExp(r'[`*_#>\[\]]|```').hasMatch(cleaned);
    if (!hasMarkdown) {
      final body = Padding(
        padding: padding,
        child: Text(cleaned, style: base),
      );
      if (!selectable) return body;
      return SelectionArea(child: body);
    }

    final mdStyle = base.copyWith(height: (base.height ?? 1.2) + 0.1);
    final body = MarkdownBody(
      data: cleaned,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: mdStyle,
        h1: mdStyle.copyWith(fontSize: (base.fontSize ?? 14) + 6, fontWeight: FontWeight.w800),
        h2: mdStyle.copyWith(fontSize: (base.fontSize ?? 14) + 4, fontWeight: FontWeight.w800),
        h3: mdStyle.copyWith(fontSize: (base.fontSize ?? 14) + 2, fontWeight: FontWeight.w700),
        h4: mdStyle.copyWith(fontSize: (base.fontSize ?? 14) + 1, fontWeight: FontWeight.w700),
        h5: mdStyle.copyWith(fontSize: base.fontSize ?? 14, fontWeight: FontWeight.w700),
        h6: mdStyle.copyWith(fontSize: base.fontSize ?? 14, fontWeight: FontWeight.w700),
        code: base.copyWith(
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          fontSize: (base.fontSize ?? 14) - 1,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.outlineVariant,
              width: 3,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
        listBullet: mdStyle,
        a: mdStyle.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        tableHead: base.copyWith(fontWeight: FontWeight.w800),
        tableBody: base,
      ),
      onTapLink: onTapLink,
      shrinkWrap: shrinkWrap,
    );

    final padded = Padding(padding: padding, child: body);
    if (!selectable) return padded;
    return SelectionArea(child: padded);
  }
}
