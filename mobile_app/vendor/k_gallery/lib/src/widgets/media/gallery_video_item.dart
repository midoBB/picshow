import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:media_kit_video/media_kit_video.dart';

import '../../bloc/gallery_bloc.dart';
import '../../models/gallery_item.dart';
import '../../models/gallery_theme.dart';
import '../../utils/media_source_resolver.dart';
import 'gallery_media_internals.dart';

/// Internal widget rendering a single media_kit video item inside the
/// gallery page view. Owns the [Player]/[VideoController] lifecycle and
/// drives playback based on the active gallery index.
class GalleryVideoItem extends StatefulWidget {
  final GalleryItem item;
  final int index;
  final ValueNotifier<Player?> activePlayerNotifier;
  final GalleryBloc galleryBloc;
  final String? noInternetMessage;
  final GalleryTheme? theme;

  /// Cache manager used to download and replay the video from a local file
  /// instead of re-streaming from the network on every view. When `null` (or
  /// on a download/lookup failure), falls back to streaming [item.url]
  /// directly, matching the previous behavior.
  final BaseCacheManager? cacheManager;

  const GalleryVideoItem({
    super.key,
    required this.item,
    required this.index,
    required this.activePlayerNotifier,
    required this.galleryBloc,
    this.noInternetMessage,
    this.theme,
    this.cacheManager,
  });

  @override
  State<GalleryVideoItem> createState() => _GalleryVideoItemState();
}

class _GalleryVideoItemState extends State<GalleryVideoItem>
    with GalleryUIHideMixin<GalleryVideoItem> {
  Player? _player;
  VideoController? _videoController;
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  StreamSubscription? _playingSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _bufferingSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  ResolvedMediaSource? _resolvedSource;
  bool _isBuffering = true;
  bool _hasVideoDimensions = false;

  bool get _currentlyPlaying => _player?.state.playing == true;

  @override
  void initState() {
    super.initState();
    // Defer to post-frame: activation sets the notifier, which would
    // notify ValueListenableBuilder mid-build if invoked synchronously.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.galleryBloc.state.currentIndex == widget.index) {
        _activate();
      }
    });
  }

  void _activate() {
    if (_player != null) return;
    final p = Player();
    _player = p;
    _videoController = VideoController(p);

    _playingSubscription = p.stream.playing.listen((isPlaying) {
      if (!mounted) return;
      final state = widget.galleryBloc.state;
      if (isPlaying &&
          state.isUIVisible &&
          state.currentIndex == widget.index) {
        startHideUITimer(widget.galleryBloc, widget.index);
      } else {
        cancelHideUITimer();
      }
    });

    _completedSubscription = p.stream.completed.listen((completed) {
      if (!mounted || !completed) return;
      final isActive = widget.galleryBloc.state.currentIndex == widget.index;
      if (isActive) unawaited(p.seek(Duration.zero).then((_) => p.play()));
    });
    _bufferingSubscription = p.stream.buffering.listen((isBuffering) {
      if (!mounted || _isBuffering == isBuffering) return;
      setState(() => _isBuffering = isBuffering);
    });
    _widthSubscription =
        p.stream.width.listen((_) => _markVideoDimensionsReady());
    _heightSubscription =
        p.stream.height.listen((_) => _markVideoDimensionsReady());

    widget.activePlayerNotifier.value = p;

    unawaited(_openMedia(p));

    if (mounted) setState(() {});
  }

  /// Resolves [item.url] to a local cache file (downloading it fully if not
  /// already cached) before opening it in the player, so a replayed video
  /// plays from disk instead of re-streaming. See [resolveMediaSource].
  Future<void> _openMedia(Player p) async {
    final resolved = await resolveMediaSource(
      widget.cacheManager,
      widget.item.url,
      cacheKey: widget.item.cacheKey,
    );

    // Superseded by a swipe-away/dispose while the download was in flight —
    // the player this call was meant for no longer exists.
    if (!mounted || _player != p) return;

    _resolvedSource = resolved;
    await p.open(Media(resolved.source), play: false);
    _playWithConnectivityCheck();
  }

  void _markVideoDimensionsReady() {
    final p = _player;
    if (p == null || !mounted || _hasVideoDimensions) return;
    final width = p.state.width;
    final height = p.state.height;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    setState(() => _hasVideoDimensions = true);
  }

  void _deactivate({bool fromDispose = false}) {
    cancelHideUITimer();
    final p = _player;
    if (p == null) return;

    _playingSubscription?.cancel();
    _playingSubscription = null;
    _completedSubscription?.cancel();
    _completedSubscription = null;
    _bufferingSubscription?.cancel();
    _bufferingSubscription = null;
    _widthSubscription?.cancel();
    _widthSubscription = null;
    _heightSubscription?.cancel();
    _heightSubscription = null;
    _player = null;
    _videoController = null;
    _isBuffering = true;
    _hasVideoDimensions = false;
    _resolvedSource = null;
    p.dispose();

    final notifier = widget.activePlayerNotifier;
    if (fromDispose) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (notifier.value == p) notifier.value = null;
      });
    } else {
      if (notifier.value == p) notifier.value = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _playWithConnectivityCheck() async {
    final p = _player;
    if (p == null) return;

    // The gate is about the source actually opened, not [item.url]. Checking
    // the URL meant a fully cached video — the whole point of the cache — was
    // refused with "no internet connection" the moment the radio went down,
    // while cached images kept working.
    if (_resolvedSource?.isLocal ?? !widget.item.url.startsWith('http')) {
      p.play();
      return;
    }

    final online = await mediaConnectivityCheck(
      context,
      noInternetMessage: widget.noInternetMessage,
    );
    if (!online) return;
    if (mounted &&
        _player == p &&
        widget.galleryBloc.state.currentIndex == widget.index) {
      p.play();
    }
  }

  void _togglePlayPause() {
    final p = _player;
    if (p == null) return;
    if (p.state.playing) {
      p.pause();
    } else {
      _playWithConnectivityCheck();
    }
  }

  Future<void> _enterFullscreen() async {
    cancelHideUITimer();
    await _videoKey.currentState?.enterFullscreen();
    if (mounted && _currentlyPlaying) {
      startHideUITimer(widget.galleryBloc, widget.index);
    }
  }

  @override
  void dispose() {
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
          // Isolate decoded video frames from overlay redraws (UI toggling,
          // slide gestures) so they don't repaint together.
          RepaintBoundary(child: _buildVideo()),
          GalleryMediaTapOverlay(galleryBloc: widget.galleryBloc),
          if (_videoController == null)
            const GalleryMediaLoader()
          else
            Center(
              child: StreamBuilder<bool>(
                initialData: _player?.state.playing ?? false,
                stream: _player?.stream.playing,
                builder: (context, snapshot) {
                  final p = _player;
                  if (p == null) return const SizedBox.shrink();
                  return GalleryCenterControls(
                    isPlaying: snapshot.data ?? false,
                    isReady: true,
                    bufferingStream: p.stream.buffering,
                    initialBuffering: p.state.buffering,
                    galleryBloc: widget.galleryBloc,
                    onTap: _togglePlayPause,
                  );
                },
              ),
            ),
          if (_videoController != null && _isBuffering && !_hasVideoDimensions)
            const IgnorePointer(
              child:
                  Center(child: CircularProgressIndicator(color: Colors.white)),
            ),
          if (_player != null)
            Positioned.fill(
              child: GalleryMediaKitFullscreenButton(
                player: _player!,
                galleryBloc: widget.galleryBloc,
                onTap: _enterFullscreen,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _videoController;
    if (controller == null) {
      return const SizedBox.expand(child: ColoredBox(color: Colors.black));
    }
    return Center(
      child: Video(
        key: _videoKey,
        controller: controller,
        controls: _fullscreenControlsBuilder,
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _fullscreenControlsBuilder(VideoState state) {
    bool inFullscreen;
    try {
      inFullscreen = state.isFullscreen();
    } catch (_) {
      inFullscreen = false;
    }
    if (!inFullscreen) return const SizedBox.shrink();

    final activeColor = widget.theme?.seekbarActiveColor ?? Colors.white;
    final inactiveColor = widget.theme?.seekbarInactiveColor ?? Colors.white30;
    final themeData = MaterialVideoControlsThemeData(
      seekBarPositionColor: activeColor,
      seekBarThumbColor: activeColor,
      seekBarColor: inactiveColor,
      seekBarBufferColor: inactiveColor,
      bottomButtonBarMargin: const EdgeInsets.only(
        left: 16.0,
        right: 8.0,
        bottom: 16,
      ),
      seekBarMargin: const EdgeInsets.only(
        left: 16.0,
        right: 16.0,
        bottom: 16.0,
      ),
    );
    return MaterialVideoControlsTheme(
      normal: themeData,
      fullscreen: themeData,
      child: MaterialVideoControls(state),
    );
  }
}
