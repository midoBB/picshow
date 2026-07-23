import 'dart:async';
import 'dart:io';

import 'package:file/file.dart' as file_api;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:k_gallery/src/utils/media_source_resolver.dart';

/// A [FileService] standing in for the PicShow server: it serves bytes with a
/// `max-age` (the real `/api/video/:id` sends `public, max-age=259200`) and
/// can be switched offline to fail every request the way a dead network does.
class _FakeFileService extends FileService {
  _FakeFileService({required this.maxAge});

  final Duration maxAge;
  bool offline = false;
  int gets = 0;

  @override
  Future<FileServiceResponse> get(String url, {Map<String, String>? headers}) async {
    gets++;
    if (offline) throw const SocketException('offline');
    return _FakeResponse(validTill: DateTime.now().add(maxAge));
  }
}

class _FakeResponse implements FileServiceResponse {
  _FakeResponse({required this.validTill});

  static final _bytes = List<int>.filled(1024, 7);

  @override
  final DateTime validTill;

  @override
  Stream<List<int>> get content => Stream.value(_bytes);

  @override
  int? get contentLength => _bytes.length;

  @override
  int get statusCode => 200;

  @override
  String? get eTag => null;

  @override
  String get fileExtension => '.mp4';

  String? header(String name) => null;
}

/// Keeps cache files in a throwaway temp dir instead of going through
/// path_provider's platform channel.
class _TempFileSystem implements FileSystem {
  _TempFileSystem(this.dir);

  final Directory dir;

  @override
  Future<file_api.File> createFile(String name) async =>
      const LocalFileSystem().file('${dir.path}/$name');
}

void main() {
  late Directory tempDir;
  late _FakeFileService service;
  late CacheManager manager;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('offline_video_test');
    service = _FakeFileService(maxAge: const Duration(seconds: 1));
    manager = CacheManager(
      Config(
        'test-video-cache-${DateTime.now().microsecondsSinceEpoch}',
        stalePeriod: const Duration(days: 365),
        maxNrOfCacheObjects: 1000000,
        fileService: service,
        fileSystem: _TempFileSystem(tempDir),
        repo: JsonCacheInfoRepository(path: '${tempDir.path}/cache.json'),
      ),
    );
  });

  tearDown(() async {
    await manager.dispose();
    tempDir.deleteSync(recursive: true);
  });

  const url = 'http://server.test/api/video/abc';
  const key = 'video-abc';

  test('plays a fully cached video offline once its max-age has passed', () async {
    // Online: the prefetcher downloads the whole file.
    final cached = await resolveMediaSource(manager, url, cacheKey: key);
    expect(cached.isLocal, isTrue, reason: 'sanity: online download works');
    expect(File(cached.source).existsSync(), isTrue);

    // The server's Cache-Control max-age lapses. Nothing was evicted — every
    // byte is still on disk, and the ledger still lists this file as
    // available offline.
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    // Now the network is gone.
    service.offline = true;

    final resolved = await resolveMediaSource(manager, url, cacheKey: key);

    expect(
      resolved.isLocal,
      isTrue,
      reason: 'offline playback must use the bytes already on disk',
    );
    expect(File(resolved.source).existsSync(), isTrue);
    expect(
      service.gets,
      1,
      reason: 'a complete local copy should not be re-fetched at play time',
    );
  });

  test('falls back to the network URL when nothing is cached', () async {
    service.offline = true;

    final resolved = await resolveMediaSource(manager, url, cacheKey: key);

    expect(resolved.isLocal, isFalse);
    expect(resolved.source, url);
  });
}
