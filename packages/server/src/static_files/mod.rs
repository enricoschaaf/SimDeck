use crate::auth;
use axum::body::Body;
use axum::http::{header, HeaderValue, Method, Response, StatusCode, Uri};
use std::path::{Component, Path, PathBuf};

pub async fn serve_static(
    root: PathBuf,
    method: Method,
    uri: Uri,
    access_token: Option<String>,
) -> Result<Response<Body>, StatusCode> {
    serve_static_inner(root, None, true, method, uri, access_token).await
}

pub async fn serve_static_under(
    root: PathBuf,
    mount_prefix: &str,
    method: Method,
    uri: Uri,
    access_token: Option<String>,
) -> Result<Response<Body>, StatusCode> {
    serve_static_inner(root, Some(mount_prefix), false, method, uri, access_token).await
}

async fn serve_static_inner(
    root: PathBuf,
    mount_prefix: Option<&str>,
    fallback_to_index: bool,
    method: Method,
    uri: Uri,
    access_token: Option<String>,
) -> Result<Response<Body>, StatusCode> {
    if method != Method::GET && method != Method::HEAD {
        return Err(StatusCode::METHOD_NOT_ALLOWED);
    }

    let mut path = uri.path();
    if let Some(prefix) = mount_prefix {
        path = path
            .strip_prefix(prefix)
            .ok_or(StatusCode::NOT_FOUND)?
            .trim_start_matches('/');
    }
    let Some(relative_path) = safe_relative_path(path) else {
        return Err(StatusCode::BAD_REQUEST);
    };

    let requested_path = root.join(&relative_path);
    let (file_path, immutable_asset) = match tokio::fs::metadata(&requested_path).await {
        Ok(metadata) if metadata.is_file() => (
            requested_path,
            fallback_to_index && relative_path.starts_with("assets"),
        ),
        _ if fallback_to_index => (root.join("index.html"), false),
        _ => return Err(StatusCode::NOT_FOUND),
    };

    let bytes = tokio::fs::read(&file_path)
        .await
        .map_err(|_| StatusCode::NOT_FOUND)?;
    let content_type = content_type_for_path(&file_path);
    let cache_control = if immutable_asset {
        "public, max-age=31536000, immutable"
    } else {
        "no-cache"
    };
    let content_length = bytes.len();
    let body = if method == Method::HEAD {
        Body::empty()
    } else {
        Body::from(bytes)
    };

    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, cache_control)
        .header(header::CONTENT_LENGTH, content_length)
        .body(body)
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    response.headers_mut().insert(
        header::ACCESS_CONTROL_ALLOW_ORIGIN,
        "*".parse().map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?,
    );
    if let Some(access_token) = access_token.filter(|_| content_type.starts_with("text/html")) {
        let cookie = HeaderValue::from_str(&auth::access_cookie_value(&access_token))
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        response.headers_mut().insert(header::SET_COOKIE, cookie);
    }
    Ok(response)
}

fn safe_relative_path(path: &str) -> Option<PathBuf> {
    let trimmed = path.trim_start_matches('/');
    if trimmed.is_empty() {
        return Some(PathBuf::from("index.html"));
    }

    let mut relative = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            Component::Normal(part) => relative.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    Some(relative)
}

fn content_type_for_path(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("css") => "text/css; charset=utf-8",
        Some("html") => "text/html; charset=utf-8",
        Some("ico") => "image/x-icon",
        Some("avif") => "image/avif",
        Some("js") | Some("mjs") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("map") => "application/json; charset=utf-8",
        Some("png") => "image/png",
        Some("svg") => "image/svg+xml",
        Some("wasm") => "application/wasm",
        Some("webp") => "image/webp",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[tokio::test]
    async fn client_assets_are_cacheable_without_clearing_the_browser_cache() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "simdeck-static-files-{}-{stamp}",
            std::process::id()
        ));
        std::fs::create_dir_all(root.join("assets")).unwrap();
        std::fs::write(root.join("index.html"), "<main>SimDeck</main>").unwrap();
        std::fs::write(root.join("assets/index-hash.js"), "export default 1;").unwrap();

        let asset = serve_static(
            root.clone(),
            Method::GET,
            Uri::from_static("/assets/index-hash.js"),
            Some("secret-token".to_owned()),
        )
        .await
        .unwrap();
        assert_eq!(
            asset.headers().get(header::CACHE_CONTROL).unwrap(),
            "public, max-age=31536000, immutable"
        );
        assert!(!asset.headers().contains_key("clear-site-data"));
        assert!(!asset.headers().contains_key(header::SET_COOKIE));

        let document = serve_static(
            root.clone(),
            Method::GET,
            Uri::from_static("/"),
            Some("secret-token".to_owned()),
        )
        .await
        .unwrap();
        assert_eq!(
            document.headers().get(header::CACHE_CONTROL).unwrap(),
            "no-cache"
        );
        assert!(!document.headers().contains_key("clear-site-data"));
        assert!(document.headers().contains_key(header::SET_COOKIE));

        std::fs::remove_dir_all(root).unwrap();
    }
}
