import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const layoutCss = readFileSync(
  new URL("../styles/layout.css", import.meta.url),
  "utf8",
);
const appShellSource = readFileSync(
  new URL("./AppShell.tsx", import.meta.url),
  "utf8",
);
const toolbarSource = readFileSync(
  new URL("../features/toolbar/Toolbar.tsx", import.meta.url),
  "utf8",
);
const simulatorMenuSource = readFileSync(
  new URL("../features/simulators/SimulatorMenu.tsx", import.meta.url),
  "utf8",
);
const confirmationDialogSource = readFileSync(
  new URL("../features/simulators/ConfirmationDialog.tsx", import.meta.url),
  "utf8",
);

describe("embedded viewer layout", () => {
  it("reserves a right-side column for controls outside the viewport", () => {
    expect(layoutCss).toMatch(
      /\.app-embedded\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) 44px;/s,
    );
    expect(layoutCss).toMatch(
      /\.app-embedded \.main\s*{[^}]*grid-column:\s*1;[^}]*grid-row:\s*1;/s,
    );
    expect(layoutCss).toMatch(
      /\.app-embedded \.toolbar\s*{[^}]*grid-column:\s*2;[^}]*grid-row:\s*1;[^}]*align-self:\s*start;[^}]*margin-top:\s*12px;/s,
    );
  });

  it("uses one uninterrupted black canvas around the reserved controls", () => {
    expect(layoutCss).toMatch(
      /\.app-embedded\s*{[^}]*--canvas-bg:\s*#000000;[^}]*padding:\s*0 12px 0 0;[^}]*background:\s*var\(--canvas-bg\);/s,
    );
  });

  it("moves controls below the viewport at narrow widths", () => {
    expect(layoutCss).toMatch(
      /@media \(max-width: 520px\)[\s\S]*\.app-embedded\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\);[^}]*grid-template-rows:\s*minmax\(0, 1fr\) 44px;/,
    );
    expect(layoutCss).toMatch(
      /@media \(max-width: 520px\)[\s\S]*\.app-embedded \.toolbar\s*{[^}]*grid-column:\s*1;[^}]*grid-row:\s*2;/,
    );
  });

  it("keeps WebKit and accessibility panels inside the reserved viewport column", () => {
    expect(layoutCss).toMatch(
      /\.app-embedded \.main\s*{[^}]*grid-column:\s*1;/s,
    );
    expect(layoutCss).toContain(".webkit-panel {");
    expect(layoutCss).toContain(".hierarchy-panel {");
  });

  it("exposes Core app-data reset as an embedded sidebar action", () => {
    expect(appShellSource).toContain('get("coreAppDataReset") === "1"');
    expect(appShellSource).toContain('{ type: "simdeck:reset-app-data" }');
    expect(toolbarSource).toContain('aria-label="Clear app data"');
    expect(toolbarSource).toContain("<TrashIcon />");
    expect(toolbarSource).toContain('data-tooltip="Developer tools"');
    expect(confirmationDialogSource).toContain('role="alertdialog"');
    expect(confirmationDialogSource).toContain("autoFocus");
  });

  it("places embedded toolbar tooltips beside the controls", () => {
    expect(layoutCss).toMatch(
      /\.app-embedded \.toolbar \.tbtn\[data-tooltip\]::after\s*{[^}]*right:\s*calc\(100% \+ 10px\);[^}]*left:\s*auto;/s,
    );
  });

  it("keeps recording controls and status outside the simulator viewport", () => {
    expect(toolbarSource).toContain("recording-btn");
    expect(toolbarSource).toContain("data-tooltip={");
    expect(toolbarSource).toContain("recordingLabel");
    expect(toolbarSource).toContain("recordingElapsed");
    expect(toolbarSource).toContain("recording-status");
    expect(toolbarSource).toContain("Recording ${recordingElapsed}");
    expect(simulatorMenuSource).not.toContain("Start Recording");
    expect(simulatorMenuSource).not.toContain("Stop Recording");
    expect(appShellSource).not.toContain("recordingOverlayLabel");
  });
});
