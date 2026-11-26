import 'dart:io';

import 'package:archive/archive.dart';

import 'os.dart';

/// Finds or installs adb so the app works on machines without platform-tools.
class AdbInstaller {
  static String get _zipUrl {
    final os = Platform.isWindows
        ? 'windows'
        : Platform.isMacOS
        ? 'darwin'
        : 'linux';
    return 'https://dl.google.com/android/repository/platform-tools-latest-$os.zip';
  }

  static String get _adbName => Platform.isWindows ? 'adb.exe' : 'adb';

  /// Where downloaded platform-tools are unpacked (`<this>/platform-tools`).
  static String get managedRoot => appDataDir(local: true);

  static String get managedDir =>
      '$managedRoot${Platform.pathSeparator}platform-tools';

  static String get managedAdb =>
      '$managedDir${Platform.pathSeparator}$_adbName';

  /// Places adb is commonly installed, besides our own managed copy. An app
  /// started from Finder doesn't inherit the shell's PATH, so on macOS the
  /// usual Homebrew and Android Studio locations are listed explicitly.
  static List<String> get knownLocations {
    final env = Platform.environment;
    if (Platform.isWindows) {
      return [
        '${env['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
      ];
    }
    final home = env['HOME'] ?? '';
    return [
      if (Platform.isMacOS) '$home/Library/Android/sdk/platform-tools/adb',
      if (!Platform.isMacOS) '$home/Android/Sdk/platform-tools/adb',
      '/opt/homebrew/bin/adb',
      '/usr/local/bin/adb',
      '/usr/bin/adb',
    ];
  }

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
    for (final c in [managedAdb, ...knownLocations]) {
      if (await File(c).exists() && await isUsable(c)) return c;
    }
    try {
      final r = await Process.run(
          Platform.isWindows ? 'where.exe' : 'which', ['adb']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim().split('\n').first.trim();
        if (p.isNotEmpty && await isUsable(p)) return p;
      }
    } catch (_) {}
    return null;
  }

  /// Download platform-tools from Google and extract it into [destDir]
  /// (default: [managedRoot]). Reports 0..1 progress, or null while
  /// extracting. Returns the adb path.
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

      final root = destDir ?? managedRoot;
      final archive = ZipDecoder().decodeBytes(bytes);
      final executables = <String>[];
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final out = File(localJoin(root, entry.name));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(entry.readBytes()!, flush: true);
        // Zip extraction drops the executable bit; put it back where the
        // archive had it (adb, fastboot, …) or nothing will run.
        if (!Platform.isWindows && entry.unixPermissions & 0x49 != 0) {
          executables.add(out.path);
        }
      }
      if (executables.isNotEmpty) {
        await Process.run('chmod', ['755', ...executables]);
      }
      final adb = localJoin(root, 'platform-tools/$_adbName');
      if (!await isUsable(adb)) {
        throw StateError('downloaded adb failed its version check');
      }
      return adb;
    } finally {
      client.close();
    }
  }
}
