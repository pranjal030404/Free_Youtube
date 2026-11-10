import 'package:flutter_test/flutter_test.dart';
import 'package:youtubemusicbrowser/settings/theme_pref.dart';

void main() {
  test('sets and clears the dark bit, keeping other fields', () {
    expect(prefWithDark(null, dark: true), 'f6=400');
    expect(prefWithDark('', dark: false), '');
    expect(
      prefWithDark('tz=Asia.Kolkata&f4=4000000', dark: true),
      'tz=Asia.Kolkata&f4=4000000&f6=400',
    );
    expect(
      prefWithDark('f6=40000000&tz=UTC', dark: true),
      'tz=UTC&f6=40000400',
    );
    expect(
      prefWithDark('tz=UTC&f6=40000400', dark: false),
      'tz=UTC&f6=40000000',
    );
    expect(prefWithDark('f6=400', dark: false), '');
  });
}
