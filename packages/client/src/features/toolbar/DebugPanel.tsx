import type { CameraStatusResponse, EncoderStats } from "../../api/types";
import type {
  StreamRuntimeInfo,
  StreamStats,
  StreamStatus,
} from "../stream/streamTypes";

interface DebugPanelProps {
  camera?: CameraStatusResponse | null;
  encoder?: EncoderStats | null;
  fps: number;
  inline?: boolean;
  onClose?: () => void;
  runtimeInfo: StreamRuntimeInfo;
  stats: StreamStats;
  status: StreamStatus;
}

function formatFps(value: number): string {
  if (!Number.isFinite(value)) {
    return "0.0";
  }
  return value.toFixed(1);
}

function formatMs(value: number): string {
  if (!Number.isFinite(value) || value <= 0) {
    return "—";
  }
  return `${value.toFixed(1)} ms`;
}

function formatUsAsMs(value: number | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return "—";
  }
  return `${(value / 1000).toFixed(1)} ms`;
}

function formatPercent(value: number | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return "—";
  }
  return `${value.toFixed(0)}%`;
}

function formatBitrate(value: number | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return "—";
  }
  return `${(value / 1_000_000).toFixed(1)} Mbps`;
}

function formatCameraResolution(camera: CameraStatusResponse): string {
  const browser = camera.webRtcCamera?.browser;
  const width = browser?.outputWidth ?? camera.width;
  const height = browser?.outputHeight ?? camera.height;
  return width && height ? `${width}×${height}` : "—";
}

function formatResolution(stats: StreamStats): string {
  if (!stats.width || !stats.height) {
    return "—";
  }
  return `${stats.width}×${stats.height}`;
}

export function DebugPanel({
  camera,
  encoder,
  fps,
  inline = false,
  onClose,
  runtimeInfo,
  stats,
  status,
}: DebugPanelProps) {
  const rows: Array<{ label: string; value: string }> = [
    { label: "State", value: status.state },
    { label: "FPS", value: formatFps(fps) },
    { label: "Resolution", value: formatResolution(stats) },
    { label: "Packets", value: String(stats.receivedPackets) },
    { label: "Packet Loss", value: String(stats.packetsLost) },
    { label: "Decode Drops", value: String(stats.decoderDroppedFrames) },
    { label: "Present Drops", value: String(stats.presentationDroppedFrames) },
    { label: "Reconnects", value: String(stats.reconnects) },
    { label: "Reconnect Reason", value: stats.reconnectReason || "—" },
    { label: "ICE Restarts", value: String(stats.iceRestarts) },
    { label: "ICE Restart Reason", value: stats.iceRestartReason || "—" },
    { label: "Decoded", value: String(stats.decodedFrames) },
    { label: "Rendered", value: String(stats.renderedFrames) },
    { label: "Render", value: formatMs(stats.latestRenderMs) },
    { label: "Frame Gap", value: formatMs(stats.latestFrameGapMs) },
    { label: "Path", value: runtimeInfo.streamBackend },
  ];
  if (encoder) {
    rows.push(
      { label: "Encoder", value: encoder.encoderMode ?? "—" },
      { label: "Active Encoder", value: encoder.activeEncoderMode ?? "—" },
      {
        label: "Client Foreground",
        value:
          typeof encoder.clientForeground === "boolean"
            ? encoder.clientForeground
              ? "yes"
              : "no"
            : "—",
      },
      {
        label: "Auto HW Slot",
        value:
          typeof encoder.autoHardwareSlot === "boolean"
            ? encoder.autoHardwareSlot
              ? "yes"
              : "no"
            : "—",
      },
      { label: "Encoder State", value: encoder.overloadState ?? "—" },
      {
        label: "Encoder Load",
        value: formatPercent(encoder.averageEncoderLoadPercent),
      },
      {
        label: "Encode Latency",
        value: formatUsAsMs(encoder.averageEncodeLatencyUs),
      },
      { label: "Encode Budget", value: formatUsAsMs(encoder.encoderBudgetUs) },
      { label: "Encoder Reason", value: encoder.overloadReason ?? "—" },
      {
        label: "Overload Events",
        value: String(encoder.overloadEvents ?? 0),
      },
    );
  }
  if (camera?.alive && camera.source === "camera") {
    const browser = camera.webRtcCamera?.browser;
    const cameraDrops =
      (camera.webRtcCamera?.droppedFrames ?? 0) +
      (camera.webRtcCamera?.dependencyDrops ?? 0);
    rows.push(
      { label: "Camera Resolution", value: formatCameraResolution(camera) },
      {
        label: "Camera FPS",
        value: formatFps(browser?.encodedFramesPerSecond ?? 0),
      },
      { label: "Camera Bitrate", value: formatBitrate(browser?.bitrate) },
      {
        label: "Camera Color",
        value:
          [camera.colorRange, camera.yCbCrMatrix].filter(Boolean).join(" / ") ||
          "—",
      },
      {
        label: "Camera Encode",
        value: formatMs(browser?.averageEncodeTimeMs ?? 0),
      },
      {
        label: "Camera Pipeline",
        value: formatMs(camera.averagePipelineLatencyMs ?? 0),
      },
      {
        label: "Camera RTP Loss",
        value: String(camera.webRtcCamera?.lostPackets ?? 0),
      },
      {
        label: "Camera Queue",
        value: String(camera.webRtcCamera?.queueHighWater ?? 0),
      },
      { label: "Camera Drops", value: String(cameraDrops) },
      {
        label: "Camera Copies",
        value: String(camera.fullFrameCopies ?? 0),
      },
      {
        label: "Camera Conversions",
        value: String(
          (camera.geometryConversions ?? 0) + (camera.pixelConversions ?? 0),
        ),
      },
    );
  }

  return (
    <section
      aria-label="Stream debug info"
      className={`debug-panel ${inline ? "debug-panel-inline" : "debug-panel-popover"}`}
    >
      <div className="debug-panel-header">
        <span>Debug Info</span>
        {onClose ? (
          <button
            aria-label="Close debug info"
            className="debug-close"
            onClick={onClose}
            title="Close"
            type="button"
          >
            x
          </button>
        ) : null}
      </div>
      <dl className="debug-grid">
        {rows.map((row) => (
          <div className="debug-row" key={row.label}>
            <dt className="debug-label">{row.label}</dt>
            <dd className="debug-value">{row.value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
