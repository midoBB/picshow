import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/media_cache_lookup.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

/// Persists metadata for media the user has already fetched, so the gallery
/// can keep showing a "recently viewed" subset while offline. This is a
/// metadata-only cache: the actual thumbnail/image/video bytes continue to
/// live in the existing flutter_cache_manager instances (ThumbCacheManager,
/// FullImageCacheManager, VideoCacheManager) and are not duplicated here.
class RecentMediaStore {
  RecentMediaStore._(this._box, this._pendingFavoritesBox);

  static const boxName = 'recent_media_v1';
  static const _pendingFavoritesBoxName = 'pending_favorite_sync_v1';
  static const _cap = 1000;

  final Box<Map> _box;

  /// Ids toggled while offline, mapped to the desired (locally optimistic)
  /// favorite state, so they can be reconciled against the server once
  /// connectivity returns. Persisted so a killed app doesn't lose pending
  /// changes.
  final Box<bool> _pendingFavoritesBox;

  static Future<RecentMediaStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<Map>(boxName);
    final pendingFavorites = await Hive.openBox<bool>(
      _pendingFavoritesBoxName,
    );
    return RecentMediaStore._(box, pendingFavorites);
  }

  /// Backs the store with a throwaway on-disk Hive box outside the normal
  /// app data directory, so tests don't depend on path_provider platform
  /// channels.
  @visibleForTesting
  static Future<RecentMediaStore> openInMemoryForTesting() async {
    final dir = Directory.systemTemp.createTempSync('recent_media_store_test');
    Hive.init(dir.path);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final box = await Hive.openBox<Map>('test_$suffix');
    final pendingFavorites = await Hive.openBox<bool>(
      'test_pending_favorites_$suffix',
    );
    return RecentMediaStore._(box, pendingFavorites);
  }

  Future<void> upsertAll(Iterable<MediaFile> files) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final updates = <String, Map>{
      for (final file in files) file.id: {'file': file.toJson(), 'lastSeenAt': now},
    };
    await _box.putAll(updates);
    await _enforceCap();
  }

  List<MediaFile> getAll() {
    final files = <MediaFile>[];
    for (final entry in _box.values) {
      final file = _tryParse(entry);
      if (file != null) files.add(file);
    }
    return files;
  }

  /// Applies [query]'s filter and sort semantics client-side over the
  /// locally cached pool. Server-side random ordering can't be replicated
  /// offline, so `SortOrder.random` falls back to a deterministic shuffle
  /// keyed by the same seed.
  List<MediaFile> queryOffline(GalleryQuery query) {
    var files = getAll().where((f) => _matchesFilter(f, query.filter)).toList();

    switch (query.order) {
      case SortOrder.createdAt:
        files.sort(
          (a, b) => query.direction == SortDirection.asc
              ? a.createdAt.compareTo(b.createdAt)
              : b.createdAt.compareTo(a.createdAt),
        );
      case SortOrder.random:
        final rng = Random(query.seed ?? 0);
        final keyed = [for (final f in files) MapEntry(rng.nextDouble(), f)];
        keyed.sort((a, b) => a.key.compareTo(b.key));
        files = [for (final entry in keyed) entry.value];
    }

    return files;
  }

  /// Same as [queryOffline], additionally filtered down to entries that are
  /// actually viewable offline: both the thumbnail (for the grid tile) and
  /// the full-resolution image/video (for the full-screen viewer) must
  /// already be present in their respective disk caches (local lookups, no
  /// network calls). A file whose thumbnail loaded once but whose full
  /// blob was never fetched would otherwise show up as a tile that dead-ends
  /// in a "Not available offline" toast on tap — excluding it here means it
  /// never appears as a tappable tile in the first place.
  Future<List<MediaFile>> queryOfflineFilterCached(
    GalleryQuery query,
    ApiClient api,
  ) async {
    final candidates = queryOffline(query);
    final results = await Future.wait(
      candidates.map((file) async {
        final thumbCached = await ThumbCacheManager.instance.getFileFromCache(
          'thumb-${file.id}',
        );
        if (thumbCached == null) return null;
        return (await isFullBlobCached(file, api)) ? file : null;
      }),
    );
    return [for (final file in results) if (file != null) file];
  }

  Future<void> remove(String id) => _box.delete(id);

  /// Updates the cached copy of [id]'s favorite flag in place, so
  /// [queryOffline]/[queryOfflineFilterCached] reflect a toggle immediately
  /// (whether the toggle happened online or offline) instead of waiting for
  /// the next full [upsertAll] from a list fetch.
  Future<void> updateFavorite(String id, bool isFavorite) async {
    final entry = _box.get(id);
    if (entry == null) return;
    final file = _tryParse(entry);
    if (file == null) return;
    await _box.put(id, {
      'file': file.copyWith(isFavorite: isFavorite).toJson(),
      'lastSeenAt': entry['lastSeenAt'],
    });
  }

  /// Records that [id]'s favorite state was changed to [isFavorite] while
  /// offline, so it can be reconciled against the server on reconnect.
  Future<void> markFavoritePending(String id, bool isFavorite) =>
      _pendingFavoritesBox.put(id, isFavorite);

  /// Clears [id] from the pending-sync set — either it was toggled back to
  /// its original state before reconnecting (net no-op), or it was
  /// successfully reconciled with the server.
  Future<void> clearFavoritePending(String id) =>
      _pendingFavoritesBox.delete(id);

  /// `{id: desired isFavorite}` for every favorite change made while
  /// offline that hasn't yet been reconciled with the server.
  Map<String, bool> get pendingFavorites => {
    for (final key in _pendingFavoritesBox.keys)
      key as String: _pendingFavoritesBox.get(key)!,
  };

  bool _matchesFilter(MediaFile file, MediaFilter filter) {
    switch (filter) {
      case MediaFilter.all:
        return true;
      case MediaFilter.image:
        return file.mediaType == MediaType.image;
      case MediaFilter.video:
        return file.mediaType == MediaType.video;
      case MediaFilter.favorite:
        return file.isFavorite;
    }
  }

  MediaFile? _tryParse(Map entry) {
    try {
      final json = _deepCast(entry['file']) as Map<String, dynamic>;
      return MediaFile.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  dynamic _deepCast(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k as String, _deepCast(v)));
    }
    if (value is List) {
      return value.map(_deepCast).toList();
    }
    return value;
  }

  Future<void> _enforceCap() async {
    if (_box.length <= _cap) return;

    final entries = _box.keys.map((key) {
      final value = _box.get(key);
      final lastSeenAt = value?['lastSeenAt'] as int? ?? 0;
      return MapEntry(key, lastSeenAt);
    }).toList()..sort((a, b) => a.value.compareTo(b.value));

    final excess = entries.length - _cap;
    final keysToRemove = entries.take(excess).map((e) => e.key);
    await _box.deleteAll(keysToRemove);
  }
}
