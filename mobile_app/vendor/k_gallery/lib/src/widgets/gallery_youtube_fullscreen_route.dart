import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../models/gallery_theme.dart';

/// Landscape fullscreen route that hosts an existing [YoutubePlayerController]
/// without recreating it — playback continues seamlessly.
///
/// Built as a [PageRoute] so the gallery can call `Navigator.of(context).push`
/// directly. Forces landscape on push and restores portrait on pop.
class GalleryYoutubeFullscreenRoute<T> extends PageRoute<T> {
  final YoutubePlayerController ytController;
  final GalleryTheme? theme;

  GalleryYoutubeFullscreenRoute({
    required this.ytController,
    this.theme,
  });

  @override
  bool get opaque => true;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => Colors.black;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  TickerFuture didPush() {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    return super.didPush();
  }

  @override
  bool didPop(T? result) {
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    return super.didPop(result);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _FullscreenContent(controller: ytController, theme: theme);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }
}

class _FullscreenContent extends StatefulWidget {
  final YoutubePlayerController controller;
  final GalleryTheme? theme;

  const _FullscreenContent({required this.controller, this.theme});

  @override
  State<_FullscreenContent> createState() => _FullscreenContentState();
}

class _FullscreenContentState extends State<_FullscreenContent> {
  /// Whether the play/pause button and bottom seekbar are shown. Mirrors the
  /// inline media controls: auto-hides after 3s of playback and toggles on a
  /// tap anywhere outside the controls.
  bool _controlsVisible = true;
  bool _previousIsPlaying = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_listener);
    _previousIsPlaying = widget.controller.value.isPlaying;
    if (_previousIsPlaying) _startHideTimer();
  }

  /// Restarts the auto-hide timer on each play transition and reveals the
  /// controls again whenever playback pauses.
  void _listener() {
    if (!mounted) return;
    final isPlaying = widget.controller.value.isPlaying;
    if (isPlaying == _previousIsPlaying) return;
    _previousIsPlaying = isPlaying;
    if (isPlaying) {
      if (_controlsVisible) _startHideTimer();
    } else {
      _cancelHideTimer();
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !widget.controller.value.isPlaying) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _cancelHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible && widget.controller.value.isPlaying) {
      _startHideTimer();
    } else {
      _cancelHideTimer();
    }
  }

  @override
  void dispose() {
    _cancelHideTimer();
    widget.controller.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final activeColor = widget.theme?.seekbarActiveColor ?? Colors.white;
    final inactiveColor = widget.theme?.seekbarInactiveColor ?? Colors.white30;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: YoutubePlayer(
                  controller: controller,
                  showVideoProgressIndicator: false,
                  bottomActions: const [],
                  topActions: const [],
                  bufferIndicator: const SizedBox.shrink(),
                ),
              ),
            ),
            // Tap anywhere outside the controls to toggle their visibility.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                child: const SizedBox.expand(),
              ),
            ),
            // Center play/pause + buffering indicator. The buffering spinner
            // always shows; the play/pause button respects [_controlsVisible].
            Center(
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  final v = controller.value;
                  if (!v.isReady || v.playerState == PlayerState.buffering) {
                    return const CircularProgressIndicator(
                      color: Colors.white,
                    );
                  }
                  return IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 300),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            v.isPlaying ? controller.pause() : controller.play(),
                        child: Padding(
                          padding: const EdgeInsets.all(40.0),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              v.isPlaying ? Icons.pause : Icons.play_arrow,
                              color: Colors.white,
                              size: 48,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Bottom controls: "00:00 / 10:00" timer on the left, exit-
            // fullscreen button on the right (mirroring media_kit's
            // fullscreen layout), with the seekbar directly underneath.
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Padding(
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
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Text(
                                    '${_formatDuration(position)} / ${_formatDuration(duration)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () =>
                                        Navigator.of(context).maybePop(),
                                    child: const Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.fullscreen_exit,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                              ),
                              child: Slider(
                                value: val,
                                max: max,
                                activeColor: activeColor,
                                inactiveColor: inactiveColor,
                                onChanged: (value) {
                                  controller.seekTo(
                                    Duration(milliseconds: value.toInt()),
                                  );
                                  // Keep controls up while scrubbing.
                                  if (controller.value.isPlaying) {
                                    _startHideTimer();
                                  }
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }
}
