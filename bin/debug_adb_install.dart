// ignore_for_file: avoid_print

import 'dart:io';

import 'package:android_files/src/adb_installer.dart';

Future<void> main() async {
  final dest = Directory.systemTemp.createTempSync('adb_install_test_');
  print('installing into ${dest.path}');
  final path = await AdbInstaller.install(
    destDir: dest.path,
    onProgress: (p) => p == null
        ? print('extracting…')
        : stdout.write('\r${(p * 100).toStringAsFixed(0)}%'),
  );
  print('\nadb at: $path');
  final r = await Process.run(path, ['version']);
  print((r.stdout as String).split('\n').first);
  dest.deleteSync(recursive: true);
  print('cleaned up');
}
