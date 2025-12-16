import React, { useEffect, useRef, useState } from "react";
import { FaRegPlayCircle } from "react-icons/fa";
import { LuLoader2 } from "react-icons/lu";
import { useThumbnail } from "@/queries/loaders";
import type { FileItemProps } from "@/types/gallery";

export const FileItem = React.memo(
  ({
    file,
    virtualRow,
    columnCount,
    onContextMenu,
    onClick,
    isSelected,
  }: FileItemProps) => {
    const ref = useRef<HTMLDivElement>(null);
    const [isIntersecting, setIsIntersecting] = useState(false);

    useEffect(() => {
      const observer = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting) {
              setIsIntersecting(true);
              observer.unobserve(entry.target);
            }
          });
        },
        {
          rootMargin: "50px",
        },
      );

      if (ref.current) {
        observer.observe(ref.current);
      }

      return () => {
        if (ref.current) {
          observer.unobserve(ref.current);
        }
      };
    }, []);

    const { data: thumbnailUrl, isLoading } = useThumbnail(
      isIntersecting ? file.Id : "",
    );

    const aspectRatio = file.Image
      ? file.Image.ThumbnailWidth / file.Image.ThumbnailHeight
      : file.Video
        ? file.Video.ThumbnailWidth / file.Video.ThumbnailHeight
        : 1;

    return (
      <div
        ref={ref}
        className={`cursor-pointer group ${isSelected ? "border-2 border-blue-500 rounded-lg" : ""}`}
        onContextMenu={(e) => onContextMenu(e, file.Id)}
        onClick={() => onClick(virtualRow.index, file.Id)}
        style={{
          position: "absolute",
          top: 0,
          left: `${(virtualRow.lane / columnCount) * 100}%`,
          width: `${100 / columnCount}%`,
          height: `${virtualRow.size}px`,
          transform: `translateY(${virtualRow.start}px)`,
          padding: "8px",
        }}
      >
        <figure className="relative w-full h-full overflow-hidden rounded-lg transform group-hover:shadow transition duration-300 ease-out">
          <div
            className="absolute w-full h-full object-cover rounded-lg transform group-hover:scale-105 transition duration-300 ease-out"
            style={{ aspectRatio }}
          >
            {isLoading && (
              <div className="absolute inset-0 flex items-center justify-center bg-gray-100 dark:bg-gray-800">
                <LuLoader2 className="w-8 h-8 animate-spin text-blue-500" />
              </div>
            )}

            {thumbnailUrl && (
              <>
                <img
                  src={thumbnailUrl}
                  alt={file.Filename}
                  className="w-full h-full object-cover rounded-lg"
                />
                {file.Video && (
                  <div className="absolute inset-0 flex items-center justify-center">
                    <FaRegPlayCircle className="text-white h-16 w-16 text-4xl opacity-70" />
                  </div>
                )}
              </>
            )}
          </div>
        </figure>

        {isSelected && (
          <div className="absolute top-2 left-2 w-6 h-6 bg-blue-500 rounded-full flex items-center justify-center">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              className="h-4 w-4 text-white"
              viewBox="0 0 20 20"
              fill="currentColor"
            >
              <path
                fillRule="evenodd"
                d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                clipRule="evenodd"
              />
            </svg>
          </div>
        )}
      </div>
    );
  },
);
