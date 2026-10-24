mod accounts;
mod s3;

use accounts::{Account, AccountInput, AccountStore};
use std::fs::OpenOptions;
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{Manager, State};

pub struct AppState {
    pub store: AccountStore,
}

#[tauri::command]
fn list_accounts(state: State<'_, AppState>) -> Result<Vec<Account>, String> {
    Ok(state.store.list())
}

#[tauri::command]
fn save_account(state: State<'_, AppState>, input: AccountInput) -> Result<Account, String> {
    state.store.save(input)
}

#[tauri::command]
fn delete_account(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state.store.delete(&id)
}

#[tauri::command]
async fn test_connection(state: State<'_, AppState>, id: String) -> Result<String, String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    s3::test_connection(&account, &secret).await
}

#[tauri::command]
async fn list_buckets(
    state: State<'_, AppState>,
    id: String,
) -> Result<Vec<s3::BucketInfo>, String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    s3::list_buckets(&account, &secret).await
}

#[tauri::command]
async fn create_bucket(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    s3::create_bucket(&account, &secret, &bucket).await
}

#[tauri::command]
async fn delete_bucket(
    state: State<'_, AppState>,
    id: String,
    bucket: String,
) -> Result<(), String> {
    let account = state.store.get(&id)?;
    let secret = state.store.secret(&id)?;
    s3::delete_bucket(&account, &secret, &bucket).await
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
    s3::list_objects(&account, &secret, &bucket, &prefix, continuation_token).await
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
    s3::upload_object(&account, &secret, &bucket, &key, &file_path).await
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
    s3::download_object(&account, &secret, &bucket, &key, &destination).await
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
    s3::delete_object(&account, &secret, &bucket, &key).await
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
    s3::create_folder(&account, &secret, &bucket, &key).await
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

    let result = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { store })
        .setup(|app| {
            startup_log("setup");
            match app.get_webview_window("main") {
                Some(window) => {
                    startup_log("main window exists");
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
        .invoke_handler(tauri::generate_handler![
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
