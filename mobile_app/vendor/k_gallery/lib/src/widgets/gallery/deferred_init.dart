import 'dart:async';

import 'package:flutter/material.dart';

/// Delays building an expensive child widget until [delay] has elapsed.
///
/// Shows [placeholder] in the meantime. If this widget is disposed before
/// the timer fires, [builder] is never invoked — useful for skipping heavy
/// initialization (media players, network calls) when a page is scrolled
/// past quickly inside a [PageView].
class DeferredInit extends StatefulWidget {
  final Duration delay;
  final WidgetBuilder builder;
  final Widget? placeholder;

  const DeferredInit({
    super.key,
    required this.builder,
    this.delay = const Duration(milliseconds: 150),
    this.placeholder,
  });

  @override
  State<DeferredInit> createState() => _DeferredInitState();
}

class _DeferredInitState extends State<DeferredInit> {
  Timer? _timer;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.builder(context);
    return widget.placeholder ?? const SizedBox.shrink();
  }
}
