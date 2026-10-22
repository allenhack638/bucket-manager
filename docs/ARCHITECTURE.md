# Architecture and S3 notes

This document explains what the application does, why the code is shaped the way it
is, and how to reason about S3 when something goes wrong. It is intended as a
maintainer and contributor reference.

---

## 1. The mental model

S3 is an object store, not a file system. Four ideas explain almost everything:

1. **Account** — an access key ID + secret access key. The secret signs every HTTP
   request. The account owns buckets.
2. **Bucket** — a globally unique container. A bucket has a region, a policy, and
   optionally versioning. Buckets do not nest.
3. **Object** — a byte blob plus metadata, addressed by a **key** (a string).
   `photos/2026/IMG_7089.JPG` is a single key; it is **not** a file in a folder.
4. **Prefix** — any leading substring of keys. The UI draws folders because it asks
   S3 to group keys by the next `/` after the current prefix. There are no real
   folders to create or rename; "Create folder" writes a zero-byte object whose key
   ends in `/`.

Two consequences that surprise newcomers:

- Renaming an object is a **copy to a new key + delete the old key**. The app does
  exactly that and labels the operation honestly.
- Listing `photos/` does not read every object under `photos/`. With a delimiter,
  S3 returns just the immediate child prefixes and objects. This is what keeps the
  app fast on buckets with millions of keys.

---

## 2. The anatomy of an S3 request

Every request is an HTTP request signed with **AWS Signature Version 4**:

```
GET https://in-maa-1.linodeobjects.com/?list-type=2&prefix=photos/&delimiter=/
Host: in-maa-1.linodeobjects.com
x-amz-date: 20261020T182545Z
x-amz-content-sha256: e3b0c442...  (SHA-256 of the body; empty body for GET)
Authorization: AWS4-HMAC-SHA256
  Credential=ACCESS_KEY/20261020/in-maa-1/s3/aws4_request,
  SignedHeaders=host;x-amz-content-sha256;x-amz-date,
  Signature=...
```

Roughly, the client:

1. Canonicalizes the method, path, query, headers, and payload hash.
2. Builds a string to sign from that canonical request.
3. Derives a signing key from the secret, date, region, and service.
4. Sends the resulting signature in `Authorization`.

The server repeats the computation. If any byte differs — a header the server did
not include, a query parameter it ignored, a wrong region, a wrong secret — it
returns:

```
403 SignatureDoesNotMatch
```

### The bug this project hit

The AWS CLI worked, but the Swift SDK did not:

```
403 SignatureDoesNotMatch
endpoint https://in-maa-1.linodeobjects.com
region   in-maa-1
```

Capturing both requests showed the difference:

- AWS CLI: `GET https://in-maa-1.linodeobjects.com/`
- Swift SDK: `GET https://in-maa-1.linodeobjects.com/?x-id=ListBuckets`

The SDK adds `x-id=<Operation>` during serialization. AWS accepts it; Linode's
signature verification did not include it. The fix is not to change the secret or
the region. It is to remove the parameter **before signing**:

```swift
// Services/StripXIDInterceptor.swift
func modifyBeforeSigning(context: some MutableRequest<InputType, RequestType>) async throws {
    guard let request = context.getRequest() as? HTTPRequest,
          let items = request.queryItems,
          items.contains(where: { $0.name == "x-id" }) else { return }
    let filtered = items.filter { $0.name != "x-id" }
    context.updateRequest(updated: request.toBuilder().replacingQueryItems(filtered).build() as! RequestType)
}
```

This is registered only for S3-compatible accounts. The diagnostic probe
(`--probe`) proves the result: `listBuckets` returns all 20 buckets.

**Lesson:** for S3-compatible providers, always compare the exact signed request,
not just the credentials. A valid key can still produce `SignatureDoesNotMatch`
because the client and server disagree about what was signed.

---

## 3. Listing a folder (ListObjectsV2)

The browser calls:

```
ListObjectsV2(bucket, prefix, delimiter: "/", maxKeys: 1000, continuationToken: ...)
```

The response contains:

- `Contents` — objects directly under the prefix.
- `CommonPrefixes` — the next level of "folders" (e.g. `photos/2026/`).
- `IsTruncated` + `NextContinuationToken` — more pages.

The app:

- requests **1,000 keys per page**;
- shows a **Load more…** button instead of fetching everything;
- caches the first page for **60 seconds** per account+bucket+prefix;
- stores clients per account so TLS connections are reused;
- serializes requests through a **concurrency cap of 4** so bulk work never floods
  the endpoint.

The tree uses the same call but keeps only `CommonPrefixes`, so expanding a bucket
loads one level of folders, not the contents of the whole bucket.

### Folder sizes

There is no S3 API that returns a folder's size. Folder rows are prefixes, not
directories, and the zero-byte marker only says the prefix exists. To show a
total, a client must recursively list every key under the prefix and sum `Size`.
The subsystem does that with **one coalesced parent scan**, not one scan per
folder:

- All sibling folders in the current listing are grouped. A single
  `ListObjectsV2(prefix: parent)`
  with **no delimiter** walks the keys once and aggregates totals for every
  child and nested descendant prefix.
- The same scan takes the newest `LastModified` among objects, so folder dates
  are content dates rather than marker dates.
- At most **2 scans** run at once; request starts are paced at **8 per second**.
  The global 4-request limiter still applies.
- Results are written to a persistent cache at
  `~/Library/Application Support/BucketManager/folder-stats.json` (0600). On
  restart the cache is loaded synchronously, so cached values render before any
  request. Fresh entries (5 minutes) are reused; stale entries stay visible while
  one refresh runs.
- Writes invalidate the changed prefix and its ancestors, not the whole bucket.
  Navigation cancels the scan; scrolling does not alter the active set, so rows
  keep their cached/loading state instead of blanking.
- The scan stops at 100,000 objects and shows `≥ size` as a partial result.
  AccessDenied becomes `—`, not a zero-byte lie.

`Calculate folder sizes in the background` can be turned off in Options.

### Why the UI feels fast

- `NSTableView` is virtualized: it asks for the visible rows only.
- Folders are lazy: no network until the user expands or selects.
- Re-opening a folder hits the 60-second listing cache; the explicit Refresh
  button bypasses it and invalidates the cache.
- Folder statistics are cache-first and persisted, so restarting the app does not
  re-scan already-known folders.
- Selecting a row does **not** fetch metadata. Inspector tabs fetch details on demand.
  One selection would otherwise cost HeadObject + Tags + ACL + Versions.

---

## 4. Transfers: where progress really comes from

A progress bar is only honest if it reports bytes that the network layer actually
consumed.

### Downloads

`GetObject` returns a `ByteStream`. For a stream body, the app reads **256 KiB
chunks** in a loop, writes them to a temporary owner-only file, and calls the
progress closure with the running total. Cancellation is checked between chunks.
The final destination is replaced only after the received length succeeds.

### Uploads

Files up to 16 MiB use one explicit-length `PutObject`. Larger files use
multipart upload with 8 MiB parts and four concurrent part requests. Completed
part ETags are written to `MultipartUploadStore` after each batch, so a paused,
failed, or restarted upload can continue without re-sending completed parts.
The state file is owner-only and contains no credentials. Cancel aborts the
server-side upload; retry reuses the upload ID; a changed file invalidates and
aborts the old session. `TransferQueueStore` persists active queue tasks in an
owner-only JSON file without secrets; running/queued tasks restore paused, failed
tasks keep their error, downloads restart from the beginning, and missing or
changed upload sources are marked failed. The account is resolved from
`AccountStore` when a restored task starts.

### The queue

`TransferQueue` is `@MainActor`, owns `[TransferTask]`, and starts at most four
worker `Task`s. Each task has:

- direction (upload/download)
- bucket, key, local URL
- total size, bytes done, speed
- status: queued → running → completed / failed / stopped / canceled

Progress callbacks are hopped to the main actor and UI updates are throttled to
about 10 per second. Speed is an exponentially smoothed bytes/second value.
Active tasks are persisted to `transfer-queue.json` (0600, no secrets) at most
once every 400 ms and on quit. Relaunch restores queued/running tasks as paused
and failed tasks as failed; uploads whose source is missing, resized, or has a
different modification time are marked failed. Restored tasks resolve their
account and Keychain secret only when started. Downloads restart from the
beginning rather than using byte ranges and stream into a 0600 temporary file;
the destination is replaced only after the received length is verified, so a
failed/canceled download leaves any existing destination untouched.

---

## 5. Accounts, secrets, and the Keychain

Account metadata is JSON in:

```
~/Library/Application Support/BucketManager/accounts.json
```

It contains display name, access key ID, kind, region, endpoint, path-style/SSL
flags, and a UUID. The **secret never goes in this file**. It is a generic password
in the login Keychain:

```
service: com.bucketmanager.secret
account: <account UUID>
```

Why split?

- JSON is easy to inspect and back up; a secret is not.
- The Keychain is protected by the login password and the app's code signature.
- Deleting an account removes both records.

`AccountStore` caches the secret in memory for the lifetime of the process, keyed by
account UUID. Before that cache existed, every operation (listing, metadata, upload,
download) called `secret(for:)` and therefore `SecItemCopyMatching` again, which could
prompt repeatedly. Now there is one Keychain read per account per launch.

Why macOS still asks for the login password after a rebuild: development builds are
**ad-hoc signed**, so every build is a different app identity from the Keychain's
point of view. Click **Always Allow**. A stable Developer ID signature (or a stable
self-signed identity) would remove that once-per-build prompt. The app never stores
the secret in its JSON, UserDefaults, logs, or error messages.

An account can be AWS, S3-compatible, or GovCloud. For compatible accounts the
endpoint is required and can be path-style (`https://host/bucket/key`) or
virtual-hosted (`https://bucket.host/key`). The `x-id` interceptor is enabled for
these accounts.

---

## 6. Versions, ETags, storage classes, metadata

- **ETag** is usually the MD5 of the object (not for multipart uploads). It is an
  integrity hint, not a security guarantee.
- **Storage class** (`STANDARD`, `STANDARD_IA`, `GLACIER_IR`, …) affects cost and
  retrieval latency. The column is read-only here.
- **Versioning** keeps every PUT as a new version. `ListObjectVersions` is shown in
  the Versions tab; delete markers are labeled. The app does not delete versions.
- **Metadata** is the `x-amz-meta-*` map. The Headers tab shows both HTTP headers and
  user metadata. Tags are separate (`GetObjectTagging`), and ACL grants are separate
  (`GetObjectAcl`).
- **Permissions** may be disabled by bucket-owner-enforced ownership; the UI shows a
  clear empty message instead of pretending an ACL exists.

---

## 7. Data flow in the app

```
User action
   │
   ▼
BrowserViewController / Sidebar / Transfers
   │  (AppKit, main actor)
   ▼
BrowserModel
   │  state: accounts, tree, bucket, prefix, items, selection,
   │         details, versions, acl, transfers
   ▼
S3Service (actor)                    TransferQueue (@MainActor)
   │  S3Client per account               │  max 4 concurrent Tasks
   │  throttle(4), 60s cache             │  status/progress/speed
   ▼                                     ▼
AWS SDK for Swift → HTTPS → S3 endpoint
```

- Views never call the SDK directly.
- The model owns user intent and friendly errors.
- `S3Service` is the only place that knows about clients, endpoints, and signatures.
- `TransferQueue` is the only place that knows about scheduling concurrent work.

### File map

| File | Responsibility |
| --- | --- |
| `UI/MainWindowController.swift` | window, custom chrome, menus, sheets, shortcuts |
| `UI/SidebarViewController.swift` | account picker + flat bucket list; bucket selection drives the right pane |
| `UI/BrowserViewController.swift` | path bar, file table, action bar, status |
| `UI/TransfersViewController.swift` | queue, tabs, inspector, event log |
| `UI/LogsWindowController.swift` | Logs, Statistics, and logging settings |
| `UI/AddAccountSheet.swift` | Add/Edit account + Storage Accounts |
| `ViewModels/BrowserModel.swift` | state and operations |
| `Services/S3Service.swift` | clients, list, head, tags, ACL, versions, transfers |
| `Services/S3ErrorPresenter.swift` | one user-facing mapping for S3 and credential errors |
| `Services/TransferQueue.swift` | queueing, progress, speed, cancel |
| `Models/S3Key.swift` | shared object-key parent/safe-filename helpers |
| `Models/MultipartUploadRecord.swift` | persisted multipart session and part state |
| `Models/LogRecord.swift` | log levels, categories, records, and settings |
| `Services/MultipartUploadStore.swift` | owner-only JSON store for resumable parts |
| `Services/TransferQueueStore.swift` | owner-only persisted queue tasks, no credentials |
| `Services/LogStore.swift` | JSONL diagnostics/audit, redaction, rotation, retention |
| `Services/RequestMetricsStore.swift` | per-account/bucket/operation counters |
| `Services/AdminPasscode.swift` | Keychain verifier, authorization session, passcode prompts |
| `Services/RateLimiter.swift` | paced folder-size request starts |
| `FolderStats/FolderStats.swift` | key/record/snapshot/policy types |
| `FolderStats/FolderStatsCache.swift` | synchronous 0600 disk cache |
| `FolderStats/FolderStatsScanner.swift` | parent-coalesced recursive scans |
| `FolderStats/FolderStatsCoordinator.swift` | visible keys, cache-first refresh, cancellation |
| `Services/StripXIDInterceptor.swift` | S3-compatible signing fix |
| `Services/AccountStore.swift` | JSON metadata + Keychain lookup |
| `Services/KeychainStore.swift` | Keychain primitives |
| `UI/Theme.swift` | theme palette and metrics |
| `UI/Components.swift` | custom controls, header, progress, text view |

---

## 8. Layout metrics

The app uses a compact desktop object-browser layout:

- Window: **1120 × 650** logical points; minimum **900 × 480**.
- Title bar: **30 pt**; in-app menu bar: **20 pt**.
- Sidebar: **321 pt** (resizable from 240–620 pt).
- Folder rows: **16 pt**; file/transfer rows: **18 pt**.
- File columns: checkbox 24, Name flexible, Size 90, Type 135, Last Modified 168,
  Storage Class 130.
- Colors: background `#FFFFFF`, chrome `#F0F0F0`, sidebar `#FDFDFD`, selection
  `#0078D4`, progress `#0F7B0F`, borders `#E5E5E5`.

Responsive behavior:

- < 720 pt file pane: hide Storage Class.
- < 640 pt: also hide Type.
- < 480 pt: also hide Last Modified.
- < 680 pt transfer footer: hide the summary; filters and actions remain.
- < 340 pt sidebar: hide "Add external bucket".
- The sidebar is constrained so the transfer tabs always fit.
- Both dialogs adapt to the parent window and scroll their forms.

The app is light-only, so it forces `NSAppearance.aqua`. Native controls
(text fields, tables, checkboxes) otherwise render dark on a dark-mode Mac and become
invisible on the custom light chrome.

---

## 9. Accessibility and keyboard

- Every custom button has a role, a label, keyboard activation (Space/Return), and a
  focus ring; icon-only buttons have human-readable accessibility titles.
- Checkboxes expose `AXCheckBox`, their selected value, and Space activation.
- Progress bars expose `AXProgressIndicator` and a percentage.
- Tables, outlines, and text views are standard AppKit controls with labels.
- The Add Account fields are associated with accessibility labels and support
  Return-to-save and Escape-to-cancel.
- The window controls (close/minimize/full screen) have labels.
- The menu bar is fully keyboard reachable through the native menu and the in-app
  menu bar; the main file table receives focus on launch.
- Run the audit with `S3C_A11Y=1 --snapshot ...`; it prints interactive views that
  lack an accessible label.

---

## 10. Error playbook

Read the JSONL files under `~/Library/Logs/BucketManager/` first, or open
**Tools → Logs & Statistics**. Diagnostic logging is opt-in; audit records are always
written. Records include account names, endpoint hosts (no credentials), operation,
bucket/key, outcome, duration, and redacted error text. The Event Log tab shows the
in-memory user-facing history.

| Error | Usual meaning | What to do |
| --- | --- | --- |
| `SignatureDoesNotMatch` | Client/server disagree about the signed request, or the secret/region is wrong | Compare the exact request (SDK vs AWS CLI). This app strips `x-id` for compatible providers. Verify the secret and region. |
| `InvalidAccessKeyId` | Key does not exist or was revoked | Re-enter the access key. |
| `AccessDenied` | Key is valid but not authorized for this bucket/operation | Check the bucket policy/IAM permissions. Signing is fine. |
| `NoSuchBucket` / `NoSuchKey` | Wrong name or object was deleted | Refresh. S3 keys are case-sensitive. |
| `RULESET_EXHAUSTED` | Custom endpoint failed SDK endpoint resolution | Include `https://` and check the host/region. |
| `Keychain error -128` / "User canceled" | Keychain access was denied | Click **Always Allow** when macOS asks, or re-enter the secret. |
| `-25300` / item not found | Secret was deleted or the account was imported without it | Re-enter the secret in Manage Accounts. |

If the Keychain prompt itself is the problem, note that after a rebuild the app's
ad-hoc signature changes; macOS treats it as a different app. The secret is still
there.

---

## 11. Diagnostics and tests in this repo

```bash
# 1. Compile
swift build

# 2. Exercise the endpoint resolver with dummy credentials
.build/debug/BucketManager --selftest

# 3. Prove signing against a real endpoint without the GUI.
#    The secret is read from the environment and never logged.
S3C_ENDPOINT=https://… S3C_REGION=… S3C_ACCESS_KEY=… S3C_SECRET=… \
  .build/debug/BucketManager --probe
#    Add S3C_BUCKET=… to also run ListObjectsV2.

# 4. Headless interaction tests (validation, save, cancel, storage list)
.build/debug/BucketManager --uitest

# 5. Render the UI offscreen for visual review
.build/debug/BucketManager --snapshot /tmp/main.png --size 900x480
.build/debug/BucketManager --snapshot /tmp/props.png --size 900x480 --tab properties
.build/debug/BucketManager --snapshot /tmp/empty.png --size 900x480 --empty accounts
.build/debug/BucketManager --snapshot-sheet add --out /tmp/add.png --size 520x420
```

Offscreen rendering is used because macOS screen recording permission is not
required: the app draws its own view hierarchy into a bitmap. This makes it
possible to review every tab, empty state, and dialog at multiple sizes without a
human taking screenshots.

---

## 12. Exercises

1. Implement the **bucket policy / CORS / lifecycle** editors as JSON text editors.
2. Implement **version deletion** and **restore** in the Versions tab.
3. Replace the ad-hoc signature with a Developer ID or stable self-signed identity
   and verify the Keychain stops re-prompting across rebuilds.
4. Add a UI test that focuses the Add Account name field, types, presses Return, and
   asserts the sheet closed — using the accessibility API.

The code is deliberately small and direct: the goal is that each file can be read
top-to-bottom and connected back to an S3 concept.
