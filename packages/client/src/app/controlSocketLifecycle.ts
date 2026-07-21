export const CONTROL_SOCKET_RECONNECT_DELAY_MS = 500;
export const CONTROL_SOCKET_DISCONNECTED_ERROR =
  "Simulator control stream disconnected.";

export function clearRecoveredControlSocketError(error: string): string {
  return error === CONTROL_SOCKET_DISCONNECTED_ERROR ? "" : error;
}

export function shouldReconnectControlSocket(
  desiredUDID: string,
  closedUDID: string,
  wasCurrent: boolean,
): boolean {
  return wasCurrent && desiredUDID === closedUDID;
}
