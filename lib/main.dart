import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'app_flavor.dart';
import 'browser/browser_controller.dart';
import 'browser/browser_screen.dart';
import 'browser/user_agent.dart';
import 'settings/settings_store.dart';

const MethodChannel _deviceChannel = MethodChannel('ytmb/device');

typedef _DeviceInfo = ({bool isTv, int sdkInt, String? userAgent});

Future<_DeviceInfo> _loadDeviceInfo() async {
  try {
    final info = await _deviceChannel
        .invokeMapMethod<String, dynamic>('deviceInfo')
        .timeout(const Duration(seconds: 2));
    return (
      isTv: info?['isTv'] == true,
      sdkInt: (info?['sdkInt'] as num?)?.toInt() ?? 0,
      userAgent: info?['userAgent'] as String?,
    );
  } catch (_) {
    // Not an Android TV / channel unavailable: keep phone defaults.
    return (isTv: false, sdkInt: 0, userAgent: null);
  }
}

/// The installed WebView's own Chrome version with the WebView markers
/// stripped, so Google sign-in does not reject the first page load.
Future<String> _loadUserAgent() async {
  try {
    return UserAgents.sanitize(
      await InAppWebViewController.getDefaultUserAgent().timeout(
        const Duration(seconds: 2),
      ),
    );
  } catch (_) {
    return UserAgents.fallback;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Opt-in WebView debugging for development builds only. It is off in normal
  // release builds (the flag is a compile-time constant).
  if (kDebugMode || const bool.fromEnvironment('WEBVIEW_DEBUG')) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  final settings = SettingsStore();
  // Run all startup work concurrently. These used to be sequential awaits,
  // which added their latencies together before the first frame.
  final (_, device) = await (settings.init(), _loadDeviceInfo()).wait;
  // Built natively from the WebView version (cheap). Asking WebView for its
  // default user agent loads the whole Chromium engine before the first
  // frame, so it is only the fallback for Android < 8.
  final userAgent = device.userAgent != null
      ? UserAgents.sanitize(device.userAgent)
      : await _loadUserAgent();

  // The flavor decides the interface; device detection is only the fallback
  // for an unflavored development build.
  final isTv = isTvBuild || (!isMobileBuild && device.isTv);

  final controller = BrowserController(
    settings: settings,
    isTv: isTv,
    initialUserAgent: userAgent,
  );

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  if (isTv) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  runApp(
    App(
      controller: controller,
      isTv: isTv,
      themeMode: switch (settings.themeMode) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
    ),
  );
}

class App extends StatelessWidget {
  const App({
    super.key,
    required this.controller,
    this.isTv = false,
    this.themeMode = ThemeMode.system,
  });
  final ThemeMode themeMode;
  final BrowserController controller;
  final bool isTv;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      colorSchemeSeed: Colors.red,
      scaffoldBackgroundColor: b == Brightness.dark
          ? const Color(0xFF0F0F0F)
          : null,
      // A strong focus highlight makes D-pad navigation usable on a TV.
      focusColor: isTv ? const Color(0x66FFFFFF) : null,
    );
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: isTv ? ThemeMode.dark : themeMode,
      // Status/navigation bar icons follow the theme, so they stay readable
      // over the page in both light and dark mode.
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final icons = dark ? Brightness.light : Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            statusBarIconBrightness: icons,
            systemNavigationBarIconBrightness: icons,
          ),
          child: child!,
        );
      },
      home: BrowserScreen(controller: controller),
    );
  }
}
