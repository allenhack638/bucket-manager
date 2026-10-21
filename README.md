# S3Companion

A native macOS S3 browser built with SwiftUI-free AppKit and the AWS SDK for Swift.
It is a from-first-principles reimplementation of the classic S3 Browser / CS Browser
desktop client: a tree of accounts and buckets, a file table, a transfer queue, and
property/permissions/version inspectors.

It is an independent learning project, not affiliated with Netsdk Software.

For the "how and why" behind the code, read **[docs/LEARNING.md](docs/LEARNING.md)**.

## What works

- **Unlimited accounts** — Amazon S3, S3-compatible endpoints (Linode, MinIO, Wasabi,
  Cloudflare R2, Backblaze B2, …), GovCloud, custom region, path-style addressing,
  SSL on/off.
- **Credentials** — access key metadata in Application Support, secrets in the
  **macOS Keychain**. Nothing secret is written to JSON.
- **Account dialogs** — Add/Edit Account and Storage Accounts, with validation,
  Test Connection, adaptive size, and a scrollable form on short screens.
- **Account → bucket → folder tree** with lazy loading. Selecting a bucket lists its
  root; folders load on demand.
- **Object browser** — a clickable breadcrumb (`/ bucket/ folder/ current/`), Name,
  Size, Type, Last Modified, Storage Class; multi-select, per-row checkboxes,
  sortable headers, adaptive columns at small widths.
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
- **Light S3 Browser theme**, Windows-style custom title/menu chrome, extracted
  application icon, accessible controls, keyboard activation, focus rings.
- **Empty states** for no accounts, no bucket, empty folders, a failed bucket load
  (with **Retry**), and an empty queue.

## Quick start

```bash
cd /Users/allen/Documents/Projects/Practise/rea
./make-app.sh
open build/S3Companion.app
```

Or run from the toolchain:

```bash
swift run
```

The first launch auto-opens **Add New Account** if no account exists. Enter:

- Display name (anything)
- Account type (Amazon S3 / S3-compatible / GovCloud)
- Access Key ID and Secret Access Key
- Region (must match the bucket)
- For S3-compatible storage: the endpoint, e.g.
  `https://in-maa-1.linodeobjects.com`, and path-style if the provider requires it.

The secret is stored in the login Keychain under `com.local.s3companion.secret`
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
  `~/Library/Application Support/S3Companion/folder-stats.json` (0600) is loaded
  at launch, so values render immediately with no request. Entries fresher than
  5 minutes are reused silently; older entries stay visible while one background
  refresh runs. Writes invalidate the affected prefix and its ancestors, and the
  cache is flushed on quit.
- Transfers cap at four concurrent requests. Credentials are removed from queue
  memory when a task completes, fails or is cancelled.

Logs are written to:

```
~/Library/Logs/S3Companion/app.log
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘N | New bucket |
| ⌘U / ⇧⌘U | Upload files / folder |
| ⌘D | Download selected |
| ⌘R | Refresh listing |
| ⌘A | Select all |
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
Sources/S3Companion/
  main.swift                 entry point + hidden diagnostic modes
  App/
  UI/
    MainWindowController     window, custom chrome, menus, sheets, shortcuts
    SidebarViewController    account/bucket/folder outline
    BrowserViewController    breadcrumb, file table, actions, status
    TransfersViewController  queue, tabs, inspector, event log
    AddAccountSheet          Add/Edit account + Storage Accounts dialogs
    Components.swift         FlatButton, checkbox, progress, InfoTextView, …
    Chrome.swift             custom title bar + in-app menu bar
    Theme.swift              measured colors, fonts, metrics
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

## The S3 Browser compatibility fix

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
  .build/debug/S3Companion --probe

# Headless dialog/model tests (validation, breadcrumb, folder markers, paths)
.build/debug/S3Companion --uitest

# Full end-to-end suite: real AWS SDK + model + transfers against a local fake S3
./scripts/run-e2e.sh

# Real-account startup check (the first run of a rebuilt bundle may prompt
# once for Keychain access; the log then shows one read plus cache hits)
build/S3Companion.app/Contents/MacOS/S3Companion --verify-startup

# Offscreen UI snapshot, optional tab / empty state / window size
.build/debug/S3Companion --snapshot out.png --size 900x480
.build/debug/S3Companion --snapshot out.png --size 900x480 --tab properties
.build/debug/S3Companion --snapshot out.png --size 900x480 --empty accounts
.build/debug/S3Companion --snapshot log-empty.png --size 1120x650 --tab log --empty log
.build/debug/S3Companion --snapshot out.png --size 900x480 --error "Access denied."
.build/debug/S3Companion --snapshot-sheet add --out add.png --size 640x500
.build/debug/S3Companion --snapshot-sheet accounts --out accounts.png --size 760x460
```

The current suite is 49 dialog/model checks plus 74 end-to-end checks. The E2E
harness in `scripts/fake_s3.py` covers signed `ListBuckets`/`ListObjectsV2`,
folder markers returned in `Contents`, AccessDenied, deliberately delayed
responses, folder creation (`PUT .../name/`), metadata request counts, the 60s
listing cache, parent-coalesced folder scans, nested descendant caching,
persistent cache reload (including a fresh model instance with zero requests),
paginated/cancelled/partial scans, folder-size sorting, 2-scan and 8 req/s
pacing, the global 4-request cap, cross-bucket folder paths, downloads and
uploads.

The snapshot matrix used during development lives in `.commandcode/refs/`.
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
- Some S3 Browser menu commands (ACL editor, bucket policy, lifecycle, CORS, website,
  replication, CloudFront, sync, sharing wizard) are present but disabled.
- Image previews show a placeholder; text/UTF-8 previews render.
- The theme is fixed light, matching the reference; dark mode is not themed.
- Versioning, tags, metadata, and ACLs are read-only.
- Ad-hoc signing means Keychain may re-prompt after each rebuild.
- The window uses native macOS traffic lights at top-left; offscreen snapshot
  images do not include the native titlebar controls.
