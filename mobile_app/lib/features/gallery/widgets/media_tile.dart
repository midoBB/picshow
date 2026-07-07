import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/widgets/async_states.dart';

class MediaTile extends StatelessWidget {
  const MediaTile({
    super.key,
    required this.file,
    required this.thumbnailUrl,
    required this.heroTag,
    required this.onTap,
  });

  final MediaFile file;
  final String thumbnailUrl;
  final String heroTag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Hero(
        tag: heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              AspectRatio(
                aspectRatio: file.thumbAspect,
                child: CachedNetworkImage(
                  imageUrl: thumbnailUrl,
                  cacheKey: 'thumb-${file.id}',
                  cacheManager: ThumbCacheManager.instance,
                  fit: BoxFit.cover,
                  memCacheWidth: 400,
                  placeholder: (context, url) =>
                      SkeletonTile(aspectRatio: file.thumbAspect),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
              if (file.mediaType == MediaType.video)
                const Positioned.fill(
                  child: Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white70,
                      size: 40,
                    ),
                  ),
                ),
              if (file.isFavorite)
                const Positioned(
                  top: 6,
                  right: 6,
                  child: Icon(
                    Icons.favorite,
                    color: Colors.redAccent,
                    size: 18,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
