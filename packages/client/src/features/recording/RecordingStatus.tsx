interface RecordingStatusProps {
  elapsed: string | null;
}

export function RecordingStatus({ elapsed }: RecordingStatusProps) {
  if (!elapsed) {
    return null;
  }

  return (
    <output
      aria-label={`Recording ${elapsed}`}
      aria-live="off"
      className="recording-status recording-status-floating"
    >
      <span aria-hidden="true" className="recording-status-dot" />
      <span>{elapsed}</span>
    </output>
  );
}
