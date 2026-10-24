use crate::accounts::Account;
use crate::s3;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use uuid::Uuid;

const MULTIPART_THRESHOLD: u64 = 16 * 1024 * 1024;
const PART_SIZE: u64 = 8 * 1024 * 1024;

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
}

pub struct TransferControl {
    pub paused: AtomicBool,
    pub cancelled: AtomicBool,
}

pub struct TransferManager {
    tasks: Mutex<Vec<TransferTask>>,
    controls: Mutex<HashMap<String, Arc<TransferControl>>>,
    path: PathBuf,
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
            path,
        }
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
        let tasks = self
            .tasks
            .lock()
            .map(|tasks| tasks.clone())
            .unwrap_or_default();
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_vec_pretty(&tasks) {
            let _ = std::fs::write(&self.path, json);
        }
    }
}

pub async fn run_upload(
    app: AppHandle,
    manager: Arc<TransferManager>,
    account: Account,
    secret: String,
    id: String,
) {
    let Some(task) = manager.get(&id) else { return };
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
            manager.set_status(&app, &id, status, Some(error));
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
    let client = s3::client_for(account, secret).await;
    let content_type = mime_guess::from_path(&task.local_path)
        .first_or_octet_stream()
        .to_string();
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
        .map_err(|error| error.to_string())?;
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
    let client = s3::client_for(account, secret).await;
    let created = client
        .create_multipart_upload()
        .bucket(&task.bucket)
        .key(&task.key)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    let upload_id = created
        .upload_id()
        .ok_or_else(|| "Multipart upload id missing.".to_string())?
        .to_string();
    let mut file = tokio::fs::File::open(&task.local_path)
        .await
        .map_err(|error| error.to_string())?;
    let mut parts = Vec::new();
    let mut offset = 0u64;
    let mut part_number = 1i32;
    let result = loop {
        if manager.is_cancelled(&task.id) {
            break Err("Transfer cancelled.".to_string());
        }
        if manager.is_paused(&task.id) {
            break Err("Transfer paused.".to_string());
        }
        let remaining = task.size.saturating_sub(offset);
        if remaining == 0 {
            break Ok(());
        }
        let length = remaining.min(PART_SIZE) as usize;
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
            .upload_id(&upload_id)
            .part_number(part_number)
            .body(aws_sdk_s3::primitives::ByteStream::from(data))
            .send()
            .await
            .map_err(|error| error.to_string())?;
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
    };

    match result {
        Ok(()) => {
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
                .map_err(|error| error.to_string())?;
            Ok(())
        }
        Err(error) => {
            let _ = client
                .abort_multipart_upload()
                .bucket(&task.bucket)
                .key(&task.key)
                .upload_id(&upload_id)
                .send()
                .await;
            Err(error)
        }
    }
}

pub async fn run_download(
    app: AppHandle,
    manager: Arc<TransferManager>,
    account: Account,
    secret: String,
    id: String,
) {
    let Some(task) = manager.get(&id) else { return };
    if manager.is_cancelled(&id) {
        manager.set_status(&app, &id, "cancelled", None);
        return;
    }
    manager.set_status(&app, &id, "running", None);
    let result = download(&app, &manager, &account, &secret, &task).await;
    match result {
        Ok(()) => manager.update(&app, &id, |task| {
            task.transferred = task.size;
            task.status = "completed".to_string();
            task.error = None;
        }),
        Err(error) => {
            let status = if manager.is_cancelled(&id) {
                "cancelled"
            } else {
                "failed"
            };
            manager.set_status(&app, &id, status, Some(error));
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
    let client = s3::client_for(account, secret).await;
    let response = client
        .get_object()
        .bucket(&task.bucket)
        .key(&task.key)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    let mut body = response.body;
    let destination = PathBuf::from(&task.local_path);
    let temporary = destination.with_extension("bucket-manager-part");
    if let Some(parent) = temporary.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|error| error.to_string())?;
    }
    let mut file = tokio::fs::File::create(&temporary)
        .await
        .map_err(|error| error.to_string())?;
    let mut transferred = 0u64;
    while let Some(chunk) = body.next().await {
        if manager.is_cancelled(&task.id) {
            drop(file);
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err("Transfer cancelled.".to_string());
        }
        let bytes = chunk.map_err(|error| error.to_string())?;
        file.write_all(&bytes)
            .await
            .map_err(|error| error.to_string())?;
        transferred += bytes.len() as u64;
        manager.update(app, &task.id, |task| {
            task.transferred = transferred;
            task.status = "running".to_string();
        });
    }
    file.flush().await.map_err(|error| error.to_string())?;
    drop(file);
    tokio::fs::rename(&temporary, &destination)
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
