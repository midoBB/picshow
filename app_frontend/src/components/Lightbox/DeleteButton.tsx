import {
  createIcon,
  IconButton,
  useLightboxState,
} from "yet-another-react-lightbox";

const TrashIcon = createIcon(
  "TrashIcon",
  <path
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    d="M3 6h18M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"
  />,
);

interface DeleteButtonProps {
  onDelete?: (slideId: string) => void;
  disabled?: boolean;
}

export function DeleteButton({ onDelete, disabled }: DeleteButtonProps) {
  const { currentSlide } = useLightboxState();

  const handleDelete = () => {
    if (currentSlide && currentSlide.id && onDelete) {
      onDelete(currentSlide.id);
    }
  };

  return (
    <IconButton
      label="Delete"
      icon={TrashIcon}
      disabled={disabled || !currentSlide || !onDelete}
      onClick={handleDelete}
    />
  );
}
