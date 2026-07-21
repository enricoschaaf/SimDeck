import { describe, expect, it } from "vitest";

import {
  clearRecoveredControlSocketError,
  CONTROL_SOCKET_DISCONNECTED_ERROR,
  shouldReconnectControlSocket,
} from "./controlSocketLifecycle";

describe("control socket lifecycle", () => {
  it("reconnects the active simulator after an interrupted connection", () => {
    expect(shouldReconnectControlSocket("sim-1", "sim-1", true)).toBe(true);
  });

  it("does not reconnect a socket superseded by another simulator", () => {
    expect(shouldReconnectControlSocket("sim-2", "sim-1", false)).toBe(false);
  });

  it("does not reconnect after an intentional close", () => {
    expect(shouldReconnectControlSocket("", "sim-1", true)).toBe(false);
  });

  it("clears only the recovered control connection error", () => {
    expect(
      clearRecoveredControlSocketError(CONTROL_SOCKET_DISCONNECTED_ERROR),
    ).toBe("");
    expect(clearRecoveredControlSocketError("Install failed.")).toBe(
      "Install failed.",
    );
  });
});
