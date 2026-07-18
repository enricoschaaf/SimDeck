import { describe, expect, it } from "vitest";

import {
  cameraCanEncodeDirectly,
  cameraFrameLayout,
  cameraH264ConfigPacket,
  cameraH264FramePacket,
  cameraShouldEncodeKeyFrame,
  cameraVideoConstraints,
  videoDevices,
} from "./cameraTransport";

describe("camera", () => {
  it("keeps a 4:3 identity camera at native resolution", () => {
    const layout = cameraFrameLayout(960, 720);
    expect(layout).toEqual({
      sourceX: 0,
      sourceY: 0,
      sourceWidth: 960,
      sourceHeight: 720,
      outputWidth: 960,
      outputHeight: 720,
    });
    expect(cameraCanEncodeDirectly(layout)).toBe(true);
  });

  it("center-crops a wide camera without upscaling", () => {
    expect(cameraFrameLayout(1280, 720)).toEqual({
      sourceX: 160,
      sourceY: 0,
      sourceWidth: 960,
      sourceHeight: 720,
      outputWidth: 960,
      outputHeight: 720,
    });
  });

  it("requests the selected camera at 30 fps", () => {
    expect(cameraVideoConstraints("front-camera")).toMatchObject({
      deviceId: { exact: "front-camera" },
      width: { ideal: 960 },
      height: { ideal: 720 },
      frameRate: { ideal: 30, max: 30 },
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

  it("encodes configuration and sequenced frame packets", () => {
    expect([
      ...new Uint8Array(cameraH264ConfigPacket(new Uint8Array([1, 2]))),
    ]).toEqual([1, 1, 2]);
    const packet = new Uint8Array(
      cameraH264FramePacket(
        {
          byteLength: 3,
          type: "key",
          copyTo(destination) {
            const view = ArrayBuffer.isView(destination)
              ? new Uint8Array(
                  destination.buffer,
                  destination.byteOffset,
                  destination.byteLength,
                )
              : new Uint8Array(destination);
            view.set([7, 8, 9]);
          },
        },
        0x01020304,
      ),
    );
    expect([...packet]).toEqual([2, 1, 1, 2, 3, 4, 7, 8, 9]);
  });

  it("starts with a keyframe and refreshes it every five seconds", () => {
    expect(cameraShouldEncodeKeyFrame(1, true)).toBe(true);
    expect(cameraShouldEncodeKeyFrame(1, false)).toBe(false);
    expect(cameraShouldEncodeKeyFrame(150, false)).toBe(true);
  });
});
