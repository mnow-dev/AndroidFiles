import 'dart:io';

import 'package:archive/archive.dart';

/// Finds or installs adb so the app works on machines without platform-tools.
class AdbInstaller {
  static const _zipUrl =
      'https://dl.google.com/android/repository/platform-tools-latest-windows.zip';

  static String get managedDir =>
      '${Platform.environment['LOCALAPPDATA'] ?? '.'}\\AndroidFiles\\platform-tools';

  static String get managedAdb => '$managedDir\\adb.exe';

  /// True if [path] runs and reports a version.
  static Future<bool> isUsable(String path) async {
    try {
      final r = await Process.run(path, ['version']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Search settings-independent locations: PATH, common SDK dirs, and our
  /// own managed copy.
  static Future<String?> findAdb() async {
    final candidates = [
      managedAdb,
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists() && await isUsable(c)) return c;
    }
    try {
      final r = await Process.run('where.exe', ['adb']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim().split('\n').first.trim();
        if (p.isNotEmpty && await isUsable(p)) return p;
      }
    } catch (_) {}
    return null;
  }

  /// Download platform-tools from Google and extract adb into [destDir]
  /// (default: %LOCALAPPDATA%\AndroidFiles). Reports 0..1 progress, or null
  /// while extracting. Returns the adb.exe path.
  static Future<String> install({
    void Function(double?)? onProgress,
    String? destDir,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(_zipUrl));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('platform-tools download failed: ${res.statusCode}');
      }
      final total = res.contentLength;
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
        if (total > 0) onProgress?.call(bytes.length / total);
      }
      onProgress?.call(null); // extracting

      final root = destDir ??
          '${Platform.environment['LOCALAPPDATA'] ?? '.'}\\AndroidFiles';
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final out = File('$root\\${entry.name.replaceAll('/', '\\')}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(entry.readBytes()!, flush: true);
      }
      final adb = '$root\\platform-tools\\adb.exe';
      if (!await isUsable(adb)) {
        throw StateError('downloaded adb failed its version check');
      }
      return adb;
    } finally {
      client.close();
    }
  }
}
