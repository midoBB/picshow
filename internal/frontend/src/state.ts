import { create } from "zustand";

type NavbarState = {
  sortDirection: "asc" | "desc";
  sortType: "created_at" | "random";
  selectedCategory: string;
  isSortDirectionDisabled: boolean;
  seed: number | null;
  dontAskAgainForDelete: boolean;
  setDontAskAgainForDelete: (value: boolean) => void;
  setSortDirection: (direction: "asc" | "desc") => void;
  setSortType: (type: "created_at" | "random") => void;
  setSelectedCategory: (category: string) => void;
  setSeed: (seed: number) => void;
  toggleSortDirection: () => void;
  toggleSortType: () => void;
};

const useNavbarStore = create<NavbarState>((set) => ({
  sortDirection: "desc",
  sortType: "created_at",
  selectedCategory: "all",
  isSortDirectionDisabled: false,
  seed: null,
  dontAskAgainForDelete: false,
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
}));

export default useNavbarStore;
