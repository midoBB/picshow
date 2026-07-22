import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/server_connection.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';

MediaFile _mediaFile(String id, {MediaType mediaType = MediaType.image}) {
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
    size: 1,
    mediaType: mediaType,
    mimeType: mediaType == MediaType.image ? 'image/jpeg' : 'video/mp4',
    isFavorite: false,
    image: mediaType == MediaType.image ? meta : null,
    video: mediaType == MediaType.video ? meta : null,
  );
}

Uint8List _bytes(int length) => Uint8List(length);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The cache managers reach for the app support directory via path_provider
  // on first use; stub it so tests don't hang on a real platform channel.
  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_budget_test')
      .path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => pathProviderDir,
      );

  setUp(() async {
    await ThumbCacheManager.instance.emptyCache();
    await FullImageCacheManager.instance.emptyCache();
    await VideoCacheManager.instance.emptyCache();
  });

  test('stays quiet while under budget', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    await budget.record(CacheBucket.image, 'a', 300);
    await budget.record(CacheBucket.image, 'b', 300);

    expect(budget.totalBytes, 600);
    expect(budget.knows(CacheBucket.image, 'a'), isTrue);
    expect(budget.knows(CacheBucket.image, 'b'), isTrue);
  });

  test('evicts oldest-added first once over budget', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    // Written in FIFO order; the manager holds real files so eviction has
    // something to remove.
    for (final id in ['first', 'second', 'third']) {
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, id),
        _bytes(400),
      );
      await budget.record(CacheBucket.image, id, 400);
      // Ensure distinct addedAt timestamps.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // 3 x 400 = 1200 > 1000, so exactly one eviction is needed.
    expect(budget.totalBytes, 800);
    expect(budget.knows(CacheBucket.image, 'first'), isFalse);
    expect(budget.knows(CacheBucket.image, 'second'), isTrue);
    expect(budget.knows(CacheBucket.image, 'third'), isTrue);

    // The bytes are gone from disk too, not just from the ledger.
    expect(
      await FullImageCacheManager.instance.getFileFromCache(
        cacheKeyFor(CacheBucket.image, 'first'),
      ),
      isNull,
    );
  });

  test('re-recording a key keeps its place in the FIFO queue', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    await budget.record(CacheBucket.image, 'old', 400);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await budget.record(CacheBucket.image, 'new', 400);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // Touching 'old' again must not promote it past 'new'.
    await budget.record(CacheBucket.image, 'old', 400);
    await budget.record(CacheBucket.image, 'newest', 400);

    expect(budget.knows(CacheBucket.image, 'old'), isFalse);
    expect(budget.knows(CacheBucket.image, 'new'), isTrue);
    expect(budget.knows(CacheBucket.image, 'newest'), isTrue);
  });

  test('evicts a file\'s thumbnail and blob together', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    // Both halves of 'x' are recorded before 'y' arrives, so 'x' is the
    // oldest file and the one eviction must claim.
    for (final id in ['x', 'y']) {
      await ThumbCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.thumb, id),
        _bytes(50),
      );
      await budget.record(CacheBucket.thumb, id, 50);
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, id),
        _bytes(600),
      );
      await budget.record(CacheBucket.image, id, 600);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // 2 x 650 = 1300 > 1000. An earlier version spared thumbnails under a
    // reserved floor, which left 'x' listed in the offline grid as a tile
    // that could no longer be opened. Availability is all-or-nothing.
    expect(budget.knows(CacheBucket.thumb, 'x'), isFalse);
    expect(budget.knows(CacheBucket.image, 'x'), isFalse);
    expect(budget.isAvailableOffline(_mediaFile('x')), isFalse);
    expect(budget.isAvailableOffline(_mediaFile('y')), isTrue);
  });

  test('isAvailableOffline requires both the thumbnail and the blob', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );

    await budget.record(CacheBucket.thumb, 'partial', 50);
    expect(
      budget.isAvailableOffline(_mediaFile('partial')),
      isFalse,
      reason: 'a thumbnail alone is a tile that cannot be opened',
    );

    await budget.record(CacheBucket.image, 'partial', 600);
    expect(budget.isAvailableOffline(_mediaFile('partial')), isTrue);

    // A video's blob lives in its own bucket; an image row must not satisfy it.
    final clip = _mediaFile('clip', mediaType: MediaType.video);
    await budget.record(CacheBucket.thumb, 'clip', 50);
    await budget.record(CacheBucket.image, 'clip', 600);
    expect(budget.isAvailableOffline(clip), isFalse);
    await budget.record(CacheBucket.video, 'clip', 600);
    expect(budget.isAvailableOffline(clip), isTrue);
  });

  test('availability survives a change of server address', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final file = _mediaFile('stable');

    final lan = ApiClient(
      connection: ServerConnection(
        serverUrls: const ['http://192.168.1.20:8281'],
        probe: (_) async => true,
        connectivityStream: const Stream.empty(),
      ),
    );
    final public = ApiClient(
      connection: ServerConnection(
        serverUrls: const ['https://picshow.example.com'],
        probe: (_) async => true,
        connectivityStream: const Stream.empty(),
      ),
    );

    // Cached while on the LAN.
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, file.id),
      _bytes(50),
    );
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, file.id),
      _bytes(600),
    );
    await budget.reconcile([file]);
    expect(budget.isAvailableOffline(file), isTrue);

    // The URLs genuinely differ between the two addresses...
    expect(lan.imageUrl(file.id), isNot(public.imageUrl(file.id)));
    // ...but the cache key does not, which is the whole point: keying blobs
    // by URL is what made photos vanish on failover while their thumbnails
    // (always keyed by id) survived.
    await budget.reconcile([file]);
    expect(budget.isAvailableOffline(file), isTrue);
    expect(budget.totalBytes, 650);
  });

  test('reconcile picks up files written outside the ledger', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );

    // Simulates a grid tile's CachedNetworkImage writing a thumbnail
    // directly, with no record() call.
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, 'ghost'),
      _bytes(120),
    );
    expect(budget.totalBytes, 0);

    await budget.reconcile([_mediaFile('ghost')]);

    expect(budget.knows(CacheBucket.thumb, 'ghost'), isTrue);
    expect(budget.totalBytes, 120);
  });

  test('reconcile drops rows whose file is no longer on disk', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );

    const id = 'vanished';
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, id),
      _bytes(500),
    );
    await budget.record(CacheBucket.image, id, 500);
    expect(budget.totalBytes, 500);

    await FullImageCacheManager.instance.removeFile(
      cacheKeyFor(CacheBucket.image, id),
    );
    await budget.reconcile([_mediaFile(id)]);

    expect(budget.knows(CacheBucket.image, id), isFalse);
    expect(budget.totalBytes, 0);
  });

  test('shrinking the budget evicts down to the new cap immediately',
      () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 10000,
    );

    for (final id in ['a', 'b', 'c', 'd']) {
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, id),
        _bytes(1000),
      );
      await budget.record(CacheBucket.image, id, 1000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(budget.totalBytes, 4000);

    await budget.setBudgetBytes(2000);

    expect(budget.totalBytes, lessThanOrEqualTo(2000));
    // Oldest-first: 'a' and 'b' go before 'c' and 'd'.
    expect(budget.knows(CacheBucket.image, 'a'), isFalse);
    expect(budget.knows(CacheBucket.image, 'b'), isFalse);
    expect(budget.knows(CacheBucket.image, 'd'), isTrue);
  });

  test('isFull reports the ceiling the filler stops at', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    await budget.record(CacheBucket.image, 'a', 900);
    expect(budget.isFull, isFalse);

    await budget.record(CacheBucket.image, 'b', 60);
    expect(budget.isFull, isTrue);
  });
}
