import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';
import 'package:picshow_mobile/features/gallery/widgets/media_tile.dart';

class MediaGrid extends ConsumerStatefulWidget {
  const MediaGrid({
    super.key,
    required this.query,
    required this.files,
    required this.onOpen,
  });

  final GalleryQuery query;
  final List<MediaFile> files;
  final Future<String?> Function(int index) onOpen;

  @override
  ConsumerState<MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends ConsumerState<MediaGrid> {
  static const _gridPadding = EdgeInsets.all(8);
  static const _mainAxisSpacing = 8.0;
  static const _crossAxisSpacing = 8.0;

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent * 0.8) {
      ref.read(pagedFilesProvider(widget.query).notifier).loadMore();
    }
  }

  int _columnCount(double width) {
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }

  double _masonryTopForIndex(
    int targetIndex,
    int columns,
    double viewportWidth,
  ) {
    final tileWidth =
        (viewportWidth -
            _gridPadding.horizontal -
            _crossAxisSpacing * (columns - 1)) /
        columns;
    final columnHeights = List<double>.filled(columns, 0);

    for (var index = 0; index <= targetIndex; index++) {
      var shortestColumn = 0;
      for (var column = 1; column < columns; column++) {
        if (columnHeights[column] < columnHeights[shortestColumn]) {
          shortestColumn = column;
        }
      }

      if (index == targetIndex) return columnHeights[shortestColumn];

      columnHeights[shortestColumn] +=
          tileWidth / widget.files[index].thumbAspect + _mainAxisSpacing;
    }

    return 0;
  }

  void _scrollToFile(String fileId) {
    if (!_scrollController.hasClients) return;

    final targetIndex = widget.files.indexWhere((file) => file.id == fileId);
    if (targetIndex == -1) return;

    final viewportWidth =
        context.size?.width ?? MediaQuery.of(context).size.width;
    final columns = _columnCount(viewportWidth);
    final targetTop = _masonryTopForIndex(targetIndex, columns, viewportWidth);
    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = targetTop + _gridPadding.top - (viewportHeight * 0.35);
    final clampedOffset = targetOffset.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _openAndSyncToLastSlide(int index) async {
    final lastFileId = await widget.onOpen(index);
    if (!mounted || lastFileId == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToFile(lastFileId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final columns = _columnCount(MediaQuery.of(context).size.width);
    final api = ref.watch(apiClientProvider);
    final isOnline = ref.watch(isOnlineProvider);
    final budget = ref.watch(mediaCacheBudgetProvider);
    // Rebuilds the badges as the background filler makes files available.
    ref.watch(mediaCacheLedgerRevisionProvider);

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(pagedFilesProvider(widget.query).notifier).refresh(),
      child: MasonryGridView.count(
        controller: _scrollController,
        crossAxisCount: columns,
        mainAxisSpacing: _mainAxisSpacing,
        crossAxisSpacing: _crossAxisSpacing,
        padding: _gridPadding,
        itemCount: widget.files.length,
        itemBuilder: (context, index) {
          final file = widget.files[index];
          return MediaTile(
            file: file,
            thumbnailUrl: api.thumbnailUrl(file.id),
            heroTag: file.mediaType == MediaType.video
                ? api.videoUrl(file.id)
                : api.imageUrl(file.id),
            isOfflineReady: isOnline && budget.isAvailableOffline(file),
            onTap: () => _openAndSyncToLastSlide(index),
          );
        },
      ),
    );
  }
}
