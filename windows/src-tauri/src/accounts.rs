use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use uuid::Uuid;

const KEYRING_SERVICE: &str = "com.bucketmanager.windows.secret";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub id: String,
    pub name: String,
    pub access_key_id: String,
    pub region: String,
    pub endpoint: Option<String>,
    pub bucket: Option<String>,
    pub path_style: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountInput {
    pub id: Option<String>,
    pub name: String,
    pub access_key_id: String,
    pub secret_access_key: Option<String>,
    pub region: String,
    pub endpoint: Option<String>,
    pub bucket: Option<String>,
    pub path_style: bool,
}

pub struct AccountStore {
    path: PathBuf,
    accounts: Mutex<Vec<Account>>,
}

impl AccountStore {
    pub fn load() -> Result<Self, String> {
        let path = accounts_path()?;
        let accounts = if path.exists() {
            let contents = fs::read_to_string(&path).map_err(|error| error.to_string())?;
            if contents.trim().is_empty() {
                Vec::new()
            } else {
                serde_json::from_str(&contents)
                    .map_err(|error| format!("Could not parse {}: {error}", path.display()))?
            }
        } else {
            Vec::new()
        };

        Ok(Self {
            path,
            accounts: Mutex::new(accounts),
        })
    }

    pub fn empty() -> Self {
        Self {
            path: accounts_path().unwrap_or_else(|_| PathBuf::from("accounts.json")),
            accounts: Mutex::new(Vec::new()),
        }
    }

    pub fn list(&self) -> Vec<Account> {
        self.accounts
            .lock()
            .map(|accounts| accounts.clone())
            .unwrap_or_default()
    }

    pub fn get(&self, id: &str) -> Result<Account, String> {
        self.accounts
            .lock()
            .map_err(|_| "Account store is locked.".to_string())?
            .iter()
            .find(|account| account.id == id)
            .cloned()
            .ok_or_else(|| "Account not found.".to_string())
    }

    pub fn secret(&self, id: &str) -> Result<String, String> {
        let entry = keyring::Entry::new(KEYRING_SERVICE, id).map_err(|error| error.to_string())?;
        entry.get_password().map_err(|error| {
            format!(
                "The secret for this account is unavailable in Windows Credential Manager: {error}"
            )
        })
    }

    pub fn save(&self, input: AccountInput) -> Result<Account, String> {
        let name = input.name.trim();
        let access_key_id = input.access_key_id.trim();
        let region = input.region.trim();
        let endpoint = clean_endpoint(input.endpoint.as_deref())?;
        let bucket = clean_optional(input.bucket.as_deref())?;

        if name.is_empty() {
            return Err("Display name is required.".to_string());
        }
        if access_key_id.is_empty() {
            return Err("Access key ID is required.".to_string());
        }
        if region.is_empty() {
            return Err("Region is required.".to_string());
        }

        let mut accounts = self
            .accounts
            .lock()
            .map_err(|_| "Account store is locked.".to_string())?;
        let existing_index = input
            .id
            .as_deref()
            .and_then(|id| accounts.iter().position(|account| account.id == id));
        let previous = existing_index.map(|index| accounts[index].clone());
        let id = input
            .id
            .clone()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let secret = input
            .secret_access_key
            .as_deref()
            .map(str::trim)
            .unwrap_or_default();
        if existing_index.is_none() && secret.is_empty() {
            return Err("Secret access key is required for a new account.".to_string());
        }
        if !secret.is_empty() {
            let entry = keyring::Entry::new(KEYRING_SERVICE, &id)
                .map_err(|error| format!("Could not open Windows Credential Manager: {error}"))?;
            entry
                .set_password(secret)
                .map_err(|error| format!("Could not store the secret: {error}"))?;
        }

        let account = Account {
            id,
            name: name.to_string(),
            access_key_id: access_key_id.to_string(),
            region: region.to_string(),
            endpoint,
            bucket,
            path_style: input.path_style,
        };

        if let Some(index) = existing_index {
            accounts[index] = account.clone();
        } else {
            accounts.push(account.clone());
        }

        if let Err(error) = self.write(&accounts) {
            if let Some(index) = existing_index {
                if let Some(previous) = previous {
                    accounts[index] = previous;
                }
            } else {
                accounts.pop();
            }
            return Err(error);
        }

        Ok(account)
    }

    pub fn delete(&self, id: &str) -> Result<(), String> {
        let mut accounts = self
            .accounts
            .lock()
            .map_err(|_| "Account store is locked.".to_string())?;
        let before = accounts.len();
        accounts.retain(|account| account.id != id);
        if accounts.len() == before {
            return Err("Account not found.".to_string());
        }
        self.write(&accounts)?;
        if let Ok(entry) = keyring::Entry::new(KEYRING_SERVICE, id) {
            let _ = entry.delete_credential();
        }
        Ok(())
    }

    fn write(&self, accounts: &[Account]) -> Result<(), String> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let contents = serde_json::to_vec_pretty(accounts).map_err(|error| error.to_string())?;
        write_private(&self.path, &contents)
    }
}

fn accounts_path() -> Result<PathBuf, String> {
    let base = dirs::config_dir().ok_or_else(|| "Could not locate AppData.".to_string())?;
    Ok(base.join("BucketManager").join("accounts.json"))
}

fn clean_optional(value: Option<&str>) -> Result<Option<String>, String> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    Ok(Some(value.to_string()))
}

fn clean_endpoint(value: Option<&str>) -> Result<Option<String>, String> {
    let Some(value) = clean_optional(value)? else {
        return Ok(None);
    };
    let local_http = value.starts_with("http://localhost")
        || value.starts_with("http://127.0.0.1")
        || value.starts_with("http://[::1]");
    if !value.starts_with("https://") && !local_http {
        return Err("The endpoint must use HTTPS, except for localhost.".to_string());
    }
    Ok(Some(value.trim_end_matches('/').to_string()))
}

fn write_private(path: &Path, contents: &[u8]) -> Result<(), String> {
    let mut options = fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|error| error.to_string())?;
    file.write_all(contents).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::{clean_endpoint, clean_optional};

    #[test]
    fn blank_optional_values_become_none() {
        assert_eq!(clean_optional(Some("  ")), Ok(None));
        assert_eq!(clean_optional(None), Ok(None));
    }

    #[test]
    fn requires_https_for_remote_endpoints() {
        assert!(clean_endpoint(Some("http://s3.example.com")).is_err());
        assert_eq!(
            clean_endpoint(Some("https://s3.example.com/")),
            Ok(Some("https://s3.example.com".to_string()))
        );
        assert!(clean_endpoint(Some("http://localhost:9000")).is_ok());
    }

    #[test]
    fn trims_optional_values() {
        assert_eq!(
            clean_optional(Some("  https://s3.example.com ")),
            Ok(Some("https://s3.example.com".to_string()))
        );
    }
}
