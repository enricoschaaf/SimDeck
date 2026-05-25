type CipherPayload = {
  algorithm: "SHA256-SALTED+A256GCM";
  ciphertext: string;
  iv: string;
  salt: string;
};

type EncodedSession = {
  v: 1;
  upstream: string;
  token?: string;
  tokenCipher?: CipherPayload;
  device?: string;
  platform?: string;
  repo?: string;
  pr?: string;
  commit?: string;
  runId?: string;
  expiresAt?: string;
};

type SessionCookie = {
  upstream: string;
  token: string;
  device?: string;
  expiresAt?: string;
};

const REDIRECT_PARAM = "redirect";
const SESSION_COOKIE = "sdcp_session";
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 6;
const JSON_CONTENT = "application/json; charset=utf-8";

export default {
  async fetch(request: Request): Promise<Response> {
    try {
      return await handleRequest(request);
    } catch (error) {
      console.error(JSON.stringify({ error: String(error) }));
      return jsonResponse(
        { ok: false, error: "SimDeck CI proxy failed." },
        500,
      );
    }
  },
};

async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);

  if (url.pathname === "/api/session") {
    return sessionMetadata(request);
  }

  if (url.pathname === "/api/session/auth" && request.method === "POST") {
    return authenticateSession(request);
  }

  const redirect = url.searchParams.get(REDIRECT_PARAM);
  if (redirect) {
    const session = parseEncodedSession(redirect);
    const device = url.searchParams.get("device");
    if (device) {
      session.device = device;
    }
    if (session.tokenCipher) {
      return passwordPage(session, redirect, "");
    }
    if (!session.token) {
      return passwordPage(
        session,
        redirect,
        "This session link is missing its SimDeck access token.",
      );
    }
    return establishSession(session, session.token);
  }

  const cookieSession = sessionFromCookie(request);
  if (!cookieSession) {
    return landingPage();
  }

  if (sessionExpired(cookieSession.expiresAt)) {
    return clearSessionResponse(
      passwordShell(
        "Session expired",
        "<p>This SimDeck CI session has expired. Re-run the workflow to create a new link.</p>",
      ),
      410,
    );
  }

  return proxyToSimDeck(request, cookieSession);
}

function sessionMetadata(request: Request): Response {
  const session = sessionFromCookie(request);
  if (!session) {
    return jsonResponse({ ok: false, authenticated: false }, 401);
  }
  return jsonResponse({
    ok: true,
    authenticated: true,
    device: session.device ?? null,
    expiresAt: session.expiresAt ?? null,
  });
}

async function authenticateSession(request: Request): Promise<Response> {
  const form = await request.formData();
  const encoded = stringFormValue(form.get(REDIRECT_PARAM));
  const password = stringFormValue(form.get("password"));
  if (!encoded || !password) {
    return passwordShellResponse(
      "Password required",
      "<p>Enter the SimDeck session password to continue.</p>",
      400,
    );
  }

  const session = parseEncodedSession(encoded);
  if (!session.tokenCipher) {
    if (!session.token) {
      return passwordPage(
        session,
        encoded,
        "This session link is invalid.",
        400,
      );
    }
    return establishSession(session, session.token);
  }

  try {
    const token = await decryptToken(session.tokenCipher, password);
    return establishSession(session, token);
  } catch {
    return passwordPage(
      session,
      encoded,
      "That password did not unlock this session.",
      401,
    );
  }
}

function establishSession(session: EncodedSession, token: string): Response {
  if (sessionExpired(session.expiresAt)) {
    return passwordShellResponse(
      "Session expired",
      "<p>This SimDeck CI session has expired. Re-run the workflow to create a new link.</p>",
      410,
    );
  }

  const cookie: SessionCookie = {
    upstream: session.upstream,
    token,
    device: session.device,
    expiresAt: session.expiresAt,
  };
  const target = new URL("https://simdeck.local/");
  if (session.device) {
    target.searchParams.set("device", session.device);
  }
  target.searchParams.set("remoteStream", "1");

  return new Response(null, {
    status: 303,
    headers: {
      Location: `${target.pathname}${target.search}`,
      "Set-Cookie": sessionCookie(cookie),
      "Cache-Control": "no-store",
    },
  });
}

async function proxyToSimDeck(
  request: Request,
  session: SessionCookie,
): Promise<Response> {
  const requestUrl = new URL(request.url);
  const upstream = new URL(session.upstream);
  const target = new URL(requestUrl.pathname + requestUrl.search, upstream);
  target.searchParams.set("simdeckToken", session.token);
  if (session.device && !target.searchParams.has("device")) {
    target.searchParams.set("device", session.device);
  }

  const headers = new Headers(request.headers);
  headers.set("X-SimDeck-Token", session.token);
  headers.set("Host", target.host);
  headers.delete("Cookie");

  const response = await fetch(target.toString(), {
    body: request.body,
    headers,
    method: request.method,
    redirect: "manual",
  });

  const responseHeaders = new Headers(response.headers);
  responseHeaders.delete("set-cookie");
  responseHeaders.set("Cache-Control", "no-store");
  rewriteLocationHeader(responseHeaders, upstream, requestUrl.origin);

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: responseHeaders,
  });
}

function rewriteLocationHeader(
  headers: Headers,
  upstream: URL,
  proxyOrigin: string,
): void {
  const location = headers.get("Location");
  if (!location) return;

  const rewritten = new URL(location, upstream);
  if (rewritten.origin === upstream.origin) {
    headers.set(
      "Location",
      `${proxyOrigin}${rewritten.pathname}${rewritten.search}${rewritten.hash}`,
    );
  }
}

function parseEncodedSession(value: string): EncodedSession {
  const decoded = base64UrlDecode(value);
  const trimmed = decoded.trim();
  if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
    const url = new URL(trimmed);
    const token = url.searchParams.get("simdeckToken") ?? undefined;
    const device = url.searchParams.get("device") ?? undefined;
    url.searchParams.delete("simdeckToken");
    url.searchParams.delete("device");
    return normalizeSession({
      v: 1,
      upstream: `${url.origin}${url.pathname === "/" ? "" : url.pathname}`,
      token,
      device,
    });
  }

  const parsed = JSON.parse(trimmed) as EncodedSession;
  return normalizeSession(parsed);
}

function normalizeSession(session: EncodedSession): EncodedSession {
  if (session.v !== 1) {
    throw new Error("Unsupported session payload version.");
  }
  const upstream = new URL(session.upstream);
  if (upstream.protocol !== "https:") {
    throw new Error("SimDeck CI upstream must use https.");
  }
  return {
    ...session,
    upstream: upstream.origin,
  };
}

async function decryptToken(
  cipher: CipherPayload,
  password: string,
): Promise<string> {
  if (cipher.algorithm !== "SHA256-SALTED+A256GCM") {
    throw new Error("Unsupported token cipher.");
  }
  const key = await aesKeyForPassword(password, cipher.salt);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64UrlBytes(cipher.iv) },
    key,
    base64UrlBytes(cipher.ciphertext),
  );
  return new TextDecoder().decode(plaintext);
}

async function aesKeyForPassword(
  password: string,
  encodedSalt: string,
): Promise<CryptoKey> {
  const salt = base64UrlBytes(encodedSalt);
  const passwordBytes = new TextEncoder().encode(password);
  const material = new Uint8Array(passwordBytes.length + salt.length + 1);
  material.set(passwordBytes);
  material[passwordBytes.length] = 0;
  material.set(salt, passwordBytes.length + 1);
  const digest = await crypto.subtle.digest("SHA-256", material);
  return crypto.subtle.importKey(
    "raw",
    digest,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
}

function sessionFromCookie(request: Request): SessionCookie | null {
  const raw = cookieValue(request.headers.get("Cookie") ?? "", SESSION_COOKIE);
  if (!raw) return null;

  try {
    const parsed = JSON.parse(base64UrlDecode(raw)) as SessionCookie;
    if (!parsed.upstream || !parsed.token) return null;
    const upstream = new URL(parsed.upstream);
    if (upstream.protocol !== "https:") return null;
    return { ...parsed, upstream: upstream.origin };
  } catch {
    return null;
  }
}

function sessionCookie(session: SessionCookie): string {
  const value = base64UrlEncode(JSON.stringify(session));
  return [
    `${SESSION_COOKIE}=${value}`,
    "Path=/",
    "HttpOnly",
    "Secure",
    "SameSite=Lax",
    `Max-Age=${COOKIE_MAX_AGE_SECONDS}`,
  ].join("; ");
}

function clearSessionResponse(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Set-Cookie": `${SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
      "Cache-Control": "no-store",
    },
  });
}

function passwordPage(
  session: EncodedSession,
  encoded: string,
  error: string,
  status = 200,
): Response {
  const details = [
    session.repo ? escapeHtml(session.repo) : "",
    session.pr ? `PR #${escapeHtml(session.pr)}` : "",
    session.platform ? escapeHtml(session.platform) : "",
  ]
    .filter(Boolean)
    .join(" · ");
  const body = `
    ${details ? `<p class="details">${details}</p>` : ""}
    ${error ? `<p class="error">${escapeHtml(error)}</p>` : ""}
    <form method="post" action="/api/session/auth">
      <input type="hidden" name="${REDIRECT_PARAM}" value="${escapeHtml(encoded)}" />
      <label>
        Session password
        <input name="password" type="password" autocomplete="current-password" autofocus />
      </label>
      <button type="submit">Open SimDeck</button>
    </form>
  `;
  return passwordShellResponse("Protected SimDeck session", body, status);
}

function landingPage(): Response {
  return passwordShellResponse(
    "SimDeck CI proxy",
    "<p>Open a SimDeck CI link from a pull request comment.</p>",
    200,
  );
}

function passwordShellResponse(
  title: string,
  body: string,
  status: number,
): Response {
  return new Response(passwordShell(title, body), {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function passwordShell(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  <style>
    :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { min-height: 100vh; margin: 0; display: grid; place-items: center; background: #0e1116; color: #f4f7fb; }
    main { width: min(100% - 32px, 420px); }
    h1 { font-size: 1.45rem; margin: 0 0 12px; letter-spacing: 0; }
    p { color: #aab5c3; line-height: 1.5; margin: 0 0 18px; }
    .details { color: #d7deea; font-size: 0.92rem; }
    .error { color: #ffb4a9; }
    form { display: grid; gap: 14px; }
    label { display: grid; gap: 8px; color: #d7deea; font-size: 0.92rem; }
    input { border: 1px solid #354153; border-radius: 8px; background: #151a22; color: #f4f7fb; font: inherit; padding: 11px 12px; }
    button { border: 0; border-radius: 8px; background: #37c57b; color: #07110b; font: inherit; font-weight: 700; padding: 11px 14px; cursor: pointer; }
    button:hover { background: #4bdd8f; }
  </style>
</head>
<body>
  <main>
    <h1>${escapeHtml(title)}</h1>
    ${body}
  </main>
</body>
</html>`;
}

function jsonResponse(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": JSON_CONTENT,
      "Cache-Control": "no-store",
    },
  });
}

function sessionExpired(value: string | undefined): boolean {
  if (!value) return false;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp <= Date.now();
}

function stringFormValue(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function cookieValue(header: string, name: string): string | null {
  for (const chunk of header.split(";")) {
    const [rawName, ...rawValue] = chunk.trim().split("=");
    if (rawName === name) {
      return rawValue.join("=");
    }
  }
  return null;
}

function base64UrlEncode(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

function base64UrlDecode(value: string): string {
  return new TextDecoder().decode(base64UrlBytes(value));
}

function base64UrlBytes(value: string): Uint8Array<ArrayBuffer> {
  const padded = value
    .replaceAll("-", "+")
    .replaceAll("_", "/")
    .padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
