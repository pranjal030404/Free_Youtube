import 'package:flutter_test/flutter_test.dart';
import 'package:youtubemusicbrowser/browser/domain_filter.dart';

void main() {
  const f = DomainFilter();
  test('allows YouTube and Google sign-in hosts', () {
    for (final u in [
      'https://youtube.com/',
      'https://www.youtube.com/watch?v=x',
      'https://music.youtube.com/',
      'https://m.youtube.com/',
      'https://accounts.google.com/signin',
      'https://accounts.youtube.com/accounts/SetSID',
      'https://consent.google.com/',
      'https://consent.youtube.com/',
      'https://myaccount.google.com/',
      'https://www.google.com/accounts',
      'https://google.com/',
      'https://accounts.google.co.in/',
      'https://accounts.google.co.uk/',
    ]) {
      expect(f.isAllowedTopLevel(Uri.parse(u)), isTrue, reason: u);
    }
  });
  test('blocks everything else', () {
    for (final u in [
      'https://example.com/',
      'https://evil-youtube.com/',
      'https://youtube.com.evil.com/',
      'https://notyoutube.com/',
      'https://evilgoogle.com/',
      'https://google.com.evil.com/',
      'http://www.youtube.com/',
      'intent://x#Intent;end',
      'file:///etc/passwd',
    ]) {
      expect(f.isAllowedTopLevel(Uri.parse(u)), isFalse, reason: u);
    }
  });
  test('detects Google auth pages', () {
    for (final u in [
      'https://accounts.google.com/x',
      'https://accounts.youtube.com/x',
      'https://consent.youtube.com/x',
      'https://myaccount.google.com/x',
    ]) {
      expect(f.isAuthUrl(Uri.parse(u)), isTrue, reason: u);
    }
    expect(f.isAuthUrl(Uri.parse('https://www.youtube.com/')), isFalse);
    expect(f.isAuthUrl(Uri.parse('https://example.com/')), isFalse);
  });
}
