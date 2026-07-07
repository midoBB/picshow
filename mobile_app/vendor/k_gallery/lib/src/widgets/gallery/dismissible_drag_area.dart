import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Wraps a child with vertical-drag-to-dismiss behavior (Apple Photos style).
///
/// While dragging the child translates with the finger and subtly shrinks.
/// The background fade is driven via [onDragProgress] (0.0 = opaque, 1.0 = transparent).
///
/// On release past [dismissThreshold] / [velocityThreshold], the child
/// flies off the bottom of the screen and THEN [onDismiss] is called so the
/// route pop happens after the animation (no abrupt cut).
///
/// On release below the threshold, the child snaps back with a spring curve.
///
/// While [dragLocked] is `true`, the vertical-drag recognizer is not attached,
/// so the dismiss gesture is suppressed. The parent locks during zoom (so a
/// zoomed-in image can be panned without dismissing) and during an active
/// pinch (so a two-finger gesture reaches [InteractiveViewer]'s scale
/// recognizer instead of being claimed as a dismiss drag).
class DismissibleDragArea extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismiss;
  final bool enabled;
  final ValueListenable<bool>? dragLocked;
  final double dismissThreshold;
  final double velocityThreshold;
  final double horizontalCancelRatio;
  final Duration snapBackDuration;
  final ValueChanged<double>? onDragProgress;
  final ValueChanged<bool>? onDragActiveChanged;

  const DismissibleDragArea({
    super.key,
    required this.child,
    required this.onDismiss,
    this.enabled = true,
    this.dragLocked,
    this.dismissThreshold = 150.0,
    this.velocityThreshold = 700.0,
    this.horizontalCancelRatio = 1.0,
    this.snapBackDuration = const Duration(milliseconds: 200),
    this.onDragProgress,
    this.onDragActiveChanged,
  });

  @override
  State<DismissibleDragArea> createState() => _DismissibleDragAreaState();
}

class _DismissibleDragAreaState extends State<DismissibleDragArea> with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  Animation<Offset>? _offsetAnimation;
  Offset _offset = Offset.zero;
  bool _dragging = false;
  double _screenHeight = 800.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this)..addListener(_onAnimate);
  }

  @override
  void dispose() {
    _animController
      ..removeListener(_onAnimate)
      ..dispose();
    super.dispose();
  }

  void _onAnimate() {
    if (_offsetAnimation != null) {
      setState(() {
        _offset = _offsetAnimation!.value;
      });
      _emitProgress();
    }
  }

  void _emitProgress() {
    final progress = (_offset.dy.abs() / 400.0).clamp(0.0, 1.0);
    widget.onDragProgress?.call(progress);
  }

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    _dragging = dragging;
    widget.onDragActiveChanged?.call(dragging);
  }

  void _handleStart(DragStartDetails details) {
    // When locked (zoomed / pinching) the drag callbacks are detached, so this
    // only fires for a genuine single-finger dismiss drag.
    if (!widget.enabled) return;
    _animController.stop();
    _setDragging(true);
  }

  void _handleUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() {
      _offset += details.delta;
    });
    _emitProgress();
  }

  void _handleEnd(DragEndDetails details) {
    if (!_dragging) return;

    final dy = _offset.dy;
    final velocity = details.velocity.pixelsPerSecond.dy;
    final shouldDismiss = widget.enabled && (dy > widget.dismissThreshold || velocity > widget.velocityThreshold);

    if (shouldDismiss) {
      // Keep _dragging=true so _handleDragEnded never fires (no opacity flash).
      // The fly-away animation handles everything; onDismiss fires at the end.
      _flyAway();
    } else {
      _setDragging(false);
      _snapBack();
    }
  }

  void _handleCancel() {
    if (!_dragging) return;
    _setDragging(false);
    _snapBack();
  }

  /// Animates the image off the bottom of the screen, then calls [onDismiss].
  void _flyAway() {
    final targetDy = _screenHeight + 200.0;
    _offsetAnimation = Tween<Offset>(
      begin: _offset,
      end: Offset(0, targetDy),
    ).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.duration = const Duration(milliseconds: 280);
    _animController
      ..reset()
      ..forward().whenComplete(widget.onDismiss);
  }

  void _snapBack() {
    _offsetAnimation = Tween<Offset>(
      begin: _offset,
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.duration = widget.snapBackDuration;
    _animController
      ..reset()
      ..forward();
  }

  /// Subtle scale-down while dragging downward — gives the Apple Photos feel.
  double get _dragScale {
    if (_offset.dy <= 0) return 1.0;
    final progress = (_offset.dy / 400.0).clamp(0.0, 1.0);
    return 1.0 - progress * 0.12;
  }

  @override
  Widget build(BuildContext context) {
    _screenHeight = MediaQuery.of(context).size.height;

    final content = Transform.scale(
      scale: _dragScale,
      child: Transform.translate(
        offset: _offset,
        child: widget.child,
      ),
    );

    final lockListenable = widget.dragLocked;
    if (lockListenable == null) {
      return _buildDetector(dragEnabled: widget.enabled, child: content);
    }

    // While locked (image zoomed in, or a pinch in progress), do NOT attach the
    // vertical-drag recognizer. If we did, it would win the gesture arena over
    // InteractiveViewer's scale/pan — blocking pinch-to-zoom from 1.0 and
    // vertical panning of a zoomed image.
    return ValueListenableBuilder<bool>(
      valueListenable: lockListenable,
      builder: (context, locked, child) {
        final dragEnabled = widget.enabled && !locked;
        return _buildDetector(dragEnabled: dragEnabled, child: child!);
      },
      child: content,
    );
  }

  Widget _buildDetector({required bool dragEnabled, required Widget child}) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: dragEnabled ? _handleStart : null,
      onVerticalDragUpdate: dragEnabled ? _handleUpdate : null,
      onVerticalDragEnd: dragEnabled ? _handleEnd : null,
      onVerticalDragCancel: dragEnabled ? _handleCancel : null,
      child: child,
    );
  }
}
