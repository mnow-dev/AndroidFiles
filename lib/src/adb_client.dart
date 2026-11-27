import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'manifest.dart';
import 'models.dart';
import 'os.dart';

/// Thin wrapper around the adb CLI.
class AdbClient {
  /// Mutable so a freshly auto-downloaded adb can be swapped in at runtime.
  String adbPath;

  AdbClient(this.adbPath);

  /// Quote an argument for the device-side shell (adb joins exec-out args
  /// with spaces and runs them through /system/bin/sh).
  static String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Whether [serial] names a wireless transport — either `ip:port` from
  /// `adb connect` or an mDNS instance like
  /// `adb-XXXX-YYYY._adb-tls-connect._tcp`. USB serials are plain
  /// alphanumeric, so neither marker appears.
  ///
  /// Wireless carries every byte over TLS with Wi-Fi round trips between
  /// acks, which is why transfers there are split across parallel streams.
  static bool isWireless(String serial) =>
      serial.contains(':') || serial.contains('_adb-tls');

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

  /// Stop the adb server. Best-effort: nothing to stop is not a failure.
  Future<void> killServer() async {
    try {
      await _run(['kill-server'], timeout: const Duration(seconds: 10));
    } catch (_) {}
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

  /// Hardware serial (`ro.serialno`) for [serial], used to recognize when two
  /// wireless ADB transports (e.g. `192.168.0.116:36687` and
  /// `adb-<hw>-<id>._adb-tls-connect._tcp`) refer to the exact same phone.
  Future<String?> hardwareSerial(String serial) async {
    try {
      final r = await _shell(
        serial,
        'getprop ro.serialno',
        timeout: const Duration(seconds: 5),
      );
      if (r.exitCode != 0) return null;
      final s = (r.stdout as String).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  /// Live Wi-Fi link speed, band (2.4 / 5 / 6 GHz), and RSSI for [serial].
  /// Uses `cmd wifi status` (Android 11+) with a `dumpsys wifi` fallback for
  /// older Android versions. Returns `null` if unavailable or not on Wi-Fi.
  Future<WifiLinkInfo?> wifiLinkInfo(String serial) async {
    try {
      final r = await _shell(
        serial,
        "cmd wifi status 2>/dev/null || dumpsys wifi | grep -m1 'mWifiInfo'",
        timeout: const Duration(seconds: 4),
      );
      if (r.exitCode != 0 && (r.stdout as String).trim().isEmpty) return null;
      return parseWifiLinkInfo(r.stdout as String);
    } catch (_) {
      return null;
    }
  }

  /// Parse `cmd wifi status` or `dumpsys wifi` output into a [WifiLinkInfo].
  static WifiLinkInfo? parseWifiLinkInfo(String raw) {
    if (raw.trim().isEmpty) return null;
    final txMatch =
        RegExp(r'\bTx Link speed:\s*(-?\d+)\s*Mbps', caseSensitive: false)
            .firstMatch(raw);
    final linkMatch =
        RegExp(r'\bLink speed:\s*(-?\d+)\s*Mbps', caseSensitive: false)
            .firstMatch(raw);
    final txSpeed = txMatch == null ? null : int.tryParse(txMatch.group(1)!);
    final genSpeed =
        linkMatch == null ? null : int.tryParse(linkMatch.group(1)!);
    final speed = (txSpeed != null && txSpeed > 0)
        ? txSpeed
        : (genSpeed != null && genSpeed > 0 ? genSpeed : null);
    if (speed == null) return null;

    final freqMatch =
        RegExp(r'\bFrequency:\s*(\d+)\s*MHz', caseSensitive: false)
            .firstMatch(raw);
    final rssiMatch =
        RegExp(r'\bRSSI:\s*(-?\d+)', caseSensitive: false).firstMatch(raw);
    final stdMatch =
        RegExp(r'\bWi-Fi standard:\s*([A-Za-z0-9._-]+)', caseSensitive: false)
            .firstMatch(raw);
    final ssidMatch = RegExp(r'\bSSID:\s*"([^"]+)"').firstMatch(raw);

    final freq = freqMatch == null ? null : int.tryParse(freqMatch.group(1)!);
    final rssi = rssiMatch == null ? null : int.tryParse(rssiMatch.group(1)!);
    return WifiLinkInfo(
      linkSpeedMbps: speed,
      frequencyMhz: (freq != null && freq > 0) ? freq : null,
      rssiDbm: (rssi != null && rssi < 0 && rssi > -127) ? rssi : null,
      standard: stdMatch?.group(1),
      ssid: ssidMatch?.group(1),
    );
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

  /// Combined size in bytes of several paths (du counts allocated blocks).
  /// One `du` per call — each path yields its own summary line, which we sum.
  Future<int> sizeOfAll(String serial, List<String> paths) async {
    if (paths.isEmpty) return 0;
    final args = paths.map(shellQuote).join(' ');
    final r = await _shell(serial, 'du -sk $args',
        timeout: const Duration(minutes: 5));
    var total = 0;
    for (final line in (r.stdout as String).split('\n')) {
      final m = RegExp(r'^(\d+)').firstMatch(line.trimLeft());
      if (m != null) total += int.parse(m.group(1)!) * 1024;
    }
    return total;
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
    final local = File(localJoin(Directory.systemTemp.path,
        'af_list_${DateTime.now().microsecondsSinceEpoch}.txt'));
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

  /// Remove a single device file (used for temp files).
  Future<void> remove(String serial, String devicePath) async {
    await _shell(serial, 'rm -f ${shellQuote(devicePath)}');
  }

  /// Device storage totals (total/used/free bytes) for [path] via `df -k`.
  Future<({int totalBytes, int usedBytes, int freeBytes})?> storageSpace(
    String serial,
    String path,
  ) async {
    final target = path.endsWith('/') ? path : '$path/';
    final r = await _shell(serial, 'df -k ${shellQuote(target)}');
    if (r.exitCode != 0) return null;
    final lines = const LineSplitter()
        .convert(r.stdout as String)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    // Standard toybox `df -k`: Filesystem 1K-blocks Used Available Use% Mounted
    final parts = lines.last.split(RegExp(r'\s+'));
    if (parts.length < 4) return null;
    final totalKb = int.tryParse(parts[1]);
    final usedKb = int.tryParse(parts[2]);
    final availKb = int.tryParse(parts[3]);
    if (totalKb == null || usedKb == null || availKb == null) return null;
    return (
      totalBytes: totalKb * 1024,
      usedBytes: usedKb * 1024,
      freeBytes: availKb * 1024,
    );
  }

  /// Fast single-pass scan of user files under [rootPath] (e.g. `/sdcard`).
  /// Uses a trailing slash so symlinked `/sdcard` is traversed, prunes
  /// restricted `Android/data` and `Android/obb` subtrees, and tolerates
  /// partial permission warnings as long as stdout yields entries.
  Future<Map<String, FileMeta>> scanStorage(
    String serial,
    String rootPath,
  ) async {
    final root = rootPath.endsWith('/')
        ? rootPath.substring(0, rootPath.length - 1)
        : rootPath;
    final cmd =
        "find ${shellQuote('$root/')} "
        "\\( -path ${shellQuote('$root/Android/data')} "
        "-o -path ${shellQuote('$root/Android/obb')} \\) -prune "
        "-o -type f -exec stat -c '%s|%Y|%n' {} + 2>/dev/null";
    final r = await _shell(serial, cmd, timeout: const Duration(minutes: 5));
    final stdout = r.stdout as String;
    if (r.exitCode != 0 && stdout.trim().isEmpty) {
      throw AdbException('Storage scan failed: ${r.stderr}'.trim());
    }
    return parseDeviceManifest(stdout, root);
  }

  /// Hash an explicit list of absolute device paths via batched `md5sum`.
  /// Returns `{absPath -> lowercase hex md5}`.
  Future<Map<String, String>> md5Files(
    String serial,
    List<String> absPaths, {
    void Function(int done, int total)? onProgress,
  }) async {
    final out = <String, String>{};
    if (absPaths.isEmpty) return out;
    final re = RegExp(r'^([0-9a-fA-F]{32})\s+(.+)$');
    const chunkSize = 50;
    var done = 0;
    for (var i = 0; i < absPaths.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, absPaths.length);
      final batch = absPaths.sublist(i, end);
      final args = batch.map(shellQuote).join(' ');
      final r = await _shell(
        serial,
        'md5sum $args 2>/dev/null',
        timeout: const Duration(minutes: 5),
      );
      for (final line in const LineSplitter().convert(r.stdout as String)) {
        final m = re.firstMatch(line);
        if (m != null) {
          out[m.group(2)!] = m.group(1)!.toLowerCase();
        }
      }
      done = end;
      onProgress?.call(done, absPaths.length);
    }
    return out;
  }

  /// Discover browsable storage roots on the device: always includes internal
  /// storage (`/sdcard`), plus any mounted readable external microSD / USB
  /// volumes under `/storage/<UUID>`.
  Future<List<StorageVolume>> storageVolumes(String serial) async {
    try {
      // Single shell round-trip: enumerate /storage/*, skip Android's virtual
      // internal symlinks (`emulated`, `self`, etc.), and keep only readable
      // mounted directories.
      const cmd = 'for d in /storage/*; do '
          'n="\${d##*/}"; '
          'case "\$n" in emulated|self|enc_emulated|knox-emulated|isolated|\'*\') continue ;; esac; '
          '[ -d "\$d" ] && ls "\$d/" >/dev/null 2>&1 && printf \'%s\\n\' "\$d"; '
          'done';
      final r = await _shell(serial, cmd, timeout: const Duration(seconds: 10));
      return parseStorageVolumes(r.stdout as String);
    } catch (_) {
      return const [StorageVolume.internal];
    }
  }

  /// Parse newline-separated external mount paths (from `/storage/*`) into a
  /// deduplicated list starting with [StorageVolume.internal].
  static List<StorageVolume> parseStorageVolumes(String rawPaths) {
    final volumes = <StorageVolume>[StorageVolume.internal];
    final seen = <String>{StorageVolume.internal.path};
    final externalPaths = <String>[];
    for (final line in const LineSplitter().convert(rawPaths)) {
      var p = line.trim();
      while (p.length > 1 && p.endsWith('/')) {
        p = p.substring(0, p.length - 1);
      }
      final id = externalStorageId(p);
      if (id == null) continue;
      final canonical = '/storage/$id';
      if (seen.add(canonical)) {
        externalPaths.add(canonical);
      }
    }
    externalPaths.sort();
    for (final p in externalPaths) {
      final id = externalStorageId(p)!;
      volumes.add(StorageVolume(
        path: p,
        label: 'SD card ($id)',
        isExternal: true,
      ));
    }
    return volumes;
  }

  /// Safety fence for on-device file deletion: permits regular user paths
  /// strictly inside `/sdcard/` or a mounted external `/storage/<UUID>/`
  /// volume, and rejects traversal (`..`), root paths, or system directories.
  static bool isSafeUserStoragePath(String path) {
    if (path.contains('/../') || path.endsWith('/..') || path.endsWith('/')) {
      return false;
    }
    if (path.startsWith('/sdcard/') && path.length > '/sdcard/'.length) {
      return true;
    }
    final extId = externalStorageId(path);
    if (extId != null) {
      final prefix = '/storage/$extId/';
      return path.startsWith(prefix) && path.length > prefix.length;
    }
    return false;
  }

  /// Safely delete verified user files under `/sdcard/` or an external
  /// `/storage/<UUID>/` volume. Returns paths that failed to delete (empty
  /// list = all removed cleanly).
  Future<List<String>> deleteDeviceFiles(
    String serial,
    List<String> absPaths, {
    void Function(int done, int total)? onProgress,
  }) async {
    final failed = <String>[];
    if (absPaths.isEmpty) return failed;
    // Safety fence: refuse any path outside user storage or with path traversal.
    final safe = <String>[];
    for (final p in absPaths) {
      if (!isSafeUserStoragePath(p)) {
        failed.add(p);
      } else {
        safe.add(p);
      }
    }
    const chunkSize = 40;
    var done = 0;
    for (var i = 0; i < safe.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, safe.length);
      final batch = safe.sublist(i, end);
      final args = batch.map(shellQuote).join(' ');
      final r = await _shell(
        serial,
        'rm -f -- $args',
        timeout: const Duration(minutes: 2),
      );
      if (r.exitCode != 0) {
        // Fall back to per-file removal to pinpoint any failures.
        for (final p in batch) {
          final single = await _shell(serial, 'rm -f -- ${shellQuote(p)}');
          if (single.exitCode != 0) failed.add(p);
        }
      }
      done = end;
      onProgress?.call(done, safe.length);
    }
    return failed;
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
  /// Streams the device output, calling [onProgress] with the running file
  /// count as the phone hashes each one (the slow first half of deep verify),
  /// then parses the collected lines.
  Future<Map<String, String>> md5Manifest(String serial, String path,
      {void Function(int hashed, String? rel)? onProgress}) async {
    final proc = await Process.start(adbPath, [
      '-s', serial, 'shell',
      'find ${shellQuote(path)} -type f -exec md5sum {} +',
    ]);
    final out = StringBuffer();
    final err = StringBuffer();
    final prefix = '${dirname(path)}/';
    var count = 0;
    await Future.wait([
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        out.writeln(line); // one md5sum line == one hashed file
        // "<hash>  <abs path>" — hand the relative path up so the caller can
        // weight progress by this file's size, not just its count.
        String? rel;
        final sp = line.indexOf('  ');
        if (sp > 0) {
          final abs = line.substring(sp + 2);
          if (abs.startsWith(prefix)) rel = abs.substring(prefix.length);
        }
        onProgress?.call(++count, rel);
      }),
      proc.stderr.transform(utf8.decoder).forEach(err.write),
    ]);
    final exit = await proc.exitCode;
    if (exit != 0) {
      throw AdbException('md5sum of $path failed ($exit): ${err.toString().trim()}');
    }
    return parseMd5Manifest(out.toString(), dirname(path));
  }

  /// Wireless devices discovered via mDNS (`adb mdns services`, augmented on
  /// macOS by native Bonjour `dns-sd`).
  ///
  /// ADB's Openscreen mDNS backend on macOS frequently wedges after sleep or
  /// network changes and misses `_adb-tls-connect._tcp` services even while
  /// macOS's `mDNSResponder` sees them immediately. Merging `dns-sd` results
  /// makes QR pairing, manual discovery, and auto-reconnect reliable on macOS.
  Future<List<MdnsService>> mdnsServices() async {
    final adbFuture = _adbMdnsServices();
    final bonjourFuture =
        Platform.isMacOS ? _bonjourMdnsServices() : Future.value(const <MdnsService>[]);
    final results = await Future.wait([adbFuture, bonjourFuture]);

    // Deduplicate by (instance, type), preferring IPv4 addresses when both
    // backends report the same service.
    final byKey = <String, MdnsService>{};
    for (final list in results) {
      for (final s in list) {
        final key = '${s.instance}|${s.type}';
        final existing = byKey[key];
        if (existing == null || (!existing.isIpv4 && s.isIpv4)) {
          byKey[key] = s;
        }
      }
    }
    return byKey.values.toList();
  }

  Future<List<MdnsService>> _adbMdnsServices() async {
    try {
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
    } catch (_) {
      return const [];
    }
  }

  Future<List<MdnsService>> _bonjourMdnsServices() async {
    const types = ['_adb-tls-pairing._tcp', '_adb-tls-connect._tcp'];
    final browsed = await Future.wait([
      for (final t in types) _bonjourBrowse(t),
    ]);
    final lookupFutures = <Future<MdnsService?>>[];
    for (var i = 0; i < types.length; i++) {
      for (final instance in browsed[i]) {
        lookupFutures.add(_bonjourLookup(instance, types[i]));
      }
    }
    if (lookupFutures.isEmpty) return const [];
    final resolved = await Future.wait(lookupFutures);
    return [for (final s in resolved) ?s];
  }

  /// Browse Bonjour for [serviceType] briefly (~400ms) and return active
  /// instance names.
  Future<Set<String>> _bonjourBrowse(String serviceType) async {
    final active = <String>{};
    Process? proc;
    try {
      proc = await Process.start('dns-sd', ['-B', serviceType, 'local.']);
      final sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final parsed = parseBonjourBrowseLine(line);
        if (parsed == null) return;
        if (parsed.added) {
          active.add(parsed.instance);
        } else {
          active.remove(parsed.instance);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      proc.kill();
      await sub.cancel();
    } catch (_) {
      proc?.kill();
    }
    return active;
  }

  /// Resolve a single Bonjour instance to an `ip:port` [MdnsService].
  Future<MdnsService?> _bonjourLookup(String instance, String serviceType) async {
    Process? proc;
    try {
      proc = await Process.start('dns-sd', ['-L', instance, serviceType, 'local.']);
      final completer = Completer<(String, String)?>();
      final sub = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final target = parseBonjourLookupLine(line);
        if (target != null && !completer.isCompleted) {
          completer.complete(target);
        }
      });
      final target = await completer.future.timeout(
        const Duration(milliseconds: 1200),
        onTimeout: () => null,
      );
      proc.kill();
      await sub.cancel();
      if (target == null) return null;

      final (rawHost, port) = target;
      final host = rawHost.endsWith('.')
          ? rawHost.substring(0, rawHost.length - 1)
          : rawHost;
      String? resolvedAddr;
      try {
        final v4 = await InternetAddress.lookup(
          host,
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 2));
        if (v4.isNotEmpty) resolvedAddr = '${v4.first.address}:$port';
      } catch (_) {}
      if (resolvedAddr == null) {
        try {
          final any = await InternetAddress.lookup(host)
              .timeout(const Duration(seconds: 2));
          if (any.isNotEmpty) {
            final a = any.first;
            resolvedAddr = a.type == InternetAddressType.IPv6
                ? '[${a.address}]:$port'
                : '${a.address}:$port';
          }
        } catch (_) {}
      }
      if (resolvedAddr == null) return null;
      return MdnsService(
        instance: instance,
        type: serviceType,
        address: resolvedAddr,
      );
    } catch (_) {
      proc?.kill();
      return null;
    }
  }

  static ({bool added, String instance})? parseBonjourBrowseLine(String line) {
    final m = RegExp(
      r'^\S+\s+(Add|Rmv)\s+\d+\s+\d+\s+\S+\s+\S+\s+(.+?)\s*$',
    ).firstMatch(line.trim());
    if (m == null) return null;
    return (added: m.group(1) == 'Add', instance: m.group(2)!);
  }

  static (String, String)? parseBonjourLookupLine(String line) {
    final m = RegExp(r'can be reached at\s+(\S+):(\d+)\b').firstMatch(line);
    if (m == null) return null;
    return (m.group(1)!, m.group(2)!);
  }

  static bool _isWedgedServerError(String out) {
    final lower = out.toLowerCase();
    return lower.contains('protocol fault') ||
        lower.contains('no route to host') ||
        lower.contains('cannot connect to daemon');
  }

  /// Pair with a device over Wi-Fi (Android 11+ pairing dialog).
  /// If a stale/wedged adb daemon returns a protocol fault or local-network
  /// error, restarts the adb server once and retries automatically.
  Future<String> pair(String hostPort, String code) async {
    var r = await _run(['pair', hostPort, code], timeout: const Duration(seconds: 60));
    var out = '${r.stdout}${r.stderr}'.trim();
    if (!out.toLowerCase().contains('success') && _isWedgedServerError(out)) {
      await killServer();
      r = await _run(['pair', hostPort, code], timeout: const Duration(seconds: 60));
      out = '${r.stdout}${r.stderr}'.trim();
    }
    return out;
  }

  /// Connect to a device over Wi-Fi.
  /// Retries once after restarting a wedged adb server on protocol/route errors.
  Future<String> connect(String hostPort) async {
    var r = await _run(['connect', hostPort], timeout: const Duration(seconds: 60));
    var out = '${r.stdout}${r.stderr}'.trim();
    if (!out.toLowerCase().contains('connected') && _isWedgedServerError(out)) {
      await killServer();
      r = await _run(['connect', hostPort], timeout: const Duration(seconds: 60));
      out = '${r.stdout}${r.stderr}'.trim();
    }
    return out;
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

  /// Read up to [maxBytes] from the beginning of a device file using binary-safe
  /// `exec-out head -c`, allowing instant text/code/Markdown/HTML previews even
  /// on huge log files without transferring the whole file.
  Future<Uint8List> readFileHead(
    String serial,
    String path, {
    int maxBytes = 524288,
  }) async {
    final r = await Process.run(
      adbPath,
      ['-s', serial, 'exec-out', 'head -c $maxBytes ${shellQuote(path)}'],
      stdoutEncoding: null,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 30));
    if (r.exitCode != 0) {
      throw AdbException(
          'Cannot read $path (${r.exitCode}): ${(r.stderr as String).trim()}');
    }
    final out = r.stdout;
    if (out is Uint8List) return out;
    if (out is List<int>) return Uint8List.fromList(out);
    return Uint8List(0);
  }

  /// Pull a single device file to an exact [localPath] (used by Quick Look
  /// previews and single-file Save Copy).
  Future<void> pullFile(
    String serial,
    String devicePath,
    String localPath,
  ) async {
    final r = await _run(
      ['-s', serial, 'pull', '-a', devicePath, localPath],
      timeout: const Duration(minutes: 5),
    );
    if (r.exitCode != 0) {
      final msg = '${r.stderr}${r.stdout}'.trim();
      throw AdbException('adb pull failed (${r.exitCode}): $msg');
    }
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

  /// Host portion of [address], handling both IPv4 (`192.168.1.2:5555`) and
  /// bracketed IPv6 (`[fe80::1]:5555`).
  String get ip {
    final colon = address.lastIndexOf(':');
    final host = colon == -1 ? address : address.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) {
      return host.substring(1, host.length - 1);
    }
    return host;
  }

  bool get isIpv4 => !ip.contains(':');
}

class AdbException implements Exception {
  final String message;
  AdbException(this.message);
  @override
  String toString() => message;
}
