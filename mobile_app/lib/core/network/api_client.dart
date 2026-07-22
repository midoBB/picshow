import 'dart:async';

import 'package:dio/dio.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/media_stats.dart';
import 'package:picshow_mobile/core/models/pagination.dart';
import 'package:picshow_mobile/core/network/server_connection.dart';

class PagedFilesResult {
  PagedFilesResult({required this.files, required this.pagination});

  final List<MediaFile> files;
  final Pagination pagination;
}

class ApiClient {
  /// Talks to whichever server address [connection] currently considers
  /// active, and reports every outcome back to it.
  ///
  /// Address selection deliberately lives in [ServerConnection] rather than
  /// here. This class once carried its own failover loop, which had two
  /// problems: it only ran when an API request happened to fail, and it left
  /// media URLs alone entirely — thumbnails, images and videos are fetched by
  /// `flutter_cache_manager`, which never passes through a dio interceptor.
  /// With one owner, [thumbnailUrl]/[imageUrl]/[videoUrl] follow the same
  /// address as every API call, and probing happens on connectivity changes
  /// and app resume rather than only after something has already broken.
  ApiClient({required this.connection}) : _dio = Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Resolved per request: the active address can change between the
          // client being constructed and a call being made.
          options.baseUrl = _apiBaseUrl;
          handler.next(options);
        },
        onResponse: (response, handler) {
          connection.noteResponse();
          handler.next(response);
        },
        onError: (error, handler) {
          if (isConnectionError(error)) {
            // Best-effort: gives the connection a chance to move to another
            // configured address before the next call. This request still
            // fails — callers already treat a connection error as "fall back
            // to the cache".
            unawaited(connection.failOver(baseUrl));
          }
          handler.next(error);
        },
      ),
    );
  }

  final ServerConnection connection;

  static bool isConnectionError(DioException e) =>
      e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout;

  final Dio _dio;

  String get _apiBaseUrl => '$baseUrl/api';

  /// The currently-active server address, as decided by [connection].
  String get baseUrl => connection.activeServerUrl ?? '';

  Future<MediaStats> fetchStats() async {
    final response = await _dio.get<Map<String, dynamic>>('/stats');
    return MediaStats.fromJson(response.data!);
  }

  Future<PagedFilesResult> listFiles({
    required int page,
    int pageSize = 15,
    String order = 'created_at',
    String direction = 'desc',
    int? seed,
    String type = 'all',
  }) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '',
      queryParameters: {
        'page': page,
        'page_size': pageSize,
        'order': order,
        'direction': direction,
        'seed': ?seed,
        'type': type,
      },
    );
    final data = response.data!;
    final files = (data['files'] as List<dynamic>)
        .map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
        .toList();
    final pagination = Pagination.fromJson(
      data['pagination'] as Map<String, dynamic>,
    );
    return PagedFilesResult(files: files, pagination: pagination);
  }

  Future<void> toggleFavorite(String id) async {
    await _dio.patch('/$id/favorite');
  }

  /// The server's current favorite state for [id]. Used to reconcile
  /// favorite changes made while offline: since [toggleFavorite] is a pure
  /// flip with no way to set an explicit value, the client must check the
  /// current value before deciding whether replaying a toggle is needed.
  Future<bool> getFavorite(String id) async {
    final response = await _dio.get<bool>('/$id/favorite');
    return response.data!;
  }

  // Built from the live address, so a failover mid-session immediately
  // redirects media fetches too. Cache keys deliberately do not follow
  // (see cacheKeyFor): the bytes are the same file either way.
  String thumbnailUrl(String id) => '$baseUrl/api/thumbnail/$id';

  String imageUrl(String id) => '$baseUrl/api/image/$id';

  String videoUrl(String id) => '$baseUrl/api/video/$id';
}
