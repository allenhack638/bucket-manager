# Bucket Manager

A native macOS client for S3-compatible object storage, built with AppKit and the
AWS SDK for Swift. Bucket Manager gives you an account picker and bucket sidebar, an
object browser, a transfer queue, and property, permissions, tag, version, and
event-log inspectors in one focused desktop app.

Bucket Manager is open source under the MIT License.

For the "how and why" behind the code, read **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## What works

- **Unlimited accounts** — Amazon S3, S3-compatible endpoints (Linode, MinIO, Wasabi,
  Cloudflare R2, Backblaze B2, …), GovCloud, custom region, path-style addressing,
  SSL on/off.
- **Credentials** — access key metadata in Application Support, secrets in the
  **macOS Keychain**. Nothing secret is written to JSON.
- **Account dialogs** — Add/Edit Account and Storage Accounts, with validation,
  Test Connection, adaptive size, and a scrollable form on short screens.
- **Account picker → bucket sidebar → folder browser.** The sidebar lists buckets at
  bucket-level granularity for the active account; opening one browses its folders
  and objects in the right pane. Columns are resizable by dragging header dividers.
- **Object browser** — a clickable breadcrumb (`/ bucket/ folder/ current/`), Name,
  Size, Type, Last Modified, Storage Class; multi-select, per-row checkboxes,
  sortable headers, filter/search, and resizable columns.
- **Folder sizes and dates** — recursive prefix totals shown for every folder row
  in the current listing, with cached/refreshing/partial/unavailable states and
  sorting by the computed values.
- **Operations** — upload files, upload a folder tree, download, open, delete,
  rename (copy + delete), copy/move to another bucket/prefix, cut/copy/paste,
  create folder, new/delete bucket.
- **Transfer queue** — real byte progress for uploads and downloads, speed,
  concurrency cap of 4, running/queued/stopped/failed filters, start/stop/cancel,
  retry, open in Finder.
- **Inspector tabs** — Tasks, Permissions (ACL), Headers, Tags, Properties, Preview,
  Versions, Event Log. Details are loaded on demand so selecting rows does not
  bombard the endpoint.
- **Bookmarks**, **Generate Web URL** (copies a URL to the clipboard), and an
  on-disk **event log**.
- **Appearance** — native macOS **View → Appearance** with System, Light, and Dark
  modes. The custom chrome, tables, inspector, transfer footer, and menus all follow
  the selected appearance.
- **Purpose-built theme** — a restrained palette, native macOS window controls, a
  custom bucket icon, accessible controls, keyboard activation, and visible focus
  states.
- **Empty states** for no accounts, no bucket, empty folders, a failed bucket load
  (with **Retry**), and an empty queue.

## Quick start

```bash
cd /Users/allen/Documents/Projects/Practise/bucket-manager
./make-app.sh
open "build/Bucket Manager.app"
```

Or run from the toolchain:

```bash
swift run
```

Brand assets live in `Assets/AppIcon.svg` and `Assets/AppIcon.icns`; regenerate the
iconset with `swift scripts/make-icon.swift`.

For a distributable build, pass the version and signing identity:

```bash
VERSION=0.2.0 BUILD_NUMBER=42 \
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./make-app.sh release
```

See [docs/RELEASE.md](docs/RELEASE.md) for signing, notarization, and verification.

The first launch auto-opens **Add New Account** if no account exists. Enter:

- Display name (anything)
- Account type (Amazon S3 / S3-compatible / GovCloud)
- Access Key ID and Secret Access Key
- Region (must match the bucket)
- For S3-compatible storage: the endpoint, e.g.
  `https://in-maa-1.linodeobjects.com`, and path-style if the provider requires it.

The secret is stored in the login Keychain under `com.bucketmanager.secret`
(service) / the account UUID (account), marked **accessible when unlocked, this
device only**. It is read **once per account per launch** and cached in memory, so
an operation does not re-prompt. `accounts.json` contains only the account ID,
display name, access key ID, region, endpoint and flags; it is `0600` inside a
`0700` directory. Because development builds are ad-hoc signed, macOS may still
ask for the login Keychain password once after each rebuild; click **Always Allow**.

## Request behavior

The browser is deliberately conservative with an S3 endpoint:

- Listings use 1,000 keys per page and a 60-second per-bucket/prefix cache.
- Changing bucket or folder clears the old rows immediately; a late response from
  the previous listing is discarded instead of overwriting the new view.
- The inspector fetches only the **active tab**, not every metadata type. Fetches
  are debounced 180 ms while moving through rows and cached per object for 60 s.
  In-flight requests are de-duplicated.
- Folder sizes use the only S3-valid method: a recursive `ListObjectsV2` prefix
  scan. Sibling folders are coalesced into **one parent scan**, which also caches
  nested descendant prefixes. All folder rows in the current listing trigger
  one coalesced scan, so scrolling never blanks or re-fetches rows. Navigating
  away cancels the scan. At most **2 scans** run at once, paced to **8 request
  starts per second**, capped at **100,000 objects** with a `≥` partial result.
  Failed/denied scans show `—`.
- Folder stats are **cache-first**: an on-disk cache at
  `~/Library/Application Support/BucketManager/folder-stats.json` (0600) is loaded
  at launch, so values render immediately with no request. Entries fresher than
  5 minutes are reused silently; older entries stay visible while one background
  refresh runs. Writes invalidate the affected prefix and its ancestors, and the
  cache is flushed on quit.
- Transfers cap at four concurrent requests. Credentials are removed from queue
  memory when a task completes, fails or is cancelled.

Logs are written to:

```
~/Library/Logs/BucketManager/app.log
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New bucket |
| ⌘U / ⇧⌘U | Upload files / folder |
| ⌘D | Download selected |
| ⌘R | Refresh listing |
| ⌘A | Select all |
| ⌘F | Filter objects |
| ⌘X / ⌘C / ⌘V | Cut / Copy / Paste objects |
| ⇧⌘C / ⇧⌘X | Copy to / Move to |
| ⇧⌘N | Create folder |
| ⌘I | Properties |
| ⇧⌘V | Versions |
| ⌥⌘N / ⌥⌘M | Add / Manage accounts |
| F2 | Rename |
| Delete | Delete selected |
| Esc | Go to parent folder |
| F5 | Refresh buckets and listing |
| ⇧⌘D | Dump current state to the log |
| ⌃⌘F | Enter full screen |

## Architecture at a glance

```
Sources/BucketManager/
  main.swift                 entry point + hidden diagnostic modes
  UI/
    MainWindowController     window, custom chrome, menus, sheets, shortcuts
    SidebarViewController    account picker + flat bucket list
    BrowserViewController    breadcrumb, file table, actions, status
    TransfersViewController  queue, tabs, inspector, event log
    AddAccountSheet          Add/Edit account + Storage Accounts dialogs
    Components.swift         FlatButton, checkbox, progress, InfoTextView, …
    Chrome.swift             custom title bar + in-app menu bar
    Theme.swift              theme colors, fonts, metrics
  Models/                    Account, S3Item, TransferTask, BrowserNode
  Services/
    S3Service                clients, listing, metadata, transfers, cache
    TransferQueue            queue, concurrency, progress, speed
    ProgressStream           SDK stream wrapper that reports upload bytes
    KeychainStore            secrets
    AccountStore             account JSON + secret lookup
    StripXIDInterceptor     S3-compatible signing fix
    AppLog                  stderr + rotating-friendly file log
  ViewModels/BrowserModel    state, operations, inspector loaders
  SnapshotRunner.swift      offscreen PNG rendering for UI review
  UITest.swift              headless dialog interaction tests
```

## S3-compatible signing fix

Linode (and some other S3-compatible services) returned:

```
403 SignatureDoesNotMatch
```

The AWS CLI worked with the same key. Comparing requests showed the Swift SDK appends
`?x-id=ListBuckets` to every operation, while the CLI does not. Linode computes the
SigV4 canonical request without that SDK-only marker, so the signatures differ.
`StripXIDInterceptor` removes `x-id` in the `modifyBeforeSigning` phase. After that,
`listBuckets` returns all 20 buckets and `ListObjectsV2` returns `AccessDenied` only
for buckets the key is not allowed to list — i.e. the request is now correctly signed.

## Diagnostics and tests

```bash
# Headless signing probe (reads credentials from env, never logs the secret)
S3C_ENDPOINT=... S3C_REGION=... S3C_ACCESS_KEY=... S3C_SECRET=... \
  .build/debug/BucketManager --probe

# Everything: build, headless UI/model checks, then fake-S3 end-to-end checks
./scripts/test.sh

# Headless dialog/model tests (validation, breadcrumb, column resizing, paths)
.build/debug/BucketManager --uitest

# Full end-to-end suite: real AWS SDK + model + transfers against a local fake S3
./scripts/run-e2e.sh

# Real-account startup check (the first run of a rebuilt bundle may prompt
# once for Keychain access; the log then shows one read plus cache hits)
"build/Bucket Manager.app/Contents/MacOS/BucketManager" --verify-startup

# Offscreen UI snapshot, optional tab / empty state / window size
.build/debug/BucketManager --snapshot out.png --size 900x480
S3C_APPEARANCE=dark .build/debug/BucketManager --snapshot dark.png --size 900x480
.build/debug/BucketManager --snapshot out.png --size 900x480 --tab properties
.build/debug/BucketManager --snapshot out.png --size 900x480 --empty accounts
.build/debug/BucketManager --snapshot log-empty.png --size 1120x650 --tab log --empty log
.build/debug/BucketManager --snapshot out.png --size 900x480 --error "Access denied."
.build/debug/BucketManager --snapshot filtered.png --size 900x480 --filter Border
.build/debug/BucketManager --snapshot-sheet add --out add.png --size 640x500
.build/debug/BucketManager --snapshot-sheet accounts --out accounts.png --size 760x460
```

The current suite is 64 dialog/model checks plus 74 end-to-end checks. The E2E
harness in `scripts/fake_s3.py` covers signed `ListBuckets`/`ListObjectsV2`,
folder markers returned in `Contents`, AccessDenied, deliberately delayed
responses, folder creation (`PUT .../name/`), metadata request counts, the 60s
listing cache, parent-coalesced folder scans, nested descendant caching,
persistent cache reload (including a fresh model instance with zero requests),
paginated/cancelled/partial scans, folder-size sorting, 2-scan and 8 req/s
pacing, the global 4-request cap, cross-bucket folder paths, downloads and
uploads.

`S3C_A11Y=1` adds an accessibility audit (missing labels on interactive controls).
`S3C_LOG=1` turns on AWS SDK request logging (debug builds only; signatures and
headers, never the secret).

## Known limits

- Folder sizes are bounded snapshots: they scan up to 100,000 objects for the
  folder rows in the current listing and can be disabled in Options. Cached
  values persist across
  app restarts; external changes become visible after the cache is refreshed or
  invalidated by this app's own writes.
- Large uploads use a single streaming PUT; multipart upload/resume is not implemented.
- Cross-account copy/move is intentionally rejected; copy within one account works.
- Some advanced bucket-management commands (ACL editor, bucket policy, lifecycle, CORS,
  website, replication, CloudFront, sync, sharing wizard) are present but disabled.
- Image previews show a placeholder; text/UTF-8 previews render.
- Versioning, tags, metadata, and ACLs are read-only.
- Ad-hoc signing means Keychain may re-prompt after each rebuild.
- The window uses native macOS traffic lights at top-left; offscreen snapshot
  images do not include the native titlebar controls.

## License

Bucket Manager is released under the MIT License. See [LICENSE](LICENSE).
