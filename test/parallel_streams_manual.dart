// Measures the effect of parallel tar streams against a real connected
// device, and md5-verifies that a sharded transfer lands intact. NOT part of
// the default suite (no _test suffix); run explicitly:
//   flutter test test/parallel_streams_manual.dart   (ADB=<path> if not on PATH)
//
// Creates /sdcard/AndroidFilesBench on the device and removes it afterwards.
// Wireless transports are the interesting case — over USB the engine always
// uses one stream, so both runs here will report the same speed.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

final adbPath = Platform.environment['ADB'] ?? 'adb';
const deviceDir = '/sdcard/AndroidFilesBench';

/// 8x25 MB + 50x1 MB — big files to saturate the link, small ones to expose
/// per-file overhead.
const bigFiles = 8;
const bigMb = 25;
const smallFiles = 50;

Future<void> sh(AdbClient adb, String serial, String cmd,
    {Duration timeout = const Duration(minutes: 5)}) async {
  final p = await Process.start(adbPath, ['-s', serial, 'shell', cmd]);
  final err = await p.stderr.transform(const SystemEncoding().decoder).join();
  await p.stdout.drain<void>();
  final exit = await p.exitCode.timeout(timeout);
  expect(exit, 0, reason: '$cmd → $err');
}

int localBytes(String root) => Directory(root)
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .fold(0, (sum, f) => sum + f.lengthSync());

int localCount(String root) => Directory(root)
    .listSync(recursive: true, followLinks: false)
    .whereType<File>()
    .length;

void main() async {
  final adb = AdbClient(adbPath);
  final devices = await adb.devices();
  if (devices.isEmpty || !devices.first.isReady) {
    print('SKIP: no device connected');
    return;
  }
  final serial = devices.first.serial;
  final wireless = AdbClient.isWireless(serial);
  final scratch = Directory.systemTemp.createTempSync('af_bench_');
  final entry =
      RemoteEntry(name: 'AndroidFilesBench', path: deviceDir, isDir: true);

  setUpAll(() async {
    print('Device $serial (${wireless ? 'wireless' : 'USB'}) — staging '
        '${bigFiles * bigMb + smallFiles} MB on the phone…');
    await sh(adb, serial, 'rm -rf $deviceDir && mkdir -p $deviceDir/sub');
    await sh(
        adb,
        serial,
        'for i in \$(seq $bigFiles); do '
        'dd if=/dev/zero of=$deviceDir/big\$i.bin bs=1048576 count=$bigMb '
        '2>/dev/null; done');
    await sh(
        adb,
        serial,
        'for i in \$(seq $smallFiles); do '
        'dd if=/dev/zero of=$deviceDir/sub/small\$i.bin bs=1048576 count=1 '
        '2>/dev/null; done');
  });

  tearDownAll(() async {
    await sh(adb, serial, 'rm -rf $deviceDir');
    scratch.deleteSync(recursive: true);
  });

  /// Full transfer through the file-list path: an empty base makes every file
  /// "changed", which is what the engine shards.
  Future<(double seconds, BackupJob job)> run(int streams) async {
    final dest = Directory('${scratch.path}\\s$streams')..createSync();
    final engine = BackupEngine(adb,
        log: (m) => print('  [log] $m'), parallelStreams: streams);
    final job = BackupJob(
      source: entry,
      serial: serial,
      destDir: dest.path,
      baseDir: dest.path, // empty → everything counts as changed
      incremental: true,
    );
    final sw = Stopwatch()..start();
    engine.enqueue(job);
    while (!job.status.isTerminal) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    sw.stop();
    expect(job.status, isNot(JobStatus.failed), reason: job.error ?? '');
    return (sw.elapsedMilliseconds / 1000.0, job);
  }

  test('parallel streams move the same bytes, faster', () async {
    final expectedFiles = bigFiles + smallFiles;
    final expectedBytes = (bigFiles * bigMb + smallFiles) * 1024 * 1024;

    final (oneSec, oneJob) = await run(1);
    final oneDir = '${scratch.path}\\s1';
    expect(localCount(oneDir), expectedFiles);
    expect(localBytes(oneDir), expectedBytes);

    final (manySec, manyJob) = await run(8);
    final manyDir = '${scratch.path}\\s8';
    expect(localCount(manyDir), expectedFiles,
        reason: 'sharded transfer lost files');
    expect(localBytes(manyDir), expectedBytes,
        reason: 'sharded transfer lost bytes');
    expect(manyJob.warnings, isEmpty);

    final mb = expectedBytes / (1024 * 1024);
    print('\n  1 stream : ${oneSec.toStringAsFixed(1)}s '
        '(${(mb / oneSec).toStringAsFixed(1)} MB/s)');
    print('  8 streams: ${manySec.toStringAsFixed(1)}s '
        '(${(mb / manySec).toStringAsFixed(1)} MB/s)  '
        '${(oneSec / manySec).toStringAsFixed(2)}x\n');

    // Byte-for-byte proof that sharding didn't corrupt or interleave anything.
    final engine =
        BackupEngine(adb, log: (m) => print('  [verify] $m'), parallelStreams: 8);
    await engine.deepVerify(manyJob);
    expect(manyJob.deepVerified, isTrue,
        reason: 'md5 mismatch after a sharded transfer');

    expect(oneJob.status, isNot(JobStatus.failed));
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('a plain full backup is sharded too, not just incremental', () async {
    final dest = Directory('${scratch.path}\\full')..createSync();
    final logs = <String>[];
    final engine = BackupEngine(adb, log: logs.add, parallelStreams: 8);
    final job = BackupJob(source: entry, serial: serial, destDir: dest.path);
    engine.enqueue(job);
    while (!job.status.isTerminal) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(job.status, isNot(JobStatus.failed), reason: job.error ?? '');
    expect(localCount(dest.path), bigFiles + smallFiles);
    expect(localBytes(dest.path), (bigFiles * bigMb + smallFiles) * 1024 * 1024);
    if (wireless) {
      expect(logs.any((l) => l.contains('parallel streams')), isTrue,
          reason: 'full wireless backup fell back to a single stream');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('cancel stops every shard, not just the first', () async {
    final dest = Directory('${scratch.path}\\cancel')..createSync();
    final engine = BackupEngine(adb,
        log: (m) => print('  [log] $m'), parallelStreams: 8);
    final job = BackupJob(
      source: entry,
      serial: serial,
      destDir: dest.path,
      baseDir: dest.path,
      incremental: true,
    );
    engine.enqueue(job);
    // Let the streams get going, then pull the plug mid-transfer.
    while (job.doneBytes < 8 * 1024 * 1024) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(job.status, isNot(JobStatus.failed), reason: job.error ?? '');
    }
    job.cancel();
    while (!job.status.isTerminal) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(job.status, JobStatus.cancelled);

    // If any shard were still running, the destination would keep growing.
    final settled = localBytes(dest.path);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(localBytes(dest.path), settled,
        reason: 'a shard survived the cancel and kept writing');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('pause halts every shard and resume restarts them all', () async {
    final dest = Directory('${scratch.path}\\pause')..createSync();
    final engine = BackupEngine(adb,
        log: (m) => print('  [log] $m'), parallelStreams: 8);
    final job = BackupJob(
      source: entry,
      serial: serial,
      destDir: dest.path,
      baseDir: dest.path,
      incremental: true,
    );
    engine.enqueue(job);
    while (job.doneBytes < 8 * 1024 * 1024) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(job.status, isNot(JobStatus.failed), reason: job.error ?? '');
    }
    job.pause();
    expect(job.paused, isTrue);
    // Each stream stalls within a buffer's worth of data rather than instantly,
    // so let them coast to a stop before sampling.
    await Future<void>.delayed(const Duration(seconds: 3));
    final stalled = job.doneBytes;
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(job.doneBytes, stalled, reason: 'a shard ignored the pause');

    job.resume();
    while (!job.status.isTerminal) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(job.status, isNot(JobStatus.failed), reason: job.error ?? '');
    expect(job.doneBytes, greaterThan(stalled), reason: 'resume did not restart');
    expect(localCount(dest.path), bigFiles + smallFiles);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
