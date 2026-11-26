import 'dart:io';

/// The few places where Windows and macOS genuinely differ: path joining, the
/// per-user data folder, opening URLs, and external volumes on macOS.

/// Join a local directory and a tar-style relative path ('/'-separated, as the
/// phone, the manifests and tar entries all spell them).
String localJoin(String dir, String rel) {
  final native = Platform.isWindows ? rel.replaceAll('/', r'\') : rel;
  return '$dir${Platform.pathSeparator}$native';
}

/// Last component of a local path.
String localBaseName(String path) =>
    path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);

/// Per-user folder for settings and the managed adb download:
/// %APPDATA%\AndroidFiles on Windows, ~/Library/Application Support/AndroidFiles
/// on macOS, $XDG_DATA_HOME/AndroidFiles (or ~/.local/share) elsewhere.
String appDataDir({bool local = false}) {
  final env = Platform.environment;
  if (Platform.isWindows) {
    // adb lives under LOCALAPPDATA (machine-specific, not roamed); settings
    // under APPDATA, as they always have.
    final base = env[local ? 'LOCALAPPDATA' : 'APPDATA'] ?? '.';
    return '$base\\AndroidFiles';
  }
  final home = env['HOME'] ?? '.';
  if (Platform.isMacOS) return '$home/Library/Application Support/AndroidFiles';
  final xdg = env['XDG_DATA_HOME'];
  return '${xdg != null && xdg.isNotEmpty ? xdg : '$home/.local/share'}/AndroidFiles';
}

/// Open a URL (or folder) with the desktop's default handler.
Future<void> openExternal(String target) async {
  if (Platform.isWindows) {
    // `start` is a cmd builtin; the empty first argument is the window title,
    // so a URL isn't mistaken for one.
    await Process.run('cmd', ['/c', 'start', '', target]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [target]);
  } else {
    await Process.run('xdg-open', [target]);
  }
}

/// On macOS, external drives appear under `/Volumes/<name>` only while they are
/// plugged in. If [path] is on such a volume and it is not mounted right now,
/// returns the volume's name; otherwise null (including on other platforms).
///
/// A destination on an absent volume must never be written to: the path would
/// resolve onto the startup disk, and a backup meant for the external drive
/// would quietly fill the Mac instead.
String? unmountedVolume(String path) {
  if (!Platform.isMacOS) return null;
  final m = RegExp(r'^/Volumes/([^/]+)').firstMatch(path.trim());
  if (m == null) return null;
  return Directory('/Volumes/${m.group(1)}').existsSync() ? null : m.group(1);
}
