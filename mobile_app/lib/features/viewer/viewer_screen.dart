import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';
import 'package:picshow_mobile/features/viewer/widgets/image_page.dart';
import 'package:picshow_mobile/features/viewer/widgets/video_page.dart';
import 'package:picshow_mobile/features/viewer/widgets/viewer_toolbar.dart';

const _slideshowDelay = Duration(seconds: 5);
const _preloadAhead = 2;
const _preloadBehind = 1;

class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.query, required this.initialIndex});

  final GalleryQuery query;
  final int initialIndex;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  late int _currentIndex = widget.initialIndex;
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  bool _chromeVisible = true;
  int _swipesSinceShown = 0;
  bool _slideshowPlaying = false;
  Timer? _slideshowTimer;
  int? _lastPrecachedIndex;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _slideshowTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    setState(() {
      _chromeVisible = !_chromeVisible;
      _swipesSinceShown = 0;
    });
  }

  void _onPageChanged(int index, List<MediaFile> files) {
    setState(() {
      _currentIndex = index;
      if (_chromeVisible) {
        _swipesSinceShown++;
        if (_swipesSinceShown >= 3) {
          _chromeVisible = false;
        }
      }
    });
    if (index >= files.length - 3) {
      ref.read(pagedFilesProvider(widget.query).notifier).loadMore();
    }
    if (_slideshowPlaying) {
      _armSlideshowTimer(files);
    }
  }

  void _toggleSlideshow(List<MediaFile> files) {
    setState(() => _slideshowPlaying = !_slideshowPlaying);
    if (_slideshowPlaying) {
      _armSlideshowTimer(files);
    } else {
      _slideshowTimer?.cancel();
    }
  }

  void _armSlideshowTimer(List<MediaFile> files) {
    _slideshowTimer?.cancel();
    if (_currentIndex < 0 || _currentIndex >= files.length) return;
    final current = files[_currentIndex];
    if (current.mediaType == MediaType.video) {
      // Advance is driven by VideoPage.onCompleted instead of a timer.
      return;
    }
    _slideshowTimer = Timer(_slideshowDelay, () => _advanceSlideshow(files));
  }

  void _advanceSlideshow(List<MediaFile> files) {
    if (!_slideshowPlaying || !mounted) return;
    final hasMore =
        ref.read(pagedFilesProvider(widget.query)).valueOrNull?.hasMore ?? false;
    if (_currentIndex >= files.length - 1 && !hasMore) {
      setState(() => _slideshowPlaying = false);
      return;
    }
    _pageController.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  void _precacheAround(int index, List<MediaFile> files, ApiClient api) {
    if (_lastPrecachedIndex == index) return;
    _lastPrecachedIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (var offset = -_preloadBehind; offset <= _preloadAhead; offset++) {
        if (offset == 0) continue;
        final i = index + offset;
        if (i < 0 || i >= files.length) continue;
        final file = files[i];
        if (file.mediaType != MediaType.image) continue;
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(
              api.imageUrl(file.id),
              cacheManager: FullImageCacheManager.instance,
            ),
            context,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(pagedFilesProvider(widget.query));
    final api = ref.watch(apiClientProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => const Center(
          child: Text('Failed to load media', style: TextStyle(color: Colors.white)),
        ),
        data: (state) {
          final files = state.files;
          if (files.isEmpty) return const SizedBox.shrink();
          final index = _currentIndex.clamp(0, files.length - 1);
          final currentFile = files[index];
          _precacheAround(index, files, api);

          return Stack(
            children: [
              PhotoViewGallery.builder(
                pageController: _pageController,
                itemCount: files.length,
                onPageChanged: (i) => _onPageChanged(i, files),
                builder: (context, i) {
                  final file = files[i];
                  if (file.mediaType == MediaType.video) {
                    return PhotoViewGalleryPageOptions.customChild(
                      child: GestureDetector(
                        onTap: _toggleChrome,
                        child: VideoPage(
                          videoUrl: api.videoUrl(file.id),
                          isActive: i == _currentIndex,
                          onCompleted: (_slideshowPlaying && i == _currentIndex)
                              ? () => _advanceSlideshow(files)
                              : null,
                        ),
                      ),
                      minScale: PhotoViewComputedScale.contained,
                      maxScale: PhotoViewComputedScale.contained,
                      initialScale: PhotoViewComputedScale.contained,
                      heroAttributes: PhotoViewHeroAttributes(tag: 'media-${file.id}'),
                    );
                  }
                  return imagePageOptions(
                    file: file,
                    imageUrl: api.imageUrl(file.id),
                    thumbnailUrl: api.thumbnailUrl(file.id),
                    onTapUp: (_, _, _) => _toggleChrome(),
                  );
                },
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                top: _chromeVisible ? 0 : -120,
                left: 0,
                right: 0,
                child: ViewerToolbar(
                  file: currentFile,
                  onToggleFavorite: () => ref
                      .read(pagedFilesProvider(widget.query).notifier)
                      .toggleFavorite(currentFile.id),
                  onClose: () => Navigator.of(context).maybePop(),
                  isSlideshowPlaying: _slideshowPlaying,
                  onToggleSlideshow: () => _toggleSlideshow(files),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
