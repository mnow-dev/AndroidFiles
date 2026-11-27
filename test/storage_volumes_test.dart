import 'dart:io';

import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/macos/mac_home_screen.dart';
import 'package:android_files/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('External storage volume parsing & safety fence', () {
    test('parseStorageVolumes returns internal + sorted external SD cards', () {
      const raw = '''
/storage/emulated
/storage/self
/storage/9016-4EF8
/storage/1A2B-3C4D/
/storage/enc_emulated
/storage/knox-emulated
/storage/1A2B-3C4D
''';
      final vols = AdbClient.parseStorageVolumes(raw);
      expect(vols.length, 3);
      expect(vols[0], StorageVolume.internal);
      expect(vols[1].path, '/storage/1A2B-3C4D');
      expect(vols[1].label, 'SD card (1A2B-3C4D)');
      expect(vols[1].isExternal, isTrue);
      expect(vols[1].volumeId, '1A2B-3C4D');
      expect(vols[2].path, '/storage/9016-4EF8');
    });

    test('externalStorageId & externalStorageBackupSubdir isolate SD cards', () {
      expect(externalStorageId('/sdcard/DCIM'), isNull);
      expect(externalStorageBackupSubdir('/sdcard/DCIM'), isNull);
      expect(externalStorageId('/storage/emulated/0/DCIM'), isNull);
      expect(externalStorageId('/storage/self/primary/DCIM'), isNull);
      expect(externalStorageId('/storage/1A2B-3C4D/DCIM/a.jpg'), '1A2B-3C4D');
      expect(
        externalStorageBackupSubdir('/storage/1A2B-3C4D/DCIM'),
        'SD-1A2B-3C4D',
      );
    });

    test('isSafeUserStoragePath allows /sdcard and external SD files only', () {
      expect(AdbClient.isSafeUserStoragePath('/sdcard/DCIM/a.jpg'), isTrue);
      expect(
        AdbClient.isSafeUserStoragePath('/storage/1A2B-3C4D/DCIM/a.jpg'),
        isTrue,
      );
      // Reject volume roots, reserved dirs, system paths, and traversal.
      expect(AdbClient.isSafeUserStoragePath('/sdcard'), isFalse);
      expect(AdbClient.isSafeUserStoragePath('/sdcard/'), isFalse);
      expect(AdbClient.isSafeUserStoragePath('/storage/1A2B-3C4D'), isFalse);
      expect(AdbClient.isSafeUserStoragePath('/storage/1A2B-3C4D/'), isFalse);
      expect(
        AdbClient.isSafeUserStoragePath('/storage/emulated/0/a.jpg'),
        isFalse,
      );
      expect(
        AdbClient.isSafeUserStoragePath('/storage/1A2B-3C4D/../system/x'),
        isFalse,
      );
      expect(AdbClient.isSafeUserStoragePath('/data/local/tmp/x'), isFalse);
    });
  });

  group('AppController multi-volume state & Profile round-trip', () {
    test('Profile persists non-default external rootPath', () {
      final p = Profile(
        name: 'SD Card Music',
        paths: ['/storage/1A2B-3C4D/Music'],
        destination: '/tmp/backups',
        rootPath: '/storage/1A2B-3C4D',
      );
      final roundTrip = Profile.fromJson(p.toJson());
      expect(roundTrip.rootPath, '/storage/1A2B-3C4D');
      expect(roundTrip.paths, ['/storage/1A2B-3C4D/Music']);

      final internal = Profile(
        name: 'Internal',
        paths: ['/sdcard/DCIM'],
        destination: '/tmp/backups',
        rootPath: '/sdcard',
      );
      expect(internal.toJson().containsKey('rootPath'), isFalse);
    });

    test('switching volumes keeps selections across volumes & scopes toggleAll', () {
      final app = AppController(Settings(adbPath: 'adb'), startPolling: false);
      addTearDown(app.dispose);
      const sd = StorageVolume(
        path: '/storage/1A2B-3C4D',
        label: 'SD card (1A2B-3C4D)',
        isExternal: true,
      );
      app.volumes = [StorageVolume.internal, sd];
      app.children['/sdcard'] = const [
        RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
      ];
      app.children[sd.path] = const [
        RemoteEntry(name: 'Music', path: '/storage/1A2B-3C4D/Music', isDir: true),
      ];

      app.checkAll();
      expect(app.checked, {'/sdcard/DCIM'});
      expect(app.checkedCountForVolume(StorageVolume.internal), 1);
      expect(app.checkedCountForVolume(sd), 0);

      app.selectVolume(sd);
      expect(app.activeRootPath, '/storage/1A2B-3C4D');
      expect(app.allSelected, isFalse);

      app.checkAll();
      expect(app.checked, {'/sdcard/DCIM', '/storage/1A2B-3C4D/Music'});

      // Deselecting all on SD card leaves Internal selection intact.
      app.toggleAll();
      expect(app.checked, {'/sdcard/DCIM'});
    });

    test('applyProfile restores saved destination and never wipes current one if empty', () {
      final settings = Settings(
        adbPath: 'adb',
        lastDestination: '/Volumes/Backup/Phone',
      );
      final app = AppController(settings, startPolling: false);
      addTearDown(app.dispose);

      // Profile saved without a destination must keep the current destination.
      final noDest = Profile(
        name: 'Photos',
        paths: ['/sdcard/DCIM/Camera'],
        destination: '',
      );
      app.applyProfile(noDest);
      expect(app.destination.text, '/Volumes/Backup/Phone');

      // Profile with a saved destination restores it.
      final withDest = Profile(
        name: 'Archive',
        paths: ['/sdcard/Documents'],
        destination: '/Volumes/Archive',
      );
      app.applyProfile(withDest);
      expect(app.destination.text, '/Volumes/Archive');
    });

    test('probeEntryBackupStatus detects nested subfolder backups (e.g. <dest>/Camera)', () async {
      final tmp = await Directory.systemTemp.createTemp('af_status_test_');
      addTearDown(() => tmp.delete(recursive: true));
      final camDir = Directory('${tmp.path}/Camera');
      await camDir.create();
      final photo = File('${camDir.path}/IMG_001.jpg');
      await photo.writeAsBytes(const [1, 2, 3, 4]);

      final dirStatus = await AppController.probeEntryBackupStatus(
        const RemoteEntry(
          name: 'Camera',
          path: '/sdcard/DCIM/Camera',
          isDir: true,
          modified: '2020-01-01 00:00',
        ),
        tmp.path,
      );
      expect(dirStatus, EntryBackupStatus.backedUp);

      final fileStatus = await AppController.probeEntryBackupStatus(
        const RemoteEntry(
          name: 'IMG_001.jpg',
          path: '/sdcard/DCIM/Camera/IMG_001.jpg',
          isDir: false,
          size: 4,
          modified: '2020-01-01 00:00',
        ),
        tmp.path,
      );
      expect(fileStatus, EntryBackupStatus.backedUp);

      final missingStatus = await AppController.probeEntryBackupStatus(
        const RemoteEntry(
          name: 'Movies',
          path: '/sdcard/Movies',
          isDir: true,
          modified: '2020-01-01 00:00',
        ),
        tmp.path,
      );
      expect(missingStatus, EntryBackupStatus.notBackedUp);

      // Partial folder rollup: Camera has 1 backed-up file and 1 missing file
      // -> Camera and parent DCIM must both report `partial`, not `backedUp`.
      final app = AppController(
        Settings(adbPath: 'adb', lastDestination: tmp.path),
        startPolling: false,
      );
      addTearDown(app.dispose);
      app.children['/sdcard'] = const [
        RemoteEntry(
          name: 'DCIM',
          path: '/sdcard/DCIM',
          isDir: true,
          modified: '2020-01-01 00:00',
        ),
      ];
      app.children['/sdcard/DCIM'] = const [
        RemoteEntry(
          name: 'Camera',
          path: '/sdcard/DCIM/Camera',
          isDir: true,
          modified: '2020-01-01 00:00',
        ),
      ];
      app.children['/sdcard/DCIM/Camera'] = const [
        RemoteEntry(
          name: 'IMG_001.jpg',
          path: '/sdcard/DCIM/Camera/IMG_001.jpg',
          isDir: false,
          size: 4,
          modified: '2020-01-01 00:00',
        ),
        RemoteEntry(
          name: 'IMG_002.jpg',
          path: '/sdcard/DCIM/Camera/IMG_002.jpg',
          isDir: false,
          size: 8,
          modified: '2020-01-01 00:00',
        ),
      ];
      await app.refreshBackupStatuses();
      expect(app.entryBackupStatus['/sdcard/DCIM/Camera/IMG_001.jpg'],
          EntryBackupStatus.backedUp);
      expect(app.entryBackupStatus['/sdcard/DCIM/Camera/IMG_002.jpg'],
          EntryBackupStatus.notBackedUp);
      expect(app.entryBackupStatus['/sdcard/DCIM/Camera'],
          EntryBackupStatus.partial);
      expect(app.entryBackupStatus['/sdcard/DCIM'], EntryBackupStatus.partial);
    });

    test('nested partial folder stays checking and NEVER flashes backedUp before partial', () async {
      final tmp = await Directory.systemTemp.createTemp('af_no_flash_');
      addTearDown(() => tmp.delete(recursive: true));

      final localCam = Directory('${tmp.path}/DCIM/Camera');
      await localCam.create(recursive: true);
      await File('${localCam.path}/IMG_001.jpg').writeAsBytes([1, 2, 3, 4]);

      final fakeAdb = _FakeListAdb({
        '/sdcard': const [
          RemoteEntry(
            name: 'DCIM',
            path: '/sdcard/DCIM',
            isDir: true,
            modified: '2020-01-01 00:00',
          ),
        ],
        '/sdcard/DCIM': const [
          RemoteEntry(
            name: 'Camera',
            path: '/sdcard/DCIM/Camera',
            isDir: true,
            modified: '2020-01-01 00:00',
          ),
        ],
        '/sdcard/DCIM/Camera': const [
          RemoteEntry(
            name: 'IMG_001.jpg',
            path: '/sdcard/DCIM/Camera/IMG_001.jpg',
            isDir: false,
            size: 4,
            modified: '2020-01-01 00:00',
          ),
          RemoteEntry(
            name: 'IMG_002.jpg',
            path: '/sdcard/DCIM/Camera/IMG_002.jpg',
            isDir: false,
            size: 8,
            modified: '2020-01-01 00:00',
          ),
        ],
      });

      final app = AppController(
        Settings(adbPath: 'adb', lastDestination: tmp.path),
        startPolling: false,
        adb: fakeAdb,
      );
      addTearDown(app.dispose);
      app.selected = const AdbDevice(serial: 'S1', state: 'device', model: 'Pixel 8');

      final dcimHistory = <EntryBackupStatus>[];
      final camHistory = <EntryBackupStatus>[];
      app.addListener(() {
        final d = app.entryBackupStatus['/sdcard/DCIM'];
        final c = app.entryBackupStatus['/sdcard/DCIM/Camera'];
        if (d != null && (dcimHistory.isEmpty || dcimHistory.last != d)) {
          dcimHistory.add(d);
        }
        if (c != null && (camHistory.isEmpty || camHistory.last != c)) {
          camHistory.add(c);
        }
      });

      await app.expand('/sdcard');
      // Let recursive verification of DCIM -> Camera finish.
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(dcimHistory, isNot(contains(EntryBackupStatus.backedUp)));
      expect(camHistory, isNot(contains(EntryBackupStatus.backedUp)));
      expect(app.entryBackupStatus['/sdcard/DCIM'], EntryBackupStatus.partial);
      expect(app.entryBackupStatus['/sdcard/DCIM/Camera'], EntryBackupStatus.partial);
    });

    testWidgets(
      'macOS sidebar shows Storage switcher when external SD card is present',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 760);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final app = AppController(Settings(adbPath: 'adb'), startPolling: false);
        addTearDown(app.dispose);
        const device = AdbDevice(serial: 'ABC123', state: 'device', model: 'Xperia 1');
        const sd = StorageVolume(
          path: '/storage/1A2B-3C4D',
          label: 'SD card (1A2B-3C4D)',
          isExternal: true,
        );
        app.devices = [device];
        app.selected = device;
        app.volumes = [StorageVolume.internal, sd];
        app.expanded.add('/sdcard');
        app.children['/sdcard'] = const [
          RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        ];
        app.expanded.add(sd.path);
        app.children[sd.path] = const [
          RemoteEntry(name: 'FLAC', path: '/storage/1A2B-3C4D/FLAC', isDir: true),
        ];
        app.children['/storage/1A2B-3C4D/FLAC'] = const [];

        await tester.pumpWidget(
          CupertinoApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MacHomeScreen(app: app),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('STORAGE'), findsOneWidget);
        expect(find.text('SD card (1A2B-3C4D)'), findsOneWidget);
        expect(find.text('DCIM'), findsOneWidget);

        await tester.tap(find.text('SD card (1A2B-3C4D)'));
        await tester.pumpAndSettle();

        expect(app.activeRootPath, '/storage/1A2B-3C4D');
        expect(find.text('FLAC'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });
}

class _FakeListAdb extends AdbClient {
  final Map<String, List<RemoteEntry>> tree;
  _FakeListAdb(this.tree) : super('adb');

  @override
  Future<List<RemoteEntry>> list(String serial, String path) async {
    await Future<void>.delayed(const Duration(milliseconds: 15));
    return tree[path] ?? const [];
  }
}
