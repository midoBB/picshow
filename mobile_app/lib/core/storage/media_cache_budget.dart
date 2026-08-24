import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

/// Which of the three disk caches a ledger row belongs to. Needed because
/// eviction has to call `removeFile` on the *same* manager that wrote the
/// bytes, and because a file's thumbnail and its full blob are evicted
/// together (see [enforce]).
enum CacheBucket { thumb, image, video }

extension CacheBucketManager on CacheBucket {
  /// The disk cache that owns this bucket's bytes. Writers must go through
  /// it so the bytes land where [MediaCacheBudget] later looks for them.
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

/// The cache key each bucket uses for [id]: `thumb-`, `image-` or `video-`
/// followed by the media id.
///
/// Deliberately derived from nothing but the bucket and the id. An earlier
/// version keyed the image and video buckets by their full URL, which meant
/// every entry silently became unreachable the moment [ApiClient] failed over
/// between the LAN and the public address — the bytes stayed on disk under a
/// key nothing would ever ask for again. Cache identity must not depend on
/// which of several addresses happened to answer.
///
/// These are the same keys the rest of the app builds at its
/// `getSingleFile`/`CachedNetworkImage` call sites, and keeping them in one
/// place is what lets the ledger stay authoritative without ever
/// reverse-mapping an on-disk filename back to a cache key.
String cacheKeyFor(CacheBucket bucket, String id) => '${bucket.name}-$id';

/// The bucket holding [file]'s full-resolution bytes, as opposed to its
/// thumbnail.
CacheBucket fullBlobBucketFor(MediaFile file) =>
    file.mediaType == MediaType.video ? CacheBucket.video : CacheBucket.image;

/// A byte-size budget across all three media disk caches, and the single
/// authority on what is available offline.
///
/// `flutter_cache_manager`'s own `Config` can only cap the *number* of cached
/// objects, which says nothing useful about disk use when a single entry
/// ranges from a 30 KB thumbnail to a 300 MB video. This class keeps a
/// separate ledger of `{cache key -> id, bucket, bytes, addedAt, isFavorite}`
/// and decides when something gets dropped; the managers themselves are
/// configured to effectively never evict on their own.
///
/// Because the ledger records exactly what is on disk, it also answers
/// [isAvailableOffline] synchronously, which is what lets the gallery grid
/// show only files it can actually open while offline.
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

  /// Fires whenever a row is added, updated or dropped, so the offline grid
  /// can re-query as the background filler makes more files available.
  Listenable get changes => _box.listenable();

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

  bool knows(CacheBucket bucket, String id) =>
      _box.containsKey(cacheKeyFor(bucket, id));

  /// Whether [file] can be opened with no network at all: both its thumbnail
  /// (so it renders as a grid tile) and its full-resolution bytes (so the
  /// viewer has something to show) are on disk.
  ///
  /// Requiring *both* is the point. Grid browsing writes thumbnails far more
  /// often than full blobs, so a thumbnail alone means a tile the user can
  /// see but not open — which is exactly the "Not available offline" dead end
  /// this replaced.
  bool isAvailableOffline(MediaFile file) =>
      knows(CacheBucket.thumb, file.id) &&
      knows(fullBlobBucketFor(file), file.id);

  /// Changes the budget and immediately brings the cache back under it.
  Future<void> setBudgetBytes(int bytes) async {
    _budgetBytes = bytes;
    await enforce();
  }

  /// Records that [id]'s [bucket] bytes now occupy [bytes] on disk, then
  /// evicts as needed. Re-recording an existing entry updates its size but
  /// keeps its original `addedAt`, so refreshing bytes never moves an entry to
  /// the back of the FIFO queue.
  Future<void> record(
    CacheBucket bucket,
    String id,
    int bytes, {
    bool isFavorite = false,
  }) async {
    final key = cacheKeyFor(bucket, id);
    final existing = _box.get(key);
    await _box.put(key, {
      'id': id,
      'bucket': bucket.name,
      'bytes': bytes,
      'addedAt':
          existing?['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      'isFavorite': isFavorite,
    });
    await enforce();
  }

  /// Looks up [id]'s actual on-disk size in [bucket] and records it. No-op
  /// when the file isn't in the cache (e.g. the download failed).
  Future<void> recordFromCache(
    CacheBucket bucket,
    String id, {
    bool? isFavorite,
  }) async {
    final bytes = await _sizeOnDisk(bucket, cacheKeyFor(bucket, id));
    if (bytes == null) return;
    final existing = _box.get(cacheKeyFor(bucket, id));
    final fav = isFavorite ?? (existing?['isFavorite'] as bool? ?? false);
    await record(bucket, id, bytes, isFavorite: fav);
  }

  /// Updates the favorite flag for every ledger row belonging to [id] without
  /// moving `addedAt`, so protection is synchronous offline and online and
  /// survives restart.
  Future<void> updateFavorite(String id, bool isFavorite) async {
    final keys = _box.keys.cast<String>().where((key) {
      final row = _box.get(key);
      if (row == null) return false;
      return (row['id'] as String?) == id;
    }).toList();
    for (final key in keys) {
      final row = _box.get(key);
      if (row == null) continue;
      await _box.put(key, {
        'id': row['id'],
        'bucket': row['bucket'],
        'bytes': row['bytes'],
        'addedAt': row['addedAt'],
        'isFavorite': isFavorite,
      });
    }
  }

  /// One-time migration: for rows missing `isFavorite`, fill from
  /// [favoriteForId] where possible. Old rows without the field are treated as
  /// non-favorite.
  Future<int> backfillIsFavorite(
    bool? Function(String id) favoriteForId,
  ) async {
    var updated = 0;
    final keys = _box.keys.cast<String>().toList();
    for (final key in keys) {
      final row = _box.get(key);
      if (row == null) continue;
      if (row.containsKey('isFavorite')) continue;
      final id = row['id'] as String? ?? key;
      final fav = favoriteForId(id);
      if (fav == null) {
        await _box.put(key, {
          'id': row['id'],
          'bucket': row['bucket'],
          'bytes': row['bytes'],
          'addedAt': row['addedAt'],
          'isFavorite': false,
        });
        updated++;
      } else {
        await _box.put(key, {
          'id': row['id'],
          'bucket': row['bucket'],
          'bytes': row['bytes'],
          'addedAt': row['addedAt'],
          'isFavorite': fav,
        });
        updated++;
      }
    }
    return updated;
  }

  /// Drops [id]'s [bucket] row from the ledger without touching the disk
  /// cache. For use by callers that already removed the file themselves.
  Future<void> forget(CacheBucket bucket, String id) =>
      _box.delete(cacheKeyFor(bucket, id));

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

  /// Empties the full-image and video caches and their ledger rows, leaving
  /// thumbnails intact.
  ///
  /// Used by the one-time migration off URL-derived cache keys: those two
  /// buckets' on-disk entries are unreachable under the new key scheme, while
  /// thumbnails were always keyed `thumb-<id>` and carry over untouched.
  Future<void> clearFullBlobs() async {
    await Future.wait(
      [
        FullImageCacheManager.instance.emptyCache(),
        VideoCacheManager.instance.emptyCache(),
      ].map((future) => future.catchError((_) {})),
    );
    final stale = _box.keys.cast<String>().where((key) {
      final bucket = _bucketOf(_box.get(key)!);
      return bucket == CacheBucket.image || bucket == CacheBucket.video;
    }).toList();
    await _box.deleteAll(stale);
  }

  /// Evicts oldest-first until the total fits the budget, dropping each
  /// file's thumbnail *and* full blob together.
  ///
  /// Favorite protection: non-favorite files are evicted before favorites,
  /// FIFO by `addedAt` within each partition. Only when no non-favorites
  /// remain does the oldest favorite (FIFO) evict. Old rows without
  /// `isFavorite` are treated as non-favorite.
  ///
  /// Evicting per blob rather than per file is what produced the original
  /// bug: a run of full-resolution downloads would push out earlier full
  /// images while their cheap thumbnails survived, leaving a grid full of
  /// tiles that could no longer be opened. Whole-file eviction keeps the
  /// ledger's two halves in step, so [isAvailableOffline] never flips to a
  /// half-truth.
  Future<void> enforce() async {
    if (totalBytes <= _budgetBytes) return;

    final rows = _box.keys.map((key) {
      final row = _box.get(key)!;
      return (
        key: key as String,
        // Rows written before ids were stored fall back to their own key, so
        // they simply evict individually instead of grouping.
        id: (row['id'] as String?) ?? key,
        bucket: _bucketOf(row),
        bytes: (row['bytes'] as int?) ?? 0,
        addedAt: (row['addedAt'] as int?) ?? 0,
        isFavorite: (row['isFavorite'] as bool?) ?? false,
      );
    }).toList()..sort((a, b) => a.addedAt.compareTo(b.addedAt));

    // Insertion order over the sorted rows ranks each file by its oldest
    // blob, so the file whose bytes have been resident longest goes first.
    final byFile =
        <String, List<({String key, CacheBucket bucket, int bytes})>>{};
    final fileMeta = <String, ({int addedAt, bool isFavorite})>{};
    for (final row in rows) {
      byFile.putIfAbsent(row.id, () => []).add((
        key: row.key,
        bucket: row.bucket,
        bytes: row.bytes,
      ));
      final existing = fileMeta[row.id];
      if (existing == null) {
        fileMeta[row.id] = (addedAt: row.addedAt, isFavorite: row.isFavorite);
      } else {
        // Favorite if any row is favorite; addedAt stays the oldest.
        if (row.isFavorite) {
          fileMeta[row.id] = (addedAt: existing.addedAt, isFavorite: true);
        }
      }
    }

    // Partition: non-favorites FIFO then favorites FIFO.
    final orderedIds = <String>[];
    final nonFavs = fileMeta.entries.where((e) => !e.value.isFavorite).toList()
      ..sort((a, b) => a.value.addedAt.compareTo(b.value.addedAt));
    final favs = fileMeta.entries.where((e) => e.value.isFavorite).toList()
      ..sort((a, b) => a.value.addedAt.compareTo(b.value.addedAt));
    for (final e in nonFavs) {
      orderedIds.add(e.key);
    }
    for (final e in favs) {
      orderedIds.add(e.key);
    }

    var total = totalBytes;
    for (final id in orderedIds) {
      if (total <= _budgetBytes) break;
      final file = byFile[id]!;
      for (final row in file) {
        try {
          await row.bucket.manager.removeFile(row.key);
        } catch (_) {
          // Already gone from disk; the ledger row still needs clearing.
        }
        await _box.delete(row.key);
        total -= row.bytes;
      }
    }
  }

  /// Re-syncs the ledger rows for [files] against what is actually on disk,
  /// without touching rows for anything else.
  ///
  /// Necessary because not every write goes through code we control — the
  /// grid's `CachedNetworkImage` tiles write thumbnails straight into
  /// `ThumbCacheManager`. Rather than hook that, this walks the given ids,
  /// checks each one's two cache keys, and adds/updates/drops rows to match.
  /// Existing `addedAt` values are preserved so FIFO order survives.
  ///
  /// Returns the keys it examined, which [reconcile] uses to tell a row that
  /// is genuinely orphaned from one this pass simply didn't look at.
  Future<Set<String>> refresh(Iterable<MediaFile> files) async {
    final seen = <String>{};

    for (final file in files) {
      for (final bucket in [CacheBucket.thumb, fullBlobBucketFor(file)]) {
        final key = cacheKeyFor(bucket, file.id);
        seen.add(key);
        final bytes = await _sizeOnDisk(bucket, key);
        if (bytes == null) {
          await _box.delete(key);
        } else {
          final existing = _box.get(key);
          await _box.put(key, {
            'id': file.id,
            'bucket': bucket.name,
            'bytes': bytes,
            'addedAt':
                existing?['addedAt'] as int? ??
                DateTime.now().millisecondsSinceEpoch,
            'isFavorite': file.isFavorite,
          });
        }
      }
    }

    await enforce();
    return seen;
  }

  /// A full resync: [refresh]es every file in [known] and then drops any row
  /// left over.
  ///
  /// [known] must be the *complete* set of files the app knows about — pass a
  /// subset and every row outside it is discarded. Callers holding one page of
  /// a paged listing want [refresh] instead.
  Future<void> reconcile(Iterable<MediaFile> known) async {
    final seen = await refresh(known);

    // Rows for files no longer in the known set (deleted server-side) are
    // dropped from the ledger so they stop counting against the budget. Their
    // bytes are left to the managers' own stale-period cleanup, since without
    // a MediaFile we can't tell which manager owns the key.
    final orphans = _box.keys.cast<String>().where((k) => !seen.contains(k));
    await _box.deleteAll(orphans.toList());

    await enforce();
  }

  @visibleForTesting
  Box<Map> get debugBox => _box;

  @visibleForTesting
  bool? debugIsFavorite(CacheBucket bucket, String id) =>
      _box.get(cacheKeyFor(bucket, id))?['isFavorite'] as bool?;

  @visibleForTesting
  int? debugAddedAt(CacheBucket bucket, String id) =>
      _box.get(cacheKeyFor(bucket, id))?['addedAt'] as int?;

  @visibleForTesting
  Future<void> debugPutRaw(
    CacheBucket bucket,
    String id,
    Map<String, dynamic> row,
  ) => _box.put(cacheKeyFor(bucket, id), row);

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
