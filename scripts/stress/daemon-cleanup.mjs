#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const args = parseArgs(process.argv.slice(2));
const binary = resolve(
  root,
  String(
    args.binary ??
      process.env.SIMDECK_STRESS_BINARY ??
      join(root, "build", "simdeck"),
  ),
);
const iterations = positiveInt(
  args.iterations ?? process.env.SIMDECK_DAEMON_STRESS_ITERATIONS,
  20,
);
const concurrency = positiveInt(
  args.concurrency ?? process.env.SIMDECK_DAEMON_STRESS_CONCURRENCY,
  2,
);
const basePort = positiveInt(
  args["base-port"] ?? process.env.SIMDECK_DAEMON_STRESS_BASE_PORT,
  45100,
);
const settleMs = positiveInt(
  args["settle-ms"] ?? process.env.SIMDECK_DAEMON_STRESS_SETTLE_MS,
  750,
);
const maxStopMs = positiveInt(
  args["max-stop-ms"] ?? process.env.SIMDECK_DAEMON_STRESS_MAX_STOP_MS,
  8000,
);
const requestsPerIteration = positiveInt(
  args.requests ?? process.env.SIMDECK_DAEMON_STRESS_REQUESTS,
  3,
);
const keepTemp = booleanArg(
  args["keep-temp"] ?? process.env.SIMDECK_DAEMON_STRESS_KEEP_TEMP,
);

if (!existsSync(binary)) {
  console.error(
    `Missing SimDeck binary at ${binary}. Run npm run build:cli or pass --binary.`,
  );
  process.exit(1);
}

const clientRoot = join(root, "client", "dist");
const useClientRoot = existsSync(clientRoot);
const failures = [];
const results = [];
let nextIteration = 0;
const startedAt = Date.now();

await Promise.all(
  Array.from({ length: concurrency }, async (_, workerIndex) => {
    while (true) {
      const iteration = nextIteration;
      nextIteration += 1;
      if (iteration >= iterations) {
        return;
      }
      const result = await runIteration(workerIndex, iteration);
      results.push(result);
      if (!result.ok) {
        failures.push(
          `worker=${workerIndex} iteration=${iteration}: ${result.failures.join("; ")}`,
        );
      }
    }
  }),
);

results.sort((left, right) => left.iteration - right.iteration);
const elapsedMs = Date.now() - startedAt;
const summary = {
  ok: failures.length === 0,
  binary,
  iterations,
  concurrency,
  basePort,
  settleMs,
  maxStopMs,
  requestsPerIteration,
  elapsedMs,
  completed: results.length,
  failures: failures.slice(0, 20),
  results: results.map((result) => ({
    iteration: result.iteration,
    worker: result.worker,
    port: result.port,
    pid: result.pid,
    startMs: result.startMs,
    stopMs: result.stopMs,
    processCountAtStart: result.processesAtStart.length,
    maxRssMb: result.maxRssMb,
    maxOpenFiles: result.maxOpenFiles,
    ok: result.ok,
    failures: result.failures,
  })),
};

console.log(JSON.stringify(summary, null, 2));
if (!summary.ok) {
  process.exit(1);
}

async function runIteration(worker, iteration) {
  const tempRoot = await mkdtemp(join(tmpdir(), "simdeck-daemon-stress-"));
  const projectRoot = join(tempRoot, "project");
  mkdirSync(projectRoot, { recursive: true });
  writeFileSync(
    join(projectRoot, "package.json"),
    JSON.stringify({
      private: true,
      name: `simdeck-daemon-stress-${iteration}`,
    }),
  );

  const port = basePort + worker * 200 + (iteration % 200);
  const failures = [];
  let metadata = null;
  let processesAtStart = [];
  let maxRssMb = null;
  let maxOpenFiles = null;
  let startMs = 0;
  let stopMs = 0;

  try {
    killPortListeners(port);
    const startArgs = [
      "daemon",
      "start",
      "--port",
      String(port),
      "--bind",
      "127.0.0.1",
      "--video-codec",
      "software",
      "--stream-quality",
      "tiny",
    ];
    if (useClientRoot) {
      startArgs.push("--client-root", clientRoot);
    }

    const startedAt = Date.now();
    metadata = runJson(startArgs, { cwd: projectRoot });
    startMs = Date.now() - startedAt;
    if (metadata.ok !== true) {
      failures.push(
        `start did not return ok=true: ${JSON.stringify(metadata)}`,
      );
    }
    if (!metadata.pid || !Number.isFinite(Number(metadata.pid))) {
      failures.push(
        `start did not return a daemon pid: ${JSON.stringify(metadata)}`,
      );
    }

    const health = await fetchJson(metadata.url, "/api/health");
    if (
      health.ok !== true ||
      Number(health.httpPort) !== Number(metadata.url.split(":").pop())
    ) {
      failures.push(
        `health payload was not for the started daemon: ${JSON.stringify(health)}`,
      );
    }

    for (let index = 0; index < requestsPerIteration; index += 1) {
      await fetchJson(
        metadata.url,
        index % 2 === 0 ? "/api/health" : "/api/metrics",
      );
    }

    processesAtStart = processGroupProcesses(Number(metadata.pid));
    if (processesAtStart.length === 0) {
      failures.push(`process group ${metadata.pid} was empty after start`);
    }
    for (const process of processesAtStart) {
      const rssMb = rssMbForPid(process.pid);
      const openFiles = openFileCountForPid(process.pid);
      if (rssMb != null) {
        maxRssMb = maxRssMb == null ? rssMb : Math.max(maxRssMb, rssMb);
      }
      if (openFiles != null) {
        maxOpenFiles =
          maxOpenFiles == null ? openFiles : Math.max(maxOpenFiles, openFiles);
      }
    }

    const stoppedAt = Date.now();
    const stop = runJson(["daemon", "stop"], { cwd: projectRoot });
    stopMs = Date.now() - stoppedAt;
    if (stop.ok !== true || stop.running !== false) {
      failures.push(
        `stop did not report running=false: ${JSON.stringify(stop)}`,
      );
    }
    if (stopMs > maxStopMs) {
      failures.push(`stop took ${stopMs}ms, above ${maxStopMs}ms`);
    }
    await sleep(settleMs);

    const leakedProcesses = processGroupProcesses(Number(metadata.pid));
    if (leakedProcesses.length > 0) {
      failures.push(
        `process group ${metadata.pid} still has pids ${leakedProcesses
          .map((process) => process.pid)
          .join(",")}`,
      );
    }
    const leakedListeners = portListeners(port);
    if (leakedListeners.length > 0) {
      failures.push(
        `port ${port} still has listeners ${leakedListeners.join(",")}`,
      );
    }
    const status = runJson(["daemon", "status"], { cwd: projectRoot });
    if (
      status.running ||
      status.healthy ||
      status.processRunning ||
      status.stale
    ) {
      failures.push(`daemon status remained active: ${JSON.stringify(status)}`);
    }
  } catch (error) {
    failures.push(error instanceof Error ? error.message : String(error));
  } finally {
    if (metadata?.pid) {
      terminateProcessGroup(Number(metadata.pid));
    }
    killPortListeners(port);
    try {
      runJson(["daemon", "stop"], { cwd: projectRoot, allowFailure: true });
    } catch {
      // Best effort; the assertions above carry the useful failure.
    }
    if (!keepTemp) {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  }

  return {
    ok: failures.length === 0,
    failures,
    iteration,
    worker,
    port,
    pid: metadata?.pid ?? null,
    startMs,
    stopMs,
    processesAtStart,
    maxRssMb,
    maxOpenFiles,
  };
}

async function fetchJson(baseUrl, path) {
  const response = await fetch(new URL(path, baseUrl));
  const text = await response.text();
  if (!response.ok) {
    throw new Error(
      `${path} returned ${response.status}: ${text.slice(0, 500)}`,
    );
  }
  return JSON.parse(text);
}

function runJson(commandArgs, options = {}) {
  const result = spawnSync(binary, commandArgs, {
    cwd: options.cwd ?? root,
    encoding: "utf8",
    env: {
      ...process.env,
      SIMDECK_REALTIME_STREAM: "0",
    },
  });
  if (!options.allowFailure && result.status !== 0) {
    throw new Error(
      `${binary} ${commandArgs.join(" ")} failed with ${result.status ?? result.signal}: ${[
        result.stdout,
        result.stderr,
        result.error?.message,
      ]
        .filter(Boolean)
        .join("\n")}`,
    );
  }
  const text = result.stdout.trim();
  if (!text) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    if (options.allowFailure) {
      return {};
    }
    throw new Error(
      `Unable to parse JSON from ${commandArgs.join(" ")}: ${text}`,
    );
  }
}

function processGroupProcesses(pgid) {
  if (!Number.isFinite(pgid) || pgid <= 0) {
    return [];
  }
  const result = spawnSync("ps", ["-axo", "pid=,ppid=,pgid=,command="], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    return [];
  }
  return result.stdout
    .split("\n")
    .map((line) => parsePsLine(line))
    .filter((process) => process && process.pgid === pgid);
}

function parsePsLine(line) {
  const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/);
  if (!match) {
    return null;
  }
  return {
    pid: Number(match[1]),
    ppid: Number(match[2]),
    pgid: Number(match[3]),
    command: match[4],
  };
}

function rssMbForPid(pid) {
  const result = spawnSync("ps", ["-o", "rss=", "-p", String(pid)], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return null;
  }
  const rssKb = Number(result.stdout.trim());
  return Number.isFinite(rssKb) ? Number((rssKb / 1024).toFixed(2)) : null;
}

function openFileCountForPid(pid) {
  const result = spawnSync("lsof", ["-nP", "-p", String(pid)], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (result.status !== 0) {
    return null;
  }
  return Math.max(0, result.stdout.split("\n").filter(Boolean).length - 1);
}

function portListeners(port) {
  const result = spawnSync(
    "lsof",
    ["-nP", "-ti", `tcp:${port}`, "-sTCP:LISTEN"],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    },
  );
  if (result.status !== 0 || !result.stdout.trim()) {
    return [];
  }
  return result.stdout.trim().split(/\s+/).filter(Boolean);
}

function killPortListeners(port) {
  for (const pid of portListeners(port)) {
    if (pid !== String(process.pid)) {
      spawnSync("kill", ["-TERM", pid], { stdio: "ignore" });
    }
  }
}

function terminateProcessGroup(pgid) {
  if (!Number.isFinite(pgid) || pgid <= 0) {
    return;
  }
  spawnSync("kill", ["-TERM", "--", `-${pgid}`], { stdio: "ignore" });
  spawnSync("kill", ["-TERM", String(pgid)], { stdio: "ignore" });
}

function parseArgs(values) {
  const parsed = {};
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (!value.startsWith("--")) {
      continue;
    }
    const [rawKey, inlineValue] = value.slice(2).split("=", 2);
    if (inlineValue != null) {
      parsed[rawKey] = inlineValue;
    } else if (values[index + 1] && !values[index + 1].startsWith("--")) {
      parsed[rawKey] = values[index + 1];
      index += 1;
    } else {
      parsed[rawKey] = "true";
    }
  }
  return parsed;
}

function optionalInt(value) {
  if (value == null || value === "") {
    return null;
  }
  const parsed = Number.parseInt(String(value), 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function positiveInt(value, fallback) {
  const parsed = optionalInt(value);
  return parsed && parsed > 0 ? parsed : fallback;
}

function booleanArg(value) {
  if (value == null) {
    return false;
  }
  const normalized = String(value).trim().toLowerCase();
  return ["1", "true", "yes", "on"].includes(normalized);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
