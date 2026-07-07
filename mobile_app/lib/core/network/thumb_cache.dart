import 'package:flutter_cache_manager/flutter_cache_manager.dart';

// Note: the web frontend caps thumbnail HTTP `Cache-Control` at 12 seconds,
// but that TTL is irrelevant here — flutter_cache_manager never keys its
// cache-hit decisions off response headers, only its own `stalePeriod`
// below, which is already far more generous than the web's cache.
class ThumbCacheManager {
  static const key = 'picshowThumbCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 2000,
    ),
  );
}

// 500 objects at ~2-5MB per full-res photo is a bounded ~1-2.5GB worst
// case, acceptable for a mobile app's dedicated storage. The old cap of 50
// was defeating the nearby-slide preload in gallery_screen.dart by evicting
// slide N-3 before a linear scroll session reached it.
class FullImageCacheManager {
  static const key = 'picshowFullImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 500,
    ),
  );
}

// flutter_cache_manager's Config has no byte-size cap, only object count,
// so this is sized conservatively given videos run tens to hundreds of MB
// each (vs a few MB for photos).
class VideoCacheManager {
  static const key = 'picshowVideoCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 60,
    ),
  );
}
