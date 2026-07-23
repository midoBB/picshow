import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/server_connection.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

class _UnreachableApi extends ApiClient {
  _UnreachableApi()
    : super(
        connection: ServerConnection(
          serverUrls: const ['http://example.test'],
          probe: (_) async => false,
          connectivityStream: const Stream.empty(),
        ),
      );

  @override
  Future<PagedFilesResult> listFiles({
    required int page,
    int pageSize = 15,
    String order = 'created_at',
    String direction = 'desc',
    int? seed,
    String type = 'all',
  }) async => throw StateError('offline: the gallery must not call the server');
}

class _FakeOnlineNotifier extends OnlineNotifier {
  _FakeOnlineNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

MediaFile _mediaFile(String id) => MediaFile(
  id: id,
  hash: 'hash-$id',
  createdAt: DateTime.utc(2026, 1, 5, 12),
  filename: '$id.jpg',
  size: 1,
  mediaType: MediaType.image,
  mimeType: 'image/jpeg',
  isFavorite: false,
  image: MediaMeta(
    width: 100,
    height: 100,
    thumbnailWidth: 10,
    thumbnailHeight: 10,
  ),
  video: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_flicker_test')
      .path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => pathProviderDir,
      );

  test('a burst of ledger writes does not restart the offline grid', () async {
    // The startup reconcile writes one ledger row per cached file per bucket.
    // Each of those used to bump mediaCacheLedgerRevisionProvider, which the
    // offline branch of build() watches — so every row tore the provider down
    // and rebuilt it, and GalleryScreen's `asyncState.when(loading: ...)`
    // painted a full-screen spinner for each one. That is the "offline mode
    // flashes a lot before settling" the user sees.
    final files = [for (var i = 0; i < 40; i++) _mediaFile('file-$i')];
    final store = await RecentMediaStore.openInMemoryForTesting();
    await store.upsertAll(files);
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1 << 30,
    );

    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(_UnreachableApi()),
        recentMediaStoreProvider.overrideWithValue(store),
        mediaCacheBudgetProvider.overrideWithValue(budget),
        isOnlineProvider.overrideWith(() => _FakeOnlineNotifier(false)),
      ],
    );
    addTearDown(container.dispose);

    const query = GalleryQuery(order: SortOrder.createdAt);

    var loadingFrames = 0;
    final sub = container.listen(pagedFilesProvider(query), (_, next) {
      if (next.isLoading) loadingFrames++;
    });
    addTearDown(sub.close);
    await container.read(pagedFilesProvider(query).future);

    // Simulate the startup reconcile filling in the ledger.
    for (final file in files) {
      await budget.record(CacheBucket.thumb, file.id, 1000);
      await budget.record(CacheBucket.image, file.id, 10000);
    }
    await container.read(pagedFilesProvider(query).future);

    expect(
      loadingFrames,
      lessThanOrEqualTo(1),
      reason:
          'the offline grid should absorb ledger updates in place, not drop '
          'back to a loading spinner on every cached file',
    );
  });
}
