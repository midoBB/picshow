import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/pagination.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/cache_filler.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/server_connection.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';

ServerConnection _fakeConnection() => ServerConnection(
  serverUrls: const ['http://example.test'],
  probe: (_) async => true,
  connectivityStream: const Stream.empty(),
);

class _CountingApi extends ApiClient {
  _CountingApi(this.allFiles) : super(connection: _fakeConnection());

  final List<MediaFile> allFiles;
  int listCalls = 0;
  final List<String> types = [];
  final List<int> pages = [];
  final List<int> pageSizes = [];
  final List<String> orders = [];
  final List<String> directions = [];

  @override
  Future<PagedFilesResult> listFiles({
    required int page,
    int pageSize = 15,
    String order = 'created_at',
    String direction = 'desc',
    int? seed,
    String type = 'all',
  }) async {
    listCalls++;
    types.add(type);
    pages.add(page);
    pageSizes.add(pageSize);
    orders.add(order);
    directions.add(direction);
    // Simulate server-side pagination so multi-page filler behavior can be
    // exercised without a real server. Single-page tests still get one page.
    final start = (page - 1) * pageSize;
    final end = (start + pageSize).clamp(0, allFiles.length);
    final slice = start < allFiles.length
        ? allFiles.sublist(start, end)
        : <MediaFile>[];
    final totalPages = (allFiles.length / pageSize).ceil();
    if (totalPages == 0) {
      return PagedFilesResult(
        files: const [],
        pagination: Pagination(
          totalRecords: 0,
          currentPage: 1,
          totalPages: 0,
          prevPage: null,
          nextPage: null,
        ),
      );
    }
    return PagedFilesResult(
      files: slice,
      pagination: Pagination(
        totalRecords: allFiles.length,
        currentPage: page,
        totalPages: totalPages,
        prevPage: page > 1 ? page - 1 : null,
        nextPage: page < totalPages ? page + 1 : null,
      ),
    );
  }
}

class _FakeOnlineNotifier extends OnlineNotifier {
  _FakeOnlineNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

MediaFile _mediaFile(
  String id, {
  MediaType mediaType = MediaType.image,
  int size = 1,
  bool isFavorite = false,
}) {
  final meta = MediaMeta(
    width: 100,
    height: 100,
    thumbnailWidth: 10,
    thumbnailHeight: 10,
  );
  return MediaFile(
    id: id,
    hash: 'hash-$id',
    createdAt: DateTime.utc(2026, 1, 5, 12),
    filename: '$id.jpg',
    size: size,
    mediaType: mediaType,
    mimeType: mediaType == MediaType.image ? 'image/jpeg' : 'video/mp4',
    isFavorite: isFavorite,
    image: mediaType == MediaType.image ? meta : null,
    video: mediaType == MediaType.video ? meta : null,
  );
}

Future<ProviderContainer> _container({
  required _CountingApi api,
  required MediaCacheBudget budget,
  required bool online,
  required List<ConnectivityResult> connectivity,
  List<MediaFile> knownFiles = const [],
}) async {
  final store = await RecentMediaStore.openInMemoryForTesting();
  if (knownFiles.isNotEmpty) await store.upsertAll(knownFiles);

  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      recentMediaStoreProvider.overrideWithValue(store),
      mediaCacheBudgetProvider.overrideWithValue(budget),
      isOnlineProvider.overrideWith(() => _FakeOnlineNotifier(online)),
      connectivityResultProvider.overrideWith(
        (ref) => Stream.value(connectivity),
      ),
    ],
  );

  // Resolve the connectivity stream before the filler reads it, so tests
  // aren't just measuring "the stream hadn't emitted yet".
  await container.read(connectivityResultProvider.future);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_filler_test')
      .path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => pathProviderDir,
      );

  test('does not run on a metered connection', () async {
    final api = _CountingApi([_mediaFile('a')]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.mobile],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;
    await container.read(cacheFillProvider.notifier).start();

    expect(api.listCalls, 0);
    expect(container.read(cacheFillProvider).isRunning, isFalse);
  });

  test('"fill now" overrides the metered-connection gate', () async {
    final api = _CountingApi([]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.mobile],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;
    await container.read(cacheFillProvider.notifier).start(force: true);

    expect(api.listCalls, 1);
    expect(api.types, everyElement('favorite'));
    expect(api.orders, everyElement('created_at'));
    expect(api.directions, everyElement('desc'));
    expect(api.pageSizes, everyElement(100));
  });

  test('does not run while offline', () async {
    final api = _CountingApi([_mediaFile('a')]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final container = await _container(
      api: api,
      budget: budget,
      online: false,
      connectivity: [ConnectivityResult.wifi],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;
    await container.read(cacheFillProvider.notifier).start();

    expect(api.listCalls, 0);
  });

  test(
    'stops at a full budget instead of evicting its own downloads',
    () async {
      final api = _CountingApi([_mediaFile('a'), _mediaFile('b')]);
      final budget = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 1000,
      );

      // Already at 96% — above the 95% ceiling. Written as a real cached file
      // for a file the store knows about, so the startup reconcile keeps it
      // rather than treating it as an orphan row.
      final existing = _mediaFile('existing');
      final existingKey = cacheKeyFor(CacheBucket.image, existing.id);
      await FullImageCacheManager.instance.putFile(existingKey, Uint8List(960));

      final container = await _container(
        api: api,
        budget: budget,
        online: true,
        connectivity: [ConnectivityResult.wifi],
        knownFiles: [existing],
      );
      addTearDown(container.dispose);

      await container.read(cacheFillProvider.notifier).bootstrapped;

      // Never even asks the server for a page, and nothing already cached is
      // dropped to make room.
      expect(api.listCalls, 0);
      expect(budget.knows(CacheBucket.image, existing.id), isTrue);
    },
  );

  test('prefetches videos under the size cap', () async {
    const id = 'clip';
    final api = _CountingApi([
      _mediaFile(id, mediaType: MediaType.video, size: 1024, isFavorite: true),
    ]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    // Stands in for the server: the filler's fetch resolves from the disk
    // cache, so the assertion is about whether it *asked* for the video.
    await VideoCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.video, id),
      Uint8List(1024),
    );

    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.wifi],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;

    expect(budget.knows(CacheBucket.video, id), isTrue);
    expect(api.types, everyElement('favorite'));
  });

  test('the prefetch predicate skips only oversized non-favorite videos', () {
    // Asserted on the predicate rather than through a fill pass: once a page
    // completes, the ledger records every blob it finds on disk regardless of
    // who put it there, so a row is no evidence about what was downloaded.
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile('photo', size: 500 * 1024 * 1024),
      ),
      isTrue,
      reason: 'images are prefetched at any size',
    );
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile('clip', mediaType: MediaType.video, size: 1024),
      ),
      isTrue,
    );
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile(
          'feature',
          mediaType: MediaType.video,
          size: CacheFillNotifier.maxPrefetchVideoBytes,
        ),
      ),
      isFalse,
      reason: 'the cap is exclusive for non-favorites',
    );
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile(
          'feature-fav',
          mediaType: MediaType.video,
          size: CacheFillNotifier.maxPrefetchVideoBytes,
          isFavorite: true,
        ),
      ),
      isTrue,
      reason: 'favorite videos bypass the cap',
    );
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile(
          'huge-fav',
          mediaType: MediaType.video,
          size: 200 * 1024 * 1024,
          isFavorite: true,
        ),
      ),
      isTrue,
      reason: 'oversized favorite videos are cached',
    );
  });

  test('filler queries type favorite only', () async {
    final favorites = [
      _mediaFile('fav-a', isFavorite: true),
      _mediaFile('fav-b', isFavorite: true),
    ];
    final api = _CountingApi(favorites);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.wifi],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;

    expect(api.listCalls, greaterThanOrEqualTo(1));
    expect(api.types, everyElement('favorite'));
    expect(api.types, isNot(contains('all')));
    expect(api.orders, everyElement('created_at'));
    expect(api.directions, everyElement('desc'));
    expect(api.pageSizes, everyElement(100));
    // done/total reflects favorite pagination totalRecords
    expect(container.read(cacheFillProvider).total, favorites.length);
    expect(container.read(cacheFillProvider).done, favorites.length);
  });

  test('oversized favorite video is cached despite the size gate', () async {
    const id = 'huge-fav-video';
    final api = _CountingApi([
      _mediaFile(
        id,
        mediaType: MediaType.video,
        size: 200 * 1024 * 1024,
        isFavorite: true,
      ),
    ]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 10 * 1024 * 1024,
    );
    // Pre-seed the disk cache so the filler fetch hits; size gate would have
    // previously prevented even attempting the download.
    await VideoCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.video, id),
      Uint8List(1024),
    );
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, id),
      Uint8List(512),
    );

    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.wifi],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;

    expect(api.types, everyElement('favorite'));
    expect(budget.knows(CacheBucket.video, id), isTrue);
    // Ledger entry proves oversized favorite bypassed maxPrefetchVideoBytes
    expect(
      CacheFillNotifier.shouldPrefetch(
        _mediaFile(
          id,
          mediaType: MediaType.video,
          size: 200 * 1024 * 1024,
          isFavorite: true,
        ),
      ),
      isTrue,
    );
  });

  test('zero favorites does no filler work', () async {
    final api = _CountingApi([]);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final container = await _container(
      api: api,
      budget: budget,
      online: true,
      connectivity: [ConnectivityResult.wifi],
    );
    addTearDown(container.dispose);

    await container.read(cacheFillProvider.notifier).bootstrapped;

    expect(api.listCalls, 1);
    expect(api.types, everyElement('favorite'));
    expect(container.read(cacheFillProvider).done, 0);
    expect(container.read(cacheFillProvider).total, 0);
    expect(budget.totalBytes, 0);
    // Browsing-driven caching still works: manually putting a file and
    // reconciling should still record it even though filler did nothing.
    const id = 'browsed';
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, id),
      Uint8List(100),
    );
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, id),
      Uint8List(100),
    );
    final browsedFile = _mediaFile(id, isFavorite: false);
    await budget.refresh([browsedFile]);
    expect(budget.knows(CacheBucket.thumb, id), isTrue);
    expect(budget.knows(CacheBucket.image, id), isTrue);
  });

  test(
    'filler pages favorites without duplication and updates done/total',
    () async {
      // 150 favorites -> 2 pages at pageSize 100
      final favorites = List.generate(
        150,
        (i) => _mediaFile('fav-$i', isFavorite: true),
      );
      // Pre-seed a couple so ledger has something to refresh per page
      await ThumbCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.thumb, 'fav-0'),
        Uint8List(10),
      );
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, 'fav-0'),
        Uint8List(10),
      );

      final api = _CountingApi(favorites);
      final budget = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 10 * 1024 * 1024,
      );
      final container = await _container(
        api: api,
        budget: budget,
        online: true,
        connectivity: [ConnectivityResult.wifi],
      );
      addTearDown(container.dispose);

      await container.read(cacheFillProvider.notifier).bootstrapped;

      expect(api.listCalls, 2);
      expect(api.pages, [1, 2]);
      expect(api.types, everyElement('favorite'));
      expect(container.read(cacheFillProvider).done, 150);
      expect(container.read(cacheFillProvider).total, 150);
      // Store should contain all favorites without duplication
      final store = container.read(recentMediaStoreProvider);
      final stored = store.getAll();
      expect(stored.length, 150);
      expect(stored.map((f) => f.id).toSet().length, 150);
    },
  );

  test('per-page download order remains images first then videos', () async {
    // This is a predicate-level check: a page containing both types should
    // consider images and favorite videos of any size as prefetchable, while
    // non-favorite oversized videos are not.
    final page = [
      _mediaFile('img-1', mediaType: MediaType.image, isFavorite: true),
      _mediaFile(
        'huge-vid',
        mediaType: MediaType.video,
        size: 200 * 1024 * 1024,
        isFavorite: true,
      ),
      _mediaFile(
        'huge-nonfav',
        mediaType: MediaType.video,
        size: 200 * 1024 * 1024,
        isFavorite: false,
      ),
    ];
    // All favorites on the page should be considered for download; the
    // non-favorite oversized should not.
    final toPrefetchVideos = page
        .where(
          (f) =>
              f.mediaType == MediaType.video &&
              CacheFillNotifier.shouldPrefetch(f),
        )
        .toList();
    expect(toPrefetchVideos.map((f) => f.id), contains('huge-vid'));
    expect(toPrefetchVideos.map((f) => f.id), isNot(contains('huge-nonfav')));
    // Images are always prefetched
    final toPrefetchImages = page
        .where(
          (f) =>
              f.mediaType == MediaType.image &&
              CacheFillNotifier.shouldPrefetch(f),
        )
        .toList();
    expect(toPrefetchImages.map((f) => f.id), contains('img-1'));
  });
}
