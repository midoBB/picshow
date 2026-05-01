import * as Select from "@radix-ui/react-select";
import * as Tooltip from "@radix-ui/react-tooltip";
import type { Options } from "nuqs";
import { useEffect, useState } from "react";
import {
  FaChartBar,
  FaChevronDown,
  FaCog,
  FaDice,
  FaLayerGroup,
  FaMoon,
  FaRegCalendarAlt,
  FaSortAmountDown,
  FaSortAmountUp,
  FaSpinner,
  FaSun,
  FaSync,
  FaTh,
  FaTrash,
  FaUndo,
} from "react-icons/fa";
import { FaShuffle } from "react-icons/fa6";
import { useProcessorStatus } from "@/hooks/useProcessorStatus";
import { useTriggerScan } from "@/queries/loaders";
import SettingsDialog from "@/SettingsDialog";
import StatsDialog from "@/StatsDialog";
import useAppState from "@/state";

interface TooltipButtonProps {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  ariaLabel: string;
  isDarkMode: boolean;
  disabled?: boolean;
}

const TooltipButton = ({
  icon,
  label,
  onClick,
  ariaLabel,
  isDarkMode,
  disabled = false,
}: TooltipButtonProps) => {
  return (
    <Tooltip.Provider>
      <Tooltip.Root>
        <Tooltip.Trigger asChild>
          <button
            type="button"
            onClick={onClick}
            disabled={disabled}
            className={`${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-200"} p-1.5 sm:p-2 rounded-full ${
              disabled ? "opacity-50 cursor-not-allowed" : ""
            }`}
            aria-label={ariaLabel}
          >
            {icon}
          </button>
        </Tooltip.Trigger>

        <Tooltip.Portal>
          <Tooltip.Content
            className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
          >
            {label}
            <Tooltip.Arrow
              className={`${isDarkMode ? "fill-gray-700" : "fill-white"}`}
            />
          </Tooltip.Content>
        </Tooltip.Portal>
      </Tooltip.Root>
    </Tooltip.Provider>
  );
};

const Navbar = ({
  onDelete,
  setSeed,
  setSelectedCategory,
  setSortDirection,
  setSortType,
  sortDirection,
  sortType,
  selectedCategory,
  viewMode,
  setViewMode,
}: {
  onDelete: () => void;
  setSeed: (
    value: number | ((old: number | null) => number | null) | null,
    options?: Options,
  ) => Promise<URLSearchParams>;
  setSelectedCategory: (
    value:
      | "video"
      | "image"
      | "all"
      | "favorite"
      | ((
          old: "video" | "image" | "all" | "favorite",
        ) => ("video" | "image" | "all" | "favorite") | null)
      | null,
    options?: Options,
  ) => Promise<URLSearchParams>;
  setSortDirection: (
    value:
      | "desc"
      | "asc"
      | ((old: "desc" | "asc") => ("desc" | "asc") | null)
      | null,
    options?: Options,
  ) => Promise<URLSearchParams>;
  setSortType: (
    value:
      | "created_at"
      | "random"
      | ((old: "created_at" | "random") => ("created_at" | "random") | null)
      | null,
    options?: Options,
  ) => Promise<URLSearchParams>;
  sortDirection: "asc" | "desc";
  sortType: "created_at" | "random";
  selectedCategory: "all" | "video" | "image" | "favorite";
  viewMode: "gallery" | "clusters";
  setViewMode: (
    value:
      | "gallery"
      | "clusters"
      | ((
          old: "gallery" | "clusters",
        ) => "gallery" | "clusters" | null)
      | null,
    options?: Options,
  ) => Promise<URLSearchParams>;
}) => {
  const [isStatsOpen, setIsStatsOpen] = useState(false);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const { isProcessing } = useProcessorStatus();
  const { mutate: triggerScan } = useTriggerScan();
  const {
    isSelectionMode,
    selectedCount,
    setIsSelectionMode,
    setSelectedFiles,
    isDarkMode,
    toggleDarkMode,
  } = useAppState();

  const toggleSortDirection = () => {
    setSortDirection(sortDirection === "desc" ? "asc" : "desc");
  };

  const [isSortDirectionDisabled, setIsSortDirectionDisabled] = useState(true);
  useEffect(() => {
    setIsSortDirectionDisabled(sortType === "random");
  }, [sortType]);
  const toggleSortType = () => {
    const newType = sortType === "created_at" ? "random" : "created_at";
    if (newType === "created_at") {
      setSeed(null);
    } else {
      handleReseed();
    }
    setSortType(newType);
    setSortDirection(newType === "random" ? "desc" : sortDirection);
  };
  const handleReseed = () => {
    const randomOffset = Math.floor(Math.random() * 1000); // Random number between 0 and 999
    const randomMultiplier = Math.random() + 0.5; // Random multiplier between 0.5 and 1.5
    const newSeed = Math.floor(
      (Date.now() / 1000 + randomOffset) * randomMultiplier,
    );
    setSeed(newSeed);
  };

  function resetSelection() {
    setIsSelectionMode(false);
    setSelectedFiles(() => []);
  }

  return (
    <nav
      className={`${isDarkMode ? "bg-gray-900 text-white" : "bg-white text-gray-900"} p-4 sticky top-0 z-50 shadow-md`}
    >
      <div className="container mx-auto flex justify-between items-center">
        <div className="flex items-center">
          {isSelectionMode ? (
            <span className="text-sm font-medium">
              {selectedCount()} selected
            </span>
          ) : (
            <Select.Root
              value={selectedCategory}
              onValueChange={setSelectedCategory}
            >
              <Select.Trigger
                className={`${isDarkMode ? "bg-gray-800" : "bg-gray-200"} text-sm rounded-md px-3 py-2 inline-flex items-center justify-center`}
              >
                <Select.Value placeholder="Select a category">
                  {selectedCategory.charAt(0).toUpperCase() +
                    selectedCategory.slice(1)}
                </Select.Value>
                <Select.Icon className="ml-2">
                  <FaChevronDown className="w-4 h-4 sm:w-4 sm:h-4" />
                </Select.Icon>
              </Select.Trigger>
              <Select.Portal>
                <Select.Content
                  className={`${isDarkMode ? "bg-gray-800 text-white" : "bg-white text-gray-900"} rounded-md shadow-lg z-50`}
                >
                  <Select.Viewport className="p-1">
                    <Select.Item
                      value="all"
                      className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>All </Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="video"
                      className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Video </Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="image"
                      className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Image </Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="favorite"
                      className={`cursor-pointer ${isDarkMode ? "hover:bg-gray-700" : "hover:bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Favorites </Select.ItemText>
                    </Select.Item>
                  </Select.Viewport>
                </Select.Content>
              </Select.Portal>
            </Select.Root>
          )}
        </div>
        <div className="flex items-center space-x-2 sm:space-x-4">
          {isSelectionMode ? (
            <>
              <TooltipButton
                icon={<FaTrash className="w-4 h-4 sm:w-5 sm:h-5" />}
                label="Delete Selected"
                onClick={onDelete}
                ariaLabel="Delete selected files"
                isDarkMode={isDarkMode}
              />
              <TooltipButton
                icon={<FaUndo className="w-4 h-4 sm:w-5 sm:h-5" />}
                label="Exit Selection Mode"
                onClick={resetSelection}
                ariaLabel="Exit selection mode"
                isDarkMode={isDarkMode}
              />
            </>
          ) : (
            <>
              {isSortDirectionDisabled ? (
                <TooltipButton
                  icon={<FaDice className="w-4 h-4 sm:w-5 sm:h-5" />}
                  label="Reseed random order"
                  onClick={handleReseed}
                  ariaLabel="Reseed random order"
                  isDarkMode={isDarkMode}
                />
              ) : (
                <TooltipButton
                  icon={
                    sortDirection === "desc" ? (
                      <FaSortAmountDown className="w-4 h-4 sm:w-5 sm:h-5" />
                    ) : (
                      <FaSortAmountUp className="w-4 h-4 sm:w-5 sm:h-5" />
                    )
                  }
                  label={
                    sortDirection === "desc"
                      ? "Sort Descending"
                      : "Sort Ascending"
                  }
                  onClick={toggleSortDirection}
                  ariaLabel={`Sort ${sortDirection === "desc" ? "descending" : "ascending"}`}
                  isDarkMode={isDarkMode}
                />
              )}
              <TooltipButton
                icon={
                  sortType === "created_at" ? (
                    <FaRegCalendarAlt className="w-4 h-4 sm:w-5 sm:h-5" />
                  ) : (
                    <FaShuffle className="w-4 h-4 sm:w-5 sm:h-5" />
                  )
                }
                label={
                  sortType === "created_at" ? "Sort by Date" : "Sort Randomly"
                }
                onClick={toggleSortType}
                ariaLabel={`Sort by ${sortType === "created_at" ? "date" : "random"}`}
                isDarkMode={isDarkMode}
              />
              <TooltipButton
                icon={
                  viewMode === "gallery" ? (
                    <FaLayerGroup className="w-4 h-4 sm:w-5 sm:h-5" />
                  ) : (
                    <FaTh className="w-4 h-4 sm:w-5 sm:h-5" />
                  )
                }
                label={
                  viewMode === "gallery"
                    ? "View Similar Photos"
                    : "View Gallery"
                }
                onClick={() =>
                  setViewMode(viewMode === "gallery" ? "clusters" : "gallery")
                }
                ariaLabel={
                  viewMode === "gallery"
                    ? "View similar photos clusters"
                    : "View gallery"
                }
                isDarkMode={isDarkMode}
              />
              <TooltipButton
                icon={<FaChartBar className="w-4 h-4 sm:w-5 sm:h-5" />}
                label="View Stats"
                onClick={() => setIsStatsOpen(true)}
                ariaLabel="View statistics"
                isDarkMode={isDarkMode}
              />
              <TooltipButton
                icon={<FaCog className="w-4 h-4 sm:w-5 sm:h-5" />}
                label="Settings"
                onClick={() => setIsSettingsOpen(true)}
                ariaLabel="Open settings"
                isDarkMode={isDarkMode}
              />
              <TooltipButton
                icon={<FaSync className="w-4 h-4 sm:w-5 sm:h-5" />}
                label="Trigger Scan"
                onClick={() => triggerScan()}
                ariaLabel="Manually trigger a scan for new files"
                isDarkMode={isDarkMode}
                disabled={isProcessing}
              />
            </>
          )}
          {/* Processing/Connection Status Indicator */}
          <div className="flex items-center">
            {isProcessing ? (
              <div className="animate-spin">
                <FaSpinner
                  className={`w-4 h-4 sm:w-5 sm:h-5 ${isDarkMode ? "text-white" : "text-gray-900"}`}
                  title="Processing files..."
                />
              </div>
            ) : null}
          </div>
          <TooltipButton
            icon={
              isDarkMode ? (
                <FaSun className="w-4 h-4 sm:w-5 sm:h-5" />
              ) : (
                <FaMoon className="w-4 h-4 sm:w-5 sm:h-5" />
              )
            }
            label={isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"}
            onClick={toggleDarkMode}
            ariaLabel={`Switch to ${isDarkMode ? "light" : "dark"} mode`}
            isDarkMode={isDarkMode}
          />
        </div>
      </div>
      <StatsDialog isOpen={isStatsOpen} onClose={() => setIsStatsOpen(false)} />
      <SettingsDialog
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
      />
    </nav>
  );
};

export default Navbar;
