import { describe, expect, it } from "vitest";

import type { DeepLinkDefinition } from "../../api/types";
import {
  deepLinkPlaceholders,
  filterDeepLinks,
  groupedDeepLinks,
  resolveDeepLink,
} from "./deepLinks";

const links: DeepLinkDefinition[] = [
  {
    group: "Home",
    title: "Home",
    url: "demo://home",
    requiresAuthentication: false,
  },
  {
    group: "Cards",
    title: "Card details",
    url: "demo://card/{id}",
    requiresAuthentication: true,
    parameters: [{ name: "id", default: "card-1" }],
  },
];

describe("deep links", () => {
  it("extracts unique placeholders in order", () => {
    expect(deepLinkPlaceholders("demo://{id}/{kind}/{id}")).toEqual([
      "id",
      "kind",
    ]);
  });

  it("resolves and URL-encodes parameter values", () => {
    expect(resolveDeepLink(links[1]!, { id: "card / 42" })).toBe(
      "demo://card/card%20%2F%2042",
    );
  });

  it("uses defaults and rejects missing parameters", () => {
    expect(resolveDeepLink(links[1]!, {})).toBe("demo://card/card-1");
    expect(
      resolveDeepLink({ ...links[1]!, parameters: undefined }, {}),
    ).toBeNull();
  });

  it("searches titles, groups, descriptions, and URLs", () => {
    expect(filterDeepLinks(links, "CARD")).toEqual([links[1]]);
    expect(filterDeepLinks(links, "demo://home")).toEqual([links[0]]);
  });

  it("separates public and authenticated groups", () => {
    const sections = groupedDeepLinks(links);
    expect(sections.map((section) => section.label)).toEqual([
      "Available without authentication",
      "Requires authentication",
    ]);
    expect(sections[1]?.groups[0]?.[0]).toBe("Cards");
  });
});
