import 'dart:async';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';

enum _FillPhaseResult { exhausted, budgetFull, cancelledOrError }

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

/// Proactively downloads media until the cache budget is full, so going
/// offline doesn't mean losing everything the user hasn't happened to scroll
/// past.
///
/// Two-phase strategy:
///
/// 1. **Favorites first, newest first** — pages
///    `type=favorite, order=created_at, direction=desc` until every favorite
///    is cached or the budget is 95 % full. Favorite videos are cached at any
///    size, bypassing the video size gate.
/// 2. **Remainder, uniform random** — if budget remains, pages
///    `type=all, order=random, seed=<stable per pass>` (single seed for the
///    whole pass so pagination is deterministic and covers the library
///    uniformly). This samples the rest of the library evenly instead of only
///    the newest items, filling the user-selected storage budget.
///
/// Deliberate restrictions:
///
/// * **WiFi/ethernet only** (unless forced from settings) — filling a
///   multi-gigabyte budget over cellular would be a nasty surprise.
/// * **Video size gate:** non-favorite videos at or above
///   [_maxPrefetchVideoBytes] (50 MB) are left to on-demand caching; favorite
///   videos bypass it. The gate is enforced in phase 2 via [shouldPrefetch].
/// * **Images before videos** within each page, since they're cheaper and the
///   bulk of a typical library.
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

    // Dedupe across phases: phase-2 type=all includes favorites again.
    final seenIds = <String>{};
    var combinedDone = 0;
    int? favTotal;
    int? allTotal;

    int combinedTotal() {
      // Before phase-2: total is favorite count. Once phase-2 has reported,
      // total is library size (allTotal) — combined progress is unique done
      // out of the whole library.
      if (allTotal != null) return allTotal!;
      return favTotal ?? 0;
    }

    // ---- Phase 1: favorites newest-first ----
    final phase1Done = await _fillPhase(
      budget: budget,
      api: api,
      store: store,
      seenIds: seenIds,
      type: 'favorite',
      order: 'created_at',
      direction: 'desc',
      seed: null,
      onProgress: (delta, total) {
        favTotal = total;
        combinedDone += delta;
        state = state.copyWith(done: combinedDone, total: combinedTotal());
      },
    );
    if (phase1Done == _FillPhaseResult.cancelledOrError) return;
    if (phase1Done == _FillPhaseResult.budgetFull) {
      state = state.copyWith(stoppedBecauseFull: true);
      return;
    }
    if (_cancelled || budget.isFull) {
      if (budget.isFull) state = state.copyWith(stoppedBecauseFull: true);
      return;
    }

    // ---- Phase 2: remainder uniformly sampled ----
    // Single stable seed for the whole pass so ORDER BY random is deterministic
    // across pages (see repository.rs: random with seed). Without a fixed seed
    // pagination would revisit the same files while never reaching others.
    final randomSeed = Random().nextInt(1 << 31);
    final phase2Done = await _fillPhase(
      budget: budget,
      api: api,
      store: store,
      seenIds: seenIds,
      type: 'all',
      order: 'random',
      direction: 'desc',
      seed: randomSeed,
      skipSeenForProgress: true,
      onProgress: (delta, total) {
        allTotal = total;
        combinedDone += delta;
        state = state.copyWith(done: combinedDone, total: combinedTotal());
      },
    );
    if (phase2Done == _FillPhaseResult.budgetFull) {
      state = state.copyWith(stoppedBecauseFull: true);
    }
  }

  /// Drives one phase of the filler, paging [type]/[order]/[seed] until the
  /// budget is full, the server reports no more pages, or a network error
  /// occurs. Returns how the phase terminated.
  Future<_FillPhaseResult> _fillPhase({
    required MediaCacheBudget budget,
    required ApiClient api,
    required RecentMediaStore store,
    required Set<String> seenIds,
    required String type,
    required String order,
    required String direction,
    required int? seed,
    bool skipSeenForProgress = false,
    required void Function(int delta, int totalRecords) onProgress,
  }) async {
    var page = 1;
    while (!_cancelled) {
      if (budget.isFull) return _FillPhaseResult.budgetFull;

      final PagedFilesResult result;
      try {
        result = await api.listFiles(
          page: page,
          pageSize: _pageSize,
          order: order,
          direction: direction,
          seed: seed,
          type: type,
        );
      } catch (_) {
        return _FillPhaseResult
            .cancelledOrError; // Offline or server trouble; next trigger retries.
      }

      unawaited(store.upsertAll(result.files));

      // Work on unique files only when the phase overlaps phase-1 (type=all
      // includes favorites). De-dupe before downloading and before counting
      // toward combined done, so progress is unique files out of total.
      final List<MediaFile> unique;
      if (skipSeenForProgress) {
        unique = [];
        for (final f in result.files) {
          if (seenIds.add(f.id)) unique.add(f);
        }
      } else {
        for (final f in result.files) {
          seenIds.add(f.id);
        }
        unique = result.files;
      }

      // Images first: a page's worth of them costs less than one large video
      // and makes far more of the library browsable offline.
      await _downloadAll(
        unique.where((f) => f.mediaType == MediaType.image).toList(),
        api,
        budget,
      );
      await _downloadAll(
        unique
            .where((f) => f.mediaType == MediaType.video && shouldPrefetch(f))
            .toList(),
        api,
        budget,
      );

      onProgress(unique.length, result.pagination.totalRecords);

      // Only this page's rows — a full reconcile would treat every file
      // outside the page as an orphan and drop it from the ledger.
      await budget.refresh(result.files);

      if (budget.isFull) return _FillPhaseResult.budgetFull;

      final next = result.pagination.nextPage;
      if (next == null) return _FillPhaseResult.exhausted;
      page = next;
    }
    return _FillPhaseResult.cancelledOrError;
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
      await budget.recordFromCache(
        blobBucket,
        file.id,
        isFavorite: file.isFavorite,
      );
    }

    if (_cancelled) return;

    if (!budget.knows(CacheBucket.thumb, file.id)) {
      await _fetch(
        () => ThumbCacheManager.instance.getSingleFile(
          api.thumbnailUrl(file.id),
          key: cacheKeyFor(CacheBucket.thumb, file.id),
        ),
      );
      await budget.recordFromCache(
        CacheBucket.thumb,
        file.id,
        isFavorite: file.isFavorite,
      );
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
