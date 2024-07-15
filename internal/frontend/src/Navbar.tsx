import { useState } from "react";
import StatsDialog from "@/StatsDialog";
import * as Select from "@radix-ui/react-select";
import * as Tooltip from "@radix-ui/react-tooltip";
import {
  FaUndo,
  FaChartBar,
  FaTrash,
  FaSortAmountDown,
  FaSortAmountUp,
  FaRegCalendarAlt,
  FaChevronDown,
  FaDice,
  FaMoon,
  FaSun,
} from "react-icons/fa";
import { FaShuffle } from "react-icons/fa6";
import useAppState from "@/state";

const Navbar = ({ onDelete }: { onDelete: () => void }) => {
  const [isStatsOpen, setIsStatsOpen] = useState(false);
  const {
    sortDirection,
    sortType,
    selectedCategory,
    isSortDirectionDisabled,
    toggleSortDirection,
    toggleSortType,
    setSelectedCategory,
    setSeed,
    isSelectionMode,
    selectedCount,
    setIsSelectionMode,
    setSelectedFiles,
    isDarkMode,
    toggleDarkMode,
  } = useAppState();

  const handleReseed = () => {
    setSeed(Math.floor(Date.now() / 1000));
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
                  <FaChevronDown size={16} />
                </Select.Icon>
              </Select.Trigger>
              <Select.Portal>
                <Select.Content
                  className={`${isDarkMode ? "bg-gray-800 text-white" : "bg-white text-gray-900"} rounded-md shadow-lg z-50`}
                >
                  <Select.Viewport className="p-1">
                    <Select.Item
                      value="all"
                      className={`cursor-pointer hover:${isDarkMode ? "bg-gray-700" : "bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>All</Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="video"
                      className={`cursor-pointer hover:${isDarkMode ? "bg-gray-700" : "bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Video</Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="image"
                      className={`cursor-pointer hover:${isDarkMode ? "bg-gray-700" : "bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Image</Select.ItemText>
                    </Select.Item>
                    <Select.Item
                      value="favorite"
                      className={`cursor-pointer hover:${isDarkMode ? "bg-gray-700" : "bg-gray-100"} rounded px-2 py-1`}
                    >
                      <Select.ItemText>Favorites</Select.ItemText>
                    </Select.Item>
                  </Select.Viewport>
                </Select.Content>
              </Select.Portal>
            </Select.Root>
          )}
        </div>
        <div className="flex items-center space-x-4">
          {isSelectionMode ? (
            <>
              <Tooltip.Provider>
                <Tooltip.Root>
                  <Tooltip.Trigger asChild>
                    <button
                      onClick={onDelete}
                      className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                    >
                      <FaTrash size={20} />
                    </button>
                  </Tooltip.Trigger>
                  <Tooltip.Portal>
                    <Tooltip.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                    >
                      Delete Selected
                      <Tooltip.Arrow
                        className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                      />
                    </Tooltip.Content>
                  </Tooltip.Portal>
                </Tooltip.Root>
              </Tooltip.Provider>

              <Tooltip.Provider>
                <Tooltip.Root>
                  <Tooltip.Trigger asChild>
                    <button
                      onClick={resetSelection}
                      className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                    >
                      <FaUndo size={20} />
                    </button>
                  </Tooltip.Trigger>
                  <Tooltip.Portal>
                    <Tooltip.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                    >
                      Exit Selection Mode
                      <Tooltip.Arrow
                        className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                      />
                    </Tooltip.Content>
                  </Tooltip.Portal>
                </Tooltip.Root>
              </Tooltip.Provider>
            </>
          ) : (
            <>
              <Tooltip.Provider>
                <Tooltip.Root>
                  <Tooltip.Trigger asChild>
                    {isSortDirectionDisabled ? (
                      <button
                        onClick={handleReseed}
                        className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                      >
                        <FaDice size={20} />
                      </button>
                    ) : (
                      <button
                        onClick={toggleSortDirection}
                        className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                      >
                        {sortDirection === "desc" ? (
                          <FaSortAmountDown size={20} />
                        ) : (
                          <FaSortAmountUp size={20} />
                        )}
                      </button>
                    )}
                  </Tooltip.Trigger>
                  <Tooltip.Portal>
                    <Tooltip.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                    >
                      {isSortDirectionDisabled
                        ? "Reseed random order"
                        : sortDirection === "desc"
                          ? "Sort Descending"
                          : "Sort Ascending"}
                      <Tooltip.Arrow
                        className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                      />
                    </Tooltip.Content>
                  </Tooltip.Portal>
                </Tooltip.Root>
              </Tooltip.Provider>

              <Tooltip.Provider>
                <Tooltip.Root>
                  <Tooltip.Trigger asChild>
                    <button
                      onClick={toggleSortType}
                      className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                    >
                      {sortType === "created_at" ? (
                        <FaRegCalendarAlt size={20} />
                      ) : (
                        <FaShuffle size={20} />
                      )}
                    </button>
                  </Tooltip.Trigger>
                  <Tooltip.Portal>
                    <Tooltip.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                    >
                      {sortType === "created_at"
                        ? "Sort by Date"
                        : "Sort Randomly"}
                      <Tooltip.Arrow
                        className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                      />
                    </Tooltip.Content>
                  </Tooltip.Portal>
                </Tooltip.Root>
              </Tooltip.Provider>
              <Tooltip.Provider>
                <Tooltip.Root>
                  <Tooltip.Trigger asChild>
                    <button
                      onClick={() => setIsStatsOpen(true)}
                      className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                    >
                      <FaChartBar size={20} />
                    </button>
                  </Tooltip.Trigger>
                  <Tooltip.Portal>
                    <Tooltip.Content
                      className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                    >
                      View Stats
                      <Tooltip.Arrow
                        className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                      />
                    </Tooltip.Content>
                  </Tooltip.Portal>
                </Tooltip.Root>
              </Tooltip.Provider>
            </>
          )}
          <Tooltip.Provider>
            <Tooltip.Root>
              <Tooltip.Trigger asChild>
                <button
                  onClick={toggleDarkMode}
                  className={`hover:${isDarkMode ? "bg-gray-700" : "bg-gray-200"} p-2 rounded-full`}
                >
                  {isDarkMode ? <FaSun size={20} /> : <FaMoon size={20} />}
                </button>
              </Tooltip.Trigger>
              <Tooltip.Portal>
                <Tooltip.Content
                  className={`${isDarkMode ? "bg-gray-700 text-white" : "bg-white text-gray-900"} px-2 py-1 rounded text-sm z-50`}
                >
                  {isDarkMode ? "Switch to Light Mode" : "Switch to Dark Mode"}
                  <Tooltip.Arrow
                    className={`fill-${isDarkMode ? "gray-700" : "white"}`}
                  />
                </Tooltip.Content>
              </Tooltip.Portal>
            </Tooltip.Root>
          </Tooltip.Provider>
        </div>
      </div>
      <StatsDialog isOpen={isStatsOpen} onClose={() => setIsStatsOpen(false)} />
    </nav>
  );
};

export default Navbar;
