import { describe, expect, it } from "vitest";

import {
  cameraH264Codecs,
  cameraMaxBitrate,
  cameraVideoConstraints,
  isCameraFeedAbort,
  videoDevices,
} from "./cameraTransport";

describe("camera", () => {
  it("requests a high-resolution native camera mode", () => {
    expect(cameraVideoConstraints("front-camera")).toEqual({
      deviceId: { exact: "front-camera" },
      frameRate: { ideal: 30, max: 30 },
      height: { ideal: 1080 },
      width: { ideal: 1920 },
    });
  });

  it("names cameras after permission reveals their labels", () => {
    expect(
      videoDevices([
        { deviceId: "audio", kind: "audioinput", label: "Mic" },
        { deviceId: "one", kind: "videoinput", label: "FaceTime Camera" },
        { deviceId: "two", kind: "videoinput", label: "" },
      ]),
    ).toEqual([
      { id: "one", name: "FaceTime Camera" },
      { id: "two", name: "Camera 2" },
    ]);
  });

  it("keeps only packetization-mode 1 H.264 and prefers efficient profiles", () => {
    const codecs = cameraH264Codecs([
      {
        clockRate: 90_000,
        mimeType: "video/VP8",
      },
      {
        clockRate: 90_000,
        mimeType: "video/H264",
        sdpFmtpLine: "packetization-mode=0;profile-level-id=42e01f",
      },
      {
        clockRate: 90_000,
        mimeType: "video/H264",
        sdpFmtpLine: "packetization-mode=1;profile-level-id=640c1f",
      },
      {
        clockRate: 90_000,
        mimeType: "video/H264",
        sdpFmtpLine: "packetization-mode=1;profile-level-id=42e01f",
      },
    ]);

    expect(codecs).toHaveLength(2);
    expect(codecs[0]?.sdpFmtpLine).toContain("profile-level-id=64");
    expect(codecs[1]?.sdpFmtpLine).toContain("profile-level-id=42");
  });

  it("allocates enough bitrate for noisy full-HD camera frames", () => {
    expect(cameraMaxBitrate(640, 480)).toBe(4_000_000);
    expect(cameraMaxBitrate(1_920, 1_080)).toBe(16_588_800);
    expect(cameraMaxBitrate(3_840, 2_160)).toBe(20_000_000);
  });

  it("recognizes an aborted camera negotiation", () => {
    expect(isCameraFeedAbort(new DOMException("cancelled", "AbortError"))).toBe(
      true,
    );
    expect(isCameraFeedAbort(new Error("failed"))).toBe(false);
  });
});
