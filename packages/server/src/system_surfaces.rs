use crate::device_events::DeviceEventHub;
use crate::uikit_services::{
    application_service_details, application_services, service_bundle_identifier,
    UIKitApplicationService, UIKitApplicationServiceDetails,
};
use serde::Serialize;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const SURFACE_POLL_INTERVAL: Duration = Duration::from_millis(250);
const DOCUMENT_PICKER_BUNDLE_IDENTIFIERS: &[&str] = &[
    "com.apple.DocumentsApp.DocumentsViewService",
    "com.apple.DocumentManager.DocumentPickerViewService",
    "com.apple.DocumentManager.Service",
];

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemSurface {
    pub kind: String,
    pub process_identifier: i64,
    pub session_id: String,
}

#[derive(Clone, Default)]
pub struct SystemSurfaceRegistry {
    inner: Arc<Mutex<SystemSurfaceRegistryState>>,
}

#[derive(Default)]
struct SystemSurfaceRegistryState {
    current: HashMap<String, SystemSurface>,
    monitoring: HashSet<String>,
}

impl SystemSurfaceRegistry {
    pub fn current(&self, udid: &str) -> Option<SystemSurface> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .current
            .get(udid)
            .cloned()
    }

    pub async fn probe(
        &self,
        udid: &str,
        events: &DeviceEventHub,
    ) -> Result<Option<SystemSurface>, String> {
        let surface = detect_document_picker(udid).await?;
        self.set(udid, surface.clone(), events);
        Ok(surface)
    }

    pub fn ensure_monitor(&self, udid: String, events: DeviceEventHub) {
        let should_start = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .monitoring
            .insert(udid.clone());
        if !should_start {
            return;
        }

        let registry = self.clone();
        tokio::spawn(async move {
            loop {
                if let Err(error) = registry.probe(&udid, &events).await {
                    tracing::debug!("Unable to inspect UIKit system surface for {udid}: {error}");
                }
                tokio::time::sleep(SURFACE_POLL_INTERVAL).await;
            }
        });
    }

    pub fn clear(&self, udid: &str, events: &DeviceEventHub) {
        self.set(udid, None, events);
    }

    fn set(&self, udid: &str, surface: Option<SystemSurface>, events: &DeviceEventHub) {
        let changed = {
            let mut state = self
                .inner
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let previous = state.current.get(udid).cloned();
            if previous == surface {
                false
            } else {
                match &surface {
                    Some(surface) => {
                        state.current.insert(udid.to_owned(), surface.clone());
                    }
                    None => {
                        state.current.remove(udid);
                    }
                }
                true
            }
        };
        if changed {
            events.publish(
                udid,
                json!({
                    "type": "system-surface.changed",
                    "udid": udid,
                    "systemSurface": surface,
                }),
            );
        }
    }
}

pub fn is_document_picker_service(details: &UIKitApplicationServiceDetails) -> bool {
    details.spawn_role.contains("ui focal")
        && document_picker_identifier(details.bundle_identifier.as_deref())
            .or_else(|| {
                document_picker_identifier(service_bundle_identifier(&details.service_name))
            })
            .is_some()
}

async fn detect_document_picker(udid: &str) -> Result<Option<SystemSurface>, String> {
    let services = application_services(udid).await?;
    let mut best: Option<UIKitApplicationServiceDetails> = None;
    for service in services
        .iter()
        .filter(|service| service_might_be_document_picker(service))
    {
        let Some(details) = application_service_details(udid, service).await? else {
            continue;
        };
        if !is_document_picker_service(&details) {
            continue;
        }
        if best
            .as_ref()
            .is_none_or(|current| details.active_count > current.active_count)
        {
            best = Some(details);
        }
    }

    Ok(best.map(|details| SystemSurface {
        kind: "documentPicker".to_owned(),
        process_identifier: details.process_identifier,
        session_id: surface_session_id(udid, &details),
    }))
}

fn service_might_be_document_picker(service: &UIKitApplicationService) -> bool {
    document_picker_identifier(service_bundle_identifier(&service.service_name)).is_some()
}

fn document_picker_identifier(identifier: Option<&str>) -> Option<&str> {
    let identifier = identifier?;
    DOCUMENT_PICKER_BUNDLE_IDENTIFIERS
        .contains(&identifier)
        .then_some(identifier)
}

fn surface_session_id(udid: &str, details: &UIKitApplicationServiceDetails) -> String {
    let mut hasher = DefaultHasher::new();
    udid.hash(&mut hasher);
    details.service_name.hash(&mut hasher);
    details.process_identifier.hash(&mut hasher);
    details.active_count.hash(&mut hasher);
    format!("surface-{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::{is_document_picker_service, surface_session_id};
    use crate::uikit_services::{
        application_service_details_from_output, parse_application_service_line,
    };

    const IOS_18_DOCUMENT_PICKER_LIST_TRACE: &str =
        "  54831 - UIKitApplication:com.apple.DocumentsApp.DocumentsViewService[beef][rb-legacy]";
    const IOS_18_DOCUMENT_PICKER_DETAIL_TRACE: &str = r#"
        active count = 2
        state = running
        program = /System/Applications/Files.app/PlugIns/DocumentsViewService.appex/DocumentsViewService
        bundle id = com.apple.DocumentsApp.DocumentsViewService
        spawn role = ui focal (1)
        pid = 54831
    "#;

    #[test]
    fn recognizes_focal_documents_view_service_trace() {
        let service = parse_application_service_line(IOS_18_DOCUMENT_PICKER_LIST_TRACE).unwrap();
        let details =
            application_service_details_from_output(&service, IOS_18_DOCUMENT_PICKER_DETAIL_TRACE)
                .unwrap();

        assert!(is_document_picker_service(&details));
        assert_eq!(
            surface_session_id("device-a", &details),
            surface_session_id("device-a", &details)
        );
        assert_ne!(
            surface_session_id("device-a", &details),
            surface_session_id("device-b", &details)
        );
    }

    #[test]
    fn rejects_nonfocal_and_unknown_services() {
        let service = parse_application_service_line(IOS_18_DOCUMENT_PICKER_LIST_TRACE).unwrap();
        let background = application_service_details_from_output(
            &service,
            &IOS_18_DOCUMENT_PICKER_DETAIL_TRACE.replace("ui focal (1)", "non-ui (3)"),
        )
        .unwrap();
        assert!(!is_document_picker_service(&background));

        let unknown_service = parse_application_service_line(
            "  54832 - UIKitApplication:com.apple.SomeViewService[beef][rb-legacy]",
        )
        .unwrap();
        let unknown = application_service_details_from_output(
            &unknown_service,
            &IOS_18_DOCUMENT_PICKER_DETAIL_TRACE.replace(
                "com.apple.DocumentsApp.DocumentsViewService",
                "com.apple.SomeViewService",
            ),
        )
        .unwrap();
        assert!(!is_document_picker_service(&unknown));
    }
}
