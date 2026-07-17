import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'manifest.dart';
import 'models.dart';

/// Thin wrapper around the adb CLI.
class AdbClient {
  /// Mutable so a freshly auto-downloaded adb can be swapped in at runtime.
  String adbPath;

  AdbClient(this.adbPath);

  /// Quote an argument for the device-side shell (adb joins exec-out args
  /// with spaces and runs them through /system/bin/sh).
  static String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<ProcessResult> _run(List<String> args, {Duration timeout = const Duration(seconds: 30)}) {
    return Process.run(adbPath, args, stdoutEncoding: utf8, stderrEncoding: utf8)
        .timeout(timeout);
  }

  /// Run a command on the device shell. The command must be a single string:
  /// adb escapes separately-passed arguments, so embedded quotes/pipes only
  /// survive when the whole command is one argument. `shell` (unlike
  /// `exec-out`) propagates the device-side exit code.
  Future<ProcessResult> _shell(String serial, String command,
      {Duration timeout = const Duration(seconds: 30)}) {
    return _run(['-s', serial, 'shell', command], timeout: timeout);
  }

  Future<List<AdbDevice>> devices() async {
    final r = await _run(['devices', '-l']);
    final devices = <AdbDevice>[];
    for (final line in const LineSplitter().convert(r.stdout as String).skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final model = parts
          .firstWhere((p) => p.startsWith('model:'), orElse: () => '')
          .replaceFirst('model:', '')
          .replaceAll('_', ' ');
      devices.add(AdbDevice(serial: parts[0], state: parts[1], model: model));
    }
    return devices;
  }

  /// List a directory using toybox ls (stable output format on Android 6+).
  Future<List<RemoteEntry>> list(String serial, String path) async {
    // Trailing slash makes ls list the contents of symlinked dirs (/sdcard
    // is a symlink to /storage/self/primary) instead of the link itself.
    final target = path.endsWith('/') ? path : '$path/';
    final r = await _shell(serial, 'ls -lA ${shellQuote(target)}');
    if (r.exitCode != 0) {
      throw AdbException('ls $path failed: ${r.stderr}'.trim());
    }
    final entries = <RemoteEntry>[];
    final re = RegExp(
        r'^([bcdlps-][rwxsStT-]{9}\+?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$');
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      final m = re.firstMatch(line);
      if (m == null) continue; // "total N", char devices, permission errors
      final type = m.group(1)![0];
      var name = m.group(5)!;
      final isLink = type == 'l';
      if (isLink) {
        final arrow = name.indexOf(' -> ');
        if (arrow != -1) name = name.substring(0, arrow);
      }
      entries.add(RemoteEntry(
        name: name,
        path: path == '/' ? '/$name' : '$path/$name',
        // Treat symlinks as directories so /sdcard-style links stay browsable.
        isDir: type == 'd' || isLink,
        isLink: isLink,
        size: int.parse(m.group(2)!),
        modified: '${m.group(3)} ${m.group(4)}',
      ));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Approximate size in bytes of a path (du counts allocated blocks).
  Future<int> sizeOf(String serial, String path) async {
    final r = await _shell(serial, 'du -sk ${shellQuote(path)}',
        timeout: const Duration(minutes: 5));
    final m = RegExp(r'^(\d+)').firstMatch((r.stdout as String).trim());
    return m == null ? 0 : int.parse(m.group(1)!) * 1024;
  }

  /// Number of regular files under a path.
  Future<int> fileCount(String serial, String path) async {
    final r = await _shell(serial, 'find ${shellQuote(path)} -type f | wc -l',
        timeout: const Duration(minutes: 5));
    return int.tryParse((r.stdout as String).trim()) ?? -1;
  }

  /// Size+mtime manifest of every regular file under [path], keyed by path
  /// relative to [path]'s parent (matching tar entry names).
  Future<Map<String, FileMeta>> manifest(String serial, String path) async {
    final r = await _shell(
        serial, "find ${shellQuote(path)} -type f -exec stat -c '%s|%Y|%n' {} +",
        timeout: const Duration(minutes: 10));
    if (r.exitCode != 0) {
      throw AdbException('manifest of $path failed: ${r.stderr}'.trim());
    }
    return parseDeviceManifest(r.stdout as String, dirname(path));
  }

  /// Push [lines] to a temp file on the device; returns its device path.
  Future<String> pushLines(String serial, List<String> lines) async {
    final local = File(
        '${Directory.systemTemp.path}\\af_list_${DateTime.now().microsecondsSinceEpoch}.txt');
    await local.writeAsString(lines.join('\n'), flush: true);
    final devicePath =
        '/data/local/tmp/androidfiles_${DateTime.now().millisecondsSinceEpoch}.txt';
    try {
      final r = await _run(['-s', serial, 'push', local.path, devicePath],
          timeout: const Duration(minutes: 2));
      if (r.exitCode != 0) {
        throw AdbException('push list failed: ${r.stderr}'.trim());
      }
    } finally {
      await local.delete().catchError((_) => local);
    }
    return devicePath;
  }

  Future<void> remove(String serial, String devicePath) async {
    await _shell(serial, 'rm -f ${shellQuote(devicePath)}');
  }

  /// Tar only the files listed (one relative path per line) in the device
  /// file [deviceListPath], relative to [parent].
  Future<Process> startTarStreamFromList(
      String serial, String parent, String deviceListPath) {
    return Process.start(adbPath, [
      '-s', serial, 'exec-out',
      'tar -cf - -C ${shellQuote(parent)} -T ${shellQuote(deviceListPath)}',
    ]);
  }

  /// Whether the device shell has a usable tar.
  Future<bool> hasTar(String serial) async {
    final r = await _shell(serial, 'tar --help');
    return r.exitCode == 0;
  }

  /// md5 of every regular file under [path], keyed relative to its parent.
  Future<Map<String, String>> md5Manifest(String serial, String path) async {
    final r = await _shell(
        serial, 'find ${shellQuote(path)} -type f -exec md5sum {} +',
        timeout: const Duration(minutes: 30));
    if (r.exitCode != 0) {
      throw AdbException('md5sum of $path failed: ${r.stderr}'.trim());
    }
    return parseMd5Manifest(r.stdout as String, dirname(path));
  }

  /// Wireless devices discovered via mDNS (`adb mdns services`).
  /// `_adb-tls-pairing` = phone showing a pairing screen;
  /// `_adb-tls-connect` = paired phone ready for `adb connect`.
  Future<List<MdnsService>> mdnsServices() async {
    final r = await _run(['mdns', 'services'], timeout: const Duration(seconds: 10));
    final out = <MdnsService>[];
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 3 || !parts[1].startsWith('_adb-tls-')) continue;
      out.add(MdnsService(
        instance: parts[0],
        type: parts[1].replaceAll(RegExp(r'\.$'), ''),
        address: parts[2],
      ));
    }
    return out;
  }

  /// Pair with a device over Wi-Fi (Android 11+ pairing dialog).
  Future<String> pair(String hostPort, String code) async {
    final r = await _run(['pair', hostPort, code], timeout: const Duration(seconds: 60));
    return '${r.stdout}${r.stderr}'.trim();
  }

  /// Connect to a device over Wi-Fi.
  Future<String> connect(String hostPort) async {
    final r = await _run(['connect', hostPort], timeout: const Duration(seconds: 60));
    return '${r.stdout}${r.stderr}'.trim();
  }

  /// Start a device-side tar stream of [path]; caller owns the process.
  /// exec-out keeps stdout binary-safe; the command is one string because
  /// adb escapes separately-passed arguments.
  Future<Process> startTarStream(String serial, String path) {
    final parent = dirname(path);
    final name = _basename(path);
    return Process.start(adbPath, [
      '-s', serial, 'exec-out',
      'tar -cf - -C ${shellQuote(parent)} ${shellQuote(name)}',
    ]);
  }

  /// Fallback: plain adb pull (used when device tar is unavailable).
  /// -a preserves mtimes, which incremental compares rely on.
  Future<Process> startPull(String serial, String path, String destDir) {
    return Process.start(adbPath, ['-s', serial, 'pull', '-a', path, destDir]);
  }

  static String dirname(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  static String _basename(String p) => p.substring(p.lastIndexOf('/') + 1);
}

class MdnsService {
  final String instance;
  final String type;
  final String address; // ip:port

  const MdnsService(
      {required this.instance, required this.type, required this.address});

  bool get isPairing => type.startsWith('_adb-tls-pairing');
  bool get isConnect => type.startsWith('_adb-tls-connect');
  String get ip => address.split(':').first;
}

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override
  String toString() => message;
}
