#!/usr/bin/env node
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { selectIntegrationSimulator } from "./simulator-selection.mjs";

const root = path.resolve(new URL("../..", import.meta.url).pathname);
const simdeck = path.join(root, "build", "simdeck");
const tempRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), "simdeck-webkit-camera-it-"),
);
const executable = "SimDeckWebKitCameraFixture";
const bundleId = "dev.nativescript.simdeck.integration.webkit-camera";
const minimumIosVersion = "15.0";
const serverUrl = new URL(
  process.env.SIMDECK_SERVER_URL ?? "http://127.0.0.1:4310",
);
const commandTimeoutMs = Number(
  process.env.SIMDECK_INTEGRATION_SIMCTL_TIMEOUT_MS ?? "300000",
);
const externalCameraOverrideResponseId = 8_000_000_000_000_000;
const keepSimulator = process.env.SIMDECK_INTEGRATION_KEEP_SIMULATOR === "1";
const verbose = process.env.SIMDECK_INTEGRATION_VERBOSE === "1";

let simulatorUDID = "";
let inspectorSocket = null;
let webServer = null;
const browserEvents = [];

process.on("SIGINT", () => {
  cleanup();
  process.exit(130);
});
process.on("SIGTERM", () => {
  cleanup();
  process.exit(143);
});
process.on("exit", cleanup);

main()
  .then(() => {
    cleanup();
    console.log("SimDeck WebKit camera integration suite passed");
    process.exit(0);
  })
  .catch((error) => {
    console.error(error?.stack ?? error);
    cleanup();
    process.exit(1);
  });

async function main() {
  if (process.platform !== "darwin") {
    throw new Error("SimDeck WebKit camera integration tests require macOS.");
  }
  if (!fs.existsSync(simdeck)) {
    throw new Error(`Missing ${simdeck}. Run npm run build:cli first.`);
  }

  const fixtureUrl = await startWebServer();
  step("select simulator runtime");
  const { runtime, deviceType, sdkVersion } = selectIntegrationSimulator({
    runJson,
    runText,
    timeoutMs: commandTimeoutMs,
    env: {
      ...process.env,
      SIMDECK_INTEGRATION_IOS_RUNTIME:
        process.env.SIMDECK_INTEGRATION_IOS_RUNTIME ?? "18.5",
    },
  });
  simulatorUDID = runText("xcrun", [
    "simctl",
    "create",
    `SimDeck WebKit Camera ${Date.now()}`,
    deviceType.identifier,
    runtime.identifier,
  ]).trim();
  console.log(
    `created ${simulatorUDID} (${deviceType.name}, ${runtime.version}; iphonesimulator SDK ${sdkVersion})`,
  );

  step("boot simulator with camera injection");
  runText("xcrun", ["simctl", "boot", simulatorUDID], {
    allowFailure: true,
  });
  runText("xcrun", ["simctl", "bootstatus", simulatorUDID, "-b"], {
    timeoutMs: 600_000,
  });
  simdeckJson(["boot", simulatorUDID]);
  simdeckJson([
    "camera",
    "switch",
    simulatorUDID,
    "--placeholder",
    "--mirror",
    "off",
  ]);

  step("build and launch SFSafariViewController fixture");
  const appPath = buildFixtureApp(fixtureUrl);
  await retryRunText("xcrun", ["simctl", "install", simulatorUDID, appPath], {
    attempts: 3,
    delayMs: 2_000,
  });
  simdeckJson(["launch", simulatorUDID, bundleId]);

  step("attach external Web Inspector before camera capture");
  const target = await waitForWebKitTarget(fixtureUrl);
  const inspector = await attachInspector(target.webSocketUrl);
  inspectorSocket = inspector.socket;

  step("run permission-probe, stop, enumerate, environment capture");
  startBrowserCapture(inspector);
  await allowCameraPermissionIfRequested();
  const environmentEvent = await waitForBrowserEvent(
    "environment-open",
    45_000,
  );
  await waitForBrowserEvent("video-frame", 15_000);

  const eventNames = browserEvents.map((event) => event.name);
  for (const required of ["probe-open", "probe-stopped", "devices"]) {
    if (!eventNames.includes(required)) {
      throw new Error(
        `Missing ${required} in browser lifecycle: ${JSON.stringify(browserEvents)}`,
      );
    }
  }

  const status = await waitForCameraStatus(
    (value) => value.activeConsumers > 0 && value.deliveredFrames > 0,
    15_000,
  );
  if (environmentEvent.settings?.facingMode !== "environment") {
    throw new Error(
      `WebKit did not select an environment camera: ${JSON.stringify(environmentEvent)}`,
    );
  }
  console.log(
    `WebKit camera lifecycle: ${JSON.stringify({ events: eventNames, environment: environmentEvent.settings, activeConsumers: status.activeConsumers, deliveredFrames: status.deliveredFrames })}`,
  );
}

async function startWebServer() {
  webServer = http.createServer((request, response) => {
    if (request.method === "POST" && request.url === "/event") {
      let body = "";
      request.setEncoding("utf8");
      request.on("data", (chunk) => {
        body += chunk;
      });
      request.on("end", () => {
        try {
          const event = JSON.parse(body);
          browserEvents.push({ ...event, receivedAt: Date.now() });
          if (verbose) {
            console.log(`[webkit-camera-page] ${JSON.stringify(event)}`);
          }
          response.writeHead(204).end();
        } catch (error) {
          response.writeHead(400).end(String(error));
        }
      });
      return;
    }
    if (request.method === "GET" && request.url === "/") {
      response.writeHead(200, {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
      });
      response.end(cameraFixturePage());
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise((resolve, reject) => {
    webServer.once("error", reject);
    webServer.listen(0, "127.0.0.1", resolve);
  });
  const address = webServer.address();
  return `http://127.0.0.1:${address.port}/`;
}

function cameraFixturePage() {
  return `<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SimDeck WebKit Camera</title>
</head>
<body>
  <button id="start" style="font-size: 28px; padding: 24px">Start camera</button>
  <video id="preview" autoplay muted playsinline style="width: 100%"></video>
  <script>
    const report = (name, detail = {}) => fetch('/event', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name, ...detail, at: Date.now() }),
    });
    const trackDetails = (track) => ({
      label: track.label,
      settings: track.getSettings ? track.getSettings() : {},
      capabilities: track.getCapabilities ? track.getCapabilities() : {},
    });
    document.querySelector('#start').addEventListener('click', async () => {
      document.querySelector('#start').disabled = true;
      try {
        await report('started', { secureContext: window.isSecureContext });
        const probe = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        await report('probe-open', trackDetails(probe.getVideoTracks()[0]));
        probe.getTracks().forEach((track) => track.stop());
        await report('probe-stopped');
        const devices = await navigator.mediaDevices.enumerateDevices();
        await report('devices', {
          devices: devices.map(({ deviceId, kind, label }) => ({ deviceId, kind, label })),
        });
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { width: 1280, height: 720, frameRate: 30, facingMode: 'environment' },
          audio: false,
        });
        const track = stream.getVideoTracks()[0];
        await report('environment-open', trackDetails(track));
        const preview = document.querySelector('#preview');
        preview.srcObject = stream;
        await preview.play();
        if (preview.requestVideoFrameCallback) {
          preview.requestVideoFrameCallback(() => report('video-frame', {
            width: preview.videoWidth,
            height: preview.videoHeight,
          }));
        } else {
          preview.addEventListener('loadeddata', () => report('video-frame', {
            width: preview.videoWidth,
            height: preview.videoHeight,
          }), { once: true });
        }
      } catch (error) {
        await report('error', { errorName: error.name, message: error.message });
      }
    });
  </script>
</body>
</html>`;
}

async function waitForWebKitTarget(fixtureUrl) {
  const deadline = Date.now() + 30_000;
  let discovery = null;
  while (Date.now() < deadline) {
    const url = new URL(
      `/api/simulators/${encodeURIComponent(simulatorUDID)}/webkit/targets`,
      serverUrl,
    );
    const response = await fetch(url);
    if (response.ok) {
      discovery = await response.json();
      const target = discovery.targets?.find((candidate) =>
        candidate.url?.startsWith(fixtureUrl),
      );
      if (target) {
        return target;
      }
    }
    await sleep(250);
  }
  throw new Error(
    `Timed out waiting for SFSafariViewController target: ${JSON.stringify(discovery)}`,
  );
}

async function attachInspector(webSocketUrl) {
  const url = new URL(webSocketUrl, serverUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const socket = new WebSocket(url);
  const receivedMethods = [];
  const opened = new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Timed out attaching Web Inspector.")),
      15_000,
    );
    socket.addEventListener(
      "open",
      () => {
        clearTimeout(timeout);
        resolve();
      },
      { once: true },
    );
    socket.addEventListener("error", reject, { once: true });
  });
  const pageTargetCreated = new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("Web Inspector did not expose its page target.")),
      15_000,
    );
    const onMessage = (event) => {
      const message = JSON.parse(event.data);
      receivedMethods.push(message.method ?? `response:${message.id}`);
      const targetId =
        message.method === "Target.targetCreated"
          ? message.params.targetInfo.targetId
          : message.id === externalCameraOverrideResponseId && !message.error
            ? null
            : undefined;
      if (targetId === undefined) {
        return;
      }
      clearTimeout(timeout);
      socket.removeEventListener("message", onMessage);
      resolve(targetId);
    };
    socket.addEventListener("message", onMessage);
  });
  let targetId;
  try {
    [, targetId] = await Promise.all([opened, pageTargetCreated]);
  } catch (error) {
    throw new Error(
      `${error.message} Received: ${JSON.stringify(receivedMethods)}`,
    );
  }
  return { socket, targetId };
}

function startBrowserCapture(inspector) {
  const evaluation = {
    id: 2,
    method: "Runtime.evaluate",
    params: {
      expression: "document.querySelector('#start').click()",
      emulateUserGesture: true,
      awaitPromise: true,
      returnByValue: true,
    },
  };
  inspector.socket.send(
    JSON.stringify(
      inspector.targetId
        ? {
            id: 1,
            method: "Target.sendMessageToTarget",
            params: {
              targetId: inspector.targetId,
              message: JSON.stringify(evaluation),
            },
          }
        : evaluation,
    ),
  );
}

async function allowCameraPermissionIfRequested() {
  for (let attempt = 0; attempt < 10; attempt += 1) {
    if (browserEvents.some((event) => event.name === "probe-open")) {
      return;
    }
    runText(
      simdeck,
      ["tap", simulatorUDID, "--label", "Allow", "--wait-timeout-ms", "1000"],
      { allowFailure: true, timeoutMs: 5_000 },
    );
    await sleep(500);
  }
}

async function waitForBrowserEvent(name, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const error = browserEvents.find((event) => event.name === "error");
    if (error) {
      throw new Error(`WebKit camera page failed: ${JSON.stringify(error)}`);
    }
    const event = browserEvents.find((candidate) => candidate.name === name);
    if (event) {
      return event;
    }
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for browser event ${name}: ${JSON.stringify(browserEvents)}`,
  );
}

async function waitForCameraStatus(predicate, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let status = null;
  while (Date.now() < deadline) {
    status = simdeckJson(["camera", "status", simulatorUDID]);
    if (predicate(status)) {
      return status;
    }
    await sleep(100);
  }
  throw new Error(
    `Timed out waiting for WebKit camera demand: ${JSON.stringify(status)}`,
  );
}

function buildFixtureApp(fixtureUrl) {
  const targetArch = process.arch === "arm64" ? "arm64" : "x86_64";
  const appPath = path.join(tempRoot, `${executable}.app`);
  const sourcePath = path.join(tempRoot, `${executable}.m`);
  fs.mkdirSync(appPath, { recursive: true });
  fs.writeFileSync(path.join(appPath, "Info.plist"), fixtureInfoPlist());
  fs.writeFileSync(sourcePath, fixtureSource(fixtureUrl));
  runText("xcrun", [
    "--sdk",
    "iphonesimulator",
    "clang",
    "-target",
    `${targetArch}-apple-ios${minimumIosVersion}-simulator`,
    "-fobjc-arc",
    "-fmodules",
    "-framework",
    "Foundation",
    "-framework",
    "SafariServices",
    "-framework",
    "UIKit",
    sourcePath,
    "-o",
    path.join(appPath, executable),
  ]);
  return appPath;
}

function fixtureInfoPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>${executable}</string>
  <key>CFBundleIdentifier</key><string>${bundleId}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${executable}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>${minimumIosVersion}</string>
  <key>NSCameraUsageDescription</key><string>Validate SimDeck WebKit camera capture.</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key><dict>
      <key>UIWindowSceneSessionRoleApplication</key><array><dict>
        <key>UISceneConfigurationName</key><string>Default Configuration</string>
        <key>UISceneDelegateClassName</key><string>SceneDelegate</string>
      </dict></array>
    </dict>
  </dict>
</dict></plist>`;
}

function fixtureSource(fixtureUrl) {
  return `#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>

@interface FixtureViewController : UIViewController
@property (nonatomic) BOOL presentedFixture;
@end

@implementation FixtureViewController
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.presentedFixture) return;
  self.presentedFixture = YES;
  NSURL *url = [NSURL URLWithString:@"${fixtureUrl}"];
  SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
  safari.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:safari animated:NO completion:nil];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene
willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions {
  (void)session;
  (void)connectionOptions;
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.rootViewController = [[FixtureViewController alloc] init];
  [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  (void)application;
  (void)options;
  return YES;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
  }
}`;
}

function simdeckJson(args, options = {}) {
  return JSON.parse(runText(simdeck, args, options));
}

function runJson(command, args, options = {}) {
  return JSON.parse(runText(command, args, options));
}

function runText(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      SIMDECK_SERVER_URL: serverUrl.toString(),
    },
    timeout: options.timeoutMs ?? commandTimeoutMs,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(
      `${command} ${args.join(" ")} failed with status ${result.status}: ${[
        result.stderr,
        result.stdout,
      ]
        .filter(Boolean)
        .join("\n")}`,
    );
  }
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  if (verbose && output.trim()) {
    process.stderr.write(output);
  }
  return result.stdout ?? "";
}

async function retryRunText(command, args, options) {
  let lastError;
  for (let attempt = 1; attempt <= options.attempts; attempt += 1) {
    try {
      return runText(command, args, options);
    } catch (error) {
      lastError = error;
      if (attempt < options.attempts) {
        await sleep(options.delayMs);
      }
    }
  }
  throw lastError;
}

function cleanup() {
  if (inspectorSocket) {
    inspectorSocket.close();
    inspectorSocket = null;
  }
  if (webServer) {
    webServer.close();
    webServer = null;
  }
  if (simulatorUDID) {
    try {
      simdeckJson(["camera", "stop", simulatorUDID], { timeoutMs: 30_000 });
    } catch {}
    if (!keepSimulator) {
      try {
        simdeckJson(["shutdown", simulatorUDID], { timeoutMs: 120_000 });
      } catch {}
      try {
        runText("xcrun", ["simctl", "shutdown", simulatorUDID], {
          allowFailure: true,
          timeoutMs: 120_000,
        });
      } catch {}
      try {
        runText("xcrun", ["simctl", "delete", simulatorUDID], {
          allowFailure: true,
          timeoutMs: 120_000,
        });
      } catch {}
    }
    simulatorUDID = "";
  }
  if (!keepSimulator) {
    try {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    } catch {}
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function step(label) {
  console.log(`[webkit-camera-it] ${label}`);
}
