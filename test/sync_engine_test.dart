import 'dart:io';

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/manifest.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/os.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/sync_engine.dart';
import 'package:android_files/src/ui/macos/mac_sync_view.dart';
import 'package:android_files/src/ui/win_sync_view.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSyncAdb extends AdbClient {
  final Map<String, List<int>> deviceFiles = {};
  final Map<String, int> deviceMtimes = {};
  final List<String> createdDirs = [];
  final List<String> deletedPaths = [];
  final List<(String, bool)> hiPerfCalls = [];

  _FakeSyncAdb() : super('adb');

  @override
  Future<void> setWifiHighPerf(String serial, bool enabled) async {
    hiPerfCalls.add((serial, enabled));
  }

  @override
  Future<void> ensureDeviceDir(String serial, String deviceDir) async {
    createdDirs.add(deviceDir);
  }

  @override
  Future<void> pushFile(
    String serial,
    String localPath,
    String devicePath,
  ) async {
    final bytes = await File(localPath).readAsBytes();
    final st = await File(localPath).stat();
    deviceFiles[devicePath] = bytes;
    deviceMtimes[devicePath] = st.modified.millisecondsSinceEpoch ~/ 1000;
  }

  @override
  Future<void> pullFile(
    String serial,
    String devicePath,
    String localPath,
  ) async {
    final bytes = deviceFiles[devicePath];
    if (bytes == null) throw AdbException('missing $devicePath');
    final f = File(localPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    final mtime = deviceMtimes[devicePath];
    if (mtime != null) {
      await f.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
      );
    }
  }

  @override
  Future<List<String>> deleteDeviceFiles(
    String serial,
    List<String> absPaths, {
    void Function(int done, int total)? onProgress,
  }) async {
    for (final p in absPaths) {
      deviceFiles.remove(p);
      deviceMtimes.remove(p);
      deletedPaths.add(p);
    }
    return const [];
  }

  @override
  Future<Map<String, FileMeta>> folderManifest(
    String serial,
    String deviceDir,
  ) async {
    final prefix = deviceDir.endsWith('/') ? deviceDir : '$deviceDir/';
    final out = <String, FileMeta>{};
    for (final entry in deviceFiles.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final rel = entry.key.substring(prefix.length);
      out[rel] = FileMeta(
        entry.value.length,
        deviceMtimes[entry.key] ?? 1700000000,
      );
    }
    return out;
  }
}

void main() {
  group('SyncEngine.computePlan', () {
    final fixedNow = DateTime(2026, 11, 28, 10, 0);

    test('pushToPhone pushes new/modified files and respects propagateDeletes',
        () {
      final pair = SyncPair(
        id: 'p1',
        name: 'Music',
        localPath: '/tmp/music',
        devicePath: '/sdcard/Music',
        mode: SyncMode.pushToPhone,
        propagateDeletes: false,
      );

      final local = {
        'a.mp3': const FileMeta(100, 1000),
        'b.mp3': const FileMeta(250, 2000),
        '.DS_Store': const FileMeta(10, 1000),
      };
      final device = {
        'a.mp3': const FileMeta(100, 1001), // within 2s mtime tolerance
        'b.mp3': const FileMeta(200, 1500), // changed size
        'extra_on_phone.mp3': const FileMeta(300, 1000),
      };

      final safePlan = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        now: fixedNow,
      );
      expect(safePlan.toPush.map((e) => e.relPath), ['b.mp3']);
      expect(safePlan.toDeleteOnDevice, isEmpty);
      expect(safePlan.unchangedCount, 2); // a.mp3 + extra_on_phone kept safe

      pair.propagateDeletes = true;
      final mirrorPlan = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        now: fixedNow,
      );
      expect(mirrorPlan.toDeleteOnDevice.map((e) => e.relPath),
          ['extra_on_phone.mp3']);
    });

    test('pullToComputer pulls new/modified device files', () {
      final pair = SyncPair(
        id: 'p2',
        name: 'Recordings',
        localPath: '/tmp/rec',
        devicePath: '/sdcard/Recordings',
        mode: SyncMode.pullToComputer,
      );
      final plan = SyncEngine.computePlan(
        pair: pair,
        local: {'old.m4a': const FileMeta(50, 1000)},
        device: {'new.m4a': const FileMeta(80, 2000)},
        now: fixedNow,
      );
      expect(plan.toPull.map((e) => e.relPath), ['new.m4a']);
      expect(plan.toDeleteLocal, isEmpty);
    });

    test('twoWay handles one-sided edits, conflicts, and delete protection',
        () {
      final pair = SyncPair(
        id: 'p3',
        name: 'Vault',
        localPath: '/tmp/vault',
        devicePath: '/sdcard/Documents/Vault',
        mode: SyncMode.twoWay,
        propagateDeletes: false,
      );

      final baseline = {
        'same.md': const FileMeta(100, 1000),
        'local_edit.md': const FileMeta(100, 1000),
        'phone_edit.md': const FileMeta(100, 1000),
        'both_edit.md': const FileMeta(100, 1000),
        'deleted_on_phone.md': const FileMeta(100, 1000),
        'deleted_on_phone_but_edited_local.md': const FileMeta(100, 1000),
      };
      final local = {
        'same.md': const FileMeta(100, 1000),
        'local_edit.md': const FileMeta(120, 1500),
        'phone_edit.md': const FileMeta(100, 1000),
        'both_edit.md': const FileMeta(140, 1600),
        'deleted_on_phone.md': const FileMeta(100, 1000),
        'deleted_on_phone_but_edited_local.md': const FileMeta(130, 1700),
        'brand_new_local.md': const FileMeta(50, 1800),
      };
      final device = {
        'same.md': const FileMeta(100, 1000),
        'local_edit.md': const FileMeta(100, 1000),
        'phone_edit.md': const FileMeta(150, 1550),
        'both_edit.md': const FileMeta(160, 1650),
        'brand_new_phone.md': const FileMeta(60, 1900),
      };

      final plan = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        baseline: baseline,
        now: fixedNow,
      );

      expect(
        plan.toPush.map((e) => e.relPath),
        unorderedEquals([
          'local_edit.md',
          'deleted_on_phone_but_edited_local.md',
          'brand_new_local.md',
        ]),
      );
      expect(
        plan.toPull.map((e) => e.relPath),
        unorderedEquals(['phone_edit.md', 'brand_new_phone.md']),
      );
      expect(plan.conflicts.length, 1);
      expect(plan.conflicts.first.relPath, 'both_edit.md');
      expect(
        plan.conflicts.first.conflictRelPath,
        'both_edit (phone-conflict 2026-11-28).md',
      );
      // Delete protection off: deleted_on_phone.md stays safe locally.
      expect(plan.toDeleteLocal, isEmpty);

      // With propagateDeletes enabled, unchanged deleted_on_phone.md deletes locally.
      pair.propagateDeletes = true;
      final planWithDeletes = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        baseline: baseline,
        now: fixedNow,
      );
      expect(
        planWithDeletes.toDeleteLocal.map((e) => e.relPath),
        ['deleted_on_phone.md'],
      );
    });

    test('requiresDeleteConfirmation triggers when >20% and >=5 files deleted',
        () {
      final pair = SyncPair(
        id: 'p4',
        name: 'Big',
        localPath: '/tmp/big',
        devicePath: '/sdcard/Big',
        mode: SyncMode.pushToPhone,
        propagateDeletes: true,
      );
      final device = {
        for (var i = 0; i < 10; i++) 'f$i.txt': const FileMeta(10, 1000),
      };
      final local = {
        for (var i = 0; i < 4; i++) 'f$i.txt': const FileMeta(10, 1000),
      };
      final plan = SyncEngine.computePlan(
        pair: pair,
        local: local,
        device: device,
        now: fixedNow,
      );
      expect(plan.totalDeletes, 6);
      expect(plan.requiresDeleteConfirmation, isTrue);
    });
  });

  group('SyncController end-to-end & persistence', () {
    test('executes two-way sync, preserves both conflict copies, persists baseline',
        () async {
      final tmp = await Directory.systemTemp.createTemp('af_sync_test_');
      addTearDown(() => tmp.delete(recursive: true));

      final localDir = Directory(localJoin(tmp.path, 'vault'));
      await localDir.create(recursive: true);
      final stateDir = Directory(localJoin(tmp.path, 'state'));
      final settingsFile = File(localJoin(tmp.path, 'settings.json'));

      await File(localJoin(localDir.path, 'only_local.md'))
          .writeAsString('from mac');
      await File(localJoin(localDir.path, 'conflict.md'))
          .writeAsString('mac version');

      final adb = _FakeSyncAdb();
      adb.deviceFiles['/sdcard/Vault/only_phone.md'] = 'from phone'.codeUnits;
      adb.deviceMtimes['/sdcard/Vault/only_phone.md'] = 1700000100;
      adb.deviceFiles['/sdcard/Vault/conflict.md'] =
          'phone version longer'.codeUnits;
      adb.deviceMtimes['/sdcard/Vault/conflict.md'] = 1700000200;

      final settings = Settings(adbPath: 'adb', storageFile: settingsFile);
      final controller = SyncController(
        adb: adb,
        settings: settings,
        log: (_) {},
        stateDirOverride: stateDir,
      );

      final pair = SyncPair(
        id: 'vault1',
        name: 'Obsidian',
        localPath: localDir.path,
        devicePath: '/sdcard/Vault',
        mode: SyncMode.twoWay,
      );
      controller.addPair(pair);

      final result = await controller.runPair(pair, '192.168.0.42:41823');
      expect(result, isNotNull);
      expect(result!.ok, isTrue);
      expect(result.pushed, 1);
      expect(result.pulled, 1);
      expect(result.conflictsResolved, 1);

      // Verify wireless Wi-Fi hi-perf lock was acquired and released.
      expect(adb.hiPerfCalls, [
        ('192.168.0.42:41823', true),
        ('192.168.0.42:41823', false),
      ]);

      // Verify files exist on both sides and conflict preserved phone version.
      expect(
        String.fromCharCodes(adb.deviceFiles['/sdcard/Vault/only_local.md']!),
        'from mac',
      );
      expect(
        await File(localJoin(localDir.path, 'only_phone.md')).readAsString(),
        'from phone',
      );
      final conflictFiles = localDir
          .listSync()
          .whereType<File>()
          .where((f) => localBaseName(f.path).contains('phone-conflict'))
          .toList();
      expect(conflictFiles.length, 1);
      expect(await conflictFiles.first.readAsString(), 'phone version longer');

      // Re-preview immediately after sync should report already in sync.
      final secondPlan =
          await controller.previewPair(pair, '192.168.0.42:41823');
      expect(secondPlan, isNotNull);
      expect(secondPlan!.isEmpty, isTrue);

      // Verify SyncPair round-trips through Settings JSON.
      await settings.save();
      final rawJson = await settingsFile.readAsString();
      expect(rawJson, contains('Obsidian'));
      expect(rawJson, contains('/sdcard/Vault'));
    });
  });

  group('Folder Sync UI widgets', () {
    testWidgets('MacSyncView shows presets when empty and pair card when added',
        (tester) async {
      final app = AppController(Settings(adbPath: 'adb'), startPolling: false);
      addTearDown(app.dispose);
      app.selected = const AdbDevice(
        serial: 'ABC123',
        state: 'device',
        model: 'Pixel 8',
      );

      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 820, height: 600, child: MacSyncView(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('Folder Sync'), findsOneWidget);
      expect(find.text('Music → Phone'), findsOneWidget);
      expect(find.text('Obsidian / Notes ⇄'), findsOneWidget);

      app.sync.addPair(SyncPair(
        id: 'm1',
        name: 'My Music',
        localPath: '/Users/alex/Music',
        devicePath: '/sdcard/Music',
        mode: SyncMode.pushToPhone,
        autoSyncOnConnect: true,
      ));
      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 820, height: 600, child: MacSyncView(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('My Music'), findsOneWidget);
      expect(find.text('Sync Now'), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
    });

    testWidgets('WinSyncView shows presets when empty and pair card when added',
        (tester) async {
      final app = AppController(Settings(adbPath: 'adb'), startPolling: false);
      addTearDown(app.dispose);
      app.selected = const AdbDevice(
        serial: 'ABC123',
        state: 'device',
        model: 'Pixel 8',
      );

      await tester.pumpWidget(
        FluentApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 860, height: 620, child: WinSyncView(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('Folder Sync'), findsOneWidget);
      expect(find.text('Music → Phone'), findsOneWidget);

      app.sync.addPair(SyncPair(
        id: 'm1',
        name: 'Obsidian Vault',
        localPath: r'C:\Users\Alex\Vault',
        devicePath: '/sdcard/Documents/Vault',
        mode: SyncMode.twoWay,
      ));
      await tester.pumpWidget(
        FluentApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 860, height: 620, child: WinSyncView(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('Obsidian Vault'), findsOneWidget);
      expect(find.text('Sync Now'), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
    });
  });
}
