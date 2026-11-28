import 'dart:async';
import 'dart:io';

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/tree_filter.dart';
import 'package:android_files/src/ui/macos/mac_tree_pane.dart';
import 'package:android_files/src/ui/tree_panel.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingAdbClient extends AdbClient {
  final List<(String, bool)> hiPerfCalls = [];

  _RecordingAdbClient() : super('adb');

  @override
  Future<void> setWifiHighPerf(String serial, bool enabled) async {
    hiPerfCalls.add((serial, enabled));
  }

  @override
  Future<bool> hasTar(String serial) async => false;

  @override
  Future<int> sizeOf(String serial, String path) async => 0;

  @override
  Future<int> fileCount(String serial, String path) async => 0;

  @override
  Future<Process> startPull(String serial, String path, String destDir) {
    throw AdbException('stub pull');
  }
}

void main() {
  group('TreeFilter unit logic', () {
    const dcim = RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true);
    const camera =
        RemoteEntry(name: 'Camera', path: '/sdcard/DCIM/Camera', isDir: true);
    const photo = RemoteEntry(
      name: 'PXL_20261126.jpg',
      path: '/sdcard/DCIM/Camera/PXL_20261126.jpg',
      isDir: false,
      size: 4096,
    );
    const video = RemoteEntry(
      name: 'vacation.mp4',
      path: '/sdcard/DCIM/Camera/vacation.mp4',
      isDir: false,
      size: 90000,
    );
    const docs =
        RemoteEntry(name: 'Documents', path: '/sdcard/Documents', isDir: true);
    const notes = RemoteEntry(
      name: 'notes.md',
      path: '/sdcard/Documents/notes.md',
      isDir: false,
      size: 1200,
    );

    final children = <String, List<RemoteEntry>>{
      '/sdcard': [dcim, docs],
      '/sdcard/DCIM': [camera],
      '/sdcard/DCIM/Camera': [photo, video],
      '/sdcard/Documents': [notes],
    };

    final statuses = <String, EntryBackupStatus>{
      '/sdcard/DCIM': EntryBackupStatus.partial,
      '/sdcard/DCIM/Camera': EntryBackupStatus.partial,
      '/sdcard/DCIM/Camera/PXL_20261126.jpg': EntryBackupStatus.backedUp,
      '/sdcard/DCIM/Camera/vacation.mp4': EntryBackupStatus.notBackedUp,
      '/sdcard/Documents': EntryBackupStatus.backedUp,
      '/sdcard/Documents/notes.md': EntryBackupStatus.backedUp,
    };

    test('inactive filter matches everything', () {
      const f = TreeFilter();
      expect(f.isActive, isFalse);
      expect(f.matches(dcim, statuses: statuses, children: children), isTrue);
      expect(f.matches(docs, statuses: statuses, children: children), isTrue);
    });

    test('query matches descendant files and keeps ancestor folders visible', () {
      const f = TreeFilter(query: '.mp4');
      expect(f.matches(dcim, statuses: statuses, children: children), isTrue);
      expect(f.matches(camera, statuses: statuses, children: children), isTrue);
      expect(f.matches(video, statuses: statuses, children: children), isTrue);
      expect(f.matches(photo, statuses: statuses, children: children), isFalse);
      expect(f.matches(docs, statuses: statuses, children: children), isFalse);
    });

    test('onlyUnbackedUp hides backedUp items and keeps partial/notBackedUp', () {
      const f = TreeFilter(onlyUnbackedUp: true);
      expect(f.matches(dcim, statuses: statuses, children: children), isTrue);
      expect(f.matches(video, statuses: statuses, children: children), isTrue);
      expect(f.matches(photo, statuses: statuses, children: children), isFalse);
      expect(f.matches(docs, statuses: statuses, children: children), isFalse);
    });

    test('combined query + onlyUnbackedUp narrows to matching unbacked files', () {
      const f = TreeFilter(query: 'pxl', onlyUnbackedUp: true);
      expect(f.matches(photo, statuses: statuses, children: children), isFalse);
      expect(f.matches(dcim, statuses: statuses, children: children), isFalse);
    });

    test('matching parent folder keeps children visible when expanded', () {
      const f = TreeFilter(query: 'documents');
      expect(f.nameMatchesQuery(docs), isTrue);
      expect(
        f.matches(
          notes,
          statuses: statuses,
          children: children,
          ancestorMatchedQuery: true,
        ),
        isTrue,
      );
    });
  });

  group('BackupEngine Wi-Fi high-performance lock', () {
    test('enables and disables hi-perf mode for wireless jobs', () async {
      final adb = _RecordingAdbClient();
      final engine = BackupEngine(adb, log: (_) {});
      final drained = Completer<void>();
      engine.onDrained = () => drained.complete();
      engine.enqueue(BackupJob(
        source: const RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        serial: '192.168.0.42:41823',
        destDir: Directory.systemTemp.path,
      ));
      await drained.future.timeout(const Duration(seconds: 5));
      expect(adb.hiPerfCalls, [
        ('192.168.0.42:41823', true),
        ('192.168.0.42:41823', false),
      ]);
    });

    test('does not toggle hi-perf mode for USB jobs', () async {
      final adb = _RecordingAdbClient();
      final engine = BackupEngine(adb, log: (_) {});
      final drained = Completer<void>();
      engine.onDrained = () => drained.complete();
      engine.enqueue(BackupJob(
        source: const RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        serial: '3B241FDJH002HF',
        destDir: Directory.systemTemp.path,
      ));
      await drained.future.timeout(const Duration(seconds: 5));
      expect(adb.hiPerfCalls, isEmpty);
    });
  });

  group('Device Folders search & filter widgets', () {
    AppController makeController() {
      final app = AppController(Settings(adbPath: 'adb'), startPolling: false);
      const dev = AdbDevice(serial: 'ABC123', state: 'device', model: 'Pixel 8');
      app.devices = const [dev];
      app.selected = dev;
      app.expanded.add('/sdcard');
      app.children['/sdcard'] = const [
        RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        RemoteEntry(name: 'Documents', path: '/sdcard/Documents', isDir: true),
        RemoteEntry(name: 'Download', path: '/sdcard/Download', isDir: true),
      ];
      app.entryBackupStatus.addAll({
        '/sdcard/DCIM': EntryBackupStatus.backedUp,
        '/sdcard/Documents': EntryBackupStatus.backedUp,
        '/sdcard/Download': EntryBackupStatus.notBackedUp,
      });
      return app;
    }

    testWidgets('MacTreePane filters by query and Not backed up pill',
        (tester) async {
      final app = makeController();
      addTearDown(app.dispose);

      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 600, height: 500, child: MacTreePane(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('DCIM'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);

      await tester.enterText(find.byType(CupertinoTextField), 'doc');
      await tester.pump();
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('DCIM'), findsNothing);
      expect(find.text('1 matching'), findsOneWidget);

      // Combine with "Not backed up" — Documents is backedUp, so 0 matches.
      await tester.tap(find.text('Not backed up').first);
      await tester.pump();
      expect(find.text('No matching files or folders'), findsOneWidget);

      await tester.tap(find.text('Clear filter'));
      await tester.pumpAndSettle();
      expect(find.text('DCIM'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('TreePanel (Windows) filters by query and Not backed up pill',
        (tester) async {
      final app = makeController();
      addTearDown(app.dispose);

      await tester.pumpWidget(
        FluentApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(width: 700, height: 500, child: TreePanel(app: app)),
        ),
      );
      await tester.pump();

      expect(find.text('DCIM'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);

      await tester.tap(find.text('Not backed up').first);
      await tester.pump();
      expect(find.text('Download'), findsOneWidget);
      expect(find.text('DCIM'), findsNothing);
      expect(find.text('1 matching'), findsOneWidget);

      await tester.enterText(find.byType(TextBox), 'zzz-no-match');
      await tester.pump();
      expect(find.text('No matching files or folders'), findsOneWidget);

      await tester.tap(find.text('Clear filter'));
      await tester.pumpAndSettle();
      expect(find.text('DCIM'), findsOneWidget);
    });
  });
}
