mod accounts;
mod s3;

use accounts::{Account, AccountInput, AccountStore};
use std::fs::OpenOptions;
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::menu::{CheckMenuItem, CheckMenuItemBuilder, MenuBuilder, SubmenuBuilder};
use tauri::{AppHandle, Emitter, Manager, State, Wry};

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
    appearance: Mutex<AppearanceMode>,
    menu_items: Mutex<Option<AppearanceMenuItems>>,
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
    let result = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState {
            store,
            appearance: Mutex::new(appearance),
            menu_items: Mutex::new(None),
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
            let menu = MenuBuilder::new(app).items(&[&view_menu]).build()?;
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
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_appearance,
            set_appearance,
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
