export function shouldWarmAccessibilityAfterFirstFrame(options: {
  hasFrame: boolean;
  hierarchyVisible: boolean;
  isBooted: boolean;
}): boolean {
  return options.isBooted && (options.hierarchyVisible || options.hasFrame);
}
