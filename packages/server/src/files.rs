use bytes::Bytes;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio::fs::{self, File, OpenOptions};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::time::timeout;

pub const FILES_APP_BUNDLE_IDENTIFIER: &str = "dev.simdeck.files";
pub const FILES_APP_GROUP_IDENTIFIER: &str = "group.dev.simdeck.files";
pub const ROOT_ITEM_IDENTIFIER: &str = "root";
const STORE_RELATIVE_PATH: &str = "Library/Application Support/SimDeck Files";
const APP_CONTAINER_TIMEOUT: Duration = Duration::from_secs(3);
const STALE_STAGING_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const MAX_FILE_NAME_BYTES: usize = 255;
const ITEM_ID_HEX_LENGTH: usize = 32;
static ITEM_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileItem {
    pub id: String,
    pub parent_id: String,
    pub name: String,
    pub kind: FileItemKind,
    pub content_type: Option<String>,
    pub size: u64,
    pub created_at: u64,
    pub modified_at: u64,
    pub version: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileItemKind {
    File,
    Directory,
}

#[derive(Clone, Default)]
pub struct SimulatorFiles;

impl SimulatorFiles {
    pub async fn store_for_device(&self, udid: &str) -> Result<ProviderStore, FilesError> {
        let group_container = resolve_group_container(udid).await?;
        ProviderStore::open_in_group_container(&group_container).await
    }
}

#[derive(Clone, Debug)]
pub struct ProviderStore {
    metadata: PathBuf,
    contents: PathBuf,
    staging: PathBuf,
}

impl ProviderStore {
    pub async fn open_in_group_container(group_container: &Path) -> Result<Self, FilesError> {
        let group_container = canonical_directory(group_container).await?;
        let root = group_container.join(STORE_RELATIVE_PATH);
        ensure_directory(&root).await?;
        let root = fs::canonicalize(&root).await.map_err(FilesError::Io)?;
        if !root.starts_with(&group_container) {
            return Err(FilesError::UnsafeStorage(
                "Files storage resolves outside the companion app group.".to_owned(),
            ));
        }

        let metadata = root.join("metadata");
        let contents = root.join("contents");
        let staging = root.join("staging");
        for directory in [&metadata, &contents, &staging] {
            ensure_directory(directory).await?;
            let canonical = fs::canonicalize(directory).await.map_err(FilesError::Io)?;
            if !canonical.starts_with(&root) {
                return Err(FilesError::UnsafeStorage(format!(
                    "Files storage directory {} resolves outside its root.",
                    directory.display()
                )));
            }
        }
        cleanup_stale_staging(&staging).await?;

        Ok(Self {
            metadata,
            contents,
            staging,
        })
    }

    #[cfg(test)]
    async fn open_test_root(root: &Path) -> Result<Self, FilesError> {
        ensure_directory(root).await?;
        Self::open_in_group_container(root).await
    }

    pub async fn list(&self, parent_id: Option<&str>) -> Result<Vec<FileItem>, FilesError> {
        if let Some(parent_id) = parent_id {
            validate_parent_identifier(parent_id)?;
            if parent_id != ROOT_ITEM_IDENTIFIER {
                let parent = self.item(parent_id).await?;
                if parent.kind != FileItemKind::Directory {
                    return Err(FilesError::InvalidInput(
                        "The selected parent is not a directory.".to_owned(),
                    ));
                }
            }
        }
        let mut items = self.read_items().await?;
        if let Some(parent_id) = parent_id {
            items.retain(|item| item.parent_id == parent_id);
        }
        items.sort_by(|left, right| {
            let left_directory = left.kind == FileItemKind::Directory;
            let right_directory = right.kind == FileItemKind::Directory;
            right_directory
                .cmp(&left_directory)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(items)
    }

    pub async fn item(&self, id: &str) -> Result<FileItem, FilesError> {
        validate_item_identifier(id)?;
        self.read_item(id).await
    }

    pub async fn create_directory(
        &self,
        parent_id: &str,
        name: &str,
    ) -> Result<FileItem, FilesError> {
        validate_file_name(name)?;
        self.validate_destination(parent_id, name, None).await?;
        let timestamp = now_ms();
        let item = FileItem {
            id: new_opaque_id(parent_id, name),
            parent_id: parent_id.to_owned(),
            name: name.to_owned(),
            kind: FileItemKind::Directory,
            content_type: None,
            size: 0,
            created_at: timestamp,
            modified_at: timestamp,
            version: 1,
        };
        self.write_item(&item).await?;
        Ok(item)
    }

    pub async fn begin_upload(&self, transfer_id: &str) -> Result<StagedUpload, FilesError> {
        validate_transfer_identifier(transfer_id)?;
        let path = self.staging.join(format!("{transfer_id}.partial"));
        reject_symlink_if_present(&path).await?;
        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .await
            .map_err(FilesError::Io)?;
        Ok(StagedUpload {
            path,
            file: Some(file),
            bytes_written: 0,
            committed: false,
        })
    }

    pub async fn commit_upload(
        &self,
        mut upload: StagedUpload,
        parent_id: &str,
        name: &str,
        content_type: &str,
    ) -> Result<FileItem, FilesError> {
        validate_file_name(name)?;
        validate_content_type(content_type)?;
        self.validate_destination(parent_id, name, None).await?;
        upload.finish_writing().await?;

        let timestamp = now_ms();
        let id = new_opaque_id(parent_id, name);
        let content_path = self.content_path(&id)?;
        reject_symlink_if_present(&content_path).await?;
        fs::rename(&upload.path, &content_path)
            .await
            .map_err(FilesError::Io)?;
        upload.committed = true;
        let item = FileItem {
            id,
            parent_id: parent_id.to_owned(),
            name: name.to_owned(),
            kind: FileItemKind::File,
            content_type: Some(content_type.to_owned()),
            size: upload.bytes_written,
            created_at: timestamp,
            modified_at: timestamp,
            version: 1,
        };
        if let Err(error) = self.write_item(&item).await {
            let _ = fs::remove_file(&content_path).await;
            return Err(error);
        }
        Ok(item)
    }

    pub async fn update(
        &self,
        id: &str,
        name: Option<&str>,
        parent_id: Option<&str>,
    ) -> Result<FileItem, FilesError> {
        let mut item = self.item(id).await?;
        let next_name = name.unwrap_or(&item.name);
        let next_parent = parent_id.unwrap_or(&item.parent_id);
        validate_file_name(next_name)?;
        self.validate_destination(next_parent, next_name, Some(id))
            .await?;
        if item.kind == FileItemKind::Directory && self.is_descendant(next_parent, id).await? {
            return Err(FilesError::InvalidInput(
                "A directory cannot be moved inside itself.".to_owned(),
            ));
        }
        item.name = next_name.to_owned();
        item.parent_id = next_parent.to_owned();
        item.modified_at = now_ms();
        item.version = item.version.saturating_add(1);
        self.write_item(&item).await?;
        Ok(item)
    }

    pub async fn delete(&self, id: &str) -> Result<Vec<FileItem>, FilesError> {
        let item = self.item(id).await?;
        let all_items = self.read_items().await?;
        let mut delete_ids = HashSet::from([id.to_owned()]);
        loop {
            let before = delete_ids.len();
            for candidate in &all_items {
                if delete_ids.contains(&candidate.parent_id) {
                    delete_ids.insert(candidate.id.clone());
                }
            }
            if delete_ids.len() == before {
                break;
            }
        }
        let mut deleted = all_items
            .into_iter()
            .filter(|candidate| delete_ids.contains(&candidate.id))
            .collect::<Vec<_>>();
        if !deleted.iter().any(|candidate| candidate.id == item.id) {
            deleted.push(item);
        }
        for candidate in &deleted {
            if candidate.kind == FileItemKind::File {
                remove_regular_file_if_present(&self.content_path(&candidate.id)?).await?;
            }
            remove_regular_file_if_present(&self.metadata_path(&candidate.id)?).await?;
        }
        Ok(deleted)
    }

    pub async fn open_content(&self, id: &str) -> Result<(FileItem, File), FilesError> {
        let item = self.item(id).await?;
        if item.kind != FileItemKind::File {
            return Err(FilesError::InvalidInput(
                "Directories cannot be downloaded.".to_owned(),
            ));
        }
        let path = self.content_path(id)?;
        let metadata = fs::symlink_metadata(&path).await.map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                FilesError::NotFound(format!("File {id} has no stored content."))
            } else {
                FilesError::Io(error)
            }
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(FilesError::UnsafeStorage(
                "Stored file content is not a regular file.".to_owned(),
            ));
        }
        let canonical = fs::canonicalize(&path).await.map_err(FilesError::Io)?;
        let content_root = fs::canonicalize(&self.contents)
            .await
            .map_err(FilesError::Io)?;
        if !canonical.starts_with(content_root) {
            return Err(FilesError::UnsafeStorage(
                "Stored file content resolves outside the provider store.".to_owned(),
            ));
        }
        let file = File::open(canonical).await.map_err(FilesError::Io)?;
        Ok((item, file))
    }

    async fn validate_destination(
        &self,
        parent_id: &str,
        name: &str,
        excluding_id: Option<&str>,
    ) -> Result<(), FilesError> {
        validate_parent_identifier(parent_id)?;
        if parent_id != ROOT_ITEM_IDENTIFIER {
            let parent = self.item(parent_id).await?;
            if parent.kind != FileItemKind::Directory {
                return Err(FilesError::InvalidInput(
                    "The selected parent is not a directory.".to_owned(),
                ));
            }
        }
        let folded_name = name.to_lowercase();
        let collision = self.list(Some(parent_id)).await?.into_iter().any(|item| {
            Some(item.id.as_str()) != excluding_id && item.name.to_lowercase() == folded_name
        });
        if collision {
            return Err(FilesError::Conflict(format!(
                "An item named {name:?} already exists in this directory."
            )));
        }
        Ok(())
    }

    async fn is_descendant(&self, candidate_parent: &str, id: &str) -> Result<bool, FilesError> {
        if candidate_parent == ROOT_ITEM_IDENTIFIER {
            return Ok(false);
        }
        let items = self
            .read_items()
            .await?
            .into_iter()
            .map(|item| (item.id, item.parent_id))
            .collect::<HashMap<_, _>>();
        let mut current = candidate_parent;
        let mut visited = HashSet::new();
        while current != ROOT_ITEM_IDENTIFIER {
            if current == id {
                return Ok(true);
            }
            if !visited.insert(current.to_owned()) {
                return Err(FilesError::UnsafeStorage(
                    "Files metadata contains a parent cycle.".to_owned(),
                ));
            }
            let Some(parent) = items.get(current) else {
                break;
            };
            current = parent;
        }
        Ok(false)
    }

    async fn read_items(&self) -> Result<Vec<FileItem>, FilesError> {
        let mut entries = fs::read_dir(&self.metadata).await.map_err(FilesError::Io)?;
        let mut items = Vec::new();
        while let Some(entry) = entries.next_entry().await.map_err(FilesError::Io)? {
            if entry
                .file_type()
                .await
                .map_err(FilesError::Io)?
                .is_symlink()
            {
                continue;
            }
            let metadata = entry.metadata().await.map_err(FilesError::Io)?;
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                continue;
            }
            let path = entry.path();
            if path.extension().and_then(|value| value.to_str()) != Some("json") {
                continue;
            }
            let bytes = fs::read(&path).await.map_err(FilesError::Io)?;
            let item = serde_json::from_slice::<FileItem>(&bytes).map_err(|error| {
                FilesError::UnsafeStorage(format!(
                    "Invalid Files metadata at {}: {error}",
                    path.display()
                ))
            })?;
            validate_item(&item)?;
            items.push(item);
        }
        Ok(items)
    }

    async fn read_item(&self, id: &str) -> Result<FileItem, FilesError> {
        let path = self.metadata_path(id)?;
        let metadata = fs::symlink_metadata(&path).await.map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                FilesError::NotFound(format!("Unknown Files item {id}."))
            } else {
                FilesError::Io(error)
            }
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(FilesError::UnsafeStorage(
                "Files metadata is not a regular file.".to_owned(),
            ));
        }
        let item =
            serde_json::from_slice::<FileItem>(&fs::read(&path).await.map_err(FilesError::Io)?)
                .map_err(|error| {
                    FilesError::UnsafeStorage(format!(
                        "Invalid Files metadata at {}: {error}",
                        path.display()
                    ))
                })?;
        validate_item(&item)?;
        if item.id != id {
            return Err(FilesError::UnsafeStorage(
                "Files metadata identifier does not match its storage key.".to_owned(),
            ));
        }
        Ok(item)
    }

    async fn write_item(&self, item: &FileItem) -> Result<(), FilesError> {
        validate_item(item)?;
        let path = self.metadata_path(&item.id)?;
        reject_symlink_if_present(&path).await?;
        let temporary = self.metadata.join(format!(
            ".{}.{}.tmp",
            item.id,
            ITEM_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let mut guard = TemporaryPath::new(temporary.clone());
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .await
            .map_err(FilesError::Io)?;
        file.write_all(&serde_json::to_vec(item).map_err(FilesError::Json)?)
            .await
            .map_err(FilesError::Io)?;
        file.sync_data().await.map_err(FilesError::Io)?;
        drop(file);
        fs::rename(&temporary, &path)
            .await
            .map_err(FilesError::Io)?;
        guard.disarm();
        Ok(())
    }

    fn metadata_path(&self, id: &str) -> Result<PathBuf, FilesError> {
        validate_item_identifier(id)?;
        Ok(self.metadata.join(format!("{id}.json")))
    }

    fn content_path(&self, id: &str) -> Result<PathBuf, FilesError> {
        validate_item_identifier(id)?;
        Ok(self.contents.join(id))
    }
}

pub struct StagedUpload {
    path: PathBuf,
    file: Option<File>,
    bytes_written: u64,
    committed: bool,
}

impl StagedUpload {
    pub async fn write(&mut self, chunk: Bytes) -> Result<u64, FilesError> {
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| FilesError::InvalidInput("Upload is already finalized.".to_owned()))?;
        file.write_all(&chunk).await.map_err(FilesError::Io)?;
        self.bytes_written = self.bytes_written.saturating_add(chunk.len() as u64);
        Ok(self.bytes_written)
    }

    pub fn bytes_written(&self) -> u64 {
        self.bytes_written
    }

    async fn finish_writing(&mut self) -> Result<(), FilesError> {
        let Some(file) = self.file.take() else {
            return Err(FilesError::InvalidInput(
                "Upload is already finalized.".to_owned(),
            ));
        };
        file.sync_data().await.map_err(FilesError::Io)
    }
}

impl Drop for StagedUpload {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

struct TemporaryPath {
    path: PathBuf,
    armed: bool,
}

impl TemporaryPath {
    fn new(path: PathBuf) -> Self {
        Self { path, armed: true }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TemporaryPath {
    fn drop(&mut self) {
        if self.armed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

#[derive(Debug, Error)]
pub enum FilesError {
    #[error("{0}")]
    InvalidInput(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    ProviderUnavailable(String),
    #[error("{0}")]
    UnsafeStorage(String),
    #[error("Files metadata serialization failed: {0}")]
    Json(serde_json::Error),
    #[error("Files storage operation failed: {0}")]
    Io(std::io::Error),
}

pub fn validate_file_name(name: &str) -> Result<(), FilesError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > MAX_FILE_NAME_BYTES
        || name.contains('/')
        || name.contains('\0')
        || name.chars().any(char::is_control)
    {
        return Err(FilesError::InvalidInput(
            "File names must be a single non-empty Unicode path component up to 255 bytes."
                .to_owned(),
        ));
    }
    Ok(())
}

pub fn validate_content_type(content_type: &str) -> Result<(), FilesError> {
    let valid = !content_type.is_empty()
        && content_type.len() <= 127
        && content_type.split_once('/').is_some_and(|(kind, subtype)| {
            !kind.is_empty()
                && !subtype.is_empty()
                && kind.bytes().all(is_mime_token_byte)
                && subtype.bytes().all(is_mime_token_byte)
        });
    if !valid {
        return Err(FilesError::InvalidInput(
            "Content type must be a valid MIME type.".to_owned(),
        ));
    }
    Ok(())
}

fn is_mime_token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(&byte)
}

fn validate_item(item: &FileItem) -> Result<(), FilesError> {
    validate_item_identifier(&item.id)?;
    validate_parent_identifier(&item.parent_id)?;
    validate_file_name(&item.name)?;
    match item.kind {
        FileItemKind::File => validate_content_type(
            item.content_type
                .as_deref()
                .ok_or_else(|| FilesError::UnsafeStorage("File has no content type.".to_owned()))?,
        ),
        FileItemKind::Directory if item.content_type.is_some() || item.size != 0 => {
            Err(FilesError::UnsafeStorage(
                "Directory metadata contains file content fields.".to_owned(),
            ))
        }
        FileItemKind::Directory => Ok(()),
    }
}

fn validate_item_identifier(id: &str) -> Result<(), FilesError> {
    if id.len() != ITEM_ID_HEX_LENGTH || !id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(FilesError::InvalidInput(
            "Files item identifier is invalid.".to_owned(),
        ));
    }
    Ok(())
}

fn validate_parent_identifier(id: &str) -> Result<(), FilesError> {
    if id == ROOT_ITEM_IDENTIFIER {
        Ok(())
    } else {
        validate_item_identifier(id)
    }
}

fn validate_transfer_identifier(id: &str) -> Result<(), FilesError> {
    validate_item_identifier(id)
}

async fn resolve_group_container(udid: &str) -> Result<PathBuf, FilesError> {
    if udid.is_empty() || udid.contains('\0') {
        return Err(FilesError::InvalidInput(
            "Simulator UDID is invalid.".to_owned(),
        ));
    }
    let output = timeout(
        APP_CONTAINER_TIMEOUT,
        Command::new("xcrun")
            .args([
                "simctl",
                "get_app_container",
                udid,
                FILES_APP_BUNDLE_IDENTIFIER,
                "groups",
            ])
            .output(),
    )
    .await
    .map_err(|_| {
        FilesError::ProviderUnavailable(
            "Timed out locating the SimDeck Files companion storage.".to_owned(),
        )
    })?
    .map_err(FilesError::Io)?;
    if !output.status.success() {
        return Err(FilesError::ProviderUnavailable(
            "SimDeck Files is not installed for this simulator.".to_owned(),
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let path = parse_group_container_output(&stdout).ok_or_else(|| {
        FilesError::ProviderUnavailable(
            "The SimDeck Files app group is not registered for this simulator.".to_owned(),
        )
    })?;
    canonical_directory(&path).await
}

fn parse_group_container_output(output: &str) -> Option<PathBuf> {
    output.lines().find_map(|line| {
        let line = line.trim().trim_matches('"');
        let candidate = if line.starts_with('/') {
            line
        } else {
            let (identifier, path) = line.split_once(['=', ':'])?;
            if identifier.trim().trim_matches('"') != FILES_APP_GROUP_IDENTIFIER {
                return None;
            }
            path.trim()
                .trim_end_matches([',', ';'])
                .trim()
                .trim_matches('"')
        };
        candidate.starts_with('/').then(|| PathBuf::from(candidate))
    })
}

async fn canonical_directory(path: &Path) -> Result<PathBuf, FilesError> {
    let metadata = fs::symlink_metadata(path).await.map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            FilesError::ProviderUnavailable(format!(
                "Files storage directory {} does not exist.",
                path.display()
            ))
        } else {
            FilesError::Io(error)
        }
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(FilesError::UnsafeStorage(format!(
            "Files storage directory {} is not a regular directory.",
            path.display()
        )));
    }
    fs::canonicalize(path).await.map_err(FilesError::Io)
}

async fn ensure_directory(path: &Path) -> Result<(), FilesError> {
    match fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
            Err(FilesError::UnsafeStorage(format!(
                "Files storage path {} is not a regular directory.",
                path.display()
            )))
        }
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir_all(path).await.map_err(FilesError::Io)
        }
        Err(error) => Err(FilesError::Io(error)),
    }
}

async fn reject_symlink_if_present(path: &Path) -> Result<(), FilesError> {
    match fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(FilesError::UnsafeStorage(
            format!("Files storage path {} is a symbolic link.", path.display()),
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(FilesError::Io(error)),
    }
}

async fn remove_regular_file_if_present(path: &Path) -> Result<(), FilesError> {
    match fs::symlink_metadata(path).await {
        Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
            Err(FilesError::UnsafeStorage(format!(
                "Refusing to remove non-regular Files storage path {}.",
                path.display()
            )))
        }
        Ok(_) => fs::remove_file(path).await.map_err(FilesError::Io),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(FilesError::Io(error)),
    }
}

async fn cleanup_stale_staging(staging: &Path) -> Result<(), FilesError> {
    let mut entries = fs::read_dir(staging).await.map_err(FilesError::Io)?;
    while let Some(entry) = entries.next_entry().await.map_err(FilesError::Io)? {
        if !entry.file_name().to_string_lossy().ends_with(".partial")
            || entry
                .file_type()
                .await
                .map_err(FilesError::Io)?
                .is_symlink()
        {
            continue;
        }
        let metadata = entry.metadata().await.map_err(FilesError::Io)?;
        let stale = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age >= STALE_STAGING_AGE);
        if stale && metadata.is_file() {
            fs::remove_file(entry.path())
                .await
                .map_err(FilesError::Io)?;
        }
    }
    Ok(())
}

fn new_opaque_id(parent_id: &str, name: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(parent_id.as_bytes());
    digest.update([0]);
    digest.update(name.as_bytes());
    digest.update([0]);
    digest.update(now_nanos().to_le_bytes());
    digest.update(ITEM_SEQUENCE.fetch_add(1, Ordering::Relaxed).to_le_bytes());
    digest.update(std::process::id().to_le_bytes());
    hex::encode(digest.finalize())[..ITEM_ID_HEX_LENGTH].to_owned()
}

pub fn new_transfer_id() -> String {
    new_opaque_id("transfer", "upload")
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_nanos()
}

#[cfg(test)]
mod tests {
    use super::{
        parse_group_container_output, validate_content_type, validate_file_name, FileItemKind,
        ProviderStore, FILES_APP_GROUP_IDENTIFIER, ROOT_ITEM_IDENTIFIER,
    };
    use bytes::Bytes;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn test_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "simdeck-files-test-{}-{name}-{}",
            std::process::id(),
            TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ))
    }

    async fn store(name: &str) -> (PathBuf, ProviderStore) {
        let root = test_root(name);
        tokio::fs::create_dir_all(&root).await.unwrap();
        let store = ProviderStore::open_test_root(&root).await.unwrap();
        (root, store)
    }

    #[test]
    fn validates_unicode_names_and_mime_types() {
        assert!(validate_file_name("Décompte 🌱.pdf").is_ok());
        assert!(validate_file_name("../secret.pdf").is_err());
        assert!(validate_file_name("nested/file.pdf").is_err());
        assert!(validate_content_type("application/pdf").is_ok());
        assert!(validate_content_type("not a mime type").is_err());
    }

    #[test]
    fn parses_app_group_container_output_variants() {
        let path = "/tmp/CoreSimulator/Shared/AppGroup/example";
        assert_eq!(
            parse_group_container_output(path),
            Some(PathBuf::from(path))
        );
        assert_eq!(
            parse_group_container_output(&format!("{FILES_APP_GROUP_IDENTIFIER} = {path}")),
            Some(PathBuf::from(path))
        );
    }

    #[tokio::test]
    async fn creates_uploads_renames_moves_and_deletes_trees() {
        let (root, store) = store("crud").await;
        let folder = store
            .create_directory(ROOT_ITEM_IDENTIFIER, "Statements")
            .await
            .unwrap();
        let mut upload = store
            .begin_upload("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            .await
            .unwrap();
        upload.write(Bytes::from_static(b"pdf-data")).await.unwrap();
        let file = store
            .commit_upload(upload, &folder.id, "Décompte.pdf", "application/pdf")
            .await
            .unwrap();

        assert_eq!(file.size, 8);
        assert_eq!(
            store.list(Some(&folder.id)).await.unwrap(),
            vec![file.clone()]
        );
        let renamed = store
            .update(&file.id, Some("Annual statement.pdf"), None)
            .await
            .unwrap();
        assert_eq!(renamed.version, 2);
        let (download, mut contents) = store.open_content(&file.id).await.unwrap();
        let mut bytes = Vec::new();
        tokio::io::AsyncReadExt::read_to_end(&mut contents, &mut bytes)
            .await
            .unwrap();
        assert_eq!(download.name, "Annual statement.pdf");
        assert_eq!(bytes, b"pdf-data");

        let deleted = store.delete(&folder.id).await.unwrap();
        assert_eq!(deleted.len(), 2);
        assert!(store.list(None).await.unwrap().is_empty());
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn isolates_provider_roots_and_cleans_interrupted_staging() {
        let (first_root, first) = store("first").await;
        let (second_root, second) = store("second").await;
        let transfer_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let mut upload = first.begin_upload(transfer_id).await.unwrap();
        upload.write(Bytes::from_static(b"partial")).await.unwrap();
        drop(upload);

        assert!(first.list(None).await.unwrap().is_empty());
        assert!(second.list(None).await.unwrap().is_empty());
        assert!(tokio::fs::read_dir(&first.staging)
            .await
            .unwrap()
            .next_entry()
            .await
            .unwrap()
            .is_none());
        tokio::fs::remove_dir_all(first_root).await.unwrap();
        tokio::fs::remove_dir_all(second_root).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlinked_content() {
        use std::os::unix::fs::symlink;

        let (root, store) = store("symlink").await;
        let mut upload = store
            .begin_upload("cccccccccccccccccccccccccccccccc")
            .await
            .unwrap();
        upload.write(Bytes::from_static(b"safe")).await.unwrap();
        let file = store
            .commit_upload(upload, ROOT_ITEM_IDENTIFIER, "safe.pdf", "application/pdf")
            .await
            .unwrap();
        let content = store.contents.join(&file.id);
        tokio::fs::remove_file(&content).await.unwrap();
        symlink("/etc/passwd", &content).unwrap();

        assert!(store.open_content(&file.id).await.is_err());
        tokio::fs::remove_dir_all(root).await.unwrap();
    }

    #[tokio::test]
    async fn directories_cannot_be_moved_into_descendants() {
        let (root, store) = store("cycle").await;
        let parent = store
            .create_directory(ROOT_ITEM_IDENTIFIER, "Parent")
            .await
            .unwrap();
        let child = store.create_directory(&parent.id, "Child").await.unwrap();
        assert!(store
            .update(&parent.id, None, Some(&child.id))
            .await
            .is_err());
        assert_eq!(child.kind, FileItemKind::Directory);
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
