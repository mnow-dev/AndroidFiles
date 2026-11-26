import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/cleanup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/home_screen.dart';
import 'package:android_files/src/ui/win_theme.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatShortModified formats today, yesterday, days ago, and older dates', () {
    final now = DateTime(2026, 11, 26, 23, 0);
    expect(formatShortModified('2026-11-26 22:05', now: now), 'Today 22:05');
    expect(formatShortModified('2026-11-25 14:30', now: now), 'Yesterday');
    expect(formatShortModified('2026-11-23 09:00', now: now), '3 days ago');
    expect(formatShortModified('2026-10-12 08:15', now: now), 'Oct 12');
    expect(formatShortModified('2025-07-04 12:00', now: now), '2025-07-04');
  });

  testWidgets(
    'Windows Hybrid HomeScreen renders Mica sidebar, context bar, 3 Bento cards, Last Modified & Backup Status, and Clean Up Space',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final settings = Settings(
        adbPath: 'adb',
        lastDestination: '/tmp',
        layout: BackupLayout.snapshot,
        profiles: [
          Profile(
            name: 'Daily Photos',
            paths: ['/sdcard/DCIM'],
            destination: '/tmp',
            layout: BackupLayout.snapshot,
            scheduleTime: '22:00',
          ),
        ],
      );
      final app = AppController(settings, startPolling: false);
      addTearDown(app.dispose);

      const device = AdbDevice(
        serial: '192.168.0.42:41823',
        state: 'device',
        model: 'Pixel 8',
      );
      const sd = StorageVolume(
        path: '/storage/1A2B-3C4D',
        label: 'SD card (1A2B-3C4D)',
        isExternal: true,
      );
      app.devices = const [device];
      app.selected = device;
      app.volumes = const [StorageVolume.internal, sd];
      app.expanded.add('/sdcard');
      app.children['/sdcard'] = const [
        RemoteEntry(
          name: 'DCIM',
          path: '/sdcard/DCIM',
          isDir: true,
          modified: '2026-11-26 22:05',
        ),
        RemoteEntry(
          name: 'Documents',
          path: '/sdcard/Documents',
          isDir: true,
          modified: '2026-11-24 10:00',
        ),
      ];
      app.entryBackupStatus['/sdcard/DCIM'] = EntryBackupStatus.modified;
      app.entryBackupStatus['/sdcard/Documents'] = EntryBackupStatus.backedUp;
      app.checked.add('/sdcard/DCIM');
      app.selectionBytes = 512 * 1024 * 1024;

      // Seed Clean Up Space scan so switching workspace renders proposals cleanly.
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      app.cleanup.files = [
        ScannedFile(
          relPath: 'DCIM/Camera/VID_OLD.mp4',
          size: 420 * 1024 * 1024,
          mtimeSec: nowSec - 150 * 86400,
          backedUp: true,
        ),
      ];
      app.cleanup.folders = CleanupAnalyzer.computeFolderUsage(app.cleanup.files);

      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          FluentApp(
            theme: FluentThemeData(
              brightness: brightness,
              accentColor: Colors.green,
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HomeScreen(app: app),
          ),
        );
        await tester.pump();

        expect(find.text('Back Up'), findsOneWidget);
        expect(find.text('Clean Up Space'), findsOneWidget);
        expect(find.text('Pixel 8'), findsOneWidget);
        expect(find.text('Daily Photos'), findsOneWidget);
        expect(find.text('Last Modified'), findsOneWidget);
        expect(find.text('Backup Status'), findsOneWidget);
        expect(find.text('Modified'), findsOneWidget);
        expect(find.text('Backed up'), findsOneWidget);
        expect(find.text('SD card'), findsOneWidget);
      }

      // Switch to Clean Up Space workspace and verify proposals render.
      await tester.tap(find.text('Clean Up Space'));
      await tester.pump();
      expect(find.text('Smart Proposals'), findsOneWidget);
      expect(find.text('DCIM Videos Only'), findsOneWidget);
    },
  );
}
