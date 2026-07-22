import { describe, expect, it, vi } from "vitest";

import {
  CAMERA_IDLE_GRACE_MS,
  cameraDemandCount,
  cameraGraceRemainingMs,
  cameraLifecycleAction,
  cameraPolicyAllowsCapture,
  queryCameraPermission,
  shouldReconnectCameraFeed,
} from "./automaticCamera";

describe("automatic camera lifecycle", () => {
  it("keeps the webcam alive across a WebKit pre-check handoff", () => {
    expect(CAMERA_IDLE_GRACE_MS).toBeGreaterThanOrEqual(60_000);
  });

  it("recovers camera demand when a short WebKit consumer is missed between polls", () => {
    expect(cameraDemandCount(0, 125)).toBe(1);
    expect(cameraGraceRemainingMs(125)).toBe(CAMERA_IDLE_GRACE_MS - 125);
    expect(cameraDemandCount(0, CAMERA_IDLE_GRACE_MS)).toBe(0);
    expect(cameraDemandCount(1, null)).toBe(1);
  });

  it("does not prompt after reload unless camera permission is already granted", () => {
    expect(cameraLifecycleAction(null, 0, "granted")).toBe("none");
    expect(cameraLifecycleAction(null, 1, "granted")).toBe("start");
    expect(cameraLifecycleAction(null, 1, "prompt")).toBe("wait");
    expect(cameraLifecycleAction(null, 1, "unsupported")).toBe("wait");
  });

  it("starts on first demand and stops only after the final consumer", () => {
    expect(cameraLifecycleAction(0, 1, "prompt")).toBe("start");
    expect(cameraLifecycleAction(1, 2, "granted")).toBe("none");
    expect(cameraLifecycleAction(2, 1, "granted")).toBe("none");
    expect(cameraLifecycleAction(1, 0, "granted")).toBe("defer-stop");
  });

  it("reports denied permission without trying capture again", () => {
    expect(cameraLifecycleAction(0, 1, "denied")).toBe("blocked");
  });

  it("keeps the feed across consumer churn and reconnects after a camera service restart", () => {
    expect(shouldReconnectCameraFeed(1, 1, 812, 812)).toBe(false);
    expect(shouldReconnectCameraFeed(1, 2, 812, 812)).toBe(false);
    expect(shouldReconnectCameraFeed(1, 1, 812, 913)).toBe(true);
    expect(shouldReconnectCameraFeed(null, 1, null, 913)).toBe(false);
  });
});

describe("browser camera permission integration", () => {
  it("reads the browser camera permission when supported", async () => {
    const query = vi.fn().mockResolvedValue({ state: "granted" });
    await expect(queryCameraPermission({ query })).resolves.toBe("granted");
    expect(query).toHaveBeenCalledWith({ name: "camera" });
  });

  it("treats unsupported permission queries as unknown", async () => {
    const query = vi.fn().mockRejectedValue(new TypeError("unsupported"));
    await expect(queryCameraPermission({ query })).resolves.toBe("unsupported");
    await expect(queryCameraPermission(undefined)).resolves.toBe("unsupported");
  });

  it("detects a cross-origin Permissions Policy block", () => {
    const blocked = {
      permissionsPolicy: { allowsFeature: () => false },
    } as unknown as Document;
    const allowed = {
      permissionsPolicy: { allowsFeature: () => true },
    } as unknown as Document;
    expect(cameraPolicyAllowsCapture(blocked)).toBe(false);
    expect(cameraPolicyAllowsCapture(allowed)).toBe(true);
  });
});
