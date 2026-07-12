import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPrefs {
  AppPrefs._(this._prefs);

  static const _serverUrlKey = 'server_url';
  static const _themeModeKey = 'theme_mode';

  final SharedPreferences _prefs;

  static Future<AppPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppPrefs._(prefs);
  }

  String? get serverUrl => _prefs.getString(_serverUrlKey);

  Future<void> setServerUrl(String url) => _prefs.setString(_serverUrlKey, url);

  Future<void> clearServerUrl() => _prefs.remove(_serverUrlKey);

  ThemeMode get themeMode {
    final value = _prefs.getString(_themeModeKey);
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.dark;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) => _prefs.setString(
    _themeModeKey,
    mode == ThemeMode.light ? 'light' : 'dark',
  );
}
