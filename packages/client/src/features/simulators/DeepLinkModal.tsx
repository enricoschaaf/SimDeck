import { useEffect, useMemo, useState } from "react";

import { fetchDeepLinkInventory } from "../../api/simulators";
import type {
  DeepLinkDefinition,
  DeepLinkManifest,
  DeepLinkParameter,
  SimulatorMetadata,
} from "../../api/types";
import {
  deepLinkParameters,
  filterDeepLinks,
  groupedDeepLinks,
  resolveDeepLink,
} from "./deepLinks";
import { DialogHeader } from "./DialogHeader";

interface DeepLinkModalProps {
  onClose: () => void;
  onOpen: (url: string) => Promise<unknown>;
  open: boolean;
  selectedSimulator: SimulatorMetadata | null;
}

function parameterLabel(parameter: DeepLinkParameter): string {
  return parameter.label ?? parameter.name.replaceAll(/[-_]/g, " ");
}

export function DeepLinkModal({
  onClose,
  onOpen,
  open,
  selectedSimulator,
}: DeepLinkModalProps) {
  const [manifest, setManifest] = useState<DeepLinkManifest | null>(null);
  const [query, setQuery] = useState("");
  const [customUrl, setCustomUrl] = useState("");
  const [parameters, setParameters] = useState<
    Record<string, Record<string, string>>
  >({});
  const [opening, setOpening] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    if (!open) {
      return;
    }
    let cancelled = false;
    setError("");
    void fetchDeepLinkInventory()
      .then((inventory) => {
        if (cancelled) {
          return;
        }
        setManifest(inventory);
        setCustomUrl((current) => current || `${inventory.scheme}://`);
      })
      .catch((loadError) => {
        if (!cancelled) {
          setError(
            loadError instanceof Error
              ? loadError.message
              : "Unable to load deep links.",
          );
        }
      });
    return () => {
      cancelled = true;
    };
  }, [open]);

  useEffect(() => {
    if (!open) {
      return;
    }
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") {
        onClose();
      }
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose, open]);

  const sections = useMemo(
    () => groupedDeepLinks(filterDeepLinks(manifest?.links ?? [], query)),
    [manifest?.links, query],
  );

  if (!open) {
    return null;
  }

  async function openUrl(url: string, key: string) {
    if (!selectedSimulator?.isBooted || opening) {
      return;
    }
    setOpening(key);
    setError("");
    try {
      await onOpen(url);
    } catch (openError) {
      setError(
        openError instanceof Error
          ? openError.message
          : "Unable to open deep link.",
      );
    } finally {
      setOpening("");
    }
  }

  function renderLink(link: DeepLinkDefinition) {
    const key = `${link.group}:${link.url}`;
    const definitions = deepLinkParameters(link);
    const values = parameters[key] ?? {};
    const resolved = resolveDeepLink(link, values);
    return (
      <article className="deep-link-card" key={key}>
        <div className="deep-link-card-heading">
          <div>
            <h4>{link.title}</h4>
            <code>{link.url}</code>
          </div>
          <button
            className="deep-link-open"
            disabled={!resolved || Boolean(opening)}
            onClick={() => resolved && void openUrl(resolved, key)}
            type="button"
          >
            {opening === key ? "Opening…" : "Open"}
          </button>
        </div>
        {link.description ? <p>{link.description}</p> : null}
        {definitions.length > 0 ? (
          <div className="deep-link-parameters">
            {definitions.map((parameter) => (
              <label key={parameter.name}>
                <span>{parameterLabel(parameter)}</span>
                <input
                  autoCapitalize="none"
                  autoCorrect="off"
                  onChange={(event) =>
                    setParameters((current) => ({
                      ...current,
                      [key]: {
                        ...current[key],
                        [parameter.name]: event.currentTarget.value,
                      },
                    }))
                  }
                  placeholder={parameter.placeholder ?? parameter.name}
                  value={values[parameter.name] ?? parameter.default ?? ""}
                />
              </label>
            ))}
          </div>
        ) : null}
      </article>
    );
  }

  return (
    <div
      className="new-sim-overlay"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <section
        aria-labelledby="deep-link-title"
        aria-modal="true"
        className="new-sim-window deep-link-window"
        role="dialog"
      >
        <DialogHeader id="deep-link-title" onClose={onClose}>
          Deep Links{manifest ? ` · ${manifest.links.length}` : ""}
        </DialogHeader>
        <div className="deep-link-tools">
          <input
            aria-label="Search deep links"
            autoFocus
            onChange={(event) => setQuery(event.currentTarget.value)}
            placeholder="Search titles, groups, and routes"
            type="search"
            value={query}
          />
          <div className="deep-link-custom">
            <input
              aria-label="Custom URL"
              autoCapitalize="none"
              autoCorrect="off"
              onChange={(event) => setCustomUrl(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && customUrl.trim()) {
                  void openUrl(customUrl.trim(), "custom");
                }
              }}
              value={customUrl}
            />
            <button
              disabled={!customUrl.trim() || Boolean(opening)}
              onClick={() => void openUrl(customUrl.trim(), "custom")}
              type="button"
            >
              {opening === "custom" ? "Opening…" : "Open custom"}
            </button>
          </div>
          {error ? <p className="new-sim-error">{error}</p> : null}
        </div>
        <div className="deep-link-list">
          {sections.map((section) => (
            <section key={section.label}>
              <h3>{section.label}</h3>
              {section.groups.map(([group, links]) => (
                <div className="deep-link-group" key={group}>
                  <h4>{group}</h4>
                  <div className="deep-link-grid">{links.map(renderLink)}</div>
                </div>
              ))}
            </section>
          ))}
          {manifest && sections.length === 0 ? (
            <p className="deep-link-empty">No matching deep links.</p>
          ) : null}
        </div>
        <div className="new-sim-actions deep-link-actions">
          <span className="deep-link-target">
            {selectedSimulator?.name ?? "No simulator selected"}
          </span>
          <span className="new-sim-action-spacer" />
          <button className="new-sim-button" onClick={onClose} type="button">
            Done
          </button>
        </div>
      </section>
    </div>
  );
}
