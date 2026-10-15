import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// What [resolveMediaSource] decided to hand to the player.
class ResolvedMediaSource {
  const ResolvedMediaSource(
    this.source, {
    required this.isLocal,
    this.cacheInBackground,
  });

  /// The path or URL to open.
  final String source;

  /// Whether [source] is a local file, i.e. playable with no network at all.
  final bool isLocal;

  /// Set when [source] is a network URL that is worth caching: downloads the
  /// file into the cache without blocking playback, never throws. The caller
  /// decides *when* to run it — ideally once playback has started, so the
  /// download doesn't compete with the first bytes the player needs.
  final Future<void> Function()? cacheInBackground;
}

/// Resolves [url] to a local cache file via [cacheManager] when one is already
/// cached, so a replayed video plays from disk instead of re-streaming.
///
/// On a cache miss the network URL is returned *immediately* so the player
/// can start progressively with range requests, like a browser `<video>`.
/// Blocking here until the whole file was downloaded made first play wait for
/// 100% of the video. The download still happens, off the critical path, via
/// [ResolvedMediaSource.cacheInBackground], so the next play is local.
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

  return ResolvedMediaSource(
    url,
    isLocal: false,
    cacheInBackground: () async {
      try {
        await cacheManager.getSingleFile(url, key: key);
      } catch (_) {
        // Offline, disk full, 404: playback is already streaming; a missed
        // cache fill only means the next play streams again.
      }
    },
  );
}
