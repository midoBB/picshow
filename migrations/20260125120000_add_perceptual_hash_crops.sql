-- Add additional perceptual hash columns for crop-aware similarity
-- Keep existing `images.perceptual_hash` as the "full" hash for backward compatibility.

ALTER TABLE images ADD COLUMN perceptual_hash_center INTEGER;
ALTER TABLE images ADD COLUMN perceptual_hash_tl INTEGER;
ALTER TABLE images ADD COLUMN perceptual_hash_tr INTEGER;
ALTER TABLE images ADD COLUMN perceptual_hash_bl INTEGER;
ALTER TABLE images ADD COLUMN perceptual_hash_br INTEGER;

CREATE INDEX idx_images_perceptual_hash_center ON images(perceptual_hash_center)
  WHERE perceptual_hash_center IS NOT NULL;
CREATE INDEX idx_images_perceptual_hash_tl ON images(perceptual_hash_tl)
  WHERE perceptual_hash_tl IS NOT NULL;
CREATE INDEX idx_images_perceptual_hash_tr ON images(perceptual_hash_tr)
  WHERE perceptual_hash_tr IS NOT NULL;
CREATE INDEX idx_images_perceptual_hash_bl ON images(perceptual_hash_bl)
  WHERE perceptual_hash_bl IS NOT NULL;
CREATE INDEX idx_images_perceptual_hash_br ON images(perceptual_hash_br)
  WHERE perceptual_hash_br IS NOT NULL;
