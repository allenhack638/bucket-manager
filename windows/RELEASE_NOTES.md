# Bucket Manager for Windows 0.1.3

Windows preview with the macOS layout, appearance switching, and a transfer queue with multipart uploads.

## Included

- Tauri 2 desktop app with a React UI and Rust S3 backend.
- Multiple S3 and S3-compatible accounts.
- Secrets stored in Windows Credential Manager.
- Custom endpoints, regions, bucket-scoped credentials, and path-style addressing.
- Bucket browser, folder navigation, upload, download, create folder, and recursive folder delete.
- Paginated object listings.
- The browser now mirrors the macOS layout and proportions: 321 px sidebar, 24 px path bar, 24 px header, 18 px rows, 30 px action bar, 28 px inspector tabs, and 40 px transfer footer.
- Add a persisted **View → Appearance** menu with **System**, **Light**, and **Dark**, matching the macOS appearance behavior.
- Add a persistent transfer queue with live progress, pause/resume/cancel/retry, and a Tasks inspector tab.
- Add multipart uploads above 16 MiB with 8 MiB parts, scoped aborts, and full-size verification.
- Verified 21 MiB multipart upload/download against fake S3 and real MEGA S4 in both test buckets, with byte-identical SHA-256 downloads.

## Known limitations

- This is a preview; it does not yet have cross-account copy/move, the full inspector, logs/statistics, drag and drop, folder upload, or automatic updates.
- Paused/queued transfers restart from the beginning after relaunch.
- The installer is **unsigned**, so Windows SmartScreen may block or warn on first launch. Choose **More info → Run anyway** only if you trust the download.
- No automatic updates.

## Install

Download either:

- `Bucket.Manager_0.1.3_x64-setup.exe` (NSIS)
- `Bucket.Manager_0.1.3_x64_en-US.msi` (MSI)

Run the installer and launch Bucket Manager from the Start menu.

`SHA256SUMS.txt` contains the SHA-256 digest for each installer.

## Build from source

```powershell
cd windows
npm ci --include=dev
npm run tauri build
```
