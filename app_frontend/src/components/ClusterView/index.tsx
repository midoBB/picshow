import { useCallback, useEffect, useMemo, useRef } from "react";
import { useInfiniteClusters } from "@/queries/loaders";
import useAppState from "@/state";
import { ClusterCard } from "./ClusterCard";

const ClusterCardSkeleton = ({ isDarkMode }: { isDarkMode: boolean }) => (
  <div
    className={`overflow-hidden rounded-xl border shadow-md ${
      isDarkMode
        ? "border-gray-700/50 bg-gray-800/80"
        : "border-gray-200 bg-white"
    }`}
  >
    <div
      className={`grid grid-cols-2 gap-0.5 ${isDarkMode ? "bg-gray-900" : "bg-gray-100"}`}
    >
      {[0, 1, 2, 3].map((i) => (
        <div
          key={i}
          className={`aspect-square animate-pulse ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
        />
      ))}
    </div>
    <div className="p-3">
      <div
        className={`h-4 w-24 animate-pulse rounded ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
      />
      <div
        className={`mt-2 h-3 w-16 animate-pulse rounded ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
      />
    </div>
  </div>
);

const LoadingMoreSpinner = ({ isDarkMode }: { isDarkMode: boolean }) => (
  <div className="flex items-center justify-center gap-2 py-6">
    <div className="h-5 w-5 animate-spin rounded-full border-2 border-t-transparent border-blue-500" />
    <span
      className={`text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
    >
      Loading more clusters
    </span>
  </div>
);

export const ClusterView = () => {
  const { data, fetchNextPage, hasNextPage, isFetchingNextPage, isLoading } =
    useInfiniteClusters();
  const isDarkMode = useAppState((state) => state.isDarkMode);
  const observerRef = useRef<HTMLDivElement | null>(null);

  const allClusters = useMemo(() => {
    return data?.pages.flatMap((page) => page.clusters) ?? [];
  }, [data]);

  const totalClusters = data?.pages[0]?.pagination.total_records ?? 0;

  const handleObserver = useCallback(
    (entries: IntersectionObserverEntry[]) => {
      const [target] = entries;
      if (target.isIntersecting && hasNextPage && !isFetchingNextPage) {
        fetchNextPage();
      }
    },
    [fetchNextPage, hasNextPage, isFetchingNextPage],
  );

  useEffect(() => {
    const element = observerRef.current;
    if (!element) return;

    const observer = new IntersectionObserver(handleObserver, {
      threshold: 0.1,
    });

    observer.observe(element);
    return () => observer.disconnect();
  }, [handleObserver]);

  if (isLoading) {
    return (
      <div
        className={`h-full overflow-y-auto ${isDarkMode ? "bg-slate-800" : "bg-gray-100"}`}
      >
        <div className="mb-6 px-4 pt-6">
          <div
            className={`h-8 w-48 animate-pulse rounded ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
          />
          <div
            className={`mt-2 h-4 w-32 animate-pulse rounded ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
          />
        </div>
        <div className="grid grid-cols-1 gap-5 px-4 pb-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {Array.from({ length: 8 }).map((_, i) => (
            <ClusterCardSkeleton key={i} isDarkMode={isDarkMode} />
          ))}
        </div>
      </div>
    );
  }

  if (allClusters.length === 0) {
    return (
      <div
        className={`flex h-full items-center justify-center ${isDarkMode ? "bg-slate-800" : "bg-gray-100"}`}
      >
        <div
          className={`text-center ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
        >
          <p className="text-lg font-medium">No similar photos found</p>
          <p className="mt-2 text-sm text-gray-500">
            Similar photos will appear here automatically as you add images
          </p>
        </div>
      </div>
    );
  }

  return (
    <div
      className={`h-full overflow-y-auto ${isDarkMode ? "bg-slate-800" : "bg-gray-100"}`}
    >
      <div className="mb-6 px-4 pt-6">
        <h2
          className={`text-2xl font-bold ${isDarkMode ? "text-white" : "text-gray-900"}`}
        >
          Similar Photos
        </h2>
        <p
          className={`mt-1 text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
        >
          {totalClusters} group{totalClusters !== 1 ? "s" : ""} of similar
          images
        </p>
      </div>

      <div className="grid grid-cols-1 gap-5 px-4 pb-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {allClusters.map((cluster) => (
          <ClusterCard key={cluster.clusterId} cluster={cluster} />
        ))}
      </div>

      {isFetchingNextPage && <LoadingMoreSpinner isDarkMode={isDarkMode} />}

      {hasNextPage && <div ref={observerRef} className="h-4" />}
    </div>
  );
};
