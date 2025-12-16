import { useEffect, useRef } from "react";
import { useLightboxState } from "yet-another-react-lightbox";

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

const VideoSlide = ({ slide }: VideoSlideProps) => {
  const videoRef = useRef<HTMLVideoElement>(null);
  const { slides, currentIndex } = useLightboxState();
  const isCurrentSlide = slides[currentIndex] === slide;

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

  return (
    <div className="flex items-center justify-center h-full w-full">
      <video
        ref={videoRef}
        src={slide.sources[0].src}
        autoPlay
        loop
        controls
        muted
        className="h-full w-full rounded-lg"
        aria-label="Video player"
      />
    </div>
  );
};

export default VideoSlide;
