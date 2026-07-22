import type { ControlMessage } from "../api/controls";
import type { SimulatorFileItem } from "../api/filesMedia";
import type { SystemSurface } from "../api/types";

export interface SystemSurfaceChangedEvent {
  type: "system-surface.changed";
  systemSurface: SystemSurface | null;
  udid: string;
}

export interface SimulatorFileChangedEvent {
  type: "file.created" | "file.changed" | "file.deleted";
  item: SimulatorFileItem;
  source: "browser" | "native";
  udid: string;
}

export interface TransferProgressEvent {
  type:
    | "file.transfer-progress"
    | "media.upload-started"
    | "media.upload-progress"
    | "media.import-started"
    | "media.import-completed"
    | "media.import-failed";
  bytesTransferred: number;
  direction?: "download" | "upload";
  error?: { code: string; message?: string } | null;
  fileName: string;
  status?: "completed" | "downloading" | "failed" | "uploading";
  totalBytes?: number | null;
  transferId: string;
  udid: string;
}

export interface CameraConsumerStateEvent {
  type: "camera.consumer-state";
  activeConsumers: number;
  cameraProcessId: number;
  consumerActivityAgeMs: number | null;
  consumerRevision: number;
  framesConsumed: number;
  framesPublished: number;
  udid: string;
  webcamState: "idle" | "requested" | "streaming";
}

export type ControlServerEvent =
  | CameraConsumerStateEvent
  | SimulatorFileChangedEvent
  | SystemSurfaceChangedEvent
  | TransferProgressEvent;

export function isMoveControlMessage(message: ControlMessage): boolean {
  return (
    (message.type === "touch" || message.type === "edgeTouch") &&
    message.phase === "moved"
  );
}

export function parseControlServerEvent(
  data: unknown,
): ControlServerEvent | null {
  if (typeof data !== "string") {
    return null;
  }
  let value: unknown;
  try {
    value = JSON.parse(data);
  } catch {
    return null;
  }
  if (!isRecord(value) || typeof value.type !== "string") {
    return null;
  }
  if (typeof value.udid !== "string") {
    return null;
  }
  if (value.type === "camera.consumer-state") {
    if (
      typeof value.activeConsumers !== "number" ||
      typeof value.cameraProcessId !== "number" ||
      (value.consumerActivityAgeMs !== null &&
        typeof value.consumerActivityAgeMs !== "number") ||
      typeof value.consumerRevision !== "number" ||
      typeof value.framesConsumed !== "number" ||
      typeof value.framesPublished !== "number" ||
      (value.webcamState !== "idle" &&
        value.webcamState !== "requested" &&
        value.webcamState !== "streaming")
    ) {
      return null;
    }
    return value as unknown as CameraConsumerStateEvent;
  }
  if (
    value.type === "file.created" ||
    value.type === "file.changed" ||
    value.type === "file.deleted"
  ) {
    if (!isSimulatorFileItem(value.item)) {
      return null;
    }
    return value as unknown as SimulatorFileChangedEvent;
  }
  if (
    value.type === "file.transfer-progress" ||
    value.type === "media.upload-started" ||
    value.type === "media.upload-progress" ||
    value.type === "media.import-started" ||
    value.type === "media.import-completed" ||
    value.type === "media.import-failed"
  ) {
    if (
      typeof value.transferId !== "string" ||
      typeof value.fileName !== "string" ||
      typeof value.bytesTransferred !== "number"
    ) {
      return null;
    }
    if (
      value.type === "file.transfer-progress" &&
      value.status !== "completed" &&
      value.status !== "downloading" &&
      value.status !== "failed" &&
      value.status !== "uploading"
    ) {
      return null;
    }
    return value as unknown as TransferProgressEvent;
  }
  if (value.type !== "system-surface.changed") {
    return null;
  }
  if (value.systemSurface === null) {
    return value as unknown as SystemSurfaceChangedEvent;
  }
  if (!isRecord(value.systemSurface)) {
    return null;
  }
  const surface = value.systemSurface;
  if (
    (surface.kind !== "documentPicker" && surface.kind !== "photoPicker") ||
    typeof surface.processIdentifier !== "number" ||
    typeof surface.sessionId !== "string"
  ) {
    return null;
  }
  return value as unknown as SystemSurfaceChangedEvent;
}

function isSimulatorFileItem(value: unknown): value is SimulatorFileItem {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    typeof value.parentId === "string" &&
    typeof value.name === "string" &&
    (value.kind === "file" || value.kind === "directory") &&
    typeof value.size === "number"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
