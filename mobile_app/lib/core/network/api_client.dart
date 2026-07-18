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
  ApiClient({String? baseUrl, this.onConnectionError, this.onConnectionSuccess})
    : _dio = Dio() {
    if (baseUrl != null) this.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 10);
    _dio.options.receiveTimeout = const Duration(seconds: 30);
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          onConnectionSuccess?.call();
          handler.next(response);
        },
        onError: (error, handler) {
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

  final Dio _dio;
  String _baseUrl = '';

  String get baseUrl => _baseUrl;

  set baseUrl(String value) {
    _baseUrl = value.endsWith('/')
        ? value.substring(0, value.length - 1)
        : value;
    _dio.options.baseUrl = '$_baseUrl/api';
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
