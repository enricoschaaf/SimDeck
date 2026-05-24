import { describe, expect, it } from "vitest";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import {
  AccessibilityOverlay,
  accessibilityDomTagName,
} from "./AccessibilityOverlay";

describe("accessibilityDomTagName", () => {
  it("uses source and component names for annotator-friendly custom tags", () => {
    expect(
      accessibilityDomTagName({
        source: "nativescript",
        type: "TabItem",
      }),
    ).toBe("simdeck-tab-item");
    expect(
      accessibilityDomTagName({
        source: "nativescript",
        type: "Label",
      }),
    ).toBe("simdeck-label");
    expect(
      accessibilityDomTagName({
        source: "react-native",
        type: "RangeAndFilterBar",
      }),
    ).toBe("simdeck-range-and-filter-bar");
  });
});

describe("AccessibilityOverlay", () => {
  it("does not attach browser-native hover tooltips to selection nodes", () => {
    const markup = renderToStaticMarkup(
      createElement(AccessibilityOverlay, {
        hoveredId: null,
        roots: [
          {
            frame: { height: 844, width: 390, x: 0, y: 0 },
            role: "application",
            children: [
              {
                AXLabel: "Continue",
                frame: { height: 48, width: 180, x: 105, y: 720 },
                type: "Button",
              },
            ],
          },
        ],
        selectedId: "",
      }),
    );

    expect(markup).toContain('aria-label="SimDeck accessibility element');
    expect(markup).not.toContain(" title=");
  });
});
