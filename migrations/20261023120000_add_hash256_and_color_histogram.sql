-- 256-bit (16x16) gradient hash of the full image, stored as 32 big-endian bytes.
ALTER TABLE images ADD COLUMN perceptual_hash_256 BLOB;

-- HSV colour histogram (8 H x 4 S x 4 V = 128 bins), u16 little-endian, bins sum to 65535.
ALTER TABLE images ADD COLUMN color_histogram BLOB;
