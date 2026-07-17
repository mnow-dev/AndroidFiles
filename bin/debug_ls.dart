// ignore_for_file: avoid_print

import 'package:android_files/src/adb_client.dart';

/// Dev harness: exercises AdbClient against the first connected device.
Future<void> main() async {
  final adb = AdbClient(r'D:\Dev\tools\platform-tools\adb.exe');
  final devices = await adb.devices();
  print('devices: ${devices.map((d) => '${d.serial} ${d.state} ${d.model}').toList()}');
  if (devices.isEmpty) return;
  final serial = devices.first.serial;
  final entries = await adb.list(serial, '/sdcard');
  print('entries: ${entries.length}');
  for (final e in entries.take(8)) {
    print('  ${e.isDir ? 'd' : '-'} ${e.path} (${e.size}) ${e.modified}');
  }
  print('hasTar: ${await adb.hasTar(serial)}');
  print('sizeOf DCIM: ${await adb.sizeOf(serial, '/sdcard/DCIM')}');
  print('fileCount DCIM: ${await adb.fileCount(serial, '/sdcard/DCIM')}');
}
