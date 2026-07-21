import { Cross2Icon } from "@radix-ui/react-icons";
import type { ReactNode } from "react";

export function DialogHeader({
  children,
  id,
  onClose,
}: {
  children: ReactNode;
  id: string;
  onClose(): void;
}) {
  return (
    <div className="new-sim-titlebar">
      <h2 id={id}>{children}</h2>
      <button
        aria-label="Close"
        className="new-sim-close-button"
        onClick={onClose}
        title="Close"
        type="button"
      >
        <Cross2Icon />
      </button>
    </div>
  );
}
