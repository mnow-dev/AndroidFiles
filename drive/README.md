# AdbDrive — Android storage as a read-only Windows drive (Phase 2 prototype)

Mounts an Android phone's `/sdcard` (over adb) as a Windows drive letter using
[WinFsp](https://winfsp.dev/). This is the Phase 2 prototype of the
AndroidFiles project: a browse-oriented companion to the backup app.

## Requirements

- Windows 10/11 x64
- [WinFsp](https://winfsp.dev/rel/) installed (the project references
  `C:\Program Files (x86)\WinFsp\bin\winfsp-msil.dll`, the official .NET
  binding shipped by the installer)
- .NET SDK 9
- adb (default path `D:\Dev\tools\platform-tools\adb.exe`, override with
  `--adb`) and a device with USB debugging authorized

## Build

```
cd D:\Dev\AndroidFiles\drive
dotnet build
```

## Run

```
bin\Debug\net9.0-windows\AdbDrive.exe [options]

  --serial <serial>   device serial (default: first connected device)
  --mount <point>     mount point, e.g. P: or X: (default: P:)
  --root <path>       device root directory (default: /sdcard)
  --adb <path>        path to adb.exe
  --writable          DANGEROUS: write-through mode (see below); default is read-only
  --debug             WinFsp debug logging to stderr
```

Press **Ctrl+C** to unmount cleanly (this also deletes the local file cache).

## Writable mode (`--writable`)

**Off by default.** Without the flag the volume is strictly read-only and every
mutation is rejected with "The media is write protected." With `--writable`,
**changes made in Explorer modify the phone** (a warning banner is printed at
mount time):

- **Create/write**: new and modified files are staged in a local file; when
  the handle is cleaned up the staging copy is pushed to the device with
  `adb push`. New files appear on the device immediately (created empty via
  `touch`), content follows on close.
- **Delete**: files use device `rm -f`; directories use `rmdir` only — a
  non-empty directory delete fails with "directory not empty", matching
  Windows semantics (never `rm -rf`).
- **Rename/move**: device `mv`; renaming onto an existing name fails unless
  the caller asked to replace (and directories are never replaced).
- **New folder**: device `mkdir`.
- After every successful mutation the parent directory's listing cache and
  any pulled content for the path are invalidated.

Writable-mode caveats (semantics compromises):

- **Push errors cannot be reported through CloseHandle** — Windows offers no
  channel for that. A failed push is logged loudly on the console and the
  device copy stays stale/incomplete. Apps that call `FlushFileBuffers`
  (e.g. robocopy with `/J`-less default) do get a real error status, because
  Flush pushes synchronously.
- **Timestamps are not persisted**: Explorer sets timestamps after a copy;
  the request is accepted but ignored (Android's storage layer stamps mtime
  at push time, and there is no creation time at all).
- **Last writer wins**: two simultaneous open-for-write handles on the same
  file stage independently; whichever closes last determines the device
  content.
- A file being written is visible on the device (and in fresh listings) at
  its old size until the push on close completes.

## Expected behavior

- `P:` appears with volume label **Android**, filesystem name `AdbFS`,
  real total/free sizes from device `df`.
- Directory listings come from `adb shell ls -lA '<path>/'` and are cached in
  memory for ~10 s (failed lookups for ~3 s), so Explorer stays snappy while
  still noticing changes on the phone within seconds.
- File metadata (size, mtime) comes from those listings; toybox `ls` has
  minute resolution, so seconds always show as `:00`.
- **Reads pull the whole file once**: the first read of a file runs
  `adb exec-out cat '<path>'` into `%TEMP%\AdbDrive\<hash>.bin`, then all
  reads are served locally. The cache is capped at ~2 GB with LRU eviction
  and is deleted on unmount. A file whose size or mtime changes on the phone
  gets a fresh cache entry.
- **Read-only**: creating, writing, renaming, deleting, and attribute or
  ACL changes are rejected with `STATUS_MEDIA_WRITE_PROTECTED` — Explorer
  shows "The media is write protected."
- Names are case-sensitive (Android storage is), Unicode-clean, and symlinked
  directories (like `/sdcard` itself) are browsable.

## Known limitations

- **Read-only by default**; opt-in write-through via `--writable` (above).
- **Per-file pull latency**: opening a file pulls the *entire* file before
  the first read returns. Fine for documents and photos; a multi-GB video
  will make the first access stall for as long as the USB transfer takes
  (and files bigger than the 2 GB cache cap will temporarily overshoot it).
- **Bulk copies are slower than the AndroidFiles app.** Explorer copies
  file-by-file through the drive (per-file adb round-trips), while the app
  streams whole folders as one tar stream. Use the drive for browsing and
  casual access, the app for big backups.
- Timestamps are minute-granular; no creation time is available (mtime is
  used for all timestamps).
- No hung-transfer watchdog on `cat` pulls yet; if adb wedges mid-pull the
  read blocks until adb exits.
- One mount per process; run multiple instances with different `--mount`
  and `--serial` for multiple devices.

## Design notes (adb gotchas honored, verified on real hardware)

- adb escapes separately-passed arguments itself, so device commands are
  always passed as **one string argument** (`["shell", "ls -lA '/sdcard/'"]`).
- `adb exec-out` swallows device exit codes (always 0) → text commands use
  `adb shell` (exit codes propagate); `exec-out` is used only for the binary
  `cat` stream, and success is verified by comparing byte count with the
  size from the directory listing.
- `ls -l` on a symlinked dir shows the link, not contents → a trailing `/`
  is appended to directory paths.
- `adb shell` output on Windows has `\r\n` line endings → tolerated when
  splitting lines.
- Device paths are quoted for the device-side shell with single quotes,
  escaping embedded ones (`'` → `'\''`).
- toybox `ls -lA` line format parsed with the same regex as the Dart client
  (`lib/src/adb_client.dart`); symlinks are treated as directories so
  `/sdcard`-style links stay browsable.
