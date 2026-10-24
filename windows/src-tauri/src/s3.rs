use crate::accounts::Account;
use aws_config::BehaviorVersion;
use aws_credential_types::Credentials;
use aws_sdk_s3::config::Region;
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::Client;
use serde::Serialize;
use std::path::Path;
use tokio::fs;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BucketInfo {
    pub name: String,
    pub creation_date: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectEntry {
    pub key: String,
    pub name: String,
    pub kind: String,
    pub size: Option<i64>,
    pub last_modified: Option<String>,
    pub storage_class: Option<String>,
    pub e_tag: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListPage {
    pub bucket: String,
    pub prefix: String,
    pub entries: Vec<ObjectEntry>,
    pub next_token: Option<String>,
}

pub async fn client_for(account: &Account, secret: &str) -> Client {
    let credentials = Credentials::new(
        account.access_key_id.clone(),
        secret.to_string(),
        None,
        None,
        "bucket-manager-windows",
    );

    let mut loader = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(account.region.clone()))
        .credentials_provider(credentials);

    if let Some(endpoint) = account
        .endpoint
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        loader = loader.endpoint_url(endpoint);
    }

    let shared = loader.load().await;
    let mut config = aws_sdk_s3::config::Builder::from(&shared);
    if account.path_style {
        config = config.force_path_style(true);
    }
    Client::from_conf(config.build())
}

pub async fn list_buckets(account: &Account, secret: &str) -> Result<Vec<BucketInfo>, String> {
    if let Some(bucket) = account
        .bucket
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return Ok(vec![BucketInfo {
            name: bucket.to_string(),
            creation_date: None,
        }]);
    }

    let client = client_for(account, secret).await;
    let response = client
        .list_buckets()
        .send()
        .await
        .map_err(|error| error.to_string())?;

    Ok(response
        .buckets()
        .iter()
        .filter_map(|bucket| {
            bucket.name().map(|name| BucketInfo {
                name: name.to_string(),
                creation_date: bucket.creation_date().map(ToString::to_string),
            })
        })
        .collect())
}

pub async fn list_objects(
    account: &Account,
    secret: &str,
    bucket: &str,
    prefix: &str,
    continuation_token: Option<String>,
) -> Result<ListPage, String> {
    if bucket.trim().is_empty() {
        return Err("A bucket is required.".to_string());
    }

    let prefix = normalize_prefix(prefix);
    let client = client_for(account, secret).await;
    let mut request = client
        .list_objects_v2()
        .bucket(bucket)
        .delimiter("/")
        .prefix(&prefix)
        .max_keys(1000);

    if let Some(token) = continuation_token.filter(|value| !value.is_empty()) {
        request = request.continuation_token(token);
    }

    let response = request.send().await.map_err(|error| error.to_string())?;
    let mut entries = Vec::new();

    for folder in response.common_prefixes() {
        if let Some(key) = folder.prefix() {
            entries.push(ObjectEntry {
                key: key.to_string(),
                name: display_name(key, &prefix),
                kind: "folder".to_string(),
                size: None,
                last_modified: None,
                storage_class: None,
                e_tag: None,
            });
        }
    }

    for object in response.contents() {
        if let Some(key) = object.key() {
            if key == prefix {
                continue;
            }
            entries.push(ObjectEntry {
                key: key.to_string(),
                name: display_name(key, &prefix),
                kind: "object".to_string(),
                size: object.size(),
                last_modified: object.last_modified().map(ToString::to_string),
                storage_class: object
                    .storage_class()
                    .map(|storage_class| storage_class.as_str().to_string()),
                e_tag: object.e_tag().map(str::to_string),
            });
        }
    }

    entries.sort_by(|left, right| {
        let left_folder = left.kind == "folder";
        let right_folder = right.kind == "folder";
        right_folder
            .cmp(&left_folder)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
    });

    Ok(ListPage {
        bucket: bucket.to_string(),
        prefix,
        entries,
        next_token: response.next_continuation_token().map(str::to_string),
    })
}

pub async fn test_connection(account: &Account, secret: &str) -> Result<String, String> {
    let client = client_for(account, secret).await;

    if let Some(bucket) = account
        .bucket
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        client
            .list_objects_v2()
            .bucket(bucket)
            .max_keys(1)
            .send()
            .await
            .map_err(|error| error.to_string())?;
        return Ok(format!("Connected to bucket {bucket}."));
    }

    let response = client
        .list_buckets()
        .send()
        .await
        .map_err(|error| error.to_string())?;
    Ok(format!(
        "Connected. {} bucket(s) visible.",
        response.buckets().len()
    ))
}

pub async fn upload_object(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
    file_path: &str,
) -> Result<(), String> {
    if key.trim().is_empty() || key.ends_with('/') {
        return Err("A file key is required.".to_string());
    }

    let path = Path::new(file_path);
    let metadata = fs::metadata(path)
        .await
        .map_err(|error| format!("Could not read {}: {error}", path.display()))?;
    if !metadata.is_file() {
        return Err("Choose a file to upload.".to_string());
    }

    let content_type = mime_guess::from_path(path)
        .first_or_octet_stream()
        .to_string();
    let body = ByteStream::from_path(path)
        .await
        .map_err(|error| format!("Could not open {}: {error}", path.display()))?;

    let client = client_for(account, secret).await;
    client
        .put_object()
        .bucket(bucket)
        .key(key)
        .content_type(content_type)
        .body(body)
        .send()
        .await
        .map_err(|error| error.to_string())?;

    Ok(())
}

pub async fn download_object(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
    destination: &str,
) -> Result<(), String> {
    if key.ends_with('/') {
        return Err("Choose a file to download.".to_string());
    }

    let client = client_for(account, secret).await;
    let response = client
        .get_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    let bytes = response
        .body
        .collect()
        .await
        .map_err(|error| error.to_string())?
        .into_bytes();

    let destination = Path::new(destination);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .await
            .map_err(|error| error.to_string())?;
    }
    let temporary = destination.with_extension("bucket-manager-part");
    fs::write(&temporary, &bytes)
        .await
        .map_err(|error| error.to_string())?;
    fs::rename(&temporary, destination)
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

pub async fn delete_object(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<(), String> {
    let client = client_for(account, secret).await;

    if key.ends_with('/') {
        let mut token: Option<String> = None;
        loop {
            let mut request = client
                .list_objects_v2()
                .bucket(bucket)
                .prefix(key)
                .max_keys(1000);
            if let Some(current) = token.as_deref() {
                request = request.continuation_token(current);
            }
            let response = request.send().await.map_err(|error| error.to_string())?;

            for object in response.contents() {
                if let Some(object_key) = object.key() {
                    client
                        .delete_object()
                        .bucket(bucket)
                        .key(object_key)
                        .send()
                        .await
                        .map_err(|error| error.to_string())?;
                }
            }

            token = response.next_continuation_token().map(str::to_string);
            if token.is_none() {
                break;
            }
        }
        return Ok(());
    }

    client
        .delete_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

pub async fn create_folder(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<(), String> {
    let key = if key.ends_with('/') {
        key.to_string()
    } else {
        format!("{key}/")
    };
    let client = client_for(account, secret).await;
    client
        .put_object()
        .bucket(bucket)
        .key(key)
        .body(ByteStream::from(Vec::new()))
        .send()
        .await
        .map_err(|error| error.to_string())?;
    Ok(())
}

fn normalize_prefix(prefix: &str) -> String {
    let trimmed = prefix.trim_start_matches('/');
    if trimmed.is_empty() {
        String::new()
    } else if trimmed.ends_with('/') {
        trimmed.to_string()
    } else {
        format!("{trimmed}/")
    }
}

fn display_name(key: &str, prefix: &str) -> String {
    key.strip_prefix(prefix)
        .unwrap_or(key)
        .trim_end_matches('/')
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::{display_name, normalize_prefix};

    #[test]
    fn normalizes_folder_prefixes() {
        assert_eq!(normalize_prefix(""), "");
        assert_eq!(normalize_prefix("/photos"), "photos/");
        assert_eq!(normalize_prefix("photos/"), "photos/");
    }

    #[test]
    fn strips_the_current_prefix_from_display_names() {
        assert_eq!(display_name("photos/2024/a.jpg", "photos/2024/"), "a.jpg");
        assert_eq!(display_name("photos/2024/", ""), "photos/2024");
    }
}
