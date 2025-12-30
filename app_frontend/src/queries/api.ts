import axios from "axios";
import {
  PaginatedFiles,
  Stats,
  AppSettings,
  PartialAppSettings,
  ClustersResponse,
  ClusterDetailResponse,
} from "@/queries/model";

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
  const { data } = await api.get<PaginatedFiles>("", {
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
  await api.delete("", {
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

export const fetchThumbnail = async (fileId: string): Promise<string> => {
  const response = await api.get(`/thumbnail/${fileId}`, {
    responseType: "blob",
  });
  return URL.createObjectURL(response.data);
};

export const fetchSettings = async (): Promise<AppSettings> => {
  const { data } = await api.get<AppSettings>("/settings");
  return data;
};

export const updateSettings = async (
  settings: PartialAppSettings,
): Promise<AppSettings> => {
  const { data } = await api.patch<AppSettings>("/settings", settings);
  return data;
};

export const triggerScan = async (): Promise<void> => {
  await api.post("/internal/trigger-scan");
};

// ===== Clustering API Functions =====

export const fetchClusters = async ({
  page,
  pageSize,
}: {
  page: number;
  pageSize: number;
}): Promise<ClustersResponse> => {
  const { data } = await api.get<ClustersResponse>("/clusters", {
    params: {
      page,
      page_size: pageSize,
    },
  });
  return data;
};

export const fetchClusterDetail = async (
  clusterId: number,
): Promise<ClusterDetailResponse> => {
  const { data } = await api.get<ClusterDetailResponse>(
    `/clusters/${clusterId}`,
  );
  return data;
};

export const resolveCluster = async (payload: {
  clusterId: number;
  bestShotId: string;
  deleteOthers: boolean;
}): Promise<void> => {
  await api.post(`/clusters/${payload.clusterId}/resolve`, {
    bestShotId: payload.bestShotId,
    deleteOthers: payload.deleteOthers,
  });
};

export const rebuildClusters = async (): Promise<void> => {
  await api.post("/internal/rebuild-clusters");
};
