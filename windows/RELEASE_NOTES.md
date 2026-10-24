# Bucket Manager for Windows 0.1.1

Second Windows preview of Bucket Manager, with the macOS layout.

## Included

- Tauri 2 desktop app with a React UI and Rust S3 backend.
- Multiple S3 and S3-compatible accounts.
- Secrets stored in Windows Credential Manager.
- Custom endpoints, regions, bucket-scoped credentials, and path-style addressing.
- Bucket browser, folder navigation, upload, download, create folder, and recursive folder delete.
- Paginated object listings.
- The browser now mirrors the macOS layout and proportions: 321 px sidebar, 24 px path bar, 24 px header, 18 px rows, 30 px action bar, 28 px inspector tabs, and 40 px transfer footer.

## Known limitations

- This is a preview; it does not yet have multipart uploads, resumable transfers, the transfer queue, cross-account copy/move, inspector tabs, logs/statistics, or drag and drop.
- The installer is **unsigned**, so Windows SmartScreen may block or warn on first launch. Choose **More info → Run anyway** only if you trust the download.
- No automatic updates.

## Install

Download either:

- `Bucket.Manager_0.1.1_x64-setup.exe` (NSIS)
- `Bucket.Manager_0.1.1_x64_en-US.msi` (MSI)

Run the installer and launch Bucket Manager from the Start menu.

`SHA256SUMS.txt` contains the SHA-256 digest for each installer.

## Build from source

```powershell
cd windows
npm ci --include=dev
npm run tauri build
```
