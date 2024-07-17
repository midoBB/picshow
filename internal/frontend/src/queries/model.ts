import * as z from "zod";

export const MimeTypeSchema = z.enum(["image", "video"]);
export type MimeType = z.infer<typeof MimeTypeSchema>;

export const ImageSchema = z.object({
  ID: z.number(),
  FullMimeType: z.string(),
  Width: z.number(),
  Height: z.number(),
  FileID: z.number(),
  ThumbnailWidth: z.number(),
  ThumbnailHeight: z.number(),
  ThumbnailBase64: z.string(),
  Length: z.number().optional(),
});
export type Image = z.infer<typeof ImageSchema>;

export const PaginationSchema = z.object({
  total_records: z.number(),
  current_page: z.number(),
  total_pages: z.number(),
  next_page: z.null(),
  prev_page: z.null(),
});
export type Pagination = z.infer<typeof PaginationSchema>;

export const FileSchema = z.object({
  ID: z.number(),
  Hash: z.string(),
  CreatedAt: z.coerce.date(),
  Filename: z.string(),
  Size: z.number(),
  MimeType: MimeTypeSchema,
  Image: ImageSchema.optional(),
  Video: ImageSchema.optional(),
});
export type File = z.infer<typeof FileSchema>;

export const PaginatedFilesSchema = z.object({
  files: z.array(FileSchema),
  pagination: PaginationSchema,
});
export type PaginatedFiles = z.infer<typeof PaginatedFilesSchema>;

export const StatsSchema = z.object({
  count: z.number(),
  video_count: z.number(),
  image_count: z.number(),
  favorite_count: z.number(),
});
export type Stats = z.infer<typeof StatsSchema>;
