import { useMemo } from "react";
import { useQueries } from "@tanstack/react-query";
import type { File } from "@/queries/model";
import { BASE_URL, fetchThumbnail } from "@/queries/api";
import type { SlideType } from "@/types/gallery";

export const useLightboxSlides = (
  allFiles: Array<File & { pageIndex: number; fileIndex: number }>,
  currentIndex: number,
  isOpen: boolean,
) => {
  const slideFiles = useMemo(
    () =>
      allFiles.map((file) => ({
        id: file.Id,
        type: file.MediaType,
      })),
    [allFiles],
  );

  const thumbnailQueries = useQueries({
    queries: slideFiles.map((file, index) => {
      const distanceFromCurrent = Math.abs(index - currentIndex);
      const shouldLoad = isOpen && distanceFromCurrent <= 5;

      return {
        queryKey: ["thumbnail", file.id],
        queryFn: () => fetchThumbnail(file.id),
        staleTime: Infinity,
        gcTime: Infinity,
        refetchOnWindowFocus: false,
        refetchOnReconnect: false,
        refetchOnMount: false,
        enabled: shouldLoad,
      };
    }),
  });

  const thumbnailMap = useMemo(() => {
    return thumbnailQueries.reduce(
      (acc, query, index) => {
        const fileId = slideFiles[index].id;
        if (query.data) {
          acc[fileId] = query.data;
        }
        return acc;
      },
      {} as Record<string, string>,
    );
  }, [thumbnailQueries, slideFiles]);

  const slides: SlideType[] = useMemo(
    () =>
      allFiles.map((file) => {
        const thumbnailUrl = thumbnailMap[file.Id];
        if (file.MediaType === "video") {
          return {
            type: "video" as const,
            width: file.Video?.Width,
            height: file.Video?.Height,
            poster: thumbnailUrl,
            sources: [
              {
                src: `${BASE_URL}/video/${file.Id}`,
                type: file.MimeType,
              },
            ],
            id: file.Id,
            hash: file.Hash,
          };
        } else {
          return {
            type: "image" as const,
            src: `${BASE_URL}/image/${file.Id}`,
            width: file.Image?.Width,
            height: file.Image?.Height,
            srcSet: [
              {
                src: thumbnailUrl,
                width: file.Image?.ThumbnailWidth,
                height: file.Image?.ThumbnailHeight,
              },
              {
                src: `${BASE_URL}/image/${file.Id}`,
                width: file.Image?.Width,
                height: file.Image?.Height,
              },
            ],
            alt: file.Filename,
            id: file.Id,
            hash: file.Hash,
          };
        }
      }),
    [allFiles, thumbnailMap],
  );

  return { slides, thumbnailMap };
};
