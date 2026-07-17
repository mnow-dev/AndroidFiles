import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'adb_client.dart';
import 'manifest.dart';
import 'models.dart';
import 'tar_extractor.dart';
import 'win_links.dart';

class BackupJob extends ChangeNotifier {
  final RemoteEntry source;
  final String serial;

  /// Where this job extracts to (mirror: the destination itself;
  /// snapshot: the new timestamped folder).
  final String destDir;

  /// Previous copy to compare against for incremental mode (mirror: same as
  /// [destDir]; snapshot: the latest previous snapshot; null: no base → full).
  final String? baseDir;

  final bool incremental;

  /// When set, this job PUSHES [localSource] to the device folder
  /// [source.path] instead of backing up (drop-to-restore).
  final String? localSource;

  bool get isRestore => localSource != null;

  JobStatus status = JobStatus.queued;
  int totalBytes = 0;
  int doneBytes = 0;
  double bytesPerSec = 0;
  int deviceFileCount = -1;
  int localFileCount = -1;
  int filesStreamed = 0;
  int skippedFiles = 0;
  int linkedFiles = 0;
  String? currentFile;
  String? error;
  final List<String> warnings = [];

  Process? _adbProc;
  bool _cancelRequested = false;

  /// Pause works by not reading the tar stream — backpressure stalls the
  /// device within a buffer's worth of data. Only tar-stream transfers
  /// support it (adb pull/push manage their own I/O).
  bool paused = false;
  bool _pausable = false;
  Completer<void>? _resumeGate;

  bool get canPause => _pausable && status == JobStatus.running;

  void pause() {
    if (!canPause || paused) return;
    paused = true;
    _resumeGate = Completer<void>();
    notifyListeners();
  }

  void resume() {
    if (!paused) return;
    paused = false;
    _resumeGate?.complete();
    _resumeGate = null;
    notifyListeners();
  }

  BackupJob({
    required this.source,
    required this.serial,
    required this.destDir,
    this.baseDir,
    this.incremental = false,
    this.localSource,
  });

  double get progress => totalBytes <= 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0);

  /// Estimated seconds remaining, or null while the speed is still settling.
  double? get etaSeconds {
    if (bytesPerSec < 1 || totalBytes <= 0) return null;
    final remaining = totalBytes - doneBytes;
    return remaining <= 0 ? 0 : remaining / bytesPerSec;
  }

  void cancel() {
    _cancelRequested = true;
    _adbProc?.kill();
    // Unblock a paused stream loop so it can observe the cancellation.
    paused = false;
    _resumeGate?.complete();
    _resumeGate = null;
  }

  void _set(JobStatus s) {
    status = s;
    notifyListeners();
  }

  void _tick() => notifyListeners();
}

/// Runs backup jobs sequentially (USB is the bottleneck; parallel streams
/// just fight each other).
class BackupEngine extends ChangeNotifier {
  final AdbClient adb;
  final void Function(String) log;

  final List<BackupJob> jobs = [];
  bool _running = false;
  final Map<String, bool> _tarSupport = {};

  /// Fired whenever the queue empties after having run at least one job.
  void Function()? onDrained;

  /// Forces the adb-pull path even when the device has tar (for tests).
  @visibleForTesting
  bool forcePullFallback = false;

  BackupEngine(this.adb, {required this.log});

  bool get isRunning => _running;

  void enqueue(BackupJob job) {
    jobs.add(job);
    notifyListeners();
    _pump();
  }

  void clearFinished() {
    jobs.removeWhere((j) => j.status.isTerminal);
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    var ran = 0;
    try {
      while (true) {
        BackupJob? next;
        for (final j in jobs) {
          if (j.status == JobStatus.queued) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        ran++;
        if (next.isRestore) {
          await _runRestoreJob(next);
        } else {
          await _runJob(next);
        }
      }
    } finally {
      _running = false;
      notifyListeners();
      if (ran > 0) onDrained?.call();
    }
  }

  /// Push a local file/folder back to the device folder [job.source.path].
  Future<void> _runRestoreJob(BackupJob job) async {
    final local = job.localSource!;
    final target = job.source.path;
    try {
      job._set(JobStatus.measuring);
      job.totalBytes = await _localSize(local);
      job._set(JobStatus.running);
      log('Restoring $local → $target (${_fmtBytes(job.totalBytes)})');

      final proc = await Process.start(
          adb.adbPath, ['-s', job.serial, 'push', local, target]);
      job._adbProc = proc;
      final progressRe = RegExp(r'\[\s*(\d+)%\]\s+(.+)');
      final err = StringBuffer();
      void watch(String text) {
        for (final line in text.split(RegExp(r'[\r\n]+'))) {
          final m = progressRe.firstMatch(line.trim());
          if (m == null) continue;
          job.doneBytes = job.totalBytes * int.parse(m.group(1)!) ~/ 100;
          job.currentFile = m.group(2);
        }
        job._tick();
      }

      await Future.wait([
        proc.stdout.transform(utf8.decoder).forEach(watch),
        proc.stderr.transform(utf8.decoder).forEach((s) {
          err.write(s);
          watch(s);
        }),
      ]);
      final exit = await proc.exitCode;
      if (job._cancelRequested) {
        job.warnings.add('The phone may hold an incomplete copy of the last '
            'file — re-run the restore to overwrite it.');
        log('Cancelled restore of $local — ${job.warnings.last}');
        return job._set(JobStatus.cancelled);
      }
      if (exit != 0) {
        job.error = 'adb push failed ($exit): ${err.toString().trim()}';
        log('FAILED restore $local — ${job.error}');
        return job._set(JobStatus.failed);
      }
      job.doneBytes = job.totalBytes;
      log('DONE restore $local → $target');
      job._set(JobStatus.done);
    } catch (e) {
      job.error = e.toString();
      log('FAILED restore $local — $e');
      job._set(JobStatus.failed);
    } finally {
      job._adbProc = null;
    }
  }

  static Future<int> _localSize(String path) async {
    final f = File(path);
    if (await f.exists()) return f.length();
    var total = 0;
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> _runJob(BackupJob job) async {
    final src = job.source.path;
    String? deviceList;
    try {
      job._set(JobStatus.measuring);
      log('Measuring $src…');

      List<String>? changed; // null → full (non-incremental) transfer
      var unchanged = const <String>[];
      var localOnly = const <String>[];
      if (job.incremental && job.baseDir != null) {
        final deviceMan = await adb.manifest(job.serial, src);
        job.deviceFileCount = deviceMan.length;
        final localMan = await localManifest(job.baseDir!, job.source.name);
        final diff = diffManifests(deviceMan, localMan);
        changed = diff.changed;
        unchanged = diff.unchanged;
        localOnly = diff.localOnly;
        job.skippedFiles = unchanged.length;
        job.totalBytes =
            changed.fold(0, (sum, rel) => sum + (deviceMan[rel]?.size ?? 0));
        log('$src: ${changed.length} changed, ${unchanged.length} unchanged'
            '${localOnly.isEmpty ? '' : ', ${localOnly.length} local-only'}');
      } else {
        job.totalBytes = await adb.sizeOf(job.serial, src);
        job.deviceFileCount = await adb.fileCount(job.serial, src);
      }
      if (job._cancelRequested) return job._set(JobStatus.cancelled);

      await Directory(job.destDir).create(recursive: true);
      job._set(JobStatus.running);

      final tarOk = !forcePullFallback &&
          (_tarSupport[job.serial] ??= await adb.hasTar(job.serial));
      var pulledWithoutTar = false;
      if (!tarOk && changed != null && changed.isNotEmpty) {
        // No device tar: pull the changed files one by one instead.
        log('$src: device has no tar — pulling ${changed.length} changed '
            'file(s) via adb pull (slower)');
        await _pullFiles(job, AdbClient.dirname(src), changed);
        changed = const [];
        pulledWithoutTar = true;
      }

      Process? adbProc;
      if (changed == null) {
        log('Backing up $src → ${job.destDir} '
            '(${_fmtBytes(job.totalBytes)}, ${job.deviceFileCount} files)');
        if (tarOk) {
          adbProc = await adb.startTarStream(job.serial, src);
        } else {
          log('$src: device has no tar — falling back to adb pull (slower)');
          await _pullTree(job, src);
        }
      } else if (changed.isNotEmpty) {
        log('Transferring ${changed.length} changed file(s), '
            '${_fmtBytes(job.totalBytes)} → ${job.destDir}');
        deviceList = await adb.pushLines(job.serial, changed);
        adbProc = await adb.startTarStreamFromList(
            job.serial, AdbClient.dirname(src), deviceList);
      } else if (!pulledWithoutTar) {
        log('$src: nothing changed since last backup');
      }

      if (adbProc != null) {
        job._adbProc = adbProc;
        final adbStderr = _collect(adbProc.stderr);
        // Native extraction: Windows bsdtar mangles UTF-8 names from ustar
        // headers (ANSI codepage), which breaks non-ASCII filenames and
        // with them every future incremental compare.
        final extractor = TarExtractor(job.destDir);

        final sw = Stopwatch()..start();
        var lastNotify = 0;
        var windowStartMs = 0;
        var windowStartBytes = 0;
        job._pausable = true;
        try {
          await for (final chunk in adbProc.stdout) {
            if (job.paused) {
              job.bytesPerSec = 0;
              job._tick();
              while (job.paused && !job._cancelRequested) {
                await (job._resumeGate ??= Completer<void>()).future;
              }
              // Restart the speed window so the pause doesn't skew the ETA.
              windowStartMs = sw.elapsedMilliseconds;
              windowStartBytes = job.doneBytes;
            }
            job.doneBytes += chunk.length;
            await extractor.add(chunk);
            job.currentFile = extractor.currentPath;
            job.filesStreamed = extractor.filesWritten;
            final now = sw.elapsedMilliseconds;
            if (now - windowStartMs >= 1000) {
              final instant =
                  (job.doneBytes - windowStartBytes) * 1000 / (now - windowStartMs);
              // Exponential smoothing keeps the MB/s and ETA readouts steady.
              job.bytesPerSec = job.bytesPerSec == 0
                  ? instant
                  : 0.25 * instant + 0.75 * job.bytesPerSec;
              windowStartMs = now;
              windowStartBytes = job.doneBytes;
            }
            if (now - lastNotify >= 200) {
              lastNotify = now;
              job._tick();
            }
          }
          await extractor.close();
          job._pausable = false;
        } catch (e) {
          job._pausable = false;
          adbProc.kill();
          if (!job._cancelRequested) {
            job.error = 'Extraction failed: $e';
            log('FAILED $src — ${job.error}');
            return job._set(JobStatus.failed);
          }
        }

        final adbExit = await adbProc.exitCode;
        final deviceErrors = (await adbStderr).trim();

        // Keep extractor findings (e.g. removed incomplete file) visible
        // even on cancelled jobs.
        job.warnings.addAll(extractor.warnings);
        if (job._cancelRequested) {
          log('Cancelled $src — completed files are intact');
          for (final w in extractor.warnings) {
            log('  $w');
          }
          return job._set(JobStatus.cancelled);
        }
        if (adbExit != 0 || deviceErrors.isNotEmpty) {
          // Device tar keeps streaming past unreadable files; record, continue.
          job.warnings.add('Device-side messages: $deviceErrors (exit $adbExit)');
        }
      }

      // Snapshot layout: materialize unchanged files from the previous
      // snapshot as hardlinks (no extra disk space, instant).
      if (unchanged.isNotEmpty && job.baseDir != job.destDir) {
        job._set(JobStatus.verifying);
        log('Linking ${unchanged.length} unchanged file(s) from previous snapshot…');
        for (final rel in unchanged) {
          if (job._cancelRequested) return job._set(JobStatus.cancelled);
          final win = rel.replaceAll('/', '\\');
          try {
            await hardLinkOrCopy('${job.baseDir}\\$win', '${job.destDir}\\$win');
            job.linkedFiles++;
          } catch (e) {
            job.warnings.add('Could not link $rel: $e');
          }
          if (job.linkedFiles % 100 == 0) job._tick();
        }
      }

      job._set(JobStatus.verifying);
      final localRoot = '${job.destDir}${Platform.pathSeparator}${job.source.name}';
      job.localFileCount = await _countLocalFiles(localRoot);
      if (job.deviceFileCount >= 0 && job.localFileCount < job.deviceFileCount) {
        job.warnings.add(
            'File count mismatch: device ${job.deviceFileCount}, local ${job.localFileCount}');
      } else if (localOnly.isNotEmpty) {
        log('$src: kept ${localOnly.length} file(s) no longer on the device');
      }

      if (job.warnings.isEmpty) {
        final linked = job.linkedFiles > 0 ? ', ${job.linkedFiles} linked' : '';
        final skipped = job.skippedFiles > 0 ? ', ${job.skippedFiles} unchanged' : '';
        log('DONE $src — ${job.localFileCount} files locally '
            '(${_fmtBytes(job.doneBytes)} transferred$skipped$linked)');
        job._set(JobStatus.done);
      } else {
        for (final w in job.warnings) {
          log('WARN $src — $w');
        }
        job._set(JobStatus.doneWithWarnings);
      }
    } catch (e) {
      job.error = e.toString();
      log('FAILED $src — $e');
      job._set(JobStatus.failed);
    } finally {
      if (deviceList != null) {
        unawaited(adb.remove(job.serial, deviceList).catchError((_) {}));
      }
      job._adbProc = null;
    }
  }

  /// Full-tree `adb pull` fallback. Progress comes from pull's own
  /// "[ 42%] path" output (carriage-return separated).
  Future<void> _pullTree(BackupJob job, String src) async {
    final proc = await adb.startPull(job.serial, src, job.destDir);
    job._adbProc = proc;
    final progressRe = RegExp(r'\[\s*(\d+)%\]\s+(.+)');
    void watch(String text) {
      for (final line in text.split(RegExp(r'[\r\n]+'))) {
        final m = progressRe.firstMatch(line.trim());
        if (m == null) continue;
        job.doneBytes = job.totalBytes * int.parse(m.group(1)!) ~/ 100;
        job.currentFile = m.group(2);
      }
      job._tick();
    }

    final err = StringBuffer();
    await Future.wait([
      proc.stdout.transform(utf8.decoder).forEach(watch),
      proc.stderr.transform(utf8.decoder).forEach((s) {
        err.write(s);
        watch(s);
      }),
    ]);
    final exit = await proc.exitCode;
    if (job._cancelRequested) return;
    if (exit != 0) {
      throw AdbException('adb pull failed ($exit): ${err.toString().trim()}');
    }
    job.doneBytes = job.totalBytes;
  }

  /// Per-file `adb pull` for incremental runs on tar-less devices.
  Future<void> _pullFiles(BackupJob job, String parent, List<String> rels) async {
    for (final rel in rels) {
      if (job._cancelRequested) return;
      final destFile = '${job.destDir}\\${rel.replaceAll('/', '\\')}';
      await Directory(File(destFile).parent.path).create(recursive: true);
      final r = await Process.run(
          adb.adbPath, ['-s', job.serial, 'pull', '-a', '$parent/$rel', destFile]);
      if (r.exitCode != 0) {
        job.warnings.add('pull $rel failed: ${r.stderr.toString().trim()}');
      } else {
        job.filesStreamed++;
      }
      job.currentFile = rel;
      job._tick();
    }
  }

  /// Compare md5 of every device file against the local copy of a finished
  /// job. Slow (reads all data on both sides) but definitive.
  Future<void> deepVerify(BackupJob job) async {
    if (!job.status.isTerminal || job.status == JobStatus.failed) return;
    final src = job.source.path;
    job._set(JobStatus.verifying);
    log('Deep verify (md5) of $src — this reads every byte, hang on…');
    try {
      final device = await adb.md5Manifest(job.serial, src);
      var mismatched = 0;
      var missing = 0;
      for (final e in device.entries) {
        final f = File('${job.destDir}\\${e.key.replaceAll('/', '\\')}');
        job.currentFile = e.key;
        job._tick();
        if (!await f.exists()) {
          missing++;
          job.warnings.add('verify: missing locally: ${e.key}');
          continue;
        }
        final local = (await md5.bind(f.openRead()).first).toString();
        if (local != e.value) {
          mismatched++;
          job.warnings.add('verify: md5 mismatch: ${e.key}');
        }
      }
      job.currentFile = null;
      if (mismatched == 0 && missing == 0) {
        log('VERIFIED $src — all ${device.length} files match (md5)');
        job._set(JobStatus.done);
      } else {
        log('VERIFY FAILED $src — $mismatched mismatched, $missing missing '
            'of ${device.length}');
        job._set(JobStatus.doneWithWarnings);
      }
    } catch (e) {
      job.warnings.add('deep verify failed: $e');
      log('Deep verify of $src failed: $e');
      job._set(JobStatus.doneWithWarnings);
    }
  }

  void retry(BackupJob job) {
    if (!job.status.isTerminal) return;
    job.doneBytes = 0;
    job.bytesPerSec = 0;
    job.currentFile = null;
    job.filesStreamed = 0;
    job.skippedFiles = 0;
    job.linkedFiles = 0;
    job.error = null;
    job.warnings.clear();
    job._cancelRequested = false;
    job.paused = false;
    job._pausable = false;
    job._set(JobStatus.queued);
    _pump();
  }

  static Future<String> _collect(Stream<List<int>> s) =>
      s.transform(utf8.decoder).join();

  static Future<int> _countLocalFiles(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) {
      // Single-file backup: tar extracts the file directly.
      return await File(root).exists() ? 1 : 0;
    }
    var n = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) n++;
    }
    return n;
  }
}

String _fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
  return '$b B';
}

String fmtBytes(int b) => _fmtBytes(b);

String fmtSpeed(double bps) => '${(bps / (1 << 20)).toStringAsFixed(1)} MB/s';

String fmtEta(double? seconds) {
  if (seconds == null || !seconds.isFinite) return '';
  final s = seconds.round();
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  if (s >= 60) return '${s ~/ 60}m ${s % 60}s';
  return '${s}s';
}
