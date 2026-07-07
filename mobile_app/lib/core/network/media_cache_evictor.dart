import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

/// Best-effort cleanup of disk-cached media for files that have disappeared
/// server-side (deleted via the web frontend, another client, or a future
/// mobile delete feature the app doesn't have yet). Not required for
/// correctness — cache entries also expire via each manager's `stalePeriod`
/// regardless — this just avoids holding onto now-orphaned bytes until then.
///
/// When a mobile delete action is added, prefer calling [evict] directly at
/// that call site instead of relying on [PagedFilesNotifier]'s id-diffing,
/// since it can fire synchronously and precisely for the deleted id.
class MediaCacheEvictor {
  const MediaCacheEvictor(this._api);

  final ApiClient _api;

  Future<void> evict(String id) async {
    final imageUrl = _api.imageUrl(id);
    final videoUrl = _api.videoUrl(id);

    await Future.wait([
      ThumbCacheManager.instance.removeFile('thumb-$id'),
      FullImageCacheManager.instance.removeFile(imageUrl),
      VideoCacheManager.instance.removeFile('video-${videoUrl.hashCode}'),
    ].map((future) => future.catchError((_) {})));
  }
}
