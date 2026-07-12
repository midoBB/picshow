import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/media_stats.dart';
import 'package:picshow_mobile/core/models/pagination.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/providers.dart';
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

ProviderContainer _containerWith(ApiClient api) {
  return ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(api)],
  );
}

void main() {
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
        final container = _containerWith(api);
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
      final container = _containerWith(api);
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
}
