enum MediaType { image, video }

class MediaMeta {
  MediaMeta({
    required this.width,
    required this.height,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    this.lengthMs,
  });

  factory MediaMeta.fromJson(Map<String, dynamic> json) => MediaMeta(
    width: json['Width'] as int,
    height: json['Height'] as int,
    thumbnailWidth: json['ThumbnailWidth'] as int,
    thumbnailHeight: json['ThumbnailHeight'] as int,
    lengthMs: json['Length'] as int?,
  );

  final int width;
  final int height;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int? lengthMs;
}

class MediaFile {
  MediaFile({
    required this.id,
    required this.hash,
    required this.createdAt,
    required this.filename,
    required this.size,
    required this.mediaType,
    required this.mimeType,
    required this.isFavorite,
    this.image,
    this.video,
  });

  factory MediaFile.fromJson(Map<String, dynamic> json) => MediaFile(
    id: json['Id'] as String,
    hash: json['Hash'] as String,
    createdAt: DateTime.parse(json['CreatedAt'] as String),
    filename: json['Filename'] as String,
    size: json['Size'] as int,
    mediaType: (json['MediaType'] as String) == 'video'
        ? MediaType.video
        : MediaType.image,
    mimeType: json['MimeType'] as String,
    isFavorite: json['IsFavorite'] as bool,
    image: json['Image'] != null
        ? MediaMeta.fromJson(json['Image'] as Map<String, dynamic>)
        : null,
    video: json['Video'] != null
        ? MediaMeta.fromJson(json['Video'] as Map<String, dynamic>)
        : null,
  );

  final String id;
  final String hash;
  final DateTime createdAt;
  final String filename;
  final int size;
  final MediaType mediaType;
  final String mimeType;
  final bool isFavorite;
  final MediaMeta? image;
  final MediaMeta? video;

  MediaMeta? get meta => image ?? video;

  double get thumbAspect {
    final m = meta;
    if (m == null || m.thumbnailHeight == 0) return 1;
    return m.thumbnailWidth / m.thumbnailHeight;
  }

  MediaFile copyWith({bool? isFavorite}) => MediaFile(
    id: id,
    hash: hash,
    createdAt: createdAt,
    filename: filename,
    size: size,
    mediaType: mediaType,
    mimeType: mimeType,
    isFavorite: isFavorite ?? this.isFavorite,
    image: image,
    video: video,
  );
}
