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
				className={`group cursor-pointer overflow-hidden rounded-lg border transition-all hover:shadow-xl ${
					isDarkMode
						? "border-gray-700 bg-gray-800 hover:border-gray-600"
						: "border-gray-200 bg-white hover:border-gray-300"
				}`}
				onClick={() => setIsExpanded(true)}
			>
				{/* 2x2 grid of preview thumbnails */}
				<div
					className={`grid grid-cols-2 gap-1 ${isDarkMode ? "bg-gray-900" : "bg-gray-100"}`}
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
					{/* Fill remaining grid cells if less than 4 thumbnails */}
					{Array.from({
						length: Math.max(0, 4 - cluster.previewThumbnails.length),
					}).map((_, i) => (
						<div
							key={`placeholder-${i}`}
							className={`aspect-square ${isDarkMode ? "bg-gray-800" : "bg-gray-200"}`}
						/>
					))}
				</div>

				{/* Cluster metadata */}
				<div className="p-3">
					<div className="flex items-center justify-between">
						<span
							className={`text-sm font-medium ${isDarkMode ? "text-gray-200" : "text-gray-900"}`}
						>
							{cluster.imageCount} similar photo
							{cluster.imageCount !== 1 ? "s" : ""}
						</span>
						{cluster.isResolved && (
							<span className="rounded-full bg-green-500 px-2 py-1 text-xs text-white">
								Resolved
							</span>
						)}
					</div>
					<span
						className={`mt-1 block text-xs ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
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
