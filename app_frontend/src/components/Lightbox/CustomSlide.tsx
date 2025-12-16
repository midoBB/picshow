import VideoSlide from "@/VideoSlide";
import type { CustomSlideProps } from "@/types/gallery";

export const CustomSlide = ({ slide }: CustomSlideProps) => {
  if (slide.type === "video") {
    return <VideoSlide slide={slide} />;
  }
};
