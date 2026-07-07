import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import '../../bloc/gallery_bloc.dart';
import '../../models/gallery_item.dart';
import '../../utils/image_source.dart';
import 'gallery_media_internals.dart';

/// Internal widget rendering a single media_kit audio item. Reuses the
/// media_kit lifecycle from [GalleryVideoItem] but renders a thumbnail
/// or audiotrack icon as the visual instead of a video frame, and has
/// no fullscreen affordance.
class GalleryAudioItem extends StatefulWidget {
  final GalleryItem item;
  final int index;
  final ValueNotifier<Player?> activePlayerNotifier;
  final GalleryBloc galleryBloc;
  final String? noInternetMessage;

  /// Cache manager forwarded to the artwork's [CachedNetworkImage].
  final BaseCacheManager? cacheManager;

  /// In-memory decode width cap forwarded to the artwork's [CachedNetworkImage].
  final int? memCacheWidth;

  const GalleryAudioItem({
    super.key,
    required this.item,
    required this.index,
    required this.activePlayerNotifier,
    required this.galleryBloc,
    this.noInternetMessage,
    this.cacheManager,
    this.memCacheWidth,
  });

  @override
  State<GalleryAudioItem> createState() => _GalleryAudioItemState();
}

class _GalleryAudioItemState extends State<GalleryAudioItem>
    with GalleryUIHideMixin<GalleryAudioItem> {
  Player? _player;
  StreamSubscription? _playingSubscription;
  StreamSubscription? _completedSubscription;

  bool get _currentlyPlaying => _player?.state.playing == true;

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
    if (_player != null) return;
    final p = Player();
    _player = p;

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
      p.seek(Duration.zero);
      p.pause();
      cancelHideUITimer();
      final state = widget.galleryBloc.state;
      if (!state.isUIVisible && state.currentIndex == widget.index) {
        widget.galleryBloc.add(GalleryToggleUI(isVisible: true));
      }
    });

    widget.activePlayerNotifier.value = p;

    p.open(Media(widget.item.url), play: false);
    _playWithConnectivityCheck();

    if (mounted) setState(() {});
  }

  void _deactivate({bool fromDispose = false}) {
    cancelHideUITimer();
    final p = _player;
    if (p == null) return;

    _playingSubscription?.cancel();
    _playingSubscription = null;
    _completedSubscription?.cancel();
    _completedSubscription = null;
    _player = null;
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

    if (!widget.item.url.startsWith('http')) {
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
          _buildArtwork(),
          GalleryMediaTapOverlay(galleryBloc: widget.galleryBloc),
          if (_player != null)
            Center(
              child: StreamBuilder<bool>(
                initialData: _player!.state.playing,
                stream: _player!.stream.playing,
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
        ],
      ),
    );
  }

  Widget _buildArtwork() {
    final thumb = widget.item.thumbnailUrl;
    return Center(
      child: thumb != null
          ? galleryImage(
              source: thumb,
              fit: BoxFit.contain,
              cacheManager: widget.cacheManager,
              memCacheWidth: widget.memCacheWidth,
              errorWidget: (context, _, __) => const Icon(
                Icons.audiotrack,
                size: 100,
                color: Colors.white54,
              ),
            )
          : const Icon(
              Icons.audiotrack,
              size: 100,
              color: Colors.white54,
            ),
    );
  }
}
