import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/pagination.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

/// Serves one fixed page at a time, so a "refresh" can be made to return a
/// completely different set of ids — exactly what a randomly-ordered,
/// server-paged endpoint does.
class _PagedFakeApi extends ApiClient {
  _PagedFakeApi(this.page);

  List<MediaFile> page;

  @override
  Future<PagedFilesResult> listFiles({
    required int page,
    int pageSize = 15,
    String order = 'created_at',
    String direction = 'desc',
    int? seed,
    String type = 'all',
  }) async {
    return PagedFilesResult(
      files: this.page,
      pagination: Pagination(
        totalRecords: 200,
        currentPage: page,
        totalPages: 14,
        prevPage: null,
        // There is more to fetch — the point being that page 1 is never
        // evidence about ids outside it.
        nextPage: page + 1,
      ),
    );
  }
}

class _FakeOnlineNotifier extends StableOnlineNotifier {
  _FakeOnlineNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

MediaFile _mediaFile(String id) {
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
    mediaType: MediaType.image,
    mimeType: 'image/jpeg',
    isFavorite: false,
    image: meta,
    video: null,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_gallery_test')
      .path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => pathProviderDir,
      );

  test(
    'refreshing does not evict cached media for files outside the new page',
    () async {
      // Regression test: build() used to diff the previously loaded list
      // against a fresh page-1 fetch and evict every id not in it. Under the
      // default random sort, page 1 is a different slice each refresh, so
      // browsing 200 photos and pulling to refresh left only one page's
      // worth cached.
      final viewed = [for (var i = 0; i < 20; i++) _mediaFile('viewed-$i')];
      final api = _PagedFakeApi(viewed);
      final store = await RecentMediaStore.openInMemoryForTesting();

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          recentMediaStoreProvider.overrideWithValue(store),
          isOnlineProvider.overrideWith(() => _FakeOnlineNotifier(true)),
        ],
      );
      addTearDown(container.dispose);

      const query = GalleryQuery(order: SortOrder.random, seed: 1);
      // The provider is autoDispose: without a live listener it would be torn
      // down between reads, so the refresh below would see no previous state
      // and the regression could not reproduce at all.
      final sub = container.listen(pagedFilesProvider(query), (_, _) {});
      addTearDown(sub.close);
      await container.read(pagedFilesProvider(query).future);

      // Everything the user browsed is on disk.
      for (final file in viewed) {
        await ThumbCacheManager.instance.putFile(
          'thumb-${file.id}',
          Uint8List(10),
        );
        await FullImageCacheManager.instance.putFile(
          api.imageUrl(file.id),
          Uint8List(10),
        );
      }

      // A refresh returns a disjoint page 1, as a reshuffled random order
      // would.
      api.page = [for (var i = 0; i < 20; i++) _mediaFile('other-$i')];
      await container.read(pagedFilesProvider(query).notifier).refresh();
      // Eviction used to be fire-and-forget, so give it a chance to land.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      for (final file in viewed) {
        expect(
          await ThumbCacheManager.instance.getFileFromCache(
            'thumb-${file.id}',
          ),
          isNotNull,
          reason: '${file.id} thumbnail should survive a refresh',
        );
        expect(
          await FullImageCacheManager.instance.getFileFromCache(
            api.imageUrl(file.id),
          ),
          isNotNull,
          reason: '${file.id} full image should survive a refresh',
        );
      }
    },
  );
}
