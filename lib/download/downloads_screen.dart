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
      date = (m['date'] as num?)?.toInt() ?? 0;
  final String name, uri, mime;
  final bool audio;
  final int size, date;

  String get title {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String get sizeText => size >= 1 << 20
      ? '${(size / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(size / 1024).ceil()} KB';
}

/// Lists the videos and songs this app downloaded; tap one to play it.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<_Item>? _items;
  String? _error;

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
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

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
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text(item.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _channel.invokeMethod<void>('deleteMedia', {'uri': item.uri});
    } on PlatformException catch (e) {
      if (mounted) _say(e.message ?? 'Could not delete');
    }
    await _load();
  }

  Widget _list(List<_Item> items, String empty) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(empty, textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return ListTile(
            leading: CircleAvatar(
              child: Icon(item.audio ? Icons.music_note : Icons.play_arrow),
            ),
            title: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(item.sizeText),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(item),
            ),
            onTap: () => _play(item),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Downloads'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Videos'),
              Tab(text: 'Songs'),
            ],
          ),
        ),
        body: _error != null
            ? Center(child: Text('Could not load downloads: $_error'))
            : items == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _list(
                    items.where((i) => !i.audio).toList(),
                    'No videos yet. Open a video and tap the download button.',
                  ),
                  _list(
                    items.where((i) => i.audio).toList(),
                    'No songs yet. Open a video and choose "Download song".',
                  ),
                ],
              ),
      ),
    );
  }
}
