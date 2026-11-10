import 'package:flutter_test/flutter_test.dart';
import 'package:youtubemusicbrowser/browser/user_agent.dart';

void main() {
  test('strips the WebView markers', () {
    const raw =
        'Mozilla/5.0 (Linux; Android 10; K; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/126.0.6478.122 Mobile Safari/537.36';
    final ua = UserAgents.sanitize(raw);
    expect(ua, isNot(contains('; wv')));
    expect(ua, isNot(contains('Version/4.0')));
    expect(ua, contains('Chrome/126.0.6478.122'));
    expect(ua, contains('Mobile Safari/537.36'));
    expect(UserAgents.looksLikeWebView(ua), isFalse);
  });

  test('falls back when the input is unusable', () {
    expect(UserAgents.sanitize(null), UserAgents.fallback);
    expect(UserAgents.sanitize(''), UserAgents.fallback);
    expect(UserAgents.sanitize('wv'), UserAgents.fallback);
  });

  test('desktop fallback keeps the Chrome version', () {
    final ua = UserAgents.desktopFrom(
      'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36',
    );
    expect(ua, contains('Chrome/120.0.6099.230'));
    expect(ua, contains('X11; Linux x86_64'));
    expect(UserAgents.looksLikeWebView(ua), isFalse);
  });
}
