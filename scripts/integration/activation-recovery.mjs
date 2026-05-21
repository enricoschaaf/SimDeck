function errorMessage(error) {
  return String(error?.message ?? error ?? "");
}

export function isCoreSimulatorActivationTimeout(error) {
  const message = errorMessage(error).toLowerCase();
  return (
    message.includes("timed out") &&
    /\bsimctl\s+(launch|openurl)\b/.test(message)
  );
}

export function shouldRecycleSimulatorForFixtureLaunch({
  launchError,
  urlError,
  recoveryCount = 0,
  maxRecoveries = 1,
}) {
  if (recoveryCount >= maxRecoveries) {
    return false;
  }
  return [launchError, urlError].some(isCoreSimulatorActivationTimeout);
}

export function activationRecoveryReason({ launchError, urlError }) {
  if (isCoreSimulatorActivationTimeout(launchError)) {
    return "simctl launch timeout";
  }
  if (isCoreSimulatorActivationTimeout(urlError)) {
    return "simctl open-url timeout";
  }
  return "simulator app activation timeout";
}
