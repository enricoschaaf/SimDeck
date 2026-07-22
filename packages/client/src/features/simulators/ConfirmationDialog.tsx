import { useEffect } from "react";

interface ConfirmationDialogProps {
  confirmLabel: string;
  description: string;
  onCancel(): void;
  onConfirm(): void;
  open: boolean;
  title: string;
}

export function ConfirmationDialog({
  confirmLabel,
  description,
  onCancel,
  onConfirm,
  open,
  title,
}: ConfirmationDialogProps) {
  useEffect(() => {
    if (!open) {
      return;
    }
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onCancel();
      }
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onCancel, open]);

  if (!open) {
    return null;
  }

  return (
    <div
      className="new-sim-overlay"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) {
          onCancel();
        }
      }}
    >
      <section
        aria-describedby="confirmation-dialog-description"
        aria-labelledby="confirmation-dialog-title"
        aria-modal="true"
        className="new-sim-window confirmation-dialog-window"
        role="alertdialog"
      >
        <div className="confirmation-dialog-body">
          <h2 id="confirmation-dialog-title">{title}</h2>
          <p id="confirmation-dialog-description">{description}</p>
        </div>
        <div className="new-sim-actions confirmation-dialog-actions">
          <button
            autoFocus
            className="new-sim-button"
            onClick={onCancel}
            type="button"
          >
            Cancel
          </button>
          <button
            className="new-sim-button destructive"
            onClick={onConfirm}
            type="button"
          >
            {confirmLabel}
          </button>
        </div>
      </section>
    </div>
  );
}
