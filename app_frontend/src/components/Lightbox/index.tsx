import React, { lazy, Suspense } from "react";
import type { SlideshowRef } from "yet-another-react-lightbox";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import type { SlideType } from "@/types/gallery";
import { CustomSlide } from "./CustomSlide";
import { FavoriteButton } from "./FavoriteButton";

const Lightbox = lazy(() => import("yet-another-react-lightbox"));

interface LightboxContainerProps {
  open: boolean;
  onClose: () => void;
  currentIndex: number;
  onIndexChange: (index: number) => void;
  slides: SlideType[];
  isShowingControls: boolean;
  onControlsToggle: () => void;
  onViewChange: ({ index }: { index: number }) => void;
  slideShowRef: React.MutableRefObject<SlideshowRef | null>;
}

export const LightboxContainer = ({
  open,
  onClose,
  currentIndex,
  onIndexChange,
  slides,
  isShowingControls,
  onControlsToggle,
  onViewChange,
  slideShowRef,
}: LightboxContainerProps) => {
  return (
    <Suspense fallback={null}>
      <Lightbox
        open={open}
        close={onClose}
        carousel={{ finite: true }}
        index={currentIndex}
        slides={slides}
        fullscreen={{ auto: true }}
        slideshow={{ autoplay: false, delay: 5000, ref: slideShowRef }}
        plugins={[Thumbnails, Fullscreen, Slideshow]}
        thumbnails={{ showToggle: true, hidden: true }}
        toolbar={{
          buttons: [<FavoriteButton key="my-button" />, "close"],
        }}
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
          click: onControlsToggle,
          view: onViewChange,
        }}
      />
    </Suspense>
  );
};
