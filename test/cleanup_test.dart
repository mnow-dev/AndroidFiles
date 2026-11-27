import 'dart:io';

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/cleanup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/macos/mac_cleanup_view.dart';
import 'package:android_files/src/ui/macos/mac_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 11, 26);
  int daysAgo(int d) =>
      now.subtract(Duration(days: d)).millisecondsSinceEpoch ~/ 1000;

  final sampleFiles = <ScannedFile>[
    ScannedFile(
      relPath: 'DCIM/Camera/VID_old.mp4',
      size: 600 * 1024 * 1024,
      mtimeSec: daysAgo(140),
      backedUp: true,
      backupFilePath: '/tmp/backup/DCIM/Camera/VID_old.mp4',
    ),
    ScannedFile(
      relPath: 'DCIM/Camera/VID_recent.mp4',
      size: 400 * 1024 * 1024,
      mtimeSec: daysAgo(15),
      backedUp: false,
    ),
    ScannedFile(
      relPath: 'DCIM/Camera/IMG_old.jpg',
      size: 5 * 1024 * 1024,
      mtimeSec: daysAgo(200),
      backedUp: true,
      backupFilePath: '/tmp/backup/DCIM/Camera/IMG_old.jpg',
    ),
    ScannedFile(
      relPath: 'Download/installer.apk',
      size: 120 * 1024 * 1024,
      mtimeSec: daysAgo(110),
      backedUp: true,
      backupFilePath: '/tmp/backup/Download/installer.apk',
    ),
    ScannedFile(
      relPath: 'WhatsApp/Media/WhatsApp Video/clip.mp4',
      size: 80 * 1024 * 1024,
      mtimeSec: daysAgo(120),
      backedUp: false,
    ),
    ScannedFile(
      relPath: 'DCIM/.thumbnails/cache.jpg',
      size: 10 * 1024 * 1024,
      mtimeSec: daysAgo(2),
      backedUp: false,
    ),
  ];

  test('computeFolderUsage aggregates and sorts largest folders first', () {
    final folders = CleanupAnalyzer.computeFolderUsage(sampleFiles);
    expect(folders.first.relPath, 'DCIM/Camera');
    expect(folders.first.fileCount, 3);
    expect(folders.first.videoBytes, 1000 * 1024 * 1024);
    expect(folders.first.backedUpBytes, 605 * 1024 * 1024);
    expect(folders[1].relPath, 'Download');
  });

  test('buildProposals respects retention window and DCIM video intelligence', () {
    final p3m = CleanupAnalyzer.buildProposals(
      sampleFiles,
      retention: RetentionWindow.keep3Months,
      now: now,
    );
    final dcimVids = p3m.firstWhere((p) => p.id == 'dcim_videos');
    // Only VID_old.mp4 is >90 days old; VID_recent.mp4 is protected.
    expect(dcimVids.files.map((f) => f.name), ['VID_old.mp4']);
    expect(dcimVids.allBackedUp, true);

    final olderCam = p3m.firstWhere((p) => p.id == 'dcim_older');
    expect(olderCam.files.map((f) => f.name), containsAll(['VID_old.mp4', 'IMG_old.jpg']));

    final pAll = CleanupAnalyzer.buildProposals(
      sampleFiles,
      retention: RetentionWindow.all,
      now: now,
    );
    final allVids = pAll.firstWhere((p) => p.id == 'dcim_videos');
    expect(allVids.files.length, 2);
    expect(allVids.backedUpCount, 1);
    expect(allVids.notBackedUpCount, 1);

    final backedOnly = CleanupAnalyzer.buildProposals(
      sampleFiles,
      retention: RetentionWindow.all,
      onlyAlreadyBackedUp: true,
      now: now,
    );
    for (final p in backedOnly) {
      expect(p.allBackedUp, true);
    }
  });

  test('rankDuplicateCopies prefers DCIM/Camera over Download and WhatsApp', () {
    final ranked = CleanupAnalyzer.rankDuplicateCopies([
      ScannedFile(relPath: 'WhatsApp/Media/a.mp4', size: 1000, mtimeSec: 10),
      ScannedFile(relPath: 'Download/a.mp4', size: 1000, mtimeSec: 20),
      ScannedFile(relPath: 'DCIM/Camera/a.mp4', size: 1000, mtimeSec: 30),
    ]);
    expect(ranked.first.relPath, 'DCIM/Camera/a.mp4');
  });

  testWidgets(
    'MacCleanupView renders proposals, large files, duplicates, and review tabs',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final settings = Settings(
        adbPath: Platform.isWindows ? 'cmd' : '/usr/bin/true',
        lastDestination: Directory.systemTemp.path,
        checkForUpdates: false,
      );
      final controller = AppController(settings, startPolling: false);
      addTearDown(controller.dispose);

      const phone = AdbDevice(serial: '192.168.0.117:44533', state: 'device', model: 'Pixel 8');
      controller.devices = [phone];
      controller.selected = phone;
      controller.cleanup.files = sampleFiles;
      controller.cleanup.folders = CleanupAnalyzer.computeFolderUsage(sampleFiles);
      controller.cleanup.deviceSpace = (
        totalBytes: 128 * 1024 * 1024 * 1024,
        usedBytes: 94 * 1024 * 1024 * 1024,
        freeBytes: 34 * 1024 * 1024 * 1024,
      );
      controller.cleanup.selectFiles([sampleFiles.first]);

      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          theme: CupertinoThemeData(
            brightness: Brightness.light,
            primaryColor: MacPalette.light.green,
          ),
          home: CupertinoPageScaffold(child: MacCleanupView(app: controller)),
        ),
      );
      await tester.pump();

      expect(find.text('DCIM Videos Only'), findsOneWidget);
      expect(find.textContaining('to free'), findsOneWidget);

      await tester.tap(find.text('Large Files & Folders'));
      await tester.pump();
      expect(find.text('DCIM/Camera'), findsOneWidget);

      await tester.tap(find.text('Duplicates'));
      await tester.pump();
      expect(find.text('Find Duplicates'), findsOneWidget);

      await tester.tap(find.text('Review (1)'));
      await tester.pump();
      expect(find.text('VID_old.mp4'), findsOneWidget);

      controller.cleanup.appStorage = AdbClient.parseDiskstats(
        '''
App Size: 400000000
App Data Size: 600000000
App Cache Size: 150000000
Package Names: ["com.discord","com.android.systemui"]
App Sizes: [150000000,250000000]
App Data Sizes: [500000000,100000000]
Cache Sizes: [120000000,30000000]
''',
        const {'com.discord'},
      );
      await tester.tap(find.text('Apps'));
      await tester.pump();
      expect(find.text('Discord'), findsOneWidget);
      expect(find.text('com.discord'), findsOneWidget);
      expect(find.textContaining('Trim All Caches'), findsOneWidget);
    },
    skip: Platform.isWindows,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  test('parseDiskstats parses static APK, app data, reclaimable cache, and package validation', () {
    const sample = '''
App Size: 500000000
App Data Size: 900000000
App Cache Size: 300000000
Package Names: ["jp.naver.line.android","com.openai.chatgpt","com.android.systemui","com.empty.overlay"]
App Sizes: [120000000,90000000,290000000,0]
App Data Sizes: [600000000,200000000,100000000,0]
Cache Sizes: [250000000,40000000,10000000,0]
''';
    final report = AdbClient.parseDiskstats(
      sample,
      const {'jp.naver.line.android', 'com.openai.chatgpt'},
    );
    expect(report.apps.length, 3); // zero-byte system overlay skipped
    expect(report.userAppCount, 2);
    expect(report.totalStaticBytes, 1400000000);
    expect(report.totalReclaimableBytes, 300000000);
    expect(report.apps.first.packageName, 'jp.naver.line.android');
    expect(report.apps.first.displayName, 'LINE');
    expect(report.apps.first.reclaimableBytes, 250000000);
    expect(report.apps.first.staticBytes, 720000000);
    expect(report.apps.first.isUserApp, isTrue);

    final ctrl = CleanupController(adb: AdbClient('adb'), log: (_) {});
    ctrl.appStorage = report;
    // Defaults to user apps only
    expect(ctrl.filteredApps.map((a) => a.packageName), [
      'jp.naver.line.android',
      'com.openai.chatgpt',
    ]);
    // Include system apps + sort by static APK puts systemui first
    ctrl.setShowSystemApps(true);
    ctrl.setAppSort(AppSortMode.app);
    expect(ctrl.filteredApps.first.packageName, 'com.android.systemui');
    // Filter by search query
    ctrl.setAppSearchQuery('chatgpt');
    expect(ctrl.filteredApps.map((a) => a.displayName), ['ChatGPT']);

    expect(AdbClient.isValidPackageName('com.openai.chatgpt'), isTrue);
    expect(AdbClient.isValidPackageName('com.foo; rm -rf /'), isFalse);
  });
}
