import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

/// Whether [file]'s full-resolution image or video bytes (not just its
/// thumbnail) are already present in the appropriate disk cache — i.e.
/// whether it can actually be opened in the full-screen viewer without a
/// network fetch.
Future<bool> isFullBlobCached(MediaFile file, ApiClient api) async {
  if (file.mediaType == MediaType.video) {
    final videoUrl = api.videoUrl(file.id);
    final cached = await VideoCacheManager.instance.getFileFromCache(
      'video-${videoUrl.hashCode}',
    );
    return cached != null;
  }
  final cached = await FullImageCacheManager.instance.getFileFromCache(
    api.imageUrl(file.id),
  );
  return cached != null;
}
