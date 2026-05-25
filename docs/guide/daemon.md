# Service

SimDeck runs one local service. The service owns the browser UI, REST API, live
stream, inspector connections, and warm device sessions.

Most commands start or reuse the service automatically. Use the lifecycle
commands only when you need to inspect, stop, or restart it explicitly.

## Start

```sh
simdeck
simdeck --open
simdeck -p 4311
```

`simdeck` starts or reuses the background service and prints the browser URLs.
`--open` opens the local browser URL. `-p` or `--port` selects a non-default
port; the default is `4310`.

## Autostart

```sh
simdeck -a
simdeck --autostart
simdeck pair
```

Without `-a`, SimDeck starts an ordinary background service for the current user
session. `-a`, `--autostart`, and `simdeck pair` install or refresh the macOS
LaunchAgent so SimDeck starts again after login.

`simdeck pair` also detects LAN and Tailscale addresses, prints the pairing
code, and renders the QR/deep link for the native iOS app.

## Manage

```sh
simdeck daemon status
simdeck daemon stop
simdeck daemon restart
simdeck service reset
simdeck service off
```

`daemon status`, `daemon stop`, and `daemon restart` manage the same singleton
service that `simdeck` uses. `service reset` rotates the LaunchAgent token and
pairing code. `service off` removes the LaunchAgent.

## Options

These options are accepted by `simdeck`, `daemon start`, `daemon restart`,
`service on`, and `service restart`:

| Flag                         | Default     | Use it when                                |
| ---------------------------- | ----------- | ------------------------------------------ |
| `--port <port>` / `-p`       | `4310`      | You want a specific service port           |
| `--bind <ip>`                | `127.0.0.1` | You need LAN access with `0.0.0.0` or `::` |
| `--advertise-host <host>`    | detected    | Remote browsers need a specific host or IP |
| `--video-codec <mode>`       | `auto`      | You need to force encoder behavior         |
| `--stream-quality <profile>` | `full`      | You want lower CPU or bandwidth use        |
| `--local-stream-fps <fps>`   | `60`        | You want a different local stream target   |
| `--client-root <path>`       | bundled UI  | You are serving a custom static client     |

## Restart CoreSimulator

If `simctl` hangs, reports a stale service version, or devices never attach:

```sh
simdeck core-simulator restart
```

Then retry:

```sh
simdeck list
simdeck boot <udid>
```
