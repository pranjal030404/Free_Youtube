import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
    if (c.isTv) {
      // The remote's menu/settings key is handled natively so it works even
      // while the WebView has Android input focus.
      _deviceChannel.setMethodCallHandler((call) async {
        if (call.method == 'openSettings') await _openSettings();
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
        builder: (context, _) => Scaffold(
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
                          shouldOverrideUrlLoading: (_, action) async =>
                              c.decide(action),
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
                        if (!c.isFullscreen && !c.isTv)
                          Positioned(
                            right: 12,
                            bottom: 76, // above the site's bottom tab bar
                            child: _DownloadButton(c: c),
                          ),
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
    );
  }
}

/// Shown on watch / Shorts pages: saves the video or just its audio.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.c});
  final BrowserController c;

  Future<void> _start(BuildContext context, String id, bool audioOnly) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    void say(String text, {bool open = false}) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: open
              ? SnackBarAction(
                  label: 'OPEN',
                  onPressed: () => navigator.push(
                    MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                  ),
                )
              : null,
        ),
      );
    say(audioOnly ? 'Downloading song…' : 'Downloading video…');
    try {
      final where = await c.downloader.download(id, audioOnly: audioOnly);
      say('Saved to $where', open: true);
    } catch (e) {
      say('Download failed: $e');
    }
  }

  void _choose(BuildContext context, String id) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.movie_outlined),
              title: const Text('Download video'),
              subtitle: const Text('MP4, 360p, with sound'),
              onTap: () {
                Navigator.of(sheet).pop();
                _start(context, id, false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: const Text('Download song'),
              subtitle: const Text('Audio only (M4A)'),
              onTap: () {
                Navigator.of(sheet).pop();
                _start(context, id, true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('My downloads'),
              onTap: () {
                Navigator.of(sheet).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: c.videoId,
      builder: (context, id, _) => ValueListenableBuilder<double?>(
        valueListenable: c.downloader.progress,
        builder: (context, progress, _) {
          if (id == null && progress == null) return const SizedBox.shrink();
          return FloatingActionButton.small(
            heroTag: null,
            tooltip: progress == null ? 'Download' : 'Downloading',
            backgroundColor: const Color(0xE6272727),
            foregroundColor: Colors.white,
            onPressed: progress != null || id == null
                ? null
                : () => _choose(context, id),
            child: progress == null
                ? const Icon(Icons.download)
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: progress > 0 ? progress : null,
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                      Text(
                        '${(progress * 100).round()}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
          );
        },
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
