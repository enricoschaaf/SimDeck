use bytes::Bytes;
use std::env;
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error;
use tokio::fs::{self, File, OpenOptions};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::time::timeout;

const MEDIA_IMPORT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Error)]
pub enum MediaError {
    #[error("{0}")]
    InvalidInput(String),
    #[error("Media transfer failed: {0}")]
    Io(std::io::Error),
    #[error("CoreSimulator rejected the media import: {0}")]
    Rejected(String),
    #[error("CoreSimulator media import timed out.")]
    Timeout,
}

pub struct MediaUpload {
    udid: String,
    file_name: String,
    content_type: String,
    path: PathBuf,
    file: Option<File>,
    bytes_written: u64,
}

impl MediaUpload {
    pub async fn begin(
        udid: &str,
        transfer_id: &str,
        file_name: &str,
        content_type: &str,
    ) -> Result<Self, MediaError> {
        validate_media(file_name, content_type)?;
        if udid.is_empty()
            || !udid
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(MediaError::InvalidInput(
                "Simulator UDID is invalid.".to_owned(),
            ));
        }
        if transfer_id.is_empty() || !transfer_id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(MediaError::InvalidInput(
                "Media transfer identifier is invalid.".to_owned(),
            ));
        }
        let extension = Path::new(file_name)
            .extension()
            .and_then(|value| value.to_str())
            .ok_or_else(|| {
                MediaError::InvalidInput("Media filename requires an extension.".to_owned())
            })?;
        let directory = env::temp_dir().join("simdeck").join("media").join(udid);
        fs::create_dir_all(&directory)
            .await
            .map_err(MediaError::Io)?;
        let path = directory.join(format!("{transfer_id}.{extension}"));
        let file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&path)
            .await
            .map_err(MediaError::Io)?;
        Ok(Self {
            udid: udid.to_owned(),
            file_name: file_name.to_owned(),
            content_type: content_type.to_owned(),
            path,
            file: Some(file),
            bytes_written: 0,
        })
    }

    pub async fn write(&mut self, chunk: Bytes) -> Result<u64, MediaError> {
        let file = self.file.as_mut().ok_or_else(|| {
            MediaError::InvalidInput("Media upload is already finalized.".to_owned())
        })?;
        file.write_all(&chunk).await.map_err(MediaError::Io)?;
        self.bytes_written = self.bytes_written.saturating_add(chunk.len() as u64);
        Ok(self.bytes_written)
    }

    pub fn bytes_written(&self) -> u64 {
        self.bytes_written
    }

    pub async fn import(mut self) -> Result<MediaImport, MediaError> {
        let Some(file) = self.file.take() else {
            return Err(MediaError::InvalidInput(
                "Media upload is already finalized.".to_owned(),
            ));
        };
        file.sync_data().await.map_err(MediaError::Io)?;
        drop(file);

        let output = timeout(
            MEDIA_IMPORT_TIMEOUT,
            Command::new("xcrun")
                .args(self.command_arguments())
                .output(),
        )
        .await
        .map_err(|_| MediaError::Timeout)?
        .map_err(MediaError::Io)?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            return Err(MediaError::Rejected(if stderr.is_empty() {
                stdout
            } else {
                stderr
            }));
        }
        Ok(MediaImport {
            udid: self.udid.clone(),
            file_name: self.file_name.clone(),
            content_type: self.content_type.clone(),
            bytes: self.bytes_written,
        })
    }

    fn command_arguments(&self) -> [&str; 4] {
        [
            "simctl",
            "addmedia",
            self.udid.as_str(),
            self.path.to_str().unwrap_or_default(),
        ]
    }
}

impl Drop for MediaUpload {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaImport {
    pub udid: String,
    pub file_name: String,
    pub content_type: String,
    pub bytes: u64,
}

pub fn validate_media(file_name: &str, content_type: &str) -> Result<(), MediaError> {
    if file_name.is_empty()
        || file_name == "."
        || file_name == ".."
        || file_name.len() > 255
        || file_name.contains('/')
        || file_name.contains('\0')
        || file_name.chars().any(char::is_control)
    {
        return Err(MediaError::InvalidInput(
            "Media filename must be one Unicode path component up to 255 bytes.".to_owned(),
        ));
    }
    let extension = Path::new(file_name)
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .ok_or_else(|| {
            MediaError::InvalidInput("Media filename requires an extension.".to_owned())
        })?;
    let supported = matches!(
        (extension.as_str(), content_type),
        ("jpg" | "jpeg", "image/jpeg")
            | ("png", "image/png")
            | ("heic" | "heif", "image/heic" | "image/heif")
            | ("gif", "image/gif")
            | ("mp4", "video/mp4")
            | ("mov", "video/quicktime")
    );
    if !supported {
        return Err(MediaError::InvalidInput(format!(
            "Unsupported media filename/content type combination: {file_name:?} ({content_type})."
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{validate_media, MediaUpload};
    use bytes::Bytes;

    #[test]
    fn validates_supported_media_pairs() {
        for (name, content_type) in [
            ("photo.jpg", "image/jpeg"),
            ("photo.PNG", "image/png"),
            ("photo.heic", "image/heic"),
            ("animation.gif", "image/gif"),
            ("movie.mp4", "video/mp4"),
            ("movie.mov", "video/quicktime"),
        ] {
            assert!(validate_media(name, content_type).is_ok());
        }
        assert!(validate_media("../photo.jpg", "image/jpeg").is_err());
        assert!(validate_media("photo.jpg", "image/png").is_err());
        assert!(validate_media("document.pdf", "application/pdf").is_err());
    }

    #[tokio::test]
    async fn interrupted_upload_removes_device_scoped_staging() {
        let transfer_id = format!("{:032x}", std::process::id());
        let mut upload = MediaUpload::begin(
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            &transfer_id,
            "Décompte.png",
            "image/png",
        )
        .await
        .unwrap();
        upload.write(Bytes::from_static(b"png")).await.unwrap();
        let path = upload.path.clone();
        assert!(path
            .to_string_lossy()
            .contains("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"));
        drop(upload);
        assert!(!path.exists());
    }
}
