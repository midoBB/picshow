import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;

import '../../bloc/gallery_bloc.dart';

/// Shared internals for the per-type media item widgets
/// (video / audio / youtube). None of these are exported from the
/// public API; they live here to keep each per-type widget focused.

/// Mixin providing the 3s "auto-hide UI while playing" timer.
///
/// The timer is owned by the State so that it cancels automatically when
/// the widget is disposed via the explicit [cancelHideUITimer] call from
/// the using widget's [State.dispose].
mixin GalleryUIHideMixin<T extends StatefulWidget> on State<T> {
  Timer? _hideUITimer;

  void startHideUITimer(GalleryBloc bloc, int index) {
    _hideUITimer?.cancel();
    _hideUITimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final state = bloc.state;
      if (state.isUIVisible && state.currentIndex == index) {
        bloc.add(GalleryToggleUI(isVisible: false));
      }
    });
  }

  void cancelHideUITimer() {
    _hideUITimer?.cancel();
    _hideUITimer = null;
  }
}

/// Checks connectivity and shows a "no internet" SnackBar if offline.
/// Returns `true` when online, `false` when offline.
Future<bool> mediaConnectivityCheck(
  BuildContext context, {
  String? noInternetMessage,
}) async {
  final results = await Connectivity().checkConnectivity();
  if (!context.mounted) return false;
  if (results.contains(ConnectivityResult.none)) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          noInternetMessage ?? 'No internet connection. Please check your network.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
    return false;
  }
  return true;
}

/// Center play/pause button + buffering indicator.
///
/// Two driving modes:
/// - `bufferingStream != null`: media_kit path — buffering live-updates
///   via [StreamBuilder].
/// - `bufferingStream == null`: synchronous mode used by callers that
///   already drive rebuilds themselves (e.g. youtube via [AnimatedBuilder]).
class GalleryCenterControls extends StatelessWidget {
  final bool isPlaying;
  final bool isReady;
  final Stream<bool>? bufferingStream;
  final bool initialBuffering;
  final GalleryBloc galleryBloc;
  final VoidCallback onTap;

  const GalleryCenterControls({
    super.key,
    required this.isPlaying,
    required this.isReady,
    required this.bufferingStream,
    required this.initialBuffering,
    required this.galleryBloc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bufferingWidget = bufferingStream != null
        ? StreamBuilder<bool>(
            initialData: initialBuffering,
            stream: bufferingStream,
            builder: (context, s) {
              final b = s.data ?? false;
              if (!b || !isPlaying) return const SizedBox.shrink();
              return const CircularProgressIndicator(color: Colors.white);
            },
          )
        : (initialBuffering ? const CircularProgressIndicator(color: Colors.white) : const SizedBox.shrink());

    return Stack(
      alignment: Alignment.center,
      children: [
        bufferingWidget,
        BlocBuilder<GalleryBloc, GalleryState>(
          bloc: galleryBloc,
          buildWhen: (prev, curr) => prev.isUIVisible != curr.isUIVisible,
          builder: (context, state) {
            final isVisible = state.isUIVisible;
            final hideButton = !isVisible || (isPlaying && initialBuffering) || !isReady;
            return IgnorePointer(
              ignoring: hideButton,
              child: AnimatedOpacity(
                opacity: hideButton ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 300),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.all(40.0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
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
      ],
    );
  }
}

class GalleryMediaLoader extends StatelessWidget {
  const GalleryMediaLoader({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }
}

/// Shared rendering for the fullscreen button — positions itself inside
/// the visible video frame computed from [videoAspect] and screen aspect.
class GalleryFullscreenButton extends StatelessWidget {
  final double videoAspect;
  final GalleryBloc galleryBloc;
  final VoidCallback onTap;

  const GalleryFullscreenButton({
    super.key,
    required this.videoAspect,
    required this.galleryBloc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final double screenAspect = screenSize.width / screenSize.height;
    final double renderedH = videoAspect >= screenAspect ? screenSize.width / videoAspect : screenSize.height;
    final double renderedW = videoAspect >= screenAspect ? screenSize.width : screenSize.height * videoAspect;

    final double buttonBottom = (screenSize.height - renderedH) / 2 + 16.0;
    final double buttonRight = (screenSize.width - renderedW) / 2 + 16.0;

    return BlocBuilder<GalleryBloc, GalleryState>(
      bloc: galleryBloc,
      buildWhen: (prev, curr) => prev.isUIVisible != curr.isUIVisible || prev.isSliding != curr.isSliding,
      builder: (context, state) {
        final visible = state.isUIVisible && !state.isSliding;
        return Stack(
          children: [
            Positioned(
              bottom: buttonBottom,
              right: buttonRight,
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: GestureDetector(
                    onTap: onTap,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.fullscreen,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fullscreen button for media_kit video. Hidden for vertical videos.
///
/// Subscribes once to the player's width/height streams and stores the
/// values in state — replaces the previous nested `StreamBuilder<int?>`
/// pair that rebuilt twice per dimension change.
class GalleryMediaKitFullscreenButton extends StatefulWidget {
  final Player player;
  final GalleryBloc galleryBloc;
  final VoidCallback onTap;

  const GalleryMediaKitFullscreenButton({
    super.key,
    required this.player,
    required this.galleryBloc,
    required this.onTap,
  });

  @override
  State<GalleryMediaKitFullscreenButton> createState() => _GalleryMediaKitFullscreenButtonState();
}

class _GalleryMediaKitFullscreenButtonState extends State<GalleryMediaKitFullscreenButton> {
  int? _width;
  int? _height;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;

  @override
  void initState() {
    super.initState();
    _width = widget.player.state.width;
    _height = widget.player.state.height;
    _widthSub = widget.player.stream.width.listen((w) {
      if (!mounted || w == _width) return;
      setState(() => _width = w);
    });
    _heightSub = widget.player.stream.height.listen((h) {
      if (!mounted || h == _height) return;
      setState(() => _height = h);
    });
  }

  @override
  void dispose() {
    _widthSub?.cancel();
    _heightSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = _width;
    final h = _height;
    if (w == null || h == null || w <= h) return const SizedBox.shrink();
    return GalleryFullscreenButton(
      videoAspect: w / h,
      galleryBloc: widget.galleryBloc,
      onTap: widget.onTap,
    );
  }
}

/// Fullscreen button for YouTube items — fixed 16:9 frame.
class GalleryYoutubeFullscreenButton extends StatelessWidget {
  final GalleryBloc galleryBloc;
  final VoidCallback onTap;

  const GalleryYoutubeFullscreenButton({
    super.key,
    required this.galleryBloc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GalleryFullscreenButton(
      videoAspect: 16 / 9,
      galleryBloc: galleryBloc,
      onTap: onTap,
    );
  }
}

/// Transparent overlay that toggles UI on tap. Shared across all media
/// item types.
class GalleryMediaTapOverlay extends StatelessWidget {
  final GalleryBloc galleryBloc;

  const GalleryMediaTapOverlay({super.key, required this.galleryBloc});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          galleryBloc.add(GalleryToggleUI(isVisible: !galleryBloc.state.isUIVisible));
        },
        child: const SizedBox.expand(),
      ),
    );
  }
}
