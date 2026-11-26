import 'dart:io';
import 'dart:ui' as ui;

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/macos/mac_home_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates `docs/screenshot-macos.png` from the real `MacHomeScreen` widgets
/// using macOS's native SF Pro / SF Mono / CupertinoIcons fonts.
///
/// Run with: `flutter test tool/render_macos_screenshot_test.dart`
void main() {
  testWidgets(
    'render docs/screenshot-macos.png',
    (tester) async {
      await tester.runAsync(_loadMacFonts);

      const logicalSize = Size(1080, 680);
      const dpr = 1.5;
      tester.view.physicalSize = logicalSize * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final settings = Settings(
        adbPath: 'adb',
        lastDestination: '/Users/alex/Backups',
        layout: BackupLayout.snapshot,
        incremental: true,
        skipClutter: true,
        profiles: [
          Profile(
            name: 'Daily Photos',
            paths: ['/sdcard/DCIM', '/sdcard/Documents'],
            destination: '/Users/alex/Backups',
            layout: BackupLayout.snapshot,
            incremental: true,
            scheduleTime: '22:00',
          ),
          Profile(
            name: 'SD Card Media',
            paths: ['/storage/1A2B-3C4D/Music', '/storage/1A2B-3C4D/Movies'],
            destination: '/Users/alex/Backups',
            layout: BackupLayout.mirror,
            incremental: true,
            rootPath: '/storage/1A2B-3C4D',
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
      app.activeVolume = StorageVolume.internal;
      app.activeProfile = settings.profiles.first;

      app.expanded.addAll(['/sdcard', '/sdcard/DCIM']);
      app.children['/sdcard'] = const [
        RemoteEntry(name: 'Alarms', path: '/sdcard/Alarms', isDir: true, modified: '2026-09-10 08:00'),
        RemoteEntry(name: 'Android', path: '/sdcard/Android', isDir: true, modified: '2026-11-26 21:14'),
        RemoteEntry(name: 'Audiobooks', path: '/sdcard/Audiobooks', isDir: true, modified: '2026-08-01 12:00'),
        RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true, modified: '2026-11-26 22:05'),
        RemoteEntry(name: 'Documents', path: '/sdcard/Documents', isDir: true, modified: '2026-11-24 14:20'),
        RemoteEntry(name: 'Download', path: '/sdcard/Download', isDir: true, modified: '2026-11-26 19:40'),
        RemoteEntry(name: 'Movies', path: '/sdcard/Movies', isDir: true, modified: '2026-10-12 18:10'),
        RemoteEntry(name: 'Music', path: '/sdcard/Music', isDir: true, modified: '2026-09-28 09:30'),
        RemoteEntry(name: 'Pictures', path: '/sdcard/Pictures', isDir: true, modified: '2026-11-26 16:20'),
        RemoteEntry(name: 'Podcasts', path: '/sdcard/Podcasts', isDir: true, modified: '2026-07-02 10:00'),
        RemoteEntry(name: 'Recordings', path: '/sdcard/Recordings', isDir: true, modified: '2026-10-04 11:45'),
      ];
      app.children['/sdcard/DCIM'] = const [
        RemoteEntry(name: 'Camera', path: '/sdcard/DCIM/Camera', isDir: true, modified: '2026-11-26 22:05'),
        RemoteEntry(
            name: 'Screenshots', path: '/sdcard/DCIM/Screenshots', isDir: true, modified: '2026-11-25 18:12'),
        RemoteEntry(
            name: 'ScreenRecorder',
            path: '/sdcard/DCIM/ScreenRecorder',
            isDir: true,
            modified: '2026-09-01 09:00'),
      ];
      app.entryBackupStatus.addAll({
        '/sdcard/Android': EntryBackupStatus.notBackedUp,
        '/sdcard/DCIM': EntryBackupStatus.modified,
        '/sdcard/DCIM/Camera': EntryBackupStatus.modified,
        '/sdcard/DCIM/Screenshots': EntryBackupStatus.backedUp,
        '/sdcard/Documents': EntryBackupStatus.backedUp,
        '/sdcard/Download': EntryBackupStatus.notBackedUp,
        '/sdcard/Movies': EntryBackupStatus.backedUp,
        '/sdcard/Music': EntryBackupStatus.backedUp,
        '/sdcard/Pictures': EntryBackupStatus.modified,
        '/sdcard/Recordings': EntryBackupStatus.backedUp,
      });
      // Mark empty folders cleanly (Alarms, Audiobooks, Podcasts) vs populated
      app.children['/sdcard/Alarms'] = const [];
      app.children['/sdcard/Audiobooks'] = const [];
      app.children['/sdcard/Podcasts'] = const [];
      app.children['/sdcard/DCIM/Camera'] = const [
        RemoteEntry(
            name: 'PXL_20261018_142211.mp4',
            path: '/sdcard/DCIM/Camera/PXL_20261018_142211.mp4',
            isDir: false,
            size: 184 * 1024 * 1024),
      ];
      app.children['/sdcard/DCIM/Screenshots'] = const [
        RemoteEntry(
            name: 'Screenshot_20261015.png',
            path: '/sdcard/DCIM/Screenshots/Screenshot_20261015.png',
            isDir: false,
            size: 420 * 1024),
      ];
      app.children['/sdcard/DCIM/ScreenRecorder'] = const [];

      app.checked.addAll(['/sdcard/DCIM', '/sdcard/Documents']);
      app.selectionBytes = (6.4 * 1024 * 1024 * 1024).round();
      app.measuringSelection = false;

      final runningJob = BackupJob(
        source: const RemoteEntry(
            name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        serial: device.serial,
        destDir: '/Users/alex/Backups/Pixel8/2026-11-26_220000',
        incremental: true,
      )
        ..status = JobStatus.running
        ..totalBytes = (6.1 * 1024 * 1024 * 1024).round()
        ..doneBytes = (4.2 * 1024 * 1024 * 1024).round()
        ..bytesPerSec = 16.4 * 1024 * 1024
        ..deviceFileCount = 1248
        ..filesStreamed = 864
        ..currentFile = 'DCIM/Camera/PXL_20261018_142211.mp4';

      final doneJob = BackupJob(
        source: const RemoteEntry(
            name: 'Documents', path: '/sdcard/Documents', isDir: true),
        serial: device.serial,
        destDir: '/Users/alex/Backups/Pixel8/2026-11-26_220000',
        incremental: true,
      )
        ..status = JobStatus.done
        ..totalBytes = 312 * 1024 * 1024
        ..doneBytes = 312 * 1024 * 1024
        ..deviceFileCount = 142
        ..localFileCount = 142
        ..skippedFiles = 138
        ..linkedFiles = 138
        ..deepVerified = true;

      app.engine.jobs.addAll([runningJob, doneJob]);

      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: CupertinoApp(
            debugShowCheckedModeBanner: false,
            theme: const CupertinoThemeData(
              brightness: Brightness.light,
              textTheme: CupertinoTextThemeData(
                textStyle: TextStyle(fontFamily: 'SFPro'),
              ),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DefaultTextStyle(
              style: const TextStyle(fontFamily: 'SFPro'),
              child: Stack(
                children: [
                  MacHomeScreen(app: app),
                  // Authentic macOS unified-titlebar traffic lights
                  const Positioned(
                    left: 16,
                    top: 18,
                    child: Row(
                      children: [
                        _TrafficLight(Color(0xFFFF5F57), Color(0xFFE0443E)),
                        SizedBox(width: 8),
                        _TrafficLight(Color(0xFFFEBC2E), Color(0xFFDAA022)),
                        SizedBox(width: 8),
                        _TrafficLight(Color(0xFF28C840), Color(0xFF1EA834)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: dpr);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        final outFile = File('docs/screenshot-macos.png');
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
      });

      expect(File('docs/screenshot-macos.png').existsSync(), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _TrafficLight extends StatelessWidget {
  final Color fill;
  final Color border;
  const _TrafficLight(this.fill, this.border);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 0.6),
      ),
    );
  }
}

Future<void> _loadMacFonts() async {
  Future<void> loadFont(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family);
    final bytes = f.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  // Override Flutter's built-in test font ('FlutterTest' / Ahem) and Cupertino
  // system font names with macOS's real SF Pro and SF Mono fonts so the render
  // is pixel-authentic to the live macOS app.
  await loadFont('Ahem', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('FlutterTest', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('SFPro', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('.AppleSystemUIFont', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('CupertinoSystemText', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('CupertinoSystemDisplay', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('SF Mono', '/System/Library/Fonts/SFNSMono.ttf');
  await loadFont('Menlo', '/System/Library/Fonts/SFNSMono.ttf');

  // Load CupertinoIcons from the asset bundle so native Cupertino icons render.
  try {
    final data =
        await rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf');
    final loader = FontLoader('packages/cupertino_icons/CupertinoIcons');
    loader.addFont(Future.value(data));
    await loader.load();
  } catch (_) {}
}
