import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:picshow_mobile/core/storage/media_cache_budget.dart';

class AppPrefs {
  AppPrefs._(this._prefs);

  static const _legacyServerUrlKey = 'server_url';
  static const _localServerUrlKey = 'local_server_url';
  static const _remoteServerUrlKey = 'remote_server_url';
  static const _themeModeKey = 'theme_mode';
  static const _cacheBudgetBytesKey = 'cache_budget_bytes';

  final SharedPreferences _prefs;

  static Future<AppPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Migrate the old single-URL setting: it was reachable directly, so
    // keep it as the "local" address rather than dropping it.
    final legacyUrl = prefs.getString(_legacyServerUrlKey);
    if (legacyUrl != null &&
        prefs.getString(_localServerUrlKey) == null &&
        prefs.getString(_remoteServerUrlKey) == null) {
      await prefs.setString(_localServerUrlKey, legacyUrl);
    }
    if (legacyUrl != null) {
      await prefs.remove(_legacyServerUrlKey);
    }
    return AppPrefs._(prefs);
  }

  /// LAN-only address (e.g. http://192.168.1.20:8281).
  String? get localServerUrl => _prefs.getString(_localServerUrlKey);

  /// Internet-reachable address (e.g. https://picshow.example.com).
  String? get remoteServerUrl => _prefs.getString(_remoteServerUrlKey);

  Future<void> setServerUrls({String? local, String? remote}) async {
    if (local == null || local.isEmpty) {
      await _prefs.remove(_localServerUrlKey);
    } else {
      await _prefs.setString(_localServerUrlKey, local);
    }
    if (remote == null || remote.isEmpty) {
      await _prefs.remove(_remoteServerUrlKey);
    } else {
      await _prefs.setString(_remoteServerUrlKey, remote);
    }
  }

  Future<void> clearServerUrls() async {
    await _prefs.remove(_localServerUrlKey);
    await _prefs.remove(_remoteServerUrlKey);
  }

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

  /// Total disk budget for cached thumbnails, images and videos.
  int get cacheBudgetBytes =>
      _prefs.getInt(_cacheBudgetBytesKey) ?? MediaCacheBudget.defaultBudgetBytes;

  Future<void> setCacheBudgetBytes(int bytes) =>
      _prefs.setInt(_cacheBudgetBytesKey, bytes);
}
