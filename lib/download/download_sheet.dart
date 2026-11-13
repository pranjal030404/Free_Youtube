import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloader.dart';
import 'downloads_screen.dart';

/// YouTube-style "Download" bottom sheet: pick a quality, then Download.
Future<void> showDownloadSheet(
  BuildContext context,
  Downloader downloader,
  String videoId, {
  required bool dark,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  void say(String text, {bool open = false}) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
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

  final picked = await showModalBottomSheet<(DownloadOptions, DownloadOption)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: dark ? const Color(0xFF212121) : Colors.white,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _Sheet(downloader: downloader, videoId: videoId, dark: dark),
  );
  if (picked == null) return;
  final (info, option) = picked;
  say('Downloading ${option.label}…');
  try {
    final where = await downloader.download(videoId, info.title, option);
    say('Download complete · $where', open: true);
  } catch (e) {
    say('Download failed: $e');
  }
}

class _Sheet extends StatefulWidget {
  const _Sheet({
    required this.downloader,
    required this.videoId,
    required this.dark,
  });
  final bool dark;
  final Downloader downloader;
  final String videoId;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  DownloadOptions? _info;
  Object? _error;
  DownloadOption? _sel;
  bool _remember = false;

  static const _prefKey = 'dl_quality_v2';
  static const _prefTs = 'dl_quality_ts';

  Color get _fg => widget.dark ? Colors.white : const Color(0xFF0F0F0F);
  Color get _sub => widget.dark ? const Color(0xFFAAAAAA) : const Color(0xFF606060);
  Color get _line => widget.dark ? Colors.white24 : Colors.black12;
  Color get _blue => widget.dark ? const Color(0xFF3EA6FF) : const Color(0xFF065FD4);

  /// Official names for the lower steps; higher ones show their resolution.
  String _name(DownloadOption o) {
    if (o.audioOnly) return 'Audio only';
    final h = int.tryParse(RegExp(r'^\d+').stringMatch(o.label) ?? '') ?? 0;
    final tail = o.label.substring('${h}p'.length);
    if (h <= 240) return 'Low (${h}p$tail)';
    if (h <= 480) return 'Medium (${h}p$tail)';
    if (h <= 720) return 'High (${h}p$tail)';
    if (h == 1080) return 'Full HD (${h}p$tail)';
    return o.label;
  }

  Future<DownloadOption> _preferred(DownloadOptions o) async {
    try {
      final p = await SharedPreferences.getInstance();
      final ts = p.getInt(_prefTs) ?? 0;
      final key = p.getString(_prefKey);
      final fresh = DateTime.now().millisecondsSinceEpoch - ts <
          const Duration(days: 30).inMilliseconds;
      if (fresh && key != null) {
        if (key == 'audio' && o.audio != null) return o.audio!;
        for (final v in o.videos) {
          if (v.label == key) return v;
        }
      }
    } catch (_) {}
    return o.videos.isNotEmpty ? o.videos.first : o.audio!;
  }

  Future<void> _save(DownloadOption o) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (_remember) {
        await p.setString(_prefKey, o.audioOnly ? 'audio' : o.label);
        await p.setInt(_prefTs, DateTime.now().millisecondsSinceEpoch);
      } else {
        await p.remove(_prefKey);
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    widget.downloader
        .options(widget.videoId)
        .then((o) async {
          final sel = await _preferred(o);
          if (!mounted) return;
          setState(() {
            _info = o;
            _sel = sel;
          });
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e);
        });
  }

  Widget _row(DownloadOption o) => InkWell(
    onTap: () => setState(() => _sel = o),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(
            identical(_sel, o)
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color: _fg,
            size: 22,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              _name(o),
              style: TextStyle(color: _fg, fontSize: 16),
            ),
          ),
          Text(
            o.sizeText,
            style: TextStyle(color: _sub, fontSize: 14),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Download quality',
                style: TextStyle(
                  color: _fg,
                  fontSize: 22,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            if (info != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  info.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _sub),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Can\'t download this video: $_error',
                  style: TextStyle(color: _fg),
                ),
              )
            else if (info == null)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(color: _fg),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in info.videos) _row(o),
                    if (info.audio != null) ...[
                      Divider(color: _line, height: 1),
                      _row(info.audio!),
                    ],
                  ],
                ),
              ),
            Divider(color: _line, height: 1),
            InkWell(
              onTap: () => setState(() => _remember = !_remember),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(
                      _remember ? Icons.check_box : Icons.check_box_outline_blank,
                      color: _fg,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Remember my settings for 30 days',
                      style: TextStyle(color: _fg, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
            Divider(color: _line, height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _blue,
                        side: BorderSide(color: _line),
                        minimumSize: const Size.fromHeight(48),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF065FD4),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      onPressed: info == null || _sel == null
                          ? null
                          : () {
                              _save(_sel!);
                              Navigator.of(context).pop((info, _sel!));
                            },
                      child: const Text('Download'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
