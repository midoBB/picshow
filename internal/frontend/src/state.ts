import { create } from "zustand";

type AppState = {
  selectedFiles: number[];
  isSelectionMode: boolean;
  sortDirection: "asc" | "desc";
  sortType: "created_at" | "random";
  selectedCategory: string;
  selectedCount: () => number;
  isSortDirectionDisabled: boolean;
  seed: number;
  dontAskAgainForDelete: boolean;
  isDarkMode: boolean;
  setDontAskAgainForDelete: (value: boolean) => void;
  setIsSelectionMode: (isSelectionMode: boolean) => void;
  setSelectedFiles: (fn: (prev: number[]) => number[]) => void;
  setSortDirection: (direction: "asc" | "desc") => void;
  setSortType: (type: "created_at" | "random") => void;
  setSelectedCategory: (category: string) => void;
  setSeed: (seed: number) => void;
  toggleSortDirection: () => void;
  toggleSortType: () => void;
  toggleDarkMode: () => void;
};

const useAppState = create<AppState>((set, get) => ({
  selectedFiles: [],
  selectedCount: () => get().selectedFiles.length,
  isSelectionMode: false,
  sortDirection: "desc",
  sortType: "random",
  selectedCategory: "all",
  isSortDirectionDisabled: true,
  seed: Math.floor(Date.now() / 1000),
  dontAskAgainForDelete: false,
  isDarkMode: true,
  setIsSelectionMode: (isSelectionMode) => set({ isSelectionMode }),
  setSelectedFiles: (fn: (prev: number[]) => number[]) => {
    set((state) => ({ selectedFiles: fn(state.selectedFiles) }));
  },
  setDontAskAgainForDelete: (value) => set({ dontAskAgainForDelete: value }),
  setSortDirection: (direction) => set({ sortDirection: direction }),
  setSortType: (type) =>
    set((state) => ({
      sortType: type,
      isSortDirectionDisabled: type === "random",
      sortDirection: type === "random" ? "desc" : state.sortDirection,
    })),
  setSelectedCategory: (category) => set({ selectedCategory: category }),
  setSeed: (seed) => set({ seed }),
  toggleSortDirection: () =>
    set((state) => ({
      sortDirection: state.sortDirection === "desc" ? "asc" : "desc",
    })),
  toggleSortType: () =>
    set((state) => {
      const newType = state.sortType === "created_at" ? "random" : "created_at";
      return {
        sortType: newType,
        isSortDirectionDisabled: newType === "random",
        sortDirection: newType === "random" ? "desc" : state.sortDirection,
      };
    }),
  toggleDarkMode: () => set((state) => ({ isDarkMode: !state.isDarkMode })),
}));

export default useAppState;
