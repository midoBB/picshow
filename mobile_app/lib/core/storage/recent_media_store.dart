import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

/// Persists metadata for all known media so the gallery can show the full
/// library while offline. This is a metadata-only cache: the actual
/// thumbnail/image/video bytes continue to live in the existing
/// flutter_cache_manager instances (ThumbCacheManager,
/// FullImageCacheManager, VideoCacheManager) and are not duplicated here.
/// The store is unbounded; eviction is governed solely by the byte budget
/// ([MediaCacheBudget] 1–20 GB).
class RecentMediaStore {
  RecentMediaStore._(this._box, this._pendingFavoritesBox);

  static const boxName = 'recent_media_v1';
  static const _pendingFavoritesBoxName = 'pending_favorite_sync_v1';

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

  /// Same as [queryOffline], narrowed to files [budget] reports as fully
  /// available — thumbnail *and* full-resolution bytes both on disk.
  ///
  /// This is the guarantee the offline grid rests on: everything it lists can
  /// be opened. Filtering on the thumbnail alone (as this once did) put tiles
  /// on screen that dead-ended in a "Not available offline" toast when tapped.
  List<MediaFile> queryOfflineAvailable(
    GalleryQuery query,
    MediaCacheBudget budget,
  ) {
    return [
      for (final file in queryOffline(query))
        if (budget.isAvailableOffline(file)) file,
    ];
  }

  Future<void> remove(String id) => _box.delete(id);

  /// Updates the cached copy of [id]'s favorite flag in place, so
  /// [queryOffline]/[queryOfflineWithThumbs] reflect a toggle immediately
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

}
