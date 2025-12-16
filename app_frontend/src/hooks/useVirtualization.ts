import { useVirtualizer } from "@tanstack/react-virtual";
import { useCallback, useEffect, useRef } from "react";
import type { File } from "@/queries/model";

export const useVirtualization = (
  allFiles: Array<File & { pageIndex: number; fileIndex: number }>,
  containerRef: React.RefObject<HTMLDivElement | null>,
  columnCount: number,
  isCurrentlyMobile: boolean,
  debouncedLoadMore: () => void,
  containerSize: { width: number; height: number },
) => {
  const previousFilesLength = useRef(0);

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

  // Initial measurement
  useEffect(() => {
    rowVirtualizer.measure();
  }, [rowVirtualizer]);

  // Remeasure when files change (especially when first loaded)
  useEffect(() => {
    if (previousFilesLength.current === 0 && allFiles.length > 0) {
      // Files loaded for the first time, force remeasurement
      setTimeout(() => {
        rowVirtualizer.measure();
      }, 50);
    }
    previousFilesLength.current = allFiles.length;
  }, [allFiles.length, rowVirtualizer]);

  // Also remeasure when container size changes
  useEffect(() => {
    if (containerSize.width > 0 && containerSize.height > 0) {
      rowVirtualizer.measure();
    }
  }, [containerSize, rowVirtualizer]);

  // Scroll handling
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
  }, [debouncedLoadMore, containerRef, rowVirtualizer]);

  return { rowVirtualizer };
};
