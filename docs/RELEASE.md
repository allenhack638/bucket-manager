# Release Guide

## Prerequisites

- Xcode command line tools with Swift 6.
- A **Developer ID Application** certificate in the login Keychain.
- A notarytool keychain profile:

```bash
xcrun notarytool store-credentials "bucket-manager-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

## Build and sign

```bash
VERSION=0.2.0 BUILD_NUMBER=42 \
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./make-app.sh release
```

The script signs the bundle with the hardened runtime and a secure timestamp,
then runs `codesign --verify --strict`. Local builds use ad-hoc signing with the
same Hardened Runtime when `CODESIGN_IDENTITY` is omitted.

## Notarize

```bash
ditto -c -k --keepParent "build/Bucket Manager.app" "build/BucketManager.zip"
xcrun notarytool submit "build/BucketManager.zip" \
  --keychain-profile "bucket-manager-notary" \
  --wait
xcrun stapler staple "build/Bucket Manager.app"
spctl -a -vv "build/Bucket Manager.app"
```

Distribute the stapled `.app` or a DMG created from it. Keep the version in
`CHANGELOG.md` aligned with `CFBundleShortVersionString`.
