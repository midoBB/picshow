import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useLightboxState } from "yet-another-react-lightbox";
import { fetchFileContents } from "@/queries/api";

const ImageSlide = ({ slide }: any) => {
  const [objectUrl, setObjectUrl] = useState<string | null>(null);
  const { slides, currentIndex } = useLightboxState();
  const isCurrentSlide = slides[currentIndex] === slide;
  const { data: fullSizeFile, status } = useQuery({
    queryKey: ["fullSizeFile", slide.id],
    queryFn: () => fetchFileContents(slide.id),
    enabled: !!slide.id && isCurrentSlide,
  });

  useEffect(() => {
    if (fullSizeFile instanceof Blob) {
      const url = URL.createObjectURL(fullSizeFile);
      setObjectUrl(url);
      return () => {
        URL.revokeObjectURL(url);
      };
    }
  }, [fullSizeFile]);

  if (status === "pending") {
    return (
      <img
        src={slide.src}
        alt={slide.alt}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "contain",
        }}
      />
    );
  } else if (status === "error") {
    return <div>Error loading full-size file...</div>;
  }

  return (
    <img
      src={objectUrl || slide.src}
      alt={slide.alt}
      style={{
        width: "100%",
        height: "100%",
        objectFit: "contain",
      }}
    />
  );
};

export default ImageSlide;
