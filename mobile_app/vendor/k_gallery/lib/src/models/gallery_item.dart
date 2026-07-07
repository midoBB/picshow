import 'package:json_annotation/json_annotation.dart';

part 'gallery_item.g.dart';

/// The type of media content for a gallery item.
enum GalleryItemType {
  /// A static image (JPEG, PNG, WebP, GIF, etc.).
  image,

  /// A video file (MP4, WebM, etc.).
  video,

  /// An audio file (MP3, AAC, etc.).
  audio,

  /// A YouTube video. The [GalleryItem.url] should be any standard YouTube
  /// link (youtu.be, youtube.com/watch?v=..., /shorts/, /embed/).
  youtube,
}

/// Represents a single media item in the gallery.
///
/// Each item has a [url] pointing to the media content and an optional
/// [thumbnailUrl] for the thumbnail strip. For video/audio items, provide
/// a [thumbnailUrl] for a meaningful preview image.
///
/// ```dart
/// GalleryItem(
///   url: 'https://example.com/photo.jpg',
///   type: GalleryItemType.image,
///   title: 'Sunset',
///   description: 'A beautiful sunset over the ocean.',
/// )
/// ```
@JsonSerializable()
class GalleryItem {
  /// The URL of the media content.
  ///
  /// For images, this is the full-resolution image URL.
  /// For video/audio, this is the media stream URL.
  final String url;

  /// The type of media content.
  /// Defaults to [GalleryItemType.image].
  @JsonKey(defaultValue: GalleryItemType.image)
  final GalleryItemType type;

  /// Optional URL for the thumbnail preview image.
  ///
  /// If not provided, [url] is used as the thumbnail source.
  /// Recommended for video/audio items to show a meaningful preview.
  final String? thumbnailUrl;

  /// Optional title displayed in the text panel overlay.
  final String? title;

  /// Optional description displayed below the title in the text panel overlay.
  final String? description;

  /// Creates a [GalleryItem].
  const GalleryItem({
    required this.url,
    this.type = GalleryItemType.image,
    this.thumbnailUrl,
    this.title,
    this.description,
  });

  /// Creates a [GalleryItem] from a JSON map.
  factory GalleryItem.fromJson(Map<String, dynamic> json) =>
      _$GalleryItemFromJson(json);

  /// Converts this [GalleryItem] to a JSON map.
  Map<String, dynamic> toJson() => _$GalleryItemToJson(this);
}

