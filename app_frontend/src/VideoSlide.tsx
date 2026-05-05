import { useEffect, useRef, useCallback } from "react";
import { useLightboxState, useEvents } from "yet-another-react-lightbox";
import { ACTION_PREV, ACTION_NEXT } from "yet-another-react-lightbox";

interface VideoSlideProps {
  slide: {
    type: "video";
    sources: Array<{ src: string; type: string }>;
    poster?: string;
    width?: number;
    height?: number;
    id: string;
    hash: string;
  };
}

const SWIPE_THRESHOLD = 50;

const VideoSlide = ({ slide }: VideoSlideProps) => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const { slides, currentIndex } = useLightboxState();
  const { publish } = useEvents();
  const isCurrentSlide = slides[currentIndex] === slide;

  const touchData = useRef<{
    startX: number;
    startY: number;
    startTime: number;
    isSwiping: boolean;
  } | null>(null);

  useEffect(() => {
    const video = videoRef.current;

    if (isCurrentSlide && video) {
      video.play();
    } else if (video) {
      video.pause();
      video.currentTime = 0;
    }

    return () => {
      if (video) {
        video.pause();
        video.currentTime = 0;
      }
    };
  }, [isCurrentSlide]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const handleTouchStart = (e: TouchEvent) => {
      const t = e.touches[0];
      touchData.current = {
        startX: t.clientX,
        startY: t.clientY,
        startTime: Date.now(),
        isSwiping: false,
      };
    };

    const handleTouchMove = (e: TouchEvent) => {
      if (!touchData.current) return;
      const t = e.touches[0];
      const dx = t.clientX - touchData.current.startX;
      const dy = t.clientY - touchData.current.startY;

      if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 10) {
        touchData.current.isSwiping = true;
        e.preventDefault();
      }
    };

    const handleTouchEnd = (e: TouchEvent) => {
      if (!touchData.current) return;
      const t = e.changedTouches[0];
      const dx = t.clientX - touchData.current.startX;

      if (touchData.current.isSwiping && Math.abs(dx) > SWIPE_THRESHOLD) {
        if (dx > 0) {
          publish(ACTION_PREV);
        } else {
          publish(ACTION_NEXT);
        }
      }

      touchData.current = null;
    };

    container.addEventListener("touchstart", handleTouchStart, {
      passive: true,
    });
    container.addEventListener("touchmove", handleTouchMove, {
      passive: false,
    });
    container.addEventListener("touchend", handleTouchEnd, { passive: true });

    return () => {
      container.removeEventListener("touchstart", handleTouchStart);
      container.removeEventListener("touchmove", handleTouchMove);
      container.removeEventListener("touchend", handleTouchEnd);
    };
  }, [publish]);

  const handleNavigate = useCallback(
    (direction: "prev" | "next") => (e: React.MouseEvent) => {
      e.stopPropagation();
      publish(direction === "prev" ? ACTION_PREV : ACTION_NEXT);
    },
    [publish],
  );

  return (
    <div
      ref={containerRef}
      className="flex items-center justify-center h-full w-full relative"
    >
      <video
        ref={videoRef}
        src={slide.sources[0].src}
        poster={slide.poster}
        autoPlay
        loop
        controls
        muted
        playsInline
        className="h-full w-full rounded-lg"
        style={{ touchAction: "pan-y pinch-zoom" }}
        aria-label="Video player"
      />
      {/* Edge tap zones for mobile navigation when arrows are hidden */}
      <div
        className="absolute top-0 left-0 bottom-0 w-[10%] z-10"
        onClick={handleNavigate("prev")}
        aria-hidden="true"
      />
      <div
        className="absolute top-0 right-0 bottom-0 w-[10%] z-10"
        onClick={handleNavigate("next")}
        aria-hidden="true"
      />
    </div>
  );
};

export default VideoSlide;
