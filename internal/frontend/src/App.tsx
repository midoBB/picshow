import { useCallback, useEffect, useState, useMemo, useRef } from "react";
import { FaRegPlayCircle } from "react-icons/fa";
import { LuLoader2, LuX } from "react-icons/lu";
import { BASE_URL } from "@/queries/api";
import Navbar from "@/Navbar";
import Lightbox, { SlideshowRef } from "yet-another-react-lightbox";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import { usePaginatedFiles, useDeleteFile } from "@/queries/loaders";
import useAppState from "@/state";
import { useVirtualizer } from "@tanstack/react-virtual";
import VideoSlide from "@/VideoSlide";
import ConfirmDialog from "@/ConfirmDeleteDialog";
import KeepAwake from "@/KeepAwake";
const PAGE_SIZE = 15;

const CustomSlide = ({ slide }: any) => {
  if (slide.type === "video") {
    return <VideoSlide slide={slide} />;
  }
};

export default function App() {
  const [columnCount, setColumnCount] = useState(0);

  const slideShowRef = useRef<SlideshowRef>(null);
  const [isSlideshowPlaying, setIsSlideshowPlaying] = useState(false);
  useEffect(() => {
    function handleResize() {
      if (window.innerWidth < 640) {
        setColumnCount(2);
      } else if (window.innerWidth >= 640 && window.innerWidth < 768) {
        setColumnCount(3);
      } else {
        setColumnCount(4);
      }
    }

    window.addEventListener("resize", handleResize);
    handleResize();

    return () => window.removeEventListener("resize", handleResize);
  }, []);

  const {
    sortDirection,
    sortType,
    selectedCategory,
    seed,
    setSeed,
    dontAskAgainForDelete,
    setDontAskAgainForDelete,
    setIsSelectionMode,
    setSelectedFiles,
    isSelectionMode,
    selectedFiles,
    isDarkMode,
  } = useAppState();

  useEffect(() => {
    if (!seed) {
      setSeed(Math.floor(Date.now() / 1000));
    }
  }, [seed, setSeed]);

  const [isOpen, setIsOpen] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isShowingControls, setIsShowingControls] = useState(true);

  const openLightbox = (index: number) => {
    setCurrentIndex(index);
    setIsOpen(true);
  };

  const deleteFileMutation = useDeleteFile();

  const [deleteDialogState, setDeleteDialogState] = useState<{
    isOpen: boolean;
    itemIds: number[];
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

  const {
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isLoading: isLoadingFiles,
  } = usePaginatedFiles({
    pageSize: PAGE_SIZE,
    order: sortType,
    direction: sortDirection,
    type: selectedCategory === "all" ? undefined : selectedCategory,
    seed: sortType === "random" ? seed : null,
  });

  const allFiles = useMemo(
    () =>
      data?.pages.flatMap((page, pageIndex) =>
        page.files.map((file, fileIndex) => ({
          ...file,
          pageIndex,
          fileIndex,
        })),
      ) || [],
    [data],
  );

  const parentRef = useRef<HTMLDivElement>(null);

  const estimateSize = useCallback(
    (index: number) => {
      const file = allFiles[index];
      if (file.Image) {
        return file.Image.ThumbnailHeight;
      } else if (file.Video) {
        return file.Video.ThumbnailHeight;
      } else {
        return 300;
      }
    },
    [allFiles],
  );

  const rowVirtualizer = useVirtualizer({
    count: allFiles.length,
    getScrollElement: () => parentRef.current,
    estimateSize,
    overscan: 5,
    lanes: columnCount,
  });

  const loadMoreItems = useCallback(() => {
    if (hasNextPage && !isFetchingNextPage) {
      fetchNextPage();
    }
  }, [fetchNextPage, hasNextPage, isFetchingNextPage]);

  useEffect(() => {
    const scrollElement = parentRef.current;
    if (!scrollElement) return;

    const handleScroll = () => {
      if (
        scrollElement.scrollTop + scrollElement.clientHeight >=
        scrollElement.scrollHeight - 300
      ) {
        loadMoreItems();
      }
    };

    scrollElement.addEventListener("scroll", handleScroll);
    return () => scrollElement.removeEventListener("scroll", handleScroll);
  }, [loadMoreItems]);

  const slides = useMemo(
    () =>
      allFiles.map((file) => {
        if (file.MimeType === "video") {
          return {
            type: "video",
            width: file.Video?.Width,
            height: file.Video?.Height,
            poster: file.Video?.ThumbnailBase64,
            sources: [
              {
                src: `${BASE_URL}/video/${file.ID}`,
                type: file.Video?.FullMimeType,
              },
            ],
            id: file.ID,
            hash: file.Hash,
          };
        } else {
          return {
            type: "image",
            src: `${BASE_URL}/image/${file.ID}`,
            width: file.Image?.Width,
            height: file.Image?.Height,
            srcSet: [
              {
                src: file.Image?.ThumbnailBase64,
                width: file.Image?.ThumbnailWidth,
                height: file.Image?.ThumbnailHeight,
              },
              {
                src: `${BASE_URL}/image/${file.ID}`,
                width: file.Image?.Width,
                height: file.Image?.Height,
              },
            ],
            alt: file.Filename,
            id: file.ID,
            hash: file.Hash,
          };
        }
      }),
    [allFiles],
  );

  const handleContextMenu = (event: MouseEvent, id: number) => {
    event.preventDefault();
    toggleFileSelection(id);
  };

  function handleClick(index: number, ID: number): void {
    if (!isSelectionMode) {
      openLightbox(index);
    } else {
      toggleFileSelection(ID);
    }
  }
  const toggleFileSelection = (id: number) => {
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
  };

  const selectedFileObjects = useMemo(() => {
    if (isSelectionMode) {
      return allFiles.filter((file) => selectedFiles.includes(file.ID));
    } else {
      return [];
    }
  }, [allFiles, isSelectionMode, selectedFiles]);
  useEffect(() => {
    setIsSlideshowPlaying(!!slideShowRef.current?.playing);
  }, [slideShowRef.current?.playing]);

  return (
    <div
      className={`flex flex-col h-full ${isDarkMode ? "bg-slate-800" : "bg-white"}`}
    >
      <KeepAwake isActive={isSlideshowPlaying} />
      <Navbar onDelete={handleDelete} />
      <Lightbox
        open={isOpen}
        close={() => setIsOpen(false)}
        index={currentIndex}
        slides={slides}
        fullscreen={{ auto: true }}
        slideshow={{ autoplay: false, delay: 5000, ref: slideShowRef }}
        plugins={[Thumbnails, Fullscreen, Slideshow]}
        thumbnails={{ showToggle: true, hidden: true }}
        render={{
          slide: CustomSlide,
          buttonPrev:
            isShowingControls && currentIndex > 0 ? undefined : () => null,
          buttonNext:
            isShowingControls && currentIndex < slides.length - 1
              ? undefined
              : () => null,
        }}
        on={{
          click: () => {
            setIsShowingControls(!isShowingControls);
          },
          view: ({ index }) => {
            setCurrentIndex(index);
            if (
              index === slides.length - 1 &&
              hasNextPage &&
              !isFetchingNextPage
            ) {
              fetchNextPage();
            }
          },
        }}
      />
      {isLoadingFiles ? (
        <div className="absolute inset-0 flex items-center justify-center bg-black bg-opacity-50 z-50">
          <LuLoader2 className="w-8 h-8 animate-spin text-blue-500" />
        </div>
      ) : (
        <>
          <div
            ref={parentRef}
            className="w-full p-4 mx-auto flex-grow overflow-auto"
            style={{ height: "100vh " }}
          >
            <div
              style={{
                height: `${rowVirtualizer.getTotalSize()}px`,
                width: "100%",
                position: "relative",
              }}
            >
              {rowVirtualizer.getVirtualItems().map((virtualRow) => {
                const file = allFiles[virtualRow.index];

                return (
                  <div
                    key={virtualRow.index}
                    className={`cursor-pointer group ${selectedFiles.includes(file.ID) ? "border-2 border-blue-500 rounded-lg" : ""}`}
                    onContextMenu={(e) => handleContextMenu(e, file.ID)}
                    onClick={() => handleClick(virtualRow.index, file.ID)}
                    style={{
                      position: "absolute",
                      top: 0,
                      left: `${(virtualRow.lane / columnCount) * 100}%`,
                      width: `${100 / columnCount}%`,
                      height: `${virtualRow.size}px`,
                      transform: `translateY(${virtualRow.start}px)`,
                      padding: "8px",
                    }}
                  >
                    <figure className="relative w-full h-full overflow-hidden rounded-lg transform group-hover:shadow transition duration-300 ease-out">
                      <div className="absolute w-full h-full object-cover rounded-lg transform group-hover:scale-105 transition duration-300 ease-out">
                        {file.Image && (
                          <img
                            src={file.Image.ThumbnailBase64}
                            alt={file.Filename}
                            className="w-full h-full object-cover rounded-lg"
                          />
                        )}
                        {file.Video && (
                          <div className="relative w-full h-full">
                            <img
                              src={file.Video.ThumbnailBase64}
                              alt={file.Filename}
                              className="w-full h-full object-cover rounded-lg"
                            />
                            <div className="absolute inset-0 flex items-center justify-center">
                              <FaRegPlayCircle className="text-white h-16 w-16 text-4xl opacity-70" />
                            </div>
                          </div>
                        )}
                      </div>
                    </figure>
                    {selectedFiles.includes(file.ID) && (
                      <div className="absolute top-2 left-2 w-6 h-6 bg-blue-500 rounded-full flex items-center justify-center">
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          className="h-4 w-4 text-white"
                          viewBox="0 0 20 20"
                          fill="currentColor"
                        >
                          <path
                            fillRule="evenodd"
                            d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                            clipRule="evenodd"
                          />
                        </svg>
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
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
    </div>
  );
}
