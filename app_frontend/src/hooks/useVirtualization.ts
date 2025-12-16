import { useVirtualizer } from "@tanstack/react-virtual";
import { useCallback, useEffect } from "react";
import type { File } from "@/queries/model";

export const useVirtualization = (
  allFiles: Array<File & { pageIndex: number; fileIndex: number }>,
  containerRef: React.RefObject<HTMLDivElement | null>,
  columnCount: number,
  isCurrentlyMobile: boolean,
  debouncedLoadMore: () => void,
  containerSize: { width: number; height: number },
) => {
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
    getScrollElement: () => containerRef.current,
    estimateSize,
    overscan: isCurrentlyMobile ? 2 : 5,
    lanes: columnCount,
  });

  useEffect(() => {
    rowVirtualizer.measure();
  }, [rowVirtualizer]);

  useEffect(() => {
    const scrollElement = containerRef.current;
    if (!scrollElement) return;

    const handleScroll = () => {
      if (
        scrollElement.scrollTop + scrollElement.clientHeight >=
        scrollElement.scrollHeight - 300
      ) {
        debouncedLoadMore();
      }
    };

    scrollElement.addEventListener("scroll", handleScroll);
    return () => {
      scrollElement.removeEventListener("scroll", handleScroll);
    };
  }, [debouncedLoadMore, containerRef]);

  return { rowVirtualizer };
};
