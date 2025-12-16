import { useCallback, useMemo } from "react";
import type { File } from "@/queries/model";

export const useFileSelection = (
  isSelectionMode: boolean,
  setIsSelectionMode: (mode: boolean) => void,
  selectedFiles: string[],
  setSelectedFiles: (fn: (prev: string[]) => string[]) => void,
  allFiles: Array<File & { pageIndex: number; fileIndex: number }>,
  openLightbox: (index: number) => void,
) => {
  const toggleFileSelection = useCallback(
    (id: string) => {
      setSelectedFiles((prev) => {
        if (prev.includes(id)) {
          const newSelection = prev.filter((fileId) => fileId !== id);
          if (newSelection.length === 0) {
            setIsSelectionMode(false);
          }
          return newSelection;
        } else {
          setIsSelectionMode(true);
          return [...prev, id];
        }
      });
    },
    [setIsSelectionMode, setSelectedFiles],
  );

  const handleContextMenu = useCallback(
    (event: React.MouseEvent, id: string) => {
      event.preventDefault();
      toggleFileSelection(id);
    },
    [toggleFileSelection],
  );

  const handleClick = useCallback(
    (index: number, ID: string) => {
      if (!isSelectionMode) {
        openLightbox(index);
      } else {
        toggleFileSelection(ID);
      }
    },
    [isSelectionMode, openLightbox, toggleFileSelection],
  );

  const selectedFileObjects = useMemo(() => {
    if (isSelectionMode) {
      return allFiles.filter((file) => selectedFiles.includes(file.Id));
    } else {
      return [];
    }
  }, [allFiles, isSelectionMode, selectedFiles]);

  return {
    toggleFileSelection,
    handleContextMenu,
    handleClick,
    selectedFileObjects,
  };
};
