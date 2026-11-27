import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'adb_client.dart';
import 'models.dart';
import 'os.dart';

/// Supported Quick Look preview categories.
enum PreviewKind {
  image,
  heicImage,
  markdown,
  html,
  json,
  text,
  pdf,
  video,
  audio,
  unsupported,
}

/// Descriptor for a single file shown in the Quick Look lightbox.
///
/// Works identically for files in the Back Up tree (`RemoteEntry`) and files in
/// Clean Up Space (`ScannedFile`).
class PreviewItem {
  final String name;
  final String devicePath;
  final int size;
  final String modified;
  final EntryBackupStatus backupStatus;
  final PreviewKind kind;

  /// Optional selection state & toggle callback so users can check/uncheck a
  /// file for backup or cleanup directly while inspecting it in Quick Look.
  final bool Function()? isChecked;
  final VoidCallback? onToggleChecked;
  final String? checkLabel;

  PreviewItem({
    required this.name,
    required this.devicePath,
    required this.size,
    required this.modified,
    this.backupStatus = EntryBackupStatus.unknown,
    PreviewKind? kind,
    this.isChecked,
    this.onToggleChecked,
    this.checkLabel,
  }) : kind = kind ?? PreviewService.classifyKind(name);
}

/// Simple typedef to avoid importing `flutter/foundation.dart` in pure Dart.
typedef VoidCallback = void Function();

/// Result of loading a [PreviewItem] for Quick Look display.
class PreviewData {
  final PreviewItem item;
  final File? localFile;
  final bool fromLocalBackup;
  final Uint8List? imageBytes;
  final String? textContent;
  final bool truncated;
  final int? pdfPageCount;
  final bool needsDownloadConfirm;
  final String? error;

  const PreviewData({
    required this.item,
    this.localFile,
    this.fromLocalBackup = false,
    this.imageBytes,
    this.textContent,
    this.truncated = false,
    this.pdfPageCount,
    this.needsDownloadConfirm = false,
    this.error,
  });
}

/// Structured block for the built-in lightweight Markdown and HTML readers.
enum RichBlockType { h1, h2, h3, paragraph, code, quote, listItem, rule }

class RichBlock {
  final RichBlockType type;
  final String text;
  const RichBlock(this.type, this.text);
}

/// Fetches, caches, and prepares on-demand file previews for Quick Look.
///
/// Design goals:
/// - **Instant local hit:** if the file already exists in the active backup
///   destination (mirror, latest snapshot, external `SD-<UUID>/`, or nested
///   subfolder backup), load directly from disk in <5ms with zero ADB traffic.
/// - **Fast head-read for text/code/Markdown/HTML/JSON:** uses `adb exec-out
///   head -c 524288` so even huge log files preview in milliseconds.
/// - **Safe bandwidth limits:** large remote images (>40 MB), PDFs (>25 MB),
///   and videos (>25 MB) ask before pulling unless already backed up locally.
/// - **Bounded LRU cache:** cached files live in a dedicated temp directory
///   capped at 150 MB and cleaned up on app exit.
class PreviewService {
  static const int maxTextPreviewBytes = 512 * 1024; // 512 KB
  static const int autoImageLimitBytes = 40 * 1024 * 1024; // 40 MB
  static const int autoMediaLimitBytes = 25 * 1024 * 1024; // 25 MB
  static const int maxCacheBytes = 150 * 1024 * 1024; // 150 MB

  static final RegExp _snapshotRe =
      RegExp(r'^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$');

  final AdbClient adb;
  final void Function(String) log;
  final Directory? _cacheDirOverride;

  Directory? _cacheDir;

  PreviewService({
    required this.adb,
    required this.log,
    Directory? cacheDir,
  }) : _cacheDirOverride = cacheDir;

  static const Set<String> _imageExts = {
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'wbmp',
  };
  static const Set<String> _heicExts = {'heic', 'heif'};
  static const Set<String> _markdownExts = {'md', 'markdown'};
  static const Set<String> _htmlExts = {'html', 'htm'};
  static const Set<String> _jsonExts = {'json'};
  static const Set<String> _textExts = {
    'txt', 'log', 'csv', 'tsv', 'xml', 'yaml', 'yml', 'ini', 'cfg', 'conf',
    'env', 'sh', 'bash', 'zsh', 'py', 'dart', 'js', 'jsx', 'ts', 'tsx', 'css',
    'scss', 'java', 'kt', 'kts', 'swift', 'c', 'cpp', 'cc', 'h', 'hpp', 'rs',
    'go', 'sql', 'vcf', 'ics', 'properties', 'gradle', 'toml', 'srt', 'vtt',
    'gitignore', 'dockerfile', 'makefile', 'readme', 'license',
  };
  static const Set<String> _pdfExts = {'pdf'};
  static const Set<String> _videoExts = {
    'mp4', 'mov', 'mkv', 'webm', '3gp', 'm4v', 'avi', 'ts',
  };
  static const Set<String> _audioExts = {
    'mp3', 'm4a', 'flac', 'wav', 'ogg', 'aac', 'opus',
  };

  /// Classify a filename into its [PreviewKind].
  static PreviewKind classifyKind(String name) {
    final lower = name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot == -1 || dot == lower.length - 1) {
      if (lower == 'readme' || lower == 'license' || lower == 'makefile') {
        return PreviewKind.text;
      }
      return PreviewKind.unsupported;
    }
    final ext = lower.substring(dot + 1);
    if (_imageExts.contains(ext)) return PreviewKind.image;
    if (_heicExts.contains(ext)) return PreviewKind.heicImage;
    if (_markdownExts.contains(ext)) return PreviewKind.markdown;
    if (_htmlExts.contains(ext)) return PreviewKind.html;
    if (_jsonExts.contains(ext)) return PreviewKind.json;
    if (_textExts.contains(ext)) return PreviewKind.text;
    if (_pdfExts.contains(ext)) return PreviewKind.pdf;
    if (_videoExts.contains(ext)) return PreviewKind.video;
    if (_audioExts.contains(ext)) return PreviewKind.audio;
    return PreviewKind.unsupported;
  }

  static bool isTextLike(PreviewKind kind) =>
      kind == PreviewKind.text ||
      kind == PreviewKind.markdown ||
      kind == PreviewKind.html ||
      kind == PreviewKind.json;

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDir != null && await _cacheDir!.exists()) return _cacheDir!;
    final dir = _cacheDirOverride ??
        Directory(
          localJoin(Directory.systemTemp.path, 'androidfiles_preview_cache'),
        );
    await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// Resolve a matching local backup copy of [devicePath] under [destRoot],
  /// supporting mirror, latest timestamped snapshot, external `SD-<UUID>/`,
  /// and nested subfolder backups (e.g. `<dest>/Camera/a.jpg`).
  static Future<File?> resolveLocalBackupFile(
    String devicePath,
    int expectedSize,
    String? destRoot,
  ) async {
    final trimmed = destRoot?.trim() ?? '';
    if (trimmed.isEmpty || unmountedVolume(trimmed) != null) return null;
    final rootDir = Directory(trimmed);
    if (!await rootDir.exists()) return null;

    // Prefer latest dated snapshot if present, else mirror root.
    String effectiveBase = trimmed;
    try {
      final names = <String>[];
      await for (final entity in rootDir.list(followLinks: false)) {
        if (entity is Directory) {
          final name =
              entity.path.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
          if (_snapshotRe.hasMatch(name)) names.add(name);
        }
      }
      if (names.isNotEmpty) {
        names.sort();
        effectiveBase = localJoin(trimmed, names.last);
      }
    } catch (_) {}

    final extId = externalStorageId(devicePath);
    final String rel;
    final String localBase;
    if (extId != null) {
      final prefix = '/storage/$extId/';
      if (!devicePath.startsWith(prefix)) return null;
      rel = devicePath.substring(prefix.length);
      final namespaced = localJoin(effectiveBase, 'SD-$extId');
      localBase =
          await Directory(namespaced).exists() ? namespaced : effectiveBase;
    } else if (devicePath.startsWith('/sdcard/')) {
      rel = devicePath.substring('/sdcard/'.length);
      localBase = effectiveBase;
    } else {
      return null;
    }

    final segs = rel.split('/');
    for (var start = 0; start < segs.length; start++) {
      final candidateRel = segs.sublist(start).join('/');
      final localPath = localJoin(localBase, candidateRel);
      final stat = await FileStat.stat(localPath);
      if (stat.type != FileSystemEntityType.file) continue;
      if (expectedSize > 0 && stat.size != expectedSize) continue;
      return File(localPath);
    }
    return null;
  }

  /// Build a deterministic cache path for `(serial, devicePath, size, modified)`.
  Future<File> _cacheFileFor(String serial, PreviewItem item) async {
    final dir = await _ensureCacheDir();
    final key = '$serial|${item.devicePath}|${item.size}|${item.modified}';
    final hash = md5.convert(utf8.encode(key)).toString().substring(0, 16);
    final safeName =
        item.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(localJoin(dir.path, '${hash}_$safeName'));
  }

  /// Load preview content for [item].
  Future<PreviewData> loadPreview(
    String serial,
    PreviewItem item, {
    String? destRoot,
    bool forceDownload = false,
  }) async {
    try {
      final localBackup = await resolveLocalBackupFile(
        item.devicePath,
        item.size,
        destRoot,
      );

      if (isTextLike(item.kind)) {
        return await _loadTextPreview(serial, item, localBackup: localBackup);
      }

      if (item.kind == PreviewKind.image ||
          item.kind == PreviewKind.heicImage) {
        return await _loadImagePreview(
          serial,
          item,
          localBackup: localBackup,
          forceDownload: forceDownload,
        );
      }

      if (item.kind == PreviewKind.pdf) {
        return await _loadPdfPreview(
          serial,
          item,
          localBackup: localBackup,
          forceDownload: forceDownload,
        );
      }

      if (item.kind == PreviewKind.video) {
        return await _loadVideoPreview(
          serial,
          item,
          localBackup: localBackup,
          forceDownload: forceDownload,
        );
      }

      // Audio and unsupported files show instant metadata without pulling
      // bytes unless the user clicks Open or Save Copy.
      return PreviewData(
        item: item,
        localFile: localBackup,
        fromLocalBackup: localBackup != null,
      );
    } catch (e) {
      return PreviewData(item: item, error: e.toString());
    }
  }

  Future<PreviewData> _loadTextPreview(
    String serial,
    PreviewItem item, {
    File? localBackup,
  }) async {
    Uint8List bytes;
    var truncated = false;

    if (localBackup != null) {
      final raf = await localBackup.open();
      try {
        final len = await raf.length();
        truncated = len > maxTextPreviewBytes;
        final readLen = truncated ? maxTextPreviewBytes : len;
        bytes = await raf.read(readLen);
      } finally {
        await raf.close();
      }
    } else {
      bytes = await adb.readFileHead(
        serial,
        item.devicePath,
        maxBytes: maxTextPreviewBytes,
      );
      truncated = item.size > maxTextPreviewBytes ||
          bytes.length >= maxTextPreviewBytes;
    }

    if (isLikelyBinary(bytes)) {
      return PreviewData(
        item: item,
        localFile: localBackup,
        fromLocalBackup: localBackup != null,
        error: 'This file appears to contain binary data and cannot be displayed as text.',
      );
    }

    final text = utf8.decode(bytes, allowMalformed: true);
    return PreviewData(
      item: item,
      localFile: localBackup,
      fromLocalBackup: localBackup != null,
      textContent: text,
      truncated: truncated,
    );
  }

  Future<PreviewData> _loadImagePreview(
    String serial,
    PreviewItem item, {
    File? localBackup,
    required bool forceDownload,
  }) async {
    File file;
    var fromBackup = false;
    if (localBackup != null) {
      file = localBackup;
      fromBackup = true;
    } else {
      final cached = await _cacheFileFor(serial, item);
      if (await cached.exists() && (item.size <= 0 || await cached.length() == item.size)) {
        file = cached;
      } else if (!forceDownload && item.size > autoImageLimitBytes) {
        return PreviewData(item: item, needsDownloadConfirm: true);
      } else {
        await adb.pullFile(serial, item.devicePath, cached.path);
        unawaited(_evictCacheIfNeeded());
        file = cached;
      }
    }

    if (item.kind == PreviewKind.heicImage) {
      if (Platform.isMacOS) {
        final jpg = await _convertHeicOnMac(file);
        if (jpg != null) {
          return PreviewData(
            item: item,
            localFile: file,
            fromLocalBackup: fromBackup,
            imageBytes: await jpg.readAsBytes(),
          );
        }
      }
      return PreviewData(
        item: item,
        localFile: file,
        fromLocalBackup: fromBackup,
        error: 'HEIC preview requires macOS ImageIO. Click Open to view in your system photo viewer.',
      );
    }

    final bytes = await file.readAsBytes();
    return PreviewData(
      item: item,
      localFile: file,
      fromLocalBackup: fromBackup,
      imageBytes: bytes,
    );
  }

  Future<PreviewData> _loadPdfPreview(
    String serial,
    PreviewItem item, {
    File? localBackup,
    required bool forceDownload,
  }) async {
    File file;
    var fromBackup = false;
    if (localBackup != null) {
      file = localBackup;
      fromBackup = true;
    } else {
      final cached = await _cacheFileFor(serial, item);
      if (await cached.exists() && (item.size <= 0 || await cached.length() == item.size)) {
        file = cached;
      } else if (!forceDownload && item.size > autoMediaLimitBytes) {
        return PreviewData(item: item, needsDownloadConfirm: true);
      } else {
        await adb.pullFile(serial, item.devicePath, cached.path);
        unawaited(_evictCacheIfNeeded());
        file = cached;
      }
    }

    int? pages;
    try {
      final bytes = await file.readAsBytes();
      pages = countPdfPages(bytes);
    } catch (_) {}

    Uint8List? renderedPage;
    if (Platform.isMacOS) {
      renderedPage = await _renderQuickLookThumbnailMac(file, size: 1600);
    }

    return PreviewData(
      item: item,
      localFile: file,
      fromLocalBackup: fromBackup,
      imageBytes: renderedPage,
      pdfPageCount: pages,
    );
  }

  Future<PreviewData> _loadVideoPreview(
    String serial,
    PreviewItem item, {
    File? localBackup,
    required bool forceDownload,
  }) async {
    File? file = localBackup;
    var fromBackup = localBackup != null;

    if (file == null) {
      final cached = await _cacheFileFor(serial, item);
      if (await cached.exists() && (item.size <= 0 || await cached.length() == item.size)) {
        file = cached;
      } else if (!forceDownload && item.size > autoMediaLimitBytes) {
        return PreviewData(item: item, needsDownloadConfirm: true);
      } else {
        await adb.pullFile(serial, item.devicePath, cached.path);
        unawaited(_evictCacheIfNeeded());
        file = cached;
      }
    }

    Uint8List? poster;
    if (Platform.isMacOS) {
      poster = await _renderQuickLookThumbnailMac(file, size: 1280);
    }

    return PreviewData(
      item: item,
      localFile: file,
      fromLocalBackup: fromBackup,
      imageBytes: poster,
    );
  }

  /// Ensure the full file exists on local disk (either via an existing backup
  /// copy or by pulling into the preview cache) for Open or Save Copy.
  Future<File> ensureLocalFile(
    String serial,
    PreviewItem item, {
    String? destRoot,
  }) async {
    final localBackup = await resolveLocalBackupFile(
      item.devicePath,
      item.size,
      destRoot,
    );
    if (localBackup != null) return localBackup;
    final cached = await _cacheFileFor(serial, item);
    if (await cached.exists() &&
        (item.size <= 0 || await cached.length() == item.size)) {
      return cached;
    }
    await adb.pullFile(serial, item.devicePath, cached.path);
    unawaited(_evictCacheIfNeeded());
    return cached;
  }

  /// Open [file] in the host OS's default viewer/player.
  static Future<void> openExternally(File file) async {
    if (Platform.isMacOS) {
      await Process.start('open', [file.path], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', file.path],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        'xdg-open',
        [file.path],
        mode: ProcessStartMode.detached,
      );
    }
  }

  /// Convert a HEIC/HEIF image to JPEG using macOS built-in `sips`.
  Future<File?> _convertHeicOnMac(File heicFile) async {
    try {
      final dir = await _ensureCacheDir();
      final outPath = localJoin(
        dir.path,
        '${md5.convert(utf8.encode(heicFile.path)).toString().substring(0, 12)}.jpg',
      );
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) return outFile;
      final r = await Process.run(
        'sips',
        ['-s', 'format', 'jpeg', '-s', 'formatOptions', '85', heicFile.path, '--out', outPath],
      ).timeout(const Duration(seconds: 15));
      if (r.exitCode == 0 && await outFile.exists()) {
        return outFile;
      }
    } catch (_) {}
    return null;
  }

  /// Render a high-res PNG thumbnail for PDFs and videos on macOS using
  /// built-in `qlmanage -t`.
  Future<Uint8List?> _renderQuickLookThumbnailMac(
    File file, {
    int size = 1280,
  }) async {
    try {
      final dir = await _ensureCacheDir();
      final thumbDir = Directory(localJoin(dir.path, 'thumbs'));
      await thumbDir.create(recursive: true);
      final base =
          file.path.split(Platform.pathSeparator).where((s) => s.isNotEmpty).last;
      final expected = File(localJoin(thumbDir.path, '$base.png'));
      if (await expected.exists() && await expected.length() > 0) {
        return await expected.readAsBytes();
      }
      final r = await Process.run(
        'qlmanage',
        ['-t', '-s', '$size', '-o', thumbDir.path, file.path],
      ).timeout(const Duration(seconds: 15));
      if (r.exitCode == 0 && await expected.exists()) {
        return await expected.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _evictCacheIfNeeded() async {
    try {
      final dir = _cacheDir;
      if (dir == null || !await dir.exists()) return;
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final st = await entity.stat();
          files.add((entity, st));
          total += st.size;
        }
      }
      if (total <= maxCacheBytes) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (f, st) in files) {
        if (total <= (maxCacheBytes * 0.75).round()) break;
        try {
          await f.delete();
          total -= st.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Remove all temporary cached preview files (called on app exit).
  Future<void> clearCache() async {
    try {
      final dir = _cacheDir ?? _cacheDirOverride;
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  // --- Pure, unit-tested content parsers ---

  /// Heuristic binary check: returns true if the first 4 KB contain NUL bytes
  /// or an excessive ratio of non-text control characters.
  static bool isLikelyBinary(Uint8List bytes) {
    final len = bytes.length < 4096 ? bytes.length : 4096;
    if (len == 0) return false;
    var control = 0;
    for (var i = 0; i < len; i++) {
      final b = bytes[i];
      if (b == 0) return true;
      if (b < 0x09 || (b > 0x0D && b < 0x20)) control++;
    }
    return control / len > 0.15;
  }

  /// Pretty-print JSON string, returning null if it is not valid JSON.
  static String? prettyPrintJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Fast pure-Dart PDF page count heuristic (`/Type /Page` entries, excluding
  /// `/Type /Pages`).
  static int? countPdfPages(Uint8List bytes) {
    if (bytes.length < 5) return null;
    final header = latin1.decode(bytes.sublist(0, 5), allowInvalid: true);
    if (!header.startsWith('%PDF')) return null;
    final text = latin1.decode(bytes, allowInvalid: true);
    final matches = RegExp(r'/Type\s*/Page(?![sA-Za-z])').allMatches(text);
    final count = matches.length;
    return count > 0 ? count : null;
  }

  /// Parse Markdown text into lightweight display blocks for the Quick Look
  /// `Rendered` view.
  static List<RichBlock> parseMarkdownBlocks(String source) {
    final blocks = <RichBlock>[];
    final lines = const LineSplitter().convert(source);
    var inCode = false;
    final codeBuf = StringBuffer();
    final paraBuf = StringBuffer();

    void flushPara() {
      final s = paraBuf.toString().trim();
      if (s.isNotEmpty) blocks.add(RichBlock(RichBlockType.paragraph, s));
      paraBuf.clear();
    }

    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('```')) {
        flushPara();
        if (inCode) {
          blocks.add(RichBlock(RichBlockType.code, codeBuf.toString().trimRight()));
          codeBuf.clear();
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.writeln(raw);
        continue;
      }
      if (trimmed.isEmpty) {
        flushPara();
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        flushPara();
        blocks.add(const RichBlock(RichBlockType.rule, ''));
        continue;
      }
      if (trimmed.startsWith('### ')) {
        flushPara();
        blocks.add(RichBlock(RichBlockType.h3, trimmed.substring(4).trim()));
        continue;
      }
      if (trimmed.startsWith('## ')) {
        flushPara();
        blocks.add(RichBlock(RichBlockType.h2, trimmed.substring(3).trim()));
        continue;
      }
      if (trimmed.startsWith('# ')) {
        flushPara();
        blocks.add(RichBlock(RichBlockType.h1, trimmed.substring(2).trim()));
        continue;
      }
      if (trimmed.startsWith('> ')) {
        flushPara();
        blocks.add(RichBlock(RichBlockType.quote, trimmed.substring(2).trim()));
        continue;
      }
      final listMatch = RegExp(r'^(\s*[-*+]|\s*\d+\.)\s+(.+)$').firstMatch(raw);
      if (listMatch != null) {
        flushPara();
        blocks.add(RichBlock(RichBlockType.listItem, listMatch.group(2)!.trim()));
        continue;
      }
      if (paraBuf.isNotEmpty) paraBuf.write(' ');
      paraBuf.write(trimmed);
    }
    if (inCode && codeBuf.isNotEmpty) {
      blocks.add(RichBlock(RichBlockType.code, codeBuf.toString().trimRight()));
    }
    flushPara();
    return blocks;
  }

  /// Convert HTML markup into clean readable blocks by stripping `<script>`,
  /// `<style>`, comments, and tags while preserving headings, paragraphs,
  /// list items, and decoded HTML entities.
  static List<RichBlock> stripHtmlToBlocks(String html) {
    var s = html
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
        .replaceAll(
            RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'<head\b[^>]*>[\s\S]*?</head>', caseSensitive: false), '');

    // Convert block tags into sentinel markers so structure survives stripping.
    s = s
        .replaceAll(RegExp(r'<h1\b[^>]*>', caseSensitive: false), '\n@@H1@@')
        .replaceAll(RegExp(r'<h2\b[^>]*>', caseSensitive: false), '\n@@H2@@')
        .replaceAll(RegExp(r'<h[3-6]\b[^>]*>', caseSensitive: false), '\n@@H3@@')
        .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n@@LI@@')
        .replaceAll(
            RegExp(r'<blockquote\b[^>]*>', caseSensitive: false), '\n@@QT@@')
        .replaceAll(RegExp(r'<pre\b[^>]*>', caseSensitive: false), '\n@@CD@@')
        .replaceAll(RegExp(r'<hr\b[^>]*>', caseSensitive: false), '\n@@HR@@\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(
            r'</(p|div|h[1-6]|li|tr|section|article|header|footer|blockquote|pre)>',
            caseSensitive: false,
          ),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]+>'), '');

    s = _decodeHtmlEntities(s);

    final blocks = <RichBlock>[];
    for (final rawLine in const LineSplitter().convert(s)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line == '@@HR@@') {
        blocks.add(const RichBlock(RichBlockType.rule, ''));
      } else if (line.startsWith('@@H1@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.h1, t));
      } else if (line.startsWith('@@H2@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.h2, t));
      } else if (line.startsWith('@@H3@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.h3, t));
      } else if (line.startsWith('@@LI@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.listItem, t));
      } else if (line.startsWith('@@QT@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.quote, t));
      } else if (line.startsWith('@@CD@@')) {
        final t = line.substring(6).trim();
        if (t.isNotEmpty) blocks.add(RichBlock(RichBlockType.code, t));
      } else {
        final clean = line.replaceAll(RegExp(r'\s+'), ' ');
        if (clean.isNotEmpty) blocks.add(RichBlock(RichBlockType.paragraph, clean));
      }
    }
    return blocks;
  }

  static String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&copy;', '©')
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
          final code = int.tryParse(m.group(1)!);
          return code == null ? m.group(0)! : String.fromCharCode(code);
        })
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
          final code = int.tryParse(m.group(1)!, radix: 16);
          return code == null ? m.group(0)! : String.fromCharCode(code);
        });
  }
}
