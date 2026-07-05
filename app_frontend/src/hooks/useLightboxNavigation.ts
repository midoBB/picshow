import { useCallback, useEffect, useRef, useState } from "react";
import type { SlideshowRef } from "yet-another-react-lightbox";

const DECLUTTER_AFTER_SLIDE_CHANGES = 3;

export const useLightboxNavigation = () => {
  const [isOpen, setIsOpen] = useState(false);
  const [currentIndex, setCurrentIndex] = useState(0);
  const [isShowingControls, setIsShowingControls] = useState(true);
  const [isDecluttered, setIsDecluttered] = useState(false);
  const slideShowRef = useRef<SlideshowRef>(null);
  const [isSlideshowPlaying, setIsSlideshowPlaying] = useState(false);
  const slideChangesSinceControlsShown = useRef(0);
  const lastViewedIndex = useRef(0);

  const resetDeclutterCounter = useCallback(() => {
    slideChangesSinceControlsShown.current = 0;
    lastViewedIndex.current = currentIndex;
  }, [currentIndex]);

  const restoreControls = useCallback(() => {
    setIsDecluttered(false);
    setIsShowingControls(true);
    resetDeclutterCounter();
  }, [resetDeclutterCounter]);

  const toggleDeclutter = useCallback(() => {
    if (isDecluttered) {
      restoreControls();
      return;
    }

    setIsDecluttered(true);
    setIsShowingControls(false);
  }, [isDecluttered, restoreControls]);

  const toggleViewerControls = useCallback(() => {
    if (isDecluttered) {
      restoreControls();
      return;
    }

    setIsShowingControls((showingControls) => {
      const nextShowingControls = !showingControls;
      if (nextShowingControls) {
        resetDeclutterCounter();
      }
      return nextShowingControls;
    });
  }, [isDecluttered, resetDeclutterCounter, restoreControls]);

  const openLightbox = useCallback(
    (index: number) => {
      slideChangesSinceControlsShown.current = 0;
      lastViewedIndex.current = index;
      setCurrentIndex(index);
      setIsOpen(true);
      setIsDecluttered(false);
      setIsShowingControls(true);
    },
    [setCurrentIndex, setIsOpen],
  );

  useEffect(() => {
    if (!isOpen || currentIndex === lastViewedIndex.current) {
      return;
    }

    lastViewedIndex.current = currentIndex;
    slideChangesSinceControlsShown.current += 1;

    if (
      slideChangesSinceControlsShown.current >=
      DECLUTTER_AFTER_SLIDE_CHANGES
    ) {
      setIsDecluttered(true);
      setIsShowingControls(false);
    }
  }, [currentIndex, isOpen]);

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
    isDecluttered,
    toggleDeclutter,
    toggleViewerControls,
    slideShowRef,
    isSlideshowPlaying,
    openLightbox,
  };
};
