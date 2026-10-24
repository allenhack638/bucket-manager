# Cross-account copy and move

## Behavior

Cross-account transfers are available from **Copy to…** and **Move to…** in the
Files menu and the object context menu. Choose the destination account, bucket,
and optional prefix.

- **Copy** leaves the source object in place.
- **Move** copies the object, verifies the destination, then deletes the source.
- A selected folder is expanded recursively and its relative paths are preserved.
- Each object is queued as an individual transfer with progress, pause, cancel,
  retry, and restart-safe persistence.
- The source and destination use separate credentials. Neither secret is written
  to the transfer queue or logs.

## Safety rules

1. The source is downloaded to an owner-only staging file in the system temporary
   directory. Staging paths are registered for orphan cleanup and validated before
   deletion on restore.
2. The destination is uploaded using the destination account.
3. The destination object's size is read back and must match the downloaded byte
   count.
4. A move deletes the source only after verification. If the source's ETag or size
   changed, the move fails and the source is retained.
5. Cancellation during transport leaves the source untouched. Cancellation or
   failure of a multipart destination upload attempts an abort against the
   destination account.
6. Destination keys that already exist are checked and refused before any transfer
   starts. Selected items that collapse to the same destination key are also refused.
   This is a best-effort check; a concurrent writer can race between the check and
   the upload.
7. A source and destination that resolve to the same storage location and key are
   refused, preventing self-move deletion.
8. The source content type and user metadata are carried to the destination.

## Limitations

- The transfer relays bytes through the Mac; it is not a server-side copy. Large
  objects require temporary disk space.
- Copy tasks restart from the beginning after cancellation or app relaunch. They
  do not resume a partially downloaded copy.
- Existing destination objects are rejected by a best-effort preflight check. An
  explicit overwrite/replace policy is tracked in `docs/BACKLOG.md`.
- Same-account folder copies are not supported by the synchronous server-side copy
  path; use cross-account copy or copy the folder contents individually.
- Object tags, ACLs, storage class, encryption settings, object lock settings,
  `Content-Encoding`, `Cache-Control`, `Content-Disposition`, and `Content-Language`
  are not preserved by the relay path. Content type and user metadata are preserved.
- Conflict checks and destination verification run serially before/after each
  transfer; very large folder selections can take time before the queue starts.

## Test coverage

Local E2E tests use two independent fake S3 endpoints so the source and destination
credentials and endpoints are distinct. The cross-account matrix covers:

- small object copy and move
- recursive folder copy
- 17 MiB multipart destination upload
- clipboard paste across accounts
- destination write failure and source retention
- destination verification failure and source retention
- source mutation during copy and source retention
- destination multipart part failure and abort
- cancel during copy and staging-file cleanup
- missing destination credentials
- self-move rejection
- existing-destination and duplicate-destination rejection
- blank destination bucket rejection
- destination content-type preservation
- queue restore of copy metadata and unsafe staging-path rejection
