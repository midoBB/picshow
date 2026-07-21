import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/media_stats.dart';
import 'package:picshow_mobile/core/models/pagination.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/network/thumb_cache.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient(this.files);

  List<MediaFile> files;
  final toggledIds = <String>[];

  @override
  Future<PagedFilesResult> listFiles({
    required int page,
    int pageSize = 15,
    String order = 'created_at',
    String direction = 'desc',
    int? seed,
    String type = 'all',
  }) async {
    final filtered = switch (type) {
      'favorite' => files.where((file) => file.isFavorite).toList(),
      'image' =>
        files.where((file) => file.mediaType == MediaType.image).toList(),
      'video' =>
        files.where((file) => file.mediaType == MediaType.video).toList(),
      _ => files,
    };

    return PagedFilesResult(
      files: filtered,
      pagination: Pagination(
        totalRecords: filtered.length,
        currentPage: 1,
        totalPages: 1,
        prevPage: null,
        nextPage: null,
      ),
    );
  }

  @override
  Future<void> toggleFavorite(String id) async {
    toggledIds.add(id);
    files = [
      for (final file in files)
        if (file.id == id)
          file.copyWith(isFavorite: !file.isFavorite)
        else
          file,
    ];
  }

  @override
  Future<bool> getFavorite(String id) async {
    return files.firstWhere((file) => file.id == id).isFavorite;
  }
}

// isOnlineProvider is a NotifierProvider<StableOnlineNotifier, bool>, so
// overrideWith requires a StableOnlineNotifier subclass — these bypass the
// real connectivity-stream/debounce wiring in build() for direct control.
class _FakeOnlineNotifier extends StableOnlineNotifier {
  _FakeOnlineNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

Override _online(bool value) =>
    isOnlineProvider.overrideWith(() => _FakeOnlineNotifier(value));

/// Like [_FakeOnlineNotifier], but its value can be flipped mid-test to
/// simulate a reconnect without recreating the container.
class _ControllableOnlineNotifier extends StableOnlineNotifier {
  _ControllableOnlineNotifier(this._initial);

  final bool _initial;

  @override
  bool build() => _initial;

  void setOnline(bool value) => state = value;
}

MediaFile _mediaFile({
  required String id,
  required bool isFavorite,
  MediaType mediaType = MediaType.image,
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

Future<ProviderContainer> _containerWith(ApiClient api) async {
  final store = await RecentMediaStore.openInMemoryForTesting();
  return ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      recentMediaStoreProvider.overrideWithValue(store),
      _online(true),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ThumbCacheManager (used by RecentMediaStore.queryOfflineWithThumbs)
  // reaches for the app support directory via path_provider on first use;
  // stub it out so tests don't hang waiting on a real platform channel.
  final pathProviderDir = Directory.systemTemp
      .createTempSync('path_provider_test')
      .path;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => pathProviderDir,
      );

  test('MediaStats.fromJson parses server totals', () {
    final stats = MediaStats.fromJson({
      'count': 24,
      'image_count': 18,
      'video_count': 6,
      'favorite_count': 4,
      'is_processing': false,
    });

    expect(stats.totalCount, 24);
    expect(stats.imageCount, 18);
    expect(stats.videoCount, 6);
    expect(stats.favoriteCount, 4);
  });

  group('MediaFile.fromJson', () {
    test('parses an image file', () {
      final file = MediaFile.fromJson({
        'Id': 'abc-123',
        'Hash': 'deadbeef',
        'CreatedAt': '2026-01-05T12:00:00Z',
        'Filename': 'photo.jpg',
        'Size': 12345,
        'MediaType': 'image',
        'MimeType': 'image/jpeg',
        'IsFavorite': false,
        'Image': {
          'Width': 4000,
          'Height': 3000,
          'ThumbnailWidth': 300,
          'ThumbnailHeight': 225,
          'Length': null,
        },
      });

      expect(file.id, 'abc-123');
      expect(file.mediaType, MediaType.image);
      expect(file.isFavorite, false);
      expect(file.image, isNotNull);
      expect(file.video, isNull);
      expect(file.thumbAspect, closeTo(300 / 225, 0.001));
    });

    test('parses a video file', () {
      final file = MediaFile.fromJson({
        'Id': 'vid-1',
        'Hash': 'cafebabe',
        'CreatedAt': '2026-01-05T12:00:00Z',
        'Filename': 'clip.mp4',
        'Size': 999,
        'MediaType': 'video',
        'MimeType': 'video/mp4',
        'IsFavorite': true,
        'Video': {
          'Width': 1920,
          'Height': 1080,
          'ThumbnailWidth': 300,
          'ThumbnailHeight': 169,
          'Length': 15000,
        },
      });

      expect(file.mediaType, MediaType.video);
      expect(file.isFavorite, true);
      expect(file.video!.lengthMs, 15000);
      expect(file.image, isNull);
    });

    test('copyWith toggles favorite without mutating original', () {
      final file = MediaFile.fromJson({
        'Id': 'x',
        'Hash': 'h',
        'CreatedAt': '2026-01-05T12:00:00Z',
        'Filename': 'f.jpg',
        'Size': 1,
        'MediaType': 'image',
        'MimeType': 'image/jpeg',
        'IsFavorite': false,
        'Image': {
          'Width': 100,
          'Height': 100,
          'ThumbnailWidth': 10,
          'ThumbnailHeight': 10,
        },
      });

      final toggled = file.copyWith(isFavorite: true);
      expect(file.isFavorite, false);
      expect(toggled.isFavorite, true);
    });
  });

  group('Pagination.fromJson', () {
    test('parses nullable next/prev page', () {
      final pagination = Pagination.fromJson({
        'total_records': 42,
        'current_page': 1,
        'total_pages': 3,
        'prev_page': null,
        'next_page': 2,
      });

      expect(pagination.totalRecords, 42);
      expect(pagination.prevPage, isNull);
      expect(pagination.nextPage, 2);
    });

    test('parses last page with null next_page', () {
      final pagination = Pagination.fromJson({
        'total_records': 42,
        'current_page': 3,
        'total_pages': 3,
        'prev_page': 2,
        'next_page': null,
      });

      expect(pagination.nextPage, isNull);
    });
  });

  group('PagedFilesNotifier.toggleFavorite', () {
    test(
      'optimistically toggles favorite state in an unfiltered gallery',
      () async {
        final api = _FakeApiClient([
          _mediaFile(id: 'file-1', isFavorite: false),
        ]);
        final container = await _containerWith(api);
        addTearDown(container.dispose);

        final provider = pagedFilesProvider(const GalleryQuery());
        final sub = container.listen(provider, (_, _) {});
        addTearDown(sub.close);

        await container.read(provider.future);
        await container.read(provider.notifier).toggleFavorite('file-1');
        await container.read(provider.future);

        final files = container.read(provider).value!.files;
        expect(files.single.isFavorite, true);
        expect(api.toggledIds, ['file-1']);
      },
    );

    test('removes an unfavorited item from the favorites filter', () async {
      final api = _FakeApiClient([
        _mediaFile(id: 'favorite-1', isFavorite: true),
        _mediaFile(id: 'favorite-2', isFavorite: true),
      ]);
      final container = await _containerWith(api);
      addTearDown(container.dispose);

      const query = GalleryQuery(filter: MediaFilter.favorite);
      final provider = pagedFilesProvider(query);
      final sub = container.listen(provider, (_, _) {});
      addTearDown(sub.close);

      await container.read(provider.future);
      await container.read(provider.notifier).toggleFavorite('favorite-1');
      await container.read(provider.future);

      final files = container.read(provider).value!.files;
      expect(files.map((file) => file.id), ['favorite-2']);
      expect(api.toggledIds, ['favorite-1']);
    });
  });

  group('RecentMediaStore', () {
    test('round-trips upserted files through getAll', () async {
      final store = await RecentMediaStore.openInMemoryForTesting();
      final file = _mediaFile(id: 'a', isFavorite: true);

      await store.upsertAll([file]);
      final loaded = store.getAll();

      expect(loaded.single.id, 'a');
      expect(loaded.single.isFavorite, true);
    });

    test('queryOffline filters by MediaFilter', () async {
      final store = await RecentMediaStore.openInMemoryForTesting();
      await store.upsertAll([
        _mediaFile(id: 'img', isFavorite: false),
        _mediaFile(id: 'vid', isFavorite: false, mediaType: MediaType.video),
        _mediaFile(id: 'fav', isFavorite: true),
      ]);

      final videos = store.queryOffline(
        const GalleryQuery(filter: MediaFilter.video),
      );
      final favorites = store.queryOffline(
        const GalleryQuery(filter: MediaFilter.favorite),
      );

      expect(videos.map((f) => f.id), ['vid']);
      expect(favorites.map((f) => f.id), ['fav']);
    });

    test('queryOffline sorts by createdAt honoring direction', () async {
      final store = await RecentMediaStore.openInMemoryForTesting();
      final older = _mediaFile(
        id: 'older',
        isFavorite: false,
      );
      final newer = MediaFile(
        id: 'newer',
        hash: 'hash-newer',
        createdAt: older.createdAt.add(const Duration(days: 1)),
        filename: 'newer.jpg',
        size: 1,
        mediaType: MediaType.image,
        mimeType: 'image/jpeg',
        isFavorite: false,
        image: older.image,
      );
      await store.upsertAll([older, newer]);

      final desc = store.queryOffline(
        const GalleryQuery(
          order: SortOrder.createdAt,
          direction: SortDirection.desc,
        ),
      );
      final asc = store.queryOffline(
        const GalleryQuery(
          order: SortOrder.createdAt,
          direction: SortDirection.asc,
        ),
      );

      expect(desc.map((f) => f.id), ['newer', 'older']);
      expect(asc.map((f) => f.id), ['older', 'newer']);
    });

    test(
      'queryOfflineWithThumbs includes thumbnail-only files but not uncached ones',
      () async {
        final api = _FakeApiClient([]);
        final store = await RecentMediaStore.openInMemoryForTesting();
        await store.upsertAll([
          _mediaFile(id: 'thumb-only', isFavorite: false),
          _mediaFile(id: 'fully-cached', isFavorite: false),
          _mediaFile(id: 'not-cached', isFavorite: false),
        ]);

        await ThumbCacheManager.instance.putFile(
          'thumb-thumb-only',
          Uint8List.fromList([0]),
        );
        await ThumbCacheManager.instance.putFile(
          'thumb-fully-cached',
          Uint8List.fromList([0]),
        );
        await FullImageCacheManager.instance.putFile(
          api.imageUrl('fully-cached'),
          Uint8List.fromList([0]),
        );

        final result = await store.queryOfflineWithThumbs(
          const GalleryQuery(order: SortOrder.createdAt),
        );

        // 'thumb-only' is included: it renders as a grid tile offline even
        // though tapping it will hit the "Not available offline" path.
        expect(
          result.map((f) => f.id).toSet(),
          {'thumb-only', 'fully-cached'},
        );
      },
    );
  });

  group('PagedFilesNotifier offline fallback', () {
    test('falls back to recently-viewed cache when offline', () async {
      final api = _FakeApiClient([_mediaFile(id: 'cached-1', isFavorite: false)]);
      final store = await RecentMediaStore.openInMemoryForTesting();
      await store.upsertAll(api.files);

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          recentMediaStoreProvider.overrideWithValue(store),
          _online(false),
        ],
      );
      addTearDown(container.dispose);

      final provider = pagedFilesProvider(const GalleryQuery());
      final sub = container.listen(provider, (_, _) {});
      addTearDown(sub.close);

      final state = await container.read(provider.future);

      expect(state.isOffline, true);
      // Thumbnail bytes aren't in ThumbCacheManager's disk cache in this
      // test environment, so the metadata-only entry is excluded.
      expect(state.files, isEmpty);
    });

    test('loadMore is a no-op while offline', () async {
      final api = _FakeApiClient([_mediaFile(id: 'cached-1', isFavorite: false)]);
      final store = await RecentMediaStore.openInMemoryForTesting();

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          recentMediaStoreProvider.overrideWithValue(store),
          _online(false),
        ],
      );
      addTearDown(container.dispose);

      final provider = pagedFilesProvider(const GalleryQuery());
      final sub = container.listen(provider, (_, _) {});
      addTearDown(sub.close);

      await container.read(provider.future);
      await container.read(provider.notifier).loadMore();

      expect(container.read(provider).value!.isLoadingMore, false);
    });
  });

  group('offline favoriting', () {
    test(
      'toggling while offline updates immediately and reconciles once back online',
      () async {
        final api = _FakeApiClient([
          _mediaFile(id: 'file-1', isFavorite: false),
        ]);
        final store = await RecentMediaStore.openInMemoryForTesting();

        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            recentMediaStoreProvider.overrideWithValue(store),
            isOnlineProvider.overrideWith(
              () => _ControllableOnlineNotifier(true),
            ),
          ],
        );
        addTearDown(container.dispose);

        final provider = pagedFilesProvider(const GalleryQuery());
        final sub = container.listen(provider, (_, _) {});
        addTearDown(sub.close);

        await container.read(provider.future);
        await store.upsertAll(api.files);
        await ThumbCacheManager.instance.putFile(
          'thumb-file-1',
          Uint8List.fromList([0]),
        );
        await FullImageCacheManager.instance.putFile(
          api.imageUrl('file-1'),
          Uint8List.fromList([0]),
        );

        final onlineNotifier =
            container.read(isOnlineProvider.notifier)
                as _ControllableOnlineNotifier;
        onlineNotifier.setOnline(false);
        final offlineState = await container.read(provider.future);
        expect(offlineState.isOffline, true);
        expect(offlineState.files.map((f) => f.id), ['file-1']);

        await container.read(provider.notifier).toggleFavorite('file-1');

        // Applied optimistically and persisted to the cache, with no
        // server call while offline.
        expect(api.toggledIds, isEmpty);
        expect(store.pendingFavorites, {'file-1': true});
        expect(
          store.getAll().firstWhere((f) => f.id == 'file-1').isFavorite,
          true,
        );

        // Reconnect: pending change should be reconciled against the
        // server (which still has isFavorite == false), so exactly one
        // toggle call is made.
        onlineNotifier.setOnline(true);
        await container.read(provider.future);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(api.toggledIds, ['file-1']);
        expect(store.pendingFavorites, isEmpty);
      },
    );

    test(
      'toggling back to the original state while offline is a no-op on reconnect',
      () async {
        final api = _FakeApiClient([
          _mediaFile(id: 'file-1', isFavorite: false),
        ]);
        final store = await RecentMediaStore.openInMemoryForTesting();

        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            recentMediaStoreProvider.overrideWithValue(store),
            isOnlineProvider.overrideWith(
              () => _ControllableOnlineNotifier(true),
            ),
          ],
        );
        addTearDown(container.dispose);

        final provider = pagedFilesProvider(const GalleryQuery());
        final sub = container.listen(provider, (_, _) {});
        addTearDown(sub.close);

        await container.read(provider.future);
        await store.upsertAll(api.files);
        await ThumbCacheManager.instance.putFile(
          'thumb-file-1',
          Uint8List.fromList([0]),
        );
        await FullImageCacheManager.instance.putFile(
          api.imageUrl('file-1'),
          Uint8List.fromList([0]),
        );

        final onlineNotifier =
            container.read(isOnlineProvider.notifier)
                as _ControllableOnlineNotifier;
        onlineNotifier.setOnline(false);
        await container.read(provider.future);

        // Toggle twice while offline: false -> true -> false, back to the
        // server's actual value.
        await container.read(provider.notifier).toggleFavorite('file-1');
        await container.read(provider.notifier).toggleFavorite('file-1');
        expect(store.pendingFavorites, {'file-1': false});

        onlineNotifier.setOnline(true);
        await container.read(provider.future);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          api.toggledIds,
          isEmpty,
          reason: 'desired state already matches the server, no call needed',
        );
        expect(store.pendingFavorites, isEmpty);
      },
    );
  });
}
