# Changelog

## v0.1.1 — 2026-07-19

Maintenance release: validates the in-place Velopack updater end to end
(download, apply, relaunch). No user-facing feature changes.

## v0.1.0 — 2026-07-17

First release.

- Tar-streamed backups over ADB with progress, speed, ETA, pause/resume
- Incremental mode (size+mtime manifest diff, changed files only)
- Mirror and Snapshot layouts; snapshots hardlink unchanged files
- File-count verification per run; optional md5 deep verify
- Native tar extraction (correct UTF-8 filenames, exact mtimes, path
  traversal protection); cancel never leaves partial files
- Profiles, daily scheduling via Task Scheduler, completion toasts
- Drag-in restore (push files back to the phone)
- Explorer drive (WinFsp, read-only by default, opt-in writable mode)
- Wireless: QR pairing, auto-reconnect of known devices
- adb auto-download when missing
- Fluent (Windows 11) UI, light/dark/system theme
