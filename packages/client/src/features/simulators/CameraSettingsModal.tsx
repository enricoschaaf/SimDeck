import { useEffect } from "react";

import type { AutomaticCamera } from "./automaticCamera";
import { DialogHeader } from "./DialogHeader";

export function CameraSettingsModal({
  camera,
  onClose,
  open,
}: {
  camera: AutomaticCamera;
  onClose(): void;
  open: boolean;
}) {
  useEffect(() => {
    if (!open) {
      return;
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose, open]);

  if (!open) {
    return null;
  }

  return (
    <div
      className="new-sim-overlay"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
    >
      <section
        aria-labelledby="camera-settings-title"
        aria-modal="true"
        className="new-sim-window camera-settings-window"
        role="dialog"
      >
        <DialogHeader id="camera-settings-title" onClose={onClose}>
          Camera settings
        </DialogHeader>
        <div className="new-sim-body camera-settings-body">
          <label className="new-sim-field">
            <span>Camera:</span>
            <select
              onChange={(event) =>
                camera.selectCamera(event.currentTarget.value)
              }
              value={camera.cameraId}
            >
              <option value="">System default</option>
              {camera.cameras.map((device) => (
                <option key={device.id} value={device.id}>
                  {device.name}
                </option>
              ))}
            </select>
          </label>
          <p className="new-sim-status">
            {camera.activeConsumers === 0
              ? "The webcam connects automatically when the simulated app requests a camera."
              : camera.phase === "streaming"
                ? `${camera.activeConsumers} active camera consumer${camera.activeConsumers === 1 ? "" : "s"} · ${camera.framesConsumed} frames consumed`
                : "The simulated app is waiting for the webcam."}
          </p>
          {camera.error ? (
            <p className="new-sim-error">{camera.error}</p>
          ) : null}
        </div>
        <div className="new-sim-actions">
          <button className="new-sim-button" onClick={onClose} type="button">
            Close
          </button>
          <span className="new-sim-action-spacer" />
          {camera.activeConsumers > 0 && camera.phase !== "streaming" ? (
            <button
              className="new-sim-button primary"
              onClick={camera.retry}
              type="button"
            >
              Reconnect
            </button>
          ) : null}
        </div>
      </section>
    </div>
  );
}

export function CameraRecoveryBanner({ camera }: { camera: AutomaticCamera }) {
  if (!camera.error || camera.activeConsumers === 0) {
    return null;
  }
  return (
    <div className="camera-recovery-banner" role="alert">
      <span>{camera.error}</span>
      <button onClick={camera.retry} type="button">
        Reconnect
      </button>
    </div>
  );
}
