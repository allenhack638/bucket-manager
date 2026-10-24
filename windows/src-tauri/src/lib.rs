mod accounts;
mod s3;

use accounts::{Account, AccountInput, AccountStore};
use tauri::State;

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

pub fn run() {
    let store = AccountStore::load().unwrap_or_else(|error| {
        eprintln!("Could not load accounts: {error}");
        AccountStore::empty()
    });

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { store })
        .invoke_handler(tauri::generate_handler![
            list_accounts,
            save_account,
            delete_account,
            test_connection,
            list_buckets,
            list_objects,
            upload_object,
            download_object,
            delete_object,
            create_folder
        ])
        .run(tauri::generate_context!())
        .expect("error while running Bucket Manager");
}
