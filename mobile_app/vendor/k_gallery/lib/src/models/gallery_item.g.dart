// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gallery_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

GalleryItem _$GalleryItemFromJson(Map<String, dynamic> json) => GalleryItem(
      url: json['url'] as String,
      type: $enumDecodeNullable(_$GalleryItemTypeEnumMap, json['type']) ??
          GalleryItemType.image,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      title: json['title'] as String?,
      description: json['description'] as String?,
    );

Map<String, dynamic> _$GalleryItemToJson(GalleryItem instance) =>
    <String, dynamic>{
      'url': instance.url,
      'type': _$GalleryItemTypeEnumMap[instance.type]!,
      'thumbnailUrl': instance.thumbnailUrl,
      'title': instance.title,
      'description': instance.description,
    };

const _$GalleryItemTypeEnumMap = {
  GalleryItemType.image: 'image',
  GalleryItemType.video: 'video',
  GalleryItemType.audio: 'audio',
  GalleryItemType.youtube: 'youtube',
};
