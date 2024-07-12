import {
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import {
  fetchStats,
  fetchPaginatedFiles,
  PaginationParams,
  deleteFile,
} from "@/queries/api";
import { Stats } from "@/queries/model";

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

export const useDeleteFile = () => {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: deleteFile,
    onMutate: async (deletedFileIds) => {
      const ids = deletedFileIds.split(",").map(Number);
      await queryClient.cancelQueries({ queryKey: ["files"] });
      const queries = queryClient.getQueriesData<{
        pages: Array<{ files: Array<{ ID: number }> }>;
      }>({ queryKey: ["files"] });

      queries.forEach(([queryKey, queryData]) => {
        if (queryData) {
          const updatedPages = queryData.pages.map((page) => ({
            ...page,
            files: page.files.filter((file) => !ids.includes(file.ID)),
          }));
          queryClient.setQueryData(queryKey, {
            ...queryData,
            pages: updatedPages,
          });
        }
      });
      return { queries };
    },
    onError: (_, __, context) => {
      if (context?.queries) {
        context.queries.forEach(([queryKey, queryData]) => {
          queryClient.setQueryData(queryKey, queryData);
        });
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ["files"] });
      queryClient.invalidateQueries({ queryKey: ["stats"] });
    },
  });
};
