# SimDeck VS Code Extension

This extension opens the local SimDeck browser client inside a VS Code webview panel. It uses the configured server URL when available, falls back to the default always-on service at `http://127.0.0.1:4310`, and starts or reuses a project daemon through `simdeck ui` only when needed.

## Commands

- `SimDeck: Open Simulator View`
- `SimDeck: Stop Project Daemon`
- `SimDeck: Show Output`

## Settings

- `simdeck.serverUrl`
- `simdeck.cliPath`
- `simdeck.port`
- `simdeck.bindAddress`
- `simdeck.autoStartDaemon`
