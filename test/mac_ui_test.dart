import 'dart:io';

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/backup_engine.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/macos/mac_home_screen.dart';
import 'package:android_files/src/ui/macos/mac_theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrapMac(AppController controller, {Brightness brightness = Brightness.light}) {
  return CupertinoApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    theme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: brightness == Brightness.dark
          ? MacPalette.dark.green
          : MacPalette.light.green,
    ),
    home: MacHomeScreen(app: controller),
  );
}

void main() {
  testWidgets(
    'MacHomeScreen renders Proposal A layout in light and dark modes',
    (tester) async {
      tester.view.physicalSize = const Size(1040, 680);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final settings = Settings(
        adbPath: Platform.isWindows ? 'cmd' : '/usr/bin/true',
        lastDestination: Directory.systemTemp.path,
        checkForUpdates: false,
        profiles: [
          Profile(
            name: 'Photos & Docs',
            paths: ['/sdcard/DCIM', '/sdcard/Documents'],
            destination: Directory.systemTemp.path,
            scheduleTime: '03:00',
          ),
        ],
      );
      final controller = AppController(settings, startPolling: false);
      addTearDown(controller.dispose);

      const phone = AdbDevice(
        serial: '3A191FDH2004KL',
        state: 'device',
        model: 'Pixel 8 Pro',
      );
      controller.devices = [phone];
      controller.selected = phone;
      controller.expanded.add(AppController.rootPath);
      controller.children[AppController.rootPath] = const [
        RemoteEntry(name: 'DCIM', path: '/sdcard/DCIM', isDir: true),
        RemoteEntry(name: 'Documents', path: '/sdcard/Documents', isDir: true),
        RemoteEntry(
          name: 'IMG_001.jpg',
          path: '/sdcard/IMG_001.jpg',
          isDir: false,
          size: 3200000,
        ),
      ];
      controller.checked.add('/sdcard/DCIM');
      controller.selectionBytes = 40 * 1024 * 1024;

      // Light mode + onboarding state
      await tester.pumpWidget(_wrapMac(controller, brightness: Brightness.light));
      await tester.pump();
      expect(find.text('Pixel 8 Pro'), findsAtLeastNWidgets(1));
      expect(find.text('Photos & Docs'), findsOneWidget);
      expect(find.text('DCIM'), findsOneWidget);
      expect(find.text('Back up your phone in 3 steps'), findsOneWidget);

      // Add an active job + switch to Dark mode + show console drawer
      final job = BackupJob(
        source: const RemoteEntry(
          name: 'DCIM',
          path: '/sdcard/DCIM',
          isDir: true,
        ),
        serial: phone.serial,
        destDir: Directory.systemTemp.path,
      )
        ..status = JobStatus.running
        ..totalBytes = 100 * 1024 * 1024
        ..doneBytes = 46 * 1024 * 1024
        ..currentFile = 'DCIM/Camera/PXL_001.jpg';
      controller.engine.jobs.add(job);
      controller.settings.showLog = true;
      controller.log('Streaming /sdcard/DCIM');

      await tester.pumpWidget(_wrapMac(controller, brightness: Brightness.dark));
      await tester.pump();
      expect(find.text('/sdcard/DCIM'), findsOneWidget);
      expect(find.text('DCIM/Camera/PXL_001.jpg'), findsOneWidget);
    },
    skip: Platform.isWindows,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
