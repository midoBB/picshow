import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// All three managers are configured to effectively never evict on their own:
// MediaCacheBudget is the single authority on what gets dropped, and it
// evicts by total bytes (FIFO) rather than by object count or age. A manager
// silently dropping entries underneath the ledger would make the accounting
// drift and, worse, quietly shrink what's available offline.
//
// `maxNrOfCacheObjects` has no "unlimited" value, so it's set far above any
// realistic library size. `stalePeriod` still applies as a final backstop for
// entries the ledger has lost track of (see MediaCacheBudget.reconcile).
const _effectivelyUnlimitedObjects = 1000000;
const _stalePeriod = Duration(days: 365);

// Note: `stalePeriod` governs only the managers' own background cleanup. Each
// entry additionally carries a `validTill` taken straight from the response's
// `Cache-Control: max-age` — 12 seconds for thumbnails, 3 days for media — and
// `CacheManager.getSingleFile` re-downloads (and, offline, *throws*) once that
// passes, however many bytes are already on disk. Anything that must work
// offline therefore has to consult the cache itself rather than rely on
// getSingleFile; see `resolveMediaSource` in k_gallery, and `getFileStream`,
// which CachedNetworkImage uses and which emits the stale file before trying
// to refresh it.
class ThumbCacheManager {
  static const key = 'picshowThumbCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: _stalePeriod,
      maxNrOfCacheObjects: _effectivelyUnlimitedObjects,
    ),
  );
}

class FullImageCacheManager {
  static const key = 'picshowFullImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: _stalePeriod,
      maxNrOfCacheObjects: _effectivelyUnlimitedObjects,
    ),
  );
}

class VideoCacheManager {
  static const key = 'picshowVideoCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: _stalePeriod,
      maxNrOfCacheObjects: _effectivelyUnlimitedObjects,
    ),
  );
}
