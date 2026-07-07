enum MediaFilter { all, image, video, favorite }

enum SortOrder { createdAt, random }

enum SortDirection { asc, desc }

extension MediaFilterApi on MediaFilter {
  String get apiValue {
    switch (this) {
      case MediaFilter.all:
        return 'all';
      case MediaFilter.image:
        return 'image';
      case MediaFilter.video:
        return 'video';
      case MediaFilter.favorite:
        return 'favorite';
    }
  }

  String get label {
    switch (this) {
      case MediaFilter.all:
        return 'All';
      case MediaFilter.image:
        return 'Images';
      case MediaFilter.video:
        return 'Videos';
      case MediaFilter.favorite:
        return 'Favorites';
    }
  }
}

extension SortOrderApi on SortOrder {
  String get apiValue => this == SortOrder.createdAt ? 'created_at' : 'random';
}

extension SortDirectionApi on SortDirection {
  String get apiValue => this == SortDirection.asc ? 'asc' : 'desc';
}

class GalleryQuery {
  const GalleryQuery({
    this.filter = MediaFilter.all,
    this.order = SortOrder.random,
    this.direction = SortDirection.desc,
    this.seed,
  });

  final MediaFilter filter;
  final SortOrder order;
  final SortDirection direction;
  final int? seed;

  GalleryQuery copyWith({
    MediaFilter? filter,
    SortOrder? order,
    SortDirection? direction,
    int? seed,
    bool clearSeed = false,
  }) {
    return GalleryQuery(
      filter: filter ?? this.filter,
      order: order ?? this.order,
      direction: direction ?? this.direction,
      seed: clearSeed ? null : (seed ?? this.seed),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryQuery &&
      other.filter == filter &&
      other.order == order &&
      other.direction == direction &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(filter, order, direction, seed);
}
