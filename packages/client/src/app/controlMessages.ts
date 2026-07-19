import type { ControlMessage } from "../api/controls";
import type { SystemSurface } from "../api/types";

export interface SystemSurfaceChangedEvent {
  type: "system-surface.changed";
  systemSurface: SystemSurface | null;
  udid: string;
}

export function isMoveControlMessage(message: ControlMessage): boolean {
  return (
    (message.type === "touch" || message.type === "edgeTouch") &&
    message.phase === "moved"
  );
}

export function parseControlServerEvent(
  data: unknown,
): SystemSurfaceChangedEvent | null {
  if (typeof data !== "string") {
    return null;
  }
  let value: unknown;
  try {
    value = JSON.parse(data);
  } catch {
    return null;
  }
  if (!isRecord(value) || value.type !== "system-surface.changed") {
    return null;
  }
  if (typeof value.udid !== "string") {
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
    surface.kind !== "documentPicker" ||
    typeof surface.processIdentifier !== "number" ||
    typeof surface.sessionId !== "string"
  ) {
    return null;
  }
  return value as unknown as SystemSurfaceChangedEvent;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
