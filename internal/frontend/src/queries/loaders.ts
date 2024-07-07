import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { fetchStats, fetchPaginatedFiles } from "./api";
import { Stats } from "./model";

// Hook to fetch stats
export const useStats = () => {
  return useQuery<Stats>({
    queryKey: ["stats"],
    queryFn: fetchStats,
  });
};

// Hook to fetch paginated files
export const usePaginatedFiles = (pageSize: number) => {
  return useInfiniteQuery({
    queryKey: ["files", `${pageSize}`],
    queryFn: ({ pageParam }) => fetchPaginatedFiles(pageParam),
    initialPageParam: {
      page: 1,
      pageSize,
    },
    getNextPageParam: (lastPage) =>
      lastPage.pagination.next_page
        ? { page: lastPage.pagination.next_page, pageSize }
        : undefined,
    getPreviousPageParam: (firstPage) =>
      firstPage.pagination.prev_page
        ? { page: firstPage.pagination.prev_page, pageSize }
        : undefined,
  });
};
