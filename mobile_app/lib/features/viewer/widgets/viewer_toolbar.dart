import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:picshow_mobile/core/models/media_file.dart';

class ViewerToolbar extends StatelessWidget {
  const ViewerToolbar({
    super.key,
    required this.file,
    required this.onToggleFavorite,
    required this.onClose,
    required this.isSlideshowPlaying,
    required this.onToggleSlideshow,
  });

  final MediaFile file;
  final VoidCallback onToggleFavorite;
  final VoidCallback onClose;
  final bool isSlideshowPlaying;
  final VoidCallback onToggleSlideshow;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top,
        left: 8,
        right: 8,
        bottom: 8,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: onClose,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  file.filename,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  DateFormat.yMMMd().add_jm().format(file.createdAt.toLocal()),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              isSlideshowPlaying ? Icons.pause_circle_outline : Icons.slideshow,
              color: Colors.white,
            ),
            onPressed: onToggleSlideshow,
          ),
          IconButton(
            icon: Icon(
              file.isFavorite ? Icons.favorite : Icons.favorite_border,
              color: file.isFavorite ? Colors.redAccent : Colors.white,
            ),
            onPressed: onToggleFavorite,
          ),
        ],
      ),
    );
  }
}
