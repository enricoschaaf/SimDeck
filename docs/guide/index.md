# Overview

SimDeck is a local tool for viewing, controlling, inspecting, and automating mobile simulators.

Run `simdeck` from your project. It starts or reuses the local service, serves a browser UI, and exposes the same controls through the CLI and HTTP API.

## Core workflows

- View a live iOS Simulator or Android emulator in a browser.
- Tap, swipe, type, press hardware buttons, rotate, and open URLs.
- Install, launch, uninstall, boot, shut down, and erase devices.
- Capture screenshots, recordings, logs, pasteboard text, and accessibility trees.
- Inspect app UI through built-in accessibility or optional in-app inspectors.
- Write JS/TS automation with `simdeck/test`.
- Share a paired browser session over your LAN.
- Open the simulator view inside VS Code.

## Daily workflow

```sh
simdeck
```

Open the local URL, pick a device, and use the toolbar or CLI commands:

```sh
simdeck list
simdeck use <udid>
simdeck boot <udid>
simdeck install /path/to/App.app
simdeck install /path/to/App.ipa
simdeck launch com.example.App
simdeck tap --label "Continue" --wait-timeout-ms 5000
simdeck tap "Continue"
simdeck back
simdeck describe --format agent --max-depth 3 --interactive
```

Use `simdeck --open` to open the browser, `simdeck -p 4311` for a custom port, and `simdeck -a` to enable login autostart.

## Pick a page

- [Install](/guide/installation): requirements and setup.
- [Quick start](/guide/quick-start): first browser session.
- [Service](/guide/service): local service, autostart, and pairing.
- [Video and streaming](/guide/video): stream quality and codec choices.
- [LAN access](/guide/lan-access): pairing and remote browser access.
- [Testing](/guide/testing): `simdeck/test` and integration tests.
- [Troubleshooting](/guide/troubleshooting): practical fixes for common failures.
