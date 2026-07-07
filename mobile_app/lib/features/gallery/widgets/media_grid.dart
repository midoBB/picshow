import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
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
  final void Function(int index) onOpen;

  @override
  ConsumerState<MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends ConsumerState<MediaGrid> {
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

  @override
  Widget build(BuildContext context) {
    final columns = _columnCount(MediaQuery.of(context).size.width);
    final api = ref.watch(apiClientProvider);

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(pagedFilesProvider(widget.query).notifier).refresh(),
      child: MasonryGridView.count(
        controller: _scrollController,
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        padding: const EdgeInsets.all(8),
        itemCount: widget.files.length,
        itemBuilder: (context, index) {
          final file = widget.files[index];
          return MediaTile(
            file: file,
            thumbnailUrl: api.thumbnailUrl(file.id),
            heroTag: file.mediaType == MediaType.video
                ? api.videoUrl(file.id)
                : api.imageUrl(file.id),
            onTap: () => widget.onOpen(index),
          );
        },
      ),
    );
  }
}
