import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:k_gallery/k_gallery.dart';

/// A small (160×160) four-quadrant PNG embedded inline as a base64 data URI.
/// Demonstrates that kGallery renders base64 images in both the full-screen
/// viewer and the thumbnail strip — no network request is made for this item.
const String kBase64SampleImage =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAADMElEQVR4nOzVwQnAIBQFQYXff81RUkQCOyDj1YOPnbXWPmeTRef+/3O/OyBjzh3CD95BfqICMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMK0CMO0TAAD//2Anhf4QtqobAAAAAElFTkSuQmCC';

class DemoGalleryScreen extends StatefulWidget {
  static const id = 'k_gallery_demo';
  static const path = '/$id';

  const DemoGalleryScreen({super.key});

  @override
  State<DemoGalleryScreen> createState() => _DemoGalleryScreenState();
}

class _DemoGalleryScreenState extends State<DemoGalleryScreen> {
  final ScrollController _scrollController = ScrollController();

  /// A custom cache manager shared between this grid and the gallery. Passing
  /// the same instance to both the grid thumbnails and [KGallery.show] means an
  /// image fetched for the grid is reused full-screen (and vice-versa), and the
  /// host app — not the package — owns the disk-cache policy (key, stale
  /// period, max object count). [CacheManager], [Config], and [BaseCacheManager]
  /// are re-exported by `package:k_gallery`.
  final BaseCacheManager _cacheManager = CacheManager(
    Config(
      'kGalleryDemoCache',
      stalePeriod: const Duration(days: 7),
      maxNrOfCacheObjects: 200,
    ),
  );

  int _getCrossAxisCount(BuildContext context) {
    final shortestSide = MediaQuery.of(context).size.shortestSide;
    if (shortestSide >= 800) return 6;
    if (shortestSide >= 600) return 5;
    return 3;
  }

  void _scrollToIndex(int index, int crossAxisCount) {
    if (!_scrollController.hasClients) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final availableWidth = screenWidth - 8 - 8;
    final itemWidth = availableWidth / crossAxisCount;
    final rowHeight = itemWidth + 4;

    final row = index ~/ crossAxisCount;
    double offset = row * rowHeight;

    // Ensure we don't scroll beyond limits
    if (offset > _scrollController.position.maxScrollExtent) {
      offset = _scrollController.position.maxScrollExtent;
    }

    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Grid thumbnail for an image-bearing item. Branches on the source the same
  /// way kGallery does internally: an inline base64 data URI is decoded and
  /// drawn with [Image.memory]; anything else is fetched via
  /// [CachedNetworkImage]. Mirrors how a host app builds its own grid.
  Widget _buildGridThumbnail(GalleryItem item) {
    final source = item.thumbnailUrl ?? item.url;

    Widget typeIconFallback() => Container(
      color: Colors.grey[900],
      alignment: Alignment.center,
      child: Icon(
        item.type == GalleryItemType.video
            ? Icons.videocam
            : item.type == GalleryItemType.audio
            ? Icons.audiotrack
            : Icons.image_not_supported,
        size: 32,
        color: Colors.white54,
      ),
    );

    if (source.contains(';base64,')) {
      try {
        return Image.memory(
          base64Decode(source.split(';base64,').last),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => typeIconFallback(),
        );
      } catch (_) {
        return typeIconFallback();
      }
    }

    return CachedNetworkImage(
      imageUrl: source,
      fit: BoxFit.cover,
      cacheManager: _cacheManager,
      placeholder: (context, url) => Container(
        color: Colors.grey[900],
        child: const Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (context, url, error) => typeIconFallback(),
    );
  }

  /// Opens the gallery via [KGallery.show], which presents it on a transparent
  /// (non-opaque) route so this grid stays visible through the background fade
  /// when the user swipes down to dismiss. The returned index scrolls the grid
  /// to the last-viewed item on close.
  Future<void> _openGallery(List<GalleryItem> contentList, int index) async {
    final result = await KGallery.show(
      context,
      contentList: contentList,
      initialIndex: index,
      onIndexChanged: (newIndex) =>
          _scrollToIndex(newIndex, _getCrossAxisCount(context)),
      actionMenuBuilder: _buildActionMenu,
      // Reuse the grid's cache so images already fetched for the thumbnails
      // load instantly full-screen.
      cacheManager: _cacheManager,
      // Cap the in-memory bitmap width for full-screen images to roughly the
      // display resolution, reducing memory pressure for very large sources.
      progressWidget: Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      ),
    );

    if (result != null && mounted) {
      _scrollToIndex(result, _getCrossAxisCount(context));
    }
  }

  Widget _buildActionMenu(
    BuildContext context,
    int currentIndex,
    List<GalleryItem> items,
  ) {
    if (items.isEmpty) return const SizedBox.shrink();
    final currentItem = items[currentIndex];
    return PopupMenuButton<String>(
      color: Colors.black,
      icon: const Icon(Icons.more_vert, color: Colors.white),
      onSelected: (value) {
        switch (value) {
          case 'download':
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Downloading: ${currentItem.title ?? "Image"}'),
              ),
            );
            break;
          case 'slideshow':
            break;
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'slideshow',
          child: Row(
            children: [
              Icon(Icons.slideshow, size: 20, color: Colors.white),
              SizedBox(width: 12),
              Text('Slideshow', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(
            children: [
              Icon(Icons.download, size: 20, color: Colors.white),
              SizedBox(width: 12),
              Text('Download Image', style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<GalleryItem> contentList = List.generate(100, (index) {
      if (index == 0) {
        return const GalleryItem(
          url:
              'https://videos.pexels.com/video-files/6896062/6896062-hd_720_1280_30fps.mp4',
          type: GalleryItemType.video,
          title: 'Forest Stream (Vertical)',
          description:
              'A beautiful vertical video of a forest stream to test gallery behavior.',
          thumbnailUrl:
              'https://images.pexels.com/videos/7098293/pexels-photo-7098293.jpeg?auto=compress&cs=tinysrgb&dpr=1&w=500',
        );
      }
      if (index == 1) {
        return const GalleryItem(
          url:
              'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
          type: GalleryItemType.video,
          title: 'Big Buck Bunny (Video)',
          description:
              'A large and lovable rabbit deals with three bullying rodents. This demonstrates the MediaKit integration.',
          thumbnailUrl:
              'https://i.vimeocdn.com/video/797382244-0106ae13e902e09d0f02d8f404fa80581f38d1b8b7846b3f8e87ef391ffb8c99-d?f=webp&region=us',
        );
      }
      if (index == 2) {
        return const GalleryItem(
          url: 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
          type: GalleryItemType.audio,
          title: 'SoundHelix Song 1 (Audio)',
          description:
              'A long audio track to demonstrate the audio player interface.',
          thumbnailUrl:
              'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=600&h=800&fit=crop',
        );
      }
      if (index == 3) {
        return const GalleryItem(
          url: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
          type: GalleryItemType.youtube,
          title: 'Big Buck Bunny (YouTube)',
          description:
              'Resolved via youtube_explode_dart and played by media_kit using the same controls as the rest of the gallery.',
        );
      }
      if (index == 4) {
        return const GalleryItem(
          url: kBase64SampleImage,
          type: GalleryItemType.image,
          title: 'Base64 Image (local)',
          description:
              'This image is passed as an inline base64 data URI — no network '
              'request is made. It renders in both the grid thumbnail and the '
              'full-screen viewer.',
        );
      }
      if (index == 5) {
        return const GalleryItem(
          url: 'https://www.youtube.com/watch?v=a3ICNMQW7Ok',
          type: GalleryItemType.youtube,
          title: 'YouTube (Fullscreen Controls)',
          description:
              'A second YouTube item. Enter fullscreen and confirm the '
              'controls auto-hide after 3 seconds and reappear on tap, '
              'matching the media_kit video controls.',
        );
      }

      String? title;
      String? description;

      if (index % 4 == 0) {
        title = 'Short Title ${index + 1}';
        description = 'This is a brief caption for image ${index + 1}.';
      } else if (index % 4 == 1) {
        title = null;
        description = null;
      } else if (index % 4 == 2) {
        title = 'Epic Description ${index + 1}';
        description =
            'This is an enormous description for photo number ${index + 1}. ' *
                8 +
            'It features a huge amount of text to demonstrate scrolling. ' * 8;
      } else {
        title = 'Gallery Item ${index + 1}';
        description =
            'A moderately sized description that spans two or three lines but definitely does not hit the maximum height bound. Ideal for normal photos.';
      }

      return GalleryItem(
        url:
            'https://loremflickr.com/600/800/nature,landscape?lock=${index + 3}',
        type: GalleryItemType.image,
        title: title,
        description: description,
      );
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Telegram Gallery Demo')),
      body: GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(4),
        itemCount: contentList.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _getCrossAxisCount(context),
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
        ),
        itemBuilder: (context, index) {
          final item = contentList[index];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openGallery(contentList, index),
            child: Hero(
              tag: item.url,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  (item.type != GalleryItemType.image &&
                          item.thumbnailUrl == null)
                      ? Container(
                          color: Colors.grey[900],
                          alignment: Alignment.center,
                          child: Icon(
                            item.type == GalleryItemType.video
                                ? Icons.videocam
                                : Icons.audiotrack,
                            size: 32,
                            color: Colors.white54,
                          ),
                        )
                      : _buildGridThumbnail(item),
                  if (item.type != GalleryItemType.image &&
                      item.thumbnailUrl != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}