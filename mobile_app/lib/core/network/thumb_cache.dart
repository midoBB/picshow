import 'package:flutter_cache_manager/flutter_cache_manager.dart';

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

class FullImageCacheManager {
  static const key = 'picshowFullImageCache';

  static final CacheManager instance = CacheManager(
    Config(
      key,
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 50,
    ),
  );
}
