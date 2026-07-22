import { useCallback, useEffect, useRef, useState } from "react";

import type { CameraConsumerStateEvent } from "../../app/controlMessages";
import {
  cameraVideoConstraints,
  isCameraFeedAbort,
  startCameraFeed,
  videoDevices,
  type CameraDevice,
  type CameraFeed,
  type CameraStats,
} from "./cameraTransport";

const CAMERA_DEVICE_STORAGE_KEY = "simdeck.camera.deviceId";
export const CAMERA_IDLE_GRACE_MS = 60_000;

export type AutomaticCameraPhase =
  | "idle"
  | "waiting"
  | "requesting"
  | "streaming"
  | "blocked"
  | "error";

export interface AutomaticCamera {
  activeConsumers: number;
  cameraId: string;
  cameras: CameraDevice[];
  error: string;
  framesConsumed: number;
  framesPublished: number;
  phase: AutomaticCameraPhase;
  retry(): void;
  selectCamera(cameraId: string): void;
  stats: CameraStats | null;
}

type CameraPermissionState = PermissionState | "unsupported";

export type CameraLifecycleAction =
  | "none"
  | "start"
  | "defer-stop"
  | "wait"
  | "blocked";

export function cameraDemandCount(
  activeConsumers: number,
  consumerActivityAgeMs: number | null,
): number {
  if (activeConsumers > 0) {
    return activeConsumers;
  }
  return consumerActivityAgeMs !== null &&
    consumerActivityAgeMs < CAMERA_IDLE_GRACE_MS
    ? 1
    : 0;
}

export function cameraGraceRemainingMs(
  consumerActivityAgeMs: number | null,
): number {
  return Math.max(
    0,
    CAMERA_IDLE_GRACE_MS - (consumerActivityAgeMs ?? CAMERA_IDLE_GRACE_MS),
  );
}

export function cameraLifecycleAction(
  previousConsumers: number | null,
  activeConsumers: number,
  permission: CameraPermissionState,
): CameraLifecycleAction {
  if (activeConsumers === 0) {
    return previousConsumers && previousConsumers > 0 ? "defer-stop" : "none";
  }
  if (previousConsumers === null) {
    return permission === "granted" ? "start" : "wait";
  }
  if (previousConsumers === 0) {
    return permission === "denied" ? "blocked" : "start";
  }
  return "none";
}

export function shouldReconnectCameraFeed(
  previousConsumers: number | null,
  activeConsumers: number,
  previousCameraProcessId: number | null,
  cameraProcessId: number,
): boolean {
  return (
    activeConsumers > 0 &&
    previousConsumers !== null &&
    previousCameraProcessId !== null &&
    previousCameraProcessId !== cameraProcessId
  );
}

export function useAutomaticCamera({
  consumerState,
  enabled,
  udid,
}: {
  consumerState: CameraConsumerStateEvent | null;
  enabled: boolean;
  udid: string;
}): AutomaticCamera {
  const [cameraId, setCameraId] = useState(readStoredCameraId);
  const [cameras, setCameras] = useState<CameraDevice[]>([]);
  const [error, setError] = useState("");
  const [phase, setPhase] = useState<AutomaticCameraPhase>("idle");
  const [stats, setStats] = useState<CameraStats | null>(null);
  const feedRef = useRef<CameraFeed | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const consumerCountRef = useRef<number | null>(null);
  const cameraProcessIdRef = useRef<number | null>(null);
  const activeConsumerCountRef = useRef(0);
  const cameraDemandedRef = useRef(false);
  const cameraStartingRef = useRef(false);
  const setupAbortRef = useRef<AbortController | null>(null);
  const stopTimerRef = useRef<number | null>(null);
  const requestGenerationRef = useRef(0);
  const selectedUdidRef = useRef(udid);

  const stopLocalCamera = useCallback(() => {
    if (stopTimerRef.current !== null) {
      window.clearTimeout(stopTimerRef.current);
      stopTimerRef.current = null;
    }
    cameraDemandedRef.current = false;
    cameraStartingRef.current = false;
    setupAbortRef.current?.abort();
    setupAbortRef.current = null;
    requestGenerationRef.current += 1;
    feedRef.current?.stop();
    feedRef.current = null;
    for (const track of streamRef.current?.getTracks() ?? []) {
      track.stop();
    }
    streamRef.current = null;
    setStats(null);
  }, []);

  const scheduleLocalCameraStop = useCallback(
    (delayMs = CAMERA_IDLE_GRACE_MS) => {
      if (stopTimerRef.current !== null) {
        window.clearTimeout(stopTimerRef.current);
      }
      stopTimerRef.current = window.setTimeout(() => {
        stopTimerRef.current = null;
        stopLocalCamera();
        setError("");
        setPhase("idle");
      }, delayMs);
    },
    [stopLocalCamera],
  );

  const retainLocalCamera = useCallback(() => {
    if (stopTimerRef.current !== null) {
      window.clearTimeout(stopTimerRef.current);
      stopTimerRef.current = null;
    }
    cameraDemandedRef.current = true;
  }, []);

  const refreshDevices = useCallback(async () => {
    if (!navigator.mediaDevices?.enumerateDevices) {
      setCameras([]);
      return;
    }
    const devices = videoDevices(
      await navigator.mediaDevices.enumerateDevices(),
    );
    setCameras(devices);
  }, []);

  const startLocalCamera = useCallback(
    async (allowPermissionPrompt: boolean) => {
      if (
        !enabled ||
        !udid ||
        !cameraDemandedRef.current ||
        cameraStartingRef.current ||
        feedRef.current
      ) {
        return;
      }
      cameraStartingRef.current = true;
      const setupAbort = new AbortController();
      setupAbortRef.current = setupAbort;
      const releaseSetup = () => {
        if (setupAbortRef.current === setupAbort) {
          setupAbortRef.current = null;
        }
      };
      const generation = ++requestGenerationRef.current;
      setError("");

      const permission = await queryCameraPermission();
      if (
        requestGenerationRef.current !== generation ||
        setupAbort.signal.aborted
      ) {
        return;
      }
      if (!allowPermissionPrompt && permission !== "granted") {
        cameraStartingRef.current = false;
        releaseSetup();
        setPhase("waiting");
        return;
      }
      if (permission === "denied") {
        cameraStartingRef.current = false;
        releaseSetup();
        setPhase("blocked");
        setError(cameraRecoveryMessage());
        return;
      }

      setPhase("requesting");
      let stream: MediaStream | null = null;
      try {
        if (!navigator.mediaDevices?.getUserMedia) {
          throw new Error("This browser does not support camera capture.");
        }
        stream = await navigator.mediaDevices.getUserMedia({
          video: cameraVideoConstraints(cameraId),
        });
        if (
          requestGenerationRef.current !== generation ||
          !cameraDemandedRef.current ||
          selectedUdidRef.current !== udid
        ) {
          cameraStartingRef.current = false;
          releaseSetup();
          stopStream(stream);
          return;
        }
        streamRef.current = stream;
        await refreshDevices();
        const feed = await startCameraFeed({
          onError: (message) => {
            setError(message);
            setPhase("error");
          },
          onStats: setStats,
          signal: setupAbort.signal,
          stream,
          udid,
        });
        if (
          requestGenerationRef.current !== generation ||
          !cameraDemandedRef.current ||
          selectedUdidRef.current !== udid
        ) {
          cameraStartingRef.current = false;
          releaseSetup();
          feed.stop();
          stopStream(stream);
          return;
        }
        cameraStartingRef.current = false;
        releaseSetup();
        feedRef.current = feed;
        setPhase("streaming");
      } catch (cameraError) {
        if (stream) {
          stopStream(stream);
        }
        if (requestGenerationRef.current !== generation) {
          return;
        }
        cameraStartingRef.current = false;
        releaseSetup();
        if (isCameraFeedAbort(cameraError)) {
          return;
        }
        const denied = isCameraPermissionError(cameraError);
        setPhase(denied ? "blocked" : "error");
        setError(
          denied
            ? cameraRecoveryMessage()
            : cameraError instanceof Error
              ? cameraError.message
              : "Unable to connect the browser camera.",
        );
      }
    },
    [cameraId, enabled, refreshDevices, udid],
  );

  useEffect(() => {
    if (selectedUdidRef.current === udid) {
      return;
    }
    stopLocalCamera();
    selectedUdidRef.current = udid;
    consumerCountRef.current = null;
    cameraProcessIdRef.current = null;
    activeConsumerCountRef.current = 0;
    setError("");
    setPhase("idle");
  }, [stopLocalCamera, udid]);

  useEffect(() => {
    const activeConsumers =
      enabled && consumerState?.udid === udid
        ? consumerState.activeConsumers
        : 0;
    const consumerActivityAgeMs =
      enabled && consumerState?.udid === udid
        ? consumerState.consumerActivityAgeMs
        : null;
    const nextCount = cameraDemandCount(activeConsumers, consumerActivityAgeMs);
    const nextCameraProcessId =
      enabled && consumerState?.udid === udid
        ? consumerState.cameraProcessId
        : 0;
    const previousCount = consumerCountRef.current;
    const previousCameraProcessId = cameraProcessIdRef.current;
    consumerCountRef.current = nextCount;
    cameraProcessIdRef.current = nextCameraProcessId;
    activeConsumerCountRef.current = nextCount;

    if (nextCount === 0) {
      if (previousCount !== null && previousCount > 0) {
        scheduleLocalCameraStop();
      }
      return;
    }
    retainLocalCamera();
    if (activeConsumers === 0) {
      scheduleLocalCameraStop(cameraGraceRemainingMs(consumerActivityAgeMs));
    }
    if (previousCount === null) {
      void startLocalCamera(false);
      return;
    }
    if (previousCount === 0) {
      void startLocalCamera(true);
      return;
    }
    if (
      shouldReconnectCameraFeed(
        previousCount,
        nextCount,
        previousCameraProcessId,
        nextCameraProcessId,
      )
    ) {
      stopLocalCamera();
      retainLocalCamera();
      void startLocalCamera(true);
    }
  }, [
    consumerState?.activeConsumers,
    consumerState?.cameraProcessId,
    consumerState?.consumerActivityAgeMs,
    consumerState?.consumerRevision,
    consumerState?.udid,
    enabled,
    retainLocalCamera,
    scheduleLocalCameraStop,
    startLocalCamera,
    stopLocalCamera,
    udid,
  ]);

  useEffect(() => stopLocalCamera, [stopLocalCamera]);

  const retry = useCallback(() => {
    stopLocalCamera();
    retainLocalCamera();
    void startLocalCamera(true);
  }, [retainLocalCamera, startLocalCamera, stopLocalCamera]);

  const selectCamera = useCallback(
    (nextCameraId: string) => {
      setCameraId(nextCameraId);
      storeCameraId(nextCameraId);
      if (activeConsumerCountRef.current > 0) {
        stopLocalCamera();
        retainLocalCamera();
        setPhase("idle");
      }
    },
    [retainLocalCamera, stopLocalCamera],
  );

  useEffect(() => {
    if (
      activeConsumerCountRef.current > 0 &&
      !feedRef.current &&
      phase === "idle"
    ) {
      void startLocalCamera(false);
    }
  }, [cameraId, phase, startLocalCamera]);

  return {
    activeConsumers: consumerState?.activeConsumers ?? 0,
    cameraId,
    cameras,
    error,
    framesConsumed: consumerState?.framesConsumed ?? 0,
    framesPublished: consumerState?.framesPublished ?? 0,
    phase,
    retry,
    selectCamera,
    stats,
  };
}

export async function queryCameraPermission(
  permissions: Pick<Permissions, "query"> | undefined = navigator.permissions,
): Promise<CameraPermissionState> {
  if (!permissions?.query) {
    return "unsupported";
  }
  try {
    const result = await permissions.query({
      name: "camera" as PermissionName,
    });
    return result.state;
  } catch {
    return "unsupported";
  }
}

export function cameraPolicyAllowsCapture(
  documentValue: Document = document,
): boolean {
  const policyDocument = documentValue as Document & {
    featurePolicy?: { allowsFeature(name: string): boolean };
    permissionsPolicy?: { allowsFeature(name: string): boolean };
  };
  const policy =
    policyDocument.permissionsPolicy ?? policyDocument.featurePolicy;
  return policy?.allowsFeature("camera") ?? true;
}

function cameraRecoveryMessage(): string {
  return cameraPolicyAllowsCapture()
    ? "Camera access is blocked. Allow camera access for this site, then reconnect."
    : "Camera access is blocked by the embedding page. Allow camera access on the simulator iframe, then reconnect.";
}

function isCameraPermissionError(error: unknown): boolean {
  return (
    error instanceof DOMException &&
    (error.name === "NotAllowedError" || error.name === "SecurityError")
  );
}

function readStoredCameraId(): string {
  try {
    return window.localStorage.getItem(CAMERA_DEVICE_STORAGE_KEY) ?? "";
  } catch {
    return "";
  }
}

function storeCameraId(cameraId: string) {
  try {
    window.localStorage.setItem(CAMERA_DEVICE_STORAGE_KEY, cameraId);
  } catch {
    return;
  }
}

function stopStream(stream: MediaStream) {
  for (const track of stream.getTracks()) {
    track.stop();
  }
}
