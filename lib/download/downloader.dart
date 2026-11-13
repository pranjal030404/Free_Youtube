import 'dart:io';
import 'dart:typed_data';

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

/// One choice in the download sheet.
class DownloadOption {
  DownloadOption({
    required this.label,
    required this.bytes,
    required this.audioOnly,
    required this.video,
    required this.audio,
    required this.webm,
  });

  /// "2160p60 4K", "1080p", "Audio only"…
  final String label;
  final int bytes;
  final bool audioOnly;
  final VideoOnlyStreamInfo? video;
  final AudioOnlyStreamInfo audio;

  /// VP9 + Opus go into WebM; H.264 + AAC into MP4.
  final bool webm;

  String get sizeText => bytes >= 1 << 30
      ? '${(bytes / (1 << 30)).toStringAsFixed(2)} GB'
      : bytes >= 1 << 20
      ? '${(bytes / (1 << 20)).toStringAsFixed(0)} MB'
      : '${(bytes / 1024).ceil()} KB';
}

class DownloadOptions {
  DownloadOptions(this.title, this.videos, this.audio);
  final String title;
  final List<DownloadOption> videos; // best first
  final DownloadOption? audio;
}

/// Saves a video or its audio at the highest quality YouTube offers.
///
/// YouTube serves everything above 360p as separate video and audio tracks,
/// so the best tracks are downloaded and joined without re-encoding (native
/// MediaMuxer). Video is H.264 (MP4) or VP9 (WebM, used for 1440p/4K).

/// A minimal HTTPS GET that connects over the same IP family the stream URL
/// was issued for (its `ip` parameter). googlevideo links are bound to one
/// address; on a dual-stack network a connection over the other family is
/// refused with 403, and dart:io's HttpClient gives no control over it.
///
/// Returns the status and body; with [headersOnly] the body is not read.
Future<(int, Uint8List)> rawGet(
  Uri url, {
  bool headersOnly = false,
  void Function(int)? onBytes,
  int hops = 0,
}) async {
  final ip = url.queryParameters['ip'];
  final type = ip != null && ip.contains(':')
      ? InternetAddressType.IPv6
      : InternetAddressType.IPv4;
  final addrs = await InternetAddress.lookup(url.host, type: type);
  final plain = await Socket.connect(
    addrs.first,
    443,
    timeout: const Duration(seconds: 12),
  );
  final sock = await SecureSocket.secure(plain, host: url.host);
  try {
    sock.write(
      'GET ${url.path}?${url.query} HTTP/1.1\r\n'
      'Host: ${url.host}\r\n'
      'User-Agent: com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip\r\n'
      'Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n',
    );
    await sock.flush();
    final all = BytesBuilder(copy: false);
    var headEnd = -1;
    var status = 0;
    var chunked = false;
    var bodyStart = 0;
    var counted = 0;
    await for (final d in sock.timeout(const Duration(seconds: 30))) {
      all.add(d);
      if (headEnd < 0) {
        final bytes = all.toBytes();
        final i = _find(bytes, const [13, 10, 13, 10]);
        if (i < 0) continue;
        headEnd = i;
        bodyStart = i + 4;
        final head = String.fromCharCodes(bytes, 0, i).toLowerCase();
        status = int.tryParse(head.split(' ')[1]) ?? 0;
        chunked = head.contains('transfer-encoding: chunked');
        if (status >= 300 && status < 400 && hops < 4) {
          final raw = String.fromCharCodes(bytes, 0, i);
          final m = RegExp(r'^location:\s*(\S+)', multiLine: true, caseSensitive: false)
              .firstMatch(raw);
          if (m != null) {
            sock.destroy();
            return await rawGet(
              url.resolve(m.group(1)!),
              headersOnly: headersOnly,
              onBytes: onBytes,
              hops: hops + 1,
            );
          }
        }
        if (headersOnly || status >= 400) {
          return (status, Uint8List(0));
        }
        counted = bytes.length - bodyStart;
        onBytes?.call(counted);
      } else {
        onBytes?.call(d.length);
      }
    }
    final bytes = all.takeBytes();
    var body = Uint8List.sublistView(bytes, bodyStart < 0 ? 0 : bodyStart);
    if (chunked) body = _unchunk(body);
    return (status, body);
  } finally {
    sock.destroy();
  }
}

int _find(Uint8List b, List<int> pat) {
  outer:
  for (var i = 0; i <= b.length - pat.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (b[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}

Uint8List _unchunk(Uint8List b) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < b.length) {
    final e = _find(Uint8List.sublistView(b, i), const [13, 10]);
    if (e < 0) break;
    final n = int.tryParse(String.fromCharCodes(b, i, i + e).split(';')[0].trim(), radix: 16) ?? 0;
    i += e + 2;
    if (n == 0) break;
    out.add(Uint8List.sublistView(b, i, i + n));
    i += n + 2;
  }
  return out.takeBytes();
}

class Downloader {
  static const _channel = MethodChannel('ytmb/device');

  /// 0..1 while a download runs, null when idle.
  final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
  final ValueNotifier<String> status = ValueNotifier<String>('');

  bool get busy => progress.value != null;

  static int _q(VideoOnlyStreamInfo v) =>
      int.tryParse(RegExp(r'^\d+').stringMatch(v.videoQualityLabel) ?? '') ??
      v.videoResolution.height;

  static String _res(VideoOnlyStreamInfo v) {
    // YouTube's own tier (itag based), not the raw pixel height: a 3:2 video
    // is 2026 px tall but is still "1440p".
    final q = int.tryParse(
          RegExp(r'^\d+').stringMatch(v.videoQualityLabel) ?? '',
        ) ??
        v.videoResolution.height;
    final fps = v.framerate.framesPerSecond.round();
    final tag = q >= 4320
        ? ' 8K'
        : q >= 2160
        ? ' 4K'
        : q >= 1440
        ? ' 2K'
        : q >= 1080 && v.videoQualityLabel.contains('HDR')
        ? ' HDR'
        : '';
    return '${q}p${fps > 30 ? '$fps' : ''}$tag';
  }

  /// The qualities available for [videoId], like YouTube's own download sheet.
  /// YouTube refuses large requests for some tracks (Opus, 48 kbps AAC, the
  /// tiniest videos) from this client, so only tracks that really answer a
  /// 1 MB request are offered.
  static Future<Set<int>> _servable(List<StreamInfo> all) async {
    final ok = <int>{};
    await Future.wait([
      for (final s in all)
        () async {
          try {
            final (code, _) = await rawGet(
              s.url.replace(
                queryParameters: {...s.url.queryParameters, 'range': '0-1048575'},
              ),
              headersOnly: true,
            );
            debugPrint('YTL servable ${s.tag} -> $code');
            if (code < 400) ok.add(s.tag);
          } catch (e) {
            debugPrint('YTL servable ${s.tag} error $e');
          }
        }(),
    ]);
    return ok;
  }

  /// The qualities available for [videoId], like YouTube's own download sheet.
  Future<DownloadOptions> options(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final video = await yt.videos.get(videoId);
      final m = await yt.videos.streams.getManifest(videoId);
      final cand = [
        ...m.audioOnly.where((s) => s.container == StreamContainer.mp4),
        ...m.videoOnly.where((s) {
          final c = s.videoCodec.toLowerCase();
          return c.startsWith('avc') || c.startsWith('vp9'); // no AV1
        }),
      ];
      final ok = await _servable(cand);
      final aac = m.audioOnly.where(
        (s) => s.container == StreamContainer.mp4 && ok.contains(s.tag),
      );
      if (aac.isEmpty) throw StateError('No downloadable audio for this video');
      final bestAac = aac.withHighestBitrate();

      // One entry per quality label (1080p, 1080p60, 2160p60 4K …): the
      // highest-bitrate servable stream of it.
      final best = <String, VideoOnlyStreamInfo>{};
      for (final v in m.videoOnly) {
        final c = v.videoCodec.toLowerCase();
        if (!(c.startsWith('avc') || c.startsWith('vp9'))) continue;
        if (!ok.contains(v.tag)) continue;
        final key = _res(v);
        final cur = best[key];
        if (cur == null || v.bitrate.bitsPerSecond > cur.bitrate.bitsPerSecond) {
          best[key] = v;
        }
      }
      final list = best.values.toList()
        ..sort((a, b) {
          final h = _q(b).compareTo(_q(a));
          return h != 0
              ? h
              : b.framerate.framesPerSecond.compareTo(a.framerate.framesPerSecond);
        });
      final videos = [
        for (final v in list)
          DownloadOption(
            label: _res(v),
            bytes: v.size.totalBytes + bestAac.size.totalBytes,
            audioOnly: false,
            video: v,
            audio: bestAac,
            webm: false,
          ),
      ];
      return DownloadOptions(
        video.title,
        videos,
        DownloadOption(
          label: 'Audio only',
          bytes: bestAac.size.totalBytes,
          audioOnly: true,
          video: null,
          audio: bestAac,
          webm: false,
        ),
      );
    } finally {
      yt.close();
    }
  }

  /// Downloads [option] of [videoId]; returns where it was saved.
  Future<String> download(
    String videoId,
    String title,
    DownloadOption picked,
  ) async {
    if (busy) throw StateError('A download is already running');
    var option = picked;
    progress.value = 0;
    status.value = 'Downloading';
    final yt = YoutubeExplode();
    final temps = <File>[];
    try {
      // Stream links go stale (and the Android client's links are picky), so
      // the chosen tracks are looked up again in a fresh manifest.
      final fresh = await yt.videos.streams.getManifest(videoId);
      final freshA = fresh.audioOnly.firstWhere(
        (s) => s.tag == picked.audio.tag,
        orElse: () => picked.audio,
      );
      final freshV = picked.video == null
          ? null
          : fresh.videoOnly.firstWhere(
              (s) => s.tag == picked.video!.tag,
              orElse: () => picked.video!,
            );
      option = DownloadOption(
        label: picked.label,
        bytes: picked.bytes,
        audioOnly: picked.audioOnly,
        video: freshV,
        audio: freshA,
        webm: picked.webm,
      );
      final tmp = Directory.systemTemp.path;
      final total = (option.video?.size.totalBytes ?? 0) +
          option.audio.size.totalBytes;
      var done = 0;
      void tick(int n) {
        done += n;
        if (total > 0) progress.value = (done / total).clamp(0.0, 0.99);
      }

      // YouTube throttles a single connection, so the file is cut into
      // bounded ranges that several connections fetch at once.
      Future<void> parallel(StreamInfo info, File f) async {
        final size = info.size.totalBytes;
        const chunk = 8 << 20;
        const workers = 1;
        final raf = await f.open(mode: FileMode.write);
        var next = 0;
        var lock = Future<void>.value();
        // One ranged request; a range the server refuses is split in half
        // (down to 1 MB) because it only serves some tracks small pieces.
        Future<void> fetchRange(int from, int to) async {
          for (var attempt = 0;; attempt++) {
            var refused = false;
            try {
              var got = 0;
              final (code, bytes) = await rawGet(
                info.url.replace(
                  queryParameters: {
                    ...info.url.queryParameters,
                    'range': '$from-$to',
                  },
                ),
                onBytes: (n) {
                  got += n;
                  tick(n);
                },
              );
              if (code >= 400) {
                refused = code == 403;
                throw HttpException('HTTP $code');
              }
              if (bytes.length != to - from + 1) {
                tick(-got);
                throw HttpException('short chunk ${bytes.length}');
              }
              final turn = lock.then((_) async {
                await raf.setPosition(from);
                await raf.writeFrom(bytes);
              });
              lock = turn.catchError((_) {});
              await turn;
              return;
            } catch (e) {
              debugPrint('YTL range $from-$to attempt $attempt failed: $e');
              final len = to - from + 1;
              if (refused && len > (1 << 20)) {
                final mid = from + (len ~/ 2);
                await fetchRange(from, mid - 1);
                await fetchRange(mid, to);
                return;
              }
              if (attempt >= 3) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 600));
            }
          }
        }

        Future<void> worker() async {
          while (true) {
            final from = next;
            if (from >= size) return;
            next += chunk;
            await fetchRange(from, (from + chunk < size ? from + chunk : size) - 1);
          }
        }

        try {
          await Future.wait([for (var i = 0; i < workers; i++) worker()]);
        } finally {
          await raf.close();
        }
      }

      Future<File> fetch(StreamInfo info, String ext) async {
        final f = File('$tmp/dl_${videoId}_$ext');
        temps.add(f);
        final before = done;
        try {
          await parallel(info, f);
        } catch (e) {
          debugPrint('YTL parallel failed: $e');
          // Fall back to the library's own sequential download.
          done = before;
          final sink = f.openWrite();
          try {
            await for (final chunk in yt.videos.streams.get(info)) {
              sink.add(chunk);
              tick(chunk.length);
            }
          } finally {
            await sink.close();
          }
        }
        return f;
      }

      final base = safeFileName(title);
      if (option.audioOnly) {
        final isM4a = option.audio.container == StreamContainer.mp4;
        final ext = isM4a ? 'm4a' : 'webm';
        final f = await fetch(option.audio, 'a.$ext');
        final saved = await _channel.invokeMethod<String>('saveMedia', {
          'path': f.path,
          'name': '$base.$ext',
          'audio': true,
          'mime': isM4a ? 'audio/mp4' : 'audio/webm',
        });
        return saved ?? '$base.$ext';
      }
      final v = await fetch(option.video!, 'v.${option.webm ? 'webm' : 'mp4'}');
      final a = await fetch(option.audio, 'a.${option.webm ? 'webm' : 'm4a'}');
      status.value = 'Finishing';
      final ext = option.webm ? 'webm' : 'mp4';
      final out = File('$tmp/dl_${videoId}_out.$ext');
      temps.add(out);
      await _channel.invokeMethod<void>('muxMedia', {
        'video': v.path,
        'audio': a.path,
        'out': out.path,
        'webm': option.webm,
      });
      final saved = await _channel.invokeMethod<String>('saveMedia', {
        'path': out.path,
        'name': '$base (${option.label}).$ext',
        'audio': false,
        'mime': option.webm ? 'video/webm' : 'video/mp4',
      });
      return saved ?? '$base.$ext';
    } finally {
      yt.close();
      progress.value = null;
      for (final f in temps) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }
}
