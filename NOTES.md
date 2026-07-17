# AndroidFiles — fast ADB-based Android backup for Windows

## Goal

A Windows desktop app (Flutter) that backs up folders from an Android phone
connected over USB — **fast and reliably**, replacing MTP/Explorer copying.
Long-term: a companion virtual drive so the phone appears in Explorer.

## Why not MTP

MTP transfers file-by-file with per-file protocol round-trips, stalls on large
trees, and aborts whole copies on a single error. ADB can stream an entire
folder as **one continuous tar stream** (`adb exec-out tar -c`), which
saturates USB and is immune to per-file overhead.

## Core design (Phase 1 — the app)

- **Transport:** `adb` CLI (bundled path: `D:\Dev\tools\platform-tools\adb.exe`,
  configurable in settings). No root required; accesses shared storage
  (`/sdcard`) like MTP does.
- **Browse:** parse `adb exec-out toybox ls -llA <path>` (toybox output is
  stable on Android 6+). Lazy-load directories in a tree view.
- **Backup engine:** per selected folder, run
  `adb exec-out tar -cf - -C <parent> <name>` and pipe stdout into Windows'
  built-in `tar.exe` (bsdtar, ships with Win10+) extracting into the
  destination. One stream per folder, queued sequentially (USB is the
  bottleneck; parallelism doesn't help).
- **Fallback:** if device toybox lacks `tar`, fall back to `adb pull` (still
  much better than MTP).
- **Progress:** pre-compute folder size with `du -sk`, count bytes flowing
  through the pipe → per-folder progress bar + MB/s.
- **Verification:** after transfer, compare file count + total bytes
  (device `find -type f | wc -l` / `du` vs. local walk). Optional deep verify
  via `md5sum` sampling later (see backlog).
- **Reliability:** retries per folder, resumable queue, log pane, never
  aborts the whole queue on one bad file (tar keeps going; errors are
  collected and reported).

## UI sketch

```
┌────────────────────────────────────────────────────────┐
│ Device: Pixel 8 (ABC123)  ▼        [Settings]          │
├──────────────────────┬─────────────────────────────────┤
│ Phone tree (checkbox │ Backup queue                    │
│ per folder, lazy)    │  DCIM/Camera  ████████░░ 82%    │
│  ☐ DCIM              │  38.1 MB/s · 4.2/5.1 GB         │
│  ☑ DCIM/Camera       │  WhatsApp     queued            │
│  ☐ Download          │  ─────────────────────────────  │
│  ☑ WhatsApp          │  Destination: D:\Backups\Pixel  │
│                      │  [Start backup]  [Verify]       │
├──────────────────────┴─────────────────────────────────┤
│ Log: pulled 12,410 files, 0 errors                     │
└────────────────────────────────────────────────────────┘
```

## Explorer / drag-and-drop interop (researched 2026-07-17)

- **Explorer → app (drop in):** fully supported via `desktop_drop` package —
  files and folders. Use for: choosing destination folder, and later for
  *restore/push to phone*.
- **App → Explorer (drag out):** supported on Windows via
  `super_drag_and_drop`. Two modes:
  - *Real files* — must already exist locally; trivial.
  - *Virtual files* — content is produced at drop time (Windows
    `FILEGROUPDESCRIPTOR`/`FILECONTENTS`), so we can pull from the phone
    on-demand when the user drops. Works well for **individual files**.
  - **Limitation:** dragging whole *folder trees* out as virtual items is
    poorly exposed by current Flutter plugins (the Win32 API supports
    directory entries, but the plugin layer doesn't surface it). Options:
    small native plugin patch, pull-to-temp-then-drag, or just rely on the
    Phase 2 drive for that experience.
- Conclusion: in-app "Backup to folder" button stays the primary fast path;
  DnD is convenience.

## Phase 2 — virtual drive in Explorer

- WinFsp-based filesystem service (Rust or C#; not Flutter) exposing the
  phone as a drive letter, backed by adb.
- Expectation to manage: Explorer copies through a drive are file-by-file, so
  bulk copies will be *slower* than the app's tar streaming — the drive is
  for browsing/casual access, the app for big backups.
- The Flutter app becomes the tray/settings UI that starts/stops the service.

## Environment

- Flutter SDK: `D:\Dev\flutter` (cloned stable channel)
- adb: `D:\Dev\tools\platform-tools\adb.exe`
- Windows tar: `C:\Windows\System32\tar.exe` (bsdtar 3.8.4 — confirmed)
- Toolchain: VS 2022 Build Tools + C++ workload (required for
  `flutter build windows`)

---

# Backlog

## v0.1 (MVP) — shipped 2026-07-17, verified on Pixel 8
- [x] Detect device(s), show connection state (`adb devices -l`, poll)
- [x] Browse /sdcard tree, lazy loading, folder checkboxes
- [x] Destination picker, backup queue with tar-stream engine
- [x] Progress (bytes + MB/s), per-folder retry, error log
- [x] File-count verification after each folder

## v0.1.1 refinements (from first real use) — coded, pending app restart
- [x] ETA per queue item (smoothed speed)
- [x] Empty folders lose their chevron (background one-level-ahead prefetch,
      which also makes expanding feel instant)
- [x] Current file + extracted-count shown in queue item — implemented by
      parsing tar headers in-flight (`TarStreamMonitor`); note: device
      `tar -v` is unusable, toybox prints verbose names into stdout,
      corrupting the archive

### Gotchas learned on real hardware (keep in mind for Phase 2)
- adb escapes separately-passed args itself → always send the device command
  as ONE string argument
- `adb exec-out` swallows device exit codes (always 0) → use `adb shell` for
  text commands (exit codes propagate), exec-out only for binary streams
- `ls -l` on a symlinked dir shows the link, not contents → trailing slash
- `adb shell` output has \r\n line endings on Windows

## v0.2 (quality) — core landed 2026-07-17, verified live on Pixel 8
- [x] Incremental mode: manifest compare (size+mtime via batched `stat`),
      changed files only via `tar -T` list pushed to /data/local/tmp
- [x] Backup profiles (paths + dest + layout + incremental) in settings.json
- [x] Mirror vs Snapshot layouts; snapshots hardlink unchanged files from the
      previous snapshot (CreateHardLinkW via dart:ffi) — near-zero disk cost
- [x] Native Dart tar extractor (lib/src/tar_extractor.dart) replaced
      Windows bsdtar: bsdtar decodes ustar names in the ANSI codepage and
      mangles non-ASCII (Polish!) filenames, silently breaking incremental
      compares. Also restores mtimes exactly and blocks path traversal.
- [x] `adb pull -a` fallback when device tar is missing (full-tree pull with
      progress parsing; incremental pulls changed files individually)
- [x] Deep verify per job (batched device md5sum vs local streamed MD5;
      mismatches/missing become job warnings) — live-tested incl. tampering
- [x] Wireless adb dialog (adb pair + adb connect)
- [x] QR pairing (Android Studio-style): dialog shows a WIFI:T:ADB QR; app
      polls `adb mdns services` for the matching _adb-tls-pairing service,
      pairs, then auto-connects. Manual fields kept as fallback.
- [x] Auto-reconnect: paired devices are remembered by adb (key exchange is
      one-time); the connect PORT changes per boot, so the app rescans mDNS
      every ~30s and quietly `adb connect`s known devices it sees.
- [x] Default window narrowed to 880×720 (windows/runner/main.cpp); title
      fixed to "AndroidFiles".
- [x] App icon: generated programmatically (tool/gen_icon.dart → multi-size
      app_icon.ico; white phone + knocked-out download arrow on a green tile).
      Each frame is drawn at its own size rather than downscaled from one
      master — nested detail turns to mush below ~32px, so 16/20/24 drop the
      phone and keep just the arrow. `dart run tool/gen_icon.dart --preview`
      writes a contact sheet to check the small sizes on light and dark.
- [x] adb auto-bootstrap: if adb is missing, the app downloads Google's
      platform-tools (~8 MB) to %LOCALAPPDATA%\AndroidFiles and uses it;
      progress + retry UI in the tree pane (lib/src/adb_installer.dart,
      verified end-to-end).
- [x] Windows-native UI: migrated Material → fluent_ui 4.16 (ScaffoldPage
      header, ComboBox, TextBox/InfoLabel, ContentDialog, Expander,
      ProgressBar/Ring, fluent Checkbox/Buttons). Material UI backup kept in
      session scratchpad. Note: fluent ProgressBar value is 0..100.
- [x] Light theme by default; Light/Dark/Follow-Windows selector in
      Settings (settings.themeMode).
- [x] Log pane hidden by default; terminal-icon toolbar toggle
      (settings.showLog persists).
- [x] Resizable tree/queue split (drag the divider; settings.splitRatio) and
      an always-visible draggable tree scrollbar (RawScrollbar; the fluent
      built-in overlay bar is suppressed to avoid doubles).
- [x] Pause/resume per transfer: pausing simply stops reading the tar
      stream — backpressure stalls device tar; ETA window resets on resume.
      Only tar-stream jobs are pausable (adb pull/push are not).
- [x] Cancel hardening: truncated in-flight file is deleted on cancel/stream
      loss (unit-tested); snapshots stage as <stamp>.partial and rename only
      when every job succeeds (partials are never used as incremental base);
      cancelled restores warn that the phone may hold a partial file.
- [x] UI polish: sectioned right panel (PROFILE/BACKUP/QUEUE cards), 3-step
      onboarding checklist, device picker label+transport icon and narrower
      width, full-width job progress bars.
- [x] Drive writable mode (drive/ --writable + app setting w/ confirmation):
      staging + push-on-cleanup (FlushAndPurgeOnCleanup fixes 0-byte pushes),
      rm -f / rmdir-only / mv with ReplaceIfExists / mkdir, cache
      invalidation. Live-verified on Pixel 6a over Wi-Fi, confined to a test
      folder. Read-only default regression-checked. Compromises documented
      in drive/README.md (CloseHandle can't report push errors; timestamps
      not persisted; last-writer-wins).
- [x] Settings dialog: adb path (+test), drive host path, drive letter
- [x] Mount/unmount the Explorer drive (P:) from the app toolbar — spawns
      drive\publish\AdbDrive.exe, sweeps its stale temp cache before mount

Live e2e harness: `flutter test test/live_backup_manual.dart` (needs a
connected device; creates+removes /sdcard/AndroidFilesTest). Covers mirror,
incremental, snapshot+hardlink, deep verify, and the pull fallback.

## v0.3 (interop) — landed 2026-07-17
- [x] Drop into app → push files back to phone: drag from Explorer onto the
      tree, dialog picks the device folder, runs as queue jobs with progress
      (live-tested). Tree cache refreshes after the push.
- [x] Scheduled backups: schedule icon next to profiles registers a daily
      Windows Task Scheduler run of `AndroidFiles.exe --run-profile <name>`
      (headless: waits for device, runs, toast, exits with status code).
- [x] Toast notification whenever the queue finishes (ok/warnings/failed).
- [~] Drag OUT of app → Explorer: intentionally skipped — the P: drive
      already gives Explorer native access to single files, so virtual-file
      drag plumbing (super_drag_and_drop + Rust build chain) adds fragility
      for no new capability.

## Installer + auto-update (Velopack) — landed 2026-07-18
- [x] `updater/` — small self-contained C# console exe wrapping Velopack's
      official .NET SDK (`--check` / `--apply --wait-pid` / `--version`). The
      Flutter exe is the Velopack mainExe and handles hooks (main.dart exits on
      `--veloapp-*`); the helper does check/download/apply so Dart needs no
      Rust binding.
- [x] release.yml: publishes the updater self-contained (no runtime prereq →
      no UAC), assembles the pack dir, `vpk download` (delta base) → `vpk pack`
      → `vpk upload --publish --merge`, still attaching the portable ZIP.
- [x] In-app: Dart checks GitHub (update_checker.dart) → bar; the button calls
      the updater `--apply` in a managed install, else opens the release page.
      Apply choreography: helper downloads, signals `ready-to-apply`, app
      exits, helper applies + relaunches.
- Verified locally end-to-end EXCEPT the live download→apply→restart: `vpk
      pack` builds Setup.exe, silent per-user install to %LocalAppData% (no
      admin), installed `--version` reports 0.1.0, `--check` degrades to
      `check-failed` on the (private) repo, clean uninstall. The actual apply
      cycle needs two real PUBLIC releases to exercise — do that dry-run on a
      throwaway tag once the repo is public.
- Self-contained updater is ~68 MB (Setup.exe ~49 MB); Velopack deltas keep
      subsequent updates small. Didn't trim (Velopack reflection).

## Phase 2 (separate component)
- [x] WinFsp service prototype — `drive/` (C#/.NET 9, references the WinFsp
      installer's official `winfsp-msil.dll`). Read-only, mounts /sdcard at
      P: (`--mount`/`--serial`/`--root` args), 10s listing cache, whole-file
      pull-to-temp cache (2 GB LRU, evicted on unmount), writes rejected as
      media-write-protected. Built and verified live 2026-07-17: listings,
      SHA-256-identical reads, clean Ctrl+C unmount. `dotnet build` in
      drive/, see drive/README.md.
- [x] Mount/unmount from the Flutter app (toolbar button, DriveManager
      spawns/kills the host; published exe at drive\publish\AdbDrive.exe)
- [ ] Read-write support (push on write) — stretch. DELIBERATELY not built
      autonomously: a buggy writable filesystem over the phone risks user
      data; needs an explicit go-ahead (and a design pass on write-through
      vs. staging semantics) first.

## Open questions to refine together
- Backup layout: mirror (overwrite in place) vs. dated snapshots vs. both?
- Do we need multi-device support in v0.1 or is single phone fine?
- Which folders matter most (DCIM, WhatsApp, Download…)? Could ship presets.

## Code signing — SignPath Foundation (researched 2026-07-18)

Free signing for OSS via <https://signpath.org/>. The plan is to apply here
before paying for a cert. Eligibility, checked against their terms:

- **OSI-approved license, no commercial dual-licensing, no proprietary
  components** (system libs excepted, GPLv3 definition). MIT ✓; vendored
  fluent_ui is BSD-3 ✓; WinFsp is user-installed, not bundled ✓.
- **Automated build from source** — release.yml already builds on GitHub
  Actions from source ✓. SignPath signs artifacts handed off from that CI.
- **Signed binaries carry matching product-name/version metadata** — verify
  the Runner sets ProductName/FileVersion from pubspec before applying.
- **Publisher on the cert reads "SignPath Foundation", not us.** Accepted.
- **"Verifiable reputation" required for executables** (not for libraries).
  *This is the gap.* At v0.1.0 in a private repo with no users, we likely
  don't clear it yet.

Sequence: go public → gather a little adoption (stars / a few real users) →
then apply. Applying at v0.1.0 today risks a reputation rejection that doesn't
repeat-check, so it's worth waiting until there's something to point at.
Fallback if they decline: Certum OSS cert (~€69 then €29/yr, non-US/CA OK).
