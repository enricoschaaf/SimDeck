export interface CameraDevice {
  id: string;
  name: string;
}

export interface CameraFeed {
  stop(): void;
}

export interface CameraStats {
  bitrate: number;
  bufferedBytes: number;
  codec: string;
  encodedFramesPerSecond: number;
  inputHeight: number;
  inputWidth: number;
  outputHeight: number;
  outputWidth: number;
  skippedFrames: number;
}

export interface CameraFrameLayout {
  outputHeight: number;
  outputWidth: number;
  sourceHeight: number;
  sourceWidth: number;
  sourceX: number;
  sourceY: number;
}

interface EncodedChunk {
  readonly byteLength: number;
  readonly type: "delta" | "key";
  copyTo(destination: AllowSharedBufferSource): void;
}

interface CameraTrackProcessor {
  readable: ReadableStream<VideoFrame>;
}

interface CameraTrackProcessorConstructor {
  new (options: { track: MediaStreamTrack }): CameraTrackProcessor;
}

const IDENTITY_WIDTH = 960;
const IDENTITY_HEIGHT = 720;
const FRAMES_PER_SECOND = 30;
const MAX_BUFFERED_BYTES = 128 * 1024;
const KEYFRAME_INTERVAL = FRAMES_PER_SECOND * 5;
const STATS_WINDOW_MS = 3_000;

export function cameraVideoConstraints(
  deviceId: string,
): MediaTrackConstraints {
  return {
    ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
    width: { ideal: IDENTITY_WIDTH },
    height: { ideal: IDENTITY_HEIGHT },
    aspectRatio: { ideal: IDENTITY_WIDTH / IDENTITY_HEIGHT },
    frameRate: { ideal: FRAMES_PER_SECOND, max: FRAMES_PER_SECOND },
    resizeMode: "crop-and-scale",
  } as MediaTrackConstraints & { resizeMode: "crop-and-scale" };
}

export function videoDevices(
  devices: Array<Pick<MediaDeviceInfo, "deviceId" | "kind" | "label">>,
): CameraDevice[] {
  let cameraIndex = 0;
  return devices.flatMap((device) => {
    if (device.kind !== "videoinput") {
      return [];
    }
    cameraIndex += 1;
    return [
      {
        id: device.deviceId,
        name: device.label || `Camera ${cameraIndex}`,
      },
    ];
  });
}

export function cameraFrameLayout(
  sourceWidth: number,
  sourceHeight: number,
): CameraFrameLayout {
  const width = Math.max(2, sourceWidth || IDENTITY_WIDTH);
  const height = Math.max(2, sourceHeight || IDENTITY_HEIGHT);
  const evenDimension = (value: number) =>
    Math.max(2, Math.floor(value / 2) * 2);
  const evenOffset = (value: number) => Math.max(0, Math.floor(value / 2) * 2);
  const targetAspectRatio = IDENTITY_WIDTH / IDENTITY_HEIGHT;
  const sourceAspectRatio = width / height;
  const croppedWidth =
    sourceAspectRatio > targetAspectRatio
      ? evenDimension(height * targetAspectRatio)
      : evenDimension(width);
  const croppedHeight =
    sourceAspectRatio > targetAspectRatio
      ? evenDimension(height)
      : evenDimension(width / targetAspectRatio);
  const scale = Math.min(
    1,
    IDENTITY_WIDTH / croppedWidth,
    IDENTITY_HEIGHT / croppedHeight,
  );
  return {
    sourceX: evenOffset((width - croppedWidth) / 2),
    sourceY: evenOffset((height - croppedHeight) / 2),
    sourceWidth: croppedWidth,
    sourceHeight: croppedHeight,
    outputWidth: evenDimension(croppedWidth * scale),
    outputHeight: evenDimension(croppedHeight * scale),
  };
}

export function cameraCanEncodeDirectly(layout: CameraFrameLayout): boolean {
  return (
    layout.sourceX === 0 &&
    layout.sourceY === 0 &&
    layout.sourceWidth === layout.outputWidth &&
    layout.sourceHeight === layout.outputHeight
  );
}

export function cameraShouldEncodeKeyFrame(
  frameIndex: number,
  keyFrameRequired: boolean,
): boolean {
  return keyFrameRequired || frameIndex % KEYFRAME_INTERVAL === 0;
}

export function cameraH264ConfigPacket(
  description: AllowSharedBufferSource,
): ArrayBuffer {
  const bytes = ArrayBuffer.isView(description)
    ? new Uint8Array(
        description.buffer,
        description.byteOffset,
        description.byteLength,
      )
    : new Uint8Array(description);
  const packet = new Uint8Array(1 + bytes.byteLength);
  packet[0] = 1;
  packet.set(bytes, 1);
  return packet.buffer;
}

export function cameraH264FramePacket(
  chunk: EncodedChunk,
  sequence: number,
): ArrayBuffer {
  const packet = new Uint8Array(6 + chunk.byteLength);
  packet[0] = 2;
  packet[1] = chunk.type === "key" ? 1 : 0;
  new DataView(packet.buffer).setUint32(2, sequence >>> 0);
  chunk.copyTo(packet.subarray(6));
  return packet.buffer;
}

function encoderConfig(width: number, height: number): VideoEncoderConfig {
  const bitrate =
    width * height >= IDENTITY_WIDTH * IDENTITY_HEIGHT ? 4_000_000 : 2_500_000;
  return {
    width,
    height,
    bitrate,
    framerate: FRAMES_PER_SECOND,
    bitrateMode: "variable",
    hardwareAcceleration: "prefer-hardware",
    latencyMode: "realtime",
    avc: { format: "avc" },
    codec: "avc1.42E01F",
  };
}

function mediaStreamTrackProcessor(): CameraTrackProcessorConstructor | null {
  return (
    (
      globalThis as typeof globalThis & {
        MediaStreamTrackProcessor?: CameraTrackProcessorConstructor;
      }
    ).MediaStreamTrackProcessor ?? null
  );
}

function waitForVideo(video: HTMLVideoElement): Promise<void> {
  if (video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      cleanup();
      reject(new Error("Camera did not produce video within 5 seconds."));
    }, 5_000);
    const onReady = () => {
      cleanup();
      resolve();
    };
    const onError = () => {
      cleanup();
      reject(new Error("Camera did not produce video."));
    };
    const cleanup = () => {
      window.clearTimeout(timeout);
      video.removeEventListener("loadeddata", onReady);
      video.removeEventListener("error", onError);
    };
    video.addEventListener("loadeddata", onReady, { once: true });
    video.addEventListener("error", onError, { once: true });
  });
}

function eventText(data: unknown): Promise<string> {
  if (typeof data === "string") {
    return Promise.resolve(data);
  }
  if (data instanceof Blob) {
    return data.text();
  }
  if (data instanceof ArrayBuffer) {
    return Promise.resolve(new TextDecoder().decode(data));
  }
  return Promise.resolve("");
}

async function openSocket(url: string): Promise<WebSocket> {
  const socket = new WebSocket(url);
  socket.binaryType = "arraybuffer";
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const timeout = window.setTimeout(() => {
      settle(new Error("Camera connection timed out."));
    }, 5_000);
    const settle = (error?: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      window.clearTimeout(timeout);
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    };
    socket.onerror = () => settle(new Error("Camera connection failed."));
    socket.onclose = () => settle(new Error("Camera connection closed."));
    socket.onmessage = (event) => {
      void eventText(event.data).then((text) => {
        try {
          const reply = JSON.parse(text) as { error?: string; ready?: boolean };
          if (reply.error) {
            settle(new Error(reply.error));
          } else if (reply.ready) {
            settle();
          }
        } catch {
          return;
        }
      });
    };
  });
  return socket;
}

export async function startCameraFeed({
  onError,
  onStats,
  socketUrl,
  stream,
}: {
  onError: (message: string) => void;
  onStats?: (stats: CameraStats) => void;
  socketUrl: string;
  stream: MediaStream;
}): Promise<CameraFeed> {
  if (
    typeof VideoEncoder === "undefined" ||
    typeof VideoFrame === "undefined"
  ) {
    throw new Error(
      "This browser does not support real-time H.264 camera streaming.",
    );
  }
  const video = document.createElement("video");
  video.muted = true;
  video.playsInline = true;
  video.style.cssText =
    "position:fixed;width:1px;height:1px;opacity:0;pointer-events:none";
  document.body.append(video);
  video.srcObject = stream;
  const releaseVideo = () => {
    video.pause();
    video.srcObject = null;
    video.remove();
  };
  try {
    await video.play();
    await waitForVideo(video);
  } catch (error) {
    releaseVideo();
    throw error;
  }

  const inputWidth = video.videoWidth || 640;
  const inputHeight = video.videoHeight || 480;
  const layout = cameraFrameLayout(inputWidth, inputHeight);
  const directFrames = cameraCanEncodeDirectly(layout);
  const canvas = document.createElement("canvas");
  canvas.width = layout.outputWidth;
  canvas.height = layout.outputHeight;
  const context = directFrames
    ? null
    : canvas.getContext("2d", { alpha: false });
  if (!directFrames && !context) {
    releaseVideo();
    throw new Error("Camera canvas is unavailable.");
  }

  const requestedConfig = encoderConfig(canvas.width, canvas.height);
  const support = await VideoEncoder.isConfigSupported(requestedConfig).catch(
    () => null,
  );
  if (!support?.supported) {
    releaseVideo();
    throw new Error("This browser cannot encode the camera as H.264 Baseline.");
  }
  const activeConfig = support.config ?? requestedConfig;
  let socket: WebSocket;
  try {
    socket = await openSocket(socketUrl);
  } catch (error) {
    releaseVideo();
    throw error;
  }

  let stopped = false;
  let keyFrameRequired = true;
  let frameIndex = 0;
  let timestamp = 0;
  let encodedSequence = 0;
  let skippedFrames = 0;
  const encodedFrameTimes: number[] = [];
  const startedAt = performance.now();
  socket.onmessage = (event) => {
    void eventText(event.data).then((text) => {
      try {
        const reply = JSON.parse(text) as {
          error?: string;
          keyFrameRequired?: boolean;
        };
        if (reply.keyFrameRequired) {
          keyFrameRequired = true;
        }
        if (reply.error && !stopped) {
          onError(reply.error);
        }
      } catch {
        return;
      }
    });
  };
  socket.onclose = () => {
    if (!stopped) {
      onError("Camera connection closed.");
    }
  };

  const encoder = new VideoEncoder({
    output(chunk, metadata) {
      if (stopped) {
        return;
      }
      try {
        const description = metadata?.decoderConfig?.description;
        if (description) {
          socket.send(cameraH264ConfigPacket(description));
        }
        socket.send(cameraH264FramePacket(chunk, encodedSequence));
        encodedSequence += 1;
        encodedFrameTimes.push(performance.now());
      } catch (error) {
        onError(error instanceof Error ? error.message : String(error));
      }
    },
    error(error) {
      if (!stopped) {
        onError(`Camera H.264 encoder failed: ${error.message}`);
      }
    },
  });
  encoder.configure(activeConfig);

  const encodeFrame = (sourceFrame?: VideoFrame) => {
    if (
      stopped ||
      socket.bufferedAmount > MAX_BUFFERED_BYTES ||
      encoder.encodeQueueSize > 1 ||
      (!sourceFrame && video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA)
    ) {
      skippedFrames += 1;
      return;
    }
    try {
      let frame = sourceFrame;
      let ownsFrame = false;
      if (!frame && directFrames) {
        frame = new VideoFrame(video, { timestamp });
        ownsFrame = true;
      } else if (!frame) {
        context!.drawImage(
          video,
          layout.sourceX,
          layout.sourceY,
          layout.sourceWidth,
          layout.sourceHeight,
          0,
          0,
          canvas.width,
          canvas.height,
        );
        frame = new VideoFrame(canvas, { timestamp });
        ownsFrame = true;
      }
      const keyFrame = cameraShouldEncodeKeyFrame(frameIndex, keyFrameRequired);
      encoder.encode(frame, { keyFrame });
      if (ownsFrame) {
        frame.close();
      }
      keyFrameRequired = false;
      frameIndex += 1;
      timestamp += Math.round(1_000_000 / FRAMES_PER_SECOND);
    } catch (error) {
      onError(error instanceof Error ? error.message : String(error));
    }
  };

  const Processor = directFrames ? mediaStreamTrackProcessor() : null;
  const videoTrack = stream.getVideoTracks()[0];
  let stopFrameLoop: () => void;
  if (Processor && videoTrack) {
    const reader = new Processor({ track: videoTrack }).readable.getReader();
    let cancelled = false;
    void (async () => {
      try {
        while (!cancelled) {
          const { done, value: frame } = await reader.read();
          if (done || !frame) {
            break;
          }
          try {
            encodeFrame(frame);
          } finally {
            frame.close();
          }
        }
      } catch (error) {
        if (!cancelled) {
          onError(error instanceof Error ? error.message : String(error));
        }
      }
    })();
    stopFrameLoop = () => {
      cancelled = true;
      void reader.cancel().catch(() => undefined);
    };
  } else {
    let callbackId = 0;
    let lastFrameAt = Number.NEGATIVE_INFINITY;
    const onFrame: VideoFrameRequestCallback = (now) => {
      if (stopped) {
        return;
      }
      if (now - lastFrameAt >= 1_000 / FRAMES_PER_SECOND - 1) {
        lastFrameAt = now;
        encodeFrame();
      }
      callbackId = video.requestVideoFrameCallback(onFrame);
    };
    callbackId = video.requestVideoFrameCallback(onFrame);
    stopFrameLoop = () => video.cancelVideoFrameCallback(callbackId);
  }

  const statsTimer = window.setInterval(() => {
    const now = performance.now();
    const cutoff = now - STATS_WINDOW_MS;
    while (
      encodedFrameTimes[0] !== undefined &&
      encodedFrameTimes[0] < cutoff
    ) {
      encodedFrameTimes.shift();
    }
    const observedFor = Math.max(1_000, now - Math.max(startedAt, cutoff));
    onStats?.({
      inputWidth,
      inputHeight,
      outputWidth: canvas.width,
      outputHeight: canvas.height,
      bitrate: activeConfig.bitrate ?? 0,
      codec: activeConfig.codec,
      encodedFramesPerSecond: Math.round(
        (encodedFrameTimes.length * 1_000) / observedFor,
      ),
      skippedFrames,
      bufferedBytes: socket.bufferedAmount,
    });
    skippedFrames = 0;
  }, 1_000);

  return {
    stop() {
      if (stopped) {
        return;
      }
      stopped = true;
      window.clearInterval(statsTimer);
      stopFrameLoop();
      encoder.close();
      if (
        socket.readyState === WebSocket.CONNECTING ||
        socket.readyState === WebSocket.OPEN
      ) {
        socket.close();
      }
      video.pause();
      video.srcObject = null;
    },
  };
}
