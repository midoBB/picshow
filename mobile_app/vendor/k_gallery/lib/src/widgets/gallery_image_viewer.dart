import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../bloc/gallery_bloc.dart';
import '../models/gallery_item.dart';
import '../models/gallery_theme.dart';
import 'gallery/deferred_init.dart';
import 'gallery/dismissible_drag_area.dart';
import 'gallery/gallery_image_item.dart';
import 'gallery/zoom_aware_page_view.dart';
import 'media/gallery_audio_item.dart';
import 'media/gallery_video_item.dart';
import 'media/gallery_youtube_item.dart';

/// Thin orchestrator that hosts the swipable gallery page view.
///
/// Owns:
///   - The current item's zoom scale (so it can disable page swipe + drag
///     dismiss).
///   - The background fade opacity during drag-to-dismiss.
///   - A top-level [Listener] that detects gestures while the image is zoomed
///     in and [InteractiveViewer] has claimed the pan. Flutter routes all
///     MOVE/UP events for a pointer to the same widgets that received the DOWN
///     event, so this [Listener] reliably tracks the full gesture trajectory
///     regardless of which descendant won the gesture arena.
class GalleryImageViewer extends StatefulWidget {
  final PageController pageController;
  final Widget? progressWidget;
  final bool enableZoom;
  final bool enableSwipeToDismiss;
  final ValueNotifier<Player?> activePlayerNotifier;
  final ValueNotifier<YoutubePlayerController?> activeYoutubeNotifier;
  final void Function(int currentIndex)? onClose;
  final String? noInternetMessage;
  final GalleryTheme? theme;

  /// Cache manager forwarded to network image sources (full-screen images and
  /// audio artwork).
  final BaseCacheManager? cacheManager;

  /// In-memory decode width cap forwarded to full-screen network images.
  final int? memCacheWidth;

  const GalleryImageViewer({
    super.key,
    required this.pageController,
    this.progressWidget,
    required this.enableZoom,
    required this.enableSwipeToDismiss,
    required this.activePlayerNotifier,
    required this.activeYoutubeNotifier,
    this.onClose,
    this.noInternetMessage,
    this.theme,
    this.cacheManager,
    this.memCacheWidth,
  });

  @override
  State<GalleryImageViewer> createState() => _GalleryImageViewerState();
}

class _GalleryImageViewerState extends State<GalleryImageViewer> with SingleTickerProviderStateMixin {
  static const Duration _mediaInitDelay = Duration(milliseconds: 150);

  /// Scale of the currently visible item (1.0 = not zoomed).
  final ValueNotifier<double> _currentScale = ValueNotifier<double>(1.0);

  /// True while page-swipe and swipe-to-dismiss must stand down so the pinch
  /// (scale) gesture can win the arena: either the image is zoomed in OR a
  /// second finger is down (a pinch in progress).
  ///
  /// Without the multi-touch term, the page-swipe + dismiss drag recognizers
  /// claim a two-finger pinch before [InteractiveViewer]'s scale recognizer
  /// settles, and the deadlock means pinch-to-zoom never starts from 1.0.
  final ValueNotifier<bool> _swipeLocked = ValueNotifier<bool>(false);

  /// Background opacity for drag-to-dismiss visual feedback (1.0 = solid black).
  final ValueNotifier<double> _bgOpacity = ValueNotifier<double>(1.0);

  /// Translation offset applied to the page content during a zoomed dismiss drag
  /// or fly-away animation.
  final ValueNotifier<Offset> _zoomedDismissOffset = ValueNotifier<Offset>(Offset.zero);

  /// Drives fly-away and snap-back animations when dismissing while zoomed.
  late final AnimationController _zoomedDismissController;

  /// Held so the animation listener can be removed before a new one is added.
  VoidCallback? _zoomedDismissListener;

  /// Screen height cached each build for use in animation calculations.
  double _screenHeight = 800.0;

  // ── Raw pointer tracking ─────────────────────────────────────────────────
  int _activePointers = 0;
  VelocityTracker? _velocityTracker;

  @override
  void initState() {
    super.initState();
    _zoomedDismissController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _currentScale.addListener(_updateSwipeLock);
  }

  @override
  void dispose() {
    _stopZoomedDismissAnim();
    _zoomedDismissController.dispose();
    _zoomedDismissOffset.dispose();
    _currentScale.removeListener(_updateSwipeLock);
    _currentScale.dispose();
    _swipeLocked.dispose();
    _bgOpacity.dispose();
    super.dispose();
  }

  /// Recomputes [_swipeLocked] from the current zoom + active-pointer count.
  /// Cheap and idempotent — only writes when the value actually flips.
  void _updateSwipeLock() {
    final locked = _currentScale.value > 1.01 || _activePointers >= 2;
    if (_swipeLocked.value != locked) _swipeLocked.value = locked;
  }

  // ── Pointer event handlers ───────────────────────────────────────────────

  void _onPointerDown(PointerDownEvent event) {
    _activePointers++;
    if (_activePointers == 1) {
      _velocityTracker = VelocityTracker.withKind(event.kind);
      _velocityTracker!.addPosition(event.timeStamp, event.localPosition);
    } else {
      // Second finger (pinch) arrived → discard the single-finger tracker so a
      // pinch never registers as a flick.
      _velocityTracker = null;
    }
    _updateSwipeLock();
  }

  void _onPointerMove(PointerMoveEvent event) {
    // Only track velocity for a single-finger gesture. We intentionally do NOT
    // translate anything here: while zoomed, InteractiveViewer fully owns the
    // pan so it stays buttery smooth. Dismiss/navigate is decided purely from
    // the release velocity in _onZoomedPointerUp.
    if (_activePointers == 1) {
      _velocityTracker?.addPosition(event.timeStamp, event.localPosition);
    }
  }

  void _onZoomedPointerUp(BuildContext context, PointerUpEvent event) {
    final isLast = _activePointers == 1;
    _activePointers = (_activePointers - 1).clamp(0, 20);
    _updateSwipeLock();

    if (!isLast || _currentScale.value <= 1.01 || !widget.enableSwipeToDismiss) {
      if (_activePointers == 0) _velocityTracker = null;
      return;
    }

    final tracker = _velocityTracker;
    _velocityTracker = null;
    if (tracker == null) return;

    final estimate = tracker.getVelocityEstimate();
    if (estimate == null) return;

    final v = estimate.pixelsPerSecond;
    final absX = v.dx.abs();
    final absY = v.dy.abs();

    // Deliberate fast downward flick → dismiss (animated fly-away). The high
    // threshold keeps ordinary panning (which releases more slowly) from
    // dismissing by accident.
    if (v.dy > 700 && absY > absX * 1.5) {
      _triggerZoomedFlyAway(context);
      return;
    }

    // Deliberate fast horizontal flick → navigate prev/next.
    if (absX > 700 && absX > absY * 1.5) {
      _navigateWhileZoomed(context, next: v.dx < 0);
    }
  }

  // ── Zoomed dismiss animation helpers ────────────────────────────────────

  void _stopZoomedDismissAnim() {
    if (_zoomedDismissListener != null) {
      _zoomedDismissController.removeListener(_zoomedDismissListener!);
      _zoomedDismissListener = null;
    }
    _zoomedDismissController.stop();
  }

  /// Animates the page content off the bottom of the screen — matches the
  /// unzoomed [DismissibleDragArea] fly-away — then pops the route.
  void _triggerZoomedFlyAway(BuildContext context) {
    _stopZoomedDismissAnim();

    final startOffset = _zoomedDismissOffset.value;
    final endDy = _screenHeight + 200.0;

    final anim = Tween<Offset>(
      begin: startOffset,
      end: Offset(0, endDy),
    ).animate(CurvedAnimation(parent: _zoomedDismissController, curve: Curves.easeOut));

    _zoomedDismissListener = () {
      _zoomedDismissOffset.value = anim.value;
      final progress = (anim.value.dy / endDy).clamp(0.0, 1.0);
      _bgOpacity.value = (1.0 - progress).clamp(0.0, 1.0);
    };

    _zoomedDismissController
      ..addListener(_zoomedDismissListener!)
      ..duration = const Duration(milliseconds: 280)
      ..reset()
      ..forward().whenComplete(() {
        _stopZoomedDismissAnim();
        _handleDismiss(context);
      });
  }

  void _navigateWhileZoomed(BuildContext context, {required bool next}) {
    final bloc = context.read<GalleryBloc>();
    final current = bloc.state.currentIndex;
    final count = bloc.state.items.length;
    final target = next ? current + 1 : current - 1;
    if (target >= 0 && target < count) {
      widget.pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // ── Gallery helpers ───────────────────────────────────────────────────────

  void _resetScale() => _currentScale.value = 1.0;

  void _handleDismiss(BuildContext context) {
    final currentIndex = context.read<GalleryBloc>().state.currentIndex;
    if (widget.onClose != null) {
      widget.onClose!(currentIndex);
    } else {
      Navigator.of(context).maybePop(currentIndex);
    }
  }

  void _handleDragProgress(BuildContext context, double progress) {
    _bgOpacity.value = (1.0 - progress).clamp(0.0, 1.0);
    final bloc = context.read<GalleryBloc>();
    final shouldBeSliding = progress > 0.01;
    if (bloc.state.isSliding != shouldBeSliding) {
      bloc.add(GallerySetSliding(shouldBeSliding));
    }
  }

  void _handleDragEnded(BuildContext context) {
    final bloc = context.read<GalleryBloc>();
    if (bloc.state.isSliding) {
      bloc.add(GallerySetSliding(false));
    }
  }

  void _toggleUI(BuildContext context) => context.read<GalleryBloc>().add(GalleryToggleUI());

  void _setUIVisible(BuildContext context, bool visible) {
    final bloc = context.read<GalleryBloc>();
    if (bloc.state.isUIVisible != visible) {
      bloc.add(GalleryToggleUI(isVisible: visible));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _screenHeight = MediaQuery.of(context).size.height;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (event) => _onZoomedPointerUp(context, event),
      onPointerCancel: (_) {
        _activePointers = (_activePointers - 1).clamp(0, 20);
        if (_activePointers == 0) _velocityTracker = null;
        _updateSwipeLock();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background that fades with drag-to-dismiss progress.
          ValueListenableBuilder<double>(
            valueListenable: _bgOpacity,
            builder: (context, opacity, _) {
              return ColoredBox(
                color: (widget.theme?.backgroundColor ?? Colors.black).withValues(alpha: opacity),
              );
            },
          ),
          BlocBuilder<GalleryBloc, GalleryState>(
            buildWhen: (prev, curr) => !identical(prev.items, curr.items) || prev.items.length != curr.items.length,
            builder: (context, state) {
              // Translate + subtle scale while the zoomed fly-away animation runs.
              return ValueListenableBuilder<Offset>(
                valueListenable: _zoomedDismissOffset,
                builder: (context, dismissOffset, child) {
                  final progress = (dismissOffset.dy / 400.0).clamp(0.0, 1.0);
                  final scale = 1.0 - progress * 0.12;
                  return Transform.scale(
                    scale: scale,
                    child: Transform.translate(
                      offset: dismissOffset,
                      child: child,
                    ),
                  );
                },
                child: ZoomAwarePageView(
                  controller: widget.pageController,
                  itemCount: state.items.length,
                  swipeLocked: _swipeLocked,
                  onPageChanged: (index) {
                    _resetScale();
                    context.read<GalleryBloc>().add(GalleryIndexChanged(index));
                  },
                  itemBuilder: (context, index) {
                    return _buildPage(context, state.items[index], index);
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPage(BuildContext context, GalleryItem item, int index) {
    final bloc = context.read<GalleryBloc>();

    Widget content;
    switch (item.type) {
      case GalleryItemType.image:
        content = GalleryImageItem(
          item: item,
          scaleNotifier: _currentScale,
          enableZoom: widget.enableZoom,
          progressWidget: widget.progressWidget,
          onZoomIn: () => _setUIVisible(context, false),
          onZoomOut: () => _setUIVisible(context, true),
          cacheManager: widget.cacheManager,
          memCacheWidth: widget.memCacheWidth,
        );
        content = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => _toggleUI(context),
          child: content,
        );
      case GalleryItemType.video:
        content = DeferredInit(
          delay: _mediaInitDelay,
          placeholder: widget.progressWidget,
          builder: (_) => GalleryVideoItem(
            item: item,
            index: index,
            activePlayerNotifier: widget.activePlayerNotifier,
            galleryBloc: bloc,
            noInternetMessage: widget.noInternetMessage,
            theme: widget.theme,
          ),
        );
      case GalleryItemType.audio:
        content = DeferredInit(
          delay: _mediaInitDelay,
          placeholder: widget.progressWidget,
          builder: (_) => GalleryAudioItem(
            item: item,
            index: index,
            activePlayerNotifier: widget.activePlayerNotifier,
            galleryBloc: bloc,
            noInternetMessage: widget.noInternetMessage,
            cacheManager: widget.cacheManager,
            memCacheWidth: widget.memCacheWidth,
          ),
        );
      case GalleryItemType.youtube:
        content = DeferredInit(
          delay: _mediaInitDelay,
          placeholder: widget.progressWidget,
          builder: (_) => GalleryYoutubeItem(
            item: item,
            index: index,
            activeYoutubeNotifier: widget.activeYoutubeNotifier,
            galleryBloc: bloc,
            noInternetMessage: widget.noInternetMessage,
            theme: widget.theme,
          ),
        );
    }

    final hero = Hero(tag: item.url, child: content);

    if (!widget.enableSwipeToDismiss) return hero;

    return DismissibleDragArea(
      enabled: true,
      dragLocked: _swipeLocked,
      onDismiss: () => _handleDismiss(context),
      onDragProgress: (progress) => _handleDragProgress(context, progress),
      onDragActiveChanged: (active) {
        if (!active) _handleDragEnded(context);
      },
      child: hero,
    );
  }
}
