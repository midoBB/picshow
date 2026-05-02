import {
  type InfiniteData,
  useInfiniteQuery,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import {
  deleteFile,
  fetchClusterDetail,
  fetchClusters,
  fetchPaginatedFiles,
  fetchSettings,
  fetchStats,
  fetchThumbnail,
  getIsFavorite,
  markClusterResolved,
  type PaginationParams,
  rebuildClusters,
  resolveCluster,
  toggleFavorite,
  triggerScan,
  updateSettings,
} from "@/queries/api";
import type {
  AppSettings,
  ClusterDetailResponse,
  PaginatedFiles,
  Stats,
} from "@/queries/model";

export const useStats = () => {
  return useQuery<Stats>({
    queryKey: ["stats"],
    queryFn: fetchStats,
  });
};

// 1. Paginated Files Query (mostly unchanged, added InfiniteData typing)
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

// 2. Toggle Mutation with Two-Way Optimistic Updates
export const useToggleFavorite = () => {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: number) => toggleFavorite(id),
    onMutate: async (id: number) => {
      // Cancel outgoing refetches so they don't overwrite our optimistic update
      await queryClient.cancelQueries({ queryKey: ["isFavorite", id] });
      await queryClient.cancelQueries({ queryKey: ["files"] });

      // Snapshot the previous values for potential rollback
      const previousIsFavorite = queryClient.getQueryData<boolean>([
        "isFavorite",
        id,
      ]);
      const previousFiles = queryClient.getQueriesData<
        InfiniteData<PaginatedFiles>
      >({
        queryKey: ["files"],
      });

      // Optimistically update the single "isFavorite" cache
      queryClient.setQueryData<boolean>(["isFavorite", id], (old) => {
        // If it's undefined, we fallback to true (assuming they are liking it)
        return old !== undefined ? !old : true;
      });

      // Optimistically update all cached "files" lists so the UI updates instantly
      queryClient.setQueriesData<InfiniteData<PaginatedFiles>>(
        { queryKey: ["files"] },
        (oldData) => {
          if (!oldData) return oldData;
          return {
            ...oldData,
            pages: oldData.pages.map((page) => ({
              ...page,
              files: page.files.map((file) =>
                file.Id === String(id)
                  ? { ...file, IsFavorite: !file.IsFavorite }
                  : file,
              ),
            })),
          };
        },
      );

      // Return context for the rollback
      return { previousIsFavorite, previousFiles, id };
    },
    // If the mutation fails, roll back to the snapshots
    onError: (_err, _id, context) => {
      if (context?.previousIsFavorite !== undefined) {
        queryClient.setQueryData(
          ["isFavorite", context.id],
          context.previousIsFavorite,
        );
      }
      if (context?.previousFiles) {
        context.previousFiles.forEach(([queryKey, data]) => {
          queryClient.setQueryData(queryKey, data);
        });
      }
    },
    // Always sync with the server once the mutation finishes
    onSettled: (_, __, id) => {
      queryClient.invalidateQueries({ queryKey: ["isFavorite", id] });
      queryClient.invalidateQueries({ queryKey: ["files"] });
    },
  });
};

// 3. Get Single Favorite Status with Initial Data from List
export const useGetIsFavorite = (id: number) => {
  const queryClient = useQueryClient();

  return useQuery({
    queryKey: ["isFavorite", id],
    queryFn: () => getIsFavorite(id),
    initialData: () => {
      // Find all queries that start with "files" (regardless of params)
      const filesQueries = queryClient.getQueriesData<
        InfiniteData<PaginatedFiles>
      >({
        queryKey: ["files"],
      });

      // Look through every cached page for the file
      for (const [, queryData] of filesQueries) {
        if (!queryData) continue;

        for (const page of queryData.pages) {
          const file = page.files.find((f) => f.Id === String(id));
          if (file) {
            // Return the value to populate the initial state immediately
            return file.IsFavorite;
          }
        }
      }

      // Return undefined if not found so React Query knows to run the queryFn
      return undefined;
    },
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
export const useThumbnail = (fileId: string) => {
  const enabled = !!fileId;
  return useQuery({
    queryKey: ["thumbnail", fileId],
    queryFn: () => fetchThumbnail(fileId),
    enabled,
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    refetchOnMount: false,
    gcTime: 1000 * 60 * 60, // 1 hour
  });
};

export const useSettings = () => {
  return useQuery<AppSettings>({
    queryKey: ["settings"],
    queryFn: fetchSettings,
  });
};

export const useUpdateSettings = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: updateSettings,
    onSuccess: (data) => {
      queryClient.setQueryData(["settings"], data);
    },
  });
};

export const useTriggerScan = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: triggerScan,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["stats"] });
    },
  });
};

// ===== Clustering Hooks =====

export const useInfiniteClusters = () => {
  return useInfiniteQuery({
    queryKey: ["clusters"],
    queryFn: ({ pageParam }) =>
      fetchClusters({ page: pageParam.page, pageSize: pageParam.pageSize }),
    initialPageParam: { page: 1, pageSize: 20 },
    getNextPageParam: (lastPage) =>
      lastPage.pagination.next_page
        ? { page: lastPage.pagination.next_page, pageSize: 20 }
        : undefined,
    getPreviousPageParam: (firstPage) =>
      firstPage.pagination.prev_page
        ? { page: firstPage.pagination.prev_page, pageSize: 20 }
        : undefined,
  });
};

export const useClusterDetail = (clusterId: number) => {
  return useQuery<ClusterDetailResponse>({
    queryKey: ["cluster", clusterId],
    queryFn: () => fetchClusterDetail(clusterId),
    enabled: !!clusterId,
  });
};

export const useResolveCluster = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: resolveCluster,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clusters"] });
      queryClient.invalidateQueries({ queryKey: ["files"] });
      queryClient.invalidateQueries({ queryKey: ["stats"] });
    },
  });
};

export const useMarkClusterResolved = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: markClusterResolved,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clusters"] });
    },
  });
};

export const useRebuildClusters = () => {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: rebuildClusters,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["clusters"] });
    },
  });
};
