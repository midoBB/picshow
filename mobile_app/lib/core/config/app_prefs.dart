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
  static const _cacheKeySchemaVersionKey = 'cache_key_schema_version';
  static const _favoriteBackfillDoneKey = 'favorite_ledger_backfilled';
  static const _manualOfflineKey = 'manual_offline';

  /// Bumped whenever the [cacheKeyFor] scheme changes, making every entry
  /// already on disk unreachable. Version 1 keyed full images and videos by
  /// their URL, so those entries died on any LAN/public address switch.
  static const currentCacheKeySchemaVersion = 2;

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
      _prefs.getInt(_cacheBudgetBytesKey) ??
      MediaCacheBudget.defaultBudgetBytes;

  Future<void> setCacheBudgetBytes(int bytes) =>
      _prefs.setInt(_cacheBudgetBytesKey, bytes);

  /// The cache-key scheme the on-disk media caches were written with.
  ///
  /// Defaults to 1 because the key predates versioning: an install carrying
  /// v1 caches and a fresh install are indistinguishable here, so both take
  /// the migration path. For a fresh install that's a no-op wipe of two empty
  /// caches, which is the safe way round to be wrong.
  int get cacheKeySchemaVersion =>
      _prefs.getInt(_cacheKeySchemaVersionKey) ?? 1;

  Future<void> setCacheKeySchemaVersion(int version) =>
      _prefs.setInt(_cacheKeySchemaVersionKey, version);

  /// Whether the ledger's `isFavorite` flag has been backfilled from
  /// [RecentMediaStore]. One-time migration for installs predating
  /// favorite-protected eviction.
  bool get favoriteLedgerBackfilled =>
      _prefs.getBool(_favoriteBackfillDoneKey) ?? false;

  Future<void> setFavoriteLedgerBackfilled(bool value) =>
      _prefs.setBool(_favoriteBackfillDoneKey, value);

  /// Whether the user asked to work offline regardless of reachability.
  /// Persisted so the choice survives a restart rather than silently
  /// reverting to hitting the network.
  bool get manualOffline => _prefs.getBool(_manualOfflineKey) ?? false;

  Future<void> setManualOffline(bool value) =>
      _prefs.setBool(_manualOfflineKey, value);
}
