import { useCallback, useState } from "react";
import { FaCheck } from "react-icons/fa";
import { toast } from "sonner";
import {
  useClusterDetail,
  useMarkClusterResolved,
  useResolveCluster,
} from "@/queries/loaders";
import useAppState from "@/state";

interface ClusterDetailDialogProps {
  clusterId: number;
  onClose: () => void;
}

export const ClusterDetailDialog = ({
  clusterId,
  onClose,
}: ClusterDetailDialogProps) => {
  const { data: clusterDetail, isLoading } = useClusterDetail(clusterId);
  const resolveClusterMutation = useResolveCluster();
  const markResolvedMutation = useMarkClusterResolved();
  const [selectedBest, setSelectedBest] = useState<Set<string>>(new Set());
  const isDarkMode = useAppState((state) => state.isDarkMode);

  const handleResolve = async () => {
    if (selectedBest.size === 0) {
      toast.error("Please select at least one photo to keep");
      return;
    }

    try {
      await resolveClusterMutation.mutateAsync({
        clusterId,
        bestShotIds: Array.from(selectedBest),
        deleteOthers: true,
      });
      toast.success("Cluster resolved successfully");
      onClose();
    } catch (error) {
      toast.error("Failed to resolve cluster");
      console.error(error);
    }
  };

  const handleMarkResolved = async () => {
    const allIds = clusterDetail?.images.map((img) => img.id) ?? [];

    if (allIds.length === 0) {
      toast.error("No images in this cluster");
      return;
    }

    try {
      await markResolvedMutation.mutateAsync({
        clusterId,
        bestShotIds: allIds,
      });
      toast.success("Cluster marked as resolved");
      onClose();
    } catch (error) {
      toast.error("Failed to mark cluster as resolved");
      console.error(error);
    }
  };

  const toggleSelection = useCallback((id: string) => {
    setSelectedBest((prev) => {
      const next = new Set(prev);
      if (next.has(id)) {
        next.delete(id);
      } else {
        next.add(id);
      }
      return next;
    });
  }, []);

  const handleBackdropClick = (e: React.MouseEvent<HTMLDivElement>) => {
    if (e.target === e.currentTarget) {
      onClose();
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm p-4"
      onClick={handleBackdropClick}
    >
      <div
        className={`relative max-h-[90vh] w-full max-w-6xl overflow-hidden rounded-2xl shadow-2xl ${
          isDarkMode ? "bg-gray-900" : "bg-white"
        }`}
        onClick={(e) => e.stopPropagation()}
      >
        <div
          className={`border-b px-6 py-4 ${isDarkMode ? "border-gray-700" : "border-gray-200"}`}
        >
          <div className="flex items-center justify-between">
            <div>
              <h2
                className={`text-xl font-semibold ${isDarkMode ? "text-white" : "text-gray-900"}`}
              >
                Select Best Shot
              </h2>
              <p
                className={`mt-1 text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
              >
                {clusterDetail?.images.length ?? 0} similar images found
              </p>
            </div>
            <button
              onClick={onClose}
              className={`rounded-full p-2 transition-colors ${
                isDarkMode
                  ? "text-gray-400 hover:bg-gray-800 hover:text-white"
                  : "text-gray-600 hover:bg-gray-100 hover:text-gray-900"
              }`}
            >
              <svg
                className="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
          </div>
        </div>

        <div className="max-h-[calc(90vh-180px)] overflow-y-auto p-6">
          {isLoading ? (
            <div className="flex h-64 items-center justify-center">
              <div
                className={`text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
              >
                Loading images...
              </div>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
              {clusterDetail?.images.map((img) => (
                <div
                  key={img.id}
                  className={`group relative cursor-pointer overflow-hidden rounded-xl border-2 transition-all duration-200 ${
                    selectedBest.has(img.id)
                      ? "border-blue-500 shadow-lg shadow-blue-500/20"
                      : isDarkMode
                        ? "border-gray-700 hover:border-gray-500"
                        : "border-gray-200 hover:border-gray-400"
                  }`}
                  onClick={() => toggleSelection(img.id)}
                >
                  <div className="relative aspect-square">
                    <img
                      src={img.thumbnail}
                      className="h-full w-full object-cover"
                      alt={img.filename}
                    />

                    {img.isBestShot && (
                      <div className="absolute left-2 top-2 rounded-full bg-emerald-500 px-2 py-0.5 text-xs font-medium text-white shadow-lg">
                        Current Best
                      </div>
                    )}

                    {selectedBest.has(img.id) && (
                      <div className="absolute inset-0 flex items-center justify-center bg-blue-500/20">
                        <div className="rounded-full bg-blue-500 p-2.5 shadow-lg">
                          <FaCheck className="h-5 w-5 text-white" />
                        </div>
                      </div>
                    )}

                    <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent p-3 opacity-0 transition-opacity group-hover:opacity-100">
                      <div className="truncate text-xs font-medium text-white">
                        {img.filename}
                      </div>
                      <div className="mt-0.5 text-xs text-gray-300">
                        {Math.round((1 - img.hammingDistance / 64) * 100)}%
                        match · {img.width}x{img.height}
                      </div>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        <div
          className={`border-t px-6 py-4 ${isDarkMode ? "border-gray-700" : "border-gray-200"}`}
        >
          <div className="flex items-center justify-between">
            <p
              className={`text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
            >
              {selectedBest.size > 0
                ? `${selectedBest.size} photo${selectedBest.size > 1 ? "s" : ""} selected — others will be deleted`
                : "Select photos to keep"}
            </p>
            <div className="flex gap-2">
              <button
                onClick={handleMarkResolved}
                disabled={markResolvedMutation.isPending}
                className={`rounded-lg px-4 py-2 text-sm font-medium transition-all ${
                  markResolvedMutation.isPending
                    ? "cursor-not-allowed bg-gray-400 text-white"
                    : isDarkMode
                      ? "bg-gray-700 text-gray-200 hover:bg-gray-600"
                      : "bg-gray-200 text-gray-700 hover:bg-gray-300"
                }`}
              >
                {markResolvedMutation.isPending
                  ? "Marking..."
                  : "Mark Resolved"}
              </button>
              <button
                onClick={onClose}
                className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
                  isDarkMode
                    ? "bg-gray-800 text-gray-300 hover:bg-gray-700"
                    : "bg-gray-100 text-gray-700 hover:bg-gray-200"
                }`}
              >
                Cancel
              </button>
              <button
                onClick={handleResolve}
                disabled={
                  selectedBest.size === 0 || resolveClusterMutation.isPending
                }
                className={`rounded-lg px-4 py-2 text-sm font-medium text-white transition-all ${
                  selectedBest.size === 0 || resolveClusterMutation.isPending
                    ? "cursor-not-allowed bg-gray-400"
                    : "bg-blue-600 hover:bg-blue-700 hover:shadow-lg hover:shadow-blue-500/25"
                }`}
              >
                {resolveClusterMutation.isPending
                  ? "Resolving..."
                  : "Keep Selected & Delete Others"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};
