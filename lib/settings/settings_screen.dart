import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../browser/browser_controller.dart';
import '../browser/domain_filter.dart';
import '../download/downloads_screen.dart';

const MethodChannel _deviceChannel = MethodChannel('ytmb/device');
const Color _focusTint = Color(0x33FFFFFF);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final BrowserController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final FocusNode _signInFocus = FocusNode(debugLabel: 'google-sign-in');
  int _focused = 1; // Google sign-in is the initial TV focus.

  @override
  void initState() {
    super.initState();
    if (widget.controller.isTv) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        try {
          await _deviceChannel.invokeMethod<void>('requestFlutterFocus');
        } catch (_) {}
        if (mounted) _signInFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _signInFocus.dispose();
    super.dispose();
  }

  void _onFocus(int index, bool hasFocus) {
    if (hasFocus && _focused != index) {
      setState(() => _focused = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final tv = c.isTv;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: ListView(
          children: [
            if (!tv)
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: const Text('Theme'),
                subtitle: const Text('Changing it reloads the app.'),
                trailing: DropdownButton<String>(
                  value: c.settings.themeMode,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'system', child: Text('System')),
                    DropdownMenuItem(value: 'dark', child: Text('Dark')),
                    DropdownMenuItem(value: 'light', child: Text('Light')),
                  ],
                  onChanged: (v) {
                    if (v != null) c.setThemeMode(v);
                  },
                ),
              ),
            SwitchListTile(
              title: const Text('Ad blocking'),
              subtitle: const Text(
                'Skips YouTube video ads and hides in-feed/banner ad slots '
                'inside the page. Best effort: YouTube may change its page '
                'and let some ads through.',
              ),
              value: c.adBlockingEnabled,
              selected: tv && _focused == 0,
              selectedTileColor: _focusTint,
              onFocusChange: (f) => _onFocus(0, f),
              onChanged: (v) async {
                await c.setAdBlocking(v);
                setState(() {});
              },
            ),
            if (!tv)
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: const Text('Downloads'),
                subtitle: const Text('Play your saved videos and songs.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Google sign-in'),
              subtitle: const Text(
                'Open Google\'s sign-in page directly. Works with the '
                'YouTube account used for YouTube Music.',
              ),
              trailing: const Icon(Icons.open_in_new),
              // On TV, start on the action people actually open Settings for.
              focusNode: tv ? _signInFocus : null,
              autofocus: tv,
              selected: tv && _focused == 1,
              selectedTileColor: _focusTint,
              focusColor: _focusTint,
              onFocusChange: (f) => _onFocus(1, f),
              onTap: () async {
                await c.open(DomainFilter.signInUrl);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.music_note_outlined),
              title: const Text('YouTube Music'),
              trailing: const Icon(Icons.chevron_right),
              selected: tv && _focused == 2,
              selectedTileColor: _focusTint,
              focusColor: _focusTint,
              onFocusChange: (f) => _onFocus(2, f),
              onTap: () async {
                await c.open(DomainFilter.musicHome);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('YouTube home'),
              trailing: const Icon(Icons.chevron_right),
              selected: tv && _focused == 3,
              selectedTileColor: _focusTint,
              focusColor: _focusTint,
              onFocusChange: (f) => _onFocus(3, f),
              onTap: () async {
                await c.goHome();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Refresh page'),
              trailing: const Icon(Icons.chevron_right),
              selected: tv && _focused == 4,
              selectedTileColor: _focusTint,
              focusColor: _focusTint,
              onFocusChange: (f) => _onFocus(4, f),
              onTap: () async {
                await c.reload();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Clear cookies & site data'),
              subtitle: const Text('Signs you out of YouTube.'),
              selected: tv && _focused == 5,
              selectedTileColor: _focusTint,
              focusColor: _focusTint,
              onFocusChange: (f) => _onFocus(5, f),
              onTap: () async {
                await c.clearData();
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            if (!tv)
              const ListTile(
                title: Text('Background playback'),
                subtitle: Text(
                  'On: audio keeps playing with the screen off or the app in the background. A notification shows while playing.',
                ),
              ),
            if (tv)
              const ListTile(
                leading: Icon(Icons.tv),
                title: Text('Android TV'),
                subtitle: Text(
                  'Press the remote MENU key to open this screen. Use the '
                  'D-pad to move and OK to select. Sign-in fields focus '
                  'automatically; press OK to open the on-screen keyboard.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
