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
- Secret access keys are stored in the macOS Keychain, never in JSON.
- Secrets are read once per account per launch and cached in memory.
- Logs never include secret access keys.
- The app has no telemetry or remote crash reporting.

## Scope

The app talks directly to the S3 endpoint configured by the user. It does not
operate a backend service.
