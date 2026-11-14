use crate::accounts::Account;
use crate::logging::{LogFields, LogStore};
use crate::metrics::MetricsStore;
use crate::s3;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use uuid::Uuid;

const MULTIPART_THRESHOLD: u64 = 16 * 1024 * 1024;
const PART_SIZE: u64 = 8 * 1024 * 1024;
const MAX_PARTS: u64 = 10_000;

/// S3 allows at most 10,000 parts, so a fixed 8 MiB part caps uploads at
/// about 78 GiB. Grow the part size (in whole MiB) for larger files.
fn part_size_for(size: u64) -> u64 {
    const MIB: u64 = 1024 * 1024;
    let needed = size.div_ceil(MAX_PARTS);
    PART_SIZE.max(needed.div_ceil(MIB) * MIB)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferTask {
    pub id: String,
    pub kind: String,
    pub account_id: String,
    pub bucket: String,
    pub key: String,
    pub local_path: String,
    pub size: u64,
    pub transferred: u64,
    pub status: String,
    pub error: Option<String>,
    pub multipart: bool,
    pub created_at: u64,
    #[serde(default)]
    pub destination_account_id: Option<String>,
    #[serde(default)]
    pub destination_bucket: Option<String>,
    #[serde(default)]
    pub destination_key: Option<String>,
    #[serde(default)]
    pub move_source: bool,
    #[serde(default)]
    pub source_e_tag: Option<String>,
    #[serde(default)]
    pub phase: Option<String>,
    #[serde(default)]
    pub content_type: Option<String>,
    /// The in-progress multipart upload, so a crash can be cleaned up on the
    /// next resume or retry instead of leaving billed parts behind.
    #[serde(default)]
    pub upload_id: Option<String>,
}

pub struct TransferControl {
    pub paused: AtomicBool,
    pub cancelled: AtomicBool,
}

pub struct TransferManager {
    tasks: Mutex<Vec<TransferTask>>,
    controls: Mutex<HashMap<String, Arc<TransferControl>>>,
    /// Tasks with a live runner. A second runner on the same task would write
    /// the same temp file concurrently.
    running: Mutex<HashSet<String>>,
    /// Serialises writes of transfers.json.
    save_lock: Mutex<()>,
    path: PathBuf,
}

/// Held by a runner for its whole lifetime; releases the task on drop.
pub struct RunClaim {
    manager: Arc<TransferManager>,
    id: String,
}

impl Drop for RunClaim {
    fn drop(&mut self) {
        if let Ok(mut running) = self.manager.running.lock() {
            running.remove(&self.id);
        }
    }
}

impl TransferManager {
    pub fn load() -> Self {
        let path = dirs::config_dir()
            .unwrap_or_else(std::env::temp_dir)
            .join("BucketManager")
            .join("transfers.json");
        let mut tasks: Vec<TransferTask> = std::fs::read_to_string(&path)
            .ok()
            .and_then(|value| serde_json::from_str(&value).ok())
            .unwrap_or_default();
        for task in &mut tasks {
            if task.status == "running" || task.status == "queued" {
                task.status = "paused".to_string();
            }
        }
        Self {
            tasks: Mutex::new(tasks),
            controls: Mutex::new(HashMap::new()),
            running: Mutex::new(HashSet::new()),
            save_lock: Mutex::new(()),
            path,
        }
    }

    /// Downloads and copies restart from zero, so temp files left by a crash
    /// are useless. Called from setup, after the single-instance check, so a
    /// second launch can never delete files the first one is still writing.
    pub fn remove_stale_temps(&self) {
        let tasks = self.list();
        for task in tasks.iter().filter(|task| task.kind == "download" || task.kind == "copy") {
            let _ = std::fs::remove_file(download_temp_path(Path::new(&task.local_path), &task.id));
            if task.kind == "copy" {
                // The copy's staging file in %TEMP%, never a user file.
                let _ = std::fs::remove_file(&task.local_path);
            }
        }
    }

    pub fn is_running(&self, id: &str) -> bool {
        self.running
            .lock()
            .map(|running| running.contains(id))
            .unwrap_or(false)
    }

    /// Claims the task for one runner. Returns None while another runner is
    /// still alive (for example, a paused download that has not stopped yet).
    pub fn claim(self: &Arc<Self>, id: &str) -> Option<RunClaim> {
        let mut running = self.running.lock().ok()?;
        if !running.insert(id.to_string()) {
            return None;
        }
        Some(RunClaim {
            manager: Arc::clone(self),
            id: id.to_string(),
        })
    }

    pub fn list(&self) -> Vec<TransferTask> {
        let mut tasks = self
            .tasks
            .lock()
            .map(|tasks| tasks.clone())
            .unwrap_or_default();
        tasks.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        tasks
    }

    pub fn get(&self, id: &str) -> Option<TransferTask> {
        self.tasks
            .lock()
            .ok()?
            .iter()
            .find(|task| task.id == id)
            .cloned()
    }

    pub fn control(&self, id: &str) -> Arc<TransferControl> {
        let mut controls = self.controls.lock().expect("transfer controls");
        controls
            .entry(id.to_string())
            .or_insert_with(|| {
                Arc::new(TransferControl {
                    paused: AtomicBool::new(false),
                    cancelled: AtomicBool::new(false),
                })
            })
            .clone()
    }

    pub fn add_upload(
        &self,
        app: &AppHandle,
        account_id: &str,
        bucket: &str,
        key: &str,
        file_path: &str,
    ) -> Result<TransferTask, String> {
        let metadata = std::fs::metadata(file_path).map_err(|error| error.to_string())?;
        let task = TransferTask {
            id: Uuid::new_v4().to_string(),
            kind: "upload".to_string(),
            account_id: account_id.to_string(),
            bucket: bucket.to_string(),
            key: key.to_string(),
            local_path: file_path.to_string(),
            size: metadata.len(),
            transferred: 0,
            status: "queued".to_string(),
            error: None,
            multipart: metadata.len() > MULTIPART_THRESHOLD,
            created_at: now(),
            destination_account_id: None,
            destination_bucket: None,
            destination_key: None,
            move_source: false,
            source_e_tag: None,
            phase: None,
            content_type: None,
            upload_id: None,
        };
        self.push(app, task.clone());
        Ok(task)
    }

    pub fn add_download(
        &self,
        app: &AppHandle,
        account_id: &str,
        bucket: &str,
        key: &str,
        destination: &str,
        size: u64,
    ) -> TransferTask {
        let task = TransferTask {
            id: Uuid::new_v4().to_string(),
            kind: "download".to_string(),
            account_id: account_id.to_string(),
            bucket: bucket.to_string(),
            key: key.to_string(),
            local_path: destination.to_string(),
            size,
            transferred: 0,
            status: "queued".to_string(),
            error: None,
            multipart: false,
            created_at: now(),
            destination_account_id: None,
            destination_bucket: None,
            destination_key: None,
            move_source: false,
            source_e_tag: None,
            phase: None,
            content_type: None,
            upload_id: None,
        };
        self.push(app, task.clone());
        task
    }

    pub fn add_copy(
        &self,
        app: &AppHandle,
        source_account_id: &str,
        source_bucket: &str,
        source_key: &str,
        source_size: u64,
        source_e_tag: Option<String>,
        destination_account_id: &str,
        destination_bucket: &str,
        destination_key: &str,
        move_source: bool,
    ) -> TransferTask {
        let id = Uuid::new_v4().to_string();
        let temporary = std::env::temp_dir().join(format!("bucket-manager-copy-{id}.part"));
        let task = TransferTask {
            id,
            kind: "copy".to_string(),
            account_id: source_account_id.to_string(),
            bucket: source_bucket.to_string(),
            key: source_key.to_string(),
            local_path: temporary.to_string_lossy().to_string(),
            size: source_size,
            transferred: 0,
            status: "queued".to_string(),
            error: None,
            multipart: source_size > MULTIPART_THRESHOLD,
            created_at: now(),
            destination_account_id: Some(destination_account_id.to_string()),
            destination_bucket: Some(destination_bucket.to_string()),
            destination_key: Some(destination_key.to_string()),
            move_source,
            source_e_tag,
            phase: Some("download".to_string()),
            content_type: None,
            upload_id: None,
        };
        self.push(app, task.clone());
        task
    }

    fn push(&self, app: &AppHandle, task: TransferTask) {
        if let Ok(mut tasks) = self.tasks.lock() {
            tasks.retain(|item| item.id != task.id);
            tasks.push(task.clone());
        }
        self.save();
        let _ = app.emit("transfer-updated", task);
    }

    pub fn update<F>(&self, app: &AppHandle, id: &str, update: F)
    where
        F: FnOnce(&mut TransferTask),
    {
        let task = if let Ok(mut tasks) = self.tasks.lock() {
            if let Some(task) = tasks.iter_mut().find(|task| task.id == id) {
                update(task);
                Some(task.clone())
            } else {
                None
            }
        } else {
            None
        };
        if let Some(task) = task {
            self.save();
            let _ = app.emit("transfer-updated", task);
        }
    }

    /// Byte-progress update: emitted to the UI but not written to disk, so a
    /// download does not rewrite transfers.json for every chunk.
    pub fn progress(&self, app: &AppHandle, id: &str, transferred: u64) {
        let task = self.tasks.lock().ok().and_then(|mut tasks| {
            let task = tasks.iter_mut().find(|task| task.id == id)?;
            task.transferred = transferred;
            Some(task.clone())
        });
        if let Some(task) = task {
            let _ = app.emit("transfer-updated", task);
        }
    }

    pub fn set_status(&self, app: &AppHandle, id: &str, status: &str, error: Option<String>) {
        self.update(app, id, |task| {
            task.status = status.to_string();
            task.error = error;
        });
    }

    pub fn pause(&self, app: &AppHandle, id: &str) {
        if let Some(control) = self
            .controls
            .lock()
            .ok()
            .and_then(|map| map.get(id).cloned())
        {
            control.paused.store(true, Ordering::SeqCst);
        }
        self.set_status(app, id, "paused", None);
    }

    pub fn resume(&self, app: &AppHandle, id: &str) {
        if let Some(control) = self
            .controls
            .lock()
            .ok()
            .and_then(|map| map.get(id).cloned())
        {
            control.paused.store(false, Ordering::SeqCst);
        }
        self.set_status(app, id, "queued", None);
    }

    pub fn cancel(&self, app: &AppHandle, id: &str) {
        if let Some(control) = self
            .controls
            .lock()
            .ok()
            .and_then(|map| map.get(id).cloned())
        {
            control.cancelled.store(true, Ordering::SeqCst);
        }
        self.set_status(app, id, "cancelled", None);
    }

    pub fn retry(&self, app: &AppHandle, id: &str) {
        if let Some(control) = self
            .controls
            .lock()
            .ok()
            .and_then(|map| map.get(id).cloned())
        {
            control.cancelled.store(false, Ordering::SeqCst);
            control.paused.store(false, Ordering::SeqCst);
        }
        self.update(app, id, |task| {
            task.transferred = 0;
            task.status = "queued".to_string();
            task.error = None;
        });
    }

    pub fn is_paused(&self, id: &str) -> bool {
        self.control(id).paused.load(Ordering::SeqCst)
    }

    pub fn is_cancelled(&self, id: &str) -> bool {
        self.control(id).cancelled.load(Ordering::SeqCst)
    }

    fn save(&self) {
        // Snapshot and write under one lock so saves cannot interleave, and
        // write a sibling file then rename it, so a crash never leaves a
        // half-written transfers.json.
        let _guard = self.save_lock.lock();
        let tasks = self
            .tasks
            .lock()
            .map(|tasks| tasks.clone())
            .unwrap_or_default();
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(&tasks) {
            let _ = write_atomic(&self.path, &json);
        }
    }
}

pub async fn run_upload(
    app: AppHandle,
    manager: Arc<TransferManager>,
    account: Account,
    secret: String,
    id: String,
    logs: Arc<LogStore>,
    metrics: Arc<MetricsStore>,
) {
    let Some(task) = manager.get(&id) else { return };
    let started = Instant::now();
    if manager.is_cancelled(&id) {
        manager.set_status(&app, &id, "cancelled", None);
        return;
    }
    manager.set_status(&app, &id, "running", None);
    let result = if task.multipart {
        multipart_upload(&app, &manager, &account, &secret, &task).await
    } else {
        simple_upload(&app, &manager, &account, &secret, &task).await
    };
    let success = result.is_ok();
    let error = result.as_ref().err().cloned();
    metrics.record(
        &account.id,
        &account.name,
        &task.bucket,
        "PutObject",
        started.elapsed().as_millis() as u64,
        if success { task.size } else { task.transferred },
        success,
    );
    logs.audit(
        if success {
            "object.uploaded"
        } else {
            "object.upload_failed"
        },
        if success {
            "Object uploaded"
        } else {
            "Object upload failed"
        },
        LogFields {
            account_id: Some(account.id.clone()),
            account_name: Some(account.name.clone()),
            operation: Some("PutObject".into()),
            bucket: Some(task.bucket.clone()),
            key: Some(task.key.clone()),
            metadata: error.map(|error| serde_json::json!({ "error": error })),
        },
        Some(if success { "success" } else { "failure" }.into()),
    );
    match result {
        Ok(()) => manager.update(&app, &id, |task| {
            task.transferred = task.size;
            task.status = "completed".to_string();
            task.error = None;
        }),
        Err(error) => {
            let status = if manager.is_cancelled(&id) {
                "cancelled"
            } else if manager.is_paused(&id) {
                "paused"
            } else {
                "failed"
            };
            let error = (status != "paused").then_some(error);
            manager.set_status(&app, &id, status, error);
        }
    }
}

async fn simple_upload(
    app: &AppHandle,
    manager: &TransferManager,
    account: &Account,
    secret: &str,
    task: &TransferTask,
) -> Result<(), String> {
    if manager.is_paused(&task.id) {
        return Err("Transfer paused.".to_string());
    }
    if manager.is_cancelled(&task.id) {
        return Err("Transfer cancelled.".to_string());
    }
    let client = s3::client_for_bucket(account, secret, &task.bucket).await;
    let content_type = task.content_type.clone().unwrap_or_else(|| {
        mime_guess::from_path(&task.local_path)
            .first_or_octet_stream()
            .to_string()
    });
    let body = aws_sdk_s3::primitives::ByteStream::from_path(Path::new(&task.local_path))
        .await
        .map_err(|error| error.to_string())?;
    manager.update(app, &task.id, |task| task.status = "running".to_string());
    client
        .put_object()
        .bucket(&task.bucket)
        .key(&task.key)
        .content_type(content_type)
        .body(body)
        .send()
        .await
        .map_err(|error| s3::s3_error(&error))?;
    manager.update(app, &task.id, |task| task.transferred = task.size);
    Ok(())
}

async fn multipart_upload(
    app: &AppHandle,
    manager: &TransferManager,
    account: &Account,
    secret: &str,
    task: &TransferTask,
) -> Result<(), String> {
    let client = s3::client_for_bucket(account, secret, &task.bucket).await;
    // An upload left by a crash or kill: abort it before starting again. If
    // that fails, stop rather than overwrite the only record of its id.
    let stale = manager
        .get(&task.id)
        .and_then(|current| current.upload_id)
        .or_else(|| task.upload_id.clone());
    if let Some(stale) = stale {
        s3::abort_upload(account, secret, &task.bucket, &task.key, &stale)
            .await
            .map_err(|error| format!("Could not clean up the previous upload: {error}"))?;
        manager.update(app, &task.id, |current| current.upload_id = None);
    }
    let created = client
        .create_multipart_upload()
        .bucket(&task.bucket)
        .key(&task.key)
        .content_type(task.content_type.clone().unwrap_or_else(|| {
            mime_guess::from_path(&task.local_path)
                .first_or_octet_stream()
                .to_string()
        }))
        .send()
        .await
        .map_err(|error| s3::s3_error(&error))?;
    let upload_id = created
        .upload_id()
        .ok_or_else(|| "Multipart upload id missing.".to_string())?
        .to_string();
    manager.update(app, &task.id, |current| current.upload_id = Some(upload_id.clone()));
    let result = upload_parts(app, manager, &client, task, &upload_id).await;
    let result = match result {
        Ok(parts) => {
            let completed = aws_sdk_s3::types::CompletedMultipartUpload::builder()
                .set_parts(Some(parts))
                .build();
            client
                .complete_multipart_upload()
                .bucket(&task.bucket)
                .key(&task.key)
                .upload_id(&upload_id)
                .multipart_upload(completed)
                .send()
                .await
                .map(|_| ())
                .map_err(|error| s3::s3_error(&error))
        }
        Err(error) => Err(error),
    };
    // Every failure path aborts, so no billed parts are left behind. The id
    // is kept when the abort itself fails (often the same network outage),
    // so the next resume, retry, cancel or launch can clean it up.
    let forget = match &result {
        Ok(()) => true,
        Err(_) => s3::abort_upload(account, secret, &task.bucket, &task.key, &upload_id)
            .await
            .is_ok(),
    };
    if forget {
        manager.update(app, &task.id, |current| current.upload_id = None);
    }
    result
}

async fn upload_parts(
    app: &AppHandle,
    manager: &TransferManager,
    client: &aws_sdk_s3::Client,
    task: &TransferTask,
    upload_id: &str,
) -> Result<Vec<aws_sdk_s3::types::CompletedPart>, String> {
    let part_size = part_size_for(task.size);
    let mut file = tokio::fs::File::open(&task.local_path)
        .await
        .map_err(|error| error.to_string())?;
    let mut parts = Vec::new();
    let mut offset = 0u64;
    let mut part_number = 1i32;
    loop {
        if manager.is_cancelled(&task.id) {
            return Err("Transfer cancelled.".to_string());
        }
        if manager.is_paused(&task.id) {
            return Err("Transfer paused.".to_string());
        }
        let remaining = task.size.saturating_sub(offset);
        if remaining == 0 {
            return Ok(parts);
        }
        let length = remaining.min(part_size) as usize;
        let mut data = vec![0u8; length];
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|error| error.to_string())?;
        file.read_exact(&mut data)
            .await
            .map_err(|error| error.to_string())?;
        let response = client
            .upload_part()
            .bucket(&task.bucket)
            .key(&task.key)
            .upload_id(upload_id)
            .part_number(part_number)
            .body(aws_sdk_s3::primitives::ByteStream::from(data))
            .send()
            .await
            .map_err(|error| s3::s3_error(&error))?;
        let e_tag = response
            .e_tag()
            .ok_or_else(|| "Multipart part ETag missing.".to_string())?
            .to_string();
        parts.push(
            aws_sdk_s3::types::CompletedPart::builder()
                .part_number(part_number)
                .e_tag(e_tag)
                .build(),
        );
        offset += length as u64;
        manager.update(app, &task.id, |task| {
            task.transferred = offset;
            task.status = "running".to_string();
        });
        part_number += 1;
    }
}

pub async fn run_copy(
    app: AppHandle,
    manager: Arc<TransferManager>,
    source_account: Account,
    source_secret: String,
    destination_account: Account,
    destination_secret: String,
    id: String,
    logs: Arc<LogStore>,
    metrics: Arc<MetricsStore>,
) {
    let Some(task) = manager.get(&id) else { return };
    let started = Instant::now();
    if manager.is_cancelled(&id) {
        manager.set_status(&app, &id, "cancelled", None);
        return;
    }
    let Some(destination_bucket) = task.destination_bucket.clone() else {
        manager.set_status(
            &app,
            &id,
            "failed",
            Some("Destination bucket missing.".into()),
        );
        return;
    };
    let Some(destination_key) = task.destination_key.clone() else {
        manager.set_status(&app, &id, "failed", Some("Destination key missing.".into()));
        return;
    };
    let temporary = PathBuf::from(&task.local_path);
    let download_temporary = download_temp_path(&temporary, &task.id);
    let _ = tokio::fs::remove_file(&temporary).await;
    let _ = tokio::fs::remove_file(&download_temporary).await;

    manager.update(&app, &id, |task| {
        task.status = "running".into();
        task.phase = Some("download".into());
        task.transferred = 0;
        task.error = None;
    });

    let result = copy_between_accounts(
        &app,
        &manager,
        &source_account,
        &source_secret,
        &destination_account,
        &destination_secret,
        &task,
        &destination_bucket,
        &destination_key,
    )
    .await;

    let _ = tokio::fs::remove_file(&temporary).await;
    let _ = tokio::fs::remove_file(&download_temporary).await;

    let success = result.is_ok();
    let error = result.as_ref().err().cloned();
    metrics.record(
        &source_account.id,
        &source_account.name,
        &task.bucket,
        if task.move_source {
            "MoveObject"
        } else {
            "CopyObject"
        },
        started.elapsed().as_millis() as u64,
        if success { task.size } else { task.transferred },
        success,
    );
    logs.audit(
        if success {
            if task.move_source {
                "object.moved"
            } else {
                "object.copied"
            }
        } else if task.move_source {
            "object.move_failed"
        } else {
            "object.copy_failed"
        },
        if success {
            if task.move_source {
                "Object moved between accounts"
            } else {
                "Object copied between accounts"
            }
        } else if task.move_source {
            "Cross-account move failed"
        } else {
            "Cross-account copy failed"
        },
        LogFields {
            account_id: Some(source_account.id.clone()),
            account_name: Some(source_account.name.clone()),
            operation: Some(
                if task.move_source {
                    "MoveObject"
                } else {
                    "CopyObject"
                }
                .into(),
            ),
            bucket: Some(task.bucket.clone()),
            key: Some(task.key.clone()),
            metadata: Some(serde_json::json!({
                "destinationAccount": destination_account.name,
                "destinationAccountID": destination_account.id,
                "destinationBucket": destination_bucket,
                "destinationKey": destination_key,
                "error": error,
            })),
        },
        Some(if success { "success" } else { "failure" }.into()),
    );

    match result {
        Ok(()) => manager.update(&app, &id, |task| {
            task.transferred = task.size;
            task.status = "completed".into();
            task.phase = Some("complete".into());
            task.error = None;
        }),
        Err(error) => {
            let status = if manager.is_cancelled(&id) {
                "cancelled"
            } else if manager.is_paused(&id) {
                "paused"
            } else {
                "failed"
            };
            let error = (status != "paused").then_some(error);
            manager.set_status(&app, &id, status, error);
        }
    }
}

async fn copy_between_accounts(
    app: &AppHandle,
    manager: &TransferManager,
    source_account: &Account,
    source_secret: &str,
    destination_account: &Account,
    destination_secret: &str,
    task: &TransferTask,
    destination_bucket: &str,
    destination_key: &str,
) -> Result<(), String> {
    if source_account.id == destination_account.id
        && task.bucket == destination_bucket
        && task.key == destination_key
    {
        return Err("The source and destination resolve to the same object.".into());
    }

    let source_details =
        s3::object_details(source_account, source_secret, &task.bucket, &task.key).await?;
    let expected_size = source_details.size;
    let expected_etag = source_details
        .e_tag
        .clone()
        .or_else(|| task.source_e_tag.clone());
    manager.update(app, &task.id, |current| {
        current.size = expected_size;
        current.source_e_tag = expected_etag.clone();
        current.content_type = source_details.content_type.clone();
        current.multipart = expected_size > MULTIPART_THRESHOLD;
        current.phase = Some("download".into());
    });

    let download_task = TransferTask {
        bucket: task.bucket.clone(),
        key: task.key.clone(),
        local_path: task.local_path.clone(),
        size: expected_size,
        ..task.clone()
    };
    download(app, manager, source_account, source_secret, &download_task).await?;

    let after_download =
        s3::object_details(source_account, source_secret, &task.bucket, &task.key).await?;
    if after_download.size != expected_size
        || (expected_etag.is_some()
            && after_download.e_tag.as_deref().map(normalize_etag)
                != expected_etag.as_deref().map(normalize_etag))
    {
        return Err("The source object changed during the copy.".into());
    }

    manager.update(app, &task.id, |current| {
        current.phase = Some("upload".into());
        current.transferred = 0;
        current.status = "running".into();
    });
    let upload_task = TransferTask {
        bucket: destination_bucket.to_string(),
        key: destination_key.to_string(),
        local_path: task.local_path.clone(),
        size: expected_size,
        content_type: source_details.content_type.clone(),
        ..task.clone()
    };
    if upload_task.multipart {
        multipart_upload(
            app,
            manager,
            destination_account,
            destination_secret,
            &upload_task,
        )
        .await?;
    } else {
        simple_upload(
            app,
            manager,
            destination_account,
            destination_secret,
            &upload_task,
        )
        .await?;
    }

    let destination = s3::object_details(
        destination_account,
        destination_secret,
        destination_bucket,
        destination_key,
    )
    .await
    .map_err(|_| "Destination verification failed.".to_string())?;
    if destination.size != expected_size {
        return Err("Destination verification failed: size mismatch.".into());
    }

    if task.move_source {
        let current =
            s3::object_details(source_account, source_secret, &task.bucket, &task.key).await?;
        if current.size != expected_size
            || (expected_etag.is_some()
                && current.e_tag.as_deref().map(normalize_etag)
                    != expected_etag.as_deref().map(normalize_etag))
        {
            return Err("The source object changed during the move.".into());
        }
        s3::delete_exact_object(source_account, source_secret, &task.bucket, &task.key).await?;
    }
    Ok(())
}

fn normalize_etag(etag: &str) -> String {
    etag.trim_matches('"').to_ascii_lowercase()
}

pub async fn run_download(
    app: AppHandle,
    manager: Arc<TransferManager>,
    account: Account,
    secret: String,
    id: String,
    logs: Arc<LogStore>,
    metrics: Arc<MetricsStore>,
) {
    let Some(task) = manager.get(&id) else { return };
    let started = Instant::now();
    if manager.is_cancelled(&id) {
        manager.set_status(&app, &id, "cancelled", None);
        return;
    }
    // Downloads restart from zero; drop the old percentage.
    manager.update(&app, &id, |task| {
        task.status = "running".to_string();
        task.error = None;
        task.transferred = 0;
    });
    let result = download(&app, &manager, &account, &secret, &task).await;
    let success = result.is_ok();
    let error = result.as_ref().err().cloned();
    metrics.record(
        &account.id,
        &account.name,
        &task.bucket,
        "GetObject",
        started.elapsed().as_millis() as u64,
        if success { task.size } else { task.transferred },
        success,
    );
    logs.audit(
        if success {
            "object.downloaded"
        } else {
            "object.download_failed"
        },
        if success {
            "Object downloaded"
        } else {
            "Object download failed"
        },
        LogFields {
            account_id: Some(account.id.clone()),
            account_name: Some(account.name.clone()),
            operation: Some("GetObject".into()),
            bucket: Some(task.bucket.clone()),
            key: Some(task.key.clone()),
            metadata: error.map(|error| serde_json::json!({ "error": error })),
        },
        Some(if success { "success" } else { "failure" }.into()),
    );
    match result {
        Ok(()) => manager.update(&app, &id, |task| {
            task.transferred = task.size;
            task.status = "completed".to_string();
            task.error = None;
        }),
        Err(error) => {
            let status = if manager.is_cancelled(&id) {
                "cancelled"
            } else if manager.is_paused(&id) {
                "paused"
            } else {
                "failed"
            };
            let error = (status != "paused").then_some(error);
            manager.set_status(&app, &id, status, error);
        }
    }
}

async fn download(
    app: &AppHandle,
    manager: &TransferManager,
    account: &Account,
    secret: &str,
    task: &TransferTask,
) -> Result<(), String> {
    let client = s3::client_for_bucket(account, secret, &task.bucket).await;
    let response = client
        .get_object()
        .bucket(&task.bucket)
        .key(&task.key)
        .send()
        .await
        .map_err(|error| s3::s3_error(&error))?;
    let expected = response.content_length().and_then(|length| u64::try_from(length).ok());
    let body = response.body;
    let destination = PathBuf::from(&task.local_path);
    let temporary = download_temp_path(&destination, &task.id);
    if let Some(parent) = temporary.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|error| error.to_string())?;
    }
    let result = write_download(app, manager, task, body, &temporary, expected).await;
    if result.is_err() {
        // Never leave a partial file in the user's folder.
        let _ = tokio::fs::remove_file(&temporary).await;
        return result;
    }
    if let Err(error) = tokio::fs::rename(&temporary, &destination).await {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error.to_string());
    }
    Ok(())
}

async fn write_download(
    app: &AppHandle,
    manager: &TransferManager,
    task: &TransferTask,
    mut body: aws_sdk_s3::primitives::ByteStream,
    temporary: &Path,
    expected: Option<u64>,
) -> Result<(), String> {
    let mut file = tokio::fs::File::create(temporary)
        .await
        .map_err(|error| error.to_string())?;
    let mut transferred = 0u64;
    let mut last_emit = Instant::now();
    while let Some(chunk) = body.next().await {
        if manager.is_cancelled(&task.id) {
            return Err("Transfer cancelled.".to_string());
        }
        if manager.is_paused(&task.id) {
            return Err("Transfer paused.".to_string());
        }
        let bytes = chunk.map_err(|error| error.to_string())?;
        file.write_all(&bytes)
            .await
            .map_err(|error| error.to_string())?;
        transferred += bytes.len() as u64;
        if last_emit.elapsed().as_millis() >= 200 {
            last_emit = Instant::now();
            manager.progress(app, &task.id, transferred);
        }
    }
    file.flush().await.map_err(|error| error.to_string())?;
    if let Some(expected) = expected {
        if transferred != expected {
            return Err(format!(
                "Download incomplete: received {transferred} of {expected} bytes."
            ));
        }
    }
    manager.progress(app, &task.id, transferred);
    Ok(())
}

pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(bytes)?;
        // Flush to disk before the rename so a power cut cannot leave an
        // empty file in place of the history.
        file.sync_all()?;
    }
    // Antivirus or indexers can briefly hold the target open on Windows.
    let mut attempt = 0;
    loop {
        match std::fs::rename(&temporary, path) {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied && attempt < 3 => {
                attempt += 1;
                std::thread::sleep(std::time::Duration::from_millis(50 * attempt));
            }
            Err(error) => return Err(error),
        }
    }
}

/// A per-task temp name next to the destination. Deriving it from the stem
/// alone made IMG_1.CR2 and IMG_1.JPG share one file.
fn download_temp_path(destination: &Path, task_id: &str) -> PathBuf {
    let name = destination
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "download".to_string());
    let short_id: String = task_id.chars().take(8).collect();
    // Keep the temp name within the 255-character file name limit.
    let name: String = name.chars().take(200).collect();
    destination.with_file_name(format!("{name}.{short_id}.bucket-manager-part"))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manager(path: PathBuf) -> Arc<TransferManager> {
        Arc::new(TransferManager {
            tasks: Mutex::new(Vec::new()),
            controls: Mutex::new(HashMap::new()),
            running: Mutex::new(HashSet::new()),
            save_lock: Mutex::new(()),
            path,
        })
    }

    #[test]
    fn same_stem_downloads_get_distinct_temp_files() {
        let folder = Path::new("C:/Downloads");
        let raw = download_temp_path(&folder.join("IMG_1.CR2"), "aaaaaaaa-1");
        let jpg = download_temp_path(&folder.join("IMG_1.JPG"), "bbbbbbbb-2");
        assert_ne!(raw, jpg);
        assert_eq!(raw.parent(), Some(folder));
        let again = download_temp_path(&folder.join("IMG_1.JPG"), "cccccccc-3");
        assert_ne!(jpg, again, "two tasks for one destination never share a temp");
    }

    #[test]
    fn a_task_has_at_most_one_runner() {
        let manager = manager(std::env::temp_dir().join("bm-claim-test.json"));
        let first = manager.claim("task").expect("first claim");
        assert!(manager.claim("task").is_none());
        assert!(manager.is_running("task"));
        drop(first);
        assert!(!manager.is_running("task"));
        assert!(manager.claim("task").is_some());
    }

    fn sample_task(index: usize) -> TransferTask {
        TransferTask {
            id: format!("t{index}"),
            kind: "download".into(),
            account_id: "a".into(),
            bucket: "b".into(),
            key: format!("key-{index}-{}", "x".repeat(200)),
            local_path: "x".into(),
            size: 1,
            transferred: 0,
            status: "completed".into(),
            error: None,
            multipart: false,
            created_at: 0,
            destination_account_id: None,
            destination_bucket: None,
            destination_key: None,
            move_source: false,
            source_e_tag: None,
            phase: None,
            content_type: None,
            upload_id: None,
        }
    }

    /// A reader running alongside the savers must never see a torn file. The
    /// old unlocked, in-place fs::write fails this within a few reads.
    #[test]
    fn concurrent_saves_never_expose_a_torn_file() {
        let dir = std::env::temp_dir().join(format!("bm-save-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("transfers.json");
        let manager = manager(path.clone());
        manager.tasks.lock().unwrap().extend((0..200).map(sample_task));
        manager.save();

        let done = Arc::new(AtomicBool::new(false));
        let reader = {
            let done = Arc::clone(&done);
            let path = path.clone();
            std::thread::spawn(move || {
                let mut reads = 0;
                while !done.load(Ordering::SeqCst) {
                    let text = std::fs::read_to_string(&path).expect("file always exists");
                    let tasks: Vec<TransferTask> =
                        serde_json::from_str(&text).expect("file is never torn");
                    assert!(tasks.len() >= 200, "file is never short");
                    reads += 1;
                }
                reads
            })
        };
        let writers: Vec<_> = (0..8)
            .map(|writer| {
                let manager = Arc::clone(&manager);
                std::thread::spawn(move || {
                    for round in 0..40 {
                        // Vary the content so lost or mixed writes would show.
                        if let Ok(mut tasks) = manager.tasks.lock() {
                            tasks[writer].transferred = round;
                            if round % 2 == 0 {
                                tasks.push(sample_task(1_000 + writer * 100 + round as usize));
                            }
                        }
                        manager.save();
                    }
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }
        done.store(true, Ordering::SeqCst);
        assert!(reader.join().unwrap() > 0);

        let saved: Vec<TransferTask> =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved.len(), 200 + 8 * 20, "the last save holds every task");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn part_size_keeps_every_upload_within_ten_thousand_parts() {
        const MIB: u64 = 1024 * 1024;
        assert_eq!(part_size_for(20 * MIB), PART_SIZE);
        assert_eq!(part_size_for(MAX_PARTS * PART_SIZE), PART_SIZE);
        for size in [MAX_PARTS * PART_SIZE + 1, 100 * 1024 * MIB, 5 * 1024 * 1024 * MIB] {
            let part = part_size_for(size);
            assert!(size.div_ceil(part) <= MAX_PARTS, "{size} needs too many parts");
            assert_eq!(part % MIB, 0);
        }
    }

    #[test]
    fn temp_names_stay_within_file_name_limits() {
        let long = "n".repeat(250) + ".bin";
        let temp = download_temp_path(&Path::new("C:/d").join(&long), "abcdef12-3456");
        assert!(temp.file_name().unwrap().len() <= 255);
    }
}
