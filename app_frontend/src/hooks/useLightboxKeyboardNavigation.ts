import { useEffect } from "react";

interface UseLightboxKeyboardNavigationProps {
	isOpen: boolean;
	currentIndex: number;
	onIndexChange: (index: number) => void;
	slides: unknown[];
}

export const useLightboxKeyboardNavigation = ({
	isOpen,
	currentIndex,
	onIndexChange,
	slides,
}: UseLightboxKeyboardNavigationProps) => {
	useEffect(() => {
		if (!isOpen) return undefined;

		const handleKeyDown = (event: KeyboardEvent) => {
			const key = event.key.toLowerCase();
			let newIndex = currentIndex;

			switch (key) {
				case "arrowleft":
				case "h":
					if (currentIndex > 0) {
						newIndex = currentIndex - 1;
					}
					break;
				case "arrowright":
				case "l":
				case "n":
					if (currentIndex < slides.length - 1) {
						newIndex = currentIndex + 1;
					}
					break;
				case "p":
					if (currentIndex > 0) {
						newIndex = currentIndex - 1;
					}
					break;
				case "arrowup":
					if (currentIndex < slides.length - 1) {
						newIndex = currentIndex + 1;
					}
					break;
				case "arrowdown":
					if (currentIndex > 0) {
						newIndex = currentIndex - 1;
					}
					break;
				default:
					return;
			}

			if (newIndex !== currentIndex) {
				event.preventDefault();
				onIndexChange(newIndex);
			}
		};

		document.addEventListener("keydown", handleKeyDown);

		return () => {
			document.removeEventListener("keydown", handleKeyDown);
		};
	}, [isOpen, currentIndex, onIndexChange, slides]);
};
