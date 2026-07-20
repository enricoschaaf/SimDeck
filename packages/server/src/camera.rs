use crate::error::AppError;
use crate::native::ffi;
use bytes::Bytes;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::ffi::{c_char, c_void, CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub mod webrtc;

const CAMERA_INJECTOR_NAME: &str = "libSimDeckCameraInjector.dylib";
const CAMERA_TARGETS: &str = "com.apple.WebKit.GPU,__SIMDECK_USER_APPS__";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CameraSourceKind {
    Placeholder,
    Image,
    Video,
    Camera,
}

impl CameraSourceKind {
    fn as_native_arg(&self) -> &'static str {
        match self {
            Self::Placeholder => "placeholder",
            Self::Image => "image",
            Self::Video => "video",
            Self::Camera => "camera",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraSource {
    pub kind: CameraSourceKind,
    #[serde(default)]
    pub arg: Option<String>,
}

impl Default for CameraSource {
    fn default() -> Self {
        Self {
            kind: CameraSourceKind::Placeholder,
            arg: None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraStartRequest {
    #[serde(default)]
    pub source: CameraSource,
    #[serde(default)]
    pub mirror: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CameraSwitchRequest {
    pub source: CameraSource,
    #[serde(default)]
    pub mirror: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CameraStartOptions {
    pub udid: String,
    pub source: CameraSource,
    pub mirror: Option<String>,
}

pub fn start_camera(options: CameraStartOptions) -> Result<Value, AppError> {
    validate_udid(&options.udid)?;
    let source = normalize_source(options.source)?;
    let mirror = normalize_mirror(options.mirror.as_deref())?;
    fs::create_dir_all(camera_state_dir()).map_err(app_internal)?;

    let shm_name = shm_name_for_udid(&options.udid);
    native_start_camera(&options.udid, &shm_name, &source, &mirror)?;

    let mut status = native_status(&options.udid)?;
    enrich_status(&options.udid, &mut status);
    Ok(status)
}

pub fn ensure_idle_camera(udid: &str) -> Result<Value, AppError> {
    validate_udid(udid)?;
    let status = native_status(udid)?;
    if status.get("alive").and_then(Value::as_bool) == Some(true) {
        return Ok(status);
    }
    start_camera(CameraStartOptions {
        udid: udid.to_owned(),
        source: CameraSource {
            kind: CameraSourceKind::Camera,
            arg: None,
        },
        mirror: Some("on".to_owned()),
    })
}

pub fn prepare_camera_runtime(udid: &str) -> Result<Value, AppError> {
    validate_udid(udid)?;
    let injector = camera_injector_path()?;
    let status = ensure_idle_camera(udid)?;
    let injector = injector
        .to_str()
        .ok_or_else(|| AppError::native("Camera injector path is not valid UTF-8."))?;
    let shared_memory_name = shm_name_for_udid(udid);
    for (name, value) in [
        ("DYLD_INSERT_LIBRARIES", injector),
        ("SIMDECK_CAMERA_SHM_NAME", shared_memory_name.as_str()),
        ("SIMDECK_CAMERA_MIRROR", "on"),
        ("SIMDECK_CAMERA_TARGET_BUNDLE_IDS", CAMERA_TARGETS),
    ] {
        let output = Command::new("/usr/bin/xcrun")
            .args(["simctl", "spawn", udid, "launchctl", "setenv", name, value])
            .output()
            .map_err(|error| {
                AppError::native(format!("Unable to configure camera injection. {error}"))
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            return Err(AppError::native(if stderr.is_empty() {
                "Unable to configure camera injection.".to_owned()
            } else {
                format!("Unable to configure camera injection. {stderr}")
            }));
        }
    }
    Ok(status)
}

pub fn switch_camera(
    udid: &str,
    source: CameraSource,
    mirror: Option<String>,
) -> Result<Value, AppError> {
    validate_udid(udid)?;
    let source = normalize_source(source)?;
    let mirror = match mirror {
        Some(value) => Some(normalize_mirror(Some(&value))?),
        None => None,
    };
    let mut status = native_switch_camera(udid, &source, mirror.as_deref())?;
    enrich_status(udid, &mut status);
    Ok(status)
}

pub fn camera_status(udid: &str) -> Result<Value, AppError> {
    validate_udid(udid)?;
    let mut status = native_status(udid)?;
    enrich_status(udid, &mut status);
    Ok(status)
}

pub fn stop_camera(udid: &str) -> Result<Value, AppError> {
    validate_udid(udid)?;
    let status = native_status(udid)?;
    if status.get("alive").and_then(Value::as_bool) != Some(true) {
        return Ok(status);
    }
    native_switch_camera(
        udid,
        &CameraSource {
            kind: CameraSourceKind::Camera,
            arg: None,
        },
        None,
    )
}

pub fn configure_camera_decoder(udid: &str, configuration: &[u8]) -> Result<(), AppError> {
    validate_udid(udid)?;
    if configuration.is_empty() || configuration.len() > 2 * 1024 * 1024 {
        return Err(AppError::bad_request(
            "Camera H.264 configuration must contain between 1 byte and 2 MiB.",
        ));
    }
    let udid = cstring("simulator UDID", udid)?;
    let mut error_message = std::ptr::null_mut();
    let ok = unsafe {
        ffi::simdeck_camera_configure_h264(
            udid.as_ptr(),
            configuration.as_ptr(),
            configuration.len(),
            &mut error_message,
        )
    };
    if ok {
        Ok(())
    } else {
        Err(native_error(
            error_message,
            "Unable to configure the camera H.264 decoder.",
        ))
    }
}

pub fn decode_camera_frame(
    udid: &str,
    frame: Bytes,
    key_frame: bool,
    sequence: u32,
    assembled_timestamp_ns: u64,
) -> Result<(), AppError> {
    validate_udid(udid)?;
    if frame.is_empty() || frame.len() > 2 * 1024 * 1024 {
        return Err(AppError::bad_request(
            "Camera H.264 frame must contain between 1 byte and 2 MiB.",
        ));
    }
    let udid = cstring("simulator UDID", udid)?;
    let frame = Box::new(frame);
    let frame_data = frame.as_ptr();
    let frame_length = frame.len();
    let owner = Box::into_raw(frame).cast::<c_void>();
    let mut error_message = std::ptr::null_mut();
    let ok = unsafe {
        ffi::simdeck_camera_decode_h264_frame(
            udid.as_ptr(),
            frame_data,
            frame_length,
            key_frame,
            sequence,
            assembled_timestamp_ns,
            owner,
            Some(release_camera_frame),
            &mut error_message,
        )
    };
    if ok {
        Ok(())
    } else {
        Err(native_error(
            error_message,
            "Unable to decode the camera H.264 frame.",
        ))
    }
}

unsafe extern "C" fn release_camera_frame(owner: *mut c_void) {
    if !owner.is_null() {
        drop(unsafe { Box::from_raw(owner.cast::<Bytes>()) });
    }
}

fn native_start_camera(
    udid: &str,
    shm_name: &str,
    source: &CameraSource,
    mirror: &str,
) -> Result<(), AppError> {
    let udid = cstring("simulator UDID", udid)?;
    let shm_name = cstring("shared memory name", shm_name)?;
    let source_name = cstring("camera source", source.kind.as_native_arg())?;
    let source_arg = cstring(
        "camera source argument",
        source.arg.as_deref().unwrap_or(""),
    )?;
    let mirror = cstring("camera mirror", mirror)?;
    let mut error_message = std::ptr::null_mut();
    let ok = unsafe {
        ffi::simdeck_camera_start(
            udid.as_ptr(),
            shm_name.as_ptr(),
            source_name.as_ptr(),
            source_arg.as_ptr(),
            mirror.as_ptr(),
            &mut error_message,
        )
    };
    if ok {
        Ok(())
    } else {
        Err(native_error(
            error_message,
            "Unable to start the camera daemon.",
        ))
    }
}

fn native_status(udid: &str) -> Result<Value, AppError> {
    let udid = cstring("simulator UDID", udid)?;
    let mut error_message = std::ptr::null_mut();
    let raw = unsafe { ffi::simdeck_camera_status(udid.as_ptr(), &mut error_message) };
    native_json(raw, error_message, "Unable to read camera status.")
}

fn native_switch_camera(
    udid: &str,
    source: &CameraSource,
    mirror: Option<&str>,
) -> Result<Value, AppError> {
    let udid = cstring("simulator UDID", udid)?;
    let source_name = cstring("camera source", source.kind.as_native_arg())?;
    let source_arg = cstring(
        "camera source argument",
        source.arg.as_deref().unwrap_or(""),
    )?;
    let mirror = cstring("camera mirror", mirror.unwrap_or(""))?;
    let mut error_message = std::ptr::null_mut();
    let raw = unsafe {
        ffi::simdeck_camera_switch(
            udid.as_ptr(),
            source_name.as_ptr(),
            source_arg.as_ptr(),
            mirror.as_ptr(),
            &mut error_message,
        )
    };
    native_json(raw, error_message, "Unable to switch camera source.")
}

fn native_json(
    raw: *mut c_char,
    error_message: *mut c_char,
    fallback: &'static str,
) -> Result<Value, AppError> {
    if raw.is_null() {
        return Err(native_error(error_message, fallback));
    }
    let text = take_native_string(raw);
    serde_json::from_str(&text)
        .map_err(|error| AppError::internal(format!("Unable to parse camera JSON. {error}")))
}

fn native_error(raw: *mut c_char, fallback: &'static str) -> AppError {
    if raw.is_null() {
        return AppError::native(fallback);
    }
    let message = take_native_string(raw);
    if message.trim().is_empty() {
        AppError::native(fallback)
    } else {
        AppError::native(message)
    }
}

fn take_native_string(raw: *mut c_char) -> String {
    let value = unsafe { CStr::from_ptr(raw).to_string_lossy().into_owned() };
    unsafe { ffi::xcw_native_free_string(raw) };
    value
}

fn cstring(name: &str, value: &str) -> Result<CString, AppError> {
    CString::new(value).map_err(|_| AppError::bad_request(format!("{name} contains NUL byte.")))
}

fn normalize_source(mut source: CameraSource) -> Result<CameraSource, AppError> {
    if let Some(arg) = source.arg.as_deref() {
        let trimmed = arg.trim();
        source.arg = (!trimmed.is_empty()).then(|| trimmed.to_owned());
    }
    match source.kind {
        CameraSourceKind::Placeholder | CameraSourceKind::Camera => {
            source.arg = None;
        }
        CameraSourceKind::Image | CameraSourceKind::Video => {
            let arg = source.arg.as_deref().ok_or_else(|| {
                AppError::bad_request("Camera file or stream source requires `arg`.")
            })?;
            if !is_url(arg) {
                let path = Path::new(arg);
                if !path.is_absolute() {
                    return Err(AppError::bad_request(
                        "Camera file source must be an absolute path.",
                    ));
                }
                if !path.exists() {
                    return Err(AppError::not_found(format!(
                        "Camera media source does not exist: {}",
                        path.display()
                    )));
                }
            }
        }
    }
    Ok(source)
}

pub fn file_source(path_or_url: &str) -> CameraSource {
    let kind = if is_video_source(path_or_url) {
        CameraSourceKind::Video
    } else {
        CameraSourceKind::Image
    };
    CameraSource {
        kind,
        arg: Some(path_or_url.to_owned()),
    }
}

fn is_url(value: &str) -> bool {
    value.starts_with("http://") || value.starts_with("https://") || value.starts_with("file://")
}

fn is_video_source(value: &str) -> bool {
    if is_url(value) {
        return true;
    }
    let ext = Path::new(value)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    matches!(
        ext.as_str(),
        "mp4" | "m4v" | "mov" | "qt" | "avi" | "mkv" | "webm" | "mpg" | "mpeg" | "3gp" | "3g2"
    )
}

fn normalize_mirror(value: Option<&str>) -> Result<String, AppError> {
    let normalized = value.unwrap_or("auto").trim().to_ascii_lowercase();
    match normalized.as_str() {
        "auto" | "on" | "off" => Ok(normalized),
        _ => Err(AppError::bad_request(
            "Camera mirror must be one of `auto`, `on`, or `off`.",
        )),
    }
}

fn validate_udid(udid: &str) -> Result<(), AppError> {
    if udid.trim().is_empty() || udid.contains('/') || udid.contains('\0') {
        return Err(AppError::bad_request("Invalid simulator UDID."));
    }
    Ok(())
}

fn enrich_status(udid: &str, status: &mut Value) {
    let Some(object) = status.as_object_mut() else {
        return;
    };
    object.insert("udid".to_owned(), Value::String(udid.to_owned()));
    if let Some(pid) = object
        .get("processId")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
    {
        object.insert("daemonPid".to_owned(), json!(pid));
    }
    object.insert(
        "appLogPath".to_owned(),
        Value::String(camera_app_log_file(udid).display().to_string()),
    );
    webrtc::enrich_status(udid, object);
}

fn camera_state_dir() -> PathBuf {
    std::env::temp_dir().join("simdeck-camera")
}

fn camera_injector_path() -> Result<PathBuf, AppError> {
    let executable = std::env::current_exe()
        .map_err(|error| AppError::internal(format!("Unable to resolve SimDeck. {error}")))?;
    let executable_directory = executable
        .parent()
        .ok_or_else(|| AppError::internal("The SimDeck executable has no containing directory."))?;
    let path = executable_directory
        .join("camera")
        .join(CAMERA_INJECTOR_NAME);
    if path.is_file() {
        Ok(path)
    } else {
        Err(AppError::native(format!(
            "Camera injector is missing at {}.",
            path.display()
        )))
    }
}

fn camera_app_log_file(udid: &str) -> PathBuf {
    camera_state_dir().join(format!("{}.app.log", short_hash(udid)))
}

fn shm_name_for_udid(udid: &str) -> String {
    format!("/sd-cam-{}", short_hash(udid))
}

fn short_hash(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    hex::encode(&digest[..6])
}

fn app_internal(error: impl std::fmt::Display) -> AppError {
    AppError::internal(error.to_string())
}
