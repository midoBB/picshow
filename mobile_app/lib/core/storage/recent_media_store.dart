import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

/// Persists metadata for media the user has already fetched, so the gallery
/// can keep showing a "recently viewed" subset while offline. This is a
/// metadata-only cache: the actual thumbnail/image/video bytes continue to
/// live in the existing flutter_cache_manager instances (ThumbCacheManager,
/// FullImageCacheManager, VideoCacheManager) and are not duplicated here.
class RecentMediaStore {
  RecentMediaStore._(this._box);

  static const boxName = 'recent_media_v1';
  static const _cap = 1000;

  final Box<Map> _box;

  static Future<RecentMediaStore> open() async {
    await Hive.initFlutter();
    final box = await Hive.openBox<Map>(boxName);
    return RecentMediaStore._(box);
  }

  /// Backs the store with a throwaway on-disk Hive box outside the normal
  /// app data directory, so tests don't depend on path_provider platform
  /// channels.
  @visibleForTesting
  static Future<RecentMediaStore> openInMemoryForTesting() async {
    final dir = Directory.systemTemp.createTempSync('recent_media_store_test');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map>(
      'test_${DateTime.now().microsecondsSinceEpoch}',
    );
    return RecentMediaStore._(box);
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

  /// Same as [queryOffline], additionally filtered down to entries whose
  /// thumbnail bytes are confirmed present in [ThumbCacheManager]'s disk
  /// cache (a local lookup, no network call), so offline tiles never attempt
  /// a doomed network fetch for metadata-only entries.
  Future<List<MediaFile>> queryOfflineFilterCached(GalleryQuery query) async {
    final candidates = queryOffline(query);
    final results = await Future.wait(
      candidates.map((file) async {
        final cached = await ThumbCacheManager.instance.getFileFromCache(
          'thumb-${file.id}',
        );
        return cached != null ? file : null;
      }),
    );
    return [for (final file in results) if (file != null) file];
  }

  Future<void> remove(String id) => _box.delete(id);

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
