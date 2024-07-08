import { useCallback, useEffect, useState, useMemo, useRef } from "react";
import { FaRegPlayCircle } from "react-icons/fa";
import { BASE_URL } from "@/queries/api";
import Navbar from "@/Navbar";
import Lightbox from "yet-another-react-lightbox";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Zoom from "yet-another-react-lightbox/plugins/zoom";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import { useStats, usePaginatedFiles, useDeleteFile } from "@/queries/loaders";
import useNavbarStore from "@/state";
import { useVirtualizer } from "@tanstack/react-virtual";
import VideoSlide from "@/VideoSlide";
import ConfirmDialog from "@/ConfirmDeleteDialog";
import * as ContextMenu from "@radix-ui/react-context-menu";
const PAGE_SIZE = 40;

const CustomSlide = ({ slide }: any) => {
  if (slide.type === "video") {
    return <VideoSlide slide={slide} />;
  }
};

export default function App() {
  const [columnCount, setColumnCount] = useState(0);
  useEffect(() => {
    function handleResize() {
      if (window.innerWidth < 640) {
        setColumnCount(1);
      } else if (window.innerWidth >= 640 && window.innerWidth < 768) {
        setColumnCount(2);
      } else {
        setColumnCount(3);
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
  } = useNavbarStore();
  useEffect(() => {
    if (!seed) {
      setSeed(Math.floor(Date.now() / 1000));
    }
  }, [seed, setSeed]);
  const [isOpen, setIsOpen] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const openLightbox = (index: number) => {
    setCurrentIndex(index);
    setIsOpen(true);
  };
  const deleteFileMutation = useDeleteFile();
  const [deleteDialogState, setDeleteDialogState] = useState<{
    isOpen: boolean;
    itemId: number | null;
  }>({
    isOpen: false,
    itemId: null,
  });

  const handleDelete = useCallback(
    (id: number) => {
      if (dontAskAgainForDelete) {
        deleteFileMutation.mutate(id);
      } else {
        setDeleteDialogState({ isOpen: true, itemId: id });
      }
    },
    [deleteFileMutation, dontAskAgainForDelete],
  );

  const confirmDelete = useCallback(() => {
    if (deleteDialogState.itemId) {
      deleteFileMutation.mutate(deleteDialogState.itemId);
    }
    setDeleteDialogState({ isOpen: false, itemId: null });
  }, [deleteDialogState.itemId, deleteFileMutation]);

  const handleOpenChange = useCallback((open: boolean) => {
    if (!open) {
      setDeleteDialogState((prev) => ({ ...prev, isOpen: false }));
    }
  }, []);
  const { isLoading: isLoadingStats } = useStats();
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
    seed,
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
            alt: file.Filename,
            id: file.ID,
            hash: file.Hash,
          };
        }
      }),
    [allFiles],
  );

  if (isLoadingStats || isLoadingFiles) {
    return <div className="container mx-auto p-4">Loading...</div>;
  }

  return (
    <div className="flex flex-col h-full">
      <Navbar />
      <Lightbox
        open={isOpen}
        close={() => setIsOpen(false)}
        index={currentIndex}
        slides={slides}
        fullscreen={{ auto: true }}
        slideshow={{ autoplay: false, delay: 5000 }}
        plugins={[Thumbnails, Fullscreen, Slideshow, Zoom]}
        thumbnails={{ showToggle: true, hidden: true }}
        render={{
          slide: CustomSlide,
          buttonPrev: currentIndex > 0 ? undefined : () => null,
          buttonNext: currentIndex < slides.length - 1 ? undefined : () => null,
        }}
        on={{
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
      <div
        ref={parentRef}
        className="container p-4 mx-auto flex-grow overflow-auto"
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
              <ContextMenu.Root key={virtualRow.index}>
                <ContextMenu.Trigger>
                  <div
                    key={virtualRow.index}
                    className="cursor-pointer group"
                    onClick={() => openLightbox(virtualRow.index)}
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
                  </div>
                </ContextMenu.Trigger>
                <ContextMenu.Content className="min-w-[220px] bg-white rounded-md overflow-hidden p-[5px] shadow-[0px_10px_38px_-10px_rgba(22,_23,_24,_0.35),_0px_10px_20px_-15px_rgba(22,_23,_24,_0.2)]">
                  <ContextMenu.Item
                    className="text-[13px] leading-none text-violet11 rounded-[3px] flex items-center h-[25px] px-[5px] relative pl-[25px] select-none outline-none data-[disabled]:text-mauve8 data-[disabled]:pointer-events-none data-[highlighted]:bg-violet9 data-[highlighted]:text-violet1 cursor-pointer"
                    onSelect={() => handleDelete(file.ID)}
                  >
                    Delete
                  </ContextMenu.Item>
                </ContextMenu.Content>
              </ContextMenu.Root>
            );
          })}
        </div>
        {isFetchingNextPage && (
          <div className="text-center py-4">Loading more...</div>
        )}
        {!hasNextPage && allFiles.length > 0 && (
          <div className="text-center py-4">No more files</div>
        )}
      </div>
      <ConfirmDialog
        isOpen={deleteDialogState.isOpen}
        onOpenChange={handleOpenChange}
        onConfirm={confirmDelete}
        dontAskAgain={dontAskAgainForDelete}
        setDontAskAgain={setDontAskAgainForDelete}
      />
    </div>
  );
}
