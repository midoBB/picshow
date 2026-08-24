import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';

class CacheFillState {
  const CacheFillState({
    this.isRunning = false,
    this.done = 0,
    this.total = 0,
    this.stoppedBecauseFull = false,
  });

  final bool isRunning;

  /// Files processed so far, and the server's reported total. [total] is 0
  /// until the first page comes back.
  final int done;
  final int total;

  /// The last run ended by hitting the budget ceiling rather than running out
  /// of files — surfaced in settings so "it stopped early" is explainable.
  final bool stoppedBecauseFull;

  CacheFillState copyWith({
    bool? isRunning,
    int? done,
    int? total,
    bool? stoppedBecauseFull,
  }) {
    return CacheFillState(
      isRunning: isRunning ?? this.isRunning,
      done: done ?? this.done,
      total: total ?? this.total,
      stoppedBecauseFull: stoppedBecauseFull ?? this.stoppedBecauseFull,
    );
  }
}

/// Proactively downloads favorite full-resolution media and thumbnails until
/// the cache budget is full, so going offline doesn't mean losing everything
/// the user hasn't happened to scroll past.
///
/// Deliberate restrictions:
///
/// * **WiFi/ethernet only** (unless forced from settings) — filling a
///   multi-gigabyte budget over cellular would be a nasty surprise.
/// * **Favorites only, newest first.** The filler pages
///   `type=favorite, order=created_at, direction=desc` and stops when every
///   favorite is cached or the budget is 95 % full. A library with no
///   favorites does no filler work — browsing-driven caching still works via
///   normal grid loads.
/// * **Favorite videos at any size.** Non-favorite oversized videos were once
///   gated by [_maxPrefetchVideoBytes] (50 MB) to avoid spending the whole
///   budget on a handful of files; favorites bypass that gate. Oversized
///   non-favorites are still cached on demand when actually watched.
///
/// Images take priority over videos within a page, since they're both far
/// cheaper and the bulk of a typical library.
class CacheFillNotifier extends Notifier<CacheFillState> {
  /// Kept small so background downloads don't starve the thumbnails and
  /// full-res images the user is waiting on right now.
  static const _concurrency = 3;
  static const _pageSize = 100;

  /// Videos at or above this size are left to on-demand caching, unless
  /// they are favorites.
  static const maxPrefetchVideoBytes = 50 * 1024 * 1024;

  /// Whether a background pass should download [file]'s full blob. Images
  /// always qualify; videos below [maxPrefetchVideoBytes] qualify; favorite
  /// videos qualify at any size (the filler is favorites-only, but the
  /// predicate is kept favorite-aware so oversized favorites are never
  /// gated).
  static bool shouldPrefetch(MediaFile file) =>
      file.isFavorite ||
      file.mediaType == MediaType.image ||
      file.size < maxPrefetchVideoBytes;

  bool _cancelled = false;
  bool _disposed = false;

  /// Completes when the startup reconcile (and the fill pass it triggers) has
  /// finished. Exposed so tests can await it instead of racing it.
  late final Future<void> bootstrapped;

  @override
  CacheFillState build() {
    // Stop as soon as the connection drops; resume when it comes back.
    ref.listen<bool>(isOnlineProvider, (_, online) {
      if (!online) {
        cancel();
      } else {
        unawaited(start());
      }
    });

    // The OS connectivity stream has usually not emitted yet when the app
    // starts, so the bootstrap pass below sees "no network type" and declines
    // to run. Retry once the first (or any later) result arrives — that's
    // also what picks up a cellular-to-WiFi switch mid-session.
    ref.listen<AsyncValue<List<ConnectivityResult>>>(
      connectivityResultProvider,
      (_, _) => unawaited(start()),
    );
    ref.onDispose(() {
      _disposed = true;
      cancel();
    });

    // Read everything needed up front: this runs detached from the build, and
    // reading a provider after the container is gone throws.
    final store = ref.read(recentMediaStoreProvider);
    final budget = ref.read(mediaCacheBudgetProvider);

    bootstrapped = Future(() async {
      // Bytes written by the grid's CachedNetworkImage tiles never pass
      // through this class, so the ledger starts each launch out of date.
      // Resync it against what's actually on disk before anything reads
      // totalBytes.
      await budget.reconcile(store.getAll());
      if (_disposed) return;
      await start();
    });

    return const CacheFillState();
  }

  void cancel() => _cancelled = true;

  bool get _onUnmeteredNetwork {
    final results =
        ref.read(connectivityResultProvider).valueOrNull ??
        const <ConnectivityResult>[];
    return results.any(
      (r) => r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet,
    );
  }

  /// Starts a fill pass. Returns immediately if one is already running, the
  /// app is offline, or the network is metered ([force] overrides only the
  /// metered check — it's the settings screen's explicit "fill now").
  Future<void> start({bool force = false}) async {
    if (_disposed || state.isRunning) return;
    if (!ref.read(isOnlineProvider)) return;
    if (!force && !_onUnmeteredNetwork) return;

    final budget = ref.read(mediaCacheBudgetProvider);
    if (budget.isFull) return;

    _cancelled = false;
    state = const CacheFillState(isRunning: true);

    try {
      await _run(budget);
    } finally {
      state = state.copyWith(isRunning: false);
    }
  }

  Future<void> _run(MediaCacheBudget budget) async {
    final api = ref.read(apiClientProvider);
    final store = ref.read(recentMediaStoreProvider);

    var page = 1;
    var done = 0;

    while (!_cancelled) {
      if (budget.isFull) {
        state = state.copyWith(stoppedBecauseFull: true);
        return;
      }

      final PagedFilesResult result;
      try {
        // Deliberately not the user's current GalleryQuery: a random seed
        // makes paging non-deterministic, so a fill pass could revisit the
        // same files while never reaching others. Favorites-only: the server
        // filters and the filler never falls back to type=all.
        result = await api.listFiles(
          page: page,
          pageSize: _pageSize,
          order: 'created_at',
          direction: 'desc',
          type: 'favorite',
        );
      } catch (_) {
        return; // Offline or server trouble; the next trigger retries.
      }

      unawaited(store.upsertAll(result.files));

      // Images first: a page's worth of them costs less than one large video
      // and makes far more of the library browsable offline.
      await _downloadAll(
        result.files.where((f) => f.mediaType == MediaType.image).toList(),
        api,
        budget,
      );
      await _downloadAll(
        result.files
            .where((f) => f.mediaType == MediaType.video && shouldPrefetch(f))
            .toList(),
        api,
        budget,
      );
      done += result.files.length;
      state = state.copyWith(done: done, total: result.pagination.totalRecords);

      // Only this page's rows — a full reconcile would treat every file
      // outside the page as an orphan and drop it from the ledger.
      await budget.refresh(result.files);

      final next = result.pagination.nextPage;
      if (next == null) return;
      page = next;
    }
  }

  /// Downloads [files] with at most [_concurrency] requests in flight, using
  /// a shared cursor rather than fixed chunks so one slow file doesn't stall
  /// the others.
  Future<void> _downloadAll(
    List<MediaFile> files,
    ApiClient api,
    MediaCacheBudget budget,
  ) async {
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || budget.isFull) return;
        final index = cursor++;
        if (index >= files.length) return;
        await _cacheOne(files[index], api, budget);
      }
    }

    await Future.wait([for (var i = 0; i < _concurrency; i++) worker()]);
  }

  /// Downloads the full blob *before* the thumbnail.
  ///
  /// The order matters at the tail of a pass, where the budget fills or the
  /// user cancels partway through a file. A thumbnail without its blob is a
  /// tile the offline grid must hide anyway; a blob without its thumbnail
  /// costs one cheap fetch to complete on the next pass. Downloading the
  /// expensive half first means an interrupted pass wastes the cheap half,
  /// not the other way round.
  Future<void> _cacheOne(
    MediaFile file,
    ApiClient api,
    MediaCacheBudget budget,
  ) async {
    final blobBucket = fullBlobBucketFor(file);

    if (!budget.knows(blobBucket, file.id)) {
      final url = blobBucket == CacheBucket.video
          ? api.videoUrl(file.id)
          : api.imageUrl(file.id);
      await _fetch(
        () => blobBucket.manager.getSingleFile(
          url,
          key: cacheKeyFor(blobBucket, file.id),
        ),
      );
      await budget.recordFromCache(blobBucket, file.id);
    }

    if (_cancelled) return;

    if (!budget.knows(CacheBucket.thumb, file.id)) {
      await _fetch(
        () => ThumbCacheManager.instance.getSingleFile(
          api.thumbnailUrl(file.id),
          key: cacheKeyFor(CacheBucket.thumb, file.id),
        ),
      );
      await budget.recordFromCache(CacheBucket.thumb, file.id);
    }
  }

  Future<void> _fetch(Future<void> Function() download) async {
    try {
      await download();
    } catch (_) {
      // Best-effort prefetch; the file just stays uncached.
    }
  }
}

final cacheFillProvider = NotifierProvider<CacheFillNotifier, CacheFillState>(
  CacheFillNotifier.new,
);
