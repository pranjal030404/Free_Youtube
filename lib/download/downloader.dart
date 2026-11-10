import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// The video id of a YouTube / YouTube Music watch or Shorts page, or null.
String? videoIdOf(Uri? url) {
  if (url == null || !url.host.toLowerCase().endsWith('youtube.com')) {
    return null;
  }
  String? id;
  if (url.path == '/watch') {
    id = url.queryParameters['v'];
  } else if (url.path.startsWith('/shorts/')) {
    id = url.pathSegments.length > 1 ? url.pathSegments[1] : null;
  }
  return id != null && RegExp(r'^[\w-]{11}$').hasMatch(id) ? id : null;
}

/// A file name that is safe on Android storage.
String safeFileName(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'download';
  return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
}

/// Saves the current video (MP4) or just its audio (M4A) to the phone.
///
/// YouTube only serves combined video+audio files at 360p; higher qualities
/// are separate video and audio tracks that would need a muxer, so the video
/// download is the 360p MP4.
class Downloader {
  static const _channel = MethodChannel('ytmb/device');

  /// 0..1 while a download runs, null when idle.
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);

  bool get busy => progress.value != null;

  /// Downloads [videoId] and returns where it was saved (for display).
  Future<String> download(String videoId, {required bool audioOnly}) async {
    if (busy) throw StateError('A download is already running');
    progress.value = 0;
    final yt = YoutubeExplode();
    File? temp;
    try {
      final video = await yt.videos.get(videoId);
      final manifest = await yt.videos.streams.getManifest(videoId);
      final StreamInfo info;
      if (audioOnly) {
        final all = manifest.audioOnly;
        final mp4 = all.where((s) => s.container == StreamContainer.mp4);
        if (all.isEmpty) throw StateError('No audio available for this video');
        info = (mp4.isNotEmpty ? mp4 : all).withHighestBitrate();
      } else {
        final muxed = manifest.muxed.where(
          (s) => s.container == StreamContainer.mp4,
        );
        if (muxed.isEmpty) throw StateError('No downloadable video file');
        info = muxed.withHighestBitrate();
      }
      final ext = audioOnly
          ? (info.container == StreamContainer.mp4
                ? 'm4a'
                : info.container.name)
          : 'mp4';
      final name = '${safeFileName(video.title)}.$ext';
      temp = File('${Directory.systemTemp.path}/dl_$videoId.$ext');
      final sink = temp.openWrite();
      final total = info.size.totalBytes;
      var done = 0;
      try {
        await for (final chunk in yt.videos.streams.get(info)) {
          sink.add(chunk);
          done += chunk.length;
          if (total > 0) progress.value = (done / total).clamp(0.0, 1.0);
        }
      } finally {
        await sink.close();
      }
      final saved = await _channel.invokeMethod<String>('saveMedia', {
        'path': temp.path,
        'name': name,
        'audio': audioOnly,
        'mime': audioOnly
            ? (ext == 'm4a' ? 'audio/mp4' : 'audio/$ext')
            : 'video/mp4',
      });
      return saved ?? name;
    } finally {
      yt.close();
      progress.value = null;
      try {
        if (temp != null && temp.existsSync()) temp.deleteSync();
      } catch (_) {}
    }
  }
}
