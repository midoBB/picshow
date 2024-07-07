import { create } from "zustand";

type NavbarState = {
  sortDirection: "asc" | "desc";
  sortType: "date" | "random";
  selectedCategory: string;
  isSortDirectionDisabled: boolean;
  setSortDirection: (direction: "asc" | "desc") => void;
  setSortType: (type: "date" | "random") => void;
  setSelectedCategory: (category: string) => void;
  toggleSortDirection: () => void;
  toggleSortType: () => void;
};

const useNavbarStore = create<NavbarState>((set) => ({
  sortDirection: "desc",
  sortType: "date",
  selectedCategory: "all",
  isSortDirectionDisabled: false,
  setSortDirection: (direction) => set({ sortDirection: direction }),
  setSortType: (type) =>
    set((state) => ({
      sortType: type,
      isSortDirectionDisabled: type === "random",
      // Reset sort direction to 'desc' when switching to 'random'
      sortDirection: type === "random" ? "desc" : state.sortDirection,
    })),
  setSelectedCategory: (category) => set({ selectedCategory: category }),
  toggleSortDirection: () =>
    set((state) => ({
      sortDirection: state.sortDirection === "desc" ? "asc" : "desc",
    })),
  toggleSortType: () =>
    set((state) => {
      const newType = state.sortType === "date" ? "random" : "date";
      return {
        sortType: newType,
        isSortDirectionDisabled: newType === "random",
        // Reset sort direction to 'desc' when switching to 'random'
        sortDirection: newType === "random" ? "desc" : state.sortDirection,
      };
    }),
}));
export default useNavbarStore;
