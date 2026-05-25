#!/usr/bin/env node

const isGlobalInstall =
  process.env.npm_config_global === "true" ||
  process.env.npm_config_location === "global" ||
  process.env.npm_config_global_style === "true";

const isCi =
  process.env.CI === "true" ||
  process.env.npm_config_loglevel === "silent" ||
  process.env.npm_config_loglevel === "error";

if (!isGlobalInstall || isCi) {
  process.exit(0);
}

const message = `
SimDeck is installed.

Open the simulator UI:
  simdeck

Open a specific simulator:
  simdeck "iPhone 17 Pro"

Use a different service port:
  simdeck -p 4311

Install the agent skill:
  npx skills add NativeScript/SimDeck --skill simdeck -g

Recommended VS Code extension:
  nativescript.simdeck-vscode

Recommended for always-on agent/editor access:
  simdeck -a
  simdeck pair
`;

console.log(message.trimEnd());
