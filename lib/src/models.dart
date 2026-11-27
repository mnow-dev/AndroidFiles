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

/// Live Wi-Fi link telemetry for a wirelessly connected Android device
/// (parsed from `adb shell cmd wifi status` / `dumpsys wifi`).
class WifiLinkInfo {
  /// Effective link speed in Mbps (prefers Tx link speed since backups upload
  /// from the phone to the computer).
  final int linkSpeedMbps;
  final int? frequencyMhz;
  final int? rssiDbm;
  final String? standard;
  final String? ssid;

  const WifiLinkInfo({
    required this.linkSpeedMbps,
    this.frequencyMhz,
    this.rssiDbm,
    this.standard,
    this.ssid,
  });

  String? get bandLabel {
    final f = frequencyMhz;
    if (f == null) return null;
    if (f >= 5925) return '6 GHz';
    if (f >= 4900) return '5 GHz';
    if (f >= 2400) return '2.4 GHz';
    return null;
  }

  /// True when the phone is associated on the slower 2.4 GHz band (<3 GHz).
  bool get isSlow24Ghz => frequencyMhz != null && frequencyMhz! < 3000;

  /// Compact badge label, e.g. `5 GHz · 866 Mbps` or `2.4 GHz · 52 Mbps`.
  String get shortLabel {
    final band = bandLabel;
    return band == null ? '$linkSpeedMbps Mbps' : '$band · $linkSpeedMbps Mbps';
  }

  /// Hover tooltip explaining link quality and why 2.4 GHz may cap speed.
  String get detailTooltip {
    final parts = <String>[
      ?bandLabel,
      '$linkSpeedMbps Mbps',
      if (rssiDbm != null) '$rssiDbm dBm',
      if (standard != null && standard!.isNotEmpty) standard!,
    ];
    final summary = parts.join(' · ');
    if (isSlow24Ghz) {
      return 'Wi-Fi ($summary) — 2.4 GHz caps transfer speed; switch to 5 GHz or USB for faster backups';
    }
    return 'Wi-Fi link: $summary';
  }

  @override
  bool operator ==(Object other) =>
      other is WifiLinkInfo &&
      other.linkSpeedMbps == linkSpeedMbps &&
      other.frequencyMhz == frequencyMhz &&
      other.rssiDbm == rssiDbm &&
      other.standard == standard &&
      other.ssid == ssid;

  @override
  int get hashCode =>
      Object.hash(linkSpeedMbps, frequencyMhz, rssiDbm, standard, ssid);
}

/// Per-app storage usage reported by Android's `dumpsys diskstats`.
///
/// Separates **static** storage (`appBytes` = APK/code/libs + `dataBytes` =
/// app data/databases/media) from **reclaimable** storage (`cacheBytes` =
/// regenerable cache that can be safely cleared via `pm trim-caches`).
class AppStorageEntry {
  final String packageName;
  final int appBytes;
  final int dataBytes;
  final int cacheBytes;
  final bool isUserApp;

  const AppStorageEntry({
    required this.packageName,
    required this.appBytes,
    required this.dataBytes,
    required this.cacheBytes,
    required this.isUserApp,
  });

  /// Static storage (APK + user data; not automatically reclaimed by cache trim).
  int get staticBytes => appBytes + dataBytes;

  /// Reclaimable storage (regenerable cache).
  int get reclaimableBytes => cacheBytes;

  /// Combined storage consumed by this package.
  int get totalBytes => appBytes + dataBytes + cacheBytes;

  /// Friendly display name derived from well-known packages or the package ID.
  String get displayName => _friendlyAppName(packageName);

  static const Map<String, String> _knownNames = {
    'com.google.android.youtube': 'YouTube',
    'com.google.android.apps.youtube.music': 'YouTube Music',
    'com.google.android.apps.photos': 'Google Photos',
    'com.google.android.apps.maps': 'Google Maps',
    'com.google.android.gm': 'Gmail',
    'com.google.android.apps.docs': 'Google Drive',
    'com.google.android.apps.docs.editors.docs': 'Google Docs',
    'com.google.android.apps.docs.editors.sheets': 'Google Sheets',
    'com.google.android.apps.docs.editors.slides': 'Google Slides',
    'com.google.android.googlequicksearchbox': 'Google',
    'com.google.android.apps.messaging': 'Google Messages',
    'com.google.android.GoogleCamera': 'Pixel Camera',
    'com.android.chrome': 'Chrome',
    'com.android.vending': 'Google Play Store',
    'com.whatsapp': 'WhatsApp',
    'com.whatsapp.w4b': 'WhatsApp Business',
    'org.telegram.messenger': 'Telegram',
    'org.thoughtcrime.securesms': 'Signal',
    'jp.naver.line.android': 'LINE',
    'com.discord': 'Discord',
    'com.openai.chatgpt': 'ChatGPT',
    'com.anthropic.claude': 'Claude',
    'com.spotify.music': 'Spotify',
    'com.instagram.android': 'Instagram',
    'com.facebook.katana': 'Facebook',
    'com.facebook.orca': 'Messenger',
    'com.zhiliaoapp.musically': 'TikTok',
    'com.twitter.android': 'X (Twitter)',
    'com.reddit.frontpage': 'Reddit',
    'com.netflix.mediaclient': 'Netflix',
    'com.amazon.avod.thirdpartyclient': 'Prime Video',
    'com.microsoft.teams': 'Microsoft Teams',
    'com.Slack': 'Slack',
    'com.tailscale.ipn': 'Tailscale',
    'com.shazam.android': 'Shazam',
    'com.revolut.revolut': 'Revolut',
    'com.revolut.business': 'Revolut Business',
    'com.transferwise.android': 'Wise',
    'com.kouzoh.mercari': 'Mercari',
    'com.tplink.iot': 'Tapo / Kasa',
  };

  static String _friendlyAppName(String pkg) {
    final known = _knownNames[pkg];
    if (known != null) return known;
    final parts = pkg.split('.').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return pkg;
    const generic = {'android', 'app', 'apps', 'mobile', 'client', 'google', 'com', 'org', 'net', 'io', 'jp', 'co', 'uk', 'gov', 'dev', 'pl'};
    var candidate = parts.last;
    if (generic.contains(candidate.toLowerCase()) && parts.length >= 2) {
      candidate = parts[parts.length - 2];
    }
    if (generic.contains(candidate.toLowerCase()) && parts.length >= 3) {
      candidate = parts[parts.length - 3];
    }
    final words = candidate
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
    return words.isEmpty ? pkg : words;
  }
}

/// Device-wide app storage summary parsed from `dumpsys diskstats`.
class DeviceAppStorageReport {
  final List<AppStorageEntry> apps;
  final int totalAppBytes;
  final int totalDataBytes;
  final int totalCacheBytes;

  const DeviceAppStorageReport({
    required this.apps,
    required this.totalAppBytes,
    required this.totalDataBytes,
    required this.totalCacheBytes,
  });

  int get totalStaticBytes => totalAppBytes + totalDataBytes;
  int get totalReclaimableBytes => totalCacheBytes;
  int get totalBytes => totalAppBytes + totalDataBytes + totalCacheBytes;
  int get userAppCount => apps.where((a) => a.isUserApp).length;
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
