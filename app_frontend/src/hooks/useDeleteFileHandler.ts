import { useCallback, useState } from "react";
import { useDeleteFile } from "@/queries/loaders";

export const useDeleteFileHandler = (
  dontAskAgainForDelete: boolean,
  selectedFiles: string[],
  setSelectedFiles: (fn: (prev: string[]) => string[]) => void,
  setIsSelectionMode: (mode: boolean) => void,
) => {
  const deleteFileMutation = useDeleteFile();

  const [deleteDialogState, setDeleteDialogState] = useState<{
    isOpen: boolean;
    itemIds: string[];
  }>({
    isOpen: false,
    itemIds: [],
  });

  const handleDelete = useCallback(() => {
    if (dontAskAgainForDelete) {
      deleteFileMutation.mutate(selectedFiles.join(","));
      setSelectedFiles(() => []);
      setIsSelectionMode(false);
    } else {
      setDeleteDialogState({ isOpen: true, itemIds: selectedFiles });
    }
  }, [
    deleteFileMutation,
    dontAskAgainForDelete,
    selectedFiles,
    setIsSelectionMode,
    setSelectedFiles,
  ]);

  const confirmDelete = useCallback(() => {
    deleteFileMutation.mutate(deleteDialogState.itemIds.join(","));
    setDeleteDialogState({ isOpen: false, itemIds: [] });
    setSelectedFiles(() => []);
    setIsSelectionMode(false);
  }, [
    deleteDialogState.itemIds,
    deleteFileMutation,
    setIsSelectionMode,
    setSelectedFiles,
  ]);

  const handleOpenChange = useCallback(
    (open: boolean) => {
      if (!open) {
        setDeleteDialogState((prev) => ({ ...prev, isOpen: false }));
        setSelectedFiles(() => []);
        setIsSelectionMode(false);
      }
    },
    [setIsSelectionMode, setSelectedFiles],
  );

  return {
    deleteDialogState,
    handleDelete,
    confirmDelete,
    handleOpenChange,
  };
};
