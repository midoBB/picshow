import React, {
	lazy,
	Suspense,
	useCallback,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { FaRegPlayCircle } from "react-icons/fa";
import { LuLoader2, LuX } from "react-icons/lu";
import {
	createIcon,
	IconButton,
	type SlideshowRef,
	useLightboxState,
} from "yet-another-react-lightbox";
import Fullscreen from "yet-another-react-lightbox/plugins/fullscreen";
import Slideshow from "yet-another-react-lightbox/plugins/slideshow";
import Thumbnails from "yet-another-react-lightbox/plugins/thumbnails";

const Lightbox = lazy(() => import("yet-another-react-lightbox"));
import Navbar from "@/Navbar";
import { BASE_URL, fetchThumbnail } from "@/queries/api";
import "yet-another-react-lightbox/styles.css";
import "yet-another-react-lightbox/plugins/thumbnails.css";
import { useQueries } from "@tanstack/react-query";
import { useVirtualizer, type VirtualItem } from "@tanstack/react-virtual";
import debounce from "lodash/debounce";
import { parseAsInteger, parseAsStringLiteral, useQueryState } from "nuqs";
import ConfirmDialog from "@/ConfirmDeleteDialog";
import KeepAwake from "@/KeepAwake";
import {
	useDeleteFile,
	useGetIsFavorite,
	usePaginatedFiles,
	useThumbnail,
	useToggleFavorite,
} from "@/queries/loaders";
import type { File } from "@/queries/model";
import useAppState from "@/state";
import VideoSlide from "@/VideoSlide";

const PAGE_SIZE = 15;

interface FileItemProps {
	file: File;
	virtualRow: VirtualItem;
	columnCount: number;
	onContextMenu: (e: React.MouseEvent, fileId: string) => void;
	onClick: (index: number, fileId: string) => void;
	isSelected: boolean;
}

interface VideoSlideType {
	type: "video";
	width?: number;
	height?: number;
	poster?: string;
	sources: Array<{ src: string; type: string }>;
	id: string;
	hash: string;
}

interface ImageSlideType {
	type: "image";
	src: string;
	width?: number;
	height?: number;
	srcSet?: Array<{ src?: string; width?: number; height?: number }>;
	alt: string;
	id: string;
	hash: string;
}

type SlideType = VideoSlideType | ImageSlideType;

interface CustomSlideProps {
	slide: SlideType;
}

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

const FileItem = React.memo(
	({
		file,
		virtualRow,
		columnCount,
		onContextMenu,
		onClick,
		isSelected,
	}: FileItemProps) => {
		const ref = useRef<HTMLDivElement>(null);
		const [isIntersecting, setIsIntersecting] = React.useState(false);

		useEffect(() => {
			const observer = new IntersectionObserver(
				(entries) => {
					entries.forEach((entry) => {
						if (entry.isIntersecting) {
							setIsIntersecting(true);
							observer.unobserve(entry.target);
						}
					});
				},
				{
					rootMargin: "50px", // Start loading slightly before the item comes into view
				},
			);

			if (ref.current) {
				observer.observe(ref.current);
			}

			return () => {
				if (ref.current) {
					observer.unobserve(ref.current);
				}
			};
		}, []);

		const { data: thumbnailUrl, isLoading } = useThumbnail(
			isIntersecting ? file.Id : "", // Only fetch when in view
		);

		const aspectRatio = file.Image
			? file.Image.ThumbnailWidth / file.Image.ThumbnailHeight
			: file.Video
				? file.Video.ThumbnailWidth / file.Video.ThumbnailHeight
				: 1;

		return (
			<div
				ref={ref}
				className={`cursor-pointer group ${isSelected ? "border-2 border-blue-500 rounded-lg" : ""}`}
				onContextMenu={(e) => onContextMenu(e, file.Id)}
				onClick={() => onClick(virtualRow.index, file.Id)}
				style={{
					position: "absolute",
					top: 0,
					left: `${(virtualRow.lane / columnCount) * 100}%`,
					width: `${100 / columnCount}%`,
					height: `${virtualRow.size}px`,
					transform: `translateY(${virtualRow.start}px)`,
					padding: "8px",
				}}
			>
				<figure className="relative w-full h-full overflow-hidden rounded-lg transform group-hover:shadow transition duration-300 ease-out">
					<div
						className="absolute w-full h-full object-cover rounded-lg transform group-hover:scale-105 transition duration-300 ease-out"
						style={{ aspectRatio }}
					>
						{isLoading && (
							<div className="absolute inset-0 flex items-center justify-center bg-gray-100 dark:bg-gray-800">
								<LuLoader2 className="w-8 h-8 animate-spin text-blue-500" />
							</div>
						)}

						{thumbnailUrl && (
							<>
								<img
									src={thumbnailUrl}
									alt={file.Filename}
									className="w-full h-full object-cover rounded-lg"
								/>
								{file.Video && (
									<div className="absolute inset-0 flex items-center justify-center">
										<FaRegPlayCircle className="text-white h-16 w-16 text-4xl opacity-70" />
									</div>
								)}
							</>
						)}
					</div>
				</figure>

				{isSelected && (
					<div className="absolute top-2 left-2 w-6 h-6 bg-blue-500 rounded-full flex items-center justify-center">
						<svg
							xmlns="http://www.w3.org/2000/svg"
							className="h-4 w-4 text-white"
							viewBox="0 0 20 20"
							fill="currentColor"
						>
							<path
								fillRule="evenodd"
								d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
								clipRule="evenodd"
							/>
						</svg>
					</div>
				)}
			</div>
		);
	},
);

function FavoriteButton() {
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
const CustomSlide = ({ slide }: CustomSlideProps) => {
	if (slide.type === "video") {
		return <VideoSlide slide={slide} />;
	}
};

export default function App() {
	const isMobile = useCallback(() => {
		return window.innerWidth < 768; // You can adjust this breakpoint as needed
	}, []);
	const navbarRef = useRef<HTMLDivElement>(null);
	const [isCurrentlyMobile, setIsCurrentlyMobile] = useState(isMobile());
	const [columnCount, setColumnCount] = useState(0);
	const [containerSize, setContainerSize] = useState({ width: 0, height: 0 });
	const containerRef = useRef<HTMLDivElement>(null);
	const slideShowRef = useRef<SlideshowRef>(null);
	const [isSlideshowPlaying, setIsSlideshowPlaying] = useState(false);
	const [seed, setSeed] = useQueryState("seed", parseAsInteger);
	useEffect(() => {
		const handleResize = debounce(() => {
			setIsCurrentlyMobile(isMobile());
			if (isMobile()) {
				setColumnCount(1);
			} else {
				setColumnCount(4);
			}
			if (containerRef.current) {
				setContainerSize({
					width: containerRef.current.offsetWidth,
					height: containerRef.current.offsetHeight,
				});
			}
		}, 150);

		window.addEventListener("resize", handleResize);
		handleResize();

		return () => {
			window.removeEventListener("resize", handleResize);
			handleResize.cancel();
		};
	}, [isMobile]);
	useEffect(() => {
		const timer = setTimeout(() => {
			if (containerRef.current) {
				setContainerSize({
					width: containerRef.current.offsetWidth,
					height: containerRef.current.offsetHeight,
				});
			}
		}, 100);

		return () => clearTimeout(timer);
	}, []);
	const {
		dontAskAgainForDelete,
		setDontAskAgainForDelete,
		setIsSelectionMode,
		setSelectedFiles,
		isSelectionMode,
		selectedFiles,
		isDarkMode,
	} = useAppState();

	const isFirstRun = useRef(true);

	useEffect(() => {
		if (!seed && isFirstRun.current) {
			setSeed(Math.floor(Date.now() / 1000));
		}
	}, [seed, setSeed]);

	useEffect(() => {
		if (isFirstRun.current) {
			isFirstRun.current = false;
		}
	}, []);
	const [isOpen, setIsOpen] = useState(false);
	const [currentIndex, setCurrentIndex] = useState(0);
	const [isShowingControls, setIsShowingControls] = useState(true);

	const openLightbox = useCallback(
		(index: number) => {
			setCurrentIndex(index);
			setIsOpen(true);
		},
		[setCurrentIndex, setIsOpen],
	);

	const deleteFileMutation = useDeleteFile();

	const [deleteDialogState, setDeleteDialogState] = useState<{
		isOpen: boolean;
		itemIds: string[];
	}>({
		isOpen: false,
		itemIds: [],
	});

	const handleDelete = useCallback(() => {
		if (dontAskAgainForDelete) {
			deleteFileMutation.mutate(selectedFiles.join(","));
			setSelectedFiles(() => []);
			setIsSelectionMode(false);
		} else {
			setDeleteDialogState({ isOpen: true, itemIds: selectedFiles });
		}
	}, [
		deleteFileMutation,
		dontAskAgainForDelete,
		selectedFiles,
		setIsSelectionMode,
		setSelectedFiles,
	]);

	const confirmDelete = useCallback(() => {
		deleteFileMutation.mutate(deleteDialogState.itemIds.join(","));
		setDeleteDialogState({ isOpen: false, itemIds: [] });
		setSelectedFiles(() => []);
		setIsSelectionMode(false);
	}, [
		deleteDialogState.itemIds,
		deleteFileMutation,
		setIsSelectionMode,
		setSelectedFiles,
	]);

	const handleOpenChange = useCallback(
		(open: boolean) => {
			if (!open) {
				setDeleteDialogState((prev) => ({ ...prev, isOpen: false }));
				setSelectedFiles(() => []);
				setIsSelectionMode(false);
			}
		},
		[setIsSelectionMode, setSelectedFiles],
	);
	const sortDirectionOptions = ["asc", "desc"] as const;
	const [sortDirection, setSortDirection] = useQueryState(
		"sortDirection",
		parseAsStringLiteral(sortDirectionOptions).withDefault("desc"),
	);
	const sortTypeOptions = ["created_at", "random"] as const;
	const [sortType, setSortType] = useQueryState(
		"sortType",
		parseAsStringLiteral(sortTypeOptions).withDefault("random"),
	);
	const selectedCategoryOptions = [
		"all",
		"video",
		"image",
		"favorite",
	] as const;
	const [selectedCategory, setSelectedCategory] = useQueryState(
		"selectedCategory",
		parseAsStringLiteral(selectedCategoryOptions).withDefault("all"),
	);
	const {
		data,
		fetchNextPage,
		hasNextPage,
		isFetchingNextPage,
		isLoading: isLoadingFiles,
		isError: isErrorFiles,
		error: errorFiles,
	} = usePaginatedFiles({
		pageSize: PAGE_SIZE,
		order: sortType,
		direction: sortDirection,
		type: selectedCategory === "all" ? undefined : selectedCategory,
		seed: sortType === "random" ? seed : null,
	});

	const allFiles = useMemo(() => {
		if (!data?.pages) return [];

		const uniqueFiles = [];
		const seenIds = new Set<string>();

		for (let pageIndex = 0; pageIndex < data.pages.length; pageIndex++) {
			const page = data.pages[pageIndex];
			for (let fileIndex = 0; fileIndex < page.files.length; fileIndex++) {
				const file = page.files[fileIndex];
				if (!seenIds.has(file.Id)) {
					seenIds.add(file.Id);
					uniqueFiles.push({ ...file, pageIndex, fileIndex });
				}
			}
		}

		return uniqueFiles;
	}, [data]);
	const slideFiles = useMemo(
		() =>
			allFiles.map((file) => ({
				id: file.Id,
				type: file.MediaType,
			})),
		[allFiles],
	);

	const thumbnailQueries = useQueries({
		queries: slideFiles.map((file, index) => {
			const distanceFromCurrent = Math.abs(index - currentIndex);
			const shouldLoad = isOpen && distanceFromCurrent <= 5;

			return {
				queryKey: ["thumbnail", file.id],
				queryFn: () => fetchThumbnail(file.id),
				staleTime: Infinity,
				gcTime: Infinity,
				refetchOnWindowFocus: false,
				refetchOnReconnect: false,
				refetchOnMount: false,
				enabled: shouldLoad,
			};
		}),
	});
	const thumbnailMap = useMemo(() => {
		return thumbnailQueries.reduce(
			(acc, query, index) => {
				const fileId = slideFiles[index].id;
				if (query.data) {
					acc[fileId] = query.data;
				}
				return acc;
			},
			{} as Record<string, string>,
		);
	}, [thumbnailQueries, slideFiles]);
	const estimateSize = useCallback(
		(index: number) => {
			const file = allFiles[index];
			if (file.Image) {
				return file.Image.ThumbnailHeight;
			} else if (file.Video) {
				return file.Video.ThumbnailHeight;
			} else {
				return 300;
			}
		},
		[allFiles],
	);

	const rowVirtualizer = useVirtualizer({
		count: allFiles.length,
		getScrollElement: () => containerRef.current,
		estimateSize,
		overscan: isCurrentlyMobile ? 2 : 5,
		lanes: columnCount,
	});
	useEffect(() => {
		rowVirtualizer.measure();
	}, [allFiles, containerSize, rowVirtualizer]);
	const debouncedLoadMoreItems = useMemo(
		() =>
			debounce(() => {
				if (hasNextPage && !isFetchingNextPage) {
					fetchNextPage();
				}
			}, 200),
		[fetchNextPage, hasNextPage, isFetchingNextPage],
	);

	useEffect(() => {
		const scrollElement = containerRef.current;
		if (!scrollElement) return;

		const handleScroll = () => {
			if (
				scrollElement.scrollTop + scrollElement.clientHeight >=
				scrollElement.scrollHeight - 300
			) {
				debouncedLoadMoreItems();
			}
		};

		scrollElement.addEventListener("scroll", handleScroll);
		return () => {
			scrollElement.removeEventListener("scroll", handleScroll);
			debouncedLoadMoreItems.cancel();
		};
	}, [debouncedLoadMoreItems]);

	const slides = useMemo(
		() =>
			allFiles.map((file) => {
				const thumbnailUrl = thumbnailMap[file.Id];
				if (file.MediaType === "video") {
					return {
						type: "video",
						width: file.Video?.Width,
						height: file.Video?.Height,
						poster: thumbnailUrl,
						sources: [
							{
								src: `${BASE_URL}/video/${file.Id}`,
								type: file.MimeType,
							},
						],
						id: file.Id,
						hash: file.Hash,
					};
				} else {
					return {
						type: "image",
						src: `${BASE_URL}/image/${file.Id}`,
						width: file.Image?.Width,
						height: file.Image?.Height,
						srcSet: [
							{
								src: thumbnailUrl,
								width: file.Image?.ThumbnailWidth,
								height: file.Image?.ThumbnailHeight,
							},
							{
								src: `${BASE_URL}/image/${file.Id}`,
								width: file.Image?.Width,
								height: file.Image?.Height,
							},
						],
						alt: file.Filename,
						id: file.Id,
						hash: file.Hash,
					};
				}
			}),
		[allFiles, thumbnailMap],
	);

	const toggleFileSelection = useCallback(
		(id: string) => {
			setSelectedFiles((prev) => {
				if (prev.includes(id)) {
					const newSelection = prev.filter((fileId) => fileId !== id);
					if (newSelection.length === 0) {
						setIsSelectionMode(false);
					}
					return newSelection;
				} else {
					setIsSelectionMode(true);
					return [...prev, id];
				}
			});
		},
		[setIsSelectionMode, setSelectedFiles],
	);
	const handleContextMenu = useCallback(
		(event: React.MouseEvent, id: string) => {
			event.preventDefault();
			toggleFileSelection(id);
		},
		[toggleFileSelection],
	);

	const handleClick = useCallback(
		(index: number, ID: string) => {
			if (!isSelectionMode) {
				openLightbox(index);
			} else {
				toggleFileSelection(ID);
			}
		},
		[isSelectionMode, openLightbox, toggleFileSelection],
	);

	const selectedFileObjects = useMemo(() => {
		if (isSelectionMode) {
			return allFiles.filter((file) => selectedFiles.includes(file.Id));
		} else {
			return [];
		}
	}, [allFiles, isSelectionMode, selectedFiles]);
	useEffect(() => {
		setIsSlideshowPlaying(!!slideShowRef.current?.playing);
	}, [slideShowRef.current?.playing, setIsSlideshowPlaying]);

	return (
		<div
			className={`flex flex-col h-full ${isDarkMode ? "bg-slate-800" : "bg-white"}`}
		>
			<KeepAwake isActive={isSlideshowPlaying} />
			<div ref={navbarRef}>
				<Navbar
					onDelete={handleDelete}
					setSeed={setSeed}
					setSortType={setSortType}
					setSortDirection={setSortDirection}
					setSelectedCategory={setSelectedCategory}
					sortDirection={sortDirection}
					sortType={sortType}
					selectedCategory={selectedCategory}
				/>
			</div>
			<Suspense fallback={null}>
				<Lightbox
					open={isOpen}
					close={() => setIsOpen(false)}
					carousel={{ finite: true }}
					index={currentIndex}
					slides={slides}
					fullscreen={{ auto: true }}
					slideshow={{ autoplay: false, delay: 5000, ref: slideShowRef }}
					plugins={[Thumbnails, Fullscreen, Slideshow]}
					thumbnails={{ showToggle: true, hidden: true }}
					toolbar={{
						buttons: [<FavoriteButton key="my-button" />, "close"],
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
						click: () => {
							setIsShowingControls(!isShowingControls);
						},
						view: ({ index }) => {
							setCurrentIndex(index);
							if (
								index === slides.length - 1 &&
								hasNextPage &&
								!isFetchingNextPage
							) {
								fetchNextPage();
							}
						},
					}}
				/>
			</Suspense>
			{isErrorFiles ? (
				<div
					className={`flex items-center justify-center h-screen ${isDarkMode ? "bg-gray-900 text-white" : "bg-white text-gray-900"}`}
				>
					<div className="text-center p-8">
						<h2 className="text-2xl font-bold mb-4">Error Loading Files</h2>
						<p className="text-gray-500 mb-4">
							{errorFiles instanceof Error
								? errorFiles.message
								: "Failed to load media files. Please try again."}
						</p>
						<button
							onClick={() => window.location.reload()}
							className={`px-4 py-2 rounded ${isDarkMode ? "bg-blue-600 hover:bg-blue-700" : "bg-blue-500 hover:bg-blue-600"} text-white`}
						>
							Reload Page
						</button>
					</div>
				</div>
			) : isLoadingFiles ? (
				<div
					ref={containerRef}
					className="w-full p-4 mx-auto flex-grow overflow-auto"
					style={{
						height: `calc(100vh - ${navbarRef.current?.clientHeight}px)`,
					}}
				>
					<div className="grid grid-cols-1 md:grid-cols-4 gap-4">
						{Array.from({ length: 12 }).map((_, index) => (
							<div
								key={index}
								className={`aspect-square rounded-lg animate-pulse ${isDarkMode ? "bg-gray-700" : "bg-gray-200"}`}
							/>
						))}
					</div>
				</div>
			) : (
				<>
					<div
						ref={containerRef}
						className="w-full p-4 mx-auto flex-grow overflow-auto"
						style={{
							height: `calc(100vh - ${navbarRef.current?.clientHeight}px)`,
						}}
					>
						{allFiles.length === 0 ? (
							<div
								className={`flex flex-col items-center justify-center h-full ${isDarkMode ? "text-gray-400" : "text-gray-500"}`}
							>
								<FaRegPlayCircle size={64} className="mb-4 opacity-50" />
								<h2 className="text-2xl font-bold mb-2">No Media Found</h2>
								<p className="text-center max-w-md">
									{selectedCategory === "favorite"
										? "You haven't favorited any files yet. Click the heart icon on any image or video to add it to your favorites."
										: selectedCategory !== "all"
											? `No ${selectedCategory}s found. Try selecting a different filter.`
											: "No media files found. Make sure your media folder contains images or videos."}
								</p>
							</div>
						) : (
							<div
								style={{
									height: `${rowVirtualizer.getTotalSize()}px`,
									width: "100%",
									position: "relative",
								}}
							>
								{rowVirtualizer.getVirtualItems().map((virtualRow) => {
									const file = allFiles[virtualRow.index];
									return (
										<FileItem
											key={virtualRow.index}
											file={file}
											virtualRow={virtualRow}
											columnCount={columnCount}
											onContextMenu={handleContextMenu}
											onClick={handleClick}
											isSelected={selectedFiles.includes(file.Id)}
										/>
									);
								})}
							</div>
						)}
						{isFetchingNextPage && (
							<div
								className={`text-center py-4 ${
									isDarkMode ? "text-white" : "text-gray-900"
								} flex justify-center items-center`}
							>
								<span className="inline-flex">
									<span className="animate-bounce">.</span>
									<span className="animate-bounce animation-delay-200">.</span>
									<span className="animate-bounce animation-delay-400">.</span>
								</span>
							</div>
						)}
						{!hasNextPage && allFiles.length > 0 && (
							<div
								className={`text-center py-4 ${
									isDarkMode ? "text-gray-400" : "text-gray-500"
								} flex justify-center items-center`}
							>
								<LuX className="w-6 h-6" />
							</div>
						)}
					</div>
				</>
			)}
			<ConfirmDialog
				isOpen={deleteDialogState.isOpen}
				onOpenChange={handleOpenChange}
				onConfirm={confirmDelete}
				dontAskAgain={dontAskAgainForDelete}
				setDontAskAgain={setDontAskAgainForDelete}
				files={selectedFileObjects}
			/>
		</div>
	);
}
