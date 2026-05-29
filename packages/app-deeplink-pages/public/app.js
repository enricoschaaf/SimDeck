// SimDeck launchpad — connects to a local (or remote) SimDeck server,
// lists simulators, and produces deeplinks the user can open on iOS.

const DEFAULT_PORT = 4310;
const STORAGE_KEY = "simdeck.launchpad.v1";
const LAUNCHPAD_ORIGIN = "https://app.simdeck.sh";

const state = {
  baseURL: null, // string, no trailing slash
  token: null, // optional bearer-style token
  health: null, // /api/health response
  simulators: [], // /api/simulators payload
  selectedUDID: null,
};

const ui = {
  page: document.querySelector(".page"),
  statusDot: document.querySelector("#status .dot"),
  statusText: document.getElementById("status-text"),
  connectSubtitle: document.getElementById("connect-subtitle"),
  advanced: document.getElementById("advanced"),
  hostInput: document.getElementById("host-input"),
  portInput: document.getElementById("port-input"),
  connectBtn: document.getElementById("connect-btn"),
  pairingBlock: document.getElementById("pairing"),
  pairCode: document.getElementById("pair-code"),
  pairBtn: document.getElementById("pair-btn"),
  pairError: document.getElementById("pair-error"),
  serverCard: document.getElementById("server-card"),
  serverName: document.getElementById("server-name"),
  serverMeta: document.getElementById("server-meta"),
  disconnectBtn: document.getElementById("disconnect-btn"),
  simList: document.getElementById("sim-list"),
  refreshSims: document.getElementById("refresh-sims"),
  deeplinkCard: document.getElementById("deeplink-card"),
  deeplinkSummary: document.getElementById("deeplink-summary"),
  universalLink: document.getElementById("universal-link"),
  customScheme: document.getElementById("custom-scheme"),
  openLink: document.getElementById("open-link"),
  localLink: document.getElementById("local-link"),
};

init();

async function init() {
  bindUI();

  const remembered = loadRemembered();
  if (remembered?.baseURL) {
    ui.hostInput.value = remembered.baseURL;
    state.token = remembered.token ?? null;
    await tryConnect(remembered.baseURL, { silent: false });
    return;
  }

  await tryConnect(`http://localhost:${DEFAULT_PORT}`, { silent: false });
}

function bindUI() {
  ui.connectBtn.addEventListener("click", () => {
    const raw = ui.hostInput.value.trim();
    if (!raw) {
      flashStatus("Enter a host or full URL", "error");
      return;
    }
    const port = ui.portInput.value.trim();
    const url = buildBaseURL(raw, port);
    if (!url) {
      flashStatus("That doesn't look like a valid host or URL", "error");
      return;
    }
    state.token = null;
    tryConnect(url, { silent: false });
  });

  ui.pairBtn.addEventListener("click", async () => {
    const code = (ui.pairCode.value || "").replace(/\D+/g, "");
    if (code.length < 4) {
      ui.pairError.hidden = false;
      ui.pairError.textContent = "Pairing codes are usually 6 digits.";
      return;
    }
    ui.pairBtn.disabled = true;
    ui.pairError.hidden = true;
    try {
      const response = await apiFetch("/api/pair", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ code }),
        skipAuth: true,
      });
      if (!response.ok) {
        const message =
          response.status === 401
            ? "That pairing code didn't work. Check the terminal output and try again."
            : `Pairing failed (HTTP ${response.status}).`;
        throw new Error(message);
      }
      const payload = await response.json();
      const token = payload?.accessToken;
      if (typeof token !== "string" || !token) {
        throw new Error("Server didn't return an access token.");
      }
      state.token = token;
      persistRemembered();
      await loadServer();
    } catch (error) {
      ui.pairError.hidden = false;
      ui.pairError.textContent = error.message || String(error);
    } finally {
      ui.pairBtn.disabled = false;
    }
  });

  ui.refreshSims.addEventListener("click", () => loadSimulators());
  ui.disconnectBtn.addEventListener("click", () => {
    state.baseURL = null;
    state.token = null;
    state.health = null;
    state.simulators = [];
    state.selectedUDID = null;
    persistRemembered();
    setPageState("probing");
    ui.serverCard.hidden = true;
    ui.deeplinkCard.hidden = true;
    ui.pairingBlock.hidden = true;
    ui.advanced.open = true;
    ui.hostInput.focus();
    setStatus("Disconnected. Enter a host to try again.", "");
  });

  document.querySelectorAll("[data-copy]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const targetId = btn.getAttribute("data-copy");
      const input = document.getElementById(targetId);
      if (!input) return;
      navigator.clipboard?.writeText(input.value).then(
        () => flashButton(btn, "Copied"),
        () => {
          input.select();
          document.execCommand?.("copy");
          flashButton(btn, "Copied");
        },
      );
    });
  });
}

function flashButton(button, text) {
  const original = button.textContent;
  button.textContent = text;
  button.disabled = true;
  setTimeout(() => {
    button.textContent = original;
    button.disabled = false;
  }, 1200);
}

function loadRemembered() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return null;
    return parsed;
  } catch {
    return null;
  }
}

function persistRemembered() {
  try {
    if (!state.baseURL) {
      localStorage.removeItem(STORAGE_KEY);
      return;
    }
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ baseURL: state.baseURL, token: state.token ?? null }),
    );
  } catch {
    // ignore storage failures (private mode, etc.)
  }
}

function buildBaseURL(rawHost, rawPort) {
  let host = rawHost.trim();
  if (!host) return null;
  // Accept either "host[:port]", "scheme://host[:port][/path]", or just "host".
  let parsed;
  try {
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(host)) {
      parsed = new URL(host);
    } else {
      parsed = new URL(`http://${host}`);
    }
  } catch {
    return null;
  }
  if (!parsed.hostname) return null;
  if (!parsed.port && rawPort) {
    const port = Number.parseInt(rawPort, 10);
    if (!Number.isFinite(port) || port <= 0 || port > 65535) return null;
    parsed.port = String(port);
  }
  if (!parsed.port && parsed.protocol === "http:") {
    parsed.port = String(DEFAULT_PORT);
  }
  parsed.pathname = "";
  parsed.search = "";
  parsed.hash = "";
  return parsed.origin;
}

async function tryConnect(baseURL, { silent }) {
  state.baseURL = baseURL;
  setPageState("probing");
  setStatus(`Probing ${displayHost(baseURL)}…`, "probing");
  ui.pairingBlock.hidden = true;
  ui.pairError.hidden = true;
  try {
    const response = await apiFetch("/api/health");
    if (response.status === 401) {
      // Server is up but the cross-origin request needs a token.
      const identity = await safeJSON(response);
      state.health = identity ?? null;
      setPageState("auth");
      setStatus(
        identity?.hostName
          ? `${identity.hostName} needs pairing`
          : "Server requires pairing",
        "auth",
      );
      ui.pairingBlock.hidden = false;
      ui.serverCard.hidden = true;
      ui.deeplinkCard.hidden = true;
      ui.advanced.open = false;
      ui.pairCode.focus();
      return;
    }
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    state.health = await response.json();
    persistRemembered();
    await loadServer();
  } catch (error) {
    setPageState("error");
    setStatus(
      `Couldn't reach ${displayHost(baseURL)} — ${friendlyError(error)}`,
      "error",
    );
    ui.serverCard.hidden = true;
    ui.deeplinkCard.hidden = true;
    ui.advanced.open = true;
    if (!silent) ui.hostInput.focus();
  }
}

async function loadServer() {
  if (!state.health) {
    const response = await apiFetch("/api/health");
    if (!response.ok) {
      if (response.status === 401) {
        setPageState("auth");
        ui.pairingBlock.hidden = false;
        return;
      }
      throw new Error(`HTTP ${response.status}`);
    }
    state.health = await response.json();
  }
  setPageState("ok");
  setStatus(
    `Connected to ${state.health.hostName ?? displayHost(state.baseURL)}`,
    "ok",
  );
  ui.pairingBlock.hidden = true;
  ui.serverCard.hidden = false;
  ui.serverName.textContent =
    state.health.hostName?.trim() ||
    displayHost(state.baseURL) ||
    "SimDeck server";
  ui.serverMeta.textContent = formatServerMeta(state.health, state.baseURL);
  ui.connectSubtitle.textContent =
    "Pick a simulator below to build a deeplink, or paste the link wherever you want it opened.";
  ui.advanced.open = false;
  await loadSimulators();
}

function formatServerMeta(health, baseURL) {
  const parts = [];
  if (health?.serverKind) parts.push(prettyServerKind(health.serverKind));
  if (baseURL) parts.push(displayHost(baseURL));
  if (health?.hostId) parts.push(`host: ${health.hostId.slice(0, 8)}`);
  if (health?.serverId) parts.push(`id: ${health.serverId}`);
  return parts.join(" • ");
}

function prettyServerKind(kind) {
  switch (kind?.toLowerCase()) {
    case "launchagent":
      return "LaunchAgent";
    case "foreground":
      return "Foreground";
    case "workspace":
      return "Workspace";
    case "standalone":
      return "Standalone";
    case "cloudflareproxy":
      return "Cloudflare proxy";
    default:
      return kind ?? "";
  }
}

async function loadSimulators() {
  ui.simList.innerHTML = "";
  const skeleton = document.createElement("li");
  skeleton.className = "muted";
  skeleton.textContent = "Loading simulators…";
  ui.simList.appendChild(skeleton);
  try {
    const response = await apiFetch("/api/simulators");
    if (response.status === 401) {
      setPageState("auth");
      ui.pairingBlock.hidden = false;
      ui.simList.innerHTML = "";
      return;
    }
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    const list = Array.isArray(payload)
      ? payload
      : Array.isArray(payload?.simulators)
        ? payload.simulators
        : [];
    state.simulators = list;
    renderSimulators(list);
  } catch (error) {
    ui.simList.innerHTML = "";
    const li = document.createElement("li");
    li.className = "error";
    li.textContent = `Couldn't load simulators: ${friendlyError(error)}`;
    ui.simList.appendChild(li);
  }
}

function renderSimulators(list) {
  ui.simList.innerHTML = "";
  if (!list.length) {
    const li = document.createElement("li");
    li.className = "muted";
    li.textContent =
      "No simulators registered with this SimDeck. Boot one and refresh.";
    ui.simList.appendChild(li);
    return;
  }
  const sorted = [...list].sort((a, b) => {
    if ((b.isBooted ? 1 : 0) !== (a.isBooted ? 1 : 0)) {
      return (b.isBooted ? 1 : 0) - (a.isBooted ? 1 : 0);
    }
    return (a.name ?? "").localeCompare(b.name ?? "");
  });
  for (const sim of sorted) {
    const li = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "sim";
    button.setAttribute("aria-pressed", String(state.selectedUDID === sim.udid));
    button.innerHTML = `
      <div class="sim-meta">
        <span class="sim-name"></span>
        <span class="sim-sub"></span>
      </div>
      <span class="sim-state" data-booted="${sim.isBooted ? "true" : "false"}"></span>
    `;
    button.querySelector(".sim-name").textContent = sim.name ?? sim.udid;
    button.querySelector(".sim-sub").textContent = [
      sim.runtimeName ?? sim.runtimeIdentifier,
      sim.deviceTypeName ?? sim.deviceTypeIdentifier,
      sim.udid?.slice(0, 8),
    ]
      .filter(Boolean)
      .join(" • ");
    button.querySelector(".sim-state").textContent = sim.isBooted
      ? "Booted"
      : "Shutdown";
    button.addEventListener("click", () => selectSimulator(sim));
    li.appendChild(button);
    ui.simList.appendChild(li);
  }
}

function selectSimulator(sim) {
  state.selectedUDID = sim.udid;
  for (const btn of ui.simList.querySelectorAll(".sim")) {
    btn.setAttribute("aria-pressed", "false");
  }
  const sortedButtons = ui.simList.querySelectorAll(".sim");
  for (const btn of sortedButtons) {
    if (btn.querySelector(".sim-sub")?.textContent?.includes(sim.udid?.slice(0, 8))) {
      btn.setAttribute("aria-pressed", "true");
    }
  }
  const links = buildDeeplinks(sim);
  ui.deeplinkCard.hidden = false;
  ui.deeplinkSummary.textContent = `${sim.name ?? sim.udid} on ${
    state.health?.hostName ?? displayHost(state.baseURL)
  }`;
  ui.universalLink.value = links.universal;
  ui.customScheme.value = links.scheme;
  ui.openLink.href = links.universal;
}

function buildDeeplinks(sim) {
  const target = resolveTargetEndpoint();
  const params = new URLSearchParams();
  params.set("host", target.host);
  if (target.port) params.set("port", String(target.port));
  if (target.scheme && target.scheme !== "http") {
    params.set("scheme", target.scheme);
  }
  params.set("udid", sim.udid);
  if (state.health?.hostId) params.set("hostId", state.health.hostId);
  if (state.health?.hostName) params.set("hostName", state.health.hostName);
  if (state.health?.serverId) params.set("serverId", state.health.serverId);
  if (state.health?.serverKind) params.set("serverKind", state.health.serverKind);
  const query = params.toString();
  return {
    universal: `${LAUNCHPAD_ORIGIN}/open?${query}`,
    scheme: `simdeck://open?${query}`,
  };
}

function resolveTargetEndpoint() {
  // Prefer the server's advertised LAN/tunnel host so the iOS app can reach it
  // off-device. Fall back to whatever the user is currently talking to.
  const advertised = (state.health?.advertiseHost ?? "").trim();
  const port = state.health?.httpPort ?? null;
  if (
    advertised &&
    advertised !== "0.0.0.0" &&
    advertised !== "::" &&
    advertised !== "127.0.0.1" &&
    advertised.toLowerCase() !== "localhost"
  ) {
    return { host: advertised, port, scheme: "http" };
  }
  // Fall back to the URL we're currently using — useful if the user pasted
  // a tunnel hostname directly.
  try {
    const url = new URL(state.baseURL);
    return {
      host: url.hostname,
      port: url.port ? Number.parseInt(url.port, 10) : null,
      scheme: url.protocol.replace(":", ""),
    };
  } catch {
    return { host: "localhost", port: port ?? DEFAULT_PORT, scheme: "http" };
  }
}

async function apiFetch(path, init = {}) {
  if (!state.baseURL) throw new Error("Not connected.");
  const url = path.startsWith("http") ? path : `${state.baseURL}${path}`;
  const headers = new Headers(init.headers ?? {});
  if (!init.skipAuth && state.token) {
    headers.set("x-simdeck-token", state.token);
  }
  return fetch(url, {
    ...init,
    headers,
    // omit credentials — we use header-based auth, not cookies.
    credentials: "omit",
    cache: "no-store",
    mode: "cors",
  });
}

async function safeJSON(response) {
  try {
    return await response.clone().json();
  } catch {
    return null;
  }
}

function setPageState(value) {
  ui.page.dataset.state = value;
}

function setStatus(text, mode) {
  ui.statusText.textContent = text;
  ui.statusDot.dataset.status = mode || "";
}

function flashStatus(text, mode) {
  setStatus(text, mode);
  setTimeout(() => {
    if (state.baseURL && state.health) {
      setStatus(
        `Connected to ${state.health.hostName ?? displayHost(state.baseURL)}`,
        "ok",
      );
    } else {
      setStatus(text, mode);
    }
  }, 2500);
}

function displayHost(baseURL) {
  if (!baseURL) return "";
  try {
    const url = new URL(baseURL);
    return url.host;
  } catch {
    return baseURL;
  }
}

function friendlyError(error) {
  if (!error) return "unknown error";
  const message = String(error.message || error);
  if (/failed to fetch|networkerror/i.test(message)) {
    return "no response (not running, wrong port, or blocked by the browser)";
  }
  return message;
}
