import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import {
  fetchStats,
  fetchPaginatedFiles,
  PaginationParams,
} from "@/queries/api";
import { Stats } from "@/queries/model";

// Hook to fetch stats
export const useStats = () => {
  return useQuery<Stats>({
    queryKey: ["stats"],
    queryFn: fetchStats,
  });
};

export const usePaginatedFiles = (params: Omit<PaginationParams, "page">) => {
  return useInfiniteQuery({
    queryKey: ["files", params],
    queryFn: ({ pageParam }) =>
      fetchPaginatedFiles({ ...params, ...pageParam }),
    initialPageParam: { page: 1 },
    getNextPageParam: (lastPage) =>
      lastPage.pagination.next_page
        ? { page: lastPage.pagination.next_page }
        : undefined,
    getPreviousPageParam: (firstPage) =>
      firstPage.pagination.prev_page
        ? { page: firstPage.pagination.prev_page }
        : undefined,
  });
};
