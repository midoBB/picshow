class Pagination {
  Pagination({
    required this.totalRecords,
    required this.currentPage,
    required this.totalPages,
    required this.prevPage,
    required this.nextPage,
  });

  factory Pagination.fromJson(Map<String, dynamic> json) => Pagination(
    totalRecords: json['total_records'] as int,
    currentPage: json['current_page'] as int,
    totalPages: json['total_pages'] as int,
    prevPage: json['prev_page'] as int?,
    nextPage: json['next_page'] as int?,
  );

  final int totalRecords;
  final int currentPage;
  final int totalPages;
  final int? prevPage;
  final int? nextPage;
}
