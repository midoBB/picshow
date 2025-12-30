import * as z from "zod";

export const MimeTypeSchema = z.enum(["image", "video"]);
export type MimeType = z.infer<typeof MimeTypeSchema>;

export const ImageSchema = z.object({
  Width: z.number(),
  Height: z.number(),
  ThumbnailWidth: z.number(),
  ThumbnailHeight: z.number(),
  // ThumbnailBase64: z.string(),
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
  Id: z.string(),
  Hash: z.string(),
  CreatedAt: z.coerce.date(),
  Filename: z.string(),
  Size: z.number(),
  MediaType: MimeTypeSchema,
  MimeType: z.string(),
  IsFavorite: z.boolean(),
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
  is_processing: z.boolean(),
});
export type Stats = z.infer<typeof StatsSchema>;

export const DuplicateHandlingSchema = z.enum([
  "movetofolder",
  "delete",
  "skip",
]);
export type DuplicateHandling = z.infer<typeof DuplicateHandlingSchema>;

export const DeleteModeSchema = z.enum(["movetotrash", "deletepermanently"]);
export type DeleteMode = z.infer<typeof DeleteModeSchema>;

export const AppSettingsSchema = z.object({
  duplicateHandling: DuplicateHandlingSchema,
  deleteMode: DeleteModeSchema,
  autoRefreshEnabled: z.boolean(),
  autoRefreshDuration: z.number(),
});
export type AppSettings = z.infer<typeof AppSettingsSchema>;

export type PartialAppSettings = Partial<AppSettings>;

// ===== Clustering Schemas =====

export const ClusterDTOSchema = z.object({
  clusterId: z.number(),
  imageCount: z.number(),
  representativeImageId: z.string(),
  previewThumbnails: z.array(z.string()),
  isResolved: z.boolean(),
  createdAt: z.coerce.date(),
});
export type ClusterDTO = z.infer<typeof ClusterDTOSchema>;

export const ClusterImageSchema = z.object({
  id: z.string(),
  filename: z.string(),
  hammingDistance: z.number(),
  isBestShot: z.boolean(),
  thumbnail: z.string(),
  width: z.number(),
  height: z.number(),
});
export type ClusterImage = z.infer<typeof ClusterImageSchema>;

export const ClustersResponseSchema = z.object({
  clusters: z.array(ClusterDTOSchema),
  pagination: PaginationSchema,
});
export type ClustersResponse = z.infer<typeof ClustersResponseSchema>;

export const ClusterDetailResponseSchema = z.object({
  clusterId: z.number(),
  images: z.array(ClusterImageSchema),
});
export type ClusterDetailResponse = z.infer<typeof ClusterDetailResponseSchema>;
