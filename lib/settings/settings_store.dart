import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore {
  static const _adKey = 'ad_blocking_enabled';
  late SharedPreferences _prefs;

  Future<void> init() async => _prefs = await SharedPreferences.getInstance();

  /// The remote-control hint is only shown on the first launch.
  bool get tvHintShown => _prefs.getBool('tv_hint_shown') ?? false;
  Future<void> setTvHintShown() => _prefs.setBool('tv_hint_shown', true);

  /// 'system', 'light' or 'dark'. Also read natively at launch (see
  /// MainActivity.attachBaseContext), so keep the key and values in sync.
  String get themeMode => _prefs.getString('theme_mode') ?? 'system';
  Future<void> setThemeMode(String v) => _prefs.setString('theme_mode', v);

  bool get adBlockingEnabled => _prefs.getBool(_adKey) ?? true;
  Future<void> setAdBlockingEnabled(bool v) => _prefs.setBool(_adKey, v);
}
