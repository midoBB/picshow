import type { Virtualizer } from "@tanstack/react-virtual";
import type { File } from "@/queries/model";
import { FileItem } from "./FileItem";

interface GalleryGridProps {
  files: Array<File & { pageIndex: number; fileIndex: number }>;
  columnCount: number;
  virtualizer: Virtualizer<HTMLDivElement, Element>;
  onContextMenu: (e: React.MouseEvent, fileId: string) => void;
  onClick: (index: number, fileId: string) => void;
  selectedFiles: string[];
}

export const GalleryGrid = ({
  files,
  columnCount,
  virtualizer,
  onContextMenu,
  onClick,
  selectedFiles,
}: GalleryGridProps) => {
  return (
    <div
      style={{
        height: `${virtualizer.getTotalSize()}px`,
        width: "100%",
        position: "relative",
      }}
    >
      {virtualizer.getVirtualItems().map((virtualRow) => {
        const file = files[virtualRow.index];
        return (
          <FileItem
            key={file.Id}
            file={file}
            virtualRow={virtualRow}
            columnCount={columnCount}
            onContextMenu={onContextMenu}
            onClick={onClick}
            isSelected={selectedFiles.includes(file.Id)}
          />
        );
      })}
    </div>
  );
};
