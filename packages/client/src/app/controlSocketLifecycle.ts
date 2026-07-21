export const CONTROL_SOCKET_RECONNECT_DELAY_MS = 500;

export function shouldReconnectControlSocket(
  desiredUDID: string,
  closedUDID: string,
  wasCurrent: boolean,
): boolean {
  return wasCurrent && desiredUDID === closedUDID;
}
