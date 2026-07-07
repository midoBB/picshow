import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

PhotoViewGalleryPageOptions imagePageOptions({
  required MediaFile file,
  required String imageUrl,
  required String thumbnailUrl,
  required void Function(BuildContext, TapUpDetails, PhotoViewControllerValue) onTapUp,
}) {
  return PhotoViewGalleryPageOptions(
    imageProvider: CachedNetworkImageProvider(
      imageUrl,
      cacheManager: FullImageCacheManager.instance,
    ),
    minScale: PhotoViewComputedScale.contained,
    maxScale: PhotoViewComputedScale.covered * 4,
    heroAttributes: PhotoViewHeroAttributes(tag: 'media-${file.id}'),
    filterQuality: FilterQuality.medium,
    onTapUp: onTapUp,
    errorBuilder: (context, error, stackTrace) => Center(
      child: Image(
        image: CachedNetworkImageProvider(
          thumbnailUrl,
          cacheKey: 'thumb-${file.id}',
          cacheManager: ThumbCacheManager.instance,
        ),
        fit: BoxFit.contain,
      ),
    ),
  );
}
