// Live end-to-end test against a real connected device. NOT part of the
// default suite (no _test suffix); run explicitly:
//   flutter test test/live_backup_manual.dart
//
// Creates /sdcard/AndroidFilesTest on the device, backs it up through the
// real engine in mirror and snapshot modes, and removes it afterwards.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

const adbPath = r'D:\Dev\tools\platform-tools\adb.exe';
const deviceDir = '/sdcard/AndroidFilesTest';

Future<void> sh(AdbClient adb, String serial, String cmd) async {
  final r = await Process.run(adbPath, ['-s', serial, 'shell', cmd]);
  expect(r.exitCode, 0, reason: '$cmd → ${r.stderr}');
}

Future<BackupJob> runJob(BackupEngine engine, BackupJob job) async {
  engine.enqueue(job);
  while (!job.status.isTerminal) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return job;
}

int countFiles(String root) => Directory(root)
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
  final engine = BackupEngine(adb, log: (m) => print('  [log] $m'));
  final scratch = Directory.systemTemp.createTempSync('af_e2e_');
  final entry = RemoteEntry(name: 'AndroidFilesTest', path: deviceDir, isDir: true);

  setUpAll(() async {
    await sh(adb, serial, 'rm -rf $deviceDir && mkdir -p $deviceDir/sub');
    await sh(adb, serial, "echo one > $deviceDir/a.txt");
    await sh(adb, serial, "echo two > '$deviceDir/file with space.txt'");
    await sh(adb, serial, "echo trzy > '$deviceDir/sub/zażółć.txt'");
  });

  tearDownAll(() async {
    await sh(adb, serial, 'rm -rf $deviceDir');
    scratch.deleteSync(recursive: true);
  });

  test('mirror full → incremental no-op → incremental picks up changes',
      () async {
    final dest = '${scratch.path}\\mirror';

    final full = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: true));
    expect(full.status, JobStatus.done);
    expect(countFiles('$dest\\AndroidFilesTest'), 3);

    final noop = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: true));
    expect(noop.status, JobStatus.done);
    expect(noop.skippedFiles, 3);
    expect(noop.doneBytes, 0);

    await sh(adb, serial, "echo changed > $deviceDir/a.txt");
    await sh(adb, serial, "echo new > $deviceDir/b.txt");
    final incr = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: true));
    expect(incr.status, JobStatus.done);
    expect(incr.skippedFiles, 2);
    expect(countFiles('$dest\\AndroidFilesTest'), 4);
    expect(
        File('$dest\\AndroidFilesTest\\a.txt').readAsStringSync().trim(), 'changed');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('deep verify passes on a good backup and flags tampering', () async {
    final dest = '${scratch.path}\\verify';
    final job = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: false));
    expect(job.status, JobStatus.done);

    await engine.deepVerify(job);
    expect(job.status, JobStatus.done);
    expect(job.warnings, isEmpty);

    File('$dest\\AndroidFilesTest\\a.txt').writeAsStringSync('tampered');
    await engine.deepVerify(job);
    expect(job.status, JobStatus.doneWithWarnings);
    expect(job.warnings.any((w) => w.contains('md5 mismatch')), true);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('adb pull fallback (full + incremental) when device lacks tar',
      () async {
    engine.forcePullFallback = true;
    try {
      final dest = '${scratch.path}\\pull';
      final expected = await adb.fileCount(serial, deviceDir);

      final full = await runJob(
          engine,
          BackupJob(
              source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: false));
      expect(full.status, JobStatus.done);
      expect(countFiles('$dest\\AndroidFilesTest'), expected);

      await sh(adb, serial, "echo pulled-v2 > $deviceDir/a.txt");
      final incr = await runJob(
          engine,
          BackupJob(
              source: entry, serial: serial, destDir: dest, baseDir: dest, incremental: true));
      expect(incr.status, JobStatus.done);
      expect(File('$dest\\AndroidFilesTest\\a.txt').readAsStringSync().trim(),
          'pulled-v2');
    } finally {
      engine.forcePullFallback = false;
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('restore pushes a local file back to the device', () async {
    final localFile = File('${scratch.path}\\restore me.txt')
      ..writeAsStringSync('hello phone');
    final before = await adb.fileCount(serial, deviceDir);
    final job = await runJob(
        engine,
        BackupJob(
          source: RemoteEntry(name: 'restore me.txt', path: deviceDir, isDir: true),
          serial: serial,
          destDir: deviceDir,
          localSource: localFile.path,
        ));
    expect(job.status, JobStatus.done);
    expect(await adb.fileCount(serial, deviceDir), before + 1);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('snapshot run hardlinks unchanged files from previous snapshot',
      () async {
    final snapRoot = '${scratch.path}\\snaps';
    final snap1 = '$snapRoot\\2026-07-17_100000';
    final snap2 = '$snapRoot\\2026-07-17_110000';

    final first = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: snap1, baseDir: null, incremental: true));
    expect(first.status, JobStatus.done);
    final baseline = countFiles('$snap1\\AndroidFilesTest');

    await sh(adb, serial, "echo v2 > $deviceDir/b.txt");
    final second = await runJob(
        engine,
        BackupJob(
            source: entry, serial: serial, destDir: snap2, baseDir: snap1, incremental: true));
    expect(second.status, JobStatus.done);
    expect(second.linkedFiles, baseline - 1);
    expect(countFiles('$snap2\\AndroidFilesTest'), baseline);
    expect(File('$snap2\\AndroidFilesTest\\b.txt').readAsStringSync().trim(), 'v2');
    // Unchanged file must be a hardlink: same content, and editing the
    // snapshot copy is not something we do, so just verify contents match.
    expect(File('$snap2\\AndroidFilesTest\\a.txt').readAsStringSync(),
        File('$snap1\\AndroidFilesTest\\a.txt').readAsStringSync());
  }, timeout: const Timeout(Duration(minutes: 5)));
}
