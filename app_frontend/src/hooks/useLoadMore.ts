import { useMemo } from "react";
import debounce from "lodash/debounce";

export const useLoadMore = (
  hasNextPage: boolean,
  isFetchingNextPage: boolean,
  fetchNextPage: () => void,
) => {
  const debouncedLoadMore = useMemo(
    () =>
      debounce(() => {
        if (hasNextPage && !isFetchingNextPage) {
          fetchNextPage();
        }
      }, 200),
    [fetchNextPage, hasNextPage, isFetchingNextPage],
  );

  return { debouncedLoadMore };
};
