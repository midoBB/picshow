import * as Dialog from "@radix-ui/react-dialog";
import { useStats } from "@/queries/loaders";
import useAppState from "@/state";
import { FaImages, FaVideo, FaFileAlt } from "react-icons/fa";

interface StatsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

const StatsDialog = ({ isOpen, onClose }: StatsDialogProps) => {
  const { data: stats, isLoading } = useStats();
  const { isDarkMode } = useAppState();

  const StatCard = ({
    icon,
    title,
    value,
  }: {
    icon: React.ReactNode;
    title: string;
    value: number | undefined;
  }) => (
    <div
      className={`${isDarkMode ? "bg-gray-700" : "bg-gray-100"} p-4 rounded-lg flex items-center space-x-4`}
    >
      <div className={`${isDarkMode ? "text-gray-300" : "text-gray-600"}`}>
        {icon}
      </div>
      <div>
        <h3
          className={`text-lg font-semibold ${isDarkMode ? "text-gray-200" : "text-gray-800"}`}
        >
          {title}
        </h3>
        <p
          className={`text-2xl font-bold ${isDarkMode ? "text-white" : "text-gray-900"}`}
        >
          {value?.toLocaleString() ?? "N/A"}
        </p>
      </div>
    </div>
  );

  return (
    <Dialog.Root open={isOpen} onOpenChange={onClose}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black bg-opacity-50" />
        <Dialog.Content
          className={`fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 ${isDarkMode ? "bg-gray-800 text-white" : "bg-white text-gray-900"} p-6 rounded-lg shadow-xl w-full max-w-md`}
        >
          <Dialog.Title className="text-2xl font-bold mb-6">
            Media Statistics
          </Dialog.Title>
          {isLoading ? (
            <div className="flex justify-center items-center h-40">
              <div
                className={`animate-spin rounded-full h-12 w-12 border-t-2 border-b-2 ${isDarkMode ? "border-white" : "border-gray-900"}`}
              ></div>
            </div>
          ) : (
            <div className="space-y-4">
              <StatCard
                icon={<FaFileAlt size={24} />}
                title="Total Files"
                value={stats?.count}
              />
              <StatCard
                icon={<FaImages size={24} />}
                title="Images"
                value={stats?.image_count}
              />
              <StatCard
                icon={<FaVideo size={24} />}
                title="Videos"
                value={stats?.video_count}
              />
            </div>
          )}
          <div className="mt-6 flex justify-end">
            <Dialog.Close asChild>
              <button
                className={`px-4 py-2 rounded ${
                  isDarkMode
                    ? "bg-gray-700 hover:bg-gray-600 text-white"
                    : "bg-gray-200 hover:bg-gray-300 text-gray-800"
                } transition-colors duration-200`}
              >
                Close
              </button>
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};

export default StatsDialog;
