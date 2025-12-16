import {
  createIcon,
  IconButton,
  useLightboxState,
} from "yet-another-react-lightbox";
import { useGetIsFavorite, useToggleFavorite } from "@/queries/loaders";

const FilledHeartIcon = createIcon(
  "FilledHeartIcon",
  <path
    fill="currentColor"
    d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"
  />,
);

const EmptyHeartIcon = createIcon(
  "EmptyHeartIcon",
  <path
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"
  />,
);

export function FavoriteButton() {
  const { currentSlide } = useLightboxState();
  const toggleFavoriteMutation = useToggleFavorite();
  const { data: isFavorite, isLoading } = useGetIsFavorite(
    currentSlide?.id || 0,
  );

  const handleToggleFavorite = () => {
    if (currentSlide && currentSlide.id) {
      toggleFavoriteMutation.mutate(currentSlide.id.toString());
    }
  };

  const HeartIcon = isFavorite ? FilledHeartIcon : EmptyHeartIcon;

  return (
    <IconButton
      label={isFavorite ? "Remove from favorites" : "Add to favorites"}
      icon={HeartIcon}
      disabled={!currentSlide || isLoading}
      onClick={handleToggleFavorite}
    />
  );
}
