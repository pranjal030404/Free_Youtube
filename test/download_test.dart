import 'package:flutter_test/flutter_test.dart';
import 'package:youtubemusicbrowser/download/downloader.dart';

void main() {
  test('finds the video id on watch and Shorts pages', () {
    expect(
      videoIdOf(Uri.parse('https://m.youtube.com/watch?v=jNQXAC9IVRw&t=3')),
      'jNQXAC9IVRw',
    );
    expect(
      videoIdOf(Uri.parse('https://music.youtube.com/watch?v=jNQXAC9IVRw')),
      'jNQXAC9IVRw',
    );
    expect(
      videoIdOf(Uri.parse('https://m.youtube.com/shorts/jNQXAC9IVRw')),
      'jNQXAC9IVRw',
    );
  });
  test('no id on other pages', () {
    expect(videoIdOf(Uri.parse('https://m.youtube.com/')), isNull);
    expect(videoIdOf(Uri.parse('https://m.youtube.com/watch?v=bad')), isNull);
    expect(
      videoIdOf(Uri.parse('https://example.com/watch?v=jNQXAC9IVRw')),
      isNull,
    );
    expect(videoIdOf(null), isNull);
  });
  test('file names are safe', () {
    expect(safeFileName('a/b: c?  "d"'), 'a b c d');
    expect(safeFileName('///'), 'download');
    expect(safeFileName('x' * 200).length, 80);
  });
}
