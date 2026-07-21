import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
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

  final api = ApiClient(baseUrls: const ['http://example.test']);

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
    expect(budget.knows('a'), isTrue);
    expect(budget.knows('b'), isTrue);
  });

  test('evicts oldest-added first once over budget', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    // Written in FIFO order; the manager holds real files so eviction has
    // something to remove.
    for (final id in ['first', 'second', 'third']) {
      final key = api.imageUrl(id);
      await FullImageCacheManager.instance.putFile(key, _bytes(400));
      await budget.record(CacheBucket.image, key, 400);
      // Ensure distinct addedAt timestamps.
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // 3 x 400 = 1200 > 1000, so exactly one eviction is needed.
    expect(budget.totalBytes, 800);
    expect(budget.knows(api.imageUrl('first')), isFalse);
    expect(budget.knows(api.imageUrl('second')), isTrue);
    expect(budget.knows(api.imageUrl('third')), isTrue);

    // The bytes are gone from disk too, not just from the ledger.
    expect(
      await FullImageCacheManager.instance.getFileFromCache(
        api.imageUrl('first'),
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

    expect(budget.knows('old'), isFalse);
    expect(budget.knows('new'), isTrue);
    expect(budget.knows('newest'), isTrue);
  });

  test('protects thumbnails under the floor and evicts images instead',
      () async {
    // Floor is min(10% of budget, 200MB) = 100 bytes here.
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );

    // Oldest entry is a thumbnail, so naive FIFO would drop it first.
    await ThumbCacheManager.instance.putFile('thumb-a', _bytes(50));
    await budget.record(CacheBucket.thumb, 'thumb-a', 50);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    for (final id in ['x', 'y']) {
      final key = api.imageUrl(id);
      await FullImageCacheManager.instance.putFile(key, _bytes(600));
      await budget.record(CacheBucket.image, key, 600);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // 50 + 600 + 600 = 1250 > 1000. Thumbnails total 50, under the 100-byte
    // floor, so the image added first goes instead.
    expect(budget.knows('thumb-a'), isTrue);
    expect(budget.knows(api.imageUrl('x')), isFalse);
    expect(budget.knows(api.imageUrl('y')), isTrue);
  });

  test('reconcile picks up files written outside the ledger', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );

    // Simulates a grid tile's CachedNetworkImage writing a thumbnail
    // directly, with no record() call.
    await ThumbCacheManager.instance.putFile('thumb-ghost', _bytes(120));
    expect(budget.totalBytes, 0);

    await budget.reconcile([_mediaFile('ghost')], api);

    expect(budget.knows('thumb-ghost'), isTrue);
    expect(budget.totalBytes, 120);
  });

  test('reconcile drops rows whose file is no longer on disk', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );

    final key = api.imageUrl('vanished');
    await FullImageCacheManager.instance.putFile(key, _bytes(500));
    await budget.record(CacheBucket.image, key, 500);
    expect(budget.totalBytes, 500);

    await FullImageCacheManager.instance.removeFile(key);
    await budget.reconcile([_mediaFile('vanished')], api);

    expect(budget.knows(key), isFalse);
    expect(budget.totalBytes, 0);
  });

  test('shrinking the budget evicts down to the new cap immediately',
      () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 10000,
    );

    for (final id in ['a', 'b', 'c', 'd']) {
      final key = api.imageUrl(id);
      await FullImageCacheManager.instance.putFile(key, _bytes(1000));
      await budget.record(CacheBucket.image, key, 1000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(budget.totalBytes, 4000);

    await budget.setBudgetBytes(2000);

    expect(budget.totalBytes, lessThanOrEqualTo(2000));
    // Oldest-first: 'a' and 'b' go before 'c' and 'd'.
    expect(budget.knows(api.imageUrl('a')), isFalse);
    expect(budget.knows(api.imageUrl('b')), isFalse);
    expect(budget.knows(api.imageUrl('d')), isTrue);
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
