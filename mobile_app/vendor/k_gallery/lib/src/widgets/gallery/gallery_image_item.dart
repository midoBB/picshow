import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../models/gallery_item.dart';
import '../../utils/image_source.dart';
import 'zoomable_image.dart';

/// Renders a single image gallery item (network URL or base64 data URI via
/// [galleryImage]), optionally wrapped in [ZoomableImage] for pinch +
/// double-tap zoom.
///
/// This widget is purely visual — it does not handle page swiping or
/// dismiss gestures. Those are owned by parent widgets.
class GalleryImageItem extends StatelessWidget {
  final GalleryItem item;
  final ValueNotifier<double> scaleNotifier;
  final bool enableZoom;
  final Widget? progressWidget;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  /// Optional cache manager forwarded to [CachedNetworkImage] for network
  /// image sources.
  final BaseCacheManager? cacheManager;

  /// Optional in-memory decode width cap forwarded to [CachedNetworkImage].
  final int? memCacheWidth;

  const GalleryImageItem({
    super.key,
    required this.item,
    required this.scaleNotifier,
    required this.enableZoom,
    this.progressWidget,
    this.onZoomIn,
    this.onZoomOut,
    this.cacheManager,
    this.memCacheWidth,
  });

  @override
  Widget build(BuildContext context) {
    final Widget image = galleryImage(
      source: item.url,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
      cacheManager: cacheManager,
      memCacheWidth: memCacheWidth,
      placeholder: (context, _) =>
          progressWidget ??
          const Center(child: CircularProgressIndicator(color: Colors.white)),
      errorWidget: (context, _, __) => const Center(
        child: Icon(Icons.broken_image, color: Colors.white54, size: 64),
      ),
    );

    if (!enableZoom) {
      return image;
    }

    return ZoomableImage(
      scaleNotifier: scaleNotifier,
      onZoomIn: onZoomIn,
      onZoomOut: onZoomOut,
      child: image,
    );
  }
}
