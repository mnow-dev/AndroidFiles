# Changelog

## v0.1.5 — 2026-09-25

- Wireless backups split the files across 8 parallel tar streams, balanced
  by size: about 3.4x faster over Wi-Fi (4.9 → 16.5 MB/s on a Pixel 8).
  Covers full, incremental and clutter-pruned runs; pause, resume and cancel
  reach every stream. USB stays single-stream.
- Fix: clicking **Update** silently did nothing once an update had been
  downloaded but failed to apply. The adb server kept the install folder busy,
  so the swap failed, and every later update attempt then exited without a
  word. The app no longer runs its helpers from the install folder, stops adb
  before updating, and says so when an update fails.
- Upgrading from v0.1.3 or v0.1.4: if **Update** does nothing, close the app,
  run `adb kill-server`, and run the new Setup.exe once.

## v0.1.4 — 2026-07-19

- The "update available" prompt is a dialog with Later/Update and an install
  progress bar
- Re-select the last used device on launch

## v0.1.3 — 2026-07-19

- UI translated into 11 languages
- Destination free space and selection size indicators
- "Verify after backup" option; deep verify shows progress and an ETA
- Onboarding checklist, tree and Settings polish

## v0.1.2 — 2026-07-19

- Fix: the Settings dialog silently failed to open when a drive letter was
  assigned to a not-ready device (an empty card reader, a disconnected
  network or optical drive)
- Show the app version at the bottom of the Settings dialog

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
