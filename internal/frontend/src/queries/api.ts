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

export const deleteFile = async (id: number): Promise<void> => {
  await api.delete(`/${id}`);
};

export const fetchStats = async (): Promise<Stats> => {
  const { data } = await api.get<Stats>("/stats");
  return data;
};
