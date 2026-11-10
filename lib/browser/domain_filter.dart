/// Decides which URLs may be opened as TOP-LEVEL page navigations.
///
/// This is deliberately separate from sub-resource requests (video chunks,
/// images, scripts...), which are never restricted here.
class DomainFilter {
  const DomainFilter();

  static const String youtubeHome = 'https://www.youtube.com/';

  /// YouTube's mobile site, the phone app's home.
  static const String mobileHome = 'https://m.youtube.com/';

  /// YouTube's own remote-control (10-foot) interface.
  static const String tvHome = 'https://www.youtube.com/tv';
  static const String musicHome = 'https://music.youtube.com/';
  static const String accountsHome = 'https://accounts.google.com/';

  /// YouTube's own sign-in flow (not just Google account management), so the
  /// `.youtube.com` session cookies are created and Music opens signed in.
  static const String signInUrl =
      'https://accounts.google.com/ServiceLogin'
      '?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F';

  /// YouTube hosts (and all of their subdomains) the user may browse.
  /// `m.youtube.com` is YouTube's own mobile site; YouTube redirects phones
  /// there, so blocking it would make the app unusable.
  static const List<String> _youtubeDomains = [
    'youtube.com',
    'youtu.be',
    'youtube-nocookie.com',
  ];

  /// Google's sign-in / consent flow bounces across many hosts. Allow the
  /// whole `google.com` tree (plus country domains such as `google.co.in`)
  /// instead of a short list that breaks whenever Google adds a step.
  static final RegExp _googleCountryDomain = RegExp(
    r'(^|\.)google\.(?:[a-z]{2,3}|co\.[a-z]{2}|com\.[a-z]{2})$',
    caseSensitive: false,
  );

  bool isAllowedTopLevel(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'about' && uri.toString() == 'about:blank') return true;
    if (scheme != 'https') return false; // no http, intent:, market:, file: ...
    final host = uri.host.toLowerCase();
    for (final domain in _youtubeDomains) {
      if (_hasDomain(host, domain)) return true;
    }
    return _isGoogleHost(host);
  }

  /// True for Google account, sign-in and consent pages.
  bool isAuthUrl(Uri? uri) {
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    return _isGoogleHost(host) ||
        host == 'accounts.youtube.com' ||
        host == 'consent.youtube.com';
  }

  /// True for YouTube's TV interface (`youtube.com/tv`), which handles the
  /// remote itself.
  bool isTvSite(Uri? uri) {
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return (host == 'www.youtube.com' || host == 'youtube.com') &&
        (uri.path == '/tv' || uri.path.startsWith('/tv/'));
  }

  /// youtube.com pages that should be served the TV user agent.
  bool wantsTvUserAgent(Uri? uri) {
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (isMusic(uri) || isAuthUrl(uri)) return false;
    return _hasDomain(host, 'youtube.com');
  }

  bool isMusic(Uri? uri) => uri?.host.toLowerCase() == 'music.youtube.com';

  static bool _hasDomain(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  static bool _isGoogleHost(String host) =>
      _hasDomain(host, 'google.com') || _googleCountryDomain.hasMatch(host);
}
