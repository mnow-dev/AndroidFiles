import 'dart:convert';
import 'dart:io';

/// Size + mtime of one file, the fingerprint used for incremental compares.
class FileMeta {
  final int size;
  final int mtimeSec;
  const FileMeta(this.size, this.mtimeSec);
}

/// Parse `find <path> -type f -exec stat -c '%s|%Y|%n' {} +` output into
/// {relative path -> meta}. [parentPrefix] is the device-side parent dir
/// (e.g. `/sdcard`); keys come out relative to it (`DCIM/a.jpg`), matching
/// the paths tar stores. Malformed lines (e.g. filenames containing
/// newlines) are skipped — worst case those files always re-transfer.
Map<String, FileMeta> parseDeviceManifest(String raw, String parentPrefix) {
  final prefix = parentPrefix.endsWith('/') ? parentPrefix : '$parentPrefix/';
  final result = <String, FileMeta>{};
  for (final line in const LineSplitter().convert(raw)) {
    final a = line.indexOf('|');
    final b = line.indexOf('|', a + 1);
    if (a <= 0 || b <= a) continue;
    final size = int.tryParse(line.substring(0, a));
    final mtime = int.tryParse(line.substring(a + 1, b));
    final path = line.substring(b + 1);
    if (size == null || mtime == null || !path.startsWith(prefix)) continue;
    result[path.substring(prefix.length)] = FileMeta(size, mtime);
  }
  return result;
}

/// Walk [baseDir]/[topName] and return {relative path -> meta} with
/// tar-style forward-slash keys relative to [baseDir].
Future<Map<String, FileMeta>> localManifest(String baseDir, String topName) async {
  final root = Directory('$baseDir${Platform.pathSeparator}$topName');
  final result = <String, FileMeta>{};
  if (!await root.exists()) return result;
  final basePrefix = '$baseDir${Platform.pathSeparator}';
  await for (final e in root.list(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final stat = await e.stat();
    final rel = e.path.substring(basePrefix.length).replaceAll('\\', '/');
    result[rel] = FileMeta(stat.size, stat.modified.millisecondsSinceEpoch ~/ 1000);
  }
  return result;
}

/// Parse `find <path> -type f -exec md5sum {} +` output ("hash  /abs/path")
/// into {relative path -> hash}, relative to [parentPrefix].
Map<String, String> parseMd5Manifest(String raw, String parentPrefix) {
  final prefix = parentPrefix.endsWith('/') ? parentPrefix : '$parentPrefix/';
  final re = RegExp(r'^([0-9a-fA-F]{32})\s+(.+)$');
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(raw)) {
    final m = re.firstMatch(line);
    if (m == null) continue;
    final path = m.group(2)!;
    if (!path.startsWith(prefix)) continue;
    result[path.substring(prefix.length)] = m.group(1)!.toLowerCase();
  }
  return result;
}

/// Compile ignore [patterns] into matchers. Each pattern is a '/'-separated
/// glob (case-insensitive; `*` and `?` match within a single segment). It
/// matches a run of consecutive path segments anywhere in a relative path —
/// so `.thumbnails` skips any such directory at any depth, and `Android/data`
/// skips exactly that subtree. Blank/whitespace patterns are dropped.
List<RegExp> compileIgnorePatterns(Iterable<String> patterns) {
  final out = <RegExp>[];
  for (final raw in patterns) {
    final segs = raw
        .trim()
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(_globToRegex)
        .toList();
    if (segs.isEmpty) continue;
    out.add(RegExp('(^|/)${segs.join('/')}(/|\$)', caseSensitive: false));
  }
  return out;
}

String _globToRegex(String seg) {
  final sb = StringBuffer();
  for (final rune in seg.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '*') {
      sb.write('[^/]*');
    } else if (ch == '?') {
      sb.write('[^/]');
    } else {
      sb.write(RegExp.escape(ch));
    }
  }
  return sb.toString();
}

/// Whether [relPath] (tar-style, '/'-separated) matches any compiled pattern.
bool isIgnored(String relPath, List<RegExp> compiled) {
  for (final re in compiled) {
    if (re.hasMatch(relPath)) return true;
  }
  return false;
}

/// The default clutter (caches/system files) the "skip clutter" option
/// removes. Kept conservative: caches and recovery cruft that regenerate or
/// aren't useful in a backup — never user documents or media.
const defaultClutterPatterns = <String>[
  '.thumbnails', // gallery thumbnail caches
  '.trashed-*', // Android per-file trash
  'LOST.DIR', // FAT filesystem recovery fragments
  '.thumbdata*', // messenger thumbnail blobs
  'Android/data', // per-app caches/data (often unreadable anyway)
  'Android/obb', // app expansion downloads
];

class ManifestDiff {
  /// On device, missing or different locally — must transfer.
  final List<String> changed;

  /// On device and identical locally — can be skipped/hardlinked.
  final List<String> unchanged;

  /// Present locally but gone from the device — kept, but reported.
  final List<String> localOnly;

  ManifestDiff(this.changed, this.unchanged, this.localOnly);
}

/// Compare manifests by size + mtime. [toleranceSec] absorbs filesystem
/// timestamp granularity differences (tar stores whole seconds).
ManifestDiff diffManifests(
  Map<String, FileMeta> device,
  Map<String, FileMeta> local, {
  int toleranceSec = 2,
}) {
  final changed = <String>[];
  final unchanged = <String>[];
  for (final e in device.entries) {
    final l = local[e.key];
    final same = l != null &&
        l.size == e.value.size &&
        (l.mtimeSec - e.value.mtimeSec).abs() <= toleranceSec;
    (same ? unchanged : changed).add(e.key);
  }
  final localOnly = [
    for (final k in local.keys)
      if (!device.containsKey(k)) k
  ];
  return ManifestDiff(changed, unchanged, localOnly);
}
