/// Strip model-emitted reasoning blocks (`<think>…</think>`, the
/// longer `<thinking>…</thinking>` form, and the `<reason>` /
/// `<reasoning>` / `<reflection>` variants) from raw LLM output.
///
/// Some models emit a single opening tag with no matching close (the
/// response was truncated mid-reasoning); the second regex absorbs
/// everything from such an opening tag to the end of the string.
///
/// We can't use a single regex because the open/close tag names don't
/// always match exactly (some models emit `<think>…</thinking>`), so
/// we strip each variant independently.
///
/// Returns the input with all matches replaced by the empty string
/// and trimmed. Safe to call on already-clean input — it returns the
/// trimmed string unchanged.
String stripThinkBlocks(String input) {
  if (input.isEmpty) return input;
  var s = input;

  // Closed blocks: opening variant, anything (incl. newlines), closing
  // variant. The closing variant is matched independently so a model
  // emitting `<think>…</thinking>` still has its content removed.
  for (final tag in const ['think', 'thinking', 'reason', 'reasoning', 'reflection', 'thought']) {
    s = s.replaceAll(
      RegExp(
        '<$tag\\b[^>]*>[\\s\\S]*?</$tag\\s*>',
        caseSensitive: false,
      ),
      '',
    );
    // Cross-name close: `<think>…</thinking>` etc.
    for (final closeTag in const ['think', 'thinking', 'reason', 'reasoning', 'reflection', 'thought']) {
      if (closeTag == tag) continue;
      s = s.replaceAll(
        RegExp(
          '<$tag\\b[^>]*>[\\s\\S]*?</$closeTag\\s*>',
          caseSensitive: false,
        ),
        '',
      );
    }
  }

  // Unclosed opening tags — everything to end of string is reasoning
  // and should be dropped.
  for (final tag in const ['think', 'thinking', 'reason', 'reasoning', 'reflection', 'thought']) {
    s = s.replaceAll(
      RegExp(
        '<$tag\\b[^>]*>[\\s\\S]*\$',
        caseSensitive: false,
      ),
      '',
    );
  }

  return s.trim();
}