const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 720;
const DEFAULT_FRAMES_PER_SECOND = 30;
const MARKER_BITS = 48;
const FRAME_BITS = 16;
const TIMESTAMP_BITS = MARKER_BITS - FRAME_BITS;
const TIMESTAMP_MODULUS = 2 ** TIMESTAMP_BITS;

export interface CameraBenchmarkSource {
  readonly framesPerSecond: number;
  readonly height: number;
  readonly stream: MediaStream;
  readonly width: number;
  snapshot(): CameraBenchmarkSnapshot;
  stop(): void;
}

export interface CameraBenchmarkSnapshot {
  frame: number;
  generatedAt: number;
  timestamp: number;
}

export interface CameraBenchmarkOptions {
  framesPerSecond?: number;
  height?: number;
  width?: number;
}

export function createCameraBenchmarkSource(
  options: CameraBenchmarkOptions = {},
): CameraBenchmarkSource {
  const width = evenDimension(options.width ?? DEFAULT_WIDTH);
  const height = evenDimension(options.height ?? DEFAULT_HEIGHT);
  const framesPerSecond = Math.max(
    1,
    Math.min(
      60,
      Math.round(options.framesPerSecond ?? DEFAULT_FRAMES_PER_SECOND),
    ),
  );
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) {
    throw new Error("Camera benchmark canvas is unavailable.");
  }

  let frame = 0;
  let generatedAt = performance.now();
  let timestamp = Math.floor(generatedAt) % TIMESTAMP_MODULUS;
  const draw = () => {
    generatedAt = performance.now();
    timestamp = Math.floor(generatedAt) % TIMESTAMP_MODULUS;
    drawCameraBenchmarkFrame(context, width, height, frame, timestamp);
    frame = (frame + 1) % 2 ** FRAME_BITS;
  };
  draw();
  const timer = window.setInterval(draw, 1_000 / framesPerSecond);
  const stream = canvas.captureStream(framesPerSecond);

  return {
    framesPerSecond,
    height,
    stream,
    width,
    snapshot: () => ({
      frame: (frame - 1 + 2 ** FRAME_BITS) % 2 ** FRAME_BITS,
      generatedAt,
      timestamp,
    }),
    stop() {
      window.clearInterval(timer);
      for (const track of stream.getTracks()) {
        track.stop();
      }
    },
  };
}

export function drawCameraBenchmarkFrame(
  context: CanvasRenderingContext2D,
  width: number,
  height: number,
  frame: number,
  timestamp: number,
) {
  context.fillStyle = "#20242b";
  context.fillRect(0, 0, width, height);

  const grid = Math.max(24, Math.round(Math.min(width, height) / 12));
  context.strokeStyle = "#59616d";
  context.lineWidth = Math.max(2, Math.round(grid / 20));
  for (let x = 0; x <= width; x += grid) {
    context.beginPath();
    context.moveTo(x, 0);
    context.lineTo(x, height);
    context.stroke();
  }
  for (let y = 0; y <= height; y += grid) {
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(width, y);
    context.stroke();
  }

  const corner = Math.max(32, Math.round(Math.min(width, height) / 8));
  context.fillStyle = "#ff2828";
  context.fillRect(0, 0, corner, corner);
  context.fillStyle = "#28ff28";
  context.fillRect(width - corner, 0, corner, corner);
  context.fillStyle = "#2878ff";
  context.fillRect(0, height - corner, corner, corner);
  context.fillStyle = "#ffffff";
  context.fillRect(width - corner, height - corner, corner, corner);

  const sideWidth = Math.max(12, Math.round(width / 64));
  context.fillStyle = "#ffd000";
  context.fillRect(sideWidth * 2, corner, sideWidth, height - corner * 2);
  context.fillStyle = "#00e5ff";
  context.fillRect(
    width - sideWidth * 3,
    corner,
    sideWidth,
    height - corner * 2,
  );

  const marker = cameraBenchmarkMarkerBits(frame, timestamp);
  const cell = Math.max(6, Math.floor(height / 72));
  const markerHeight = marker.length * cell;
  const markerX = Math.floor((width - cell) / 2);
  const markerY = Math.floor((height - markerHeight) / 2);
  context.fillStyle = "#ff00ff";
  context.fillRect(
    markerX - cell,
    markerY - cell,
    cell * 3,
    markerHeight + cell * 2,
  );
  marker.forEach((bit, index) => {
    context.fillStyle = bit ? "#ffffff" : "#000000";
    context.fillRect(markerX, markerY + index * cell, cell, cell);
  });

  context.fillStyle = "#ffffff";
  context.font = `700 ${Math.max(24, Math.round(height / 18))}px ui-monospace, monospace`;
  context.textAlign = "center";
  context.textBaseline = "middle";
  context.fillText(
    `${String(frame % 2 ** FRAME_BITS).padStart(5, "0")} · ${String(timestamp).padStart(8, "0")}`,
    width / 2,
    height / 2,
  );
}

export function cameraBenchmarkMarkerBits(
  frame: number,
  timestamp: number,
): boolean[] {
  return [
    ...numberBits(frame, FRAME_BITS),
    ...numberBits(timestamp, TIMESTAMP_BITS),
  ];
}

function numberBits(value: number, bitCount: number): boolean[] {
  const normalized = Math.floor(value) % 2 ** bitCount;
  return Array.from(
    { length: bitCount },
    (_, index) => (normalized & (2 ** (bitCount - index - 1))) !== 0,
  );
}

function evenDimension(value: number): number {
  return Math.max(2, Math.floor(value / 2) * 2);
}
