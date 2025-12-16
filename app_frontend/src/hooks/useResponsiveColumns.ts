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
      setIsCurrentlyMobile(isMobile());
      if (isMobile()) {
        setColumnCount(1);
      } else {
        setColumnCount(4);
      }
      if (containerRef.current) {
        setContainerSize({
          width: containerRef.current.offsetWidth,
          height: containerRef.current.offsetHeight,
        });
      }
    }, 150);

    window.addEventListener("resize", handleResize);
    handleResize();

    return () => {
      window.removeEventListener("resize", handleResize);
      handleResize.cancel();
    };
  }, [isMobile, containerRef]);

  useEffect(() => {
    const timer = setTimeout(() => {
      if (containerRef.current) {
        setContainerSize({
          width: containerRef.current.offsetWidth,
          height: containerRef.current.offsetHeight,
        });
      }
    }, 100);

    return () => clearTimeout(timer);
  }, [containerRef]);

  return { isCurrentlyMobile, columnCount, containerSize };
};
