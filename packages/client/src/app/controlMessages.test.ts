import { describe, expect, it } from "vitest";

import {
  isMoveControlMessage,
  parseControlServerEvent,
} from "./controlMessages";

describe("controlMessages", () => {
  it("marks single-touch moves as coalescible", () => {
    expect(
      isMoveControlMessage({ type: "touch", x: 0.4, y: 0.5, phase: "moved" }),
    ).toBe(true);
    expect(
      isMoveControlMessage({
        type: "edgeTouch",
        x: 0.4,
        y: 0.95,
        phase: "moved",
        edge: "bottom",
      }),
    ).toBe(true);
  });

  it("does not coalesce multi-touch, gesture boundaries, or discrete controls", () => {
    expect(
      isMoveControlMessage({ type: "touch", x: 0.4, y: 0.5, phase: "began" }),
    ).toBe(false);
    expect(
      isMoveControlMessage({
        type: "multiTouch",
        x1: 0.35,
        y1: 0.5,
        x2: 0.65,
        y2: 0.5,
        phase: "moved",
      }),
    ).toBe(false);
    expect(
      isMoveControlMessage({
        type: "multiTouch",
        x1: 0.35,
        y1: 0.5,
        x2: 0.65,
        y2: 0.5,
        phase: "ended",
      }),
    ).toBe(false);
    expect(
      isMoveControlMessage({ type: "scroll", deltaX: 0, deltaY: 42 }),
    ).toBe(false);
    expect(isMoveControlMessage({ type: "home" })).toBe(false);
  });

  it("parses document surface opening and closing events", () => {
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "system-surface.changed",
          udid: "device-a",
          systemSurface: {
            kind: "documentPicker",
            processIdentifier: 123,
            sessionId: "surface-a",
          },
        }),
      ),
    ).toEqual({
      type: "system-surface.changed",
      udid: "device-a",
      systemSurface: {
        kind: "documentPicker",
        processIdentifier: 123,
        sessionId: "surface-a",
      },
    });
    const closing = parseControlServerEvent(
      JSON.stringify({
        type: "system-surface.changed",
        udid: "device-a",
        systemSurface: null,
      }),
    );
    expect(closing?.type).toBe("system-surface.changed");
    expect(
      closing?.type === "system-surface.changed"
        ? closing.systemSurface
        : undefined,
    ).toBeNull();
  });

  it("parses photo picker surface events", () => {
    const opening = parseControlServerEvent(
      JSON.stringify({
        type: "system-surface.changed",
        udid: "device-a",
        systemSurface: {
          kind: "photoPicker",
          processIdentifier: 456,
          sessionId: "surface-photo",
        },
      }),
    );
    expect(
      opening?.type === "system-surface.changed"
        ? opening.systemSurface?.kind
        : undefined,
    ).toBe("photoPicker");
  });

  it("parses file changes and media transfer evidence", () => {
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "file.created",
          udid: "device-a",
          source: "native",
          item: {
            id: "file-a",
            parentId: "root",
            name: "Décompte.pdf",
            kind: "file",
            size: 42,
            createdAt: 1,
            modifiedAt: 1,
            version: 1,
          },
        }),
      )?.type,
    ).toBe("file.created");
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "media.import-completed",
          udid: "device-a",
          transferId: "transfer-a",
          fileName: "photo.png",
          bytesTransferred: 42,
          totalBytes: 42,
        }),
      )?.type,
    ).toBe("media.import-completed");
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "file.transfer-progress",
          udid: "device-a",
          transferId: "transfer-b",
          fileName: "Décompte.pdf",
          direction: "upload",
          status: "completed",
          bytesTransferred: 42,
          totalBytes: 42,
        }),
      ),
    ).toMatchObject({ status: "completed" });
  });

  it("parses camera demand and frame metrics", () => {
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "camera.consumer-state",
          udid: "device-a",
          activeConsumers: 2,
          consumerRevision: 4,
          webcamState: "streaming",
          framesPublished: 91,
          framesConsumed: 87,
        }),
      ),
    ).toEqual({
      type: "camera.consumer-state",
      udid: "device-a",
      activeConsumers: 2,
      consumerRevision: 4,
      webcamState: "streaming",
      framesPublished: 91,
      framesConsumed: 87,
    });
  });

  it("rejects unknown and malformed server events", () => {
    expect(parseControlServerEvent("not-json")).toBeNull();
    expect(
      parseControlServerEvent(
        JSON.stringify({ type: "ready", udid: "device-a" }),
      ),
    ).toBeNull();
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "system-surface.changed",
          udid: "device-a",
          systemSurface: { kind: "documentPicker" },
        }),
      ),
    ).toBeNull();
    expect(
      parseControlServerEvent(
        JSON.stringify({
          type: "file.transfer-progress",
          udid: "device-a",
          transferId: "transfer-b",
          fileName: "file.txt",
          bytesTransferred: 42,
        }),
      ),
    ).toBeNull();
  });
});
