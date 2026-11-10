import 'codec_filter.dart';
import 'tv_navigation.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../download/downloader.dart';
import '../settings/settings_store.dart';
import '../settings/theme_pref.dart';
import 'domain_filter.dart';
import 'user_agent.dart';
import 'yt_ad_skipper.dart';

/// Page script: keeps YouTube from pausing when the app is backgrounded,
/// reports play/pause to the app, and dismisses "still watching?" prompts.
const String _playbackScript = r"""
(function () {
  try {
    const vis = { configurable: true, get: () => 'visible' };
    const hid = { configurable: true, get: () => false };
    Object.defineProperty(document, 'visibilityState', vis);
    Object.defineProperty(document, 'webkitVisibilityState', vis);
    Object.defineProperty(document, 'hidden', hid);
    Object.defineProperty(document, 'webkitHidden', hid);
    const stop = (e) => e.stopImmediatePropagation();
    document.addEventListener('visibilitychange', stop, true);
    document.addEventListener('webkitvisibilitychange', stop, true);
  } catch (e) {}
  let last = null;
  function report() {
    const media = Array.from(document.querySelectorAll('video,audio'));
    const playing = media.some((m) => !m.paused && !m.ended);
    const loaded = media.some((m) => m.currentSrc && !m.ended && m.currentTime > 0);
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const txt = (e) => (e && e.textContent || '').trim();
    const bar = document.querySelector('ytmusic-player-bar');
    let title = md && md.title || txt(bar && bar.querySelector('.title'));
    let artist = md && md.artist ||
        txt(bar && bar.querySelector('.byline')).split('\u2022')[0].trim();
    if (!title) title = (document.title || '').replace(/ - YouTube( Music)?$/, '');
    const key = [playing, loaded, title, artist].join('|');
    if (key !== last) {
      last = key;
      try {
        window.flutter_inappwebview.callHandler('playback',
            { playing: playing, loaded: loaded, title: title, artist: artist });
      } catch (e) {}
    }
  }
  setInterval(report, 3000);
  ['play', 'playing', 'pause', 'ended', 'emptied'].forEach((t) =>
      document.addEventListener(t, () => setTimeout(report, 0), true));
  setInterval(() => {
    try {
      const d = document.querySelector('ytmusic-you-there-renderer, yt-confirm-dialog-renderer');
      const b = d && d.querySelector('button, yt-button-renderer');
      if (b) b.click();
    } catch (e) {}
  }, 20000);
})();
""";

/// Page helpers for media-session commands.
const String _mediaHelpers = r'''
function ytmbCmd(cmd) {
  const m = Array.from(document.querySelectorAll('video,audio'))[0];
  const click = (sels) => {
    for (const s of sels) { const e = document.querySelector(s); if (e) { e.click(); return true; } }
    return false;
  };
  if (cmd === 'play') { if (m) m.play(); }
  else if (cmd === 'pause') { if (m) m.pause(); }
  else if (cmd === 'next') {
    click(['ytmusic-player-bar .next-button', '.ytp-next-button',
        '.player-controls-middle button[aria-label*="Next"]']);
  } else if (cmd === 'previous') {
    if (m && m.currentTime > 5) { m.currentTime = 0; return; }
    if (!click(['ytmusic-player-bar .previous-button', '.ytp-prev-button',
        '.player-controls-middle button[aria-label*="Previous"]']) && m) m.currentTime = 0;
  }
}
''';

/// Clicks the first song result on a YouTube Music search page.
const String _playFirstResult = r'''
(function () {
  let tries = 0;
  const t = setInterval(() => {
    tries++;
    const item = document.querySelector(
        'ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer, ytmusic-card-shelf-renderer');
    const play = item && item.querySelector('ytmusic-play-button-renderer');
    if (play) { play.click(); clearInterval(t); }
    else if (tries > 20) clearInterval(t);
  }, 500);
})();
''';

/// Keeps the first field of Google's sign-in form focused on TVs, so the
/// on-screen keyboard opens without the user having to hunt for the field with
/// a D-pad.
const String _tvAuthFocusScript = r"""
(function () {
  try {
    const host = location.hostname;
    if (!/(^|\.)google\.com$/i.test(host) &&
        !/^(accounts|consent)\.youtube\.com$/i.test(host)) return;
    let tries = 0;
    const t = setInterval(function () {
      tries++;
      const el = document.querySelector(
          'input[type="email"], input[name="identifier"], ' +
          'input[type="password"], input[name="Passwd"], input[name="password"]');
      if (el && document.activeElement !== el) el.focus();
      if (tries > 20) clearInterval(t);
    }, 500);
  } catch (e) {}
})();
""";

/// Detects Google's "This browser or app may not be secure" page even when it
/// is served with a 200 status.
const String _authRejectedCheck = r"""
(function () {
  try {
    const t = (document.body && document.body.innerText || '').toLowerCase();
    return t.indexOf('browser or app may not be secure') !== -1 ||
        t.indexOf('disallowed_useragent') !== -1;
  } catch (e) { return false; }
})();
""";

/// Holds browser state and talks to the WebView controller.
class BrowserController extends ChangeNotifier {
  BrowserController({
    required this.settings,
    this.isTv = false,
    String initialUserAgent = UserAgents.fallback,
  }) : _userAgent = initialUserAgent;

  final SettingsStore settings;
  final bool isTv;
  final DomainFilter domainFilter = const DomainFilter();

  InAppWebViewController? _web;

  /// Loading state lives on separate notifiers so progress ticks rebuild only
  /// the thin progress bar, not the toolbar and the WebView widget.
  final ValueNotifier<double> progressNotifier = ValueNotifier<double>(0);
  final ValueNotifier<bool> loadingNotifier = ValueNotifier<bool>(false);

  /// The video on screen (watch / Shorts page), for the download button.
  final ValueNotifier<String?> videoId = ValueNotifier<String?>(null);
  final Downloader downloader = Downloader();

  bool get isLoading => loadingNotifier.value;
  double get progress => progressNotifier.value;

  bool canGoBack = false;
  bool canGoForward = false;
  bool isFullscreen = false;
  bool isMusic = false;
  String? errorMessage;

  /// Set when a navigation was blocked; the UI shows it once and clears it.
  String? blockedNotice;

  bool get adBlockingEnabled => settings.adBlockingEnabled;

  /// A Chrome-like UA without the "; wv" WebView marker. Google sign-in
  /// rejects embedded WebViews that identify themselves as such.
  String _userAgent;
  String get userAgent => _userAgent;

  /// On a TV, youtube.com is served its TV interface via a TV user agent;
  /// Music and Google sign-in keep the regular one.
  late bool _tvSite = isTv;
  String get _activeUserAgent =>
      _tvSite ? UserAgents.tvFrom(_userAgent) : _userAgent;

  /// Where "home" is: the TV interface on a TV, otherwise the mobile site.
  String get homeUrl => isTv ? DomainFilter.tvHome : DomainFilter.mobileHome;

  /// Called when the page handling the remote changes (see MainActivity).
  static const _deviceChannel = MethodChannel('ytmb/device');
  bool _siteHandlesRemote = false;
  void _syncRemoteMode(Uri? url) {
    if (!isTv) return;
    final handles = domainFilter.isTvSite(url);
    if (handles == _siteHandlesRemote) return;
    _siteHandlesRemote = handles;
    _deviceChannel
        .invokeMethod<void>('setPageHandlesRemote', handles)
        .catchError((_) {});
  }

  bool _triedDesktopUserAgent = false;
  InAppWebViewSettings? _settingsCache;

  /// Cached: the widget reads this on every rebuild, and building the whole
  /// settings object (including the content-blocker list) each time is wasted
  /// work. Invalidated whenever the user agent or ad blocking changes.
  InAppWebViewSettings buildSettings() =>
      _settingsCache ??= InAppWebViewSettings(
        userAgent: _activeUserAgent,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        // Phone: keep playing in the background. TV: pressing HOME must stop
        // playback, like every other TV app.
        allowBackgroundAudioPlaying: !isTv,
        // TV: no scrollbars or overscroll glow to draw, and keep the page's
        // renderer process high priority so a 2 GB TV does not kill it.
        verticalScrollBarEnabled: !isTv,
        horizontalScrollBarEnabled: !isTv,
        overScrollMode: isTv
            ? OverScrollMode.NEVER
            : OverScrollMode.IF_CONTENT_SCROLLS,
        rendererPriorityPolicy: isTv
            ? RendererPriorityPolicy(
                rendererRequestedPriority:
                    RendererPriority.RENDERER_PRIORITY_IMPORTANT,
                waivedWhenNotVisible: true,
              )
            : null,
        allowsInlineMediaPlayback: true,
        // YouTube Music opens Google sign-in in a popup. Without these two
        // settings the popup is silently blocked and "Sign in" does nothing.
        supportMultipleWindows: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // Required on Android for shouldOverrideUrlLoading to run at all.
        useShouldOverrideUrlLoading: true,
        allowFileAccess: false,
        allowContentAccess: false,
        useHybridComposition: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
        supportZoom: isTv,
        useWideViewPort: isTv,
        loadWithOverviewMode: isTv,
        // Intentionally no native content blockers: on Android the plugin
        // issues an extra HEAD request for every sub-resource to guess its
        // MIME type, which roughly doubles page-load traffic. In-page ad
        // skipping (see yt_ad_skipper.dart) handles YouTube ads instead.
      );

  void _invalidateSettings() => _settingsCache = null;

  /// Replaces the hard-coded UA with the sanitised UA of the installed
  /// WebView, keeping the Chrome version truthful.
  Future<void> _initUserAgent(InAppWebViewController c) async {
    try {
      final cleaned = UserAgents.sanitize(
        await InAppWebViewController.getDefaultUserAgent(),
      );
      if (cleaned != _userAgent) {
        _userAgent = cleaned;
        _invalidateSettings();
        await c.setSettings(settings: buildSettings());
      }
    } catch (_) {}
  }

  static const _playback = MethodChannel('ytmb/playback');
  bool _serviceRunning = false;

  UserScript get playbackUserScript => UserScript(
    source: _playbackScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
  );

  UserScript get adSkipUserScript => UserScript(
    source: ytAdSkipperScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
  );

  UserScript get tvAuthFocusUserScript => UserScript(
    source: _tvAuthFocusScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
    forMainFrameOnly: true,
  );

  UserScript get codecFilterUserScript => UserScript(
    source: codecFilterScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    forMainFrameOnly: true,
  );

  UserScript get tvNavUserScript => UserScript(
    source: tvNavigationScript,
    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
    forMainFrameOnly: true,
  );

  List<UserScript> get userScripts => [
    if (isTv) codecFilterUserScript,
    // Background playback (and its once-per-3-s poll, notification and wake
    // lock) is a phone feature; a TV has no use for it.
    if (!isTv) playbackUserScript,
    if (adBlockingEnabled) adSkipUserScript,
    if (isTv) tvAuthFocusUserScript,
    if (isTv) tvNavUserScript,
  ];

  void attach(InAppWebViewController c) {
    _web = c;
    // On a TV the user agent only carries the Chrome version, which the
    // native fast path already supplied; skip the extra WebView round-trip.
    if (!isTv) _initUserAgent(c);
    c.addJavaScriptHandler(
      handlerName: 'playback',
      callback: (args) async {
        final m = args.isNotEmpty && args.first is Map
            ? args.first as Map
            : const {};
        final playing = m['playing'] == true;
        final active = playing || m['loaded'] == true;
        try {
          if (active) {
            _serviceRunning = true;
            await _playback.invokeMethod('update', {
              'playing': playing,
              'title': m['title'] ?? '',
              'artist': m['artist'] ?? '',
            });
          } else if (_serviceRunning) {
            _serviceRunning = false;
            await _playback.invokeMethod('stop');
          }
        } catch (_) {}
      },
    );
    // Commands from the media session: watch, headset, lock screen, voice search.
    _playback.setMethodCallHandler((call) async {
      if (call.method != 'command') return;
      final a = call.arguments as Map;
      await runMediaCommand(a['cmd'] as String, a['arg'] as String?);
    });
  }

  /// Executes a media command on the page. [cmd] is play, pause, next,
  /// previous or search (with the query in [arg]).
  Future<void> runMediaCommand(String cmd, [String? arg]) async {
    final c = _web;
    if (c == null) return;
    switch (cmd) {
      case 'search':
        final q = arg?.trim() ?? '';
        if (q.isEmpty) return;
        _autoplaySearch = true;
        await open(
          '${DomainFilter.musicHome}search?q=${Uri.encodeQueryComponent(q)}',
        );
        return;
      case 'play':
      case 'pause':
      case 'next':
      case 'previous':
        await c.evaluateJavascript(source: "$_mediaHelpers ytmbCmd('$cmd');");
    }
  }

  bool _autoplaySearch = false;

  Future<void> _refreshNavState() async {
    final c = _web;
    if (c == null) return;
    final back = await c.canGoBack();
    final forward = await c.canGoForward();
    // Single-page apps fire history events very often; only rebuild when the
    // enabled state of a toolbar button actually changes.
    if (back == canGoBack && forward == canGoForward) return;
    canGoBack = back;
    canGoForward = forward;
    notifyListeners();
  }

  // ---- WebView callbacks -------------------------------------------------

  /// Returns the policy for a navigation request.
  Future<NavigationActionPolicy> decideAsync(NavigationAction action) async {
    final policy = decide(action);
    final uri = action.request.url;
    if (isTv &&
        policy == NavigationActionPolicy.ALLOW &&
        action.isForMainFrame != false &&
        uri != null) {
      final wantTv = domainFilter.wantsTvUserAgent(uri);
      if (wantTv != _tvSite) {
        // The server picks the interface from the user agent, so switch it
        // first and then redo this navigation.
        _tvSite = wantTv;
        _invalidateSettings();
        await _web?.setSettings(settings: buildSettings());
        await _web?.loadUrl(urlRequest: action.request);
        return NavigationActionPolicy.CANCEL;
      }
    }
    return policy;
  }

  NavigationActionPolicy decide(NavigationAction action) {
    // Sub-frame navigations (embedded iframes) are not "pages"; let them be.
    if (action.isForMainFrame == false) return NavigationActionPolicy.ALLOW;
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.CANCEL;
    if (domainFilter.isAllowedTopLevel(uri)) {
      return NavigationActionPolicy.ALLOW;
    }
    blockedNotice = 'Blocked: ${uri.host.isEmpty ? uri.scheme : uri.host}';
    notifyListeners();
    return NavigationActionPolicy.CANCEL;
  }

  /// Handles `window.open()` / `target="_blank"`.
  ///
  /// YouTube Music opens Google sign-in in a popup. Cancelling that popup
  /// (the old behaviour) makes the sign-in button do nothing, so load the
  /// popup's URL in this same WebView instead. The sign-in cookies are then
  /// available to the page that Google redirects back to.
  Future<bool> onCreateWindow(CreateWindowAction action) async {
    final uri = action.request.url;
    if (uri == null || uri.toString() == 'about:blank') return false;
    if (decide(action) == NavigationActionPolicy.ALLOW) {
      await _web?.loadUrl(urlRequest: action.request);
    }
    return false;
  }

  /// Google sometimes still answers `403 disallowed_useragent` even after the
  /// WebView marker is removed. Retry the sign-in page once with a desktop
  /// user agent, which Google accepts more often.
  Future<void> onHttpError(
    WebResourceRequest request,
    WebResourceResponse response,
  ) async {
    if (request.isForMainFrame != true || response.statusCode != 403) return;
    if (!domainFilter.isAuthUrl(request.url)) return;
    await _retryAuthWithDesktop(request.url);
  }

  Future<void> _retryAuthWithDesktop(Uri? url) async {
    if (_triedDesktopUserAgent || url == null) return;
    _triedDesktopUserAgent = true;
    _userAgent = UserAgents.desktopFrom(_userAgent);
    _invalidateSettings();
    await _web?.setSettings(settings: buildSettings());
    await _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url.toString())));
  }

  void onLoadStart(Uri? url) {
    _syncRemoteMode(url);
    loadingNotifier.value = true;
    progressNotifier.value = 0;
    final hadError = errorMessage != null;
    errorMessage = null;
    final music = domainFilter.isMusic(url);
    final musicChanged = music != isMusic;
    isMusic = music;
    if (hadError || musicChanged) notifyListeners();
  }

  void onProgress(int p) {
    final value = p / 100;
    if (value != progressNotifier.value) progressNotifier.value = value;
  }

  Future<void> onLoadStop(Uri? url) async {
    _syncRemoteMode(url);
    videoId.value = videoIdOf(url);
    loadingNotifier.value = false;
    progressNotifier.value = 1;
    final music = domainFilter.isMusic(url);
    if (music != isMusic) {
      isMusic = music;
      notifyListeners();
    }
    if (_autoplaySearch && (url?.path.contains('/search') ?? false)) {
      _autoplaySearch = false;
      await _web?.evaluateJavascript(source: _playFirstResult);
    }
    // Some Google error pages are served with status 200, so also inspect the
    // text of sign-in pages.
    if (domainFilter.isAuthUrl(url) && !_triedDesktopUserAgent) {
      try {
        final rejected = await _web?.evaluateJavascript(
          source: _authRejectedCheck,
        );
        if (rejected == true) await _retryAuthWithDesktop(url);
      } catch (_) {}
    }
    await _refreshNavState();
  }

  Future<void> onHistoryChanged(Uri? url) {
    videoId.value = videoIdOf(url);
    return _refreshNavState();
  }

  void onMainFrameError(String description) {
    loadingNotifier.value = false;
    errorMessage = description;
    notifyListeners();
  }

  void clearBlockedNotice() => blockedNotice = null;

  Future<void> onEnterFullscreen() async {
    isFullscreen = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    notifyListeners();
  }

  Future<void> onExitFullscreen() async {
    isFullscreen = false;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(
      isTv
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [],
    );
    notifyListeners();
  }

  // ---- User actions ------------------------------------------------------

  Future<void> goBack() async => _web?.goBack();
  Future<void> goForward() async => _web?.goForward();

  /// Releases the native WebView focus so D-pad events reach Flutter routes
  /// (for example the Settings list) when the WebView is covered.
  Future<void> clearWebViewFocus() async => _web?.clearFocus();

  Future<void> reload() async {
    errorMessage = null;
    notifyListeners();
    final c = _web;
    if (c == null) return;
    // After a failed first load there may be no page to reload.
    final url = await c.getUrl();
    if (url == null || url.toString() == 'about:blank') {
      await goHome();
    } else {
      await c.reload();
    }
  }

  Future<void> goHome() => open(homeUrl);
  Future<void> toggleMusic() =>
      open(isMusic ? homeUrl : DomainFilter.musicHome);

  Future<void> open(String url) async {
    final hadError = errorMessage != null;
    errorMessage = null;
    if (hadError) notifyListeners();
    await _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// Handles the Android back button. Returns true if the app should exit.
  Future<bool> handleSystemBack() async {
    if (isFullscreen) {
      await _web?.evaluateJavascript(
        source: 'document.exitFullscreen && document.exitFullscreen();',
      );
      return false;
    }
    if (_siteHandlesRemote) return _tvSiteBack();
    if (await _web?.canGoBack() ?? false) {
      await _web?.goBack();
      return false;
    }
    return true;
  }

  DateTime? _lastRootBack;

  /// BACK on youtube.com/tv: the page handles "back" itself (closing panels,
  /// leaving the player...) but Android never delivers BACK to it as a key,
  /// so send it the Escape key it listens for. Only when already at the
  /// root screen does a second BACK exit the app.
  Future<bool> _tvSiteBack() async {
    final c = _web;
    if (c == null) return true;
    try {
      await c.evaluateJavascript(
        source: '''
(function () {
  var t = document.activeElement || document.body;
  ['keydown', 'keyup'].forEach(function (type) {
    t.dispatchEvent(new KeyboardEvent(type, {
      key: 'Escape', code: 'Escape', keyCode: 27, which: 27,
      bubbles: true, cancelable: true }));
  });
})();
''',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final hash = (await c.evaluateJavascript(source: 'location.hash'))
          ?.toString();
      final atRoot =
          hash == null || hash.isEmpty || hash == '#/' || hash == '#';
      if (!atRoot) {
        _lastRootBack = null;
        return false;
      }
    } catch (_) {}
    final now = DateTime.now();
    final last = _lastRootBack;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return true;
    }
    _lastRootBack = now;
    blockedNotice = 'Press Back again to exit';
    notifyListeners();
    return false;
  }

  // ---- Settings ----------------------------------------------------------

  Future<void> setAdBlocking(bool enabled) async {
    await settings.setAdBlockingEnabled(enabled);
    _invalidateSettings();
    await _web?.setSettings(settings: buildSettings());
    await _web?.removeAllUserScripts();
    for (final s in userScripts) {
      await _web?.addUserScript(userScript: s);
    }
    await _web?.reload(); // rules apply to subsequent requests
    notifyListeners();
  }

  /// Switches between system / light / dark. The page follows the app's
  /// theme, and YouTube's own dark switch (a cookie) is set as well. The
  /// activity is then restarted so the WebView picks the new theme up.
  Future<void> setThemeMode(String mode) async {
    if (mode == settings.themeMode) return;
    await settings.setThemeMode(mode);
    try {
      final cookies = CookieManager.instance();
      final url = WebUri(DomainFilter.youtubeHome);
      final current = await cookies.getCookie(url: url, name: 'PREF');
      final value = prefWithDark(
        current?.value?.toString(),
        dark: mode == 'dark',
      );
      if (value.isEmpty) {
        await cookies.deleteCookie(
          url: url,
          name: 'PREF',
          domain: '.youtube.com',
        );
      } else {
        await cookies.setCookie(
          url: url,
          name: 'PREF',
          value: value,
          domain: '.youtube.com',
          isSecure: true,
          expiresDate: DateTime.now()
              .add(const Duration(days: 365))
              .millisecondsSinceEpoch,
        );
      }
    } catch (_) {}
    await _deviceChannel.invokeMethod<void>('restart').catchError((_) {});
  }

  Future<void> clearData() async {
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
    await InAppWebViewController.clearAllCache();
    await goHome();
  }

  @override
  void dispose() {
    progressNotifier.dispose();
    loadingNotifier.dispose();
    videoId.dispose();
    super.dispose();
  }
}
