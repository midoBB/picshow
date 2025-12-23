import { useCallback, useEffect, useRef, useState } from "react";
import type { SlideshowRef } from "yet-another-react-lightbox";

export const useLightboxNavigation = () => {
  const [isOpen, setIsOpen] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isShowingControls, setIsShowingControls] = useState(true);
  const slideShowRef = useRef<SlideshowRef>(null);
  const [isSlideshowPlaying, setIsSlideshowPlaying] = useState(false);

  const openLightbox = useCallback(
    (index: number) => {
      setCurrentIndex(index);
      setIsOpen(true);
    },
    [setCurrentIndex, setIsOpen],
  );

  useEffect(() => {
    setIsSlideshowPlaying(!!slideShowRef.current?.playing);
  }, [slideShowRef.current?.playing]);

  return {
    isOpen,
    setIsOpen,
    currentIndex,
    setCurrentIndex,
    isShowingControls,
    setIsShowingControls,
    slideShowRef,
    isSlideshowPlaying,
    openLightbox,
  };
};

