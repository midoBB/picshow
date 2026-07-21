import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

/// Which of the three disk caches a ledger row belongs to. Needed because
/// eviction has to call `removeFile` on the *same* manager that wrote the
/// bytes, and because thumbnails get a reserved floor (see [enforce]).
enum CacheBucket { thumb, image, video }

extension on CacheBucket {
  CacheManager get manager {
    switch (this) {
      case CacheBucket.thumb:
        return ThumbCacheManager.instance;
      case CacheBucket.image:
        return FullImageCacheManager.instance;
      case CacheBucket.video:
        return VideoCacheManager.instance;
    }
  }
}

/// The cache key each bucket uses for [id]. These are the same keys the rest
/// of the app builds at its `getSingleFile`/`CachedNetworkImage` call sites,
/// and keeping them in one place is what lets the ledger stay authoritative
/// without ever reverse-mapping an on-disk filename back to a cache key.
String cacheKeyFor(CacheBucket bucket, String id, ApiClient api) {
  switch (bucket) {
    case CacheBucket.thumb:
      return 'thumb-$id';
    case CacheBucket.image:
      return api.imageUrl(id);
    case CacheBucket.video:
      return 'video-${api.videoUrl(id).hashCode}';
  }
}

/// A byte-size budget across all three media disk caches, with first-in
/// first-out eviction.
///
/// `flutter_cache_manager`'s own `Config` can only cap the *number* of cached
/// objects, which says nothing useful about disk use when a single entry
/// ranges from a 30 KB thumbnail to a 300 MB video. This class keeps a
/// separate ledger of `{cache key -> bytes, addedAt}` and is the sole
/// authority on when something gets dropped; the managers themselves are
/// configured to effectively never evict on their own.
class MediaCacheBudget {
  MediaCacheBudget._(this._box, this._budgetBytes);

  static const boxName = 'media_cache_ledger_v1';

  static const defaultBudgetBytes = 2 * 1024 * 1024 * 1024; // 2 GB

  /// Selectable budgets, in bytes, offered by the settings screen.
  static const budgetOptions = <int>[
    1 * 1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
    5 * 1024 * 1024 * 1024,
    10 * 1024 * 1024 * 1024,
    20 * 1024 * 1024 * 1024,
  ];

  /// Thumbnails are never evicted while they collectively fit under this
  /// much of the budget. A thumbnail is ~1% the size of its full image but
  /// is what makes a file *visible* in the offline grid, so letting a run of
  /// full-resolution downloads evict thumbnails would trade a whole screen
  /// of browsable tiles for one more openable photo.
  static int thumbFloorBytes(int budgetBytes) =>
      min((budgetBytes * 0.1).round(), 200 * 1024 * 1024);

  final Box<Map> _box;
  int _budgetBytes;

  static Future<MediaCacheBudget> open({required int budgetBytes}) async {
    await Hive.initFlutter();
    final box = await Hive.openBox<Map>(boxName);
    return MediaCacheBudget._(box, budgetBytes);
  }

  /// Backs the ledger with a throwaway on-disk Hive box outside the normal
  /// app data directory, so tests don't depend on path_provider platform
  /// channels. Mirrors [RecentMediaStore.openInMemoryForTesting].
  @visibleForTesting
  static Future<MediaCacheBudget> openInMemoryForTesting({
    required int budgetBytes,
  }) async {
    final dir = Directory.systemTemp.createTempSync('media_cache_budget_test');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map>(
      'test_${DateTime.now().microsecondsSinceEpoch}',
    );
    return MediaCacheBudget._(box, budgetBytes);
  }

  int get budgetBytes => _budgetBytes;

  int get totalBytes {
    var total = 0;
    for (final row in _box.values) {
      total += (row['bytes'] as int?) ?? 0;
    }
    return total;
  }

  int bytesIn(CacheBucket bucket) {
    var total = 0;
    for (final row in _box.values) {
      if (row['bucket'] == bucket.name) total += (row['bytes'] as int?) ?? 0;
    }
    return total;
  }

  /// True once the cache is close enough to full that the background filler
  /// should stop rather than start evicting its own earlier downloads.
  bool get isFull => totalBytes >= (_budgetBytes * 0.95);

  bool knows(String key) => _box.containsKey(key);

  /// Changes the budget and immediately brings the cache back under it.
  Future<void> setBudgetBytes(int bytes) async {
    _budgetBytes = bytes;
    await enforce();
  }

  /// Records that [key] now occupies [bytes] on disk, then evicts as needed.
  /// Re-recording an existing key updates its size but keeps its original
  /// `addedAt`, so refreshing bytes never moves an entry to the back of the
  /// FIFO queue.
  Future<void> record(CacheBucket bucket, String key, int bytes) async {
    final existing = _box.get(key);
    await _box.put(key, {
      'bucket': bucket.name,
      'bytes': bytes,
      'addedAt':
          existing?['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
    });
    await enforce();
  }

  /// Looks up [key]'s actual on-disk size and records it. No-op when the file
  /// isn't in the cache (e.g. the download failed).
  Future<void> recordFromCache(CacheBucket bucket, String key) async {
    final bytes = await _sizeOnDisk(bucket, key);
    if (bytes == null) return;
    await record(bucket, key, bytes);
  }

  /// Drops [key] from the ledger without touching the disk cache. For use by
  /// callers that already removed the file themselves.
  Future<void> forget(String key) => _box.delete(key);

  Future<void> clearAll() async {
    await Future.wait(
      [
        ThumbCacheManager.instance.emptyCache(),
        FullImageCacheManager.instance.emptyCache(),
        VideoCacheManager.instance.emptyCache(),
      ].map((future) => future.catchError((_) {})),
    );
    await _box.clear();
  }

  /// Evicts oldest-first until the total fits the budget.
  ///
  /// Thumbnail rows are passed over while thumbnails collectively sit under
  /// [thumbFloorBytes]; if *only* protected thumbnails remain, eviction stops
  /// rather than looping forever, leaving the cache slightly over budget.
  Future<void> enforce() async {
    if (totalBytes <= _budgetBytes) return;

    final rows = _box.keys.map((key) {
      final row = _box.get(key)!;
      return (
        key: key as String,
        bucket: _bucketOf(row),
        bytes: (row['bytes'] as int?) ?? 0,
        addedAt: (row['addedAt'] as int?) ?? 0,
      );
    }).toList()..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    final floor = thumbFloorBytes(_budgetBytes);
    var total = totalBytes;
    var thumbTotal = bytesIn(CacheBucket.thumb);

    for (final row in rows) {
      if (total <= _budgetBytes) break;
      if (row.bucket == CacheBucket.thumb && thumbTotal <= floor) continue;

      try {
        await row.bucket.manager.removeFile(row.key);
      } catch (_) {
        // Already gone from disk; the ledger row still needs clearing.
      }
      await _box.delete(row.key);
      total -= row.bytes;
      if (row.bucket == CacheBucket.thumb) thumbTotal -= row.bytes;
    }
  }

  /// Re-syncs the ledger against what is actually on disk for [known] files.
  ///
  /// Necessary because not every write goes through code we control — the
  /// grid's `CachedNetworkImage` tiles write thumbnails straight into
  /// `ThumbCacheManager`. Rather than hook that, this walks the known ids,
  /// checks each of the three cache keys, and adds/updates/drops rows to
  /// match. Existing `addedAt` values are preserved so FIFO order survives.
  Future<void> reconcile(Iterable<MediaFile> known, ApiClient api) async {
    final seen = <String>{};

    for (final file in known) {
      final buckets = file.mediaType == MediaType.video
          ? const [CacheBucket.thumb, CacheBucket.video]
          : const [CacheBucket.thumb, CacheBucket.image];

      for (final bucket in buckets) {
        final key = cacheKeyFor(bucket, file.id, api);
        seen.add(key);
        final bytes = await _sizeOnDisk(bucket, key);
        if (bytes == null) {
          await _box.delete(key);
        } else {
          final existing = _box.get(key);
          await _box.put(key, {
            'bucket': bucket.name,
            'bytes': bytes,
            'addedAt': existing?['addedAt'] as int? ??
                DateTime.now().millisecondsSinceEpoch,
          });
        }
      }
    }

    // Rows for files no longer in the known set (deleted server-side, or
    // aged out of RecentMediaStore's own cap) are dropped from the ledger so
    // they stop counting against the budget. Their bytes are left to the
    // managers' own stale-period cleanup, since without a MediaFile we can't
    // tell which manager owns the key.
    final orphans = _box.keys.cast<String>().where((k) => !seen.contains(k));
    await _box.deleteAll(orphans.toList());

    await enforce();
  }

  CacheBucket _bucketOf(Map row) {
    return CacheBucket.values.firstWhere(
      (b) => b.name == row['bucket'],
      orElse: () => CacheBucket.image,
    );
  }

  Future<int?> _sizeOnDisk(CacheBucket bucket, String key) async {
    try {
      final info = await bucket.manager.getFileFromCache(key);
      if (info == null) return null;
      if (!info.file.existsSync()) return null;
      return await info.file.length();
    } catch (_) {
      return null;
    }
  }
}
