import { useCallback, useEffect, useState, useMemo } from "react";
import { Player, Video, DefaultUi } from "@vime/react";
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

const PAGE_SIZE = 10;

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
    <div className="flex items-center justify-center h-full w-full">
      <div className="w-full h-full max-w-[90vw] max-h-[90vh]">
        <Player
          theme="dark"
          autoplay
          loop
          style={{ width: "100%", height: "100%" }}
        >
          <Video poster={slide.poster}>
            {slide.sources.map((source: any) => (
              <source key={source.src} src={source.src} type={source.type} />
            ))}
          </Video>
          <DefaultUi />
        </Player>
      </div>
    </div>
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
  } = usePaginatedFiles(PAGE_SIZE);

  const handleScroll = useCallback(() => {
    if (
      window.innerHeight + document.documentElement.scrollTop >=
      document.documentElement.offsetHeight - 100
    ) {
      if (hasNextPage && !isFetchingNextPage) {
        fetchNextPage();
      }
    }
  }, [fetchNextPage, hasNextPage, isFetchingNextPage]);

  useEffect(() => {
    window.addEventListener("scroll", handleScroll);
    return () => window.removeEventListener("scroll", handleScroll);
  }, [handleScroll]);

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
      <div className="container p-4 mx-auto">
        <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-8">
          {allFiles.map((file, index) => (
            <div key={`${file.pageIndex}-${file.fileIndex}`} className="mb-8">
              <div
                className="cursor-pointer group"
                onClick={() => openLightbox(index)}
              >
                <figure className="relative h-64 w-full overflow-hidden rounded-lg transform group-hover:shadow transition duration-300 ease-out">
                  <div className="absolute w-full h-full object-cover rounded-lg transform group-hover:scale-105 transition duration-300 ease-out">
                    {file.Image && (
                      <img
                        src={file.Image.ThumbnailBase64}
                        alt={file.Filename}
                        className="w-full h-full object-contain aspect-auto rounded-lg"
                      />
                    )}
                    {file.Video && (
                      <img
                        src={file.Video.ThumbnailBase64}
                        alt={file.Filename}
                        className="w-full h-full object-contain aspect-auto rounded-lg"
                      />
                    )}
                  </div>
                </figure>
              </div>
            </div>
          ))}
        </div>
      </div>
      {isFetchingNextPage && (
        <div className="text-center py-4">Loading more...</div>
      )}
      {!hasNextPage && <div className="text-center py-4">No more files</div>}
    </div>
  );
}
