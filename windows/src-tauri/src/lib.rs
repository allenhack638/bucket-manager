mod accounts;
mod logging;
mod metrics;
mod s3;
mod transfer;

use accounts::{Account, AccountInput, AccountStore};
use logging::{LogFields, LogFilter, LogRecord, LogStore, LoggingSettings};
use metrics::{MetricsStore, RequestMetric};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tauri::menu::{
    CheckMenuItem, CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder,
};
use tauri::{AppHandle, Emitter, Manager, State, Wry};
use transfer::{TransferManager, TransferTask};

#[derive(Clone, Copy, PartialEq, Eq)]
enum AppearanceMode {
    System,
    Light,
    Dark,
}

impl AppearanceMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        match value {
            "system" => Some(Self::System),
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

struct AppearanceMenuItems {
    system: CheckMenuItem<Wry>,
    light: CheckMenuItem<Wry>,
    dark: CheckMenuItem<Wry>,
}

pub struct AppState {
    pub store: AccountStore,
    pub transfers: Arc<TransferManager>,
    pub logs: Arc<LogStore>,
    pub metrics: Arc<MetricsStore>,
    appearance: Mutex<AppearanceMode>,
    menu_items: Mutex<Option<AppearanceMenuItems>>,
    logs_tab: Mutex<Option<String>>,
}

#[tauri::command]
fn list_transfers(state: State<'_, AppState>) -> Vec<TransferTask> {
    state.transfers.list()
}

fn spawn_transfer(app: &AppHandle, state: &AppState, task: TransferTask) -> Result<(), String> {
    let account = state.store.get(&task.account_id)?;
    let secret = state.store.secret(&task.account_id)?;
    let manager = state.transfers.clone();
    let app = app.clone();
    let id = task.id.clone();
    let logs = state.logs.clone();
    let metrics = state.metrics.clone();
    if task.kind == "upload" {
        tauri::async_runtime::spawn(async move {
            transfer::run_upload(app, manager, account, secret, id, logs, metrics).await;
        });
    } else {
        tauri::async_runtime::spawn(async move {
            transfer::run_download(app, manager, account, secret, id, logs, metrics).await;
        });
    }
    Ok(())
}

#[tauri::command]
fn enqueue_upload(
    app: AppHandle,
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
    file_path: String,
) -> Result<TransferTask, String> {
    let task = state
        .transfers
        .add_upload(&app, &id, &bucket, &key, &file_path)?;
    spawn_transfer(&app, &state, task.clone())?;
    Ok(task)
}

#[tauri::command]
fn enqueue_download(
    app: AppHandle,
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
    destination: String,
    size: u64,
) -> Result<TransferTask, String> {
    let task = state
        .transfers
        .add_download(&app, &id, &bucket, &key, &destination, size);
    spawn_transfer(&app, &state, task.clone())?;
    Ok(task)
}

#[tauri::command]
fn pause_transfer(app: AppHandle, state: State<'_, AppState>, id: String) {
    state.transfers.pause(&app, &id);
}

#[tauri::command]
fn resume_transfer(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let Some(task) = state.transfers.get(&id) else {
        return Err("Transfer not found.".to_string());
    };
    state.transfers.resume(&app, &id);
    spawn_transfer(&app, &state, task)
}

#[tauri::command]
fn cancel_transfer(app: AppHandle, state: State<'_, AppState>, id: String) {
    state.transfers.cancel(&app, &id);
}

#[tauri::command]
fn retry_transfer(app: AppHandle, state: State<'_, AppState>, id: String) -> Result<(), String> {
    let Some(task) = state.transfers.get(&id) else {
        return Err("Transfer not found.".to_string());
    };
    state.transfers.retry(&app, &id);
    spawn_transfer(&app, &state, task)
}

#[tauri::command]
fn get_appearance(state: State<'_, AppState>) -> String {
    state
        .appearance
        .lock()
        .map(|mode| mode.as_str().to_string())
        .unwrap_or_else(|_| "system".to_string())
}

#[tauri::command]
fn set_appearance(app: AppHandle, state: State<'_, AppState>, mode: String) -> Result<(), String> {
    apply_appearance(&app, &state, &mode)
}

#[tauri::command]
fn list_accounts(state: State<'_, AppState>) -> Result<Vec<Account>, String> {
    Ok(state.store.list())
}

#[tauri::command]
fn save_account(state: State<'_, AppState>, input: AccountInput) -> Result<Account, String> {
    let result = state.store.save(input);
    if let Ok(account) = &result {
        state.logs.audit(
            "account.saved",
            "Storage account saved",
            LogFields {
                account_id: Some(account.id.clone()),
                account_name: Some(account.name.clone()),
                operation: Some("SaveAccount".into()),
                ..Default::default()
            },
            Some("success".into()),
        );
    }
    result
}

#[tauri::command]
fn delete_account(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let account = state.store.get(&id).ok();
    let result = state.store.delete(&id);
    if result.is_ok() {
        state.logs.audit(
            "account.deleted",
            "Storage account deleted",
            LogFields {
                account_id: Some(id.clone()),
                account_name: account.map(|account| account.name),
                operation: Some("DeleteAccount".into()),
                ..Default::default()
            },
            Some("success".into()),
        );
    }
    result
}

#[tauri::command]
async fn test_connection(state: State<'_, AppState>, id: String) -> Result<String, String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let bucket = account.bucket.clone().unwrap_or_default();
    let result = s3::test_connection(&account, &secret).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "TestConnection",
        "connection.tested",
        "connection.failed",
        None,
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
async fn list_buckets(
    state: State<'_, AppState>,
    id: String,
) -> Result<Vec<s3::BucketInfo>, String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::list_buckets(&account, &secret).await;
    record_operation(
        &state,
        &account,
        "",
        "ListBuckets",
        "buckets.listed",
        "buckets.list_failed",
        None,
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
async fn create_bucket(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::create_bucket(&account, &secret, &bucket).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "CreateBucket",
        "bucket.created",
        "bucket.create_failed",
        None,
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
async fn delete_bucket(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::delete_bucket(&account, &secret, &bucket).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "DeleteBucket",
        "bucket.deleted",
        "bucket.delete_failed",
        None,
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
async fn list_objects(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    prefix: String,
    continuation_token: Option<String>,
) -> Result<s3::ListPage, String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::list_objects(&account, &secret, &bucket, &prefix, continuation_token).await;
    let bytes = result
        .as_ref()
        .map(|page| {
            page.entries
                .iter()
                .filter_map(|entry| entry.size)
                .map(|size| size.max(0) as u64)
                .sum()
        })
        .unwrap_or(0);
    record_operation(
        &state,
        &account,
        &bucket,
        "ListObjectsV2",
        "objects.listed",
        "objects.list_failed",
        None,
        started,
        bytes,
        &result,
    );
    result
}

#[tauri::command]
async fn upload_object(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
    file_path: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let bytes = std::fs::metadata(&file_path).map(|m| m.len()).unwrap_or(0);
    let result = s3::upload_object(&account, &secret, &bucket, &key, &file_path).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "PutObject",
        "object.uploaded",
        "object.upload_failed",
        Some(&key),
        started,
        bytes,
        &result,
    );
    result
}

#[tauri::command]
async fn download_object(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
    destination: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::download_object(&account, &secret, &bucket, &key, &destination).await;
    let bytes = std::fs::metadata(&destination)
        .map(|m| m.len())
        .unwrap_or(0);
    record_operation(
        &state,
        &account,
        &bucket,
        "GetObject",
        "object.downloaded",
        "object.download_failed",
        Some(&key),
        started,
        bytes,
        &result,
    );
    result
}

#[tauri::command]
async fn delete_object(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::delete_object(&account, &secret, &bucket, &key).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "DeleteObject",
        "object.deleted",
        "object.delete_failed",
        Some(&key),
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
async fn create_folder(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
    key: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    let started = Instant::now();
    let result = s3::create_folder(&account, &secret, &bucket, &key).await;
    record_operation(
        &state,
        &account,
        &bucket,
        "PutObject",
        "folder.created",
        "folder.create_failed",
        Some(&key),
        started,
        0,
        &result,
    );
    result
}

#[tauri::command]
fn get_logs(state: State<'_, AppState>, filter: LogFilter) -> Vec<LogRecord> {
    state.logs.recent(filter)
}

#[tauri::command]
fn get_logging_settings(state: State<'_, AppState>) -> LoggingSettings {
    state.logs.settings()
}

#[tauri::command]
fn save_logging_settings(
    state: State<'_, AppState>,
    settings: LoggingSettings,
) -> Result<(), String> {
    state.logs.update_settings(settings)
}

#[tauri::command]
fn clear_diagnostics(state: State<'_, AppState>) -> Result<usize, String> {
    state.logs.clear_diagnostics()
}

#[tauri::command]
fn export_logs(
    state: State<'_, AppState>,
    destination: String,
    filter: LogFilter,
) -> Result<usize, String> {
    state.logs.export(&destination, filter)
}

#[tauri::command]
fn reveal_logs(state: State<'_, AppState>) -> Result<(), String> {
    state.logs.reveal()
}

#[tauri::command]
fn get_statistics(state: State<'_, AppState>) -> Vec<RequestMetric> {
    state.metrics.snapshot()
}

#[tauri::command]
fn clear_statistics(state: State<'_, AppState>) {
    state.metrics.clear();
    state.logs.audit(
        "metrics.cleared",
        "Request statistics cleared",
        LogFields {
            operation: Some("ClearStatistics".into()),
            ..Default::default()
        },
        Some("success".into()),
    );
}

#[tauri::command]
fn take_logs_tab(state: State<'_, AppState>) -> Option<String> {
    state.logs_tab.lock().ok().and_then(|mut tab| tab.take())
}

#[tauri::command]
fn open_logs_window(
    app: AppHandle,
    state: State<'_, AppState>,
    tab: Option<String>,
) -> Result<(), String> {
    open_logs_window_impl(&app, &state, tab.as_deref().unwrap_or("logs"))
}

fn open_logs_window_impl(app: &AppHandle, state: &AppState, tab: &str) -> Result<(), String> {
    if let Ok(mut pending) = state.logs_tab.lock() {
        *pending = Some(tab.to_string());
    }
    if let Some(window) = app.get_webview_window("logs") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        let _ = window.emit("logs-tab", tab);
        return Ok(());
    }
    let window = app
        .get_webview_window("logs")
        .ok_or_else(|| "Logs window is unavailable.".to_string())?;
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
    let _ = window.emit("logs-tab", tab);
    Ok(())
}

fn record_operation(
    state: &AppState,
    account: &Account,
    bucket: &str,
    operation: &str,
    event_success: &str,
    event_failure: &str,
    key: Option<&str>,
    started: Instant,
    bytes: u64,
    result: &Result<impl Sized, String>,
) {
    let elapsed = started.elapsed().as_millis() as u64;
    let success = result.is_ok();
    state.metrics.record(
        &account.id,
        &account.name,
        bucket,
        operation,
        elapsed,
        bytes,
        success,
    );
    let error = result.as_ref().err().cloned();
    let message = if success {
        format!("{operation} completed")
    } else {
        format!("{operation} failed")
    };
    state.logs.audit(
        if success {
            event_success
        } else {
            event_failure
        },
        &message,
        LogFields {
            account_id: Some(account.id.clone()),
            account_name: Some(account.name.clone()),
            operation: Some(operation.to_string()),
            bucket: (!bucket.is_empty()).then(|| bucket.to_string()),
            key: key.map(str::to_string),
            metadata: error.map(|error| serde_json::json!({ "error": error })),
        },
        Some(if success { "success" } else { "failure" }.to_string()),
    );
}

fn appearance_path() -> Option<std::path::PathBuf> {
    dirs::config_dir().map(|directory| directory.join("BucketManager").join("appearance.txt"))
}

fn load_appearance() -> AppearanceMode {
    appearance_path()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .and_then(|value| AppearanceMode::parse(value.trim()))
        .unwrap_or(AppearanceMode::System)
}

fn save_appearance(mode: AppearanceMode) -> Result<(), String> {
    let path = appearance_path().ok_or_else(|| "Could not locate AppData.".to_string())?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    std::fs::write(path, mode.as_str()).map_err(|error| error.to_string())
}

fn apply_appearance(app: &AppHandle, state: &AppState, value: &str) -> Result<(), String> {
    let mode =
        AppearanceMode::parse(value).ok_or_else(|| format!("Unknown appearance mode: {value}"))?;
    *state
        .appearance
        .lock()
        .map_err(|_| "Appearance state is locked.".to_string())? = mode;
    save_appearance(mode)?;

    if let Some(items) = state
        .menu_items
        .lock()
        .map_err(|_| "Appearance menu is locked.".to_string())?
        .as_ref()
    {
        items
            .system
            .set_checked(mode == AppearanceMode::System)
            .map_err(|error| error.to_string())?;
        items
            .light
            .set_checked(mode == AppearanceMode::Light)
            .map_err(|error| error.to_string())?;
        items
            .dark
            .set_checked(mode == AppearanceMode::Dark)
            .map_err(|error| error.to_string())?;
    }

    app.emit("appearance-changed", mode.as_str())
        .map_err(|error| error.to_string())
}

fn startup_log(message: &str) {
    let directory = dirs::data_local_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("BucketManager");
    let _ = std::fs::create_dir_all(&directory);
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(directory.join("startup.log"))
    {
        let _ = writeln!(
            file,
            "{:?} {message}",
            SystemTime::now().duration_since(UNIX_EPOCH)
        );
    }
}

pub fn run() {
    std::panic::set_hook(Box::new(|panic| {
        startup_log(&format!("panic: {panic}"));
    }));
    startup_log("run start");

    let store = AccountStore::load().unwrap_or_else(|error| {
        startup_log(&format!("could not load accounts: {error}"));
        AccountStore::empty()
    });
    startup_log("account store loaded");

    let appearance = load_appearance();
    let transfers = Arc::new(TransferManager::load());
    let logs = Arc::new(LogStore::new());
    let metrics = Arc::new(MetricsStore::new());
    logs.audit(
        "app.started",
        "Bucket Manager started",
        LogFields {
            operation: Some("Startup".into()),
            ..Default::default()
        },
        Some("success".into()),
    );
    let result = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            store,
            transfers,
            logs,
            metrics,
            appearance: Mutex::new(appearance),
            menu_items: Mutex::new(None),
            logs_tab: Mutex::new(None),
        })
        .setup(move |app| {
            startup_log("setup");

            let state = app.state::<AppState>();
            let system = CheckMenuItemBuilder::with_id("appearance:system", "System")
                .checked(appearance == AppearanceMode::System)
                .build(app)?;
            let light = CheckMenuItemBuilder::with_id("appearance:light", "Light")
                .checked(appearance == AppearanceMode::Light)
                .build(app)?;
            let dark = CheckMenuItemBuilder::with_id("appearance:dark", "Dark")
                .checked(appearance == AppearanceMode::Dark)
                .build(app)?;
            let appearance_menu = SubmenuBuilder::new(app, "Appearance")
                .items(&[&system, &light, &dark])
                .build()?;
            let view_menu = SubmenuBuilder::new(app, "View")
                .items(&[&appearance_menu])
                .build()?;
            let logs_item = MenuItemBuilder::with_id("window:logs", "Logs & Statistics…")
                .accelerator("Ctrl+Alt+L")
                .build(app)?;
            let settings_item = MenuItemBuilder::with_id("window:settings", "Settings…")
                .accelerator("Ctrl+Alt+S")
                .build(app)?;
            let window_menu = SubmenuBuilder::new(app, "Window")
                .items(&[&logs_item, &settings_item])
                .build()?;
            let menu = MenuBuilder::new(app)
                .items(&[&view_menu, &window_menu])
                .build()?;
            app.set_menu(menu)?;
            *state
                .menu_items
                .lock()
                .map_err(|_| "Appearance menu is locked.".to_string())? =
                Some(AppearanceMenuItems {
                    system,
                    light,
                    dark,
                });

            match app.get_webview_window("main") {
                Some(window) => {
                    let scale = window.scale_factor().unwrap_or(1.0);
                    let before = window.inner_size();
                    let _ = window.set_size(tauri::Size::Physical(tauri::PhysicalSize::new(
                        (1120.0 * scale).round() as u32,
                        (650.0 * scale).round() as u32,
                    )));
                    let after = window.inner_size();
                    startup_log(&format!(
                        "main window exists; scale={scale}; inner {before:?} -> {after:?}"
                    ));
                    let _ = window.show();
                    let _ = window.set_focus();
                }
                None => {
                    startup_log("main window missing; creating it");
                    tauri::WebviewWindowBuilder::new(app, "main", tauri::WebviewUrl::default())
                        .title("Bucket Manager")
                        .inner_size(1120.0, 650.0)
                        .min_inner_size(900.0, 560.0)
                        .build()?;
                }
            }
            Ok(())
        })
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            if let Some(mode) = id.strip_prefix("appearance:") {
                if let Some(state) = app.try_state::<AppState>() {
                    if let Err(error) = apply_appearance(app, &state, mode) {
                        startup_log(&format!("appearance change failed: {error}"));
                    }
                }
            } else if let Some(tab) = id.strip_prefix("window:") {
                if let Some(state) = app.try_state::<AppState>() {
                    if let Err(error) = open_logs_window_impl(app, &state, tab) {
                        startup_log(&format!("open logs window failed: {error}"));
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            list_transfers,
            enqueue_upload,
            enqueue_download,
            pause_transfer,
            resume_transfer,
            cancel_transfer,
            retry_transfer,
            get_appearance,
            set_appearance,
            get_logs,
            get_logging_settings,
            save_logging_settings,
            clear_diagnostics,
            export_logs,
            reveal_logs,
            get_statistics,
            clear_statistics,
            open_logs_window,
            take_logs_tab,
            list_accounts,
            save_account,
            delete_account,
            test_connection,
            list_buckets,
            create_bucket,
            delete_bucket,
            list_objects,
            upload_object,
            download_object,
            delete_object,
            create_folder
        ])
        .run(tauri::generate_context!());

    match result {
        Ok(()) => startup_log("run returned Ok"),
        Err(error) => {
            startup_log(&format!("run returned error: {error}"));
            std::process::exit(1);
        }
    }
}
