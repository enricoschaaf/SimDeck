use crate::error::AppError;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;

const GREEN_GOT_DEEP_LINKS: &str = include_str!("../../../manifests/green-got-v2.json");

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepLinkManifest {
    pub scheme: String,
    pub bundle_id: Option<String>,
    pub links: Vec<DeepLinkDefinition>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepLinkDefinition {
    pub group: String,
    pub title: String,
    pub url: String,
    #[serde(default = "authentication_required")]
    pub requires_authentication: bool,
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub parameters: Vec<DeepLinkParameter>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepLinkParameter {
    pub name: String,
    pub label: Option<String>,
    pub placeholder: Option<String>,
    pub default: Option<String>,
}

fn authentication_required() -> bool {
    true
}

pub fn configured_manifest() -> Result<DeepLinkManifest, AppError> {
    let raw = match std::env::var_os("SIMDECK_DEEP_LINKS_PATH") {
        Some(path) => fs::read_to_string(&path).map_err(|error| {
            AppError::internal(format!(
                "Unable to read deep-link inventory {}: {error}",
                path.to_string_lossy()
            ))
        })?,
        None => GREEN_GOT_DEEP_LINKS.to_owned(),
    };
    parse_manifest(&raw)
}

fn parse_manifest(raw: &str) -> Result<DeepLinkManifest, AppError> {
    let manifest: DeepLinkManifest = serde_json::from_str(raw)
        .map_err(|error| AppError::internal(format!("Invalid deep-link inventory: {error}")))?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn validate_manifest(manifest: &DeepLinkManifest) -> Result<(), AppError> {
    if manifest.scheme.is_empty()
        || !manifest
            .scheme
            .chars()
            .enumerate()
            .all(|(index, character)| {
                character.is_ascii_alphanumeric()
                    || (index > 0 && matches!(character, '+' | '-' | '.'))
            })
    {
        return Err(AppError::internal(
            "Deep-link inventory has an invalid scheme.",
        ));
    }
    if manifest.links.is_empty() {
        return Err(AppError::internal("Deep-link inventory is empty."));
    }
    let prefix = format!("{}://", manifest.scheme);
    for link in &manifest.links {
        if link.group.trim().is_empty() || link.title.trim().is_empty() {
            return Err(AppError::internal(
                "Deep-link inventory entries require a group and title.",
            ));
        }
        if !link.url.starts_with(&prefix) {
            return Err(AppError::internal(format!(
                "Deep link `{}` must use the {} scheme.",
                link.title, manifest.scheme
            )));
        }
        let placeholders = placeholders(&link.url)?;
        let mut parameter_names = HashSet::new();
        for parameter in &link.parameters {
            if !placeholders.contains(parameter.name.as_str()) {
                return Err(AppError::internal(format!(
                    "Deep-link parameter `{}` is not present in `{}`.",
                    parameter.name, link.title
                )));
            }
            if !parameter_names.insert(parameter.name.as_str()) {
                return Err(AppError::internal(format!(
                    "Deep link `{}` repeats parameter `{}`.",
                    link.title, parameter.name
                )));
            }
        }
    }
    Ok(())
}

fn placeholders(url: &str) -> Result<HashSet<&str>, AppError> {
    let mut names = HashSet::new();
    let mut remainder = url;
    while let Some(start) = remainder.find('{') {
        let after_start = &remainder[start + 1..];
        let Some(end) = after_start.find('}') else {
            return Err(AppError::internal("Deep-link placeholder is not closed."));
        };
        let name = &after_start[..end];
        if name.is_empty()
            || !name.chars().enumerate().all(|(index, character)| {
                character.is_ascii_alphanumeric() || (index > 0 && matches!(character, '_' | '-'))
            })
        {
            return Err(AppError::internal(format!(
                "Deep-link placeholder `{name}` is invalid."
            )));
        }
        names.insert(name);
        remainder = &after_start[end + 1..];
    }
    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::{parse_manifest, GREEN_GOT_DEEP_LINKS};

    #[test]
    fn bundled_green_got_inventory_is_valid() {
        let manifest = parse_manifest(GREEN_GOT_DEEP_LINKS).unwrap();

        assert_eq!(manifest.scheme, "green-got-staging");
        assert_eq!(manifest.links.len(), 52);
        assert_eq!(
            manifest
                .links
                .iter()
                .filter(|link| !link.requires_authentication)
                .count(),
            2
        );
    }

    #[test]
    fn rejects_entries_using_another_scheme() {
        let result = parse_manifest(
            r#"{"scheme":"demo","links":[{"group":"Home","title":"Bad","url":"other://home"}]}"#,
        );

        assert!(result.is_err());
    }
}
