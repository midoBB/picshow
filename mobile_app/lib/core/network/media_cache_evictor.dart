import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';

/// Removes a single file's disk-cached bytes and its byte-ledger rows.
///
/// Intended for call sites that know a specific id is gone — an explicit
/// delete action, most obviously. It is deliberately *not* driven by diffing
/// list responses: the file list is paged and can be randomly ordered, so a
/// page's contents are never evidence about ids outside that page.
///
/// Reclaiming space in general is [MediaCacheBudget]'s job, not this class's.
class MediaCacheEvictor {
  const MediaCacheEvictor(this._budget);

  final MediaCacheBudget _budget;

  Future<void> evict(String id) async {
    final keys = {
      for (final bucket in CacheBucket.values) bucket: cacheKeyFor(bucket, id),
    };

    await Future.wait(
      [
        ThumbCacheManager.instance.removeFile(keys[CacheBucket.thumb]!),
        FullImageCacheManager.instance.removeFile(keys[CacheBucket.image]!),
        VideoCacheManager.instance.removeFile(keys[CacheBucket.video]!),
      ].map((future) => future.catchError((_) {})),
    );

    for (final bucket in CacheBucket.values) {
      await _budget.forget(bucket, id);
    }
  }
}
