import type { VirtualItem } from "@tanstack/react-virtual";
import type { File } from "@/queries/model";

export interface FileItemProps {
  file: File;
  virtualRow: VirtualItem;
  columnCount: number;
  onContextMenu: (e: React.MouseEvent, fileId: string) => void;
  onClick: (index: number, fileId: string) => void;
  isSelected: boolean;
}

export interface VideoSlideType {
  type: "video";
  width?: number;
  height?: number;
  poster?: string;
  sources: Array<{ src: string; type: string }>;
  id: string;
  hash: string;
}

export interface ImageSlideType {
  type: "image";
  src: string;
  width?: number;
  height?: number;
  srcSet?: Array<{ src?: string; width?: number; height?: number }>;
  alt: string;
  id: string;
  hash: string;
}

export type SlideType = VideoSlideType | ImageSlideType;

export interface CustomSlideProps {
  slide: SlideType;
}
