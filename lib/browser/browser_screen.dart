import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../download/download_sheet.dart';
import '../download/downloader.dart';
import '../download/downloads_screen.dart';
import '../settings/settings_screen.dart';
import '../widgets/loading_indicator.dart';
import 'browser_controller.dart';

const MethodChannel _deviceChannel = MethodChannel('ytmb/device');

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.controller});
  final BrowserController controller;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  BrowserController get c => widget.controller;
  bool _settingsOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_onChange);
    c.downloadRequest.addListener(_onDownloadRequest);
    c.openDownloads.addListener(_onOpenDownloads);
    if (c.isTv) {
      // The remote's menu/settings key is handled natively so it works even
      // while the WebView has Android input focus.
      _deviceChannel.setMethodCallHandler((call) async {
        if (call.method == 'openSettings') await _openSettings();
        if (call.method == 'voiceKey') await c.onVoiceKey();
        return null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusWebView();
        if (c.settings.tvHintShown) return;
        c.settings.setTvHintShown();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Use the D-pad to move, OK to select, MENU for Settings.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_onChange);
    c.downloadRequest.removeListener(_onDownloadRequest);
    c.openDownloads.removeListener(_onOpenDownloads);
    if (c.isTv) _deviceChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _focusWebView();
  }

  /// On TV the page owns the remote: the in-page navigation script moves a
  /// focus highlight with the D-pad, exactly like a native TV app.
  Future<void> _focusWebView() async {
    if (!mounted || !c.isTv || _settingsOpen) return;
    try {
      await _deviceChannel.invokeMethod<void>('requestWebViewFocus');
    } catch (_) {}
  }

  DateTime? _lastExitBack;

  /// Phone: BACK with nothing left to go back to. The first press offers
  /// Settings (there is no toolbar), a second one within 3 s exits.
  Future<void> _backAtRoot() async {
    if (c.isTv) return SystemNavigator.pop();
    final now = DateTime.now();
    final last = _lastExitBack;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return SystemNavigator.pop();
    }
    _lastExitBack = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Press back again to exit'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(label: 'MENU', onPressed: _openSettings),
        ),
      );
  }

  void _onOpenDownloads() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DownloadsScreen()),
    );
  }

  void _onDownloadRequest() {
    final id = c.menuVideoId ?? c.videoId.value;
    if (id == null || !mounted) return;
    if (c.downloader.busy) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('A download is already in progress')),
        );
      return;
    }
    showDownloadSheet(
      context,
      c.downloader,
      id,
      dark: c.pageDark.value ?? Theme.of(context).brightness == Brightness.dark,
    );
  }

  void _onChange() {
    final msg = c.blockedNotice;
    if (msg != null) {
      c.clearBlockedNotice();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
        );
    }
  }

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    // The native WebView can keep Android input focus even when the settings
    // route is on top. Release it and give key focus back to Flutter so the
    // D-pad moves through the settings list.
    await c.clearWebViewFocus();
    if (!mounted) return;
    if (c.isTv) {
      try {
        await _deviceChannel.invokeMethod<void>('requestFlutterFocus');
      } catch (_) {}
    }
    if (!mounted) {
      _settingsOpen = false;
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => SettingsScreen(controller: c)));
    _settingsOpen = false;
    if (!mounted || !c.isTv) return;
    await _focusWebView();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (Navigator.of(context).canPop()) return;
        if (await c.handleSystemBack() && context.mounted) await _backAtRoot();
      },
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) => ValueListenableBuilder<bool?>(
          valueListenable: c.pageDark,
          builder: (context, dark, child) {
            if (c.isTv || dark == null) return child!;
            // Status / navigation bars follow the page's own theme.
            final bg = dark ? const Color(0xFF0F0F0F) : Colors.white;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                statusBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                systemNavigationBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
              ),
              child: ColoredBox(color: bg, child: child),
            );
          },
          child: Scaffold(
            backgroundColor: c.isTv ? null : Colors.transparent,
          body: SafeArea(
            top: !c.isFullscreen,
            bottom: !c.isFullscreen,
            child: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(),
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        InAppWebView(
                          initialUrlRequest: URLRequest(url: WebUri(c.homeUrl)),
                          initialSettings: c.buildSettings(),
                          initialUserScripts: UnmodifiableListView(
                            c.userScripts,
                          ),
                          onWebViewCreated: c.attach,
                          shouldOverrideUrlLoading: (_, action) =>
                              c.decideAsync(action),
                          onCreateWindow: (_, action) =>
                              c.onCreateWindow(action),
                          onLoadStart: (_, url) => c.onLoadStart(url),
                          onProgressChanged: (_, p) => c.onProgress(p),
                          onLoadStop: (_, url) async {
                            await c.onLoadStop(url);
                            await _focusWebView();
                          },
                          onUpdateVisitedHistory: (_, url, _) =>
                              c.onHistoryChanged(url),
                          onReceivedError: (_, request, error) {
                            if (request.isForMainFrame ?? false) {
                              c.onMainFrameError(error.description);
                            }
                          },
                          onReceivedHttpError: (_, request, response) =>
                              c.onHttpError(request, response),
                          onEnterFullscreen: (_) => c.onEnterFullscreen(),
                          onExitFullscreen: (_) => c.onExitFullscreen(),
                          onPermissionRequest: (_, req) async =>
                              PermissionResponse(
                                resources: const [],
                                action: PermissionResponseAction.DENY,
                              ),
                        ),
                        // No browser toolbar: the page fills the screen, as
                        // in a native app. Only a thin progress bar on top.
                        if (!c.isFullscreen && !c.isTv)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: LoadingIndicator(
                              visible: c.loadingNotifier,
                              progress: c.progressNotifier,
                            ),
                          ),
                        // TV: the YouTube logo stays up until the first
                        // screen is drawn, so no blank page or loading
                        // state is ever visible.
                        if (!c.isTv) _DownloadBar(c.downloader),
                        if (c.isTv) _Splash(ready: c.pageReady),
                        if (c.errorMessage != null) _ErrorView(c: c),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.c});
  final BrowserController c;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, size: 56),
                const SizedBox(height: 16),
                const Text(
                  "Can't reach YouTube",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(c.errorMessage ?? '', textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: c.reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Covers the WebView until the page has drawn its first screen, then fades out.
class _Splash extends StatelessWidget {
  const _Splash({required this.ready});
  final ValueNotifier<bool> ready;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ValueListenableBuilder<bool>(
        valueListenable: ready,
        builder: (context, isReady, _) => IgnorePointer(
          ignoring: isReady,
          child: AnimatedOpacity(
            opacity: isReady ? 0 : 1,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            child: const ColoredBox(
              color: Color(0xFF0F0F0F),
              child: Center(child: _Logo()),
            ),
          ),
        ),
      ),
    );
  }
}

/// The same red play button the launch window shows (see splash_icon.xml).
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 60,
      decoration: BoxDecoration(
        color: const Color(0xFFFF0033),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.play_arrow, color: Colors.white, size: 44),
    );
  }
}

/// Progress of a running download, styled like YouTube's snackbar.
class _DownloadBar extends StatelessWidget {
  const _DownloadBar(this.d);
  final Downloader d;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      right: 8,
      bottom: 64,
      child: ValueListenableBuilder<double?>(
        valueListenable: d.progress,
        builder: (context, p, _) {
          if (p == null) return const SizedBox.shrink();
          return ValueListenableBuilder<String>(
            valueListenable: d.status,
            builder: (context, status, _) => Material(
              color: const Color(0xFF333333),
              borderRadius: BorderRadius.circular(8),
              elevation: 6,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.download, color: Colors.white, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            status == 'Finishing'
                                ? 'Finishing…'
                                : 'Downloading… ${(p * 100).round()}%',
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: status == 'Finishing' ? null : p,
                      minHeight: 3,
                      color: const Color(0xFF3EA6FF),
                      backgroundColor: Colors.white24,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
