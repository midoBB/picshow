import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.videoUrl,
    required this.isActive,
    this.onCompleted,
  });

  final String videoUrl;
  final bool isActive;

  /// Called once when playback reaches the end. When set, looping is
  /// disabled so this actually fires (used to drive slideshow auto-advance).
  final VoidCallback? onCompleted;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<bool>? _completedSubscription;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(),
    );
    _controller = VideoController(_player);
    _errorSubscription = _player.stream.error.listen((message) {
      if (mounted) setState(() => _error = message);
    });
    _completedSubscription = _player.stream.completed.listen((completed) {
      if (completed) widget.onCompleted?.call();
    });
    _openMedia();
  }

  void _openMedia() {
    setState(() => _error = null);
    _player.setPlaylistMode(widget.onCompleted != null ? PlaylistMode.none : PlaylistMode.loop);
    // The server doesn't support HTTP Range requests, so a forward-then-back
    // seek re-downloads from byte 0. Raising mpv's demuxer cache keeps more of
    // the stream buffered in memory so back-seeks within that window are free.
    final platform = _player.platform;
    if (platform is NativePlayer) {
      unawaited(platform.setProperty('demuxer-max-bytes', '${512 * 1024 * 1024}'));
      unawaited(platform.setProperty('demuxer-max-back-bytes', '${256 * 1024 * 1024}'));
    }
    _player.open(Media(widget.videoUrl), play: widget.isActive);
  }

  @override
  void didUpdateWidget(covariant VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive != oldWidget.isActive) {
      if (widget.isActive) {
        _player.play();
      } else {
        _player.pause();
      }
    }
    if ((widget.onCompleted != null) != (oldWidget.onCompleted != null)) {
      _player.setPlaylistMode(widget.onCompleted != null ? PlaylistMode.none : PlaylistMode.loop);
    }
  }

  @override
  void dispose() {
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white54, size: 48),
              const SizedBox(height: 12),
              const Text('Failed to play video', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _openMedia, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    return Container(
      color: Colors.black,
      child: Center(
        child: MaterialVideoControlsTheme(
          normal: kDefaultMaterialVideoControlsThemeData.copyWith(seekGesture: false),
          fullscreen: kDefaultMaterialVideoControlsThemeData.copyWith(seekGesture: false),
          child: Video(
            controller: _controller,
            controls: AdaptiveVideoControls,
          ),
        ),
      ),
    );
  }
}
