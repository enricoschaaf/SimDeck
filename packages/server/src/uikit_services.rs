use std::time::Duration;
use tokio::process::Command;
use tokio::time::timeout;

const SERVICE_COMMAND_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Debug)]
pub struct UIKitApplicationService {
    pub pid: i64,
    pub service_name: String,
}

#[derive(Clone, Debug)]
pub struct UIKitApplicationServiceDetails {
    pub active_count: u64,
    pub app_name: Option<String>,
    pub bundle_identifier: Option<String>,
    pub process_identifier: i64,
    pub service_name: String,
    pub spawn_role: String,
}

pub async fn application_services(udid: &str) -> Result<Vec<UIKitApplicationService>, String> {
    let output = timeout(
        SERVICE_COMMAND_TIMEOUT,
        Command::new("xcrun")
            .args(["simctl", "spawn", udid, "launchctl", "print", "user/501"])
            .output(),
    )
    .await
    .map_err(|_| "Timed out listing simulator UIKit applications.".to_owned())?
    .map_err(|error| format!("Unable to list simulator UIKit applications: {error}"))?;
    if !output.status.success() {
        return Ok(Vec::new());
    }

    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(parse_application_service_line)
        .collect())
}

pub fn parse_application_service_line(line: &str) -> Option<UIKitApplicationService> {
    let trimmed = line.trim();
    if !trimmed.contains("UIKitApplication:") {
        return None;
    }
    let mut parts = trimmed.split_whitespace();
    let pid = parts.next()?.parse::<i64>().ok()?;
    let separator = parts.next()?;
    let service_name = parts.next()?.to_owned();
    if separator != "-" || pid <= 0 || !service_name.starts_with("UIKitApplication:") {
        return None;
    }
    Some(UIKitApplicationService { pid, service_name })
}

pub async fn application_service_details(
    udid: &str,
    service: &UIKitApplicationService,
) -> Result<Option<UIKitApplicationServiceDetails>, String> {
    let output = timeout(
        SERVICE_COMMAND_TIMEOUT,
        Command::new("xcrun")
            .args([
                "simctl",
                "spawn",
                udid,
                "launchctl",
                "print",
                &format!("user/501/{}", service.service_name),
            ])
            .output(),
    )
    .await
    .map_err(|_| "Timed out reading simulator UIKit application state.".to_owned())?
    .map_err(|error| format!("Unable to read simulator UIKit application state: {error}"))?;
    if !output.status.success() {
        return Ok(None);
    }

    Ok(application_service_details_from_output(
        service,
        &String::from_utf8_lossy(&output.stdout),
    ))
}

pub fn application_service_details_from_output(
    service: &UIKitApplicationService,
    output: &str,
) -> Option<UIKitApplicationServiceDetails> {
    let active_count = launchctl_numeric_value(output, "active count").unwrap_or(0);
    let process_identifier = launchctl_numeric_value(output, "pid")
        .map(|pid| pid as i64)
        .unwrap_or(service.pid);
    if process_identifier <= 0
        || launchctl_value(output, "state").is_none_or(|value| value != "running")
    {
        return None;
    }
    let spawn_role = launchctl_value(output, "spawn role").unwrap_or_default();
    let program = launchctl_value(output, "program");
    let bundle_identifier = launchctl_value(output, "bundle id");
    let app_name = program
        .as_deref()
        .and_then(app_bundle_path_from_command)
        .and_then(|path| {
            std::path::Path::new(&path)
                .file_stem()
                .and_then(|name| name.to_str())
                .map(ToOwned::to_owned)
        })
        .or_else(|| bundle_identifier.clone());

    Some(UIKitApplicationServiceDetails {
        active_count,
        app_name,
        bundle_identifier,
        process_identifier,
        service_name: service.service_name.clone(),
        spawn_role,
    })
}

pub fn application_foreground_score(details: &UIKitApplicationServiceDetails) -> (u8, u64) {
    let role_score = if details.spawn_role.contains("ui focal") {
        2
    } else if details.spawn_role.contains("ui") {
        1
    } else {
        0
    };
    (role_score, details.active_count)
}

pub fn service_bundle_identifier(service_name: &str) -> Option<&str> {
    service_name
        .strip_prefix("UIKitApplication:")?
        .split('[')
        .next()
        .filter(|identifier| !identifier.is_empty())
}

fn launchctl_value(output: &str, key: &str) -> Option<String> {
    let prefix = format!("{key} = ");
    output.lines().find_map(|line| {
        let value = line.trim().strip_prefix(&prefix)?.trim();
        (!value.is_empty()).then_some(value.to_owned())
    })
}

fn launchctl_numeric_value(output: &str, key: &str) -> Option<u64> {
    launchctl_value(output, key)?.parse::<u64>().ok()
}

fn app_bundle_path_from_command(command: &str) -> Option<String> {
    let start = command.find(".app/")? + 4;
    Some(command[..start].to_owned())
}

#[cfg(test)]
mod tests {
    use super::{
        application_service_details_from_output, parse_application_service_line,
        service_bundle_identifier,
    };

    #[test]
    fn parses_application_service_list_lines() {
        let service = parse_application_service_line(
            "   41210      - \tUIKitApplication:com.apple.mobilesafari[2777][rb-running]",
        )
        .unwrap();
        assert_eq!(service.pid, 41210);
        assert_eq!(
            service.service_name,
            "UIKitApplication:com.apple.mobilesafari[2777][rb-running]"
        );
        assert_eq!(
            service_bundle_identifier(&service.service_name),
            Some("com.apple.mobilesafari")
        );
    }

    #[test]
    fn parses_application_service_details() {
        let service = parse_application_service_line(
            "  54831 - UIKitApplication:com.apple.DocumentsApp.DocumentsViewService[beef][rb-legacy]",
        )
        .unwrap();
        let details = application_service_details_from_output(
            &service,
            r#"
                active count = 2
                state = running
                program = /System/Applications/Files.app/PlugIns/DocumentsViewService.appex/DocumentsViewService
                bundle id = com.apple.DocumentsApp.DocumentsViewService
                spawn role = ui focal (1)
                pid = 54831
            "#,
        )
        .unwrap();
        assert_eq!(details.active_count, 2);
        assert_eq!(details.process_identifier, 54831);
        assert_eq!(details.spawn_role, "ui focal (1)");
    }
}
