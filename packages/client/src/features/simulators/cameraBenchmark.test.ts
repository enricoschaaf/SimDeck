import { describe, expect, it } from "vitest";

import { cameraBenchmarkMarkerBits } from "./cameraBenchmark";

describe("camera benchmark marker", () => {
  it("encodes frame and timestamp into a fixed-width binary marker", () => {
    const bits = cameraBenchmarkMarkerBits(0xa55a, 0x12345678);

    expect(bits).toHaveLength(48);
    expect(bits.slice(0, 16)).toEqual(
      [..."1010010101011010"].map((value) => value === "1"),
    );
    expect(bits.slice(16)).toEqual(
      [..."00010010001101000101011001111000"].map((value) => value === "1"),
    );
  });
});
