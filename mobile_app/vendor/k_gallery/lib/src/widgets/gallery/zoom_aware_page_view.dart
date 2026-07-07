import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A [PageView] whose horizontal swipe is disabled while [swipeLocked] is
/// `true` — i.e. while the current item is zoomed in OR a pinch (multi-touch)
/// is in progress. Standing the page-swipe recognizer down on multi-touch lets
/// [InteractiveViewer]'s scale recognizer win the gesture arena, so pinch-to-
/// zoom can start from scale 1.0.
class ZoomAwarePageView extends StatelessWidget {
  final PageController controller;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final ValueListenable<bool> swipeLocked;
  final ValueChanged<int>? onPageChanged;

  const ZoomAwarePageView({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.swipeLocked,
    this.onPageChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: swipeLocked,
      builder: (context, locked, _) {
        return PageView.builder(
          controller: controller,
          itemCount: itemCount,
          onPageChanged: onPageChanged,
          physics: locked
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
