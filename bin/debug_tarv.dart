// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  const adb = r'D:\Dev\tools\platform-tools\adb.exe';
  final p = await Process.start(adb, ['exec-out', "tar -cvf - -C '/sdcard' 'Alarms'"]);
  var stdoutBytes = 0;
  final stderrLines = <String>[];
  final done = Future.wait([
    p.stdout.forEach((c) => stdoutBytes += c.length),
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(stderrLines.add),
  ]);
  await done;
  print('exit=${await p.exitCode} stdoutBytes=$stdoutBytes');
  print('stderr lines: $stderrLines');
}
