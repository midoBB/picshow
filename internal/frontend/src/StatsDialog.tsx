import * as Dialog from "@radix-ui/react-dialog";
import { useStats } from "@/queries/loaders";

interface StatsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

const StatsDialog = ({ isOpen, onClose }: StatsDialogProps) => {
  const { data: stats, isLoading } = useStats();

  return (
    <Dialog.Root open={isOpen} onOpenChange={onClose}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black bg-opacity-50" />
        <Dialog.Content className="fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 bg-gray-800 text-white p-6 rounded-lg shadow-xl">
          <Dialog.Title className="text-2xl font-bold mb-4">Stats</Dialog.Title>
          {isLoading ? (
            <p>Loading stats...</p>
          ) : (
            <div>
              <p>Total Files: {stats?.count}</p>
              <p>Image Count: {stats?.image_count}</p>
              <p>Video Count: {stats?.video_count}</p>
            </div>
          )}
          <Dialog.Close asChild>
            <button className="mt-4 bg-gray-700 hover:bg-gray-600 px-4 py-2 rounded">
              Close
            </button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};

export default StatsDialog;
