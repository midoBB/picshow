import * as Select from "@radix-ui/react-select";
import * as Tooltip from "@radix-ui/react-tooltip";
import {
  FaSortAmountDown,
  FaSortAmountUp,
  FaRegCalendarAlt,
  FaChevronDown,
} from "react-icons/fa";
import { FaShuffle } from "react-icons/fa6";
import useNavbarStore from "./state";

const Navbar = () => {
  const {
    sortDirection,
    sortType,
    selectedCategory,
    isSortDirectionDisabled,
    toggleSortDirection,
    toggleSortType,
    setSelectedCategory,
  } = useNavbarStore();

  return (
    <nav className="bg-gray-900 text-white p-4 sticky top-0 z-50 shadow-md">
      <div className="container mx-auto flex justify-between items-center">
        <div className="flex items-center">
          <Select.Root
            value={selectedCategory}
            onValueChange={setSelectedCategory}
          >
            <Select.Trigger className="bg-gray-800 text-sm rounded-md px-3 py-2 inline-flex items-center justify-center">
              <Select.Value placeholder="Select a category">
                {selectedCategory.charAt(0).toUpperCase() +
                  selectedCategory.slice(1)}
              </Select.Value>
              <Select.Icon className="ml-2">
                <FaChevronDown size={16} />
              </Select.Icon>
            </Select.Trigger>
            <Select.Portal>
              <Select.Content className="bg-gray-800 text-white rounded-md shadow-lg z-50">
                <Select.Viewport className="p-1">
                  <Select.Item
                    value="all"
                    className="cursor-pointer text-white hover:bg-gray-700 rounded px-2 py-1"
                  >
                    <Select.ItemText>All</Select.ItemText>
                  </Select.Item>
                  <Select.Item
                    value="video"
                    className="cursor-pointer text-white hover:bg-gray-700 rounded px-2 py-1"
                  >
                    <Select.ItemText>Video</Select.ItemText>
                  </Select.Item>
                  <Select.Item
                    value="image"
                    className="cursor-pointer text-white hover:bg-gray-700 rounded px-2 py-1"
                  >
                    <Select.ItemText>Image</Select.ItemText>
                  </Select.Item>
                </Select.Viewport>
              </Select.Content>
            </Select.Portal>
          </Select.Root>
        </div>
        <div className="flex items-center space-x-4">
          <Tooltip.Provider>
            <Tooltip.Root>
              <Tooltip.Trigger asChild>
                <button
                  onClick={toggleSortDirection}
                  className={`p-2 rounded-full ${
                    isSortDirectionDisabled
                      ? "opacity-50 cursor-not-allowed"
                      : "hover:bg-gray-700"
                  }`}
                  disabled={isSortDirectionDisabled}
                >
                  {sortDirection === "desc" ? (
                    <FaSortAmountDown size={20} />
                  ) : (
                    <FaSortAmountUp size={20} />
                  )}
                </button>
              </Tooltip.Trigger>
              <Tooltip.Portal>
                <Tooltip.Content className="bg-gray-700 text-white px-2 py-1 rounded text-sm z-50">
                  {isSortDirectionDisabled
                    ? "Sort direction not available in random mode"
                    : sortDirection === "desc"
                      ? "Sort Descending"
                      : "Sort Ascending"}
                  <Tooltip.Arrow className="fill-gray-700" />
                </Tooltip.Content>
              </Tooltip.Portal>
            </Tooltip.Root>
          </Tooltip.Provider>

          <Tooltip.Provider>
            <Tooltip.Root>
              <Tooltip.Trigger asChild>
                <button
                  onClick={toggleSortType}
                  className="hover:bg-gray-700 p-2 rounded-full"
                >
                  {sortType === "created_at" ? (
                    <FaRegCalendarAlt size={20} />
                  ) : (
                    <FaShuffle size={20} />
                  )}
                </button>
              </Tooltip.Trigger>
              <Tooltip.Portal>
                <Tooltip.Content className="bg-gray-700 text-white px-2 py-1 rounded text-sm z-50">
                  {sortType === "date" ? "Sort by Date" : "Sort Randomly"}
                  <Tooltip.Arrow className="fill-gray-700" />
                </Tooltip.Content>
              </Tooltip.Portal>
            </Tooltip.Root>
          </Tooltip.Provider>
        </div>
      </div>
    </nav>
  );
};

export default Navbar;
