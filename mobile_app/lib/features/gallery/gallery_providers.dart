import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/media_cache_evictor.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/widgets/toasts.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

final galleryQueryProvider = StateProvider<GalleryQuery>(
  (ref) => GalleryQuery(seed: Random().nextInt(1 << 31)),
);

final mediaStatsProvider = FutureProvider.autoDispose(
  (ref) => ref.watch(apiClientProvider).fetchStats(),
);

class PagedFilesState {
  const PagedFilesState({
    required this.files,
    required this.nextPage,
    required this.isLoadingMore,
  });

  final List<MediaFile> files;
  final int? nextPage;
  final bool isLoadingMore;

  bool get hasMore => nextPage != null;

  PagedFilesState copyWith({
    List<MediaFile>? files,
    int? nextPage,
    bool clearNextPage = false,
    bool? isLoadingMore,
  }) {
    return PagedFilesState(
      files: files ?? this.files,
      nextPage: clearNextPage ? null : (nextPage ?? this.nextPage),
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

class PagedFilesNotifier
    extends AutoDisposeFamilyAsyncNotifier<PagedFilesState, GalleryQuery> {
  final Set<String> _favoriteInFlight = {};

  @override
  Future<PagedFilesState> build(GalleryQuery arg) async {
    final api = ref.watch(apiClientProvider);

    // Best-effort: if a previous fetch is available (e.g. this is a
    // refresh), diff ids to evict disk-cached media for files that have
    // disappeared server-side. See MediaCacheEvictor for details.
    List<MediaFile>? previousFiles;
    try {
      previousFiles = state.valueOrNull?.files;
    } catch (_) {
      previousFiles = null;
    }

    final result = await api.listFiles(
      page: 1,
      order: arg.order.apiValue,
      direction: arg.direction.apiValue,
      seed: arg.seed,
      type: arg.filter.apiValue,
    );

    if (previousFiles != null) {
      final newIds = result.files.map((f) => f.id).toSet();
      final vanishedIds = previousFiles
          .map((f) => f.id)
          .where((id) => !newIds.contains(id));
      final evictor = MediaCacheEvictor(api);
      for (final id in vanishedIds) {
        unawaited(evictor.evict(id));
      }
    }

    return PagedFilesState(
      files: result.files,
      nextPage: result.pagination.nextPage,
      isLoadingMore: false,
    );
  }

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.isLoadingMore || !current.hasMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true));
    final api = ref.read(apiClientProvider);
    try {
      final result = await api.listFiles(
        page: current.nextPage!,
        order: arg.order.apiValue,
        direction: arg.direction.apiValue,
        seed: arg.seed,
        type: arg.filter.apiValue,
      );
      final latest = state.valueOrNull ?? current;
      state = AsyncData(
        latest.copyWith(
          files: [...latest.files, ...result.files],
          nextPage: result.pagination.nextPage,
          clearNextPage: result.pagination.nextPage == null,
          isLoadingMore: false,
        ),
      );
    } catch (_) {
      final latest = state.valueOrNull ?? current;
      state = AsyncData(latest.copyWith(isLoadingMore: false));
      showToast('Failed to load more', isError: true);
    }
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  Future<void> toggleFavorite(String id) async {
    final current = state.valueOrNull;
    if (current == null || _favoriteInFlight.contains(id)) return;

    final index = current.files.indexWhere((f) => f.id == id);
    if (index == -1) return;

    _favoriteInFlight.add(id);
    final original = current.files[index];
    final optimistic = [...current.files];
    final shouldRemoveFromFavorites =
        arg.filter == MediaFilter.favorite && original.isFavorite;
    if (shouldRemoveFromFavorites) {
      optimistic.removeAt(index);
    } else {
      optimistic[index] = original.copyWith(isFavorite: !original.isFavorite);
    }
    state = AsyncData(current.copyWith(files: optimistic));

    final api = ref.read(apiClientProvider);
    try {
      await api.toggleFavorite(id);
    } catch (_) {
      final latest = state.valueOrNull;
      if (latest != null) {
        final rollbackIndex = latest.files.indexWhere((f) => f.id == id);
        if (shouldRemoveFromFavorites && rollbackIndex == -1) {
          final rolledBack = [...latest.files];
          rolledBack.insert(
            index.clamp(0, rolledBack.length).toInt(),
            original,
          );
          state = AsyncData(latest.copyWith(files: rolledBack));
        } else if (rollbackIndex != -1) {
          final rolledBack = [...latest.files];
          rolledBack[rollbackIndex] = original;
          state = AsyncData(latest.copyWith(files: rolledBack));
        }
      }
      showToast('Failed to update favorite', isError: true);
    } finally {
      _favoriteInFlight.remove(id);
    }
  }
}

final pagedFilesProvider = AsyncNotifierProvider.autoDispose
    .family<PagedFilesNotifier, PagedFilesState, GalleryQuery>(
      PagedFilesNotifier.new,
    );
