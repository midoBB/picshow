import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Image-source helpers that let kGallery transparently render either a
/// network URL or an inline base64 data URI (e.g.
/// `data:image/png;base64,iVBORw0KGgo...`) wherever an image is shown — the
/// full-screen viewer, the thumbnail strip, and audio/video posters.
///
/// Detection is purely on the string: a source is treated as base64 when it
/// contains the `;base64,` marker. No change to [GalleryItem] is required —
/// callers keep passing the data URI in the existing `url` / `thumbnailUrl`
/// fields.

const String _kBase64Marker = ';base64,';

/// Maximum number of decoded base64 payloads kept in memory. The cache keeps
/// the decoded [Uint8List] stable across rebuilds so repeated `build()` calls
/// (zoom, thumbnail scroll) neither re-decode nor miss Flutter's image cache.
const int _kMaxDecodedCacheEntries = 32;

/// Bounded LRU cache: data-URI string -> decoded bytes. Insertion order is the
/// LRU order; a hit is re-inserted to mark it most-recently-used.
final Map<String, Uint8List> _decodedCache = <String, Uint8List>{};

/// Whether [source] is an inline base64 data URI rather than a network URL.
bool isBase64DataUri(String source) => source.contains(_kBase64Marker);

/// Decodes the base64 payload of a data URI to bytes.
///
/// Returns `null` (never throws) when [source] is not a base64 data URI, the
/// payload is malformed, or decodes to nothing — callers fall back to their
/// error widget. Whitespace/newlines in the payload are stripped and padding
/// is normalized before decoding so real-world data URIs decode cleanly.
Uint8List? decodeBase64DataUri(String source) {
  final cached = _decodedCache[source];
  if (cached != null) {
    // Refresh LRU order.
    _decodedCache
      ..remove(source)
      ..[source] = cached;
    return cached;
  }

  final markerIndex = source.indexOf(_kBase64Marker);
  if (markerIndex < 0) return null;

  try {
    final payload = source
        .substring(markerIndex + _kBase64Marker.length)
        .replaceAll(RegExp(r'\s'), '');
    if (payload.isEmpty) return null;
    final bytes = base64.decode(base64.normalize(payload));
    if (bytes.isEmpty) return null;

    _decodedCache[source] = bytes;
    if (_decodedCache.length > _kMaxDecodedCacheEntries) {
      _decodedCache.remove(_decodedCache.keys.first);
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

/// Builds an image widget for [source], transparently handling both base64
/// data URIs and network URLs.
///
/// - **base64**: decodes once and renders [Image.memory] — no loading
///   [placeholder] (the bytes are already local) and no disk caching. On a
///   decode failure (or a later codec error) the [errorWidget] is shown.
/// - **network**: renders [CachedNetworkImage], forwarding the caller-supplied
///   [cacheManager] and [memCacheWidth] while preserving the disk-backed cache,
///   [placeholder], and [errorWidget] behavior.
///
/// [cacheWidth] / [cacheHeight] apply only to the base64 path, where they cap
/// the decoded bitmap size (useful for thumbnails to avoid decoding a large
/// image at full resolution).
///
/// [cacheManager] / [memCacheWidth] apply only to the network path:
/// [cacheManager] lets the host app share its own [BaseCacheManager] (custom
/// disk cache config, auth headers, etc.) and [memCacheWidth] caps the width of
/// the bitmap held in memory by [CachedNetworkImage] (the network analogue of
/// [cacheWidth]).
Widget galleryImage({
  required String source,
  BoxFit? fit,
  double? width,
  double? height,
  int? cacheWidth,
  int? cacheHeight,
  BaseCacheManager? cacheManager,
  int? memCacheWidth,
  PlaceholderWidgetBuilder? placeholder,
  required LoadingErrorWidgetBuilder errorWidget,
}) {
  if (isBase64DataUri(source)) {
    final bytes = decodeBase64DataUri(source);
    if (bytes == null) {
      return Builder(
        builder: (context) =>
            errorWidget(context, source, 'Invalid base64 image data'),
      );
    }
    return Image.memory(
      bytes,
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      gaplessPlayback: true,
      errorBuilder: (context, error, _) => errorWidget(context, source, error),
    );
  }

  return CachedNetworkImage(
    imageUrl: source,
    fit: fit,
    width: width,
    height: height,
    cacheManager: cacheManager,
    memCacheWidth: memCacheWidth,
    placeholder: placeholder,
    errorWidget: errorWidget,
  );
}
