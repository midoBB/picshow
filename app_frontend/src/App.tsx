import { useEffect, useMemo, useRef, useState } from "react";
import { LuX } from "react-icons/lu";
import { Toaster } from "sonner";
import ConfirmDialog from "@/ConfirmDeleteDialog";
import { GalleryGrid } from "@/components/GalleryGrid";
import { EmptyState } from "@/components/GalleryGrid/EmptyState";
import { FileItemSkeleton } from "@/components/GalleryGrid/FileItemSkeleton";
import { LightboxContainer } from "@/components/Lightbox";
import { ClusterView } from "@/components/ClusterView";
import { useDeleteFile } from "@/queries/loaders";
import { useDeleteFileHandler } from "@/hooks/useDeleteFileHandler";
import { useFileSelection } from "@/hooks/useFileSelection";
import { useGalleryFiltering } from "@/hooks/useGalleryFiltering";
import { useLightboxNavigation } from "@/hooks/useLightboxNavigation";
import { useLightboxSlides } from "@/hooks/useLightboxSlides";
import { useLoadMore } from "@/hooks/useLoadMore";
// Hooks
import { useResponsiveColumns } from "@/hooks/useResponsiveColumns";
import { useVirtualization } from "@/hooks/useVirtualization";
import KeepAwake from "@/KeepAwake";
// Components
import Navbar from "@/Navbar";

// State
import useAppState from "@/state";

export default function App() {
  const navbarRef = useRef<HTMLDivElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const isFirstRun = useRef(true);
  const [viewMode, setViewMode] = useState<"gallery" | "clusters">("gallery");

  // App state
  const {
    dontAskAgainForDelete,
    setDontAskAgainForDelete,
    setIsSelectionMode,
    setSelectedFiles,
    isSelectionMode,
    selectedFiles,
    isDarkMode,
  } = useAppState();

  // Responsive columns hook
  const { isCurrentlyMobile, columnCount, containerSize } =
    useResponsiveColumns(containerRef);

  // Gallery filtering hook
  const {
    sortDirection,
    setSortDirection,
    sortType,
    setSortType,
    selectedCategory,
    setSelectedCategory,
    seed,
    setSeed,
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isLoading: isLoadingFiles,
    isError: isErrorFiles,
    error: errorFiles,
  } = useGalleryFiltering();

  // Initialize seed on first run
  useEffect(() => {
    if (isFirstRun.current && !seed) {
      setSeed(Math.floor(Date.now() / 1000));
      isFirstRun.current = false;
    }
  }, []); // Empty deps - only run once on mount

  // Deduplicate files from paginated data
  const allFiles = useMemo(() => {
    if (!data?.pages) return [];

    const uniqueFiles = [];
    const seenIds = new Set<string>();

    for (let pageIndex = 0; pageIndex < data.pages.length; pageIndex++) {
      const page = data.pages[pageIndex];
      for (let fileIndex = 0; fileIndex < page.files.length; fileIndex++) {
        const file = page.files[fileIndex];
        if (!seenIds.has(file.Id)) {
          seenIds.add(file.Id);
          uniqueFiles.push({ ...file, pageIndex, fileIndex });
        }
      }
    }

    return uniqueFiles;
  }, [data]);

  // Lightbox navigation hook
  const {
    isOpen,
    setIsOpen,
    currentIndex,
    setCurrentIndex,
    isShowingControls,
    setIsShowingControls,
    slideShowRef,
    isSlideshowPlaying,
    openLightbox,
  } = useLightboxNavigation();

  // File selection hook
  const { handleContextMenu, handleClick, selectedFileObjects } =
    useFileSelection(
      isSelectionMode,
      setIsSelectionMode,
      selectedFiles,
      setSelectedFiles,
      allFiles,
      openLightbox,
    );

  // Load more hook
  const { debouncedLoadMore } = useLoadMore(
    hasNextPage,
    isFetchingNextPage,
    fetchNextPage,
  );

  // Virtualization hook
  const { rowVirtualizer } = useVirtualization(
    allFiles,
    containerRef,
    columnCount,
    isCurrentlyMobile,
    debouncedLoadMore,
    containerSize,
  );

  // Lightbox slides hook
  const { slides } = useLightboxSlides(allFiles, currentIndex, isOpen);

  // Delete handler hook
  const { deleteDialogState, handleDelete, confirmDelete, handleOpenChange } =
    useDeleteFileHandler(
      dontAskAgainForDelete,
      selectedFiles,
      setSelectedFiles,
      setIsSelectionMode,
    );

  // Lightbox delete handler
  const deleteFileMutation = useDeleteFile();
  const [lightboxDeleteDialog, setLightboxDeleteDialog] = useState<{
    isOpen: boolean;
    fileId: string | null;
  }>({ isOpen: false, fileId: null });

  const handleLightboxDelete = (slideId: string) => {
    if (dontAskAgainForDelete) {
      confirmLightboxDelete(slideId);
    } else {
      setLightboxDeleteDialog({ isOpen: true, fileId: slideId });
    }
  };

  const confirmLightboxDelete = (slideId: string | null) => {
    const id = slideId || lightboxDeleteDialog.fileId;
    if (!id) return;

    deleteFileMutation.mutate(id, {
      onSuccess: () => {
        setLightboxDeleteDialog({ isOpen: false, fileId: null });
        // Navigate to next or previous slide, or close lightbox
        const nextIndex =
          currentIndex < slides.length - 1 ? currentIndex : currentIndex - 1;
        if (nextIndex >= 0 && nextIndex < slides.length) {
          setCurrentIndex(nextIndex);
        } else {
          setIsOpen(false);
        }
      },
    });
  };

  const handleLightboxDeleteDialogChange = (open: boolean) => {
    if (!open) {
      setLightboxDeleteDialog({ isOpen: false, fileId: null });
    }
  };

  // Handle lightbox view change
  const handleViewChange = ({ index }: { index: number }) => {
    setCurrentIndex(index);
    if (index === slides.length - 1 && hasNextPage && !isFetchingNextPage) {
      fetchNextPage();
    }
  };

  return (
    <div
      className={`flex flex-col h-full ${isDarkMode ? "bg-slate-800" : "bg-white"}`}
    >
      <KeepAwake isActive={isSlideshowPlaying} />

      <div ref={navbarRef}>
        <Navbar
          onDelete={handleDelete}
          setSeed={setSeed}
          setSortType={setSortType}
          setSortDirection={setSortDirection}
          setSelectedCategory={setSelectedCategory}
          sortDirection={sortDirection}
          sortType={sortType}
          selectedCategory={selectedCategory}
          viewMode={viewMode}
          setViewMode={setViewMode}
        />
      </div>

      {viewMode === "gallery" && (
        <LightboxContainer
          open={isOpen}
          onClose={() => {
            setIsOpen(false);
            // Scroll to the current lightbox index when closing
            rowVirtualizer.scrollToIndex(currentIndex, {
              align: "center",
              behavior: "smooth",
            });
          }}
          currentIndex={currentIndex}
          onIndexChange={setCurrentIndex}
          slides={slides}
          isShowingControls={isShowingControls}
          onControlsToggle={() => setIsShowingControls(!isShowingControls)}
          onViewChange={handleViewChange}
          slideShowRef={slideShowRef}
          onCurrentSlideDelete={handleLightboxDelete}
        />
      )}

      {viewMode === "clusters" ? (
        <ClusterView />
      ) : isErrorFiles ? (
        <div
          className={`flex items-center justify-center h-screen ${isDarkMode ? "bg-gray-900 text-white" : "bg-white text-gray-900"}`}
        >
          <div className="text-center p-8">
            <h2 className="text-2xl font-bold mb-4">Error Loading Files</h2>
            <p className="text-gray-500 mb-4">
              {errorFiles instanceof Error
                ? errorFiles.message
                : "Failed to load media files. Please try again."}
            </p>
            <button
              type="button"
              onClick={() => window.location.reload()}
              className={`px-4 py-2 rounded ${isDarkMode ? "bg-blue-600 hover:bg-blue-700" : "bg-blue-500 hover:bg-blue-600"} text-white`}
            >
              Reload Page
            </button>
          </div>
        </div>
      ) : isLoadingFiles ? (
        <div
          ref={containerRef}
          className="w-full p-4 mx-auto flex-grow overflow-auto"
          style={{
            height: `calc(100vh - ${navbarRef.current?.clientHeight}px)`,
          }}
        >
          <FileItemSkeleton isDarkMode={isDarkMode} />
        </div>
      ) : (
        <>
          <div
            ref={containerRef}
            className="w-full p-4 mx-auto flex-grow overflow-auto"
            style={{
              height: `calc(100vh - ${navbarRef.current?.clientHeight}px)`,
            }}
          >
            {allFiles.length === 0 ? (
              <EmptyState
                selectedCategory={selectedCategory}
                isDarkMode={isDarkMode}
              />
            ) : (
              <GalleryGrid
                files={allFiles}
                columnCount={columnCount}
                virtualizer={rowVirtualizer}
                onContextMenu={handleContextMenu}
                onClick={handleClick}
                selectedFiles={selectedFiles}
              />
            )}
            {isFetchingNextPage && (
              <div
                className={`text-center py-4 ${
                  isDarkMode ? "text-white" : "text-gray-900"
                } flex justify-center items-center`}
              >
                <span className="inline-flex">
                  <span className="animate-bounce">.</span>
                  <span className="animate-bounce animation-delay-200">.</span>
                  <span className="animate-bounce animation-delay-400">.</span>
                </span>
              </div>
            )}
            {!hasNextPage && allFiles.length > 0 && (
              <div
                className={`text-center py-4 ${
                  isDarkMode ? "text-gray-400" : "text-gray-500"
                } flex justify-center items-center`}
              >
                <LuX className="w-6 h-6" />
              </div>
            )}
          </div>
        </>
      )}

      <ConfirmDialog
        isOpen={deleteDialogState.isOpen}
        onOpenChange={handleOpenChange}
        onConfirm={confirmDelete}
        dontAskAgain={dontAskAgainForDelete}
        setDontAskAgain={setDontAskAgainForDelete}
        files={selectedFileObjects}
      />
      <ConfirmDialog
        isOpen={lightboxDeleteDialog.isOpen}
        onOpenChange={handleLightboxDeleteDialogChange}
        onConfirm={() => confirmLightboxDelete(null)}
        dontAskAgain={dontAskAgainForDelete}
        setDontAskAgain={setDontAskAgainForDelete}
        files={
          lightboxDeleteDialog.fileId
            ? allFiles
                .filter((f) => f.Id === lightboxDeleteDialog.fileId)
                .map((f) => ({
                  Id: f.Id,
                  MimeType: f.MimeType,
                }))
            : []
        }
      />
      <Toaster />
    </div>
  );
}
