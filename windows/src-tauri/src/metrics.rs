use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestMetric {
    pub account_id: String,
    pub account_name: String,
    pub bucket: String,
    pub operation: String,
    pub requests: u64,
    pub failures: u64,
    pub total_ms: u64,
    pub bytes: u64,
    pub last_used: String,
    pub session_requests: u64,
}

pub struct MetricsStore {
    path: PathBuf,
    rows: Mutex<HashMap<String, RequestMetric>>,
}

impl MetricsStore {
    pub fn new() -> Self {
        let path = dirs::config_dir()
            .unwrap_or_else(|| std::env::temp_dir())
            .join("BucketManager")
            .join("metrics.json");
        let rows = fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<Vec<RequestMetric>>(&raw).ok())
            .unwrap_or_default()
            .into_iter()
            .map(|mut metric| {
                metric.session_requests = 0;
                (
                    metric_key(&metric.account_id, &metric.bucket, &metric.operation),
                    metric,
                )
            })
            .collect();
        Self {
            path,
            rows: Mutex::new(rows),
        }
    }

    pub fn record(
        &self,
        account_id: &str,
        account_name: &str,
        bucket: &str,
        operation: &str,
        elapsed_ms: u64,
        bytes: u64,
        success: bool,
    ) {
        let key = metric_key(account_id, bucket, operation);
        let mut rows = match self.rows.lock() {
            Ok(rows) => rows,
            Err(_) => return,
        };
        let metric = rows.entry(key).or_insert_with(|| RequestMetric {
            account_id: account_id.into(),
            account_name: account_name.into(),
            bucket: bucket.into(),
            operation: operation.into(),
            requests: 0,
            failures: 0,
            total_ms: 0,
            bytes: 0,
            last_used: now(),
            session_requests: 0,
        });
        metric.account_name = account_name.into();
        metric.requests += 1;
        metric.session_requests += 1;
        metric.total_ms += elapsed_ms;
        metric.bytes += bytes;
        metric.last_used = now();
        if !success {
            metric.failures += 1;
        }
        let values: Vec<_> = rows.values().cloned().collect();
        drop(rows);
        let _ = fs::write(
            &self.path,
            serde_json::to_vec_pretty(&values).unwrap_or_default(),
        );
    }

    pub fn snapshot(&self) -> Vec<RequestMetric> {
        let mut rows: Vec<_> = self
            .rows
            .lock()
            .map(|rows| rows.values().cloned().collect())
            .unwrap_or_default();
        rows.sort_by(|a, b| {
            a.account_name
                .cmp(&b.account_name)
                .then(a.bucket.cmp(&b.bucket))
                .then(a.operation.cmp(&b.operation))
        });
        rows
    }

    pub fn clear(&self) {
        if let Ok(mut rows) = self.rows.lock() {
            rows.clear();
        }
        let _ = fs::write(&self.path, b"[]");
    }
}

fn metric_key(account_id: &str, bucket: &str, operation: &str) -> String {
    format!("{account_id}|{bucket}|{operation}")
}

fn now() -> String {
    Utc::now().to_rfc3339()
}
