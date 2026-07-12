class MediaStats {
  const MediaStats({
    required this.totalCount,
    required this.imageCount,
    required this.videoCount,
    required this.favoriteCount,
  });

  factory MediaStats.fromJson(Map<String, dynamic> json) => MediaStats(
    totalCount: json['count'] as int,
    imageCount: json['image_count'] as int,
    videoCount: json['video_count'] as int,
    favoriteCount: json['favorite_count'] as int,
  );

  final int totalCount;
  final int imageCount;
  final int videoCount;
  final int favoriteCount;
}
