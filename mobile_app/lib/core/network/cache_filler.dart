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

/// Proactively downloads thumbnails and full-resolution images until the
/// cache budget is full, so going offline doesn't mean losing everything the
/// user hasn't happened to scroll past.
///
/// Two deliberate restrictions:
///
/// * **WiFi/ethernet only** (unless forced from settings) — filling a
///   multi-gigabyte budget over cellular would be a nasty surprise.
/// * **Images only.** Videos run tens to hundreds of MB each, so prefetching
///   them would spend the whole budget on a handful of files. They're still
///   cached on demand when actually watched.
class CacheFillNotifier extends Notifier<CacheFillState> {
  /// Kept small so background downloads don't starve the thumbnails and
  /// full-res images the user is waiting on right now.
  static const _concurrency = 3;
  static const _pageSize = 100;

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
    final api = ref.read(apiClientProvider);

    bootstrapped = Future(() async {
      // Bytes written by the grid's CachedNetworkImage tiles never pass
      // through this class, so the ledger starts each launch out of date.
      // Resync it against what's actually on disk before anything reads
      // totalBytes.
      await budget.reconcile(store.getAll(), api);
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
        // same files while never reaching others.
        result = await api.listFiles(
          page: page,
          pageSize: _pageSize,
          order: 'created_at',
          direction: 'desc',
        );
      } catch (_) {
        return; // Offline or server trouble; the next trigger retries.
      }

      unawaited(store.upsertAll(result.files));

      final images = result.files
          .where((f) => f.mediaType == MediaType.image)
          .toList();

      await _downloadAll(images, api, budget);
      done += result.files.length;
      state = state.copyWith(done: done, total: result.pagination.totalRecords);

      await budget.reconcile(result.files, api);

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

  Future<void> _cacheOne(
    MediaFile file,
    ApiClient api,
    MediaCacheBudget budget,
  ) async {
    final thumbKey = cacheKeyFor(CacheBucket.thumb, file.id, api);
    final imageKey = cacheKeyFor(CacheBucket.image, file.id, api);

    if (!budget.knows(thumbKey)) {
      await _fetch(
        () => ThumbCacheManager.instance.getSingleFile(
          api.thumbnailUrl(file.id),
          key: thumbKey,
        ),
      );
      await budget.recordFromCache(CacheBucket.thumb, thumbKey);
    }

    if (_cancelled || budget.isFull) return;

    if (!budget.knows(imageKey)) {
      await _fetch(
        () => FullImageCacheManager.instance.getSingleFile(api.imageUrl(file.id)),
      );
      await budget.recordFromCache(CacheBucket.image, imageKey);
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
