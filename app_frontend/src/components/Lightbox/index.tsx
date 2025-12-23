import type React from "react";
import { lazy, Suspense } from "react";
import type { SlideshowRef } from "yet-another-react-lightbox";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import type { SlideType } from "@/types/gallery";
import { CustomSlide } from "./CustomSlide";
import { DeleteButton } from "./DeleteButton";
import { FavoriteButton } from "./FavoriteButton";
import { useLightboxKeyboardNavigation } from "@/hooks/useLightboxKeyboardNavigation";

const Lightbox = lazy(() => import("yet-another-react-lightbox"));

interface LightboxContainerProps {
	open: boolean;
	onClose: () => void;
	currentIndex: number;
	onIndexChange: (index: number) => void;
	slides: SlideType[];
	isShowingControls: boolean;
	onControlsToggle: () => void;
	onViewChange: ({ index }: { index: number }) => void;
	slideShowRef: React.MutableRefObject<SlideshowRef | null>;
	onCurrentSlideDelete?: (slideId: string) => void;
}

export const LightboxContainer = ({
	open,
	onClose,
	currentIndex,
	onIndexChange,
	slides,
	isShowingControls,
	onControlsToggle,
	onViewChange,
	slideShowRef,
	onCurrentSlideDelete,
}: LightboxContainerProps) => {
	useLightboxKeyboardNavigation({
		isOpen: open,
		currentIndex,
		onIndexChange,
		slides,
	});

	return (
		<Suspense fallback={null}>
			<Lightbox
				open={open}
				close={onClose}
				carousel={{ finite: true }}
				index={currentIndex}
				slides={slides}
				fullscreen={{ auto: false }}
				slideshow={{ autoplay: false, delay: 5000, ref: slideShowRef }}
				plugins={[Thumbnails, Fullscreen, Slideshow]}
				thumbnails={{ showToggle: true, hidden: true }}
				toolbar={{
					buttons: [
						<FavoriteButton key="favorite" />,
						<DeleteButton key="delete" onDelete={onCurrentSlideDelete} />,
						"close",
					],
				}}
				render={{
					slide: CustomSlide,
					buttonPrev:
						isShowingControls && currentIndex > 0 ? undefined : () => null,
					buttonNext:
						isShowingControls && currentIndex < slides.length - 1
							? undefined
							: () => null,
				}}
				on={{
					click: onControlsToggle,
					view: onViewChange,
				}}
			/>
		</Suspense>
	);
};
