import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

  /// Glob patterns (see manifest.dart) whose files are pruned from this backup.
  /// Empty = keep everything.
  final List<String> ignore;

  /// Run a deep (md5) verify automatically once this backup finishes.
  final bool autoVerify;

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
  int ignoredFiles = 0;
  int hashedFiles = 0;
  int verifiedFiles = 0;

  /// Bytes processed / total in the active deep-verify phase, for a
  /// byte-weighted ETA (a big file is far more work than a small one). Both 0
  /// when file sizes couldn't be fetched, in which case the ETA falls back to
  /// the per-file term alone (see [verifyEtaSeconds]).
  int verifyDoneBytes = 0;
  int verifyTotalBytes = 0;

  /// Start of the current deep-verify phase (device hashing, then local
  /// checking); reset at each phase boundary so the ETA reflects that phase's
  /// own rate rather than a blended average across both.
  DateTime? verifyPhaseStart;

  /// Set once a deep (md5) verify has passed for this job.
  bool deepVerified = false;
  int linkedFiles = 0;
  String? currentFile;
  String? error;
  final List<String> warnings = [];

  /// Every adb process this job currently owns. Sharded transfers run one
  /// tar stream per shard, so cancelling has to reach all of them.
  final List<Process> _procs = [];
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
    this.ignore = const [],
    this.autoVerify = false,
    this.localSource,
  });

  double get progress => totalBytes <= 0 ? 0 : (doneBytes / totalBytes).clamp(0.0, 1.0);

  /// Estimated seconds remaining, or null while the speed is still settling.
  double? get etaSeconds {
    if (bytesPerSec < 1 || totalBytes <= 0) return null;
    final remaining = totalBytes - doneBytes;
    return remaining <= 0 ? 0 : remaining / bytesPerSec;
  }

  /// Estimated seconds remaining in the active deep-verify phase.
  ///
  /// Work is modelled as `bytes + perFile·fileCount`, not a plain file count:
  /// verify time is dominated by the bytes hashed/read, but each file also
  /// carries a fixed cost (open, md5 init, and on the device a `find`/exec
  /// round trip), so a run of many tiny files is slower per byte than one big
  /// one. Projecting the measured work-rate over the remaining work handles
  /// both. When sizes are unavailable the byte terms are 0 and only the
  /// per-file term survives — i.e. it degrades to the old files/sec estimate.
  double? get verifyEtaSeconds {
    final start = verifyPhaseStart;
    if (start == null || deviceFileCount <= 0) return null;
    // verifiedFiles>0 means we're in the local-check pass; else still hashing.
    final filesDone = verifiedFiles > 0 ? verifiedFiles : hashedFiles;
    if (filesDone <= 0) return null;
    final elapsed = DateTime.now().difference(start).inMilliseconds / 1000.0;
    if (elapsed < 1) return null;
    const perFile = 256 * 1024; // bytes-equivalent of one file's fixed cost
    final doneWork = verifyDoneBytes + filesDone * perFile;
    final totalWork = verifyTotalBytes + deviceFileCount * perFile;
    final remaining = totalWork - doneWork;
    if (remaining <= 0) return 0;
    if (doneWork <= 0) return null;
    return remaining / (doneWork / elapsed);
  }

  void cancel() {
    _cancelRequested = true;
    for (final p in _procs) {
      p.kill();
    }
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

/// Runs backup jobs one at a time. Within a job, a wireless transfer is split
/// across several concurrent tar streams (see [_streamCount]); running whole
/// jobs in parallel instead would make progress and ETA meaningless.
class BackupEngine extends ChangeNotifier {
  final AdbClient adb;
  final void Function(String) log;

  /// Concurrent tar streams to use for a wireless transfer. 1 disables
  /// sharding entirely; see [_streamCount] for why 8 is the default and why
  /// USB ignores this.
  int parallelStreams;

  final List<BackupJob> jobs = [];
  bool _running = false;
  final Map<String, bool> _tarSupport = {};

  /// Fired whenever the queue empties after having run at least one job.
  void Function()? onDrained;

  /// Forces the adb-pull path even when the device has tar (for tests).
  @visibleForTesting
  bool forcePullFallback = false;

  BackupEngine(this.adb, {required this.log, this.parallelStreams = 8});

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
          if (next.autoVerify &&
              (next.status == JobStatus.done ||
                  next.status == JobStatus.doneWithWarnings)) {
            await deepVerify(next);
          }
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
      job._procs.add(proc);
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
      job._procs.clear();
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
    final deviceLists = <String>[];
    try {
      job._set(JobStatus.measuring);
      log('Measuring $src…');

      final ignore = compileIgnorePatterns(job.ignore);

      List<String>? changed; // null → full whole-folder transfer
      var unchanged = const <String>[];
      var localOnly = const <String>[];
      // Sizes of the device-side files, kept for size-balanced sharding.
      var sizes = const <String, FileMeta>{};
      if (job.incremental && job.baseDir != null) {
        final deviceMan = await adb.manifest(job.serial, src);
        if (ignore.isNotEmpty) {
          final before = deviceMan.length;
          deviceMan.removeWhere((rel, _) => isIgnored(rel, ignore));
          job.ignoredFiles = before - deviceMan.length;
        }
        job.deviceFileCount = deviceMan.length;
        sizes = deviceMan;
        final localMan = await localManifest(job.baseDir!, job.source.name);
        final diff = diffManifests(deviceMan, localMan);
        changed = diff.changed;
        unchanged = diff.unchanged;
        localOnly = diff.localOnly;
        job.skippedFiles = unchanged.length;
        job.totalBytes =
            changed.fold(0, (sum, rel) => sum + (deviceMan[rel]?.size ?? 0));
        log('$src: ${changed.length} changed, ${unchanged.length} unchanged'
            '${localOnly.isEmpty ? '' : ', ${localOnly.length} local-only'}'
            '${job.ignoredFiles > 0 ? ', ${job.ignoredFiles} ignored' : ''}');
      } else if (ignore.isNotEmpty || _canShard(job.serial)) {
        // Full backup that needs the file list up front: clutter pruning
        // drops ignored files so they never leave the device, and a wireless
        // transfer needs it to split the files across parallel streams.
        // Either way the survivors go through the file-list path incremental
        // uses.
        final deviceMan = await adb.manifest(job.serial, src);
        final before = deviceMan.length;
        deviceMan.removeWhere((rel, _) => isIgnored(rel, ignore));
        job.ignoredFiles = before - deviceMan.length;
        changed = deviceMan.keys.toList();
        sizes = deviceMan;
        job.deviceFileCount = deviceMan.length;
        job.totalBytes = deviceMan.values.fold(0, (sum, m) => sum + m.size);
        log('$src: ${changed.length} files'
            '${job.ignoredFiles > 0 ? ', ${job.ignoredFiles} ignored' : ''}');
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

      if (changed == null) {
        log('Backing up $src → ${job.destDir} '
            '(${_fmtBytes(job.totalBytes)}, ${job.deviceFileCount} files)');
        if (tarOk) {
          // Whole-folder transfers can't be sharded without enumerating the
          // tree first; one stream tars the directory as a unit.
          final proc = await adb.startTarStream(job.serial, src);
          if (!await _streamTars(job, [proc])) return;
        } else {
          log('$src: device has no tar — falling back to adb pull (slower)');
          await _pullTree(job, src);
        }
      } else if (changed.isNotEmpty) {
        final shards = shardByBytes(
            changed, sizes, _streamCount(job.serial, changed.length, job.totalBytes));
        log('Transferring ${changed.length} changed file(s), '
            '${_fmtBytes(job.totalBytes)} → ${job.destDir}'
            '${shards.length > 1 ? ' over ${shards.length} parallel streams' : ''}');
        final procs = <Process>[];
        try {
          for (final shard in shards) {
            final list = await adb.pushLines(job.serial, shard);
            deviceLists.add(list);
            procs.add(await adb.startTarStreamFromList(
                job.serial, AdbClient.dirname(src), list));
          }
        } catch (_) {
          // Don't strand streams that already started on the phone.
          for (final p in procs) {
            p.kill();
          }
          rethrow;
        }
        if (!await _streamTars(job, procs)) return;
      } else if (!pulledWithoutTar) {
        log('$src: nothing changed since last backup');
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
      for (final list in deviceLists) {
        unawaited(adb.remove(job.serial, list).catchError((_) {}));
      }
      job._procs.clear();
    }
  }

  /// Stream device-side tar output into [job.destDir], reading every process
  /// in [procs] concurrently. Each stream carries a disjoint set of files and
  /// gets its own extractor; they share the job's byte and speed accounting.
  ///
  /// Returns false when the job ended here (cancelled or failed) and its
  /// status is already set — the caller must stop.
  Future<bool> _streamTars(BackupJob job, List<Process> procs) async {
    final src = job.source.path;
    job._procs.addAll(procs);
    if (job._cancelRequested) {
      // cancel() can land while the shards are still being launched, when it
      // has nothing yet to kill. Catch up here rather than draining streams
      // for a job that's already been called off.
      for (final p in procs) {
        p.kill();
      }
    }
    final stderrs = [for (final p in procs) _collect(p.stderr)];
    // Native extraction: Windows bsdtar mangles UTF-8 names from ustar
    // headers (ANSI codepage), which breaks non-ASCII filenames and with
    // them every future incremental compare.
    final extractors = [for (final _ in procs) TarExtractor(job.destDir)];

    final sw = Stopwatch()..start();
    var lastNotify = 0;
    var windowStartMs = 0;
    var windowStartBytes = 0;
    job._pausable = true;

    // Whichever stream just delivered a chunk updates the shared readouts;
    // the speed window measures the job's aggregate throughput, not one
    // stream's share of it.
    void account(TarExtractor extractor) {
      job.currentFile = extractor.currentPath;
      var written = 0;
      for (final e in extractors) {
        written += e.filesWritten;
      }
      job.filesStreamed = written;
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

    Future<void> drain(int i) async {
      final extractor = extractors[i];
      await for (final chunk in procs[i].stdout) {
        if (job.paused) {
          job.bytesPerSec = 0;
          job._tick();
          while (job.paused && !job._cancelRequested) {
            // All streams wait on the same gate, so one resume() releases
            // every one of them.
            await (job._resumeGate ??= Completer<void>()).future;
          }
          // Restart the speed window so the pause doesn't skew the ETA.
          windowStartMs = sw.elapsedMilliseconds;
          windowStartBytes = job.doneBytes;
        }
        job.doneBytes += chunk.length;
        await extractor.add(chunk);
        account(extractor);
      }
      await extractor.close();
    }

    final failures = <Object>[];
    await Future.wait([
      for (var i = 0; i < procs.length; i++)
        drain(i).catchError((Object e) {
          failures.add(e);
          // A dead extractor means the rest are filling a destination we're
          // about to abandon; stop the phone sending.
          for (final p in procs) {
            p.kill();
          }
        }),
    ]);
    job._pausable = false;

    final exits = await Future.wait([for (final p in procs) p.exitCode]);
    final deviceErrors = (await Future.wait(stderrs))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join('; ');

    // Keep extractor findings (e.g. removed incomplete file) visible even on
    // cancelled jobs.
    for (final e in extractors) {
      job.warnings.addAll(e.warnings);
    }
    if (job._cancelRequested) {
      log('Cancelled $src — completed files are intact');
      for (final e in extractors) {
        for (final w in e.warnings) {
          log('  $w');
        }
      }
      job._set(JobStatus.cancelled);
      return false;
    }
    if (failures.isNotEmpty) {
      job.error = 'Extraction failed: ${failures.first}';
      log('FAILED $src — ${job.error}');
      job._set(JobStatus.failed);
      return false;
    }
    final failed = exits.where((e) => e != 0).toList();
    if (failed.isNotEmpty || deviceErrors.isNotEmpty) {
      // Device tar keeps streaming past unreadable files; record, continue.
      job.warnings.add('Device-side messages: $deviceErrors '
          '(exit ${failed.isEmpty ? 0 : failed.first})');
    }
    return true;
  }

  /// Whether transfers to [serial] may be split across parallel streams at
  /// all: sharding is on and the transport is wireless.
  bool _canShard(String serial) =>
      parallelStreams > 1 && AdbClient.isWireless(serial);

  /// How many tar streams to run in parallel for a transfer of [fileCount]
  /// files totalling [totalBytes].
  ///
  /// A single adb stream over Wi-Fi is latency-bound — it sits idle waiting
  /// for acks rather than saturating the link — so independent streams
  /// multiply throughput. Measured on Wi-Fi 6 (Pixel 8, 5 GHz, -43 dBm):
  /// 5.8 MB/s at 1 stream, 9.3 at 2, 14.0 at 4, 20.0 at 8, 21.1 at 16. It
  /// plateaus past 8, so more streams only add list-push overhead.
  ///
  /// USB stays single-stream: it already runs at 25-40 MB/s, where the
  /// bottleneck is storage on one end or the other, not the transport.
  int _streamCount(String serial, int fileCount, int totalBytes) {
    if (!_canShard(serial)) return 1;
    // Each shard costs a list push and a process launch — not worth it for a
    // handful of files or a few MB.
    if (fileCount < 2 || totalBytes < 4 * 1024 * 1024) return 1;
    return math.max(1, math.min(math.min(parallelStreams, 16), fileCount));
  }

  /// Split [rels] into [count] shards of roughly equal total bytes.
  ///
  /// Longest-processing-time-first: each file in descending size order goes to
  /// the lightest shard so far. Splitting by file count instead would hand one
  /// stream every video in the folder while the others finished early and sat
  /// idle — the transfer is only as fast as its heaviest shard.
  static List<List<String>> shardByBytes(
      List<String> rels, Map<String, FileMeta> sizes, int count) {
    if (count <= 1) return [rels];
    final ordered = List.of(rels)
      ..sort((a, b) => (sizes[b]?.size ?? 0).compareTo(sizes[a]?.size ?? 0));
    final shards = List.generate(count, (_) => <String>[]);
    final load = List.filled(count, 0);
    for (final rel in ordered) {
      var lightest = 0;
      for (var i = 1; i < count; i++) {
        if (load[i] < load[lightest]) lightest = i;
      }
      shards[lightest].add(rel);
      load[lightest] += sizes[rel]?.size ?? 0;
    }
    // Fewer files than shards, or sizes unavailable — drop the empties rather
    // than launching a tar that would emit nothing.
    shards.removeWhere((s) => s.isEmpty);
    return shards;
  }

  /// Full-tree `adb pull` fallback. Progress comes from pull's own
  /// "[ 42%] path" output (carriage-return separated).
  Future<void> _pullTree(BackupJob job, String src) async {
    final proc = await adb.startPull(job.serial, src, job.destDir);
    job._procs.add(proc);
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
      // File sizes for a byte-weighted ETA — a metadata-only pass, negligible
      // next to hashing every byte twice. If it fails the ETA falls back to a
      // per-file estimate (see verifyEtaSeconds), so don't let it abort verify.
      Map<String, FileMeta> sizes = const {};
      try {
        sizes = await adb.manifest(job.serial, src);
      } catch (_) {}
      // Total for the progress bar during the device-side hashing pass.
      job.deviceFileCount = sizes.isNotEmpty
          ? sizes.length
          : await adb.fileCount(job.serial, src);
      job.hashedFiles = 0;
      job.verifiedFiles = 0;
      job.verifyDoneBytes = 0;
      // Hashing runs over every file (no ignore), so weight it by every size.
      job.verifyTotalBytes = sizes.values.fold(0, (s, m) => s + m.size);
      job.verifyPhaseStart = DateTime.now(); // device-hashing phase begins
      final device = await adb.md5Manifest(
        job.serial,
        src,
        onProgress: (n, rel) {
          job.hashedFiles = n;
          if (rel != null) job.verifyDoneBytes += sizes[rel]?.size ?? 0;
          job._tick();
        },
      );
      // Don't flag files the backup deliberately left out (clutter/excluded) as
      // "missing locally" — verify only what was meant to be copied.
      final ignore = compileIgnorePatterns(job.ignore);
      if (ignore.isNotEmpty) {
        device.removeWhere((rel, _) => isIgnored(rel, ignore));
      }
      job.deviceFileCount = device.length;
      // The local-check pass only touches the kept files: re-weight to those.
      job.verifyDoneBytes = 0;
      job.verifyTotalBytes =
          device.keys.fold(0, (s, k) => s + (sizes[k]?.size ?? 0));
      job.verifyPhaseStart = DateTime.now(); // local-checking phase begins
      var mismatched = 0;
      var missing = 0;
      var lastTick = DateTime.now();
      for (final e in device.entries) {
        final f = File('${job.destDir}\\${e.key.replaceAll('/', '\\')}');
        job.currentFile = e.key;
        job.verifiedFiles++;
        job._tick();
        if (!await f.exists()) {
          missing++;
          job.warnings.add('verify: missing locally: ${e.key}');
          // Nothing to read; still count its share so progress can reach 100%.
          job.verifyDoneBytes += sizes[e.key]?.size ?? 0;
          continue;
        }
        // Hash in chunks, crediting bytes as they're actually read (and
        // ticking at most ~10×/s). Crediting the whole file up-front made the
        // ETA lurch: it counted the work before spending the time on it.
        final input = md5.startChunkedConversion(
          ChunkedConversionSink<Digest>.withCallback((digests) {
            if (digests.single.toString() != e.value) {
              mismatched++;
              job.warnings.add('verify: md5 mismatch: ${e.key}');
            }
          }),
        );
        await for (final chunk in f.openRead()) {
          input.add(chunk);
          job.verifyDoneBytes += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastTick).inMilliseconds >= 100) {
            lastTick = now;
            job._tick();
          }
        }
        input.close();
      }
      job.currentFile = null;
      job.deepVerified = mismatched == 0 && missing == 0;
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
    job.hashedFiles = 0;
    job.verifiedFiles = 0;
    job.verifyPhaseStart = null;
    job.deepVerified = false;
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
