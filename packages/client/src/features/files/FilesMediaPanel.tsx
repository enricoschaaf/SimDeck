import {
  ArchiveIcon as FolderIcon,
  Cross2Icon,
  DownloadIcon,
  FileIcon,
  ImageIcon,
  PlusIcon,
  TrashIcon,
  UploadIcon,
} from "@radix-ui/react-icons";
import { useCallback, useEffect, useRef, useState } from "react";

import {
  createSimulatorDirectory,
  deleteSimulatorFile,
  downloadSimulatorFile,
  importSimulatorMedia,
  listSimulatorFiles,
  updateSimulatorFile,
  uploadSimulatorFile,
  type SimulatorFileItem,
} from "../../api/filesMedia";
import type { SimulatorMetadata, SystemSurface } from "../../api/types";
import type {
  ControlServerEvent,
  TransferProgressEvent,
} from "../../app/controlMessages";
import { usePanelPresence } from "../../shared/hooks/usePanelPresence";

export type FilesMediaTab = "files" | "photos";

interface FilesMediaPanelProps {
  activeSurface?: SystemSurface | null;
  activeTab: FilesMediaTab;
  event: ControlServerEvent | null;
  onActiveTabChange: (tab: FilesMediaTab) => void;
  onClose: () => void;
  selectedSimulator: SimulatorMetadata | null;
  visible: boolean;
}

interface FolderLocation {
  id: string;
  name: string;
}

interface ActivityItem {
  id: string;
  label: string;
  status: "active" | "completed" | "failed";
}

interface MediaCandidate {
  file: File;
  previewUrl: string;
}

const PHOTO_PICKER_MAX_BYTES = 10 * 1024 * 1024;
const PHOTO_PICKER_ACCEPT = [
  "image/gif",
  "image/heic",
  "image/heif",
  "image/jpeg",
  "image/png",
];

export function FilesMediaPanel({
  activeSurface,
  activeTab,
  event,
  onActiveTabChange,
  onClose,
  selectedSimulator,
  visible,
}: FilesMediaPanelProps) {
  const { isPresent, panelState } = usePanelPresence(visible);
  const [files, setFiles] = useState<SimulatorFileItem[]>([]);
  const [folders, setFolders] = useState<FolderLocation[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [dragging, setDragging] = useState(false);
  const [activity, setActivity] = useState<ActivityItem[]>([]);
  const [mediaCandidate, setMediaCandidate] = useState<MediaCandidate | null>(
    null,
  );
  const [mediaStatus, setMediaStatus] = useState("");
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const mediaInputRef = useRef<HTMLInputElement | null>(null);
  const udid = selectedSimulator?.udid ?? "";
  const parentId = folders.at(-1)?.id ?? "root";
  const photoPickerActive = activeSurface?.kind === "photoPicker";

  const loadFiles = useCallback(async () => {
    if (!visible || !udid || !selectedSimulator?.isBooted) {
      return;
    }
    setLoading(true);
    setError("");
    try {
      const response = await listSimulatorFiles(udid, parentId);
      setFiles(response.items);
    } catch (loadError) {
      setError(errorMessage(loadError));
    } finally {
      setLoading(false);
    }
  }, [parentId, selectedSimulator?.isBooted, udid, visible]);

  useEffect(() => {
    setFolders([]);
    setFiles([]);
    setError("");
    setMediaStatus("");
    setMediaCandidate((current) => {
      if (current) {
        URL.revokeObjectURL(current.previewUrl);
      }
      return null;
    });
  }, [udid]);

  useEffect(() => {
    if (visible && activeTab === "files") {
      void loadFiles();
    }
  }, [activeTab, loadFiles, visible]);

  useEffect(() => {
    if (!event || event.udid !== udid) {
      return;
    }
    if (event.type.startsWith("file.")) {
      if (event.type !== "file.transfer-progress") {
        void loadFiles();
      }
      setActivity((current) => activityFromEvent(event, current));
    } else if (event.type.startsWith("media.")) {
      setActivity((current) => activityFromEvent(event, current));
      if (event.type === "media.import-completed") {
        setMediaStatus("Added to Photos. Select it in the iOS picker.");
      } else if (event.type === "media.import-failed") {
        setMediaStatus(event.error?.message || "Media import failed.");
      }
    }
  }, [event, loadFiles, udid]);

  useEffect(
    () => () => {
      if (mediaCandidate) {
        URL.revokeObjectURL(mediaCandidate.previewUrl);
      }
    },
    [mediaCandidate],
  );

  if (!isPresent) {
    return null;
  }

  async function uploadFiles(uploadedFiles: FileList | File[]) {
    if (!udid) {
      return;
    }
    setError("");
    for (const file of Array.from(uploadedFiles)) {
      try {
        await uploadSimulatorFile(udid, file, parentId);
      } catch (uploadError) {
        setError(errorMessage(uploadError));
        break;
      }
    }
    await loadFiles();
  }

  async function createFolder() {
    const name = window.prompt("New folder name")?.trim();
    if (!name || !udid) {
      return;
    }
    setError("");
    try {
      await createSimulatorDirectory(udid, parentId, name);
      await loadFiles();
    } catch (createError) {
      setError(errorMessage(createError));
    }
  }

  async function renameItem(item: SimulatorFileItem) {
    const name = window.prompt("Rename item", item.name)?.trim();
    if (!name || name === item.name || !udid) {
      return;
    }
    setError("");
    try {
      await updateSimulatorFile(udid, item.id, { name });
      await loadFiles();
    } catch (renameError) {
      setError(errorMessage(renameError));
    }
  }

  async function deleteItem(item: SimulatorFileItem) {
    if (!udid || !window.confirm(`Delete “${item.name}”?`)) {
      return;
    }
    setError("");
    try {
      await deleteSimulatorFile(udid, item.id);
      await loadFiles();
    } catch (deleteError) {
      setError(errorMessage(deleteError));
    }
  }

  function chooseMedia(file: File | undefined) {
    if (!file) {
      return;
    }
    const validationError = validateMediaCandidate(file, photoPickerActive);
    if (validationError) {
      setError(validationError);
      return;
    }
    setError("");
    setMediaStatus("");
    setMediaCandidate((current) => {
      if (current) {
        URL.revokeObjectURL(current.previewUrl);
      }
      return { file, previewUrl: URL.createObjectURL(file) };
    });
  }

  async function addMediaToPhotos() {
    if (!mediaCandidate || !udid) {
      return;
    }
    setError("");
    setMediaStatus("Adding to Photos…");
    try {
      await importSimulatorMedia(udid, mediaCandidate.file);
      setMediaStatus("Added to Photos. Select it in the iOS picker.");
      setMediaCandidate((current) => {
        if (current) {
          URL.revokeObjectURL(current.previewUrl);
        }
        return null;
      });
    } catch (importError) {
      setMediaStatus("");
      setError(errorMessage(importError));
    }
  }

  return (
    <aside
      aria-label="Files and media"
      className="files-media-panel"
      data-state={panelState}
    >
      <header className="files-media-header">
        <div>
          <strong>Files &amp; Media</strong>
          <span>{selectedSimulator?.name ?? "No simulator selected"}</span>
        </div>
        <button
          aria-label="Close Files and Media"
          className="tbtn icon-btn"
          onClick={onClose}
          type="button"
        >
          <Cross2Icon />
        </button>
      </header>
      <div className="files-media-tabs" role="tablist">
        <button
          aria-selected={activeTab === "files"}
          className={activeTab === "files" ? "active" : ""}
          onClick={() => onActiveTabChange("files")}
          role="tab"
          type="button"
        >
          <FolderIcon /> Files
        </button>
        <button
          aria-selected={activeTab === "photos"}
          className={activeTab === "photos" ? "active" : ""}
          onClick={() => onActiveTabChange("photos")}
          role="tab"
          type="button"
        >
          <ImageIcon /> Photos
        </button>
      </div>

      {activeTab === "files" ? (
        <section className="files-media-content">
          <input
            multiple
            onChange={(inputEvent) => {
              if (inputEvent.currentTarget.files) {
                void uploadFiles(inputEvent.currentTarget.files);
              }
              inputEvent.currentTarget.value = "";
            }}
            ref={fileInputRef}
            style={{ display: "none" }}
            type="file"
          />
          <div className="files-media-actions">
            <button
              className="tbtn accent"
              onClick={() => fileInputRef.current?.click()}
              type="button"
            >
              <UploadIcon /> Choose from this computer
            </button>
            <button className="tbtn" onClick={createFolder} type="button">
              <PlusIcon /> New folder
            </button>
          </div>
          <div
            className={`files-drop-zone ${dragging ? "dragging" : ""}`}
            onDragEnter={(dragEvent) => {
              dragEvent.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDragOver={(dragEvent) => dragEvent.preventDefault()}
            onDrop={(dropEvent) => {
              dropEvent.preventDefault();
              setDragging(false);
              void uploadFiles(dropEvent.dataTransfer.files);
            }}
          >
            Drop files here to make them available in the native picker.
          </div>
          <nav className="files-breadcrumb" aria-label="Current folder">
            <button
              disabled={folders.length === 0}
              onClick={() => setFolders([])}
              type="button"
            >
              On My iPhone
            </button>
            {folders.map((folder, index) => (
              <button
                key={folder.id}
                onClick={() =>
                  setFolders((current) => current.slice(0, index + 1))
                }
                type="button"
              >
                / {folder.name}
              </button>
            ))}
          </nav>
          <div className="files-list">
            {loading ? <p className="files-empty">Loading files…</p> : null}
            {!loading && files.length === 0 ? (
              <p className="files-empty">This folder is empty.</p>
            ) : null}
            {files.map((item) => (
              <div className="files-row" key={item.id}>
                <button
                  className="files-row-main"
                  onClick={() => {
                    if (item.kind === "directory") {
                      setFolders((current) => [
                        ...current,
                        { id: item.id, name: item.name },
                      ]);
                    } else {
                      void downloadSimulatorFile(udid, item).catch(
                        (downloadError) =>
                          setError(errorMessage(downloadError)),
                      );
                    }
                  }}
                  type="button"
                >
                  {item.kind === "directory" ? <FolderIcon /> : <FileIcon />}
                  <span>
                    <strong>{item.name}</strong>
                    <small>
                      {item.kind === "directory"
                        ? "Folder"
                        : formatBytes(item.size)}
                    </small>
                  </span>
                </button>
                {item.kind === "file" ? (
                  <button
                    aria-label={`Download ${item.name}`}
                    className="tbtn icon-btn"
                    onClick={() =>
                      void downloadSimulatorFile(udid, item).catch(
                        (downloadError) =>
                          setError(errorMessage(downloadError)),
                      )
                    }
                    type="button"
                  >
                    <DownloadIcon />
                  </button>
                ) : null}
                <button
                  className="files-inline-action"
                  onClick={() => void renameItem(item)}
                  type="button"
                >
                  Rename
                </button>
                <button
                  aria-label={`Delete ${item.name}`}
                  className="tbtn icon-btn danger"
                  onClick={() => void deleteItem(item)}
                  type="button"
                >
                  <TrashIcon />
                </button>
              </div>
            ))}
          </div>
        </section>
      ) : (
        <section className="files-media-content photos-content">
          <input
            accept={
              photoPickerActive
                ? PHOTO_PICKER_ACCEPT.join(",")
                : "image/*,video/mp4,video/quicktime"
            }
            onChange={(inputEvent) => {
              chooseMedia(inputEvent.currentTarget.files?.[0]);
              inputEvent.currentTarget.value = "";
            }}
            ref={mediaInputRef}
            style={{ display: "none" }}
            type="file"
          />
          <button
            className="tbtn accent photos-choose"
            onClick={() => mediaInputRef.current?.click()}
            type="button"
          >
            <ImageIcon /> Choose image from this computer
          </button>
          <div
            className={`photos-drop-zone ${dragging ? "dragging" : ""}`}
            onDragEnter={(dragEvent) => {
              dragEvent.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDragOver={(dragEvent) => dragEvent.preventDefault()}
            onDrop={(dropEvent) => {
              dropEvent.preventDefault();
              setDragging(false);
              chooseMedia(dropEvent.dataTransfer.files[0]);
            }}
          >
            {mediaCandidate ? (
              <>
                {mediaCandidate.file.type.startsWith("image/") ? (
                  <img alt="Import preview" src={mediaCandidate.previewUrl} />
                ) : (
                  <video muted src={mediaCandidate.previewUrl} />
                )}
                <strong>{mediaCandidate.file.name}</strong>
                <span>{formatBytes(mediaCandidate.file.size)}</span>
              </>
            ) : (
              <>
                <ImageIcon />
                <span>Drop an image here</span>
              </>
            )}
          </div>
          {photoPickerActive ? (
            <p className="photos-hint">One image, up to 10 MB.</p>
          ) : null}
          <button
            className="tbtn accent photos-import"
            disabled={!mediaCandidate || mediaStatus === "Adding to Photos…"}
            onClick={() => void addMediaToPhotos()}
            type="button"
          >
            Add to Photos
          </button>
          {mediaStatus ? (
            <p className="files-media-success" role="status">
              {mediaStatus}
            </p>
          ) : null}
        </section>
      )}

      {error ? (
        <p className="files-media-error" role="alert">
          {error}
        </p>
      ) : null}
      <section className="transfer-activity">
        <h3>Recent activity</h3>
        {activity.length === 0 ? (
          <p>No transfers yet.</p>
        ) : (
          activity.map((item) => (
            <div
              className={`transfer-activity-row ${item.status}`}
              key={item.id}
            >
              <span>{item.label}</span>
              <small>{item.status}</small>
            </div>
          ))
        )}
      </section>
    </aside>
  );
}

export function filesMediaTabForSurface(
  surface: SystemSurface | null | undefined,
): FilesMediaTab {
  return surface?.kind === "photoPicker" ? "photos" : "files";
}

export function shouldAutoOpenFilesMedia(
  surface: SystemSurface | null | undefined,
  dismissedSessionIds: ReadonlySet<string>,
): boolean {
  return Boolean(surface && !dismissedSessionIds.has(surface.sessionId));
}

export function validateMediaCandidate(
  file: Pick<File, "size" | "type">,
  photoPickerActive: boolean,
): string {
  const supported = [
    ...PHOTO_PICKER_ACCEPT,
    "video/mp4",
    "video/quicktime",
  ].includes(file.type);
  if (!supported) {
    return "Choose a JPEG, PNG, HEIC, GIF, MP4, or QuickTime file.";
  }
  if (photoPickerActive && !PHOTO_PICKER_ACCEPT.includes(file.type)) {
    return "The active picker accepts images only.";
  }
  if (photoPickerActive && file.size > PHOTO_PICKER_MAX_BYTES) {
    return "The active picker accepts images up to 10 MB.";
  }
  return "";
}

function activityFromEvent(
  event: ControlServerEvent,
  current: ActivityItem[],
): ActivityItem[] {
  if (event.type === "system-surface.changed") {
    return current;
  }
  let next: ActivityItem;
  if (event.type === "file.created" || event.type === "file.changed") {
    next = {
      id: `${event.type}-${event.item.id}-${event.item.version}`,
      label: `${event.item.name} ${event.type === "file.created" ? "added to Files" : "updated"}`,
      status: "completed",
    };
  } else if (event.type === "file.deleted") {
    next = {
      id: `${event.type}-${event.item.id}-${event.item.version}`,
      label: `${event.item.name} deleted`,
      status: "completed",
    };
  } else {
    const transferEvent = event as TransferProgressEvent;
    const failed =
      transferEvent.type.endsWith("failed") ||
      transferEvent.status === "failed";
    const completed =
      transferEvent.type.endsWith("completed") ||
      transferEvent.status === "completed";
    next = {
      id: transferEvent.transferId,
      label: transferLabel(transferEvent),
      status: failed ? "failed" : completed ? "completed" : "active",
    };
  }
  return [next, ...current.filter((item) => item.id !== next.id)].slice(0, 8);
}

function transferLabel(event: TransferProgressEvent): string {
  const transferred = formatBytes(event.bytesTransferred);
  const total = event.totalBytes ? ` / ${formatBytes(event.totalBytes)}` : "";
  if (event.type === "media.import-completed") {
    return `${event.fileName} added to Photos`;
  }
  if (event.type === "media.import-failed") {
    return `${event.fileName}: ${event.error?.message || "import failed"}`;
  }
  return `${event.fileName} ${transferred}${total}`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1_024) {
    return `${bytes} B`;
  }
  if (bytes < 1_048_576) {
    return `${(bytes / 1_024).toFixed(1)} KB`;
  }
  return `${(bytes / 1_048_576).toFixed(1)} MB`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "Request failed.";
}
