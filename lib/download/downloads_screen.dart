import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('ytmb/device');

class _Item {
  _Item(Map<dynamic, dynamic> m)
    : name = m['name'] as String? ?? '',
      uri = m['uri'] as String? ?? '',
      mime = m['mime'] as String? ?? '',
      audio = m['audio'] == true,
      size = (m['size'] as num?)?.toInt() ?? 0,
      date = (m['date'] as num?)?.toInt() ?? 0,
      durationMs = (m['duration'] as num?)?.toInt() ?? 0;
  final String name, uri, mime;
  final bool audio;
  final int size, date, durationMs;

  /// "Title (1080p).mp4" -> "Title"; the quality is shown on its own line.
  String get title {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.replaceFirst(RegExp(r'\s*\(\d+p[^)]*\)$'), '');
  }

  String get quality {
    final m = RegExp(r'\((\d+p[^)]*)\)\.\w+$').firstMatch(name);
    return audio ? 'Audio' : (m?.group(1) ?? 'Video');
  }

  String get durationText {
    final s = durationMs ~/ 1000;
    if (s <= 0) return '';
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
  }
}

String _bytes(num b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(b / 1024).ceil()} KB';
}

/// The videos and songs this app downloaded, laid out like the Downloads
/// page of the YouTube app.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<_Item>? _items;
  String? _error;
  int _total = 0, _free = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('listMedia') ?? [];
      final items = raw.map(_Item.new).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final st = await _channel.invokeMapMethod<String, dynamic>('storageInfo');
      if (mounted) {
        setState(() {
          _items = items;
          _total = (st?['total'] as num?)?.toInt() ?? 0;
          _free = (st?['free'] as num?)?.toInt() ?? 0;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );

  Future<void> _play(_Item item) async {
    try {
      await _channel.invokeMethod<void>('playMedia', {
        'uri': item.uri,
        'mime': item.mime,
      });
    } on PlatformException catch (e) {
      _say(e.message ?? 'No app found to play this file');
    }
  }

  Future<void> _delete(_Item item) async {
    try {
      await _channel.invokeMethod<void>('deleteMedia', {'uri': item.uri});
      _say('Deleted from downloads');
    } on PlatformException catch (e) {
      if (mounted) _say(e.message ?? 'Could not delete');
    }
    await _load();
  }

  void _menu(_Item item, Color fg, Color bg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: Icon(Icons.play_arrow_outlined, color: fg),
              title: Text('Play', style: TextStyle(color: fg, fontSize: 16)),
              onTap: () {
                Navigator.of(sheet).pop();
                _play(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: fg),
              title: Text(
                'Delete from downloads',
                style: TextStyle(color: fg, fontSize: 16),
              ),
              onTap: () {
                Navigator.of(sheet).pop();
                _delete(item);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bg = dark ? const Color(0xFF0F0F0F) : Colors.white;
    final sheetBg = dark ? const Color(0xFF212121) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF0F0F0F);
    final sub = dark ? const Color(0xFFAAAAAA) : const Color(0xFF606060);
    final items = _items;
    final used = items?.fold<int>(0, (a, i) => a + i.size) ?? 0;

    Widget body;
    if (_error != null) {
      body = Center(
        child: Text('Could not load downloads', style: TextStyle(color: sub)),
      );
    } else if (items == null) {
      body = Center(child: CircularProgressIndicator(color: fg));
    } else if (items.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_for_offline_outlined, size: 64, color: sub),
              const SizedBox(height: 16),
              Text(
                'Videos you download will appear here',
                textAlign: TextAlign.center,
                style: TextStyle(color: fg, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.builder(
          itemCount: items.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return _Storage(
                used: used,
                free: _free,
                total: _total,
                fg: fg,
                sub: sub,
                dark: dark,
              );
            }
            final item = items[i - 1];
            return InkWell(
              onTap: () => _play(item),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Thumb(item: item, dark: dark),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: fg,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${item.quality} · ${_bytes(item.size)}',
                              style: TextStyle(color: sub, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: 'More',
                        icon: Icon(Icons.more_vert, color: fg, size: 20),
                        onPressed: () => _menu(item, fg, sheetBg),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: fg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Downloads',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
        ),
      ),
      body: body,
    );
  }
}

/// "Downloads · 1.2 GB used · 40 GB free" with the device storage bar.
class _Storage extends StatelessWidget {
  const _Storage({
    required this.used,
    required this.free,
    required this.total,
    required this.fg,
    required this.sub,
    required this.dark,
  });
  final int used, free, total;
  final Color fg, sub;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final otherUsed = total > 0 ? (total - free - used).clamp(0, total) : 0;
    final f1 = total > 0 ? otherUsed / total : 0.0;
    final f2 = total > 0 ? used / total : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Row(
                children: [
                  Expanded(
                    flex: (f1 * 1000).round(),
                    child: Container(color: sub.withValues(alpha: 0.5)),
                  ),
                  Expanded(
                    flex: (f2 * 1000).round().clamp(used > 0 ? 6 : 0, 1000),
                    child: Container(color: const Color(0xFF3EA6FF)),
                  ),
                  Expanded(
                    flex: (1000 - (f1 * 1000).round() - (f2 * 1000).round())
                        .clamp(1, 1000),
                    child: Container(
                      color: dark ? Colors.white12 : Colors.black12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${_bytes(used)} used by downloads · ${_bytes(free)} free',
            style: TextStyle(color: sub, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 16:9 thumbnail with the duration badge, like the YouTube video rows.
class _Thumb extends StatefulWidget {
  const _Thumb({required this.item, required this.dark});
  final _Item item;
  final bool dark;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _channel
        .invokeMethod<Uint8List>('thumb', {'uri': widget.item.uri})
        .then((b) {
          if (mounted && b != null) setState(() => _bytes = b);
        })
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final dur = widget.item.durationText;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 148,
        height: 83,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_bytes != null)
              Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true)
            else
              ColoredBox(
                color: widget.dark
                    ? const Color(0xFF272727)
                    : const Color(0xFFE5E5E5),
                child: Icon(
                  widget.item.audio ? Icons.music_note : Icons.play_arrow,
                  color: widget.dark ? Colors.white54 : Colors.black45,
                ),
              ),
            if (dur.isNotEmpty)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    dur,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
