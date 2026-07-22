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
  _CountingApi(this.files) : super(connection: _fakeConnection());

  final List<MediaFile> files;
  int listCalls = 0;

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
    return PagedFilesResult(
      files: files,
      pagination: Pagination(
        totalRecords: files.length,
        currentPage: page,
        totalPages: 1,
        prevPage: null,
        nextPage: null,
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
    isFavorite: false,
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

  test('stops at a full budget instead of evicting its own downloads',
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
  });

  test('prefetches videos under the size cap', () async {
    const id = 'clip';
    final api = _CountingApi([
      _mediaFile(id, mediaType: MediaType.video, size: 1024),
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
  });

  test('the prefetch predicate skips only oversized videos', () {
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
      reason: 'the cap is exclusive',
    );
  });
}
