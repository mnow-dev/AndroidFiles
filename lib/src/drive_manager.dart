import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'settings.dart';

/// Starts/stops the AdbDrive WinFsp host (Phase 2 prototype) so the phone
/// shows up as a drive letter in Explorer.
class DriveManager extends ChangeNotifier {
  final Settings settings;
  final void Function(String) log;

  Process? _proc;

  DriveManager({required this.settings, required this.log});

  String get mountPoint => settings.driveMountPoint;

  bool get mounted => _proc != null;
  bool get available => File(settings.driveExePath).existsSync();

  Future<void> mount(String serial, String adbPath) async {
    if (_proc != null) return;
    if (!available) {
      log('Drive host not found at ${settings.driveExePath} — build it with: '
          'dotnet publish drive -c Release -o drive\\publish');
      return;
    }
    // A killed host can't clean its pull cache; sweep it before mounting.
    final stale = Directory('${Directory.systemTemp.path}\\AdbDrive');
    if (await stale.exists()) {
      await stale.delete(recursive: true).catchError((_) => stale);
    }
    final proc = await Process.start(settings.driveExePath, [
      '--serial', serial,
      '--mount', mountPoint,
      '--adb', adbPath,
      if (settings.driveWritable) '--writable',
    ]);
    _proc = proc;
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => log('[drive] $l'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => log('[drive] $l'));
    unawaited(proc.exitCode.then((code) {
      _proc = null;
      log('Drive unmounted (host exited ${code == 0 ? 'cleanly' : 'with $code'})');
      notifyListeners();
    }));
    log(settings.driveWritable
        ? 'Mounted $mountPoint WRITABLE — Explorer changes modify the phone!'
        : 'Mounted $mountPoint — the phone is now visible in Explorer');
    notifyListeners();
  }

  Future<void> unmount() async {
    // WinFsp tears the mount down when the host process dies.
    _proc?.kill();
  }
}
