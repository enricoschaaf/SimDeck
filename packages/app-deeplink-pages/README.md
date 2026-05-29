# SimDeck Launchpad (`app.simdeck.sh`)

Static site deployed to Cloudflare Pages. Two jobs:

1. **Build SimDeck deeplinks.** Browse the simulators on your local SimDeck
   server, click one, and copy a `https://app.simdeck.sh/open?...` link (or its
   `simdeck://` twin). Paste that link into Codex, Claude, Slack, anywhere —
   tapping it on iPhone opens the SimDeck iOS app right on the chosen
   simulator via a Universal Link.
2. **Talk to a local SimDeck.** The site is allowed to call
   `http://localhost:4310` (and other simdeck-server origins) directly from
   the browser. On Mac (Chrome, Firefox, Safari) the browser treats `localhost`
   as a secure context, so the HTTPS launchpad page can fetch `http://localhost`
   without mixed-content errors. The server's CORS allowlist bakes in
   `https://app.simdeck.sh`, and `Access-Control-Allow-Private-Network`
   is emitted for Chrome's CORS-RFC1918.

Mobile browsers (including iOS Safari) cannot reach `localhost` of a different
machine and block mixed content from public→private targets, so the launchpad
on a phone is deeplink-only — clicks open the iOS app.

## Layout

```
public/
  index.html                                 launchpad UI
  app.js                                     vanilla JS, no build step
  styles.css
  simdeck.png                                favicon / apple-touch-icon
  _headers                                   CF Pages headers (AASA content-type)
  _redirects                                 legacy /apple-app-site-association alias
  .well-known/apple-app-site-association     iOS Universal Link config
```

The site is plain HTML/CSS/JS — no bundler, no framework. To preview locally:

```sh
npm run dev          # http://localhost:4311
```

That fires `serve` on the `public/` directory. To preview through Wrangler's
Pages emulator (closer to production, honors `_headers` / `_redirects`):

```sh
npm run preview
```

## Deploy to Cloudflare Pages

The project is set up for `wrangler pages deploy`:

```sh
npm run deploy
```

Or hook it up to a Cloudflare Pages project pointing at this directory with
`public` as the build output dir. There's no build command — `_headers` and
`_redirects` ship as-is.

## Universal Link contract

The iOS app's `StudioLinkResolver` handles these paths on `app.simdeck.sh`:

- `/open` — primary entry. Opens the app on a specific server/simulator.
- `/connect` — alias.
- `/pair` — alias when a pairing code is included.

Query params:

| param                              | meaning                                                          |
| ---------------------------------- | ---------------------------------------------------------------- |
| `host` (required)                  | Where SimDeck is reachable from the phone (LAN IP, tunnel host). |
| `port`                             | Port (defaults vary).                                            |
| `scheme`                           | `http` or `https`. Default `http`.                               |
| `udid` / `device`                  | Auto-select this simulator and auto-start streaming.             |
| `serverId` / `sid` / `s`           | Hash identifying which SimDeck instance this is.                 |
| `hostId` / `hid`                   | Stable host identifier (machine-level).                          |
| `hostName` / `hname`               | Human-readable host name for the picker.                         |
| `serverKind` / `kind`              | `launchAgent`, `foreground`, `standalone`, …                     |
| `token` / `simdeckToken`           | Pre-shared access token (optional).                              |
| `code` / `pairingCode` (on /pair)  | Pairing code for first-time link-up.                             |

The Universal Link `https://app.simdeck.sh/open?...` and the custom-scheme
`simdeck://open?...` carry the same query string and are interchangeable.

## AASA file

`public/.well-known/apple-app-site-association` declares the
`CS838V553Y.org.nativescript.simdeck` app and the path patterns iOS should
treat as universal links. The `_headers` file forces the
`application/json` content-type that iOS requires.

When you change the AASA file, force iOS to re-fetch it:

- toggle Airplane Mode, **or**
- delete + reinstall the app, **or**
- use the Apple `swcutil` CLI (`sudo swcutil reset`) on a developer device.
