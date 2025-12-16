import { parseAsInteger, parseAsStringLiteral, useQueryState } from "nuqs";
import { usePaginatedFiles } from "@/queries/loaders";

const PAGE_SIZE = 15;

export const useGalleryFiltering = () => {
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

  const [seed, setSeed] = useQueryState("seed", parseAsInteger);

  const {
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isLoading,
    isError,
    error,
  } = usePaginatedFiles({
    pageSize: PAGE_SIZE,
    order: sortType,
    direction: sortDirection,
    type: selectedCategory === "all" ? undefined : selectedCategory,
    seed: sortType === "random" ? seed : null,
  });

  return {
    sortDirection,
    setSortDirection,
    sortType,
    setSortType,
    selectedCategory,
    setSelectedCategory,
    seed,
    setSeed,
    data,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
    isLoading,
    isError,
    error,
  };
};
