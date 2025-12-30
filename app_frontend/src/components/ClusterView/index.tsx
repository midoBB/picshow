import { useCallback, useEffect, useMemo, useRef } from "react";
import { useInfiniteClusters } from "@/queries/loaders";
import useAppState from "@/state";
import { ClusterCard } from "./ClusterCard";

export const ClusterView = () => {
	const { data, fetchNextPage, hasNextPage, isFetchingNextPage, isLoading } =
		useInfiniteClusters();
	const isDarkMode = useAppState((state) => state.isDarkMode);
	const observerRef = useRef<HTMLDivElement | null>(null);

	const allClusters = useMemo(() => {
		return data?.pages.flatMap((page) => page.clusters) ?? [];
	}, [data]);

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
			<div className="flex h-full items-center justify-center">
				<div
					className={`text-lg ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
				>
					Loading clusters...
				</div>
			</div>
		);
	}

	if (allClusters.length === 0) {
		return (
			<div className="flex h-full items-center justify-center">
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
		<div className="h-full overflow-y-auto p-4">
			<div className="mb-4">
				<h2
					className={`text-2xl font-bold ${isDarkMode ? "text-white" : "text-gray-900"}`}
				>
					Similar Photos
				</h2>
				<p
					className={`mt-1 text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
				>
					{allClusters.length} group{allClusters.length !== 1 ? "s" : ""} of
					similar images
				</p>
			</div>

			<div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
				{allClusters.map((cluster) => (
					<ClusterCard key={cluster.clusterId} cluster={cluster} />
				))}
			</div>

			{isFetchingNextPage && (
				<div className="mt-4 flex justify-center py-4">
					<div
						className={`text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
					>
						Loading more clusters...
					</div>
				</div>
			)}

			{hasNextPage && <div ref={observerRef} className="h-4" />}
		</div>
	);
};
