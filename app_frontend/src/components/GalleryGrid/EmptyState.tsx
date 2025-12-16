import { FaRegPlayCircle } from "react-icons/fa";

interface EmptyStateProps {
  selectedCategory: "all" | "video" | "image" | "favorite";
  isDarkMode: boolean;
}

export const EmptyState = ({
  selectedCategory,
  isDarkMode,
}: EmptyStateProps) => {
  return (
    <div
      className={`flex flex-col items-center justify-center h-full ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
    >
      <FaRegPlayCircle size={64} className="mb-4 opacity-50" />
      <h2 className="text-2xl font-bold mb-2">No Media Found</h2>
      <p className="text-center max-w-md">
        {selectedCategory === "favorite"
          ? "You haven't favorited any files yet. Click the heart icon on any image or video to add it to your favorites."
          : selectedCategory !== "all"
            ? `No ${selectedCategory}s found. Try selecting a different filter.`
            : "No media files found. Make sure your media folder contains images or videos."}
      </p>
    </div>
  );
};
