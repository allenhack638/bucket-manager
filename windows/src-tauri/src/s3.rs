use crate::accounts::Account;
use aws_config::BehaviorVersion;
use aws_credential_types::Credentials;
use aws_sdk_s3::config::Region;
use aws_sdk_s3::error::{ProvideErrorMetadata, SdkError};
use aws_sdk_s3::primitives::ByteStream;
use aws_sdk_s3::types::{BucketLocationConstraint, CreateBucketConfiguration};
use aws_sdk_s3::Client;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

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
    client_in_region(account, secret, &account.region).await
}

/// Bucket regions found for AWS accounts, keyed by (account id, bucket).
static BUCKET_REGIONS: LazyLock<Mutex<HashMap<(String, String), String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// A client aimed at the bucket's own region. An AWS account saved with one
/// region can own buckets in others; requests sent to the wrong region fail
/// with PermanentRedirect or AuthorizationHeaderMalformed. Custom endpoints
/// (MinIO, R2, …) keep the account's settings.
pub async fn client_for_bucket(account: &Account, secret: &str, bucket: &str) -> Client {
    if has_custom_endpoint(account) || bucket.is_empty() {
        return client_for(account, secret).await;
    }
    let key = (account.id.clone(), bucket.to_string());
    let cached = BUCKET_REGIONS.lock().ok().and_then(|map| map.get(&key).cloned());
    let region = match cached {
        Some(region) => region,
        None => match discover_bucket_region(account, secret, bucket).await {
            Some(region) => {
                if let Ok(mut map) = BUCKET_REGIONS.lock() {
                    map.insert(key, region.clone());
                }
                region
            }
            // Offline, denied or timed out: try again next time rather than
            // pinning the bucket to a guess.
            None => account.region.clone(),
        },
    };
    client_in_region(account, secret, &region).await
}

/// HeadBucket reports the bucket's region in `x-amz-bucket-region`, both on
/// success and on the redirect or error a wrong-region request gets.
async fn discover_bucket_region(account: &Account, secret: &str, bucket: &str) -> Option<String> {
    let client = client_for(account, secret).await;
    match client.head_bucket().bucket(bucket).send().await {
        Ok(output) => output.bucket_region().map(str::to_string),
        Err(error) => error
            .raw_response()
            .and_then(|response| response.headers().get("x-amz-bucket-region"))
            .map(str::to_string),
    }
}

/// Forgets cached bucket regions for an account (all buckets when `bucket` is
/// None), after the account is edited or a bucket is created or deleted.
/// A bucket deleted and recreated in another region outside this app makes the
/// cached region wrong; forget it when S3 says so.
fn forget_region_on_redirect<E: ProvideErrorMetadata>(account: &Account, bucket: &str, error: &SdkError<E>) {
    let status = error.raw_response().map(|response| response.status().as_u16());
    let code = error.as_service_error().and_then(|service| service.code());
    if status == Some(301)
        || matches!(code, Some("PermanentRedirect") | Some("AuthorizationHeaderMalformed"))
    {
        forget_bucket_regions(&account.id, Some(bucket));
    }
}

pub fn forget_bucket_regions(account_id: &str, bucket: Option<&str>) {
    if let Ok(mut map) = BUCKET_REGIONS.lock() {
        map.retain(|(account, name), _| {
            account != account_id || bucket.is_some_and(|bucket| bucket != name)
        });
    }
}

/// Aborts a multipart upload. Ok when the caller may forget the id: the
/// upload is gone, the server no longer knows it (NoSuchUpload), or the
/// credentials may never abort it (403; least-privilege policies often allow
/// PutObject but not AbortMultipartUpload, and retrying would block the task
/// forever). Errs only on failures worth retrying, such as a network outage.
pub async fn abort_upload(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
    upload_id: &str,
) -> Result<(), String> {
    let client = client_for_bucket(account, secret, bucket).await;
    match client
        .abort_multipart_upload()
        .bucket(bucket)
        .key(key)
        .upload_id(upload_id)
        .send()
        .await
    {
        Ok(_) => Ok(()),
        Err(error) => {
            let status = error.raw_response().map(|response| response.status().as_u16());
            let code = error.as_service_error().and_then(|service| service.code());
            if matches!(status, Some(403) | Some(404))
                || matches!(code, Some("NoSuchUpload") | Some("AccessDenied"))
            {
                Ok(())
            } else {
                Err(s3_error(&error))
            }
        }
    }
}

fn has_custom_endpoint(account: &Account) -> bool {
    account
        .endpoint
        .as_deref()
        .map(str::trim)
        .is_some_and(|value| !value.is_empty())
}

async fn client_in_region(account: &Account, secret: &str, region: &str) -> Client {
    let credentials = Credentials::new(
        account.access_key_id.clone(),
        secret.to_string(),
        None,
        None,
        "bucket-manager-windows",
    );

    let mut loader = aws_config::defaults(BehaviorVersion::latest())
        .region(Region::new(region.to_string()))
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
        .map_err(|error| s3_error(&error))?;

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

pub async fn create_bucket(account: &Account, secret: &str, bucket: &str) -> Result<(), String> {
    if bucket.trim().is_empty() {
        return Err("A bucket name is required.".to_string());
    }
    let client = client_for(account, secret).await;
    let mut request = client.create_bucket().bucket(bucket);
    if account.region != "us-east-1" {
        let configuration = CreateBucketConfiguration::builder()
            .location_constraint(BucketLocationConstraint::from(account.region.as_str()))
            .build();
        request = request.create_bucket_configuration(configuration);
    }
    request.send().await.map_err(|error| s3_error(&error))?;
    forget_bucket_regions(&account.id, Some(bucket));
    Ok(())
}

pub async fn delete_bucket(account: &Account, secret: &str, bucket: &str) -> Result<(), String> {
    let client = client_for_bucket(account, secret, bucket).await;
    client
        .delete_bucket()
        .bucket(bucket)
        .send()
        .await
        .map_err(|error| s3_error(&error))?;
    forget_bucket_regions(&account.id, Some(bucket));
    Ok(())
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
    let client = client_for_bucket(account, secret, bucket).await;
    let mut request = client
        .list_objects_v2()
        .bucket(bucket)
        .delimiter("/")
        .prefix(&prefix)
        .max_keys(1000);

    if let Some(token) = continuation_token.filter(|value| !value.is_empty()) {
        request = request.continuation_token(token);
    }

    let response = request.send().await.map_err(|error| {
        forget_region_on_redirect(account, bucket, &error);
        s3_error(&error)
    })?;
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
        client_for_bucket(account, secret, bucket)
            .await
            .list_objects_v2()
            .bucket(bucket)
            .max_keys(1)
            .send()
            .await
            .map_err(|error| s3_error(&error))?;
        return Ok(format!("Connected to bucket {bucket}."));
    }

    let response = client
        .list_buckets()
        .send()
        .await
        .map_err(|error| s3_error(&error))?;
    Ok(format!(
        "Connected. {} bucket(s) visible.",
        response.buckets().len()
    ))
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectDetails {
    pub size: u64,
    pub e_tag: Option<String>,
    pub content_type: Option<String>,
}

pub async fn object_details(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<ObjectDetails, String> {
    let client = client_for_bucket(account, secret, bucket).await;
    let response = client
        .head_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map_err(|error| s3_error(&error))?;
    Ok(ObjectDetails {
        size: response.content_length().unwrap_or_default().max(0) as u64,
        e_tag: response.e_tag().map(str::to_string),
        content_type: response.content_type().map(str::to_string),
    })
}

pub async fn object_exists(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<bool, String> {
    match object_details(account, secret, bucket, key).await {
        Ok(_) => Ok(true),
        Err(error) if is_not_found(&error) => Ok(false),
        Err(error) => Err(error),
    }
}

pub async fn list_all_objects(
    account: &Account,
    secret: &str,
    bucket: &str,
    prefix: &str,
) -> Result<Vec<ObjectEntry>, String> {
    let client = client_for_bucket(account, secret, bucket).await;
    let mut token: Option<String> = None;
    let mut objects = Vec::new();
    loop {
        let mut request = client
            .list_objects_v2()
            .bucket(bucket)
            .prefix(prefix)
            .max_keys(1000);
        if let Some(current) = token.as_deref() {
            request = request.continuation_token(current);
        }
        let response = request.send().await.map_err(|error| s3_error(&error))?;
        for object in response.contents() {
            if let Some(key) = object.key() {
                if key == prefix {
                    continue;
                }
                objects.push(ObjectEntry {
                    key: key.to_string(),
                    name: display_name(key, prefix),
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
        token = response.next_continuation_token().map(str::to_string);
        if token.is_none() {
            break;
        }
    }
    Ok(objects)
}

fn is_not_found(error: &str) -> bool {
    let lower = error.to_lowercase();
    lower.contains("notfound")
        || lower.contains("not found")
        || lower.contains("status code: 404")
        || lower.contains("404")
}

pub async fn delete_object(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<(), String> {
    let client = client_for_bucket(account, secret, bucket).await;

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
            let response = request.send().await.map_err(|error| s3_error(&error))?;

            for object in response.contents() {
                if let Some(object_key) = object.key() {
                    client
                        .delete_object()
                        .bucket(bucket)
                        .key(object_key)
                        .send()
                        .await
                        .map_err(|error| s3_error(&error))?;
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
        .map_err(|error| s3_error(&error))?;
    Ok(())
}

/// Deletes exactly one key, even when it ends in "/". `delete_object` treats such
/// keys as a folder and removes everything below them, which a move of a single
/// folder-marker object must never do.
pub async fn delete_exact_object(
    account: &Account,
    secret: &str,
    bucket: &str,
    key: &str,
) -> Result<(), String> {
    let client = client_for_bucket(account, secret, bucket).await;
    client
        .delete_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map_err(|error| s3_error(&error))?;
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
    let client = client_for_bucket(account, secret, bucket).await;
    client
        .put_object()
        .bucket(bucket)
        .key(key)
        .body(ByteStream::from(Vec::new()))
        .send()
        .await
        .map_err(|error| s3_error(&error))?;
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
/// A readable message for an SDK error: the S3 code, HTTP status and message
/// for service errors, and the full cause chain (for example "dispatch
/// failure: connection refused") otherwise. `Display` alone gives only
/// "service error" or "dispatch failure".
pub(crate) fn s3_error<E>(error: &SdkError<E>) -> String
where
    E: ProvideErrorMetadata + std::error::Error + Send + Sync + 'static,
{
    let status = error.raw_response().map(|response| response.status().as_u16());
    if let Some(service_error) = error.as_service_error() {
        let code = service_error.code().unwrap_or("S3 error");
        let message = service_error.message().unwrap_or_default();
        return match (status, message.is_empty()) {
            (Some(status), true) => format!("{code} (HTTP {status})"),
            (Some(status), false) => format!("{code} (HTTP {status}): {message}"),
            (None, true) => code.to_string(),
            (None, false) => format!("{code}: {message}"),
        };
    }
    let detail = aws_sdk_s3::error::DisplayErrorContext(error).to_string();
    match status {
        Some(status) => format!("{detail} (HTTP {status})"),
        None => detail,
    }
}
