import axios from "axios";
import { PaginatedFiles, Stats } from "@/queries/model";

export const BASE_URL = "/api";

const api = axios.create({
  baseURL: BASE_URL,
});
export const fetchStats = async (): Promise<Stats> => {
  const { data } = await api.get<Stats>("/stats");
  return data;
};

export type PaginationParams = {
  page: number;
  pageSize: number;
};

export const fetchPaginatedFiles = async ({
  pageSize,
  page,
}: PaginationParams): Promise<PaginatedFiles> => {
  const { data } = await api.get<PaginatedFiles>("/", {
    params: {
      page,
      page_size: pageSize,
    },
  });
  return data;
};

export const fetchFileContents = async (id: string): Promise<Blob> => {
  const response = await api.get(`/image/${id}`, {
    responseType: "blob",
  });
  return response.data;
};
