import { format } from "date-fns";
import { useState } from "react";
import type { ClusterDTO } from "@/queries/model";
import useAppState from "@/state";
import { ClusterDetailDialog } from "./ClusterDetailDialog";

interface ClusterCardProps {
  cluster: ClusterDTO;
}

export const ClusterCard = ({ cluster }: ClusterCardProps) => {
  const [isExpanded, setIsExpanded] = useState(false);
  const isDarkMode = useAppState((state) => state.isDarkMode);

  return (
    <>
      <div
        className={`group cursor-pointer overflow-hidden rounded-xl border shadow-md transition-all duration-200 hover:shadow-xl hover:scale-[1.02] ${
          isDarkMode
            ? "border-gray-700/50 bg-gray-800/80 hover:border-gray-600"
            : "border-gray-200 bg-white hover:border-gray-300"
        }`}
        onClick={() => setIsExpanded(true)}
      >
        <div
          className={`grid grid-cols-2 gap-0.5 ${isDarkMode ? "bg-gray-900" : "bg-gray-100"}`}
        >
          {cluster.previewThumbnails.slice(0, 4).map((thumb, i) => (
            <div key={i} className="relative aspect-square">
              <img
                src={thumb}
                className="h-full w-full object-cover"
                alt={`Preview ${i + 1}`}
                loading="lazy"
              />
            </div>
          ))}
          {Array.from({
            length: Math.max(0, 4 - cluster.previewThumbnails.length),
          }).map((_, i) => (
            <div
              key={`placeholder-${i}`}
              className={`aspect-square ${isDarkMode ? "bg-gray-800" : "bg-gray-200"}`}
            />
          ))}
        </div>

        <div className="p-3">
          <div className="flex items-center justify-between">
            <span
              className={`text-sm font-medium ${isDarkMode ? "text-gray-200" : "text-gray-900"}`}
            >
              {cluster.imageCount} similar photo
              {cluster.imageCount !== 1 ? "s" : ""}
            </span>
            {cluster.isResolved && (
              <span className="rounded-full bg-emerald-500/90 px-2 py-0.5 text-xs font-medium text-white shadow-sm">
                Resolved
              </span>
            )}
          </div>
          <span
            className={`mt-1 block text-xs ${isDarkMode ? "text-gray-500" : "text-gray-500"}`}
          >
            {format(cluster.createdAt, "MMM d, yyyy")}
          </span>
        </div>
      </div>

      {isExpanded && (
        <ClusterDetailDialog
          clusterId={cluster.clusterId}
          onClose={() => setIsExpanded(false)}
        />
      )}
    </>
  );
};
