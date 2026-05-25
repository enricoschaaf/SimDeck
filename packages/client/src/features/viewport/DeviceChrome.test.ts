import { describe, expect, it } from "vitest";

import type { ChromeButtonProfile } from "../../api/types";
import { chromeButtonMotionVariables } from "./DeviceChrome";

describe("chromeButtonMotionVariables", () => {
  it("rests halfway inward, hovers at the original button position, and presses farther inward", () => {
    const button: ChromeButtonProfile = {
      name: "side-button",
      x: 100,
      y: 20,
      width: 10,
      height: 20,
      normalOffset: { x: 0, y: 0 },
      rolloverOffset: { x: 4, y: -2 },
    };

    expect(chromeButtonMotionVariables(button)).toEqual({
      "--button-rest-x": "-20%",
      "--button-rest-y": "5%",
      "--button-hover-x": "0%",
      "--button-hover-y": "0%",
      "--button-pressed-x": "-34%",
      "--button-pressed-y": "8.5%",
    });
  });

  it("keeps buttons without a rollover offset stationary", () => {
    const button: ChromeButtonProfile = {
      name: "home",
      x: 0,
      y: 0,
      width: 44,
      height: 44,
    };

    expect(chromeButtonMotionVariables(button)).toEqual({
      "--button-rest-x": "0%",
      "--button-rest-y": "0%",
      "--button-hover-x": "0%",
      "--button-hover-y": "0%",
      "--button-pressed-x": "0%",
      "--button-pressed-y": "0%",
    });
  });
});
