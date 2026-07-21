import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k_gallery/k_gallery.dart';
// ignore: implementation_imports
import 'package:k_gallery/src/bloc/gallery_bloc.dart' as k_gallery_bloc;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/media_cache_lookup.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/widgets/async_states.dart';
import 'package:picshow_mobile/core/widgets/toasts.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';
import 'package:picshow_mobile/features/gallery/widgets/media_grid.dart';
import 'package:picshow_mobile/features/gallery/widgets/media_stats_dialog.dart';
import 'package:picshow_mobile/features/server_setup/server_url_screen.dart';
import 'package:picshow_mobile/features/settings/cache_settings_screen.dart';

enum _OverflowAction { statistics, cache, serverUrl }

class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  static const _nearbyPreloadRadius = 3;
  // Narrower than the image radius: videos run tens to hundreds of MB, so
  // prefetching at the same radius as images could mean downloading a
  // gigabyte+ per swipe-through. Radius 1 keeps "swipe to next video"
  // feeling instant without excessive bandwidth use.
  static const _videoPreloadRadius = 1;
  static final Set<String> _preloadingImages = <String>{};
  static final Set<String> _preloadingVideos = <String>{};

  GalleryItem _galleryItemFor(MediaFile file, ApiClient api) {
    return GalleryItem(
      url: file.mediaType == MediaType.video
          ? api.videoUrl(file.id)
          : api.imageUrl(file.id),
      type: file.mediaType == MediaType.video
          ? GalleryItemType.video
          : GalleryItemType.image,
      thumbnailUrl: api.thumbnailUrl(file.id),
      thumbnailCacheKey: 'thumb-${file.id}',
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

  Iterable<int> _nearbyPreloadIndexes(
    int currentIndex,
    int itemCount, {
    int radius = _nearbyPreloadRadius,
  }) sync* {
    if (currentIndex < 0 || currentIndex >= itemCount) return;

    yield currentIndex;
    for (var offset = 1; offset <= radius; offset++) {
      final nextIndex = currentIndex + offset;
      if (nextIndex < itemCount) yield nextIndex;

      final previousIndex = currentIndex - offset;
      if (previousIndex >= 0) yield previousIndex;
    }
  }

  Future<void> _precacheNetworkImage(
    BuildContext context,
    String url, {
    required BaseCacheManager cacheManager,
    required int memCacheWidth,
    required bool online,
    required MediaCacheBudget budget,
    required CacheBucket bucket,
    String? cacheKey,
  }) async {
    if (!online) return;
    if (!url.startsWith('http')) return;

    final preloadKey = '$url:${cacheKey ?? url}:$memCacheWidth';
    if (!_preloadingImages.add(preloadKey)) return;

    try {
      if (!context.mounted) return;
      await precacheImage(
        ResizeImage(
          CachedNetworkImageProvider(
            url,
            cacheManager: cacheManager,
            cacheKey: cacheKey,
          ),
          width: memCacheWidth,
        ),
        context,
        onError: (_, _) {},
      );
      await budget.recordFromCache(bucket, cacheKey ?? url);
    } finally {
      _preloadingImages.remove(preloadKey);
    }
  }

  Future<void> _precacheVideo(
    String url, {
    required bool online,
    required MediaCacheBudget budget,
  }) async {
    if (!online) return;
    if (!_preloadingVideos.add(url)) return;
    final key = 'video-${url.hashCode}';
    try {
      await VideoCacheManager.instance.getSingleFile(url, key: key);
      await budget.recordFromCache(CacheBucket.video, key);
    } catch (_) {
      // Best-effort prefetch; playback will fall back to network streaming.
    } finally {
      _preloadingVideos.remove(url);
    }
  }

  void _preloadNearbySlides(
    BuildContext context,
    List<MediaFile> files,
    ApiClient api,
    int currentIndex, {
    required int memCacheWidth,
    required bool online,
    required MediaCacheBudget budget,
  }) {
    if (!online) return;

    for (final index in _nearbyPreloadIndexes(currentIndex, files.length)) {
      final file = files[index];
      unawaited(
        _precacheNetworkImage(
          context,
          api.thumbnailUrl(file.id),
          cacheManager: ThumbCacheManager.instance,
          cacheKey: 'thumb-${file.id}',
          memCacheWidth: 400,
          online: online,
          budget: budget,
          bucket: CacheBucket.thumb,
        ),
      );

      if (file.mediaType == MediaType.image) {
        unawaited(
          _precacheNetworkImage(
            context,
            api.imageUrl(file.id),
            cacheManager: FullImageCacheManager.instance,
            memCacheWidth: memCacheWidth,
            online: online,
            budget: budget,
            bucket: CacheBucket.image,
          ),
        );
      }
    }

    for (final index in _nearbyPreloadIndexes(
      currentIndex,
      files.length,
      radius: _videoPreloadRadius,
    )) {
      final file = files[index];
      if (file.mediaType == MediaType.video) {
        unawaited(
          _precacheVideo(
            api.videoUrl(file.id),
            online: online,
            budget: budget,
          ),
        );
      }
    }
  }

  void _replaceGalleryItems(
    BuildContext context,
    List<MediaFile> files,
    ApiClient api,
    List<GalleryItem> items,
    k_gallery_bloc.GalleryBloc? galleryBloc,
    int currentIndex, {
    required int memCacheWidth,
    required bool online,
    required MediaCacheBudget budget,
  }) {
    final safeIndex = currentIndex.clamp(0, items.length - 1).toInt();
    galleryBloc?.add(
      k_gallery_bloc.GalleryInitialize(items: items, initialIndex: safeIndex),
    );
    _preloadNearbySlides(
      context,
      files,
      api,
      safeIndex,
      memCacheWidth: memCacheWidth,
      online: online,
      budget: budget,
    );
  }

  Future<void> _syncLoadedGallerySlides({
    required BuildContext context,
    required WidgetRef ref,
    required GalleryQuery query,
    required ApiClient api,
    required int currentIndex,
    required int memCacheWidth,
    required bool online,
    required k_gallery_bloc.GalleryBloc? galleryBloc,
    required List<MediaFile> Function() getGalleryFiles,
    required void Function(List<MediaFile> files) setGalleryFiles,
    required void Function(List<GalleryItem> items) setGalleryItems,
  }) async {
    final budget = ref.read(mediaCacheBudgetProvider);
    final latestBeforeLoad = ref.read(pagedFilesProvider(query)).valueOrNull;
    if (latestBeforeLoad != null &&
        latestBeforeLoad.files.length > getGalleryFiles().length) {
      final updatedItems = [
        for (final file in latestBeforeLoad.files) _galleryItemFor(file, api),
      ];
      setGalleryFiles(latestBeforeLoad.files);
      setGalleryItems(updatedItems);
      if (context.mounted) {
        _replaceGalleryItems(
          context,
          latestBeforeLoad.files,
          api,
          updatedItems,
          galleryBloc,
          currentIndex,
          memCacheWidth: memCacheWidth,
          online: online,
          budget: budget,
        );
      }
    }

    final state = ref.read(pagedFilesProvider(query)).valueOrNull;
    if (state == null ||
        state.isLoadingMore ||
        !state.hasMore ||
        currentIndex < getGalleryFiles().length - 3) {
      return;
    }

    await ref.read(pagedFilesProvider(query).notifier).loadMore();
    final latestAfterLoad = ref.read(pagedFilesProvider(query)).valueOrNull;
    if (latestAfterLoad == null ||
        latestAfterLoad.files.length <= getGalleryFiles().length) {
      return;
    }

    final updatedItems = [
      for (final file in latestAfterLoad.files) _galleryItemFor(file, api),
    ];
    setGalleryFiles(latestAfterLoad.files);
    setGalleryItems(updatedItems);
    if (!context.mounted) return;

    _replaceGalleryItems(
      context,
      latestAfterLoad.files,
      api,
      updatedItems,
      galleryBloc,
      currentIndex,
      memCacheWidth: memCacheWidth,
      online: online,
      budget: budget,
    );
  }

  void _maybeLoadMoreGallerySlides({
    required BuildContext context,
    required WidgetRef ref,
    required GalleryQuery query,
    required ApiClient api,
    required int currentIndex,
    required int memCacheWidth,
    required bool online,
    required bool Function() isLoading,
    required void Function(bool value) setLoading,
    required k_gallery_bloc.GalleryBloc? galleryBloc,
    required List<MediaFile> Function() getGalleryFiles,
    required void Function(List<MediaFile> files) setGalleryFiles,
    required void Function(List<GalleryItem> items) setGalleryItems,
  }) {
    if (isLoading()) return;
    setLoading(true);
    unawaited(
      _syncLoadedGallerySlides(
        context: context,
        ref: ref,
        query: query,
        api: api,
        currentIndex: currentIndex,
        memCacheWidth: memCacheWidth,
        online: online,
        galleryBloc: galleryBloc,
        getGalleryFiles: getGalleryFiles,
        setGalleryFiles: setGalleryFiles,
        setGalleryItems: setGalleryItems,
      ).whenComplete(() => setLoading(false)),
    );
  }

  void _captureGalleryBloc(
    BuildContext context,
    void Function(k_gallery_bloc.GalleryBloc bloc) setGalleryBloc,
  ) {
    try {
      setGalleryBloc(context.read<k_gallery_bloc.GalleryBloc>());
    } catch (_) {
      // The first action build can happen before the package's provider is ready.
    }
  }

  MediaFile? _fileAt(List<MediaFile> files, int index) {
    if (index < 0 || index >= files.length) return null;
    return files[index];
  }

  String? _fileIdAt(List<MediaFile> files, int index) {
    return _fileAt(files, index)?.id;
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
    final online = ref.read(isOnlineProvider);
    final budget = ref.read(mediaCacheBudgetProvider);
    var galleryFiles = files;
    var startIndex = initialIndex.clamp(0, files.length - 1).toInt();

    if (!online) {
      final tappedFile = files[startIndex];
      final cachedFlags = await Future.wait(
        files.map((file) => isFullBlobCached(file, api)),
      );
      final cachedFiles = [
        for (var i = 0; i < files.length; i++)
          if (cachedFlags[i]) files[i],
      ];
      final tappedIndex = cachedFiles.indexWhere((f) => f.id == tappedFile.id);
      if (tappedIndex == -1) {
        showToast('Not available offline', isError: true);
        return null;
      }
      galleryFiles = cachedFiles;
      startIndex = tappedIndex;
    }

    if (!context.mounted) return null;
    var items = [for (final file in galleryFiles) _galleryItemFor(file, api)];
    final memCacheWidth = _fullImageMemCacheWidth(context);
    var lastIndex = startIndex;
    var isLoadingMoreSlides = false;
    k_gallery_bloc.GalleryBloc? galleryBloc;

    await WakelockPlus.enable();
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!context.mounted) return _fileIdAt(galleryFiles, lastIndex);
      _preloadNearbySlides(
        context,
        galleryFiles,
        api,
        startIndex,
        memCacheWidth: memCacheWidth,
        online: online,
        budget: budget,
      );
      await KGallery.show(
        context,
        contentList: items,
        initialIndex: startIndex,
        cacheManager: FullImageCacheManager.instance,
        thumbCacheManager: ThumbCacheManager.instance,
        videoCacheManager: VideoCacheManager.instance,
        memCacheWidth: memCacheWidth,
        noInternetMessage: 'Failed to load media',
        onIndexChanged: (index) {
          lastIndex = index;
          _preloadNearbySlides(
            context,
            galleryFiles,
            api,
            index,
            memCacheWidth: memCacheWidth,
            online: online,
            budget: budget,
          );
          _maybeLoadMoreGallerySlides(
            context: context,
            ref: ref,
            query: query,
            api: api,
            currentIndex: index,
            memCacheWidth: memCacheWidth,
            online: online,
            isLoading: () => isLoadingMoreSlides,
            setLoading: (value) => isLoadingMoreSlides = value,
            galleryBloc: galleryBloc,
            getGalleryFiles: () => galleryFiles,
            setGalleryFiles: (files) => galleryFiles = files,
            setGalleryItems: (updatedItems) => items = updatedItems,
          );
        },
        actionMenuBuilder: (context, currentIndex, _) {
          _captureGalleryBloc(context, (bloc) => galleryBloc = bloc);
          final activeGalleryBloc = galleryBloc;
          if (activeGalleryBloc != null &&
              activeGalleryBloc.state.items.length != items.length) {
            _replaceGalleryItems(
              context,
              galleryFiles,
              api,
              items,
              activeGalleryBloc,
              currentIndex,
              memCacheWidth: memCacheWidth,
              online: online,
              budget: budget,
            );
          }
          _maybeLoadMoreGallerySlides(
            context: context,
            ref: ref,
            query: query,
            api: api,
            currentIndex: currentIndex,
            memCacheWidth: memCacheWidth,
            online: online,
            isLoading: () => isLoadingMoreSlides,
            setLoading: (value) => isLoadingMoreSlides = value,
            galleryBloc: galleryBloc,
            getGalleryFiles: () => galleryFiles,
            setGalleryFiles: (files) => galleryFiles = files,
            setGalleryItems: (updatedItems) => items = updatedItems,
          );

          final originalFile = _fileAt(galleryFiles, currentIndex);
          if (originalFile == null) {
            return const SizedBox(width: 48);
          }
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
      return _fileIdAt(galleryFiles, lastIndex);
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

  String _emptyMessageFor(MediaFilter filter, {required bool isOffline}) {
    if (isOffline) return 'No cached ${filter.label.toLowerCase()} available offline';
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
    final isOnline = ref.watch(isOnlineProvider);

    void updateQuery(GalleryQuery Function(GalleryQuery) fn) {
      ref.read(galleryQueryProvider.notifier).state = fn(query);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('PicShow'),
        bottom: isOnline
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.center,
                  child: Text(
                    'Offline — showing cached items',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
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
          PopupMenuButton<_OverflowAction>(
            tooltip: 'More options',
            onSelected: (action) {
              switch (action) {
                case _OverflowAction.statistics:
                  showDialog<void>(
                    context: context,
                    builder: (_) => const MediaStatsDialog(),
                  );
                  break;
                case _OverflowAction.cache:
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CacheSettingsScreen(),
                    ),
                  );
                  break;
                case _OverflowAction.serverUrl:
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ServerUrlScreen(isEditing: true),
                    ),
                  );
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _OverflowAction.statistics,
                child: ListTile(
                  leading: Icon(Icons.insights_outlined),
                  title: Text('Media statistics'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _OverflowAction.cache,
                child: ListTile(
                  leading: Icon(Icons.sd_storage_outlined),
                  title: Text('Offline cache'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _OverflowAction.serverUrl,
                child: ListTile(
                  leading: Icon(Icons.settings_ethernet),
                  title: Text('Server URL'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
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
                      message: _emptyMessageFor(
                        query.filter,
                        isOffline: state.isOffline,
                      ),
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
