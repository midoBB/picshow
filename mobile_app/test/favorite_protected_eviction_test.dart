import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';

MediaFile _mediaFile(
  String id, {
  MediaType mediaType = MediaType.image,
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
    size: 1,
    mediaType: mediaType,
    mimeType: mediaType == MediaType.image ? 'image/jpeg' : 'video/mp4',
    isFavorite: isFavorite,
    image: mediaType == MediaType.image ? meta : null,
    video: mediaType == MediaType.video ? meta : null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_fav_test')
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

  test('fill budget with mix fav/non-fav evicts non-fav first', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );
    await budget.record(CacheBucket.image, 'fav-old', 400, isFavorite: true);
    await Future.delayed(const Duration(milliseconds: 5));
    await budget.record(
      CacheBucket.image,
      'nonfav-mid',
      400,
      isFavorite: false,
    );
    await Future.delayed(const Duration(milliseconds: 5));
    await budget.record(
      CacheBucket.image,
      'nonfav-new',
      400,
      isFavorite: false,
    );
    expect(budget.totalBytes, 800);
    expect(
      budget.knows(CacheBucket.image, 'nonfav-mid'),
      isFalse,
      reason: 'oldest non-fav should evict first',
    );
    expect(budget.knows(CacheBucket.image, 'fav-old'), isTrue);
    expect(budget.knows(CacheBucket.image, 'nonfav-new'), isTrue);
  });

  test('mix with whole-file thumb+blob evicts non-fav file together', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1300,
    );
    // File A fav: thumb 50+image 600=650 earliest
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, 'fav-A'),
      Uint8List(50),
    );
    await budget.record(CacheBucket.thumb, 'fav-A', 50, isFavorite: true);
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, 'fav-A'),
      Uint8List(600),
    );
    await budget.record(CacheBucket.image, 'fav-A', 600, isFavorite: true);
    await Future.delayed(const Duration(milliseconds: 5));
    // File B non-fav
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, 'non-B'),
      Uint8List(50),
    );
    await budget.record(CacheBucket.thumb, 'non-B', 50, isFavorite: false);
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, 'non-B'),
      Uint8List(600),
    );
    await budget.record(CacheBucket.image, 'non-B', 600, isFavorite: false);
    await Future.delayed(const Duration(milliseconds: 5));
    // File C fav newest
    await ThumbCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.thumb, 'fav-C'),
      Uint8List(50),
    );
    await budget.record(CacheBucket.thumb, 'fav-C', 50, isFavorite: true);
    await FullImageCacheManager.instance.putFile(
      cacheKeyFor(CacheBucket.image, 'fav-C'),
      Uint8List(600),
    );
    await budget.record(CacheBucket.image, 'fav-C', 600, isFavorite: true);

    // Total after 3 files would be 1950 >1300, enforce evicts oldest non-fav B first => 1300 left (A+C)
    expect(budget.knows(CacheBucket.thumb, 'non-B'), isFalse);
    expect(budget.knows(CacheBucket.image, 'non-B'), isFalse);
    expect(budget.isAvailableOffline(_mediaFile('non-B')), isFalse);
    expect(budget.knows(CacheBucket.thumb, 'fav-A'), isTrue);
    expect(budget.knows(CacheBucket.image, 'fav-A'), isTrue);
    expect(budget.knows(CacheBucket.thumb, 'fav-C'), isTrue);
    expect(budget.knows(CacheBucket.image, 'fav-C'), isTrue);
    expect(budget.isAvailableOffline(_mediaFile('fav-A')), isTrue);
    expect(budget.isAvailableOffline(_mediaFile('fav-C')), isTrue);
  });

  test('all-fav budget evicts oldest fav FIFO', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 1000,
    );
    for (final id in ['fav1', 'fav2', 'fav3']) {
      await budget.record(CacheBucket.image, id, 400, isFavorite: true);
      await Future.delayed(const Duration(milliseconds: 5));
    }
    expect(budget.knows(CacheBucket.image, 'fav1'), isFalse);
    expect(budget.knows(CacheBucket.image, 'fav2'), isTrue);
    expect(budget.knows(CacheBucket.image, 'fav3'), isTrue);
  });

  test(
    'toggle from non-fav to fav changes eviction order and preserves addedAt',
    () async {
      final budget = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 1000,
      );
      await budget.record(CacheBucket.image, 'non-old', 400, isFavorite: false);
      await Future.delayed(const Duration(milliseconds: 5));
      await budget.record(CacheBucket.image, 'non-mid', 400, isFavorite: false);
      await Future.delayed(const Duration(milliseconds: 5));
      await budget.record(CacheBucket.image, 'fav-new', 400, isFavorite: true);
      expect(budget.knows(CacheBucket.image, 'non-old'), isFalse);
      expect(budget.knows(CacheBucket.image, 'non-mid'), isTrue);
      expect(budget.knows(CacheBucket.image, 'fav-new'), isTrue);

      final budget2 = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 1200,
      );
      await budget2.record(
        CacheBucket.image,
        'A-non-oldest',
        400,
        isFavorite: false,
      );
      await Future.delayed(const Duration(milliseconds: 5));
      await budget2.record(
        CacheBucket.image,
        'B-non-middle',
        400,
        isFavorite: false,
      );
      await Future.delayed(const Duration(milliseconds: 5));
      await budget2.record(
        CacheBucket.image,
        'C-fav-newest',
        400,
        isFavorite: true,
      );
      expect(budget2.totalBytes, 1200);
      final addedBefore = budget2.debugAddedAt(
        CacheBucket.image,
        'B-non-middle',
      );
      await budget2.updateFavorite('B-non-middle', true);
      final addedAfter = budget2.debugAddedAt(
        CacheBucket.image,
        'B-non-middle',
      );
      expect(
        addedBefore,
        addedAfter,
        reason: 'updateFavorite must not move addedAt',
      );
      expect(budget2.debugIsFavorite(CacheBucket.image, 'B-non-middle'), true);
      await Future.delayed(const Duration(milliseconds: 5));
      await budget2.record(
        CacheBucket.image,
        'D-fav-brandnew',
        400,
        isFavorite: true,
      );
      expect(
        budget2.knows(CacheBucket.image, 'A-non-oldest'),
        isFalse,
        reason: 'oldest non-fav should still be A',
      );
      expect(
        budget2.knows(CacheBucket.image, 'B-non-middle'),
        isTrue,
        reason: 'B was toggled to fav, so protected',
      );
      expect(budget2.knows(CacheBucket.image, 'C-fav-newest'), isTrue);
      expect(budget2.knows(CacheBucket.image, 'D-fav-brandnew'), isTrue);
    },
  );

  test('updateFavorite does not move addedAt', () async {
    final tiny = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 300,
    );
    await tiny.record(CacheBucket.image, 'old-nonfav', 150, isFavorite: false);
    await Future.delayed(const Duration(milliseconds: 10));
    await tiny.record(
      CacheBucket.image,
      'new-nonfav-to-be-fav',
      150,
      isFavorite: false,
    );
    final before = tiny.debugAddedAt(CacheBucket.image, 'new-nonfav-to-be-fav');
    await tiny.updateFavorite('new-nonfav-to-be-fav', true);
    final after = tiny.debugAddedAt(CacheBucket.image, 'new-nonfav-to-be-fav');
    expect(before, after);
    await tiny.record(CacheBucket.image, 'newest-fav', 150, isFavorite: true);
    expect(tiny.knows(CacheBucket.image, 'old-nonfav'), isFalse);
    expect(tiny.knows(CacheBucket.image, 'new-nonfav-to-be-fav'), isTrue);
    expect(tiny.knows(CacheBucket.image, 'newest-fav'), isTrue);
  });

  test(
    'refresh and reconcile write isFavorite and old rows default non-fav',
    () async {
      final small = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 1000,
      );
      await small.record(
        CacheBucket.image,
        'old-no-flag',
        400,
      ); // defaults false -> non-fav
      await Future.delayed(const Duration(milliseconds: 5));
      await small.record(CacheBucket.image, 'fav2', 400, isFavorite: true);
      await Future.delayed(const Duration(milliseconds: 5));
      await small.record(CacheBucket.image, 'fav3', 400, isFavorite: true);
      expect(
        small.knows(CacheBucket.image, 'old-no-flag'),
        isFalse,
        reason: 'old row without flag treated as non-fav, evicted first',
      );
      // Also test refresh writes isFavorite
      final budget2 = await MediaCacheBudget.openInMemoryForTesting(
        budgetBytes: 100000,
      );
      final fav = _mediaFile('fav-x', isFavorite: true);
      final nonFav = _mediaFile('non-x', isFavorite: false);
      // need disk entries for refresh to read bytes
      await ThumbCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.thumb, fav.id),
        Uint8List(10),
      );
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, fav.id),
        Uint8List(10),
      );
      await ThumbCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.thumb, nonFav.id),
        Uint8List(10),
      );
      await FullImageCacheManager.instance.putFile(
        cacheKeyFor(CacheBucket.image, nonFav.id),
        Uint8List(10),
      );
      await budget2.refresh([fav, nonFav]);
      expect(budget2.debugIsFavorite(CacheBucket.thumb, fav.id), true);
      expect(budget2.debugIsFavorite(CacheBucket.image, fav.id), true);
      expect(budget2.debugIsFavorite(CacheBucket.thumb, nonFav.id), false);
    },
  );

  test('backfill sets isFavorite from store', () async {
    final budget = await MediaCacheBudget.openInMemoryForTesting(
      budgetBytes: 100000,
    );
    final store = await RecentMediaStore.openInMemoryForTesting();
    final favFile = _mediaFile('fav-id', isFavorite: true);
    final nonFavFile = _mediaFile('non-id', isFavorite: false);
    await store.upsertAll([favFile, nonFavFile]);
    // inject raw rows lacking isFavorite via debug helper
    await budget.debugPutRaw(CacheBucket.image, 'old-missing', {
      'id': 'old-missing',
      'bucket': 'image',
      'bytes': 200,
      'addedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await budget.debugPutRaw(CacheBucket.image, 'fav-id', {
      'id': 'fav-id',
      'bucket': 'image',
      'bytes': 200,
      'addedAt': DateTime.now().millisecondsSinceEpoch + 1000,
    });
    final favMap = {for (final f in store.getAll()) f.id: f.isFavorite};
    final count = await budget.backfillIsFavorite((id) => favMap[id]);
    expect(count, 2);
    expect(budget.debugIsFavorite(CacheBucket.image, 'old-missing'), false);
    expect(budget.debugIsFavorite(CacheBucket.image, 'fav-id'), true);
    // row with existing flag should be skipped (not overwritten)
    await budget.record(
      CacheBucket.image,
      'already-fav',
      100,
      isFavorite: true,
    );
    final count2 = await budget.backfillIsFavorite((id) => favMap[id]);
    expect(count2, 0);
  });
}
