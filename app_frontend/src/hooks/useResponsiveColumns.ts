import debounce from "lodash/debounce";
import { useCallback, useEffect, useState } from "react";

export const useResponsiveColumns = (
  containerRef: React.RefObject<HTMLDivElement | null>,
) => {
  const isMobile = useCallback(() => {
    return window.innerWidth < 768;
  }, []);

  const [isCurrentlyMobile, setIsCurrentlyMobile] = useState(isMobile());
  const [columnCount, setColumnCount] = useState(0);
  const [containerSize, setContainerSize] = useState({ width: 0, height: 0 });

  useEffect(() => {
    const handleResize = debounce(() => {
      const mobile = isMobile();
      setIsCurrentlyMobile(mobile);
      setColumnCount(mobile ? 1 : 4);
    }, 150);

    window.addEventListener("resize", handleResize);
    handleResize();

    return () => {
      window.removeEventListener("resize", handleResize);
      handleResize.cancel();
    };
  }, [isMobile]);

  // Use ResizeObserver for better container size detection
  useEffect(() => {
    if (!containerRef.current) return;

    const resizeObserver = new ResizeObserver(
      debounce((entries) => {
        for (const entry of entries) {
          const { width, height } = entry.contentRect;
          setContainerSize({ width, height });
        }
      }, 100)
    );

    resizeObserver.observe(containerRef.current);

    // Also set initial size immediately
    const { offsetWidth, offsetHeight } = containerRef.current;
    setContainerSize({ width: offsetWidth, height: offsetHeight });

    return () => {
      resizeObserver.disconnect();
    };
  }, [containerRef]);

  return { isCurrentlyMobile, columnCount, containerSize };
};
