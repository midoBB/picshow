import { create } from "zustand";

type AppState = {
  selectedFiles: string[];
  isSelectionMode: boolean;
  selectedCount: () => number;
  dontAskAgainForDelete: boolean;
  isDarkMode: boolean;
  setDontAskAgainForDelete: (value: boolean) => void;
  setIsSelectionMode: (isSelectionMode: boolean) => void;
  setSelectedFiles: (fn: (prev: string[]) => string[]) => void;
  toggleDarkMode: () => void;
};

const useAppState = create<AppState>((set, get) => ({
  selectedFiles: [],
  selectedCount: () => get().selectedFiles.length,
  isSelectionMode: false,
  dontAskAgainForDelete: false,
  isDarkMode: true,
  setIsSelectionMode: (isSelectionMode) => set({ isSelectionMode }),
  setSelectedFiles: (fn: (prev: string[]) => string[]) => {
    set((state) => ({ selectedFiles: fn(state.selectedFiles) }));
  },
  setDontAskAgainForDelete: (value) => set({ dontAskAgainForDelete: value }),
  toggleDarkMode: () => set((state) => ({ isDarkMode: !state.isDarkMode })),
}));

export default useAppState;
