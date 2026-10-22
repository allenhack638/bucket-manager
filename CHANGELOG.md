# Changelog

## Unreleased

- Add multipart uploads above 16 MiB with 8 MiB parts, four concurrent parts, pause/resume, retry from completed parts, abort-on-cancel, and changed-file invalidation.
- Persist multipart part state in an owner-only JSON file and resume after re-adding the same file/key.
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
- Enable Hardened Runtime for all packaged builds and strip diagnostics from release binaries.
- Remove the obsolete account-tree model, unused theme tokens, and unused UI helpers.
- Add a real S3-protocol acceptance harness with automatic test data cleanup.
- Send small uploads with an explicit Content-Length for stricter S3-compatible servers.
- Fix custom endpoint and path-style controls staying hidden when editing S3-compatible accounts.
- Add regression coverage for account edit, endpoint changes, type switching, update, and removal.
- Support bucket-scoped credentials by letting accounts specify one bucket and skip ListBuckets.
- Test Connection checks the configured bucket directly for bucket-scoped accounts.
