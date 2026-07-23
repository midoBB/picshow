import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// What [resolveMediaSource] decided to hand to the player.
class ResolvedMediaSource {
  const ResolvedMediaSource(this.source, {required this.isLocal});

  /// The path or URL to open.
  final String source;

  /// Whether [source] is a local file, i.e. playable with no network at all.
  final bool isLocal;
}

/// Resolves [url] to a local cache file via [cacheManager] (downloading it if
/// not already cached) so a replayed video plays from disk instead of
/// re-streaming. Falls back to the raw network URL when there is no cache
/// manager, the URL isn't remote, or nothing is cached and the download fails.
///
/// Cache *presence* wins over cache *freshness*, deliberately.
/// `CacheManager.getSingleFile` re-downloads as soon as the entry's
/// `validTill` — derived from the server's `Cache-Control: max-age` — has
/// passed, and throws when that download fails instead of falling back to the
/// bytes it already has. With any finite max-age that makes every fully
/// downloaded video unplayable offline the moment it ages out, which is
/// exactly the case caching is meant to serve. Media addressed by a
/// content-derived key doesn't change under that key, so a stale hit is still
/// the right bytes.
Future<ResolvedMediaSource> resolveMediaSource(
  BaseCacheManager? cacheManager,
  String url, {
  String? cacheKey,
}) async {
  if (cacheManager == null || !url.startsWith('http')) {
    return ResolvedMediaSource(url, isLocal: !url.startsWith('http'));
  }

  // Falling back to a URL-derived key keeps the previous behavior for callers
  // that don't set one, but a host app whose cache survives a change of server
  // address must supply [GalleryItem.cacheKey] — the hash of a URL it no
  // longer uses would miss every cached file.
  final key = cacheKey ?? 'video-${url.hashCode}';

  try {
    final cached = await cacheManager.getFileFromCache(key);
    if (cached != null && cached.file.existsSync()) {
      return ResolvedMediaSource(cached.file.path, isLocal: true);
    }
  } catch (_) {
    // Unreadable cache entry; fall through to a fresh download.
  }

  try {
    final file = await cacheManager.getSingleFile(url, key: key);
    return ResolvedMediaSource(file.path, isLocal: true);
  } catch (_) {
    // Fall back to network streaming (offline first play, disk full, 404).
    return ResolvedMediaSource(url, isLocal: false);
  }
}
