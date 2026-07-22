import {
  Contrast as AppearanceIcon,
  House as HomeIcon,
  Layers3 as HierarchyIcon,
  Link2 as OpenUrlIcon,
  PanelsTopLeft as AppSwitcherIcon,
  Play as PlayIcon,
  RotateCcw as RotateLeftIcon,
  Square as StopIcon,
  SquareTerminal as DevToolsIcon,
  Trash2 as TrashIcon,
  Video as RecordIcon,
} from "lucide-react";
import { useEffect, useState, type RefObject } from "react";

import type { SimulatorMetadata } from "../../api/types";
import type { AccessibilitySkeletonMode } from "../accessibility/skeletonMode";
import type {
  StreamConfig,
  StreamEncoder,
  StreamFps,
  StreamQualityPreset,
  StreamTransport,
} from "../stream/streamTypes";
import { simulatorHasFixedOrientation } from "../simulators/simulatorDisplay";
import { SimulatorMenu } from "../simulators/SimulatorMenu";
import { SimulatorPickerMenu } from "../simulators/SimulatorPickerMenu";

interface ToolbarProps {
  accessibilitySkeletonMode: AccessibilitySkeletonMode;
  debugVisible: boolean;
  deviceChromeAvailable: boolean;
  deviceChromeVisible: boolean;
  devToolsVisible: boolean;
  embedded?: boolean;
  error: string;
  filteredSimulators: SimulatorMetadata[];
  hierarchyVisible: boolean;
  hideSimulatorSelection?: boolean;
  isLoading: boolean;
  canInstallApp: boolean;
  onBoot: () => void;
  onCaptureScreenshot: () => void;
  onCaptureScreenshotWithBezel: () => void;
  onChangeSearch: (value: string) => void;
  onDismissKeyboard: () => void;
  onHome: () => void;
  onInstallAppPrompt: () => void;
  onOpenCameraSimulation: () => void;
  onOpenFilesMedia: () => void;
  onOpenAppSwitcher: () => void;
  onOpenBundlePrompt: () => void;
  onOpenNewSimulator: () => void;
  onOpenUrlPrompt: () => void;
  onRotateLeft: () => void;
  onRotateRight: () => void;
  onAccessibilitySkeletonModeChange: (mode: AccessibilitySkeletonMode) => void;
  onShutdown: () => void;
  onStreamEncoderChange: (encoder: StreamEncoder) => void;
  onStreamFpsChange: (fps: StreamFps) => void;
  onStreamQualityChange: (quality: StreamQualityPreset) => void;
  onStreamTransportChange: (transport: StreamTransport) => void;
  onToggleAppearance: () => void;
  onToggleDebug: () => void;
  onToggleDeviceChrome: () => void;
  onToggleDevTools: () => void;
  onToggleHierarchy: () => void;
  onToggleMenu: () => void;
  onToggleRecording: () => void;
  onToggleSimulatorMenu: () => void;
  onToggleSoftwareKeyboard: () => void;
  onToggleTouchOverlay: () => void;
  captureBusy: boolean;
  clearAppDataBusy?: boolean;
  onClearAppData?: () => void;
  recordingActive: boolean;
  recordingLabel: string;
  recordingStarting: boolean;
  recordingStopping: boolean;
  remoteStream?: boolean;
  search: string;
  selectedSimulator: SimulatorMetadata | null;
  selectedSimulatorIdentifier: string;
  setSelectedUDID: (udid: string) => void;
  showBootButton: boolean;
  showStopButton: boolean;
  streamConfig: StreamConfig;
  streamTransport: StreamTransport;
  touchOverlayVisible: boolean;
  menuOpen: boolean;
  menuRef: RefObject<HTMLDivElement | null>;
  closeMenu: () => void;
  simulatorMenuOpen: boolean;
  simulatorMenuRef: RefObject<HTMLDivElement | null>;
  closeSimulatorMenu: () => void;
}

export function Toolbar({
  accessibilitySkeletonMode,
  captureBusy,
  clearAppDataBusy = false,
  closeSimulatorMenu,
  closeMenu,
  debugVisible,
  deviceChromeAvailable,
  deviceChromeVisible,
  devToolsVisible,
  embedded = false,
  error,
  filteredSimulators,
  hierarchyVisible,
  hideSimulatorSelection = false,
  isLoading,
  canInstallApp,
  menuOpen,
  menuRef,
  onBoot,
  onCaptureScreenshot,
  onCaptureScreenshotWithBezel,
  onChangeSearch,
  onClearAppData,
  onDismissKeyboard,
  onHome,
  onInstallAppPrompt,
  onOpenCameraSimulation,
  onOpenFilesMedia,
  onOpenAppSwitcher,
  onOpenBundlePrompt,
  onOpenNewSimulator,
  onOpenUrlPrompt,
  onRotateLeft,
  onRotateRight,
  onAccessibilitySkeletonModeChange,
  onShutdown,
  onStreamEncoderChange,
  onStreamFpsChange,
  onStreamQualityChange,
  onStreamTransportChange,
  onToggleAppearance,
  onToggleDebug,
  onToggleDeviceChrome,
  onToggleDevTools,
  onToggleHierarchy,
  onToggleMenu,
  onToggleRecording,
  onToggleSimulatorMenu,
  onToggleSoftwareKeyboard,
  onToggleTouchOverlay,
  recordingActive,
  recordingLabel,
  recordingStarting,
  recordingStopping,
  remoteStream = false,
  search,
  selectedSimulator,
  selectedSimulatorIdentifier,
  setSelectedUDID,
  showBootButton,
  showStopButton,
  streamConfig,
  streamTransport,
  simulatorMenuOpen,
  simulatorMenuRef,
  touchOverlayVisible,
}: ToolbarProps) {
  const [errorCopied, setErrorCopied] = useState(false);
  const canRotateSelectedSimulator =
    selectedSimulator != null &&
    !simulatorHasFixedOrientation(selectedSimulator);

  useEffect(() => {
    setErrorCopied(false);
  }, [error]);

  async function copyError() {
    if (!error) {
      return;
    }
    try {
      await navigator.clipboard.writeText(error);
      setErrorCopied(true);
      window.setTimeout(() => setErrorCopied(false), 1200);
    } catch {
      setErrorCopied(false);
    }
  }

  return (
    <header
      aria-label="Simulator controls"
      className={`toolbar ${embedded ? "toolbar-embedded" : ""}`}
    >
      <div className="toolbar-left">
        <button
          aria-label="Toggle View Hierarchy"
          className={`tbtn icon-btn ${hierarchyVisible ? "active" : ""}`}
          data-tooltip="View hierarchy"
          onClick={onToggleHierarchy}
          type="button"
        >
          <HierarchyIcon />
        </button>
        <SimulatorMenu
          captureBusy={captureBusy}
          debugVisible={debugVisible}
          menuOpen={menuOpen}
          menuRef={menuRef}
          onBoot={onBoot}
          onCaptureScreenshot={onCaptureScreenshot}
          onCaptureScreenshotWithBezel={onCaptureScreenshotWithBezel}
          onCloseMenu={closeMenu}
          onDismissKeyboard={onDismissKeyboard}
          onHome={onHome}
          onInstallAppPrompt={onInstallAppPrompt}
          onOpenCameraSimulation={onOpenCameraSimulation}
          onOpenFilesMedia={onOpenFilesMedia}
          onOpenAppSwitcher={onOpenAppSwitcher}
          onOpenBundlePrompt={onOpenBundlePrompt}
          onOpenUrlPrompt={onOpenUrlPrompt}
          onRotateRight={onRotateRight}
          onAccessibilitySkeletonModeChange={onAccessibilitySkeletonModeChange}
          onShutdown={onShutdown}
          onStreamEncoderChange={onStreamEncoderChange}
          onStreamFpsChange={onStreamFpsChange}
          onStreamQualityChange={onStreamQualityChange}
          onStreamTransportChange={onStreamTransportChange}
          onToggleAppearance={onToggleAppearance}
          onToggleDebug={onToggleDebug}
          onToggleDeviceChrome={onToggleDeviceChrome}
          onToggleMenu={onToggleMenu}
          onToggleSoftwareKeyboard={onToggleSoftwareKeyboard}
          onToggleTouchOverlay={onToggleTouchOverlay}
          remoteStream={remoteStream}
          selectedSimulator={selectedSimulator}
          showBootButton={showBootButton}
          showStopButton={showStopButton}
          canInstallApp={canInstallApp}
          streamConfig={streamConfig}
          streamTransport={streamTransport}
          accessibilitySkeletonMode={accessibilitySkeletonMode}
          deviceChromeAvailable={deviceChromeAvailable}
          deviceChromeVisible={deviceChromeVisible}
          touchOverlayVisible={touchOverlayVisible}
        />
        {!embedded ? (
          <SimulatorPickerMenu
            filteredSimulators={filteredSimulators}
            hideSimulatorSelection={hideSimulatorSelection}
            isLoading={isLoading}
            menuOpen={simulatorMenuOpen}
            menuRef={simulatorMenuRef}
            onChangeSearch={onChangeSearch}
            onCloseMenu={closeSimulatorMenu}
            onOpenNewSimulator={onOpenNewSimulator}
            onToggleMenu={onToggleSimulatorMenu}
            search={search}
            selectedSimulator={selectedSimulator}
            selectedSimulatorIdentifier={selectedSimulatorIdentifier}
            setSelectedUDID={setSelectedUDID}
          />
        ) : null}
      </div>

      <div className="toolbar-right">
        {selectedSimulator ? (
          <div className="toolbar-actions">
            {showBootButton ? (
              <button
                aria-label="Boot"
                className="tbtn icon-btn accent"
                data-tooltip="Boot"
                onClick={onBoot}
              >
                <PlayIcon />
              </button>
            ) : null}
            {showStopButton ? (
              <button
                aria-label="Stop"
                className="tbtn icon-btn"
                data-tooltip="Stop"
                onClick={onShutdown}
              >
                <StopIcon />
              </button>
            ) : null}
            <button
              aria-label="Open URL"
              className="tbtn icon-btn toolbar-mobile-hidden"
              data-tooltip="Open URL"
              onClick={onOpenUrlPrompt}
            >
              <OpenUrlIcon />
            </button>
            <button
              aria-label="Home"
              className="tbtn icon-btn toolbar-mobile-hidden"
              data-tooltip="Home"
              onClick={onHome}
            >
              <HomeIcon />
            </button>
            <button
              aria-label="App Switcher"
              className="tbtn icon-btn toolbar-mobile-hidden"
              data-tooltip="App switcher"
              onClick={onOpenAppSwitcher}
            >
              <AppSwitcherIcon />
            </button>
            <button
              aria-label="Toggle Appearance"
              className="tbtn icon-btn toolbar-mobile-hidden"
              data-tooltip="Appearance"
              onClick={onToggleAppearance}
            >
              <AppearanceIcon />
            </button>
            {canRotateSelectedSimulator ? (
              <>
                <button
                  aria-label="Rotate Left"
                  className="tbtn icon-btn toolbar-mobile-hidden toolbar-wide-hidden"
                  data-tooltip="Rotate left"
                  onClick={onRotateLeft}
                >
                  <RotateLeftIcon />
                </button>
                <button
                  aria-label="Rotate Right"
                  className="tbtn icon-btn toolbar-mobile-hidden"
                  data-tooltip="Rotate right"
                  onClick={onRotateRight}
                >
                  <RotateLeftIcon className="rotate-right-icon" />
                </button>
              </>
            ) : null}
            <button
              aria-label={
                recordingActive ? "Stop Recording" : "Start Recording"
              }
              className={`tbtn icon-btn recording-btn ${recordingActive ? "recording-active" : ""} ${recordingStopping || recordingStarting ? "recording-pending" : ""}`}
              data-tooltip={
                selectedSimulator.isBooted
                  ? recordingLabel
                  : "Boot simulator to record"
              }
              disabled={
                !selectedSimulator.isBooted ||
                captureBusy ||
                recordingStopping ||
                recordingStarting
              }
              onClick={onToggleRecording}
              type="button"
            >
              {recordingActive ? <StopIcon /> : <RecordIcon />}
            </button>
          </div>
        ) : null}
        {error ? (
          <button
            className={`error-msg ${errorCopied ? "copied" : ""}`}
            onClick={copyError}
            title={errorCopied ? "Copied" : "Copy error"}
            type="button"
          >
            {errorCopied ? "Copied" : error}
          </button>
        ) : null}
        <button
          aria-label="Toggle DevTools"
          className={`tbtn icon-btn ${devToolsVisible ? "active" : ""}`}
          data-tooltip="Developer tools"
          onClick={onToggleDevTools}
          type="button"
        >
          <DevToolsIcon />
        </button>
        {onClearAppData ? (
          <button
            aria-label="Clear app data"
            className="tbtn icon-btn"
            data-tooltip={
              clearAppDataBusy ? "Clearing app data…" : "Clear app data"
            }
            disabled={clearAppDataBusy}
            onClick={onClearAppData}
            type="button"
          >
            <TrashIcon />
          </button>
        ) : null}
      </div>
    </header>
  );
}
