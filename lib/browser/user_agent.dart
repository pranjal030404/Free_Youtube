/// User-agent helpers.
///
/// Google refuses to sign in pages that advertise themselves as an embedded
/// Android WebView (`; wv`, `Version/4.0`). The WebView's own user agent is
/// sanitised at runtime so the Chrome version always matches the installed
/// engine instead of a hard-coded (and possibly stale) version.
class UserAgents {
  const UserAgents._();

  /// Used before the real WebView user agent is available.
  static const String fallback =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  /// Removes the WebView-only tokens from [raw].
  static String sanitize(String? raw) {
    final input = (raw ?? '').trim();
    if (input.isEmpty) return fallback;
    final cleaned = input
        .replaceAll(RegExp(r';\s*wv\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+Version/4\.0\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    if (!cleaned.contains('Chrome/')) return fallback;
    return cleaned;
  }

  /// True when [ua] still contains a marker Google treats as a WebView.
  static bool looksLikeWebView(String ua) =>
      RegExp(r'(;\s*wv\b|\bVersion/4\.0\b)', caseSensitive: false).hasMatch(ua);

  /// A desktop Chrome user agent with the same Chrome version as [raw].
  ///
  /// Used as a fallback when Google still returns `403 disallowed_useragent`
  /// for the regular (mobile) user agent.
  static String desktopFrom(String? raw) {
    final match = RegExp(r'Chrome/[\d.]+').firstMatch(raw ?? '');
    final chrome = match?.group(0) ?? 'Chrome/126.0.0.0';
    return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) $chrome Safari/537.36';
  }

  /// The user agent that makes YouTube serve its TV interface (`/tv`), with
  /// the same Chrome version as [raw].
  static String tvFrom(String? raw) {
    final match = RegExp(r'Chrome/[\d.]+').firstMatch(raw ?? '');
    final chrome = match?.group(0) ?? 'Chrome/126.0.0.0';
    return 'Mozilla/5.0 (Linux; Android 11; SmartTV) AppleWebKit/537.36 '
        '(KHTML, like Gecko) $chrome Safari/537.36 SmartTV/1.0';
  }
}
