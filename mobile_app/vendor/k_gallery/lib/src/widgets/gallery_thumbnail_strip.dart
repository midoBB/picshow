import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:k_gallery/k_gallery.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../bloc/gallery_bloc.dart';
import '../utils/image_source.dart';

/// Internal widget for displaying the scrollable thumbnail strip.
class GalleryThumbnailStrip extends StatefulWidget {
  /// Whether haptic feedback is enabled.
  final bool enableHapticFeedback;

  /// Controller for the main page view to sync scrolling.
  final PageController pageController;

  /// Custom loading widget for thumbnails.
  final Widget? thumbProgressWidget;

  /// Notifier for the currently active media_kit player (video/audio).
  final ValueNotifier<Player?> activePlayerNotifier;

  /// Notifier for the currently active YouTube player (youtube items).
  final ValueNotifier<YoutubePlayerController?> activeYoutubeNotifier;

  /// Theme used to style the seekbar colors.
  final GalleryTheme theme;

  /// Cache manager forwarded to each thumbnail's [CachedNetworkImage].
  final BaseCacheManager? cacheManager;

  const GalleryThumbnailStrip({
    super.key,
    required this.enableHapticFeedback,
    required this.pageController,
    required this.activePlayerNotifier,
    required this.activeYoutubeNotifier,
    required this.theme,
    this.thumbProgressWidget,
    this.cacheManager,
  });

  @override
  State<GalleryThumbnailStrip> createState() => _GalleryThumbnailStripState();
}

class _GalleryThumbnailStripState extends State<GalleryThumbnailStrip> {
  final ScrollController _scrollController = ScrollController();
  int _lastHapticIndex = -1;
  bool _isUserDragging = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final state = context.read<GalleryBloc>().state;
        _scrollToThumbnail(state.currentIndex, animate: false);
      }
    });
  }

  _AdaptiveDimensions _getDimensions(BuildContext context) {
    final bool isTablet = MediaQuery.of(context).size.shortestSide >= 600;

    if (isTablet) {
      return const _AdaptiveDimensions(
        height: 110,
        unselectedSize: 60,
        selectedSize: 86,
        spacing: 4,
      );
    }
    return const _AdaptiveDimensions(
      height: 90,
      unselectedSize: 48,
      selectedSize: 68,
      spacing: 6,
    );
  }

  void _scrollToThumbnail(int index, {bool animate = true}) {
    if (!_scrollController.hasClients || _isUserDragging) return;

    final dimensions = _getDimensions(context);
    final double itemFullWidth = dimensions.unselectedSize + dimensions.spacing;

    double position = index * itemFullWidth;

    position = position.clamp(0.0, _scrollController.position.maxScrollExtent);

    if ((_scrollController.offset - position).abs() < 1.0) return;

    if (animate) {
      _scrollController.animateTo(
        position,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
    } else {
      _scrollController.jumpTo(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<GalleryBloc, GalleryState>(
      listenWhen: (previous, current) =>
          previous.currentIndex != current.currentIndex,
      listener: (context, state) {
        _scrollToThumbnail(state.currentIndex);
      },
      builder: (context, state) {
        final screenWidth = MediaQuery.of(context).size.width;
        final dimensions = _getDimensions(context);
        final bottomPadding = MediaQuery.of(context).padding.bottom;

        final currentItem =
            state.items.isNotEmpty ? state.items[state.currentIndex] : null;
        final bool hasSeekbar = currentItem != null &&
            (currentItem.type == GalleryItemType.video ||
                currentItem.type == GalleryItemType.audio ||
                currentItem.type == GalleryItemType.youtube);

        return ValueListenableBuilder<Player?>(
          valueListenable: widget.activePlayerNotifier,
          builder: (context, player, _) {
            return ValueListenableBuilder<YoutubePlayerController?>(
              valueListenable: widget.activeYoutubeNotifier,
              builder: (context, ytController, _) {
                final bool showSeekbar =
                    hasSeekbar && (player != null || ytController != null);
                const double seekbarHeight = 40.0;
                final double totalHeight = dimensions.height +
                    bottomPadding +
                    (showSeekbar ? seekbarHeight : 0.0);

                return AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  bottom: (state.isUIVisible && !state.isSliding)
                      ? 0
                      : -(totalHeight + 20),
                  left: 0,
                  right: 0,
                  height: totalHeight,
                  child: ClipRect(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                        ),
                        child: Column(
                          children: [
                            if (showSeekbar)
                              SizedBox(
                                height: seekbarHeight,
                                child: ytController != null
                                    ? _buildYoutubeSeekbar(
                                        ytController, widget.theme)
                                    : _buildSeekbar(player!, widget.theme),
                              ),
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(bottom: bottomPadding),
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (notification) {
                                if (notification is ScrollStartNotification &&
                                    notification.dragDetails != null) {
                                  _isUserDragging = true;
                                } else if (notification
                                    is ScrollEndNotification) {
                                  _isUserDragging = false;
                                  _scrollToThumbnail(state.currentIndex,
                                      animate: true);
                                } else if (notification
                                        is ScrollUpdateNotification &&
                                    _isUserDragging) {
                                  final double itemFullWidth =
                                      dimensions.unselectedSize +
                                          dimensions.spacing;
                                  int centerIndex =
                                      (notification.metrics.pixels /
                                              itemFullWidth)
                                          .round();
                                  if (centerIndex >= 0 &&
                                      centerIndex < state.items.length) {
                                    if (_lastHapticIndex != centerIndex) {
                                      _lastHapticIndex = centerIndex;
                                      if (widget.enableHapticFeedback) {
                                        HapticFeedback.selectionClick();
                                      }
                                      widget.pageController
                                          .jumpToPage(centerIndex);
                                      context.read<GalleryBloc>().add(
                                            GalleryIndexChanged(centerIndex),
                                          );
                                    }
                                  }
                                }
                                return false;
                              },
                              child: ListView.builder(
                                controller: _scrollController,
                                scrollDirection: Axis.horizontal,
                                padding: EdgeInsets.symmetric(
                                  horizontal: (screenWidth -
                                          dimensions.unselectedSize -
                                          dimensions.spacing) /
                                      2,
                                ),
                                itemCount: state.items.length,
                                itemBuilder: (context, index) {
                                  final isSelected =
                                      index == state.currentIndex;
                                  return GestureDetector(
                                    onTap: () {
                                      if (widget.enableHapticFeedback) {
                                        HapticFeedback.lightImpact();
                                      }
                                      widget.pageController.animateToPage(
                                        index,
                                        duration:
                                            const Duration(milliseconds: 300),
                                        curve: Curves.easeInOut,
                                      );
                                      context.read<GalleryBloc>().add(
                                            GalleryIndexChanged(index),
                                          );
                                    },
                                    child: SizedBox(
                                      width: dimensions.unselectedSize +
                                          dimensions.spacing,
                                      child: Center(
                                        child: AnimatedContainer(
                                          duration:
                                              const Duration(milliseconds: 250),
                                          curve: Curves.easeOutBack,
                                          width: isSelected
                                              ? dimensions.selectedSize
                                              : dimensions.unselectedSize,
                                          height: isSelected
                                              ? dimensions.selectedSize
                                              : dimensions.unselectedSize,
                                          decoration: BoxDecoration(
                                            border: isSelected
                                                ? Border.all(
                                                    color: Colors.white,
                                                    width: 3)
                                                : null,
                                            borderRadius: BorderRadius.circular(
                                              dimensions.unselectedSize * 0.2,
                                            ),
                                          ),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(
                                              dimensions.unselectedSize * 0.15,
                                            ),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                _buildThumbnail(
                                                  state.items[index],
                                                  dimensions,
                                                ),
                                                if (state.items[index].type !=
                                                    GalleryItemType.image)
                                                  Positioned(
                                                    left: 4,
                                                    bottom: 4,
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              1),
                                                      decoration: BoxDecoration(
                                                        color: Colors.black
                                                            .withValues(
                                                                alpha: 0.5),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: const Icon(
                                                        Icons.play_arrow,
                                                        size: 10,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSeekbar(Player player, GalleryTheme theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          StreamBuilder<Duration>(
            initialData: player.state.position,
            stream: player.stream.position,
            builder: (context, snapshot) {
              return Text(
                _formatDuration(snapshot.data ?? Duration.zero),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              initialData: player.state.position,
              stream: player.stream.position,
              builder: (context, posSnapshot) {
                return StreamBuilder<Duration>(
                  initialData: player.state.duration,
                  stream: player.stream.duration,
                  builder: (context, durSnapshot) {
                    final position = posSnapshot.data ?? Duration.zero;
                    final duration = durSnapshot.data ?? Duration.zero;
                    double max = duration.inMilliseconds.toDouble();
                    double val = position.inMilliseconds.toDouble();
                    if (max <= 0) max = 1.0;
                    if (val < 0) val = 0.0;
                    if (val > max) val = max;
                    return Slider(
                      value: val,
                      max: max,
                      activeColor: theme.seekbarActiveColor,
                      inactiveColor: theme.seekbarInactiveColor,
                      onChanged: (value) =>
                          player.seek(Duration(milliseconds: value.toInt())),
                    );
                  },
                );
              },
            ),
          ),
          StreamBuilder<Duration>(
            initialData: player.state.duration,
            stream: player.stream.duration,
            builder: (context, snapshot) {
              return Text(
                _formatDuration(snapshot.data ?? Duration.zero),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildYoutubeSeekbar(
    YoutubePlayerController controller,
    GalleryTheme theme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final position = controller.value.position;
          final duration = controller.metadata.duration;
          double max = duration.inMilliseconds.toDouble();
          double val = position.inMilliseconds.toDouble();
          if (max <= 0) max = 1.0;
          if (val < 0) val = 0.0;
          if (val > max) val = max;
          return Row(
            children: [
              Text(
                _formatDuration(position),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: val,
                  max: max,
                  activeColor: theme.seekbarActiveColor,
                  inactiveColor: theme.seekbarInactiveColor,
                  onChanged: (value) => controller.seekTo(
                    Duration(milliseconds: value.toInt()),
                  ),
                ),
              ),
              Text(
                _formatDuration(duration),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          );
        },
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  Widget _buildThumbnail(GalleryItem item, _AdaptiveDimensions dimensions) {
    final String? thumbUrl = item.thumbnailUrl;
    final String url = item.url;

    // Use thumbnailUrl if available, otherwise use url ONLY if it's an image.
    // For video/audio, we shouldn't use the media URL as an image source.
    // For YouTube items without a custom thumbnail, derive one from the
    // video ID so the strip looks populated even when the caller didn't
    // supply thumbnailUrl.
    String? effectiveImageUrl = (thumbUrl != null && thumbUrl.isNotEmpty)
        ? thumbUrl
        : (item.type == GalleryItemType.image && url.isNotEmpty ? url : null);
    if (effectiveImageUrl == null && item.type == GalleryItemType.youtube) {
      final id = YoutubePlayer.convertUrlToId(url);
      if (id != null) {
        effectiveImageUrl = YoutubePlayer.getThumbnail(videoId: id);
      }
    }

    if (effectiveImageUrl == null) {
      return Container(
        color: Colors.white.withValues(alpha: 0.1),
        alignment: Alignment.center,
        child: _buildTypeIcon(item.type, dimensions.unselectedSize * 0.4),
      );
    }

    return galleryImage(
      source: effectiveImageUrl,
      fit: BoxFit.cover,
      // Cap the decoded bitmap so a large image isn't decoded at full
      // resolution just to fill the strip — cacheWidth covers the base64
      // path, memCacheWidth the network path. The thumbnail size is fixed
      // and small, so this stays independent of the caller's full-screen
      // memCacheWidth.
      cacheWidth: 320,
      memCacheWidth: 320,
      cacheManager: widget.cacheManager,
      placeholder: (context, _) =>
          widget.thumbProgressWidget ?? const SizedBox.shrink(),
      errorWidget: (context, _, __) => Container(
        color: Colors.white.withValues(alpha: 0.1),
        alignment: Alignment.center,
        child: _buildTypeIcon(item.type, dimensions.unselectedSize * 0.4),
      ),
    );
  }

  Widget _buildTypeIcon(GalleryItemType type, double size) {
    IconData iconData;
    switch (type) {
      case GalleryItemType.video:
        iconData = Icons.videocam;
      case GalleryItemType.audio:
        iconData = Icons.audiotrack;
      case GalleryItemType.image:
        iconData = Icons.image;
      case GalleryItemType.youtube:
        iconData = Icons.smart_display;
    }
    return Icon(
      iconData,
      color: Colors.white54,
      size: size,
    );
  }
}

class _AdaptiveDimensions {
  final double height;
  final double unselectedSize;
  final double selectedSize;
  final double spacing;

  const _AdaptiveDimensions({
    required this.height,
    required this.unselectedSize,
    required this.selectedSize,
    required this.spacing,
  });
}
