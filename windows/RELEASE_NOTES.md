# Bucket Manager for Windows 0.2.0

Windows preview: safer transfers, a security fix, account and bucket removal, a date format setting, and Check for Updates.

## What's new

- **Help → Check for Updates…** shows when a newer release is on GitHub, with a Download button. An optional once-a-day check (Help → Check for Updates Automatically) announces each new version once.
- **View → Date Format**: month-first 12-hour, day-first 24-hour, ISO, or your system's format.
- Remove an account from the Edit account dialog, and delete an empty bucket from the sidebar (type its name to confirm).

## Fixes

- Moving a folder no longer deletes files before they are copied; Pause works for downloads, same-named downloads no longer corrupt each other, transfer history survives crashes, and a second launch focuses the running app.
- Object names are cleaned before they reach the Save dialog, so a name shaped like a network path can no longer make Windows contact another server.
- Failed or interrupted multipart uploads are always cleaned up instead of leaving billed parts behind, and files larger than 78 GiB now upload.
- The Logs window can be reopened after closing it, closing the main window quits the app (asking first if transfers are running), errors show the S3 code and message, and AWS buckets in another region open correctly.
- The Tasks list no longer reorders under the cursor, finished uploads only refresh the folder they changed, F5 and Ctrl+R refresh instead of resetting the app, and at most four transfers run at once.
- Downloads carry the Mark-of-the-Web so SmartScreen checks them, and account settings are saved crash-safely.
- A click outside the account or Copy/Move dialog no longer discards what was typed, and Esc closes it.

## Known limitations

- This is a preview; it does not yet have drag and drop or folder upload.
- Paused/queued transfers restart from the beginning after relaunch.
- The installer is **unsigned**, so Windows SmartScreen may block or warn on first launch. Choose **More info → Run anyway** only if you trust the download.
- Updates are not installed automatically: Check for Updates opens the new installer in your browser.

## Install

Download either:

- `Bucket.Manager_0.2.0_x64-setup.exe` (NSIS)
- `Bucket.Manager_0.2.0_x64_en-US.msi` (MSI)

Run the installer and launch Bucket Manager from the Start menu.

`SHA256SUMS.txt` contains the SHA-256 digest for each installer.

## Build from source

```powershell
cd windows
npm ci --include=dev
npm run tauri build
```
