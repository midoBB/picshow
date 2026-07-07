import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../../bloc/gallery_bloc.dart';
import '../../models/gallery_item.dart';
import '../../models/gallery_theme.dart';
import '../gallery_youtube_fullscreen_route.dart';
import 'gallery_media_internals.dart';

/// Internal widget rendering a single YouTube item via
/// `youtube_player_flutter`. Owns the [YoutubePlayerController] lifecycle
/// and a thin side-effect listener for play-state transitions.
///
/// Performance: the controller's per-tick value changes drive only the
/// center play/pause button via [AnimatedBuilder] — the [YoutubePlayer]
/// subtree does not rebuild on every tick (it subscribes internally).
class GalleryYoutubeItem extends StatefulWidget {
  final GalleryItem item;
  final int index;
  final ValueNotifier<YoutubePlayerController?> activeYoutubeNotifier;
  final GalleryBloc galleryBloc;
  final String? noInternetMessage;
  final GalleryTheme? theme;

  const GalleryYoutubeItem({
    super.key,
    required this.item,
    required this.index,
    required this.activeYoutubeNotifier,
    required this.galleryBloc,
    this.noInternetMessage,
    this.theme,
  });

  @override
  State<GalleryYoutubeItem> createState() => _GalleryYoutubeItemState();
}

class _GalleryYoutubeItemState extends State<GalleryYoutubeItem> with GalleryUIHideMixin<GalleryYoutubeItem> {
  YoutubePlayerController? _controller;
  bool _previousIsReady = false;
  bool _previousIsPlaying = false;

  /// Position saved just before a WebView swap (enter/exit fullscreen) so the
  /// new WebView can seek there once it is ready.
  Duration? _resumePosition;

  /// True while the fullscreen route is on top. The inline [YoutubePlayer]
  /// is suppressed during this window so only one WebView is bound to the
  /// controller — otherwise the inline widget would steal the WebView and
  /// the fullscreen route would render only the static thumbnail.
  final ValueNotifier<bool> _isFullscreen = ValueNotifier<bool>(false);

  bool get _currentlyPlaying => _controller?.value.isPlaying == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.galleryBloc.state.currentIndex == widget.index) {
        _activate();
      }
    });
  }

  void _activate() {
    if (_controller != null) return;

    final id = YoutubePlayer.convertUrlToId(widget.item.url);
    if (id == null) {
      developer.log(
        'Could not parse YouTube video id from "${widget.item.url}"',
        name: 'kGallery',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("This YouTube video can't be played here."),
            duration: Duration(seconds: 2),
          ),
        );
      });
      return;
    }

    final c = YoutubePlayerController(
      initialVideoId: id,
      flags: const YoutubePlayerFlags(
        hideControls: true,
        autoPlay: false,
        hideThumbnail: true,
        mute: false,
        enableCaption: false,
      ),
    );
    _controller = c;
    c.addListener(_listener);
    widget.activeYoutubeNotifier.value = c;

    mediaConnectivityCheck(
      context,
      noInternetMessage: widget.noInternetMessage,
    );

    if (mounted) setState(() {});
  }

  /// Side-effect listener — handles readiness gating and timer transitions.
  /// Crucially does NOT call setState; the controls subtree rebuilds via
  /// the [AnimatedBuilder] in [build].
  void _listener() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;

    if (!_previousIsReady && v.isReady) {
      _previousIsReady = true;
      if (widget.galleryBloc.state.currentIndex == widget.index) {
        final pos = _resumePosition;
        _resumePosition = null;

        if (pos != null) {
          // WebView was swapped (fullscreen enter/exit). A fresh IFrame ignores
          // playVideo() alone because the video is in "unstarted" state — it
          // hasn't been cued yet. seekTo(pos, allowSeekAhead: true) forces the
          // IFrame to load/buffer from that position, and since the controller's
          // playerState is still "playing" from the previous context, seekTo()
          // also calls play() internally. That combination is what works.
          c.seekTo(pos);
        } else {
          // First activation: initialVideoId already cued the video, so
          // playVideo() works directly.
          c.play();
        }
      }
    }

    if (v.isPlaying != _previousIsPlaying) {
      _previousIsPlaying = v.isPlaying;
      final state = widget.galleryBloc.state;
      if (v.isPlaying && state.isUIVisible && state.currentIndex == widget.index) {
        startHideUITimer(widget.galleryBloc, widget.index);
      } else {
        cancelHideUITimer();
      }
    }
  }

  void _deactivate({bool fromDispose = false}) {
    cancelHideUITimer();
    final c = _controller;
    if (c == null) return;

    c.removeListener(_listener);
    _controller = null;
    _previousIsReady = false;
    _previousIsPlaying = false;
    c.dispose();

    final notifier = widget.activeYoutubeNotifier;
    if (fromDispose) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (notifier.value == c) notifier.value = null;
      });
    } else {
      if (notifier.value == c) notifier.value = null;
      if (mounted) setState(() {});
    }
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  Future<void> _enterFullscreen() async {
    final c = _controller;
    if (c == null) return;
    cancelHideUITimer();

    // Save position then reset isReady + gate so the fullscreen WebView's own
    // isReady event (not the stale flag from the old WebView) triggers seekTo.
    _resumePosition = c.value.position;
    _previousIsReady = false;
    _previousIsPlaying = false;
    c.updateValue(c.value.copyWith(isReady: false));
    _isFullscreen.value = true;

    try {
      await Navigator.of(context).push(
        GalleryYoutubeFullscreenRoute(
          ytController: c,
          theme: widget.theme,
        ),
      );
    } finally {
      if (mounted) {
        // Save position from fullscreen then reset isReady + gate so the inline
        // WebView's own isReady event (not the stale flag) triggers seekTo.
        _resumePosition = c.value.position;
        _previousIsReady = false;
        _previousIsPlaying = false;
        c.updateValue(c.value.copyWith(isReady: false));
        _isFullscreen.value = false;
      }
    }
  }

  @override
  void dispose() {
    _isFullscreen.dispose();
    _deactivate(fromDispose: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<GalleryBloc, GalleryState>(
          bloc: widget.galleryBloc,
          listenWhen: (prev, curr) => prev.currentIndex != curr.currentIndex,
          listener: (context, state) {
            if (state.currentIndex == widget.index) {
              _activate();
            } else {
              _deactivate();
            }
          },
        ),
        BlocListener<GalleryBloc, GalleryState>(
          bloc: widget.galleryBloc,
          listenWhen: (prev, curr) => prev.isUIVisible != curr.isUIVisible,
          listener: (context, state) {
            if (state.currentIndex != widget.index) return;
            if (state.isUIVisible && _currentlyPlaying) {
              startHideUITimer(widget.galleryBloc, widget.index);
            } else {
              cancelHideUITimer();
            }
          },
        ),
      ],
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildPlayer(),
          GalleryMediaTapOverlay(galleryBloc: widget.galleryBloc),
          // Until the controller exists / the player reports ready, the
          // WebView paints black — cover it with the loader so a swipe
          // between videos shows progress instead of a black screen.
          if (_controller == null)
            const GalleryMediaLoader()
          else
            AnimatedBuilder(
              animation: _controller!,
              builder: (context, _) {
                final c = _controller;
                if (c == null) return const SizedBox.shrink();
                final v = c.value;
                if (!v.isReady) return const GalleryMediaLoader();
                return Center(
                  child: GalleryCenterControls(
                    isPlaying: v.isPlaying,
                    isReady: v.isReady,
                    bufferingStream: null,
                    initialBuffering: v.playerState == PlayerState.buffering,
                    galleryBloc: widget.galleryBloc,
                    onTap: _togglePlayPause,
                  ),
                );
              },
            ),
          if (_controller != null)
            Positioned.fill(
              child: GalleryYoutubeFullscreenButton(
                galleryBloc: widget.galleryBloc,
                onTap: _enterFullscreen,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayer() {
    final c = _controller;
    if (c == null) {
      return const SizedBox.expand(child: ColoredBox(color: Colors.black));
    }
    return ValueListenableBuilder<bool>(
      valueListenable: _isFullscreen,
      builder: (context, fullscreen, _) {
        if (fullscreen) {
          // Fullscreen route owns the WebView; render a placeholder here
          // so two YoutubePlayer widgets aren't bound to one controller.
          return const SizedBox.expand(child: ColoredBox(color: Colors.black));
        }
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: YoutubePlayer(
              controller: c,
              showVideoProgressIndicator: false,
              bottomActions: const [],
              topActions: const [],
              bufferIndicator: const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}
