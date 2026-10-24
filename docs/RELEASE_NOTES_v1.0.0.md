# Bucket Manager 1.0.0

Native macOS S3-compatible storage browser.

## Highlights

- **Cross-account copy and move** between different accounts or buckets, with recursive folder support.
- **Move safety**: the destination is verified before the source is deleted; failures and cancellation keep the source.
- **Clipboard transfers** across accounts with destination-conflict and self-move protection.
- **Large-file support** through multipart destination uploads, with scoped abort and orphan cleanup.
- **Persistent transfer queue** for uploads, downloads, and cross-account copy metadata.
- **Passcode-protected logs and statistics**, request metrics, audit events, and credential redaction.
- **Real-provider acceptance** covers two-bucket copy/move and a 20 MiB cross-account multipart copy.

## Verification

- 171 headless UI/model checks
- 200 fake-S3 E2E checks
- 32 real MEGA S4 acceptance checks, including cross-account copy/move and a 20 MiB multipart copy
- CI verify and release-package jobs green

## Requirements

- macOS 14 Sonoma or later
- Apple silicon Mac for this build; Intel Macs can build from source

## Installation

This build is **ad-hoc signed with Hardened Runtime but not notarized**. macOS
will block the first launch.

1. Open the DMG and copy Bucket Manager to Applications.
2. Try to open it once, then click **Done** on the warning.
3. Open **System Settings → Privacy & Security → Security** and click **Open Anyway**.
4. Confirm **Open**.

Alternatively, remove quarantine only for this app:

```bash
xattr -dr com.apple.quarantine "/Applications/Bucket Manager.app"
open "/Applications/Bucket Manager.app"
```

Do not disable Gatekeeper globally.

## Homebrew

```bash
brew tap allenhack638/bucket-manager
brew install --build-from-source bucket-manager
bucket-manager
```

## Known limitations

- Cross-account transfers relay through temporary disk space.
- Copy tasks restart from the beginning after cancellation or relaunch.
- Destination conflict checks are best effort; concurrent writers can race.
- Some object headers, tags, ACLs, storage class, and encryption settings are not preserved by cross-account relay.
- Temporary credentials/session tokens and presigned share links are deferred to the backlog.
- Bucket administration editors are deferred to the backlog.

## Verify

SHA-256 is attached as `BucketManager-1.0.0-arm64.dmg.sha256`.
