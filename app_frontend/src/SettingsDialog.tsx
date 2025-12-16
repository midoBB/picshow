import * as Dialog from "@radix-ui/react-dialog";
import * as Select from "@radix-ui/react-select";
import { useSettings, useUpdateSettings } from "@/queries/loaders";
import useAppState from "@/state";
import { FaChevronDown, FaSave, FaTimes } from "react-icons/fa";
import { useState, useEffect } from "react";
import type {
  AppSettings,
  DuplicateHandling,
  DeleteMode,
} from "@/queries/model";

interface SettingsDialogProps {
  isOpen: boolean;
  onClose: () => void;
}

const SettingsDialog = ({ isOpen, onClose }: SettingsDialogProps) => {
  const { data: settings, isLoading, isError, error } = useSettings();
  const { mutate: updateSettings, isPending } = useUpdateSettings();
  const { isDarkMode } = useAppState();

  const [duplicateHandling, setDuplicateHandling] =
    useState<DuplicateHandling>("movetofolder");
  const [deleteMode, setDeleteMode] = useState<DeleteMode>("movetotrash");
  const [autoRefreshEnabled, setAutoRefreshEnabled] = useState(true);
  const [autoRefreshDuration, setAutoRefreshDuration] = useState(3600);

  useEffect(() => {
    if (settings) {
      setDuplicateHandling(settings.duplicateHandling);
      setDeleteMode(settings.deleteMode);
      setAutoRefreshEnabled(settings.autoRefreshEnabled);
      setAutoRefreshDuration(settings.autoRefreshDuration);
    }
  }, [settings]);

  const handleSave = () => {
    updateSettings(
      {
        duplicateHandling,
        deleteMode,
        autoRefreshEnabled,
        autoRefreshDuration,
      },
      {
        onSuccess: () => {
          onClose();
        },
      },
    );
  };

  const formatDuplicateHandlingLabel = (value: DuplicateHandling): string => {
    switch (value) {
      case "movetofolder":
        return "Move to Folder";
      case "delete":
        return "Delete";
      case "skip":
        return "Skip";
      default:
        return value;
    }
  };

  const formatDeleteModeLabel = (value: DeleteMode): string => {
    switch (value) {
      case "movetotrash":
        return "Move to Trash";
      case "deletepermanently":
        return "Delete Permanently";
      default:
        return value;
    }
  };

  const formatDuration = (seconds: number): string => {
    const hours = Math.floor(seconds / 3600);
    return `${hours} hour${hours !== 1 ? "s" : ""}`;
  };

  return (
    <Dialog.Root open={isOpen} onOpenChange={onClose}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black bg-opacity-50 z-50" />
        <Dialog.Content
          className={`fixed top-1/2 left-1/2 transform -translate-x-1/2 -translate-y-1/2 ${isDarkMode ? "bg-gray-800 text-white" : "bg-white text-gray-900"} p-6 rounded-lg shadow-xl w-full max-w-md z-50`}
        >
          <div className="flex justify-between items-center mb-6">
            <Dialog.Title className="text-2xl font-bold">Settings</Dialog.Title>
            <Dialog.Close asChild>
              <button
                className={`p-2 rounded-full ${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-200"}`}
                aria-label="Close"
              >
                <FaTimes size={20} />
              </button>
            </Dialog.Close>
          </div>

          {isError ? (
            <div className="flex justify-center items-center h-40">
              <div className="text-center">
                <p
                  className={`text-lg font-semibold mb-2 ${isDarkMode ? "text-red-400" : "text-red-600"}`}
                >
                  Error Loading Settings
                </p>
                <p
                  className={`text-sm ${isDarkMode ? "text-gray-400" : "text-gray-600"}`}
                >
                  {error instanceof Error
                    ? error.message
                    : "Failed to load settings. Please try again."}
                </p>
              </div>
            </div>
          ) : isLoading ? (
            <div className="flex justify-center items-center h-40">
              <div
                className={`animate-spin rounded-full h-12 w-12 border-t-2 border-b-2 ${isDarkMode ? "border-white" : "border-gray-900"}`}
              ></div>
            </div>
          ) : (
            <div className="space-y-6">
              {/* Duplicate Handling */}
              <div>
                <label
                  className={`block text-sm font-medium mb-2 ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
                >
                  Duplicate Handling
                </label>
                <Select.Root
                  value={duplicateHandling}
                  onValueChange={(value) =>
                    setDuplicateHandling(value as DuplicateHandling)
                  }
                >
                  <Select.Trigger
                    className={`w-full ${isDarkMode ? "bg-gray-700" : "bg-gray-200"} text-sm rounded-md px-3 py-2 inline-flex items-center justify-between`}
                  >
                    <Select.Value>
                      {formatDuplicateHandlingLabel(duplicateHandling)}
                    </Select.Value>
                    <Select.Icon className="ml-2">
                      <FaChevronDown size={16} />
                    </Select.Icon>
                  </Select.Trigger>
                  <Select.Portal>
                    <Select.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} rounded-md shadow-lg z-50`}
                    >
                      <Select.Viewport className="p-1">
                        <Select.Item
                          value="movetofolder"
                          className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-600" : "hover:bg-gray-100"} rounded px-2 py-1`}
                        >
                          <Select.ItemText>Move to Folder</Select.ItemText>
                        </Select.Item>
                        <Select.Item
                          value="delete"
                          className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-600" : "hover:bg-gray-100"} rounded px-2 py-1`}
                        >
                          <Select.ItemText>Delete</Select.ItemText>
                        </Select.Item>
                        <Select.Item
                          value="skip"
                          className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-600" : "hover:bg-gray-100"} rounded px-2 py-1`}
                        >
                          <Select.ItemText>Skip</Select.ItemText>
                        </Select.Item>
                      </Select.Viewport>
                    </Select.Content>
                  </Select.Portal>
                </Select.Root>
                <p
                  className={`text-xs mt-1 ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
                >
                  What to do when duplicate files are found
                </p>
              </div>

              {/* Delete Mode */}
              <div>
                <label
                  className={`block text-sm font-medium mb-2 ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
                >
                  Delete Mode
                </label>
                <Select.Root
                  value={deleteMode}
                  onValueChange={(value) => setDeleteMode(value as DeleteMode)}
                >
                  <Select.Trigger
                    className={`w-full ${isDarkMode ? "bg-gray-700" : "bg-gray-200"} text-sm rounded-md px-3 py-2 inline-flex items-center justify-between`}
                  >
                    <Select.Value>
                      {formatDeleteModeLabel(deleteMode)}
                    </Select.Value>
                    <Select.Icon className="ml-2">
                      <FaChevronDown size={16} />
                    </Select.Icon>
                  </Select.Trigger>
                  <Select.Portal>
                    <Select.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} rounded-md shadow-lg z-50`}
                    >
                      <Select.Viewport className="p-1">
                        <Select.Item
                          value="movetotrash"
                          className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-600" : "hover:bg-gray-100"} rounded px-2 py-1`}
                        >
                          <Select.ItemText>Move to Trash</Select.ItemText>
                        </Select.Item>
                        <Select.Item
                          value="deletepermanently"
                          className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-600" : "hover:bg-gray-100"} rounded px-2 py-1`}
                        >
                          <Select.ItemText>Delete Permanently</Select.ItemText>
                        </Select.Item>
                      </Select.Viewport>
                    </Select.Content>
                  </Select.Portal>
                </Select.Root>
                <p
                  className={`text-xs mt-1 ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
                >
                  How files should be deleted
                </p>
              </div>

              {/* Auto Refresh Enabled */}
              <div>
                <label className="flex items-center cursor-pointer">
                  <input
                    type="checkbox"
                    checked={autoRefreshEnabled}
                    onChange={(e) => setAutoRefreshEnabled(e.target.checked)}
                    className="mr-2 w-4 h-4"
                  />
                  <span
                    className={`text-sm font-medium ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
                  >
                    Enable Auto Refresh
                  </span>
                </label>
                <p
                  className={`text-xs mt-1 ml-6 ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
                >
                  Automatically scan for new files
                </p>
              </div>

              {/* Auto Refresh Duration */}
              <div>
                <label
                  className={`block text-sm font-medium mb-2 ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
                >
                  Auto Refresh Duration
                </label>
                <div className="flex items-center space-x-2">
                  <input
                    type="range"
                    min="3600"
                    max="86400"
                    step="3600"
                    value={autoRefreshDuration}
                    onChange={(e) =>
                      setAutoRefreshDuration(parseInt(e.target.value))
                    }
                    className="flex-1"
                    disabled={!autoRefreshEnabled}
                  />
                  <span
                    className={`text-sm min-w-[80px] ${isDarkMode ? "text-gray-300" : "text-gray-700"}`}
                  >
                    {formatDuration(autoRefreshDuration)}
                  </span>
                </div>
                <p
                  className={`text-xs mt-1 ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
                >
                  How often to scan for new files (1-24 hours)
                </p>
              </div>
            </div>
          )}

          <div className="mt-6 flex justify-end space-x-2">
            <Dialog.Close asChild>
              <button
                className={`px-4 py-2 rounded ${
                  isDarkMode
                    ? "bg-gray-700 hover:bg-gray-600 text-white"
                    : "bg-gray-200 hover:bg-gray-300 text-gray-800"
                } transition-colors duration-200`}
              >
                Cancel
              </button>
            </Dialog.Close>
            <button
              onClick={handleSave}
              disabled={isPending || isLoading}
              className={`px-4 py-2 rounded flex items-center space-x-2 ${
                isDarkMode
                  ? "bg-blue-600 hover:bg-blue-700 text-white"
                  : "bg-blue-500 hover:bg-blue-600 text-white"
              } transition-colors duration-200 disabled:opacity-50 disabled:cursor-not-allowed`}
            >
              <FaSave size={16} />
              <span>{isPending ? "Saving..." : "Save"}</span>
            </button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
};

export default SettingsDialog;
