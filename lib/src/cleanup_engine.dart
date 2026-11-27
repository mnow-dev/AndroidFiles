import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'adb_client.dart';
import 'backup_engine.dart' show fmtBytes;
import 'manifest.dart';
import 'models.dart';
import 'os.dart';
import 'tar_extractor.dart';

enum CleanupMediaKind { video, photo, audio, archive, document, other }

/// Sort order for the Clean Up Space → Apps storage table.
enum AppSortMode {
  total('Total'),
  cache('Reclaimable'),
  data('Data'),
  app('Static APK');

  final String label;
  const AppSortMode(this.label);
}

/// One scanned user file under [rootPath] (e.g. `/sdcard` or `/storage/UUID`).
class ScannedFile {
  final String relPath; // relative to [rootPath], e.g. "DCIM/Camera/VID_01.mp4"
  final int size;
  final int mtimeSec;
  final String rootPath;
  final bool backedUp;
  final String? backupFilePath; // resolved local path when [backedUp] is true

  const ScannedFile({
    required this.relPath,
    required this.size,
    required this.mtimeSec,
    this.rootPath = '/sdcard',
    this.backedUp = false,
    this.backupFilePath,
  });

  String get absPath => '$rootPath/$relPath';

  String get name {
    final i = relPath.lastIndexOf('/');
    return i == -1 ? relPath : relPath.substring(i + 1);
  }

  String get parentDir {
    final i = relPath.lastIndexOf('/');
    return i == -1 ? '' : relPath.substring(0, i);
  }

  String get topFolder {
    final i = relPath.indexOf('/');
    return i == -1 ? '' : relPath.substring(0, i);
  }

  DateTime get modified =>
      DateTime.fromMillisecondsSinceEpoch(mtimeSec * 1000);

  CleanupMediaKind get kind => classifyMediaKind(relPath);

  bool get isVideo => kind == CleanupMediaKind.video;
  bool get isPhoto => kind == CleanupMediaKind.photo;

  ScannedFile copyWith({bool? backedUp, String? backupFilePath}) => ScannedFile(
        relPath: relPath,
        size: size,
        mtimeSec: mtimeSec,
        rootPath: rootPath,
        backedUp: backedUp ?? this.backedUp,
        backupFilePath: backupFilePath ?? this.backupFilePath,
      );
}

CleanupMediaKind classifyMediaKind(String path) {
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return CleanupMediaKind.other;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'mp4' || 'mov' || 'mkv' || 'avi' || 'webm' || '3gp' || 'm4v' || 'ts' =>
      CleanupMediaKind.video,
    'jpg' || 'jpeg' || 'png' || 'heic' || 'heif' || 'webp' || 'dng' || 'raw' || 'gif' =>
      CleanupMediaKind.photo,
    'mp3' || 'm4a' || 'flac' || 'wav' || 'ogg' || 'opus' || 'aac' =>
      CleanupMediaKind.audio,
    'zip' || 'tar' || 'gz' || '7z' || 'rar' || 'apk' || 'xapk' || 'iso' =>
      CleanupMediaKind.archive,
    'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'ppt' || 'pptx' || 'epub' =>
      CleanupMediaKind.document,
    _ => CleanupMediaKind.other,
  };
}

/// Aggregated space usage for a device folder (top-level or 2nd-level).
class FolderUsage {
  final String relPath; // e.g. "DCIM/Camera" or "Download"
  final int totalBytes;
  final int fileCount;
  final int videoBytes;
  final int backedUpBytes;

  const FolderUsage({
    required this.relPath,
    required this.totalBytes,
    required this.fileCount,
    required this.videoBytes,
    required this.backedUpBytes,
  });
}

/// A set of byte-identical duplicate files (same MD5 hash).
class DuplicateGroup {
  final String md5;
  final int fileSize;

  /// Ordered with the recommended file to KEEP first (`files.first`).
  final List<ScannedFile> files;

  const DuplicateGroup({
    required this.md5,
    required this.fileSize,
    required this.files,
  });

  int get wastedBytes => fileSize * (files.length - 1);
  ScannedFile get recommendedKeep => files.first;
  List<ScannedFile> get redundantCopies => files.sublist(1);
}

/// Age retention threshold for smart cleanup proposals.
enum RetentionWindow {
  keep1Month(30, 'Keep last 1 mo'),
  keep3Months(90, 'Keep last 3 mo'),
  keep6Months(180, 'Keep last 6 mo'),
  keep1Year(365, 'Keep last 1 yr'),
  all(0, 'Include all');

  final int days;
  final String label;
  const RetentionWindow(this.days, this.label);
}

/// An intelligent cleanup recommendation built from the live scan.
class SmartProposal {
  final String id;
  final String title;
  final String subtitle;
  final String reason;
  final List<ScannedFile> files;

  const SmartProposal({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.reason,
    required this.files,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.size);
  int get backedUpCount => files.where((f) => f.backedUp).length;
  int get notBackedUpCount => files.length - backedUpCount;
  int get backedUpBytes =>
      files.where((f) => f.backedUp).fold(0, (sum, f) => sum + f.size);
  bool get allBackedUp => files.isNotEmpty && notBackedUpCount == 0;
}

class CleanupExecutionSummary {
  final int backedUpCount;
  final int deletedCount;
  final int freedBytes;
  final int skippedCount;
  final List<String> errors;

  const CleanupExecutionSummary({
    required this.backedUpCount,
    required this.deletedCount,
    required this.freedBytes,
    required this.skippedCount,
    required this.errors,
  });
}

/// Pure helpers for folder aggregation, smart proposals, and duplicate ranking.
class CleanupAnalyzer {
  /// Roll up files into the most informative folder buckets (uses 2nd-level
  /// folders like `DCIM/Camera` when a top-level dir has subfolders, else
  /// top-level like `Download`).
  static List<FolderUsage> computeFolderUsage(List<ScannedFile> files) {
    final buckets = <String, List<ScannedFile>>{};
    for (final f in files) {
      final segs = f.relPath.split('/');
      final key = segs.length >= 3
          ? '${segs[0]}/${segs[1]}'
          : (segs.length == 2 ? segs[0] : '(root)');
      (buckets[key] ??= []).add(f);
    }
    final list = <FolderUsage>[
      for (final e in buckets.entries)
        FolderUsage(
          relPath: e.key,
          totalBytes: e.value.fold(0, (s, f) => s + f.size),
          fileCount: e.value.length,
          videoBytes: e.value
              .where((f) => f.isVideo)
              .fold(0, (s, f) => s + f.size),
          backedUpBytes: e.value
              .where((f) => f.backedUp)
              .fold(0, (s, f) => s + f.size),
        ),
    ];
    list.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return list;
  }

  /// Build intelligent cleanup proposals given [files], [retention], and [now].
  static List<SmartProposal> buildProposals(
    List<ScannedFile> files, {
    required RetentionWindow retention,
    bool onlyAlreadyBackedUp = false,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final cutoffSec = retention.days == 0
        ? null
        : clock.subtract(Duration(days: retention.days)).millisecondsSinceEpoch ~/
            1000;

    bool matchesFilter(ScannedFile f, {bool ignoreAge = false}) {
      if (onlyAlreadyBackedUp && !f.backedUp) return false;
      if (!ignoreAge && cutoffSec != null && f.mtimeSec > cutoffSec) {
        return false;
      }
      return true;
    }

    final proposals = <SmartProposal>[];

    // 1. DCIM Videos Only — videos typically dominate camera storage while
    //    leaving all photos intact on the device.
    final dcimAll = files.where((f) => f.topFolder.toLowerCase() == 'dcim').toList();
    final dcimVideos = dcimAll
        .where((f) => f.isVideo && matchesFilter(f))
        .toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (dcimVideos.isNotEmpty) {
      final dcimTotal = dcimAll.fold(0, (s, f) => s + f.size);
      final vidTotal = dcimVideos.fold(0, (s, f) => s + f.size);
      final pct = dcimTotal > 0 ? ((vidTotal / dcimTotal) * 100).round() : 0;
      proposals.add(SmartProposal(
        id: 'dcim_videos',
        title: 'DCIM Videos Only',
        subtitle: retention == RetentionWindow.all
            ? 'All camera videos — keeps every photo on your phone'
            : 'Videos older than ${retention.days} days — keeps all photos & recent clips',
        reason: pct >= 15
            ? 'Videos make up $pct% of your DCIM storage'
            : 'Large camera videos are the fastest way to free space',
        files: dcimVideos,
      ));
    }

    // 2. Older DCIM Photos & Videos (when a retention window is active)
    if (retention != RetentionWindow.all) {
      final olderDcim = dcimAll.where((f) => matchesFilter(f)).toList()
        ..sort((a, b) => b.size.compareTo(a.size));
      if (olderDcim.length > dcimVideos.length) {
        proposals.add(SmartProposal(
          id: 'dcim_older',
          title: 'Older Camera Roll (${retention.label})',
          subtitle:
              'Photos & videos older than ${retention.days} days in DCIM',
          reason: 'Keeps your most recent ${retention.days} days right on the phone',
          files: olderDcim,
        ));
      }
    }

    // 3. Large Downloads & Installers (APKs, archives, big downloads)
    final downloads = files
        .where((f) =>
            f.topFolder.toLowerCase() == 'download' && matchesFilter(f))
        .toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (downloads.isNotEmpty) {
      proposals.add(SmartProposal(
        id: 'downloads',
        title: 'Downloads Folder',
        subtitle: retention == RetentionWindow.all
            ? 'APKs, archives, and downloaded files in Download'
            : 'Downloads older than ${retention.days} days',
        reason: 'Downloads accumulate installers and one-off files over time',
        files: downloads,
      ));
    }

    // 4. Messenger Media (WhatsApp / Telegram / Signal)
    final messenger = files.where((f) {
      final low = f.relPath.toLowerCase();
      final isChat = low.startsWith('whatsapp/') ||
          low.startsWith('android/media/com.whatsapp/') ||
          low.startsWith('telegram/') ||
          low.startsWith('pictures/telegram/') ||
          low.startsWith('movies/telegram/');
      return isChat && matchesFilter(f);
    }).toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (messenger.isNotEmpty) {
      proposals.add(SmartProposal(
        id: 'messenger',
        title: 'Messenger Media (WhatsApp / Telegram)',
        subtitle: retention == RetentionWindow.all
            ? 'All saved chat media & forwarded videos'
            : 'Chat media older than ${retention.days} days',
        reason: 'Forwarded videos and voice notes quietly consume gigabytes',
        files: messenger,
      ));
    }

    // 5. All Already Backed-Up Files (respecting retention window)
    final backedUp = files
        .where((f) => f.backedUp && matchesFilter(f))
        .toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (backedUp.isNotEmpty) {
      proposals.add(SmartProposal(
        id: 'all_backed_up',
        title: 'All Already Backed-Up Files',
        subtitle: retention == RetentionWindow.all
            ? 'Every scanned file already matched in your local backup folder'
            : 'Backed-up files older than ${retention.days} days',
        reason: 'Matched by size + modified time against your local backup',
        files: backedUp,
      ));
    }

    // 6. Clutter & Cache Files (.thumbnails, .trashed-*, etc.)
    final clutterRe = compileIgnorePatterns(defaultClutterPatterns);
    final clutter = files
        .where((f) => isIgnored(f.relPath, clutterRe) && matchesFilter(f, ignoreAge: true))
        .toList()
      ..sort((a, b) => b.size.compareTo(a.size));
    if (clutter.isNotEmpty) {
      proposals.add(SmartProposal(
        id: 'clutter',
        title: 'Regenerable Caches & Trash',
        subtitle: 'Matches .thumbnails, .trashed-*, LOST.DIR, .thumbdata*',
        reason: 'Android regenerates caches automatically if needed',
        files: clutter,
      ));
    }

    proposals.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
    return proposals;
  }

  /// Rank files within a duplicate group so index 0 is the best copy to KEEP:
  /// prefers DCIM/Camera, then non-Download/non-messenger, then oldest mtime,
  /// then shortest path.
  static List<ScannedFile> rankDuplicateCopies(List<ScannedFile> group) {
    int priority(ScannedFile f) {
      final low = f.relPath.toLowerCase();
      if (low.startsWith('dcim/camera/')) return 0;
      if (low.startsWith('dcim/')) return 1;
      if (low.startsWith('documents/') || low.startsWith('pictures/')) return 2;
      if (low.startsWith('download/')) return 4;
      if (low.contains('whatsapp') || low.contains('telegram')) return 5;
      return 3;
    }

    final sorted = List.of(group);
    sorted.sort((a, b) {
      final pa = priority(a).compareTo(priority(b));
      if (pa != 0) return pa;
      final ma = a.mtimeSec.compareTo(b.mtimeSec);
      if (ma != 0) return ma;
      return a.relPath.length.compareTo(b.relPath.length);
    });
    return sorted;
  }
}

/// Stateful controller managing storage analysis, duplicate detection, smart
/// cleanup proposals, selection, and safe "Back up first, then clean up".
class CleanupController extends ChangeNotifier {
  final AdbClient adb;
  final void Function(String) log;

  CleanupController({required this.adb, required this.log});

  String? _scannedSerial;
  String? _scannedRootPath;
  String? _scannedBackupDir;
  String activeRootPath = '/sdcard';

  bool scanning = false;
  String? scanError;
  ({int totalBytes, int usedBytes, int freeBytes})? deviceSpace;

  List<ScannedFile> files = [];
  List<FolderUsage> folders = [];

  // Duplicate detection state
  bool scanningDuplicates = false;
  int dupHashed = 0;
  int dupTotalToHash = 0;
  bool duplicatesScanned = false;
  List<DuplicateGroup> duplicates = [];

  // Smart proposal filter knobs
  RetentionWindow retention = RetentionWindow.keep3Months;
  bool onlyBackedUpProposals = false;

  // Large files tab filter knobs
  int minLargeBytes = 20 * 1024 * 1024; // 20 MB default
  bool largeVideosOnly = false;
  String? folderFilter;

  // User's active cleanup selection (relative paths under activeRootPath)
  final Set<String> selectedPaths = {};

  // Cleanup execution state
  bool executing = false;
  String executionPhase = '';
  double executionProgress = 0;
  CleanupExecutionSummary? lastSummary;

  // Installed app storage (static APK/data + reclaimable cache)
  DeviceAppStorageReport? appStorage;
  bool loadingApps = false;
  bool actingOnApps = false;
  String? appStorageError;
  String? appActionMessage;
  bool showSystemApps = false;
  AppSortMode appSort = AppSortMode.total;
  String appSearchQuery = '';

  bool get hasScan =>
      files.isNotEmpty ||
      (_scannedSerial != null && _scannedRootPath == activeRootPath && !scanning);
  String? get scannedBackupDir => _scannedBackupDir;

  void resetForDevice(String? serial, {String rootPath = '/sdcard'}) {
    if (_scannedSerial == serial && _scannedRootPath == rootPath) return;
    _scannedSerial = null;
    _scannedRootPath = null;
    _scannedBackupDir = null;
    activeRootPath = rootPath;
    deviceSpace = null;
    files = [];
    folders = [];
    duplicates = [];
    duplicatesScanned = false;
    selectedPaths.clear();
    scanError = null;
    lastSummary = null;
    folderFilter = null;
    appStorage = null;
    appStorageError = null;
    appActionMessage = null;
    notifyListeners();
  }

  void setShowSystemApps(bool v) {
    if (showSystemApps == v) return;
    showSystemApps = v;
    notifyListeners();
  }

  void setAppSort(AppSortMode v) {
    if (appSort == v) return;
    appSort = v;
    notifyListeners();
  }

  void setAppSearchQuery(String q) {
    if (appSearchQuery == q) return;
    appSearchQuery = q;
    notifyListeners();
  }

  void dismissAppActionMessage() {
    if (appActionMessage == null) return;
    appActionMessage = null;
    notifyListeners();
  }

  /// Filtered and sorted list of installed apps for the Apps tab.
  List<AppStorageEntry> get filteredApps {
    final report = appStorage;
    if (report == null) return const [];
    final q = appSearchQuery.trim().toLowerCase();
    final list = report.apps.where((a) {
      if (!showSystemApps && !a.isUserApp) return false;
      if (q.isNotEmpty &&
          !a.displayName.toLowerCase().contains(q) &&
          !a.packageName.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
    list.sort((a, b) => switch (appSort) {
          AppSortMode.total => b.totalBytes.compareTo(a.totalBytes),
          AppSortMode.cache => b.cacheBytes.compareTo(a.cacheBytes),
          AppSortMode.data => b.dataBytes.compareTo(a.dataBytes),
          AppSortMode.app => b.appBytes.compareTo(a.appBytes),
        });
    return list;
  }

  /// Load per-app storage usage from `dumpsys diskstats`.
  Future<void> scanApps(String serial) async {
    if (loadingApps) return;
    loadingApps = true;
    appStorageError = null;
    notifyListeners();
    try {
      final report = await adb.appStorageUsage(serial);
      appStorage = report;
      log('App storage scan: ${report.apps.length} packages '
          '(${fmtBytes(report.totalStaticBytes)} static, '
          '${fmtBytes(report.totalReclaimableBytes)} reclaimable cache)');
    } catch (e) {
      appStorageError = '$e';
      log('App storage scan failed: $e');
    } finally {
      loadingApps = false;
      notifyListeners();
    }
  }

  /// Safely trim regenerable app caches across the phone (`pm trim-caches`),
  /// then re-scan app storage & free space.
  Future<void> trimAllCaches(String serial) async {
    if (actingOnApps) return;
    final beforeCache = appStorage?.totalCacheBytes ?? 0;
    actingOnApps = true;
    appActionMessage = null;
    notifyListeners();
    try {
      await adb.trimAllAppCaches(serial);
      final updated = await adb.appStorageUsage(serial);
      appStorage = updated;
      deviceSpace = await adb.storageSpace(serial, activeRootPath) ?? deviceSpace;
      final freed = (beforeCache - updated.totalCacheBytes).clamp(0, beforeCache);
      appActionMessage = freed > 0
          ? 'Trimmed app caches — reclaimed ${fmtBytes(freed)}'
          : 'App caches trimmed (Android reports ${fmtBytes(updated.totalCacheBytes)} remaining)';
      log(appActionMessage!);
    } catch (e) {
      appActionMessage = 'Trim caches failed: $e';
      log(appActionMessage!);
    } finally {
      actingOnApps = false;
      notifyListeners();
    }
  }

  /// Clear all local data & cache for a single app (`pm clear`).
  Future<void> clearAppData(String serial, AppStorageEntry app) async {
    if (actingOnApps) return;
    actingOnApps = true;
    appActionMessage = null;
    notifyListeners();
    try {
      await adb.clearAppData(serial, app.packageName);
      appStorage = await adb.appStorageUsage(serial);
      deviceSpace = await adb.storageSpace(serial, activeRootPath) ?? deviceSpace;
      appActionMessage = 'Cleared data & cache for ${app.displayName}';
      log(appActionMessage!);
    } catch (e) {
      appActionMessage = 'Clear data failed: $e';
      log(appActionMessage!);
    } finally {
      actingOnApps = false;
      notifyListeners();
    }
  }

  /// Uninstall a user-installed app (`adb uninstall`).
  Future<void> uninstallApp(String serial, AppStorageEntry app) async {
    if (actingOnApps) return;
    actingOnApps = true;
    appActionMessage = null;
    notifyListeners();
    try {
      await adb.uninstallApp(serial, app.packageName);
      appStorage = await adb.appStorageUsage(serial);
      deviceSpace = await adb.storageSpace(serial, activeRootPath) ?? deviceSpace;
      appActionMessage =
          'Uninstalled ${app.displayName} (freed ~${fmtBytes(app.totalBytes)})';
      log(appActionMessage!);
    } catch (e) {
      appActionMessage = 'Uninstall failed: $e';
      log(appActionMessage!);
    } finally {
      actingOnApps = false;
      notifyListeners();
    }
  }

  /// Open an app's Settings → App Info screen on the phone.
  Future<void> openAppSettings(String serial, AppStorageEntry app) async {
    try {
      await adb.openAppSettings(serial, app.packageName);
      appActionMessage = 'Opened ${app.displayName} App Info on phone';
      notifyListeners();
    } catch (e) {
      appActionMessage = 'Could not open App Info: $e';
      notifyListeners();
    }
  }

  void setRetention(RetentionWindow v) {
    if (retention == v) return;
    retention = v;
    notifyListeners();
  }

  void setOnlyBackedUpProposals(bool v) {
    if (onlyBackedUpProposals == v) return;
    onlyBackedUpProposals = v;
    notifyListeners();
  }

  void setMinLargeBytes(int bytes) {
    if (minLargeBytes == bytes) return;
    minLargeBytes = bytes;
    notifyListeners();
  }

  void setLargeVideosOnly(bool v) {
    if (largeVideosOnly == v) return;
    largeVideosOnly = v;
    notifyListeners();
  }

  void setFolderFilter(String? folder) {
    if (folderFilter == folder) return;
    folderFilter = folder;
    notifyListeners();
  }

  List<SmartProposal> get proposals => CleanupAnalyzer.buildProposals(
        files,
        retention: retention,
        onlyAlreadyBackedUp: onlyBackedUpProposals,
      );

  List<ScannedFile> get filteredLargeFiles {
    final out = files.where((f) {
      if (f.size < minLargeBytes) return false;
      if (largeVideosOnly && !f.isVideo) return false;
      if (folderFilter != null) {
        if (folderFilter == '(root)') {
          if (f.relPath.contains('/')) return false;
        } else if (f.relPath != folderFilter &&
            !f.relPath.startsWith('$folderFilter/')) {
          return false;
        }
      }
      return true;
    }).toList();
    out.sort((a, b) => b.size.compareTo(a.size));
    return out;
  }

  List<ScannedFile> get selectedFiles =>
      [for (final f in files) if (selectedPaths.contains(f.relPath)) f];

  int get selectedBytes => selectedFiles.fold(0, (s, f) => s + f.size);
  int get selectedNotBackedUpCount =>
      selectedFiles.where((f) => !f.backedUp).length;
  int get selectedBackedUpCount => selectedFiles.length - selectedNotBackedUpCount;

  void toggleFile(String relPath) {
    if (!selectedPaths.add(relPath)) selectedPaths.remove(relPath);
    notifyListeners();
  }

  void selectFiles(Iterable<ScannedFile> items) {
    for (final f in items) {
      selectedPaths.add(f.relPath);
    }
    notifyListeners();
  }

  void deselectFiles(Iterable<ScannedFile> items) {
    for (final f in items) {
      selectedPaths.remove(f.relPath);
    }
    notifyListeners();
  }

  void clearSelection() {
    if (selectedPaths.isEmpty) return;
    selectedPaths.clear();
    notifyListeners();
  }

  bool isProposalSelected(SmartProposal p) =>
      p.files.isNotEmpty && p.files.every((f) => selectedPaths.contains(f.relPath));

  void toggleProposal(SmartProposal p) {
    if (isProposalSelected(p)) {
      deselectFiles(p.files);
    } else {
      selectFiles(p.files);
    }
  }

  /// Scan [rootPath] (e.g. `/sdcard` or `/storage/<UUID>`) and cross-reference
  /// against [backupDir] (if non-empty and mounted) so every file knows
  /// whether a matching backup already exists.
  Future<void> scan(
    String serial,
    String backupDir, {
    String rootPath = '/sdcard',
  }) async {
    if (scanning) return;
    activeRootPath = rootPath;
    scanning = true;
    scanError = null;
    lastSummary = null;
    duplicates = [];
    duplicatesScanned = false;
    selectedPaths.clear();
    notifyListeners();

    try {
      final spaceFuture = adb.storageSpace(serial, rootPath);
      final manifestFuture = adb.scanStorage(serial, rootPath);
      final localFuture = _buildLocalBackupIndex(backupDir, rootPath);
      unawaited(scanApps(serial));

      final space = await spaceFuture;
      final deviceMap = await manifestFuture;
      final (resolvedBackupDir, localIndex) = await localFuture;

      deviceSpace = space;
      _scannedSerial = serial;
      _scannedRootPath = rootPath;
      _scannedBackupDir = resolvedBackupDir;

      const toleranceSec = 2;
      final scanned = <ScannedFile>[];
      for (final e in deviceMap.entries) {
        // Match full relative path (`DCIM/Camera/a.jpg`), or suffix paths
        // (`Camera/a.jpg`) for backups where a subfolder was backed up directly.
        String? matchedLocalKey;
        FileMeta? local = localIndex[e.key];
        if (local != null) {
          matchedLocalKey = e.key;
        } else if (e.key.contains('/')) {
          final segs = e.key.split('/');
          for (var start = 1; start < segs.length - 1; start++) {
            final suffix = segs.sublist(start).join('/');
            final cand = localIndex[suffix];
            if (cand != null &&
                cand.size == e.value.size &&
                (cand.mtimeSec - e.value.mtimeSec).abs() <= toleranceSec) {
              local = cand;
              matchedLocalKey = suffix;
              break;
            }
          }
        }
        final isBacked = local != null &&
            local.size == e.value.size &&
            (local.mtimeSec - e.value.mtimeSec).abs() <= toleranceSec;
        scanned.add(ScannedFile(
          relPath: e.key,
          size: e.value.size,
          mtimeSec: e.value.mtimeSec,
          rootPath: rootPath,
          backedUp: isBacked,
          backupFilePath:
              isBacked && resolvedBackupDir != null && matchedLocalKey != null
                  ? localJoin(resolvedBackupDir, matchedLocalKey)
                  : null,
        ));
      }
      scanned.sort((a, b) => b.size.compareTo(a.size));
      files = scanned;
      folders = CleanupAnalyzer.computeFolderUsage(scanned);
      log('Space scan ($rootPath): ${scanned.length} files (${fmtBytes(scanned.fold(0, (s, f) => s + f.size))})');
    } catch (e) {
      scanError = '$e';
      log('Space scan failed: $e');
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// Build `{relPath -> FileMeta}` from the Mirror backup dir (or latest
  /// completed Snapshot folder if [backupDir] holds dated snapshots).
  /// For external storage roots (`/storage/<UUID>`), looks inside the
  /// namespaced `SD-<UUID>` subfolder if present, else falls back to the root.
  Future<(String?, Map<String, FileMeta>)> _buildLocalBackupIndex(
    String rawDest,
    String rootPath,
  ) async {
    final dest = rawDest.trim();
    if (dest.isEmpty || unmountedVolume(dest) != null) {
      return (null, const <String, FileMeta>{});
    }
    final root = Directory(dest);
    if (!await root.exists()) return (null, const <String, FileMeta>{});

    // If destination holds dated snapshot folders (YYYY-MM-DD_HHMMSS), inspect
    // the newest completed snapshot; otherwise treat dest as a Mirror root.
    final snapRe = RegExp(r'^\d{4}-\d{2}-\d{2}_\d{6}$');
    String? latestSnap;
    final topDirs = <String>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = localBaseName(e.path);
      if (snapRe.hasMatch(name)) {
        if (latestSnap == null || name.compareTo(latestSnap) > 0) {
          latestSnap = name;
        }
      } else if (!name.endsWith('.partial')) {
        topDirs.add(name);
      }
    }

    var effectiveRoot =
        latestSnap != null ? localJoin(dest, latestSnap) : dest;
    final extSubdir = externalStorageBackupSubdir(rootPath);
    if (extSubdir != null && localBaseName(effectiveRoot) != extSubdir) {
      final namespaced = localJoin(effectiveRoot, extSubdir);
      if (await Directory(namespaced).exists()) {
        effectiveRoot = namespaced;
      }
    }

    final dirsToWalk = <String>[];
    if (latestSnap != null || extSubdir != null) {
      await for (final e in Directory(effectiveRoot).list(followLinks: false)) {
        if (e is Directory) dirsToWalk.add(localBaseName(e.path));
      }
    } else {
      dirsToWalk.addAll(topDirs);
    }

    final combined = <String, FileMeta>{};
    for (final d in dirsToWalk) {
      final m = await localManifest(effectiveRoot, d);
      combined.addAll(m);
    }
    return (effectiveRoot, combined);
  }

  /// Two-stage duplicate scan: size collision filter (>= 100 KB) followed by
  /// batched on-device MD5 hashing of candidates only.
  Future<void> findDuplicates(
    String serial, {
    int minBytes = 100 * 1024,
  }) async {
    if (scanningDuplicates || files.isEmpty) return;
    scanningDuplicates = true;
    dupHashed = 0;
    dupTotalToHash = 0;
    duplicates = [];
    notifyListeners();

    try {
      final bySize = <int, List<ScannedFile>>{};
      for (final f in files) {
        if (f.size < minBytes) continue;
        (bySize[f.size] ??= []).add(f);
      }
      final candidates = <ScannedFile>[
        for (final group in bySize.values)
          if (group.length >= 2) ...group,
      ];
      dupTotalToHash = candidates.length;
      notifyListeners();

      if (candidates.isNotEmpty) {
        final hashes = await adb.md5Files(
          serial,
          [for (final c in candidates) c.absPath],
          onProgress: (done, total) {
            dupHashed = done;
            dupTotalToHash = total;
            notifyListeners();
          },
        );
        final byHash = <String, List<ScannedFile>>{};
        for (final c in candidates) {
          final h = hashes[c.absPath];
          if (h != null) (byHash[h] ??= []).add(c);
        }
        final groups = <DuplicateGroup>[
          for (final e in byHash.entries)
            if (e.value.length >= 2)
              DuplicateGroup(
                md5: e.key,
                fileSize: e.value.first.size,
                files: CleanupAnalyzer.rankDuplicateCopies(e.value),
              ),
        ];
        groups.sort((a, b) => b.wastedBytes.compareTo(a.wastedBytes));
        duplicates = groups;
      }
      duplicatesScanned = true;
      log(
        'Duplicate scan: ${duplicates.length} group(s), '
        '${fmtBytes(duplicates.fold(0, (s, g) => s + g.wastedBytes))} reclaimable',
      );
    } catch (e) {
      log('Duplicate scan failed: $e');
    } finally {
      scanningDuplicates = false;
      notifyListeners();
    }
  }

  /// Safely clean up [selectedFiles]:
  ///   1. If [backupFirst] is true, streams any not-yet-backed-up selected files
  ///      into [backupDest] via one continuous `tar -T` stream.
  ///   2. If [verifyMd5] is true (and a backup exists for each file), compares
  ///      device MD5 vs local backup MD5 before deleting — any mismatch is
  ///      skipped and kept safe on the phone.
  ///   3. Deletes verified files from `/sdcard/` and updates in-memory state.
  Future<CleanupExecutionSummary> executeCleanup({
    required String serial,
    required String backupDest,
    required bool backupFirst,
    required bool verifyMd5,
  }) async {
    final targets = selectedFiles;
    if (targets.isEmpty || executing) {
      return const CleanupExecutionSummary(
        backedUpCount: 0,
        deletedCount: 0,
        freedBytes: 0,
        skippedCount: 0,
        errors: [],
      );
    }

    executing = true;
    executionPhase = 'Preparing…';
    executionProgress = 0;
    lastSummary = null;
    notifyListeners();

    final errors = <String>[];
    var backedUpCount = 0;
    final localPathByRel = <String, String>{
      for (final f in targets)
        if (f.backedUp && f.backupFilePath != null) f.relPath: f.backupFilePath!,
    };

    try {
      // --- Step 1: Back up any not-yet-backed-up selected files ---
      final toBackUp = backupFirst
          ? targets.where((f) => !localPathByRel.containsKey(f.relPath)).toList()
          : const <ScannedFile>[];

      if (toBackUp.isNotEmpty) {
        final dest = backupDest.trim();
        if (dest.isEmpty) {
          throw StateError('Choose a backup destination folder first.');
        }
        final missingVol = unmountedVolume(dest);
        if (missingVol != null) {
          throw StateError('Drive "$missingVol" is not connected.');
        }

        executionPhase = 'Backing up ${toBackUp.length} file(s)…';
        executionProgress = 0.05;
        notifyListeners();

        final totalBackupBytes = toBackUp.fold(0, (s, f) => s + f.size);
        var streamedBytes = 0;

        final extSubdir = externalStorageBackupSubdir(activeRootPath);
        final targetBackupDir =
            extSubdir != null && localBaseName(dest) != extSubdir
                ? localJoin(dest, extSubdir)
                : dest;

        final listPath = await adb.pushLines(
          serial,
          [for (final f in toBackUp) f.relPath],
        );
        try {
          await Directory(targetBackupDir).create(recursive: true);
          final proc = await adb.startTarStreamFromList(
              serial, activeRootPath, listPath);
          final extractor = TarExtractor(targetBackupDir);
          final stderrBuf = StringBuffer();
          await Future.wait([
            proc.stdout.forEach((chunk) async {
              await extractor.add(chunk);
              streamedBytes += chunk.length;
              if (totalBackupBytes > 0) {
                executionProgress =
                    (0.05 + 0.50 * (streamedBytes / totalBackupBytes))
                        .clamp(0.05, 0.55);
                notifyListeners();
              }
            }),
            proc.stderr.transform(const SystemEncoding().decoder).forEach(stderrBuf.write),
          ]);
          await extractor.close();
          await proc.exitCode;
        } finally {
          await adb.remove(serial, listPath);
        }

        // Confirm each file landed locally with expected byte size.
        for (final f in toBackUp) {
          final dstFile = File(localJoin(targetBackupDir, f.relPath));
          if (await dstFile.exists() && await dstFile.length() == f.size) {
            localPathByRel[f.relPath] = dstFile.path;
            backedUpCount++;
          } else {
            errors.add('Backup missing or size mismatch: ${f.relPath} (kept on phone)');
          }
        }
      }

      // Decide which files are eligible for deletion.
      final eligible = <ScannedFile>[];
      var skippedCount = 0;
      for (final f in targets) {
        if (backupFirst && !localPathByRel.containsKey(f.relPath)) {
          skippedCount++;
          continue;
        }
        eligible.add(f);
      }

      // --- Step 2: Optional MD5 verification against local backup ---
      final verifiedToDelete = <ScannedFile>[];
      if (verifyMd5 && eligible.isNotEmpty) {
        // Only MD5-check files that have a local backup copy (when backupFirst
        // is false, unbacked-up files explicitly chosen by the user skip MD5).
        final toVerify =
            eligible.where((f) => localPathByRel.containsKey(f.relPath)).toList();
        final unbackedApproved =
            eligible.where((f) => !localPathByRel.containsKey(f.relPath)).toList();

        if (toVerify.isNotEmpty) {
          executionPhase = 'Verifying MD5 of ${toVerify.length} file(s)…';
          executionProgress = 0.60;
          notifyListeners();

          final deviceHashes = await adb.md5Files(
            serial,
            [for (final f in toVerify) f.absPath],
            onProgress: (done, total) {
              executionProgress = 0.60 + 0.15 * (done / total);
              notifyListeners();
            },
          );

          for (var i = 0; i < toVerify.length; i++) {
            final f = toVerify[i];
            final devHash = deviceHashes[f.absPath];
            final localFile = File(localPathByRel[f.relPath]!);
            if (devHash == null || !await localFile.exists()) {
              skippedCount++;
              errors.add('MD5 verify skipped (unreadable): ${f.relPath} (kept on phone)');
              continue;
            }
            final localDigest = await md5.bind(localFile.openRead()).first;
            if (localDigest.toString().toLowerCase() == devHash) {
              verifiedToDelete.add(f);
            } else {
              skippedCount++;
              errors.add('MD5 mismatch: ${f.relPath} (kept on phone)');
            }
            executionProgress = 0.75 + 0.10 * ((i + 1) / toVerify.length);
            notifyListeners();
          }
        }
        verifiedToDelete.addAll(unbackedApproved);
      } else {
        verifiedToDelete.addAll(eligible);
      }

      // --- Step 3: Delete verified files on phone ---
      var deletedCount = 0;
      var freedBytes = 0;
      if (verifiedToDelete.isNotEmpty) {
        executionPhase = 'Removing ${verifiedToDelete.length} file(s) from phone…';
        executionProgress = 0.86;
        notifyListeners();

        final failedAbs = (await adb.deleteDeviceFiles(
          serial,
          [for (final f in verifiedToDelete) f.absPath],
          onProgress: (done, total) {
            executionProgress = 0.86 + 0.14 * (done / total);
            notifyListeners();
          },
        ))
            .toSet();

        final deletedRels = <String>{};
        for (final f in verifiedToDelete) {
          if (failedAbs.contains(f.absPath)) {
            skippedCount++;
            errors.add('Could not delete: ${f.relPath}');
          } else {
            deletedRels.add(f.relPath);
            deletedCount++;
            freedBytes += f.size;
          }
        }

        // Update in-memory scan state immediately.
        files = [for (final f in files) if (!deletedRels.contains(f.relPath)) f];
        // Also mark newly backed-up files that were skipped as backed up.
        files = [
          for (final f in files)
            localPathByRel.containsKey(f.relPath) && !f.backedUp
                ? f.copyWith(
                    backedUp: true,
                    backupFilePath: localPathByRel[f.relPath],
                  )
                : f,
        ];
        folders = CleanupAnalyzer.computeFolderUsage(files);
        duplicates = [
          for (final g in duplicates)
            if (g.files.where((f) => !deletedRels.contains(f.relPath)).length >= 2)
              DuplicateGroup(
                md5: g.md5,
                fileSize: g.fileSize,
                files: g.files
                    .where((f) => !deletedRels.contains(f.relPath))
                    .toList(),
              ),
        ];
        selectedPaths.removeAll(deletedRels);
        deviceSpace = await adb.storageSpace(serial, activeRootPath);
      }

      final summary = CleanupExecutionSummary(
        backedUpCount: backedUpCount,
        deletedCount: deletedCount,
        freedBytes: freedBytes,
        skippedCount: skippedCount,
        errors: errors,
      );
      lastSummary = summary;
      log(
        'Cleanup finished: freed ${fmtBytes(freedBytes)} '
        '($deletedCount removed, $backedUpCount backed up, $skippedCount skipped)',
      );
      return summary;
    } catch (e) {
      errors.add('$e');
      final summary = CleanupExecutionSummary(
        backedUpCount: backedUpCount,
        deletedCount: 0,
        freedBytes: 0,
        skippedCount: targets.length,
        errors: errors,
      );
      lastSummary = summary;
      log('Cleanup failed: $e');
      return summary;
    } finally {
      executing = false;
      executionPhase = '';
      executionProgress = 0;
      notifyListeners();
    }
  }
}
