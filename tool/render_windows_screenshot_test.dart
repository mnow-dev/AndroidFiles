import 'dart:io';
import 'dart:ui' as ui;

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/home_screen.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates `docs/screenshot.png` from the real Windows 11 Hybrid `HomeScreen`
/// widgets using FluentIcons and crisp UI fonts.
///
/// Run with: `flutter test tool/render_windows_screenshot_test.dart`
void main() {
  testWidgets(
    'render docs/screenshot.png',
    (tester) async {
      await tester.runAsync(_loadWindowsFonts);

      const logicalSize = Size(1120, 728);
      const dpr = 1.5;
      tester.view.physicalSize = logicalSize * dpr;
      tester.view.devicePixelRatio = dpr;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final settings = Settings(
        adbPath: 'adb',
        lastDestination: r'D:\Backups\Pixel8',
        layout: BackupLayout.snapshot,
        incremental: true,
        skipClutter: true,
        splitRatio: 0.56,
        profiles: [
          Profile(
            name: 'Daily Photos',
            paths: ['/sdcard/DCIM', '/sdcard/Documents'],
            destination: r'D:\Backups\Pixel8',
            layout: BackupLayout.snapshot,
            incremental: true,
            scheduleTime: '22:00',
          ),
          Profile(
            name: 'SD Card Media',
            paths: ['/storage/1A2B-3C4D/Music', '/storage/1A2B-3C4D/Movies'],
            destination: r'D:\Backups\Pixel8',
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
      app.wifiLink = const WifiLinkInfo(
        linkSpeedMbps: 866,
        frequencyMhz: 5180,
        rssiDbm: -52,
        standard: '11ax',
        ssid: 'HomeWiFi-5G',
      );
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
        RemoteEntry(name: 'Screenshots', path: '/sdcard/DCIM/Screenshots', isDir: true, modified: '2026-11-25 18:12'),
        RemoteEntry(name: 'ScreenRecorder', path: '/sdcard/DCIM/ScreenRecorder', isDir: true, modified: '2026-09-01 09:00'),
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
      app.children['/sdcard/Alarms'] = const [];
      app.children['/sdcard/Audiobooks'] = const [];
      app.children['/sdcard/Podcasts'] = const [];
      app.children['/sdcard/DCIM/Camera'] = const [
        RemoteEntry(
          name: 'PXL_20261018_142211.mp4',
          path: '/sdcard/DCIM/Camera/PXL_20261018_142211.mp4',
          isDir: false,
          size: 184 * 1024 * 1024,
        ),
      ];
      app.children['/sdcard/DCIM/Screenshots'] = const [
        RemoteEntry(
          name: 'Screenshot_20261015.png',
          path: '/sdcard/DCIM/Screenshots/Screenshot_20261015.png',
          isDir: false,
          size: 420 * 1024,
        ),
      ];
      app.children['/sdcard/DCIM/ScreenRecorder'] = const [];

      app.checked.addAll(['/sdcard/DCIM', '/sdcard/Documents']);
      app.selectionBytes = (6.4 * 1024 * 1024 * 1024).round();
      app.measuringSelection = false;

      final runningJob = BackupJob(
        source: const RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        serial: device.serial,
        destDir: r'D:\Backups\Pixel8\2026-11-26_220000',
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
          name: 'Documents',
          path: '/sdcard/Documents',
          isDir: true,
        ),
        serial: device.serial,
        destDir: r'D:\Backups\Pixel8\2026-11-26_220000',
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
      final base = FluentThemeData(
        brightness: Brightness.light,
        accentColor: Colors.green,
        visualDensity: VisualDensity.compact,
        fontFamily: 'Segoe UI',
      );
      final t = base.typography;
      final theme = base.copyWith(
        typography: Typography.raw(
          display: t.display,
          titleLarge: t.titleLarge,
          title: t.title,
          subtitle: t.subtitle,
          bodyLarge: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          bodyStrong: t.bodyStrong?.copyWith(fontWeight: FontWeight.w600),
          body: t.body?.copyWith(fontWeight: FontWeight.w500),
          caption: t.caption?.copyWith(fontWeight: FontWeight.w500),
        ),
      );

      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: FluentApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Column(
              children: [
                const _WindowsTitleBar(),
                Expanded(child: HomeScreen(app: app)),
              ],
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
        final outFile = File('docs/screenshot.png');
        await outFile.writeAsBytes(byteData!.buffer.asUint8List());
      });

      expect(File('docs/screenshot.png').existsSync(), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _WindowsTitleBar extends StatelessWidget {
  const _WindowsTitleBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: 14),
      decoration: const BoxDecoration(
        color: Color(0xFFF3F5F8),
        border: Border(bottom: BorderSide(color: Color(0xFFE2E6EC), width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: const Color(0xFF14833B),
              borderRadius: BorderRadius.circular(3.5),
            ),
            alignment: Alignment.center,
            child: const Icon(
              FluentIcons.folder_horizontal,
              size: 9,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'AndroidFiles',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1D21),
              decoration: TextDecoration.none,
            ),
          ),
          const Spacer(),
          const _WinCaptionBtn(icon: FluentIcons.chrome_minimize),
          const _WinCaptionBtn(icon: FluentIcons.checkbox),
          const _WinCaptionBtn(icon: FluentIcons.chrome_close),
        ],
      ),
    );
  }
}

class _WinCaptionBtn extends StatelessWidget {
  final IconData icon;
  const _WinCaptionBtn({required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 32,
      child: Center(
        child: Icon(icon, size: 10, color: const Color(0xFF3E4650)),
      ),
    );
  }
}

Future<void> _loadWindowsFonts() async {
  Future<void> loadFont(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family);
    final bytes = f.readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }

  // Use clean sans-serif & monospace system fonts available on macOS CI/dev hosts
  // for crisp text rendering, plus the real bundled FluentIcons.ttf.
  await loadFont('Ahem', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('FlutterTest', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('Segoe UI', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('Segoe UI Variable', '/System/Library/Fonts/SFNS.ttf');
  await loadFont('Cascadia Code', '/System/Library/Fonts/SFNSMono.ttf');
  await loadFont('Cascadia Mono', '/System/Library/Fonts/SFNSMono.ttf');
  await loadFont('Consolas', '/System/Library/Fonts/SFNSMono.ttf');

  // Load FluentIcons directly from third_party/fluent_ui/fonts/FluentIcons.ttf
  // under both the package-prefixed and bare family names.
  const iconFontPath = 'third_party/fluent_ui/fonts/FluentIcons.ttf';
  await loadFont('packages/fluent_ui/FluentIcons', iconFontPath);
  await loadFont('FluentIcons', iconFontPath);
}
