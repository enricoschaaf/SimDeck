import { fetchHealth } from "../../api/client";
import { createCameraWebRtcAnswer } from "../../api/simulators";

export interface CameraDevice {
  id: string;
  name: string;
}

export interface CameraFeed {
  stop(): void;
}

export interface CameraStats {
  averageEncodeTimeMs: number;
  bitrate: number;
  bufferedBytes: number;
  bytesSent: number;
  codec: string;
  encodedFramesPerSecond: number;
  inputHeight: number;
  inputWidth: number;
  jitterMs: number;
  keyFramesEncoded: number;
  outputHeight: number;
  outputWidth: number;
  packetsLost: number;
  packetsSent: number;
  qualityLimitationReason: string;
  roundTripTimeMs: number;
  skippedFrames: number;
}

const FRAMES_PER_SECOND = 30;
const PREFERRED_CAMERA_WIDTH = 1_920;
const PREFERRED_CAMERA_HEIGHT = 1_080;
const STATS_INTERVAL_MS = 1_000;
const ICE_GATHER_TIMEOUT_MS = 3_000;
const CONNECTION_TIMEOUT_MS = 10_000;
const CAMERA_DATA_CHANNEL_LABEL = "simdeck-camera";
type RtpCodecCapability = NonNullable<
  ReturnType<typeof RTCRtpSender.getCapabilities>
>["codecs"][number];

export function cameraVideoConstraints(
  deviceId: string,
): MediaTrackConstraints {
  return {
    ...(deviceId ? { deviceId: { exact: deviceId } } : {}),
    frameRate: { ideal: FRAMES_PER_SECOND, max: FRAMES_PER_SECOND },
    height: { ideal: PREFERRED_CAMERA_HEIGHT },
    width: { ideal: PREFERRED_CAMERA_WIDTH },
  };
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

export function cameraH264Codecs(
  codecs: readonly RtpCodecCapability[],
): RtpCodecCapability[] {
  const h264 = codecs.filter(
    (codec) =>
      codec.mimeType.toLowerCase() === "video/h264" &&
      /(?:^|;)\s*packetization-mode=1(?:;|$)/i.test(codec.sdpFmtpLine ?? ""),
  );
  return h264.sort((left, right) => {
    const profileRank = (codec: RtpCodecCapability) => {
      const profile = /(?:^|;)\s*profile-level-id=([0-9a-f]{2})/i
        .exec(codec.sdpFmtpLine ?? "")?.[1]
        ?.toLowerCase();
      if (profile === "64") return 3;
      if (profile === "4d") return 2;
      if (profile === "42") return 1;
      return 0;
    };
    return profileRank(right) - profileRank(left);
  });
}

export async function startCameraFeed({
  onError,
  onStats,
  signal,
  stream,
  udid,
}: {
  onError: (message: string) => void;
  onStats?: (stats: CameraStats) => void;
  signal?: AbortSignal;
  stream: MediaStream;
  udid: string;
}): Promise<CameraFeed> {
  throwIfCameraFeedAborted(signal);
  const track = stream.getVideoTracks()[0];
  if (!track) {
    throw new Error("The selected camera did not provide a video track.");
  }
  if (typeof RTCPeerConnection === "undefined") {
    throw new Error("This browser does not support WebRTC camera streaming.");
  }
  const capabilities = RTCRtpSender.getCapabilities?.("video")?.codecs ?? [];
  const codecs = cameraH264Codecs(capabilities);
  if (codecs.length === 0) {
    throw new Error(
      "This browser cannot negotiate H.264 camera video over WebRTC.",
    );
  }

  const health = await fetchHealth({ signal }).catch(() => {
    throwIfCameraFeedAborted(signal);
    return null;
  });
  throwIfCameraFeedAborted(signal);
  const peerConnection = new RTCPeerConnection({
    iceServers: health?.webRtc?.iceServers ?? [],
    iceTransportPolicy: health?.webRtc?.iceTransportPolicy ?? "all",
  });
  const controlChannel = peerConnection.createDataChannel(
    CAMERA_DATA_CHANNEL_LABEL,
    { ordered: true },
  );
  let stopped = false;
  let connectionClosed = false;
  const closeConnection = () => {
    if (connectionClosed) {
      return;
    }
    connectionClosed = true;
    controlChannel.close();
    peerConnection.close();
  };
  const onAbort = () => {
    stopped = true;
    closeConnection();
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) {
    onAbort();
  }
  const fail = (message: string) => {
    if (!stopped) {
      onError(message);
    }
  };
  peerConnection.addEventListener("connectionstatechange", () => {
    if (
      peerConnection.connectionState === "failed" ||
      peerConnection.connectionState === "closed"
    ) {
      fail(`Camera WebRTC connection ${peerConnection.connectionState}.`);
    }
  });

  let setup:
    | { inputHeight: number; inputWidth: number; sender: RTCRtpSender }
    | undefined;
  try {
    throwIfCameraFeedAborted(signal);
    const sender = peerConnection.addTrack(track, stream);
    const transceiver = peerConnection
      .getTransceivers()
      .find((candidate) => candidate.sender === sender);
    if (!transceiver?.setCodecPreferences) {
      throw new Error(
        "This browser cannot select H.264 for WebRTC camera streaming.",
      );
    }
    transceiver.setCodecPreferences(codecs);

    const settings = track.getSettings();
    const inputWidth = settings.width ?? 0;
    const inputHeight = settings.height ?? 0;
    const maxBitrate = cameraMaxBitrate(inputWidth, inputHeight);
    const parameters = sender.getParameters();
    if (parameters.encodings.length === 0) {
      parameters.encodings = [{}];
    }
    for (const encoding of parameters.encodings) {
      encoding.maxBitrate = maxBitrate;
      encoding.maxFramerate = Math.min(
        FRAMES_PER_SECOND,
        settings.frameRate ?? FRAMES_PER_SECOND,
      );
    }
    (
      parameters as RTCRtpSendParameters & {
        degradationPreference: "maintain-resolution";
      }
    ).degradationPreference = "maintain-resolution";
    await abortableCameraOperation(
      () => sender.setParameters(parameters),
      signal,
    );

    const offer = await abortableCameraOperation(
      () => peerConnection.createOffer(),
      signal,
    );
    await abortableCameraOperation(
      () => peerConnection.setLocalDescription(offer),
      signal,
    );
    await waitForIceGathering(peerConnection, signal);
    throwIfCameraFeedAborted(signal);
    const localDescription = peerConnection.localDescription;
    if (!localDescription?.sdp) {
      throw new Error("The browser did not create a camera WebRTC offer.");
    }
    if (!/a=rtpmap:\d+ H264\/90000/i.test(localDescription.sdp)) {
      throw new Error("The browser did not offer H.264 camera video.");
    }
    const answer = await abortableCameraOperation(
      () =>
        createCameraWebRtcAnswer(
          udid,
          {
            clientId: crypto.randomUUID(),
            sdp: localDescription.sdp,
            type: "offer",
          },
          { signal },
        ),
      signal,
    );
    await abortableCameraOperation(
      () => peerConnection.setRemoteDescription(answer),
      signal,
    );
    await waitForCameraReady(controlChannel, peerConnection, signal);
    throwIfCameraFeedAborted(signal);
    setup = { inputHeight, inputWidth, sender };
  } catch (error) {
    stopped = true;
    signal?.removeEventListener("abort", onAbort);
    closeConnection();
    if (signal?.aborted) {
      throw cameraFeedAbortError();
    }
    throw error;
  }
  signal?.removeEventListener("abort", onAbort);

  const stats = new CameraStatsReporter(
    setup.sender,
    controlChannel,
    setup.inputWidth,
    setup.inputHeight,
    onStats,
  );
  stats.start();

  return {
    stop() {
      if (stopped) {
        return;
      }
      stopped = true;
      stats.stop();
      if (controlChannel.readyState === "open") {
        controlChannel.send(JSON.stringify({ event: "stopping" }));
      }
      controlChannel.close();
      peerConnection.close();
    },
  };
}

export function cameraMaxBitrate(width: number, height: number): number {
  const pixels = Math.max(640 * 480, width * height);
  return Math.max(4_000_000, Math.min(20_000_000, Math.round(pixels * 8)));
}

async function waitForCameraReady(
  channel: RTCDataChannel,
  peerConnection: RTCPeerConnection,
  signal?: AbortSignal,
): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      window.clearTimeout(timeout);
      channel.removeEventListener("message", onMessage);
      peerConnection.removeEventListener("connectionstatechange", onState);
      signal?.removeEventListener("abort", onAbort);
      error ? reject(error) : resolve();
    };
    const onMessage = (event: MessageEvent) => {
      try {
        const message = JSON.parse(String(event.data)) as {
          error?: string;
          ready?: boolean;
        };
        if (message.error) {
          finish(new Error(message.error));
        } else if (message.ready) {
          finish();
        }
      } catch {
        return;
      }
    };
    const onState = () => {
      if (peerConnection.connectionState === "failed") {
        finish(new Error("Camera WebRTC connection failed."));
      }
    };
    const onAbort = () => finish(cameraFeedAbortError());
    const timeout = window.setTimeout(
      () => finish(new Error("Camera WebRTC connection timed out.")),
      CONNECTION_TIMEOUT_MS,
    );
    channel.addEventListener("message", onMessage);
    peerConnection.addEventListener("connectionstatechange", onState);
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) {
      onAbort();
    }
  });
}

function waitForIceGathering(
  peerConnection: RTCPeerConnection,
  signal?: AbortSignal,
): Promise<void> {
  if (peerConnection.iceGatheringState === "complete") {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    let resolved = false;
    const finish = (error?: Error) => {
      if (resolved) {
        return;
      }
      resolved = true;
      window.clearTimeout(timeout);
      peerConnection.removeEventListener("icecandidate", onCandidate);
      peerConnection.removeEventListener("icegatheringstatechange", onState);
      signal?.removeEventListener("abort", onAbort);
      error ? reject(error) : resolve();
    };
    const onCandidate = (event: RTCPeerConnectionIceEvent) => {
      if (event.candidate?.type === "host") {
        finish();
      }
    };
    const onState = () => {
      if (peerConnection.iceGatheringState === "complete") {
        finish();
      }
    };
    const onAbort = () => finish(cameraFeedAbortError());
    const timeout = window.setTimeout(finish, ICE_GATHER_TIMEOUT_MS);
    peerConnection.addEventListener("icecandidate", onCandidate);
    peerConnection.addEventListener("icegatheringstatechange", onState);
    signal?.addEventListener("abort", onAbort, { once: true });
    if (signal?.aborted) {
      onAbort();
    }
  });
}

export function isCameraFeedAbort(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError";
}

function throwIfCameraFeedAborted(signal?: AbortSignal) {
  if (signal?.aborted) {
    throw cameraFeedAbortError();
  }
}

function abortableCameraOperation<T>(
  start: () => Promise<T>,
  signal?: AbortSignal,
): Promise<T> {
  if (!signal) {
    return start();
  }
  throwIfCameraFeedAborted(signal);
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const finish = (result: { error: unknown } | { value: T }) => {
      if (settled) {
        return;
      }
      settled = true;
      signal.removeEventListener("abort", onAbort);
      "error" in result ? reject(result.error) : resolve(result.value);
    };
    const onAbort = () => finish({ error: cameraFeedAbortError() });
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) {
      onAbort();
      return;
    }
    let operation: Promise<T>;
    try {
      operation = start();
    } catch (error) {
      finish({ error });
      return;
    }
    operation.then(
      (value) => finish({ value }),
      (error: unknown) => finish({ error }),
    );
  });
}

function cameraFeedAbortError(): DOMException {
  return new DOMException("Camera WebRTC setup was cancelled.", "AbortError");
}

class CameraStatsReporter {
  private previousBytes = 0;
  private previousTimestamp = 0;
  private timer = 0;

  constructor(
    private readonly sender: RTCRtpSender,
    private readonly channel: RTCDataChannel,
    private readonly width: number,
    private readonly height: number,
    private readonly onStats?: (stats: CameraStats) => void,
  ) {}

  start() {
    this.timer = window.setInterval(() => {
      void this.report();
    }, STATS_INTERVAL_MS);
  }

  stop() {
    window.clearInterval(this.timer);
  }

  private async report() {
    const report = await this.sender.getStats();
    let codec = "video/H264";
    const outbound = outboundVideoStats(report);
    if (!outbound) {
      return;
    }
    const codecId = String(outbound.codecId ?? "");
    if (codecId) {
      const codecStats = report.get(codecId) as
        | (RTCStats & { mimeType?: string })
        | undefined;
      codec = codecStats?.mimeType ?? codec;
    }
    const bytesSent = Number(outbound.bytesSent ?? 0);
    const timestamp = Number(outbound.timestamp ?? performance.now());
    const elapsed = timestamp - this.previousTimestamp;
    const bitrate =
      this.previousTimestamp > 0 && elapsed > 0
        ? Math.round(((bytesSent - this.previousBytes) * 8_000) / elapsed)
        : 0;
    this.previousBytes = bytesSent;
    this.previousTimestamp = timestamp;
    const framesEncoded = Number(outbound.framesEncoded ?? 0);
    const totalEncodeTime = Number(outbound.totalEncodeTime ?? 0);
    const remoteInbound = remoteInboundVideoStats(report, outbound);
    const roundTripTime = Number(remoteInbound?.roundTripTime ?? 0);
    const roundTripMeasurements = Number(
      remoteInbound?.roundTripTimeMeasurements ?? 0,
    );
    const averageRoundTripTime =
      roundTripTime > 0
        ? roundTripTime
        : roundTripMeasurements > 0
          ? Number(remoteInbound?.totalRoundTripTime ?? 0) /
            roundTripMeasurements
          : 0;
    const stats: CameraStats = {
      averageEncodeTimeMs:
        framesEncoded > 0 ? (totalEncodeTime * 1_000) / framesEncoded : 0,
      bitrate,
      bufferedBytes: this.channel.bufferedAmount,
      bytesSent,
      codec,
      encodedFramesPerSecond: Number(outbound.framesPerSecond ?? 0),
      inputHeight: this.height,
      inputWidth: this.width,
      jitterMs: Number(remoteInbound?.jitter ?? 0) * 1_000,
      keyFramesEncoded: Number(outbound.keyFramesEncoded ?? 0),
      outputHeight: Number(outbound.frameHeight ?? this.height),
      outputWidth: Number(outbound.frameWidth ?? this.width),
      packetsLost: Number(remoteInbound?.packetsLost ?? 0),
      packetsSent: Number(outbound.packetsSent ?? 0),
      qualityLimitationReason: String(
        outbound.qualityLimitationReason ?? "none",
      ),
      roundTripTimeMs: averageRoundTripTime * 1_000,
      skippedFrames: Math.max(
        0,
        framesEncoded - Number(outbound.framesSent ?? framesEncoded),
      ),
    };
    this.onStats?.(stats);
    if (this.channel.readyState === "open") {
      this.channel.send(JSON.stringify({ event: "telemetry", stats }));
    }
  }
}

function remoteInboundVideoStats(
  report: RTCStatsReport,
  outbound: Record<string, unknown>,
): Record<string, unknown> | null {
  const remoteId = String(outbound.remoteId ?? "");
  if (remoteId) {
    const remote = report.get(remoteId) as
      | (RTCStats & Record<string, unknown>)
      | undefined;
    if (remote?.type === "remote-inbound-rtp") {
      return remote;
    }
  }
  let remoteInbound: Record<string, unknown> | null = null;
  report.forEach((entry) => {
    const stats = entry as RTCStats & Record<string, unknown>;
    if (
      stats.type === "remote-inbound-rtp" &&
      (stats.kind === "video" || stats.mediaType === "video")
    ) {
      remoteInbound = stats;
    }
  });
  return remoteInbound;
}

function outboundVideoStats(
  report: RTCStatsReport,
): Record<string, unknown> | null {
  let outbound: Record<string, unknown> | null = null;
  report.forEach((entry) => {
    const stats = entry as RTCStats & Record<string, unknown>;
    if (stats.type === "outbound-rtp" && stats.kind === "video") {
      outbound = stats;
    }
  });
  return outbound;
}
