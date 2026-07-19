import { describe, expect, it } from "vitest";

import {
  buildStreamTarget,
  initialIceGatheringTimeoutMs,
  initialStreamBackend,
  preferredStreamBackend,
} from "./streamWorkerClient";

describe("streamWorkerClient", () => {
  it("ignores removed legacy stream transport preferences", () => {
    const target = buildStreamTarget("android:emulator-5554", {
      platform: "android-emulator",
      transport: "h264" as never,
    });

    expect(preferredStreamBackend(target)).toBe("auto");
  });

  it("uses the common WebRTC preference for Android emulator streams", () => {
    const target = buildStreamTarget("android:Pixel_8", {
      transport: "webrtc",
    });

    expect(preferredStreamBackend(target)).toBe("webrtc");
  });

  it("ignores unknown stream query parameters", () => {
    const previousWindow = globalThis.window;
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: { location: { search: "?stream=unknown" } },
    });

    try {
      expect(preferredStreamBackend(buildStreamTarget("android:Pixel_8"))).toBe(
        "auto",
      );
    } finally {
      Object.defineProperty(globalThis, "window", {
        configurable: true,
        value: previousWindow,
      });
    }
  });

  it("defaults Android auto streams to WebRTC when the browser supports it", () => {
    const previousPeerConnection = globalThis.RTCPeerConnection;
    (
      globalThis as unknown as { RTCPeerConnection: unknown }
    ).RTCPeerConnection = function RTCPeerConnection() {};
    const target = buildStreamTarget("android:Pixel_8", {
      transport: "auto",
    });

    try {
      expect(preferredStreamBackend(target)).toBe("auto");
      expect(initialStreamBackend(target)).toBe("webrtc");
    } finally {
      (
        globalThis as unknown as { RTCPeerConnection: unknown }
      ).RTCPeerConnection = previousPeerConnection;
    }
  });

  it("offers quickly when Tailscale host candidates are directly reachable", () => {
    expect(
      initialIceGatheringTimeoutMs(true, "ios-simulators.tailnet-19c2.ts.net"),
    ).toBe(250);
    expect(initialIceGatheringTimeoutMs(true, "simdeck.example.com")).toBe(
      3000,
    );
    expect(initialIceGatheringTimeoutMs(false, "localhost")).toBe(250);
  });
});
