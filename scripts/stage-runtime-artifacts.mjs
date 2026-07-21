#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export function stageRuntimeArtifacts(rootDir, buildDir) {
  const textRunnerSource = path.join(
    rootDir,
    "packages",
    "server",
    "native",
    "text-runner",
  );
  const textRunnerProject = path.join(
    textRunnerSource,
    "SimDeckTextRunner.xcodeproj",
  );
  if (!fs.statSync(textRunnerProject).isDirectory()) {
    throw new Error(
      `Missing SimDeck text runner project: ${textRunnerProject}`,
    );
  }

  const textRunnerOutput = path.join(buildDir, "text-runner");
  fs.rmSync(textRunnerOutput, { recursive: true, force: true });
  fs.cpSync(textRunnerSource, textRunnerOutput, { recursive: true });
  return { textRunnerOutput };
}

const scriptPath = fileURLToPath(import.meta.url);
if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
  const rootDir = path.resolve(path.dirname(scriptPath), "..");
  const buildDir = path.resolve(process.argv[2] ?? path.join(rootDir, "build"));
  const { textRunnerOutput } = stageRuntimeArtifacts(rootDir, buildDir);
  console.log(`Staged ${textRunnerOutput}`);
}
