# Changelog

## Windows preview 0.1.0 — 2026-10-24

- Add a Windows Tauri 2 application in `windows/` with a React UI and Rust S3 backend.
- Support multiple accounts, Windows Credential Manager secrets, custom endpoints, regions, bucket-scoped credentials, and path-style addressing.
- Add bucket and folder browsing, paginated listings, upload, download, create folder, and recursive folder delete.
- Add Windows CI and a `windows-v*` release workflow for NSIS and MSI installers.
- Document that multipart transfers, the transfer queue, cross-account copy/move, inspector tabs, logs/statistics, and drag and drop remain future parity work.

## 1.0.0 — 2026-10-24

- Add queued cross-account copy and move with a destination account/bucket picker.
- Expand selected folders recursively and preserve relative paths.
- Preserve content type and user metadata through the relay path.
- Verify the destination size before deleting a move source; keep the source on verification, transport, cancellation, or source-mutation failures.
- Refuse self-moves, duplicate destination keys, and existing destination objects with a best-effort preflight check.
- Add cross-account clipboard paste with the same conflict and self-move protections.
- Scope multipart aborts to the copy's own destination upload and reclaim paused copy uploads during orphan cleanup.
- Persist copy metadata across relaunch and register copy staging files for orphan cleanup.
- Add a second fake S3 endpoint and exhaustive cross-account E2E coverage for copy, move, folders, clipboard, failures, cancellation, multipart aborts, and credential redaction.
- Extend real-provider acceptance with two-bucket copy/move and a 20 MiB cross-account multipart copy.
- Remove disabled bucket-administration menu placeholders and track them in `docs/BACKLOG.md`.
- Document cross-account behavior, safety rules, limitations, and test coverage.

## 0.2.1 — 2026-10-23

- Add light and dark README screenshots for the browser, Logs & Statistics, and edit-account sheet.
- Correct macOS Gatekeeper instructions for current macOS: use Privacy & Security → Open Anyway or remove quarantine for this app.
- Make the release SHA-256 file portable by recording only the DMG filename.
- Publish the open-source release workflow and source-build distribution guidance.

## 0.2.0 — 2026-10-23

- **Crash-orphan cleanup**: startup removes stale download temp files and queue-state temp files, and aborts multipart state that has no matching transfer task.

- Add multipart uploads above 16 MiB with 8 MiB parts, four concurrent parts, pause/resume, retry from completed parts, abort-on-cancel, and changed-file invalidation.
- Persist multipart part state in an owner-only JSON file and resume after re-adding the same file/key.
- Persist the transfer queue across relaunch; restore paused/failed tasks, validate source size and modification time, and resolve account credentials only when resuming.
- Harden queue persistence with atomic 0600 writes, partial-record recovery with a corrupt backup, automatic debounced saves, refreshed credentials on every start, and reentrant-pump/concurrency guards.
- Download into a temporary 0600 file, verify the received length, and atomically replace the destination only on success; partial downloads resume with Range/ETag validation and cancellation removes only the temporary file.
- Report and persist multipart progress per completed part instead of waiting for a whole batch.
- Harden after independent review: pump no longer strands queued tasks after synchronous start failures, throttle slots are handed off without over-admission, cancellation is recognized after SDK errors, credentials are dropped on stopped/failed transfers, multipart source fingerprints are rechecked before batches and completion, queue-state recovery is audited, and failed log exports are reported instead of audited as success.
- Move buckets into a flat sidebar list with an account picker.
- Keep folder and object navigation exclusively in the right pane.
- Add draggable column dividers.
- Normalize icon sizes and align the app icon with the macOS icon grid.
- Add CI, Dependabot, and a unified local verification script.
- Remove compiler and concurrency warnings from the app target.
- Bound the S3 listing cache and reduce formatter allocations.
- Parallelize bulk delete/copy while respecting the global request throttle.
- Limit destructive keyboard shortcuts to the object table.
- Implement the object filter/search control with ⌘F and filtered empty states.
- Restore the full keyboard shortcut set for the custom in-window menu bar.
- Accept files and folders dropped from Finder as uploads.
- Render image previews instead of showing an image placeholder.
- Download and delete selected folders recursively, preserving nested paths and invalidating caches.
- Validate S3-compatible endpoints; require HTTPS for remote hosts.
- Enable Hardened Runtime for all packaged builds and exclude debug harnesses/diagnostic env overrides from release builds via conditional compilation.
- Remove the obsolete account-tree model, unused theme tokens, and unused UI helpers.
- Add a real S3-protocol acceptance harness with automatic test data cleanup.
- Send small uploads with an explicit Content-Length for stricter S3-compatible servers.
- Fix custom endpoint and path-style controls staying hidden when editing S3-compatible accounts.
- Add regression coverage for account edit, endpoint changes, type switching, update, and removal.
- Support bucket-scoped credentials by letting accounts specify one bucket and skip ListBuckets.
- Test Connection checks the configured bucket directly for bucket-scoped accounts.
- Add structured JSONL diagnostic and audit logging with levels, categories, filtering, live tail, redacted export, and owner-only retention.
- Add always-on audit events for accounts, buckets, objects, transfers, folders, settings, and app lifecycle.
- Add per-account/bucket/operation request counters with session and all-time statistics.
- Add a Logs & Statistics window with logging settings; diagnostic logging defaults off.
- Instrument every S3 request with duration, bytes, outcome, and redacted error context without logging credentials, authorization headers, or signatures.
- Add a Keychain-backed admin passcode gate for logs/statistics, the Event Log inspector, export, clearing, and logging settings; destructive actions require a fresh prompt.
- Add passcode creation and change flows, five-minute authorization sessions, and audited unlock failures.
- Do not cache failed object-tag loads; ACL, version, and preview data remain deliberately uncached.
