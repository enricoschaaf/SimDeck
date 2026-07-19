import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import type { SimulatorMetadata, SystemSurface } from "../../api/types";
import {
  FilesMediaPanel,
  filesMediaTabForSurface,
  shouldAutoOpenFilesMedia,
  validateMediaCandidate,
} from "./FilesMediaPanel";

const simulator = {
  isBooted: true,
  name: "Simulator 1",
  platform: "ios-simulator",
  state: "Booted",
  udid: "device-a",
} as SimulatorMetadata;

describe("FilesMediaPanel", () => {
  it("maps each native picker to the matching browser tab", () => {
    expect(filesMediaTabForSurface(surface("documentPicker", "files"))).toBe(
      "files",
    );
    expect(filesMediaTabForSurface(surface("photoPicker", "photos"))).toBe(
      "photos",
    );
  });

  it("opens once per picker session after dismissal", () => {
    const picker = surface("photoPicker", "session-a");
    expect(shouldAutoOpenFilesMedia(picker, new Set())).toBe(true);
    expect(shouldAutoOpenFilesMedia(picker, new Set(["session-a"]))).toBe(
      false,
    );
    expect(
      shouldAutoOpenFilesMedia(
        surface("photoPicker", "session-b"),
        new Set(["session-a"]),
      ),
    ).toBe(true);
  });

  it("applies active photo picker media constraints", () => {
    expect(
      validateMediaCandidate({ size: 1024, type: "image/png" }, true),
    ).toBe("");
    expect(
      validateMediaCandidate({ size: 1024, type: "video/mp4" }, true),
    ).toContain("images only");
    expect(
      validateMediaCandidate(
        { size: 10 * 1024 * 1024 + 1, type: "image/jpeg" },
        true,
      ),
    ).toContain("10 MB");
  });

  it("renders Files and Photos as one simulator-scoped panel", () => {
    const markup = renderToStaticMarkup(
      <FilesMediaPanel
        activeSurface={surface("documentPicker", "files")}
        activeTab="files"
        event={null}
        onActiveTabChange={() => undefined}
        onClose={() => undefined}
        selectedSimulator={simulator}
        visible
      />,
    );
    expect(markup).toContain("Files &amp; Media");
    expect(markup).toContain("Choose from this computer");
    expect(markup).toContain("Drop files here");
  });
});

function surface(
  kind: SystemSurface["kind"],
  sessionId: string,
): SystemSurface {
  return { kind, processIdentifier: 42, sessionId };
}
