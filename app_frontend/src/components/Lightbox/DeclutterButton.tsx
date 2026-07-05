import { createIcon, IconButton } from "yet-another-react-lightbox";

const DeclutterIcon = createIcon(
  "DeclutterIcon",
  <path
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
    d="M8 3H3v5m13-5h5v5M3 16v5h5m13-5v5h-5"
  />,
);

interface DeclutterButtonProps {
  isDecluttered: boolean;
  onToggle: () => void;
}

export function DeclutterButton({
  isDecluttered,
  onToggle,
}: DeclutterButtonProps) {
  return (
    <IconButton
      label={isDecluttered ? "Show controls" : "Declutter viewer"}
      icon={DeclutterIcon}
      onClick={onToggle}
    />
  );
}
