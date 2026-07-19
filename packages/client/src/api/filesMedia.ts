import { apiHeaders, apiRequest } from "./client";
import { apiUrl } from "./config";

export interface SimulatorFileItem {
  id: string;
  parentId: string;
  name: string;
  kind: "file" | "directory";
  contentType?: string | null;
  size: number;
  createdAt: number;
  modifiedAt: number;
  version: number;
}

export interface SimulatorFilesResponse {
  udid: string;
  rootId: string;
  items: SimulatorFileItem[];
}

export interface FileMutationResponse {
  ok: boolean;
  udid: string;
  item: SimulatorFileItem;
}

export interface FileUploadResponse extends FileMutationResponse {
  transferId: string;
}

export interface MediaImportResponse {
  ok: boolean;
  udid: string;
  transferId: string;
  fileName: string;
  contentType: string;
  bytes: number;
}

export function listSimulatorFiles(
  udid: string,
  parentId?: string,
): Promise<SimulatorFilesResponse> {
  const query = parentId ? `?parentId=${encodeURIComponent(parentId)}` : "";
  return apiRequest(
    `/api/simulators/${encodeURIComponent(udid)}/files${query}`,
  );
}

export function uploadSimulatorFile(
  udid: string,
  file: File,
  parentId = "root",
): Promise<FileUploadResponse> {
  return apiRequest(
    `/api/simulators/${encodeURIComponent(udid)}/files/upload`,
    {
      body: file,
      headers: {
        "Content-Type": "application/octet-stream",
        "X-SimDeck-Content-Type": encodeURIComponent(
          file.type || "application/octet-stream",
        ),
        "X-SimDeck-Filename": encodeURIComponent(file.name || "upload"),
        "X-SimDeck-Parent-Id": encodeURIComponent(parentId),
      },
      method: "POST",
    },
  );
}

export function createSimulatorDirectory(
  udid: string,
  parentId: string,
  name: string,
): Promise<FileMutationResponse> {
  return apiRequest(
    `/api/simulators/${encodeURIComponent(udid)}/files/directories`,
    {
      body: JSON.stringify({ name, parentId }),
      method: "POST",
    },
  );
}

export function updateSimulatorFile(
  udid: string,
  id: string,
  update: { name?: string; parentId?: string },
): Promise<FileMutationResponse> {
  return apiRequest(
    `/api/simulators/${encodeURIComponent(udid)}/files/${encodeURIComponent(id)}`,
    {
      body: JSON.stringify(update),
      method: "PATCH",
    },
  );
}

export function deleteSimulatorFile(
  udid: string,
  id: string,
): Promise<{ ok: boolean; deletedIds: string[] }> {
  return apiRequest(
    `/api/simulators/${encodeURIComponent(udid)}/files/${encodeURIComponent(id)}`,
    { method: "DELETE" },
  );
}

export async function downloadSimulatorFile(
  udid: string,
  item: SimulatorFileItem,
): Promise<void> {
  const response = await fetch(
    apiUrl(
      `/api/simulators/${encodeURIComponent(udid)}/files/${encodeURIComponent(item.id)}/download`,
    ),
    { headers: apiHeaders() },
  );
  if (!response.ok) {
    const contentType = response.headers.get("content-type") ?? "";
    if (contentType.includes("application/json")) {
      const body = (await response.json()) as { error?: string };
      throw new Error(body.error ?? `Download failed (${response.status}).`);
    }
    throw new Error(
      (await response.text()) || `Download failed (${response.status}).`,
    );
  }
  const url = URL.createObjectURL(await response.blob());
  const link = document.createElement("a");
  link.href = url;
  link.download = item.name;
  link.click();
  window.setTimeout(() => URL.revokeObjectURL(url), 1_000);
}

export function importSimulatorMedia(
  udid: string,
  file: File,
): Promise<MediaImportResponse> {
  return apiRequest(`/api/simulators/${encodeURIComponent(udid)}/media`, {
    body: file,
    headers: {
      "Content-Type": "application/octet-stream",
      "X-SimDeck-Content-Type": encodeURIComponent(file.type),
      "X-SimDeck-Filename": encodeURIComponent(file.name || "media"),
    },
    method: "POST",
  });
}
