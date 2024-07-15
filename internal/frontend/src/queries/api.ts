import axios from "axios";
import { PaginatedFiles, Stats } from "@/queries/model";

export const BASE_URL = "/api";

const api = axios.create({
  baseURL: BASE_URL,
});

export type PaginationParams = {
  page: number;
  pageSize: number;
  order?: string;
  direction?: string;
  type?: string;
  seed: number | null;
};

export const fetchPaginatedFiles = async ({
  page,
  pageSize,
  order,
  direction,
  type,
  seed,
}: PaginationParams): Promise<PaginatedFiles> => {
  const { data } = await api.get<PaginatedFiles>("/", {
    params: {
      page,
      page_size: pageSize,
      order,
      direction,
      type,
      seed,
    },
  });
  return data;
};

export const deleteFile = async (ids: string): Promise<void> => {
  await api.delete(`/`, {
    headers: {},
    data: {
      ids: ids,
    },
  });
};

export const toggleFavorite = async (id: number): Promise<void> => {
  await api.patch(`/${id}/favorite`, {});
};

export const getIsFavorite = async (id: number): Promise<boolean> => {
  const { data } = await api.get<boolean>(`/${id}/favorite`);
  return data;
};

export const fetchStats = async (): Promise<Stats> => {
  const { data } = await api.get<Stats>("/stats");
  return data;
};
