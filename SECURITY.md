# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.
Use GitHub's private vulnerability reporting:
https://github.com/allenhack638/bucket-manager/security/advisories/new

Alternatively, email the maintainer listed in the repository profile with:

- the affected version or commit,
- reproduction steps,
- impact, and
- any suggested fix.

Do not include real access keys, secrets, presigned URLs, or bucket contents.

## Credential handling

- Account metadata is stored in Application Support with `0600` permissions.
- Multipart upload state contains upload IDs and ETags, no credentials, and is stored with `0600` permissions.
- The persisted transfer queue contains account UUIDs, bucket/object keys, local paths, progress, and errors, never credentials. It is `0600`; account secrets are resolved from Keychain only when a restored task starts.
- Secret access keys are stored in the macOS Keychain, never in JSON.
- Secrets are read once per account per launch and cached in memory.
- Logs never include secret access keys, authorization headers, signatures,
  presigned query parameters, or Keychain contents.
- Diagnostic logging is off by default. Audit logging is always on for account,
  bucket, object, transfer, and settings changes.
- Log files are JSONL with `0600` permissions inside a `0700` directory. The
  diagnostic and audit streams have independent retention.
- Request counters are aggregated per account/bucket/operation in a `0600` file;
  they contain no credentials or object payloads.
- The app has no telemetry or remote crash reporting.

## Admin passcode gate

- Opening **Logs & Statistics**, opening the **Event Log** inspector tab, exporting
  logs, clearing logs/statistics, and changing logging settings require an admin
  passcode.
- The first protected action creates the passcode; it is stored only as a salted
  100,000-round SHA-256 verifier in the macOS Keychain, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Passcodes are not recoverable. If lost, an administrator can remove the
  `com.bucketmanager.admin` / `passcode` Keychain item to reset the gate; existing
  logs remain readable at the filesystem level.
- The gate is an in-app authorization control, not log encryption. Logs remain
  owner-only (`0600`) on disk.
- Authorization lasts five minutes for entry. The Logs window closes when that
  session expires and locks on close; selecting the Event Log requires unlock.
  An Event Log tab already visible when the session expires stays visible until
  you switch away. Destructive actions and settings changes always prompt again.
- Repeated failed unlocks are delayed after three attempts.
- Passcode creation, successful unlock, failed unlock, and passcode changes are
  audited without recording the passcode.

## Transport and endpoint validation

- HTTPS is the default. Remote plain-HTTP endpoints are rejected; HTTP is
  limited to loopback and private/local-network hosts for MinIO-style setups.
- Endpoint URLs are validated for scheme, host, embedded credentials, query
  strings, and fragments before an S3 client is created.
- ATS does not allow arbitrary loads. `NSAllowsLocalNetworking` is the only
  exception, for local S3-compatible services.
- AWS SDK request logging (`S3C_LOG`) is compiled only into debug builds.

## Build hardening

- Every packaged build, including ad-hoc local builds, is signed with the
  macOS Hardened Runtime.
- Release builds compile out the UI test, E2E, snapshot, probe, startup-verify,
  and self-test entrypoints.
- Dependency versions are pinned exactly in `Package.swift`.

## App Sandbox

The app is not sandboxed. Enabling the sandbox would move Application Support
and preferences into a container and invalidate existing Keychain/account
access, so it requires a deliberate migration and security-scoped bookmark
design. The current direct-distribution model relies on:

- Hardened Runtime and Developer ID signing for release builds.
- `NSOpenPanel`/drag-and-drop for explicit user-selected file access.
- No background helpers, XPC services, custom URL schemes, or Apple Events.
- `0600` account/cache/log files under `0700` app directories.

Sandbox enablement is tracked as a release-engineering prerequisite for any
App Store distribution.

## IPC and URL handling

There are no XPC services, helper processes, custom URL schemes, or Apple Event
handlers in the application bundle.

## Local data

- Account, folder-stat, log, and temporary download files are created with
  user-only permissions.
- Secrets are stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
  are never synchronized to iCloud Keychain.
- No telemetry or remote crash reporting.

## Scope

The app talks directly to the S3 endpoint configured by the user. It does not
operate a backend service.
