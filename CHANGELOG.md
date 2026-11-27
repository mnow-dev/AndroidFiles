# Changelog

## v0.3.0 — 2026-11-27

- **Quick Look file previews (macOS & Windows):** Press `Space`, double-click,
  or click the eye icon on any file in **Device Folders** or **Clean Up Space**
  (Large Files, Duplicates, Review) to inspect it before backing up or deleting:
  - **macOS:** Opens in a separate, freely resizable, Full Screen–capable native
    window powered by Apple's `QLPreviewView` — supporting full interactive video
    playback, multi-page PDFs, HEIC/RAW/JPG/PNG/WebP photos, HTML, Markdown,
    code, audio, and Office files.
  - **Windows:** Floating Fluent lightbox with pan & zoom for images,
    `Rendered | Source` Markdown, `Readable | Source` HTML, `Formatted | Raw`
    JSON, `Ctrl+F` Find, copy, and a **Pop Out** button to open an independent
    resizable preview window.
  - Loads backed-up files instantly from local disk with zero ADB traffic
    (`Local backup` badge), gates large unbacked remote media before saturating
    Wi-Fi, supports `←`/`→` sibling navigation, **Save Copy…**, **Open**, and
    live **`Include in backup`** / **`Select for cleanup`** toggling.
- **Clean Up Space → Apps storage breakdown (macOS & Windows):** Inspect
  per-app storage directly from Android's `dumpsys diskstats` without root,
  split into **Static APK**, **App Data**, and **Reclaimable Cache**. Includes
  one-click safe **Trim All Caches** (`pm trim-caches`), User/All app filter,
  search & sort, plus per-app **Open App Info on Phone**, **Clear Data**, and
  **Uninstall** (for user-installed apps).
- **Live Wi-Fi band & link speed indicator:** Shows the connected phone's active
  Wi-Fi band and Tx link speed right in the sidebar (`5 GHz · 866 Mbps` in
  green, or `2.4 GHz · 52 Mbps` in amber with a tooltip when 2.4 GHz is capping
  transfer speed).
- **Live backup status updates & zero-flash folder verification:** Files and
  parent folders in **Device Folders** now flip to `Backed up` / `Partial` live
  as files finish copying (and after Snapshot finalization), and nested backed-up
  subfolders (like `DCIM/Camera`) stay on a loading spinner while verifying so
  folders never flash `Backed up` before settling on `Partial`.
- **macOS Wireless Debugging reliability:** Added `NSLocalNetworkUsageDescription`
  and `NSBonjourServices` (`_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`) to
  `Info.plist`, plus automatic `adb kill-server` recovery when a stale daemon
  returns `protocol fault` or `No route to host` during pair/connect.
- **Refined default window sizes** on macOS (`1080×680` main, `1160×800` Quick
  Look) and Windows (`1080×700`).

## v0.2.0 — 2026-11-27

- **Native macOS support & DMG releases:** Dedicated 3-pane Finder & Inspector
  macOS UI with native menu bar shortcuts (`⌘1`/`⌘2`, `⌘B`, `⌘O`, `⌘S`, `⌘R`,
  `⌘⇧W`, `⌘,`), APFS/HFS+ hardlinked snapshots, `launchd` daily scheduling,
  Finder drag-and-drop restore, native Bonjour (`dns-sd`) wireless discovery,
  keep-awake during transfers, and unplugged `/Volumes` drive protection.
  Packaged macOS `.dmg` builds are now published alongside Windows releases.
- **Clean Up Space (Windows & macOS):** New workspace to analyze phone storage,
  inspect largest folders & files, find exact byte-identical MD5 duplicates
  (two-stage size filter + batched device MD5), and act on smart proposals
  (DCIM videos only, customizable 1/3/6/12-month retention windows, downloads,
  messenger media, regenerable caches). Includes **Back up first + verify MD5**
  before deleting any file from the phone.
- **External microSD card support (#1):** Automatically discovers mounted
  external microSD / USB storage volumes (`/storage/<UUID>`) alongside internal
  `/sdcard`. Switch volumes in the sidebar (macOS) or context bar (Windows),
  mount the active volume as a Windows Explorer drive (`AdbDrive --root`),
  save per-volume profiles, and keep external card backups cleanly separated in
  `SD-<UUID>/` subfolders.
- **Redesigned Windows 11 Fluent UI:** New Mica navigation sidebar (Workspace,
  Device, Profiles, and a pinned **Explorer Drive (`P:\`)** toggle card),
  context top bar, and 3-Bento-card layout (Device Folders, Backup Destination
  with disk-capacity bar, and Transfer Queue) in Light and Dark themes.
- **Folder Modified & Backup Status columns (Windows & macOS):** Instant
  local-disk badges (`Backed up`, `Partial`, `Modified`, `Not backed up`) and
  human-friendly `Last Modified` dates right in the folder tree, with zero
  extra ADB round-trips.
- **New app icon** across macOS (`AppIcon.appiconset`), Windows (`app_icon.ico`),
  and the website (`favicon.ico`).
- **Reliability fixes:**
  - Deduplicate dual-stack IPv4/IPv6 and `_adb-tls-connect._tcp` wireless
    transports using `ro.serialno` so the same phone never appears twice.
  - Cancel and terminate all active `adb` tar/push child processes cleanly on
    app exit so no orphaned streams linger in the background.
  - Persist backup destination immediately when chosen, preserve active
    destination when applying a profile saved without one, serialize atomic
    `settings.json` writes, and show a live activity spinner in the sidebar
    while backups or space scans are running.

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
