import { describe, expect, it } from "vitest";

import { shouldWarmAccessibilityAfterFirstFrame } from "./viewerStartup";

describe("viewer startup", () => {
  it("keeps background accessibility work behind the first visual frame", () => {
    expect(
      shouldWarmAccessibilityAfterFirstFrame({
        hasFrame: false,
        hierarchyVisible: false,
        isBooted: true,
      }),
    ).toBe(false);
    expect(
      shouldWarmAccessibilityAfterFirstFrame({
        hasFrame: true,
        hierarchyVisible: false,
        isBooted: true,
      }),
    ).toBe(true);
  });

  it("loads accessibility immediately when the inspector is requested", () => {
    expect(
      shouldWarmAccessibilityAfterFirstFrame({
        hasFrame: false,
        hierarchyVisible: true,
        isBooted: true,
      }),
    ).toBe(true);
  });

  it("does not warm accessibility for a stopped simulator", () => {
    expect(
      shouldWarmAccessibilityAfterFirstFrame({
        hasFrame: true,
        hierarchyVisible: true,
        isBooted: false,
      }),
    ).toBe(false);
  });
});
