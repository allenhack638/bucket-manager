use chrono::{Duration, Local, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRecord {
    pub timestamp: String,
    pub level: String,
    pub category: String,
    pub event: String,
    pub message: String,
    pub outcome: Option<String>,
    pub account_id: Option<String>,
    pub account_name: Option<String>,
    pub operation: Option<String>,
    pub bucket: Option<String>,
    pub key: Option<String>,
    pub metadata: Option<Value>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoggingSettings {
    pub diagnostics_enabled: bool,
    pub minimum_level: String,
    pub enabled_categories: Vec<String>,
    pub diagnostic_retention_days: u32,
    pub audit_retention_days: u32,
    pub include_object_keys: bool,
}

impl Default for LoggingSettings {
    fn default() -> Self {
        Self {
            diagnostics_enabled: false,
            minimum_level: "info".into(),
            enabled_categories: vec![
                "ui".into(),
                "network".into(),
                "transfer".into(),
                "settings".into(),
            ],
            diagnostic_retention_days: 30,
            audit_retention_days: 90,
            include_object_keys: false,
        }
    }
}

#[derive(Default, Clone)]
pub struct LogFields {
    pub account_id: Option<String>,
    pub account_name: Option<String>,
    pub operation: Option<String>,
    pub bucket: Option<String>,
    pub key: Option<String>,
    pub metadata: Option<Value>,
}

#[derive(Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogFilter {
    pub limit: Option<usize>,
    pub level: Option<String>,
    pub category: Option<String>,
    pub account_id: Option<String>,
    pub query: Option<String>,
}

pub struct LogStore {
    dir: PathBuf,
    settings: Mutex<LoggingSettings>,
}

impl LogStore {
    pub fn new() -> Self {
        let dir = config_dir().join("logs");
        let _ = fs::create_dir_all(&dir);
        let settings = load_settings(&dir);
        let store = Self {
            dir,
            settings: Mutex::new(settings),
        };
        store.prune();
        store
    }

    pub fn directory(&self) -> &Path {
        &self.dir
    }

    pub fn settings(&self) -> LoggingSettings {
        self.settings.lock().map(|s| s.clone()).unwrap_or_default()
    }

    pub fn update_settings(&self, settings: LoggingSettings) -> Result<(), String> {
        let settings = LoggingSettings {
            diagnostics_enabled: settings.diagnostics_enabled,
            minimum_level: normalize_level(&settings.minimum_level),
            enabled_categories: settings
                .enabled_categories
                .into_iter()
                .filter(|category| category != "audit")
                .collect(),
            diagnostic_retention_days: settings.diagnostic_retention_days.clamp(1, 365),
            audit_retention_days: settings.audit_retention_days.clamp(30, 365),
            include_object_keys: settings.include_object_keys,
        };
        let data = serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?;
        fs::write(config_dir().join("logging.json"), data).map_err(|e| e.to_string())?;
        if let Ok(mut current) = self.settings.lock() {
            *current = settings;
        }
        self.prune();
        self.audit(
            "settings.logging.changed",
            "Logging settings changed",
            LogFields {
                operation: Some("UpdateLoggingSettings".into()),
                ..Default::default()
            },
            Some("success".into()),
        );
        Ok(())
    }

    pub fn audit(
        &self,
        event: &str,
        message: &str,
        mut fields: LogFields,
        outcome: Option<String>,
    ) {
        if !self.settings().include_object_keys {
            fields.key = None;
        }
        self.write(LogRecord {
            timestamp: now(),
            level: "info".into(),
            category: "audit".into(),
            event: event.into(),
            message: message.into(),
            outcome,
            account_id: fields.account_id,
            account_name: fields.account_name,
            operation: fields.operation,
            bucket: fields.bucket,
            key: fields.key,
            metadata: fields.metadata,
        });
    }

    pub fn diagnostic(&self, level: &str, category: &str, event: &str, message: &str) {
        let settings = self.settings();
        if !settings.diagnostics_enabled
            || !settings.enabled_categories.iter().any(|c| c == category)
            || level_rank(level) < level_rank(&settings.minimum_level)
        {
            return;
        }
        self.write(LogRecord {
            timestamp: now(),
            level: normalize_level(level),
            category: category.into(),
            event: event.into(),
            message: message.into(),
            outcome: None,
            account_id: None,
            account_name: None,
            operation: None,
            bucket: None,
            key: None,
            metadata: None,
        });
    }

    pub fn recent(&self, filter: LogFilter) -> Vec<LogRecord> {
        let query = filter
            .query
            .as_deref()
            .unwrap_or_default()
            .trim()
            .to_lowercase();
        let mut records = Vec::new();
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                if !name.ends_with(".jsonl") {
                    continue;
                }
                let Ok(text) = fs::read_to_string(&path) else {
                    continue;
                };
                for line in text.lines() {
                    let Ok(record) = serde_json::from_str::<LogRecord>(line) else {
                        continue;
                    };
                    if let Some(min) = filter.level.as_deref() {
                        if level_rank(&record.level) < level_rank(min) {
                            continue;
                        }
                    }
                    if let Some(category) = filter.category.as_deref() {
                        if category == "audit" {
                            if record.category != "audit" {
                                continue;
                            }
                        } else if record.category != category {
                            continue;
                        }
                    }
                    if let Some(account_id) = filter.account_id.as_deref() {
                        if record.account_id.as_deref() != Some(account_id) {
                            continue;
                        }
                    }
                    if !query.is_empty() {
                        let haystack = format!(
                            "{} {} {} {} {} {} {}",
                            record.message,
                            record.event,
                            record.operation.as_deref().unwrap_or(""),
                            record.bucket.as_deref().unwrap_or(""),
                            record.key.as_deref().unwrap_or(""),
                            record.account_name.as_deref().unwrap_or(""),
                            record.category
                        )
                        .to_lowercase();
                        if !haystack.contains(&query) {
                            continue;
                        }
                    }
                    records.push(record);
                }
            }
        }
        records.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));
        records.truncate(filter.limit.unwrap_or(5000).min(20_000));
        records
    }

    pub fn clear_diagnostics(&self) -> Result<usize, String> {
        let mut removed = 0;
        if let Ok(entries) = fs::read_dir(&self.dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|name| name.starts_with("diagnostic-"))
                {
                    if fs::remove_file(path).is_ok() {
                        removed += 1;
                    }
                }
            }
        }
        self.audit(
            "logs.diagnostics.cleared",
            "Diagnostic logs cleared",
            LogFields {
                operation: Some("ClearDiagnostics".into()),
                metadata: Some(serde_json::json!({ "files": removed })),
                ..Default::default()
            },
            Some("success".into()),
        );
        Ok(removed)
    }

    pub fn export(&self, destination: &str, filter: LogFilter) -> Result<usize, String> {
        let records = self.recent(filter);
        let mut data = String::new();
        for record in &records {
            data.push_str(&serde_json::to_string(record).map_err(|e| e.to_string())?);
            data.push('\n');
        }
        fs::write(destination, data).map_err(|e| e.to_string())?;
        self.audit(
            "logs.exported",
            "Log records exported",
            LogFields {
                operation: Some("ExportLogs".into()),
                metadata: Some(serde_json::json!({ "records": records.len() })),
                ..Default::default()
            },
            Some("success".into()),
        );
        Ok(records.len())
    }

    pub fn reveal(&self) -> Result<(), String> {
        #[cfg(target_os = "windows")]
        {
            std::process::Command::new("explorer.exe")
                .arg(&self.dir)
                .spawn()
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn prune(&self) {
        let settings = self.settings();
        let today = Local::now().date_naive();
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
                continue;
            };
            let (prefix, days) = if name.starts_with("audit-") {
                ("audit-", settings.audit_retention_days)
            } else if name.starts_with("diagnostic-") {
                ("diagnostic-", settings.diagnostic_retention_days)
            } else {
                continue;
            };
            let date_part = name.trim_start_matches(prefix).trim_end_matches(".jsonl");
            let Ok(date) = chrono::NaiveDate::parse_from_str(date_part, "%Y-%m-%d") else {
                continue;
            };
            if today.signed_duration_since(date) > Duration::days(days as i64) {
                let _ = fs::remove_file(path);
            }
        }
    }

    fn write(&self, record: LogRecord) {
        let prefix = if record.category == "audit" {
            "audit"
        } else {
            "diagnostic"
        };
        let path = self.dir.join(format!(
            "{}-{}.jsonl",
            prefix,
            Local::now().format("%Y-%m-%d")
        ));
        let Ok(line) = serde_json::to_string(&record) else {
            return;
        };
        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}

fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| std::env::temp_dir())
        .join("BucketManager")
}

fn load_settings(dir: &Path) -> LoggingSettings {
    let path = dir
        .parent()
        .map(|p| p.join("logging.json"))
        .unwrap_or_else(|| dir.join("logging.json"));
    fs::read_to_string(path)
        .ok()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn normalize_level(level: &str) -> String {
    match level.to_lowercase().as_str() {
        "trace" => "trace",
        "debug" => "debug",
        "warning" | "warn" => "warning",
        "error" => "error",
        _ => "info",
    }
    .into()
}

fn level_rank(level: &str) -> u8 {
    match level.to_lowercase().as_str() {
        "trace" => 0,
        "debug" => 1,
        "info" => 2,
        "warning" | "warn" => 3,
        "error" => 4,
        _ => 2,
    }
}
