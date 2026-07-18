import type { DeepLinkDefinition, DeepLinkParameter } from "../../api/types";

export function deepLinkPlaceholders(url: string): string[] {
  return [
    ...new Set(
      [...url.matchAll(/\{([^{}]+)\}/g)].map((match) => match[1] ?? ""),
    ),
  ].filter(Boolean);
}

export function deepLinkParameters(
  link: DeepLinkDefinition,
): DeepLinkParameter[] {
  const configured = new Map(
    link.parameters?.map((parameter) => [parameter.name, parameter]),
  );
  return deepLinkPlaceholders(link.url).map(
    (name) => configured.get(name) ?? { name },
  );
}

export function resolveDeepLink(
  link: DeepLinkDefinition,
  values: Record<string, string>,
): string | null {
  const parameters = deepLinkParameters(link);
  const resolved = Object.fromEntries(
    parameters.map((parameter) => [
      parameter.name,
      values[parameter.name]?.trim() || parameter.default?.trim() || "",
    ]),
  );
  if (parameters.some((parameter) => !resolved[parameter.name])) {
    return null;
  }
  return link.url.replace(/\{([^{}]+)\}/g, (_placeholder, name: string) =>
    encodeURIComponent(resolved[name] ?? ""),
  );
}

export function filterDeepLinks(
  links: DeepLinkDefinition[],
  query: string,
): DeepLinkDefinition[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) {
    return links;
  }
  return links.filter((link) =>
    [link.title, link.group, link.description, link.url].some((value) =>
      value?.toLocaleLowerCase().includes(needle),
    ),
  );
}

export function groupedDeepLinks(links: DeepLinkDefinition[]): Array<{
  label: string;
  groups: Array<[string, DeepLinkDefinition[]]>;
}> {
  return [
    { label: "Available without authentication", authenticated: false },
    { label: "Requires authentication", authenticated: true },
  ].flatMap(({ label, authenticated }) => {
    const groups = new Map<string, DeepLinkDefinition[]>();
    for (const link of links) {
      if (link.requiresAuthentication !== authenticated) {
        continue;
      }
      const entries = groups.get(link.group) ?? [];
      entries.push(link);
      groups.set(link.group, entries);
    }
    return groups.size > 0 ? [{ label, groups: [...groups.entries()] }] : [];
  });
}
