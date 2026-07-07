import 'package:flutter/material.dart';

/// Wraps a child widget (typically an image) with pinch + double-tap zoom.
///
/// Built on Flutter's [InteractiveViewer]. Exposes the current scale via
/// [scaleNotifier] so parent widgets can react (e.g. disable a parent
/// [PageView] while zoomed, or hide overlay UI on pinch-in).
///
/// When NOT zoomed ([scaleNotifier] ≤ 1.0), [InteractiveViewer] has
/// `panEnabled: false` so single-finger drags fall through to the parent
/// [DismissibleDragArea] (vertical dismiss) and [PageView] (horizontal
/// navigation) untouched.
///
/// ## Why `panEnabled` is never toggled during a live gesture
///
/// When a property on [InteractiveViewer] changes, Flutter calls
/// `didUpdateWidget`, which causes [InteractiveViewer] to recreate its
/// gesture recognisers. Doing that while a pinch is in progress resets the
/// recogniser's live pointer tracking — it forgets where the fingers started
/// — so the very next scale-update delta is computed from scratch, producing
/// a sudden jump in the transform.
///
/// To avoid this, [_interacting] is set to `true` for the duration of any
/// gesture or animation. [_onTransformChanged] skips the [setState] call
/// while [_interacting] is true, deferring the [panEnabled] flip to
/// [InteractiveViewer.onInteractionEnd] (or animation completion), when no
/// recogniser state is live.
class ZoomableImage extends StatefulWidget {
  final Widget child;
  final ValueNotifier<double> scaleNotifier;
  final double minScale;
  final double maxScale;
  final double doubleTapScale;
  final Duration animationDuration;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  const ZoomableImage({
    super.key,
    required this.child,
    required this.scaleNotifier,
    this.minScale = 0.9,
    this.maxScale = 8.0,
    this.doubleTapScale = 2.5,
    this.animationDuration = const Duration(milliseconds: 250),
    this.onZoomIn,
    this.onZoomOut,
  });

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> with SingleTickerProviderStateMixin {
  late final TransformationController _controller;
  late final AnimationController _animController;
  Animation<Matrix4>? _animation;

  Offset _doubleTapPosition = Offset.zero;
  bool _wasZoomed = false;

  /// Whether [panEnabled] is currently true on the live [InteractiveViewer].
  bool _panEnabled = false;

  /// True while a gesture or animation is active.
  ///
  /// While true, [_onTransformChanged] skips [setState] so that
  /// [InteractiveViewer] is never rebuilt mid-gesture.
  bool _interacting = false;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _controller.addListener(_onTransformChanged);
    _animController = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    )..addListener(_onAnimate);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransformChanged);
    _animController
      ..removeListener(_onAnimate)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  // ── Transform tracking ───────────────────────────────────────────────────

  void _onAnimate() {
    if (_animation != null) {
      _controller.value = _animation!.value;
    }
  }

  void _onTransformChanged() {
    final scale = _controller.value.getMaxScaleOnAxis();

    // Always keep the parent-visible scale current.
    widget.scaleNotifier.value = scale;

    // Fire zoom callbacks exactly once per threshold crossing.
    final isZoomed = scale > 1.01;
    if (isZoomed != _wasZoomed) {
      _wasZoomed = isZoomed;
      isZoomed ? widget.onZoomIn?.call() : widget.onZoomOut?.call();
    }

    // NEVER rebuild InteractiveViewer while a gesture or animation is live.
    // Defer the panEnabled flip to _applyPanEnabled(), called on interaction
    // end / animation completion.
    if (!_interacting) _applyPanEnabled(isZoomed);
  }

  /// Applies a [panEnabled] change via [setState] only if the value differs.
  void _applyPanEnabled(bool isZoomed) {
    if (isZoomed != _panEnabled) {
      setState(() => _panEnabled = isZoomed);
    }
  }

  // ── Double-tap zoom ──────────────────────────────────────────────────────

  void _handleDoubleTap() {
    final currentScale = _controller.value.getMaxScaleOnAxis();
    final isZoomed = currentScale > 1.01;

    final Matrix4 end;
    if (isZoomed) {
      end = Matrix4.identity();
    } else {
      final s = widget.doubleTapScale;
      // Zoom centred on the tap point:
      //   T(fx*(1-s), fy*(1-s)) · S(s)  keeps the tap position fixed.
      end = Matrix4.identity()
        ..translateByDouble(
          -_doubleTapPosition.dx * (s - 1),
          -_doubleTapPosition.dy * (s - 1),
          0,
          1,
        )
        ..scaleByDouble(s, s, 1, 1);
    }

    _interacting = true; // Block panEnabled rebuilds during animation.
    _animation = Matrix4Tween(begin: _controller.value, end: end).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOutCubic),
    );
    _animController
      ..reset()
      ..forward().whenComplete(() {
        _interacting = false;
        _applyPanEnabled(_controller.value.getMaxScaleOnAxis() > 1.01);
      });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: widget.minScale,
        maxScale: widget.maxScale,
        clipBehavior: Clip.none,
        panEnabled: _panEnabled,
        onInteractionStart: (_) {
          _interacting = true;
          // Stop any running double-tap animation so it doesn't fight the
          // gesture over _controller.value.
          if (_animController.isAnimating) {
            _animController.stop();
            _animation = null;
          }
        },
        onInteractionEnd: (_) {
          // Gesture is over — safe to apply the deferred panEnabled change.
          _interacting = false;
          _applyPanEnabled(_controller.value.getMaxScaleOnAxis() > 1.01);
        },
        child: widget.child,
      ),
    );
  }
}
