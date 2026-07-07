import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:k_gallery/k_gallery.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/widgets/async_states.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';
import 'package:picshow_mobile/features/gallery/widgets/media_grid.dart';
import 'package:picshow_mobile/features/server_setup/server_url_screen.dart';

class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  static const _nearbyPreloadRadius = 3;
  static final Set<String> _preloadingImages = <String>{};

  GalleryItem _galleryItemFor(MediaFile file, ApiClient api) {
    return GalleryItem(
      url: file.mediaType == MediaType.video
          ? api.videoUrl(file.id)
          : api.imageUrl(file.id),
      type: file.mediaType == MediaType.video
          ? GalleryItemType.video
          : GalleryItemType.image,
      thumbnailUrl: api.thumbnailUrl(file.id),
      description: DateFormat.yMMMd().add_jm().format(file.createdAt.toLocal()),
    );
  }

  MediaFile? _findFileById(List<MediaFile>? files, String id) {
    if (files == null) return null;
    for (final file in files) {
      if (file.id == id) return file;
    }
    return null;
  }

  int _fullImageMemCacheWidth(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    return (mediaQuery.size.width * mediaQuery.devicePixelRatio).ceil();
  }

  Iterable<int> _nearbyPreloadIndexes(int currentIndex, int itemCount) sync* {
    if (currentIndex < 0 || currentIndex >= itemCount) return;

    yield currentIndex;
    for (var offset = 1; offset <= _nearbyPreloadRadius; offset++) {
      final nextIndex = currentIndex + offset;
      if (nextIndex < itemCount) yield nextIndex;

      final previousIndex = currentIndex - offset;
      if (previousIndex >= 0) yield previousIndex;
    }
  }

  Future<void> _precacheGalleryImage(
    BuildContext context,
    String url, {
    required int memCacheWidth,
  }) async {
    if (!url.startsWith('http')) return;

    final cacheKey = '$url@$memCacheWidth';
    if (!_preloadingImages.add(cacheKey)) return;

    try {
      if (!context.mounted) return;
      await precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            cacheManager: FullImageCacheManager.instance,
          ),
          width: memCacheWidth,
        ),
        context,
        onError: (_, _) {},
      );
    } finally {
      _preloadingImages.remove(cacheKey);
    }
  }

  void _preloadNearbySlides(
    BuildContext context,
    List<GalleryItem> items,
    int currentIndex, {
    required int memCacheWidth,
  }) {
    for (final index in _nearbyPreloadIndexes(currentIndex, items.length)) {
      final item = items[index];
      final preloadUrl = item.type == GalleryItemType.image
          ? item.url
          : item.thumbnailUrl;
      if (preloadUrl == null) continue;

      unawaited(
        _precacheGalleryImage(
          context,
          preloadUrl,
          memCacheWidth: item.type == GalleryItemType.image
              ? memCacheWidth
              : 400,
        ),
      );
    }
  }

  Future<String?> _openGallery(
    BuildContext context,
    WidgetRef ref,
    GalleryQuery query,
    List<MediaFile> files,
    int initialIndex,
  ) async {
    if (files.isEmpty) return null;

    final api = ref.read(apiClientProvider);
    final items = [for (final file in files) _galleryItemFor(file, api)];
    final startIndex = initialIndex.clamp(0, items.length - 1).toInt();
    final memCacheWidth = _fullImageMemCacheWidth(context);
    var lastIndex = startIndex;

    await WakelockPlus.enable();
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!context.mounted) return files[lastIndex].id;
      _preloadNearbySlides(
        context,
        items,
        startIndex,
        memCacheWidth: memCacheWidth,
      );
      await KGallery.show(
        context,
        contentList: items,
        initialIndex: startIndex,
        cacheManager: FullImageCacheManager.instance,
        memCacheWidth: memCacheWidth,
        noInternetMessage: 'Failed to load media',
        onIndexChanged: (index) {
          lastIndex = index;
          _preloadNearbySlides(
            context,
            items,
            index,
            memCacheWidth: memCacheWidth,
          );
          if (index >= files.length - 3) {
            ref.read(pagedFilesProvider(query).notifier).loadMore();
          }
        },
        actionMenuBuilder: (context, currentIndex, items) {
          if (currentIndex < 0 || currentIndex >= files.length) {
            return const SizedBox(width: 48);
          }
          final originalFile = files[currentIndex];
          return Consumer(
            builder: (context, ref, _) {
              final latestFiles = ref
                  .watch(pagedFilesProvider(query))
                  .valueOrNull
                  ?.files;
              final currentFile = _findFileById(latestFiles, originalFile.id);
              final file = currentFile ?? originalFile;
              return IconButton(
                icon: Icon(
                  file.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: file.isFavorite ? Colors.redAccent : Colors.white,
                ),
                onPressed: () => ref
                    .read(pagedFilesProvider(query).notifier)
                    .toggleFavorite(originalFile.id),
              );
            },
          );
        },
      );
      return files[lastIndex].id;
    } finally {
      await WakelockPlus.disable();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  IconData _emptyIconFor(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return Icons.videocam_off_outlined;
      case MediaFilter.favorite:
        return Icons.favorite_border;
      case MediaFilter.image:
      case MediaFilter.all:
        return Icons.photo_library_outlined;
    }
  }

  String _emptyMessageFor(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return 'No videos found';
      case MediaFilter.favorite:
        return 'No favorites yet';
      case MediaFilter.image:
        return 'No images found';
      case MediaFilter.all:
        return 'No media found';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(galleryQueryProvider);
    final asyncState = ref.watch(pagedFilesProvider(query));
    final themeMode = ref.watch(themeModeProvider);

    void updateQuery(GalleryQuery Function(GalleryQuery) fn) {
      ref.read(galleryQueryProvider.notifier).state = fn(query);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Picshow'),
        actions: [
          PopupMenuButton<MediaFilter>(
            icon: const Icon(Icons.filter_list),
            initialValue: query.filter,
            onSelected: (filter) =>
                updateQuery((q) => q.copyWith(filter: filter)),
            itemBuilder: (context) => MediaFilter.values
                .map((f) => PopupMenuItem(value: f, child: Text(f.label)))
                .toList(),
          ),
          IconButton(
            tooltip: query.order == SortOrder.random
                ? 'Random order'
                : 'Sort by date',
            icon: Icon(
              query.order == SortOrder.random
                  ? Icons.shuffle
                  : Icons.calendar_today,
            ),
            onPressed: () => updateQuery(
              (q) => q.order == SortOrder.random
                  ? q.copyWith(order: SortOrder.createdAt, clearSeed: true)
                  : q.copyWith(
                      order: SortOrder.random,
                      seed: Random().nextInt(1 << 31),
                    ),
            ),
          ),
          if (query.order == SortOrder.random)
            IconButton(
              tooltip: 'Reroll',
              icon: const Icon(Icons.casino_outlined),
              onPressed: () => updateQuery(
                (q) => q.copyWith(seed: Random().nextInt(1 << 31)),
              ),
            )
          else
            IconButton(
              tooltip: query.direction == SortDirection.desc
                  ? 'Newest first'
                  : 'Oldest first',
              icon: Icon(
                query.direction == SortDirection.desc
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
              ),
              onPressed: () => updateQuery(
                (q) => q.copyWith(
                  direction: q.direction == SortDirection.desc
                      ? SortDirection.asc
                      : SortDirection.desc,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(
              themeMode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode,
            ),
            onPressed: () {
              final next = themeMode == ThemeMode.dark
                  ? ThemeMode.light
                  : ThemeMode.dark;
              ref.read(themeModeProvider.notifier).state = next;
              ref.read(appPrefsProvider).setThemeMode(next);
            },
          ),
          IconButton(
            tooltip: 'Server URL',
            icon: const Icon(Icons.settings_ethernet),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const ServerUrlScreen(isEditing: true),
              ),
            ),
          ),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorRetryState(
          message: 'Failed to load media',
          onRetry: () => ref.invalidate(pagedFilesProvider(query)),
        ),
        data: (state) {
          if (state.files.isEmpty) {
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(pagedFilesProvider(query).notifier).refresh(),
              child: ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.7,
                    child: EmptyState(
                      icon: _emptyIconFor(query.filter),
                      message: _emptyMessageFor(query.filter),
                    ),
                  ),
                ],
              ),
            );
          }
          return MediaGrid(
            query: query,
            files: state.files,
            onOpen: (index) =>
                _openGallery(context, ref, query, state.files, index),
          );
        },
      ),
    );
  }
}
