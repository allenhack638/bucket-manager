# Security

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.
Email the maintainer listed in the repository profile with:

- the affected version or commit,
- reproduction steps,
- impact, and
- any suggested fix.

Do not include real access keys, secrets, presigned URLs, or bucket contents.

## Credential handling

- Account metadata is stored in Application Support with `0600` permissions.
- Multipart upload state contains upload IDs and ETags, no credentials, and is stored with `0600` permissions.
- Secret access keys are stored in the macOS Keychain, never in JSON.
- Secrets are read once per account per launch and cached in memory.
- Logs never include secret access keys.
- The app has no telemetry or remote crash reporting.

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
