import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'adb_client.dart';
import 'manifest.dart';
import 'models.dart';
import 'os.dart';
import 'settings.dart';

/// Direction of a selective folder sync pair.
enum SyncMode {
  /// Computer → Phone: pushes new/updated local files to the phone.
  pushToPhone,

  /// Phone → Computer: pulls new/updated device files to the computer.
  pullToComputer,

  /// Computer ↔ Phone: bidirectional sync using a saved baseline manifest
  /// with non-destructive conflict copies when both sides edit the same file.
  twoWay,
}

extension SyncModeLabel on SyncMode {
  String get label => switch (this) {
        SyncMode.pushToPhone => 'Push → Phone',
        SyncMode.pullToComputer => '← Pull to Computer',
        SyncMode.twoWay => '⇄ Two-Way Sync',
      };

  String get shortLabel => switch (this) {
        SyncMode.pushToPhone => 'Push → Phone',
        SyncMode.pullToComputer => 'Pull ← Phone',
        SyncMode.twoWay => 'Two-Way',
      };

  String get description => switch (this) {
        SyncMode.pushToPhone =>
          'Best for Music, Books, or Podcasts — new and edited files on your computer are pushed automatically to your phone.',
        SyncMode.pullToComputer =>
          'Mirrors new and edited files from the phone folder into your computer folder.',
        SyncMode.twoWay =>
          'Best for Obsidian vaults, Notes, or Docs — syncs edits both ways and keeps conflict copies if both sides changed the same file.',
      };
}

/// Configuration for one local ↔ phone synchronized folder pair.
class SyncPair {
  final String id;
  String name;
  String localPath;
  String devicePath;
  SyncMode mode;

  /// Whether deletions propagate to the opposite side. Off by default for safety.
  bool propagateDeletes;

  /// Automatically sync this pair when the phone connects (USB or Wi-Fi).
  bool autoSyncOnConnect;

  /// Optional hardware/ADB serial restriction; null = any connected phone.
  String? deviceSerial;

  /// Last successful sync timestamp.
  DateTime? lastSyncAt;

  /// Human-readable summary of the last run (e.g. `Pushed 8 · Pulled 2`).
  String? lastSummary;

  SyncPair({
    required this.id,
    required this.name,
    required this.localPath,
    required this.devicePath,
    this.mode = SyncMode.pushToPhone,
    this.propagateDeletes = false,
    this.autoSyncOnConnect = false,
    this.deviceSerial,
    this.lastSyncAt,
    this.lastSummary,
  });

  String get cleanDevicePath {
    var p = devicePath.trim().replaceAll('\\', '/');
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'localPath': localPath,
        'devicePath': cleanDevicePath,
        'mode': mode.name,
        'propagateDeletes': propagateDeletes,
        'autoSyncOnConnect': autoSyncOnConnect,
        if (deviceSerial != null && deviceSerial!.isNotEmpty)
          'deviceSerial': deviceSerial,
        if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toIso8601String(),
        if (lastSummary != null && lastSummary!.isNotEmpty)
          'lastSummary': lastSummary,
      };

  static SyncPair fromJson(Map<String, dynamic> j) => SyncPair(
        id: (j['id'] as String?) ??
            'sync_${DateTime.now().microsecondsSinceEpoch}',
        name: (j['name'] as String?) ?? 'Synced Folder',
        localPath: (j['localPath'] as String?) ?? '',
        devicePath: (j['devicePath'] as String?) ?? '/sdcard/Documents',
        mode: SyncMode.values.asNameMap()[j['mode']] ?? SyncMode.pushToPhone,
        propagateDeletes: j['propagateDeletes'] as bool? ?? false,
        autoSyncOnConnect: j['autoSyncOnConnect'] as bool? ?? false,
        deviceSerial: j['deviceSerial'] as String?,
        lastSyncAt: j['lastSyncAt'] is String
            ? DateTime.tryParse(j['lastSyncAt'] as String)
            : null,
        lastSummary: j['lastSummary'] as String?,
      );
}

class SyncFileEntry {
  final String relPath;
  final int size;
  final int mtimeSec;

  const SyncFileEntry({
    required this.relPath,
    required this.size,
    required this.mtimeSec,
  });
}

class SyncConflict {
  final String relPath;
  final SyncFileEntry local;
  final SyncFileEntry device;

  /// Relative path where the phone's version is preserved alongside the
  /// computer's version so neither edit is lost.
  final String conflictRelPath;

  const SyncConflict({
    required this.relPath,
    required this.local,
    required this.device,
    required this.conflictRelPath,
  });
}

/// Preview / execution plan produced by [SyncEngine.computePlan].
class SyncPlan {
  final SyncPair pair;
  final List<SyncFileEntry> toPush;
  final List<SyncFileEntry> toPull;
  final List<SyncFileEntry> toDeleteOnDevice;
  final List<SyncFileEntry> toDeleteLocal;
  final List<SyncConflict> conflicts;
  final int unchangedCount;
  final int totalKnownFiles;
  final Map<String, FileMeta> localManifest;
  final Map<String, FileMeta> deviceManifest;

  const SyncPlan({
    required this.pair,
    required this.toPush,
    required this.toPull,
    required this.toDeleteOnDevice,
    required this.toDeleteLocal,
    required this.conflicts,
    required this.unchangedCount,
    required this.totalKnownFiles,
    this.localManifest = const {},
    this.deviceManifest = const {},
  });

  int get totalDeletes => toDeleteOnDevice.length + toDeleteLocal.length;

  int get totalActions =>
      toPush.length +
      toPull.length +
      toDeleteOnDevice.length +
      toDeleteLocal.length +
      conflicts.length;

  bool get isEmpty => totalActions == 0;

  int get totalBytesToTransfer =>
      toPush.fold<int>(0, (s, e) => s + e.size) +
      toPull.fold<int>(0, (s, e) => s + e.size) +
      conflicts.fold<int>(0, (s, c) => s + c.local.size + c.device.size);

  /// Safety guardrail: prompt the user if a sync would delete >= 5 files AND
  /// more than 20% of the tracked folder (prevents accidental mass wipe if an
  /// external drive or empty folder is mounted in the wrong place).
  bool get requiresDeleteConfirmation =>
      totalDeletes >= 5 &&
      totalKnownFiles > 0 &&
      (totalDeletes / totalKnownFiles) > 0.20;

  String summary() {
    if (isEmpty) return 'Already in sync ($unchangedCount files)';
    final parts = <String>[
      if (toPush.isNotEmpty) '${toPush.length} to push',
      if (toPull.isNotEmpty) '${toPull.length} to pull',
      if (conflicts.isNotEmpty)
        '${conflicts.length} conflict${conflicts.length == 1 ? '' : 's'}',
      if (toDeleteOnDevice.isNotEmpty)
        '${toDeleteOnDevice.length} delete on phone',
      if (toDeleteLocal.isNotEmpty) '${toDeleteLocal.length} delete locally',
    ];
    return parts.join(' · ');
  }
}

class SyncResult {
  final int pushed;
  final int pulled;
  final int deletedOnDevice;
  final int deletedLocal;
  final int conflictsResolved;
  final List<String> errors;
  final bool cancelled;

  const SyncResult({
    this.pushed = 0,
    this.pulled = 0,
    this.deletedOnDevice = 0,
    this.deletedLocal = 0,
    this.conflictsResolved = 0,
    this.errors = const [],
    this.cancelled = false,
  });

  bool get ok => errors.isEmpty && !cancelled;

  String summary() {
    if (cancelled) return 'Cancelled';
    final parts = <String>[
      if (pushed > 0) 'Pushed $pushed',
      if (pulled > 0) 'Pulled $pulled',
      if (conflictsResolved > 0)
        '$conflictsResolved conflict${conflictsResolved == 1 ? '' : 's'} kept both',
      if (deletedOnDevice > 0) 'Removed $deletedOnDevice on phone',
      if (deletedLocal > 0) 'Removed $deletedLocal locally',
    ];
    if (parts.isEmpty) {
      return errors.isEmpty ? 'Already in sync' : '${errors.length} error(s)';
    }
    if (errors.isNotEmpty) parts.add('${errors.length} error(s)');
    return parts.join(' · ');
  }
}

/// Pure manifest diffing & conflict-naming helpers for selective folder sync.
class SyncEngine {
  static const int mtimeToleranceSec = 2;

  static bool isIgnoredFile(String relPath) {
    for (final seg in relPath.split('/')) {
      final lower = seg.toLowerCase();
      if (lower == '.ds_store' ||
          lower == 'thumbs.db' ||
          lower == 'desktop.ini' ||
          lower.startsWith('._') ||
          lower == '.thumbnails') {
        return true;
      }
    }
    return false;
  }

  static bool _sameFile(FileMeta a, FileMeta b) =>
      a.size == b.size && (a.mtimeSec - b.mtimeSec).abs() <= mtimeToleranceSec;

  /// Build a non-destructive conflict filename:
  /// `notes/todo.md` → `notes/todo (phone-conflict 2026-11-28).md`.
  static String conflictPathFor(String relPath, DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)}';
    final slash = relPath.lastIndexOf('/');
    final dir = slash == -1 ? '' : relPath.substring(0, slash + 1);
    final name = slash == -1 ? relPath : relPath.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      final stem = name.substring(0, dot);
      final ext = name.substring(dot);
      return '$dir$stem (phone-conflict $stamp)$ext';
    }
    return '$dir$name (phone-conflict $stamp)';
  }

  /// Scan all regular files inside [localRootDir], keyed by POSIX relative path
  /// (`sub/file.txt`). Returns `{}` if [localRootDir] does not exist yet.
  static Future<Map<String, FileMeta>> scanLocalFolder(
    String localRootDir,
  ) async {
    final root = Directory(localRootDir);
    if (!await root.exists()) return {};
    final out = <String, FileMeta>{};
    final rootPath = root.path.replaceAll('\\', '/');
    final prefix = rootPath.endsWith('/') ? rootPath : '$rootPath/';
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final normalized = entity.path.replaceAll('\\', '/');
      if (!normalized.startsWith(prefix)) continue;
      final rel = normalized.substring(prefix.length);
      if (rel.isEmpty || isIgnoredFile(rel)) continue;
      final stat = await entity.stat();
      out[rel] = FileMeta(
        stat.size,
        stat.modified.millisecondsSinceEpoch ~/ 1000,
      );
    }
    return out;
  }

  /// Compute a [SyncPlan] purely from [local], [device], and the previous
  /// [baseline] manifest.
  static SyncPlan computePlan({
    required SyncPair pair,
    required Map<String, FileMeta> local,
    required Map<String, FileMeta> device,
    Map<String, FileMeta> baseline = const {},
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    final filteredLocal = {
      for (final e in local.entries)
        if (!isIgnoredFile(e.key)) e.key: e.value,
    };
    final filteredDevice = {
      for (final e in device.entries)
        if (!isIgnoredFile(e.key)) e.key: e.value,
    };
    final allKeys = <String>{
      ...filteredLocal.keys,
      ...filteredDevice.keys,
    }.toList()
      ..sort();

    final toPush = <SyncFileEntry>[];
    final toPull = <SyncFileEntry>[];
    final toDeleteOnDevice = <SyncFileEntry>[];
    final toDeleteLocal = <SyncFileEntry>[];
    final conflicts = <SyncConflict>[];
    var unchanged = 0;

    for (final rel in allKeys) {
      final loc = filteredLocal[rel];
      final dev = filteredDevice[rel];
      final base = baseline[rel];

      switch (pair.mode) {
        case SyncMode.pushToPhone:
          if (loc != null && dev == null) {
            toPush.add(SyncFileEntry(
              relPath: rel,
              size: loc.size,
              mtimeSec: loc.mtimeSec,
            ));
          } else if (loc != null && dev != null) {
            if (_sameFile(loc, dev)) {
              unchanged++;
            } else {
              toPush.add(SyncFileEntry(
                relPath: rel,
                size: loc.size,
                mtimeSec: loc.mtimeSec,
              ));
            }
          } else if (loc == null && dev != null) {
            if (pair.propagateDeletes) {
              toDeleteOnDevice.add(SyncFileEntry(
                relPath: rel,
                size: dev.size,
                mtimeSec: dev.mtimeSec,
              ));
            } else {
              unchanged++;
            }
          }

        case SyncMode.pullToComputer:
          if (dev != null && loc == null) {
            toPull.add(SyncFileEntry(
              relPath: rel,
              size: dev.size,
              mtimeSec: dev.mtimeSec,
            ));
          } else if (dev != null && loc != null) {
            if (_sameFile(loc, dev)) {
              unchanged++;
            } else {
              toPull.add(SyncFileEntry(
                relPath: rel,
                size: dev.size,
                mtimeSec: dev.mtimeSec,
              ));
            }
          } else if (dev == null && loc != null) {
            if (pair.propagateDeletes) {
              toDeleteLocal.add(SyncFileEntry(
                relPath: rel,
                size: loc.size,
                mtimeSec: loc.mtimeSec,
              ));
            } else {
              unchanged++;
            }
          }

        case SyncMode.twoWay:
          if (loc != null && dev != null) {
            if (_sameFile(loc, dev)) {
              unchanged++;
            } else if (base == null) {
              // First two-way sync where both sides already have different
              // versions of the same file — keep both safely.
              conflicts.add(SyncConflict(
                relPath: rel,
                local: SyncFileEntry(
                  relPath: rel,
                  size: loc.size,
                  mtimeSec: loc.mtimeSec,
                ),
                device: SyncFileEntry(
                  relPath: rel,
                  size: dev.size,
                  mtimeSec: dev.mtimeSec,
                ),
                conflictRelPath: conflictPathFor(rel, ts),
              ));
            } else {
              final locChanged = !_sameFile(loc, base);
              final devChanged = !_sameFile(dev, base);
              if (locChanged && !devChanged) {
                toPush.add(SyncFileEntry(
                  relPath: rel,
                  size: loc.size,
                  mtimeSec: loc.mtimeSec,
                ));
              } else if (devChanged && !locChanged) {
                toPull.add(SyncFileEntry(
                  relPath: rel,
                  size: dev.size,
                  mtimeSec: dev.mtimeSec,
                ));
              } else {
                conflicts.add(SyncConflict(
                  relPath: rel,
                  local: SyncFileEntry(
                    relPath: rel,
                    size: loc.size,
                    mtimeSec: loc.mtimeSec,
                  ),
                  device: SyncFileEntry(
                    relPath: rel,
                    size: dev.size,
                    mtimeSec: dev.mtimeSec,
                  ),
                  conflictRelPath: conflictPathFor(rel, ts),
                ));
              }
            }
          } else if (loc != null && dev == null) {
            if (base == null) {
              // Newly created locally → push to phone.
              toPush.add(SyncFileEntry(
                relPath: rel,
                size: loc.size,
                mtimeSec: loc.mtimeSec,
              ));
            } else if (!_sameFile(loc, base)) {
              // Edited locally after being deleted on phone → preserve edit.
              toPush.add(SyncFileEntry(
                relPath: rel,
                size: loc.size,
                mtimeSec: loc.mtimeSec,
              ));
            } else if (pair.propagateDeletes) {
              // Unchanged locally and deleted on phone → propagate deletion.
              toDeleteLocal.add(SyncFileEntry(
                relPath: rel,
                size: loc.size,
                mtimeSec: loc.mtimeSec,
              ));
            } else {
              // Delete protection on: leave local copy intact without re-pushing.
              unchanged++;
            }
          } else if (loc == null && dev != null) {
            if (base == null) {
              // Newly created on phone → pull to computer.
              toPull.add(SyncFileEntry(
                relPath: rel,
                size: dev.size,
                mtimeSec: dev.mtimeSec,
              ));
            } else if (!_sameFile(dev, base)) {
              // Edited on phone after being deleted locally → preserve edit.
              toPull.add(SyncFileEntry(
                relPath: rel,
                size: dev.size,
                mtimeSec: dev.mtimeSec,
              ));
            } else if (pair.propagateDeletes) {
              // Unchanged on phone and deleted locally → propagate deletion.
              toDeleteOnDevice.add(SyncFileEntry(
                relPath: rel,
                size: dev.size,
                mtimeSec: dev.mtimeSec,
              ));
            } else {
              unchanged++;
            }
          }
      }
    }

    final knownTotal = baseline.isNotEmpty
        ? baseline.length
        : (filteredLocal.length > filteredDevice.length
            ? filteredLocal.length
            : filteredDevice.length);

    return SyncPlan(
      pair: pair,
      toPush: toPush,
      toPull: toPull,
      toDeleteOnDevice: toDeleteOnDevice,
      toDeleteLocal: toDeleteLocal,
      conflicts: conflicts,
      unchangedCount: unchanged,
      totalKnownFiles: knownTotal,
      localManifest: filteredLocal,
      deviceManifest: filteredDevice,
    );
  }
}

/// Manages selective folder sync pairs, baseline persistence, previews,
/// execution, and auto-sync-on-connect.
class SyncController extends ChangeNotifier {
  final AdbClient adb;
  final Settings settings;
  final void Function(String) log;
  final Directory? stateDirOverride;

  final Map<String, SyncPlan> previews = {};
  final Map<String, SyncResult> lastResults = {};
  final Map<String, DateTime> _autoSyncCooldown = {};

  String? activePairId;
  bool scanning = false;
  bool running = false;
  String statusText = '';
  int doneItems = 0;
  int totalItems = 0;
  bool _cancelRequested = false;

  SyncController({
    required this.adb,
    required this.settings,
    required this.log,
    this.stateDirOverride,
  });

  List<SyncPair> get pairs => settings.syncPairs;
  bool get busy => scanning || running;

  double get progress =>
      totalItems <= 0 ? 0 : (doneItems / totalItems).clamp(0.0, 1.0);

  void addPair(SyncPair pair) {
    settings.syncPairs.add(pair);
    unawaited(settings.save());
    log('Added sync pair "${pair.name}" (${pair.mode.shortLabel})');
    notifyListeners();
  }

  void updatePair(SyncPair updated) {
    final idx = settings.syncPairs.indexWhere((p) => p.id == updated.id);
    if (idx >= 0) {
      settings.syncPairs[idx] = updated;
      previews.remove(updated.id);
      unawaited(settings.save());
      notifyListeners();
    }
  }

  Future<void> removePair(String id) async {
    settings.syncPairs.removeWhere((p) => p.id == id);
    previews.remove(id);
    lastResults.remove(id);
    unawaited(settings.save());
    try {
      final f = _baselineFile(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    notifyListeners();
  }

  void cancel() {
    if (!busy) return;
    _cancelRequested = true;
    statusText = 'Cancelling…';
    notifyListeners();
  }

  File _baselineFile(String pairId) {
    final safeId = pairId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final base = stateDirOverride?.path ?? localJoin(appDataDir(), 'sync_state');
    return File(localJoin(base, '$safeId.json'));
  }

  Future<Map<String, FileMeta>> _loadBaseline(String pairId) async {
    try {
      final f = _baselineFile(pairId);
      if (!await f.exists()) return {};
      final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final out = <String, FileMeta>{};
      for (final e in raw.entries) {
        final v = e.value;
        if (v is Map<String, dynamic>) {
          out[e.key] = FileMeta(
            (v['s'] as num?)?.toInt() ?? 0,
            (v['m'] as num?)?.toInt() ?? 0,
          );
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveBaseline(String pairId, Map<String, FileMeta> map) async {
    if (stateDirOverride == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    final f = _baselineFile(pairId);
    await f.parent.create(recursive: true);
    final payload = jsonEncode({
      for (final e in map.entries)
        e.key: {'s': e.value.size, 'm': e.value.mtimeSec},
    });
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(f.path);
  }

  /// Scan local and phone folders and produce a dry-run [SyncPlan].
  Future<SyncPlan?> previewPair(SyncPair pair, String serial) async {
    if (busy) return null;
    if (pair.localPath.trim().isEmpty || pair.cleanDevicePath.isEmpty) {
      return null;
    }
    scanning = true;
    activePairId = pair.id;
    statusText = 'Scanning ${pair.name}…';
    _cancelRequested = false;
    notifyListeners();

    try {
      final results = await Future.wait([
        SyncEngine.scanLocalFolder(pair.localPath),
        adb.folderManifest(serial, pair.cleanDevicePath),
        _loadBaseline(pair.id),
      ]);
      final local = results[0];
      final device = results[1];
      final baseline = results[2];
      final plan = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        baseline: baseline,
      );
      previews[pair.id] = plan;
      log('Sync preview "${pair.name}": ${plan.summary()}');
      return plan;
    } catch (e) {
      log('Sync preview failed for "${pair.name}": $e');
      return null;
    } finally {
      scanning = false;
      activePairId = null;
      statusText = '';
      notifyListeners();
    }
  }

  /// Execute a sync pair (computing a fresh plan if [plan] is not supplied).
  Future<SyncResult?> runPair(
    SyncPair pair,
    String serial, {
    SyncPlan? plan,
    bool allowLargeDeletes = false,
  }) async {
    if (busy) return null;
    if (pair.localPath.trim().isEmpty || pair.cleanDevicePath.isEmpty) {
      return null;
    }
    final unmounted = unmountedVolume(pair.localPath);
    if (unmounted != null) {
      log('Sync skipped "${pair.name}": drive "$unmounted" is not connected');
      return const SyncResult(errors: ['Destination drive is not connected']);
    }

    final effectivePlan = plan ?? await previewPair(pair, serial);
    if (effectivePlan == null) return null;

    if (effectivePlan.requiresDeleteConfirmation && !allowLargeDeletes) {
      log('Sync paused "${pair.name}": ${effectivePlan.totalDeletes} deletes '
          'exceed safety threshold — please confirm manually.');
      return null;
    }

    if (effectivePlan.isEmpty) {
      final res = const SyncResult();
      pair.lastSyncAt = DateTime.now();
      pair.lastSummary = res.summary();
      lastResults[pair.id] = res;
      previews.remove(pair.id);
      await _saveBaseline(pair.id, effectivePlan.localManifest);
      unawaited(settings.save());
      notifyListeners();
      return res;
    }

    running = true;
    activePairId = pair.id;
    doneItems = 0;
    totalItems = effectivePlan.totalActions;
    statusText = 'Syncing ${pair.name}…';
    _cancelRequested = false;
    notifyListeners();

    final isWireless = AdbClient.isWireless(serial);
    if (isWireless) {
      unawaited(adb.setWifiHighPerf(serial, true));
    }

    var pushed = 0;
    var pulled = 0;
    var deletedOnDevice = 0;
    var deletedLocal = 0;
    var conflictsResolved = 0;
    final errors = <String>[];
    final createdDeviceDirs = <String>{};
    final baseline = Map<String, FileMeta>.from(effectivePlan.localManifest);
    final devRoot = pair.cleanDevicePath;

    Future<void> ensureDevParent(String absDevicePath) async {
      final dir = AdbClient.dirname(absDevicePath);
      if (createdDeviceDirs.add(dir)) {
        await adb.ensureDeviceDir(serial, dir);
      }
    }

    try {
      // Ensure both root folders exist before transferring.
      await Directory(pair.localPath).create(recursive: true);
      if (effectivePlan.toPush.isNotEmpty ||
          effectivePlan.conflicts.isNotEmpty) {
        if (createdDeviceDirs.add(devRoot)) {
          await adb.ensureDeviceDir(serial, devRoot);
        }
      }

      // 1. Push files (computer → phone)
      for (final f in effectivePlan.toPush) {
        if (_cancelRequested) break;
        statusText = 'Pushing ${f.relPath}';
        notifyListeners();
        final localFile = localJoin(pair.localPath, f.relPath);
        final deviceFile = '$devRoot/${f.relPath}';
        try {
          await ensureDevParent(deviceFile);
          await adb.pushFile(serial, localFile, deviceFile);
          pushed++;
          baseline[f.relPath] = FileMeta(f.size, f.mtimeSec);
        } catch (e) {
          errors.add('Push ${f.relPath}: $e');
        }
        doneItems++;
        notifyListeners();
      }

      // 2. Pull files (phone → computer)
      for (final f in effectivePlan.toPull) {
        if (_cancelRequested) break;
        statusText = 'Pulling ${f.relPath}';
        notifyListeners();
        final localFile = localJoin(pair.localPath, f.relPath);
        final deviceFile = '$devRoot/${f.relPath}';
        try {
          await File(localFile).parent.create(recursive: true);
          await adb.pullFile(serial, deviceFile, localFile);
          pulled++;
          final st = await File(localFile).stat();
          baseline[f.relPath] = FileMeta(
            st.size,
            st.modified.millisecondsSinceEpoch ~/ 1000,
          );
        } catch (e) {
          errors.add('Pull ${f.relPath}: $e');
        }
        doneItems++;
        notifyListeners();
      }

      // 3. Conflicts (keep BOTH versions safely)
      for (final c in effectivePlan.conflicts) {
        if (_cancelRequested) break;
        statusText = 'Keeping both copies of ${c.relPath}';
        notifyListeners();
        final localOrig = localJoin(pair.localPath, c.relPath);
        final localConflict = localJoin(pair.localPath, c.conflictRelPath);
        final devOrig = '$devRoot/${c.relPath}';
        final devConflict = '$devRoot/${c.conflictRelPath}';
        try {
          await File(localConflict).parent.create(recursive: true);
          await adb.pullFile(serial, devOrig, localConflict);
          await ensureDevParent(devOrig);
          await adb.pushFile(serial, localOrig, devOrig);
          await ensureDevParent(devConflict);
          await adb.pushFile(serial, localConflict, devConflict);
          conflictsResolved++;
          baseline[c.relPath] = FileMeta(c.local.size, c.local.mtimeSec);
          final st = await File(localConflict).stat();
          baseline[c.conflictRelPath] = FileMeta(
            st.size,
            st.modified.millisecondsSinceEpoch ~/ 1000,
          );
        } catch (e) {
          errors.add('Conflict ${c.relPath}: $e');
        }
        doneItems++;
        notifyListeners();
      }

      // 4. Optional delete propagation on phone (safety-fenced via AdbClient)
      if (!_cancelRequested && effectivePlan.toDeleteOnDevice.isNotEmpty) {
        statusText =
            'Removing ${effectivePlan.toDeleteOnDevice.length} file(s) on phone…';
        notifyListeners();
        final absPaths = [
          for (final f in effectivePlan.toDeleteOnDevice) '$devRoot/${f.relPath}',
        ];
        final failed = await adb.deleteDeviceFiles(serial, absPaths);
        final failedSet = failed.toSet();
        for (final f in effectivePlan.toDeleteOnDevice) {
          final abs = '$devRoot/${f.relPath}';
          if (failedSet.contains(abs)) {
            errors.add('Delete on phone failed: ${f.relPath}');
          } else {
            deletedOnDevice++;
            baseline.remove(f.relPath);
          }
          doneItems++;
        }
        notifyListeners();
      }

      // 5. Optional delete propagation locally
      for (final f in effectivePlan.toDeleteLocal) {
        if (_cancelRequested) break;
        statusText = 'Removing local ${f.relPath}';
        notifyListeners();
        final localFile = File(localJoin(pair.localPath, f.relPath));
        try {
          if (await localFile.exists()) await localFile.delete();
          deletedLocal++;
          baseline.remove(f.relPath);
        } catch (e) {
          errors.add('Delete local ${f.relPath}: $e');
        }
        doneItems++;
        notifyListeners();
      }

      // Persist updated baseline for two-way tracking (re-stat device/local
      // intersection cleanly by recording what succeeded).
      await _saveBaseline(pair.id, baseline);

      final result = SyncResult(
        pushed: pushed,
        pulled: pulled,
        deletedOnDevice: deletedOnDevice,
        deletedLocal: deletedLocal,
        conflictsResolved: conflictsResolved,
        errors: errors,
        cancelled: _cancelRequested,
      );
      lastResults[pair.id] = result;
      previews.remove(pair.id);
      if (!result.cancelled) {
        pair.lastSyncAt = DateTime.now();
        pair.lastSummary = result.summary();
        unawaited(settings.save());
      }
      log('Sync "${pair.name}" finished: ${result.summary()}');
      return result;
    } finally {
      if (isWireless) {
        unawaited(adb.setWifiHighPerf(serial, false));
      }
      running = false;
      activePairId = null;
      statusText = '';
      notifyListeners();
    }
  }

  /// Automatically sync all pairs opted in to `autoSyncOnConnect` for [device].
  /// Skips any pair whose plan triggers the large-delete safety guardrail so
  /// an unattended connect can never wipe a folder.
  Future<void> runAutoSyncForDevice(AdbDevice device) async {
    if (!device.isReady || busy) return;
    final now = DateTime.now();
    final eligible = [
      for (final p in pairs)
        if (p.autoSyncOnConnect &&
            (p.deviceSerial == null ||
                p.deviceSerial!.isEmpty ||
                p.deviceSerial == device.serial))
          p,
    ];
    for (final p in eligible) {
      final key = '${p.id}|${device.serial}';
      final last = _autoSyncCooldown[key];
      if (last != null && now.difference(last) < const Duration(minutes: 5)) {
        continue;
      }
      _autoSyncCooldown[key] = now;
      final plan = await previewPair(p, device.serial);
      if (plan == null || plan.isEmpty) continue;
      if (plan.requiresDeleteConfirmation) {
        log('Auto-sync skipped "${p.name}": large delete requires manual confirmation');
        continue;
      }
      await runPair(p, device.serial, plan: plan);
    }
  }
}
