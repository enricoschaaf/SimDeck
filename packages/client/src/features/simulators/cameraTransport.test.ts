import { afterEach, describe, expect, it, vi } from "vitest";

import {
  cameraH264Codecs,
  cameraMaxBitrate,
  cameraVideoConstraints,
  isCameraFeedAbort,
  startCameraFeed,
  videoDevices,
} from "./cameraTransport";

afterEach(() => vi.unstubAllGlobals());

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

  it("aborts a superseded negotiation without closing its replacement", async () => {
    const peers: Array<{
      close: ReturnType<typeof vi.fn>;
      createOffer: ReturnType<typeof vi.fn>;
    }> = [];
    class FakePeerConnection {
      readonly close = vi.fn();
      readonly connectionState = "new";
      readonly controlChannel = {
        addEventListener: vi.fn(),
        close: vi.fn(),
        readyState: "connecting",
        removeEventListener: vi.fn(),
        send: vi.fn(),
      };
      readonly createOffer = vi.fn(
        () => new Promise<RTCSessionDescriptionInit>(() => undefined),
      );
      readonly sender = {
        getParameters: () => ({ encodings: [] }),
        setParameters: vi.fn().mockResolvedValue(undefined),
      };

      constructor() {
        peers.push(this);
      }

      addEventListener() {}
      addTrack() {
        return this.sender;
      }
      createDataChannel() {
        return this.controlChannel;
      }
      getTransceivers() {
        return [
          {
            sender: this.sender,
            setCodecPreferences: vi.fn(),
          },
        ];
      }
      removeEventListener() {}
    }
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({
        headers: { get: () => "application/json" },
        json: async () => ({}),
        ok: true,
        status: 200,
      }),
    );
    vi.stubGlobal("RTCPeerConnection", FakePeerConnection);
    vi.stubGlobal("RTCRtpSender", {
      getCapabilities: () => ({
        codecs: [
          {
            clockRate: 90_000,
            mimeType: "video/H264",
            sdpFmtpLine: "packetization-mode=1;profile-level-id=42e01f",
          },
        ],
      }),
    });
    const stream = {
      getVideoTracks: () => [
        {
          getSettings: () => ({
            frameRate: 30,
            height: 1_080,
            width: 1_920,
          }),
        },
      ],
    } as unknown as MediaStream;
    const firstController = new AbortController();
    const first = startCameraFeed({
      onError: vi.fn(),
      signal: firstController.signal,
      stream,
      udid: "device-a",
    });
    await vi.waitFor(() => expect(peers[0]?.createOffer).toHaveBeenCalled());

    firstController.abort();
    await expect(first).rejects.toSatisfy(isCameraFeedAbort);
    const secondController = new AbortController();
    const second = startCameraFeed({
      onError: vi.fn(),
      signal: secondController.signal,
      stream,
      udid: "device-a",
    });
    await vi.waitFor(() => expect(peers[1]?.createOffer).toHaveBeenCalled());

    expect(peers[0]?.close).toHaveBeenCalledOnce();
    expect(peers[1]?.close).not.toHaveBeenCalled();
    secondController.abort();
    await expect(second).rejects.toSatisfy(isCameraFeedAbort);
  });
});
