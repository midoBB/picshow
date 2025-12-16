interface FileItemSkeletonProps {
  isDarkMode: boolean;
}

export const FileItemSkeleton = ({ isDarkMode }: FileItemSkeletonProps) => {
  return (
    <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
      {Array.from({ length: 12 }).map((_, index) => (
        <div
          key={index}
          className={`aspect-square rounded-lg animate-pulse ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
        />
      ))}
    </div>
  );
};
