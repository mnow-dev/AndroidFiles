/// Data models shared across the app.
library;

class AdbDevice {
  final String serial;
  final String state; // device | unauthorized | offline
  final String model;

  const AdbDevice({required this.serial, required this.state, required this.model});

  bool get isReady => state == 'device';

  bool get isWireless =>
      serial.contains(':') || serial.contains('_adb-tls-connect');

  String get label => model.isEmpty ? serial : '$model ($serial)';

  @override
  bool operator ==(Object other) =>
      other is AdbDevice && other.serial == serial && other.state == state;

  @override
  int get hashCode => Object.hash(serial, state);
}

class RemoteEntry {
  final String name;
  final String path; // absolute path on device
  final bool isDir;
  final bool isLink;
  final int size;
  final String modified;

  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.isLink = false,
    this.size = 0,
    this.modified = '',
  });
}

/// A browsable storage root on an Android device — internal storage (`/sdcard`)
/// or a mounted external microSD card / USB volume (`/storage/<UUID>`).
class StorageVolume {
  final String path; // e.g. '/sdcard' or '/storage/1A2B-3C4D'
  final String label; // e.g. 'Internal storage' or 'SD card (1A2B-3C4D)'
  final bool isExternal;

  const StorageVolume({
    required this.path,
    required this.label,
    required this.isExternal,
  });

  /// Internal primary storage (`/sdcard`).
  static const internal = StorageVolume(
    path: '/sdcard',
    label: 'Internal storage',
    isExternal: false,
  );

  /// Short stable identifier for external volumes (e.g. `1A2B-3C4D`); empty for
  /// internal storage.
  String get volumeId {
    if (!isExternal) return '';
    final i = path.lastIndexOf('/');
    return i == -1 ? path : path.substring(i + 1);
  }

  /// Whether [devicePath] lives inside this volume.
  bool containsPath(String devicePath) =>
      devicePath == path || devicePath.startsWith('$path/');

  @override
  bool operator ==(Object other) =>
      other is StorageVolume &&
      other.path == path &&
      other.label == label &&
      other.isExternal == isExternal;

  @override
  int get hashCode => Object.hash(path, label, isExternal);
}

final _externalStorageRe = RegExp(r'^/storage/([^/\s]+)(?:/|$)');
const _reservedStorageDirs = {
  'emulated',
  'self',
  'enc_emulated',
  'knox-emulated',
  'isolated',
  '.',
  '..',
};

/// If [devicePath] is inside an external storage mount (`/storage/<UUID>...`),
/// returns `<UUID>`. Returns `null` for `/sdcard` or system/reserved paths.
String? externalStorageId(String devicePath) {
  final m = _externalStorageRe.firstMatch(devicePath);
  if (m == null) return null;
  final id = m.group(1)!;
  if (id.startsWith('.') || _reservedStorageDirs.contains(id.toLowerCase())) {
    return null;
  }
  return id;
}

/// Subfolder name used locally to keep external SD card backups separate from
/// internal `/sdcard` folders (avoiding collisions like two `DCIM/` folders).
/// Returns `null` for internal storage so existing layouts stay unchanged.
String? externalStorageBackupSubdir(String devicePath) {
  final id = externalStorageId(devicePath);
  return id == null ? null : 'SD-$id';
}

enum BackupLayout { mirror, snapshot }

/// Local backup state for an entry in the device folder tree, computed cheaply
/// against the local destination directory (Mirror or latest Snapshot).
enum EntryBackupStatus { unknown, checking, notBackedUp, partial, backedUp, modified }

enum JobStatus { queued, measuring, running, verifying, done, doneWithWarnings, failed, cancelled }

extension JobStatusLabel on JobStatus {
  String get label => switch (this) {
        JobStatus.queued => 'queued',
        JobStatus.measuring => 'measuring…',
        JobStatus.running => 'copying',
        JobStatus.verifying => 'verifying',
        JobStatus.done => 'done',
        JobStatus.doneWithWarnings => 'done (warnings)',
        JobStatus.failed => 'failed',
        JobStatus.cancelled => 'cancelled',
      };

  bool get isTerminal =>
      this == JobStatus.done ||
      this == JobStatus.doneWithWarnings ||
      this == JobStatus.failed ||
      this == JobStatus.cancelled;
}
