import { useCallback, useEffect, useState, useMemo, useRef } from "react";
import { BASE_URL, fetchFileContents } from "@/queries/api";
import Navbar from "@/Navbar";
import Lightbox from "yet-another-react-lightbox";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import { useStats, usePaginatedFiles } from "@/queries/loaders";
import { useQuery } from "@tanstack/react-query";
import useNavbarStore from "@/state";
import { useVirtualizer } from "@tanstack/react-virtual";

const PAGE_SIZE = 100; // Increased page size for better performance

const CustomThumbnail = ({ slide }: any) => {
  if (slide.type === "custom") {
    return (
      <div className="thumbnail">
        <img src={slide.src} alt={slide.alt} />
      </div>
    );
  } else {
    <div className="thumbnail">
      <img src={slide.poster} alt={slide.alt} />
    </div>;
  }
};

// Custom slide component for the lightbox
const ImageSlide = ({ slide }: any) => {
  const [objectUrl, setObjectUrl] = useState<string | null>(null);

  const { data: fullSizeFile, status } = useQuery({
    queryKey: ["fullSizeFile", slide.id],
    queryFn: () => fetchFileContents(slide.id),
    enabled: !!slide.id,
    staleTime: Infinity, // Cache the result indefinitely
  });

  useEffect(() => {
    if (fullSizeFile instanceof Blob) {
      const url = URL.createObjectURL(fullSizeFile);
      setObjectUrl(url);
      return () => {
        URL.revokeObjectURL(url);
      };
    }
  }, [fullSizeFile]);

  if (status === "pending") {
    return <div>Loading full-size file...</div>;
  } else if (status === "error") {
    return <div>Error loading full-size file...</div>;
  }

  return (
    <img
      src={objectUrl || slide.src}
      alt={slide.alt}
      style={{
        width: "100%",
        height: "100%",
        objectFit: "contain",
      }}
    />
  );
};

const VideoSlide = ({ slide }: any) => {
  return (
    <video
      src={slide.sources[0].src}
      controls
      autoPlay
      className="h-full w-full rounded-lg"
    />
  );
};

const CustomSlide = ({ slide }: any) => {
  if (slide.type === "video") {
    return <VideoSlide slide={slide} />;
  } else {
    return <ImageSlide slide={slide} />;
  }
};

export default function App() {
  const [columnCount, setColumnCount] = useState(0);

  useEffect(() => {
    function handleResize() {
      if (window.innerWidth < 640) {
        // Mobile
        setColumnCount(2);
      } else if (window.innerWidth >= 640 && window.innerWidth < 768) {
        // Tablet
        setColumnCount(3);
      } else if (window.innerWidth >= 768 && window.innerWidth < 1024) {
        // Laptop
        setColumnCount(3);
      } else {
        // Monitor
        setColumnCount(4);
      }
    }

    window.addEventListener("resize", handleResize);
    handleResize(); // Initial call

    return () => window.removeEventListener("resize", handleResize); // Cleanup
  }, []);
  const { sortDirection, sortType, selectedCategory, seed, setSeed } =
    useNavbarStore();
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
      } else {
        return file.Video!.ThumbnailHeight;
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
            width: file.Video!.Width, // You might want to replace these with actual video dimensions if available
            height: file.Video!.Height,
            poster: file.Video!.ThumbnailBase64,
            sources: [
              {
                src: `${BASE_URL}/video/${file.ID}`,
                type: file.Video!.FullMimeType,
              },
            ],
            id: file.ID,
            hash: file.Hash,
          };
        } else {
          // For images, keep the same behavior
          return {
            type: "custom",
            src: file.Image!.ThumbnailBase64,
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
        plugins={[Thumbnails, Fullscreen, Slideshow]}
        thumbnails={{ showToggle: true, hidden: true }}
        render={{
          slide: CustomSlide,
          thumbnail: CustomThumbnail,
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
                      <img
                        src={file.Video.ThumbnailBase64}
                        alt={file.Filename}
                        className="w-full h-full object-cover rounded-lg"
                      />
                    )}
                  </div>
                </figure>
              </div>
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
    </div>
  );
}
