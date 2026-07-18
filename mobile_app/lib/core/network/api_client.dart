import 'package:dio/dio.dart';

import 'package:picshow_mobile/core/models/media_file.dart';
import 'package:picshow_mobile/core/models/media_stats.dart';
import 'package:picshow_mobile/core/models/pagination.dart';

class PagedFilesResult {
  PagedFilesResult({required this.files, required this.pagination});

  final List<MediaFile> files;
  final Pagination pagination;
}

class ApiClient {
  /// [baseUrls] is an ordered list of candidate server addresses (e.g. a
  /// LAN address and a public/internet address for the same server). The
  /// first candidate is tried by default; on a connection failure, requests
  /// automatically retry against the remaining candidates, and whichever
  /// one succeeds becomes the active address for subsequent calls (and for
  /// [thumbnailUrl]/[imageUrl]/[videoUrl]).
  ApiClient({
    List<String> baseUrls = const [],
    this.onConnectionError,
    this.onConnectionSuccess,
  }) : _candidates = baseUrls
           .map(_normalize)
           .where((u) => u.isNotEmpty)
           .toList(),
       _dio = Dio() {
    if (_candidates.isNotEmpty) {
      _baseUrl = _candidates.first;
      _dio.options.baseUrl = _apiBaseUrl;
    }
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          onConnectionSuccess?.call();
          handler.next(response);
        },
        onError: (error, handler) async {
          final alreadyRetried =
              error.requestOptions.extra['_failoverRetried'] == true;
          if (isConnectionError(error) &&
              !alreadyRetried &&
              _candidates.length > 1) {
            for (final candidate in _candidates) {
              if (candidate == _baseUrl) continue;
              try {
                final options = error.requestOptions
                  ..extra['_failoverRetried'] = true
                  ..baseUrl = '$candidate/api';
                final response = await _dio.fetch<dynamic>(options);
                baseUrl = candidate;
                onConnectionSuccess?.call();
                handler.resolve(response);
                return;
              } on DioException {
                continue;
              }
            }
          }
          if (isConnectionError(error)) onConnectionError?.call();
          handler.next(error);
        },
      ),
    );
  }

  final void Function()? onConnectionError;
  final void Function()? onConnectionSuccess;

  static bool isConnectionError(DioException e) =>
      e.type == DioExceptionType.connectionError ||
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      e.type == DioExceptionType.receiveTimeout;

  static String _normalize(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  final Dio _dio;
  final List<String> _candidates;
  String _baseUrl = '';

  String get _apiBaseUrl => '$_baseUrl/api';

  /// The currently-active server address (starts as the first candidate;
  /// switches to whichever one last answered successfully).
  String get baseUrl => _baseUrl;

  set baseUrl(String value) {
    _baseUrl = _normalize(value);
    _dio.options.baseUrl = _apiBaseUrl;
  }

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

  String thumbnailUrl(String id) => '$_baseUrl/api/thumbnail/$id';

  String imageUrl(String id) => '$_baseUrl/api/image/$id';

  String videoUrl(String id) => '$_baseUrl/api/video/$id';
}
