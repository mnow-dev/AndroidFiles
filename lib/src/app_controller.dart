import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:local_notifier/local_notifier.dart';

import 'adb_client.dart';
import 'adb_installer.dart';
import 'backup_engine.dart';
import 'drive_manager.dart';
import 'models.dart';
import 'settings.dart';
import 'update_checker.dart';
import 'updater.dart';

/// Root state: device polling, directory tree cache, selection, log.
class AppController extends ChangeNotifier {
  final Settings settings;
  late final AdbClient adb = AdbClient(settings.adbPath);
  late final BackupEngine engine = BackupEngine(adb, log: log);
  late final DriveManager drive = DriveManager(settings: settings, log: log);

  static const rootPath = '/sdcard';

  List<AdbDevice> devices = [];
  AdbDevice? selected;

  final Map<String, List<RemoteEntry>> children = {};
  final Set<String> expanded = {};
  final Set<String> loading = {};
  final Set<String> checked = {};
  final Set<String> _prefetched = {};

  final List<String> logLines = [];

  late final TextEditingController destination =
      TextEditingController(text: settings.lastDestination);

  Timer? _pollTimer;

  AppController(this.settings) {
    engine.addListener(notifyListeners);
    engine.onDrained = _onQueueDrained;
    drive.addListener(notifyListeners);
    destination.addListener(notifyListeners); // keeps the Run button state fresh
    unawaited(_ensureAdb());
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pollDevices());
    if (settings.checkForUpdates) unawaited(_checkForUpdate());
  }

  // --- update handling (see UpdateChecker for detection, Updater for apply) ---

  /// A newer release, once found. Surfaced as a dismissible bar on the home
  /// screen; cleared for the session by [dismissUpdate].
  UpdateInfo? update;

  /// 0..100 while an in-place update is downloading; null otherwise.
  int? updateProgress;

  Future<void> _checkForUpdate() async {
    final info = await UpdateChecker.latestIfNewer();
    if (info == null) return;
    update = info;
    log('Update available: ${info.version} (running $appVersion)');
    notifyListeners();
  }

  void dismissUpdate() {
    update = null;
    notifyListeners();
  }

  /// In a Velopack install, download and apply the update in place, then
  /// relaunch. Anywhere else (dev build, portable ZIP), open the release page
  /// so the user can grab it manually.
  Future<void> installUpdate() async {
    final info = update;
    if (info == null || updateProgress != null) return;
    if (await Updater.isManagedInstall) {
      updateProgress = 0;
      notifyListeners();
      final applied = await Updater.applyAndRestart(
        appPid: pid,
        onProgress: (p) {
          updateProgress = p;
          notifyListeners();
        },
        onExiting: () async {
          await drive.unmount(); // null-safe; frees the P: mount before restart
        },
      );
      // We only get here if nothing was applied; on success the app is
      // replaced and relaunched instead of returning.
      updateProgress = null;
      if (!applied) await UpdateChecker.open(info.url);
      notifyListeners();
    } else {
      await UpdateChecker.open(info.url);
    }
  }

  // --- adb bootstrap (auto-download when missing) ---

  bool adbMissing = false;
  double? adbDownloadProgress; // 0..1 downloading, null otherwise
  String? adbBootstrapError;

  Future<void> _ensureAdb() async {
    if (await AdbInstaller.isUsable(settings.adbPath)) {
      await _pollDevices();
      return;
    }
    final found = await AdbInstaller.findAdb();
    if (found != null) {
      _useAdb(found);
      return;
    }
    adbMissing = true;
    notifyListeners();
    await downloadAdb();
  }

  Future<void> downloadAdb() async {
    adbBootstrapError = null;
    adbDownloadProgress = 0;
    log('adb not found — downloading platform-tools from Google (~8 MB)…');
    notifyListeners();
    try {
      final path = await AdbInstaller.install(onProgress: (p) {
        adbDownloadProgress = p;
        notifyListeners();
      });
      _useAdb(path);
      log('adb installed at $path');
    } catch (e) {
      adbBootstrapError = e.toString();
      log('adb download failed: $e');
    }
    adbDownloadProgress = null;
    notifyListeners();
  }

  void _useAdb(String path) {
    settings.adbPath = path;
    adb.adbPath = path;
    adbMissing = false;
    unawaited(settings.save());
    notifyListeners();
    unawaited(_pollDevices());
  }

  bool _exitWhenDrained = false;
  final Set<String> _pendingRestoreTargets = {};
  String? _snapshotPartialDir;
  String? _snapshotFinalDir;
  final List<BackupJob> _snapshotJobs = [];

  Future<void> _finalizeSnapshot() async {
    final partial = _snapshotPartialDir;
    final finalDir = _snapshotFinalDir;
    if (partial == null || finalDir == null || _snapshotJobs.isEmpty) return;
    final allOk = _snapshotJobs.every((j) =>
        j.status == JobStatus.done || j.status == JobStatus.doneWithWarnings);
    _snapshotPartialDir = null;
    _snapshotFinalDir = null;
    _snapshotJobs.clear();
    if (!allOk) {
      log('Snapshot kept as ${partial.split('\\').last} — the run did not '
          'complete; the next run will not use it as a base.');
      return;
    }
    try {
      await Directory(partial).rename(finalDir);
      log('Snapshot finalized: ${finalDir.split('\\').last}');
    } catch (e) {
      log('Could not finalize snapshot $partial: $e');
    }
  }

  void _notify(String title, String body) {
    LocalNotification(title: title, body: body).show();
  }

  void _onQueueDrained() {
    final done = engine.jobs.where((j) => j.status == JobStatus.done).length;
    final warn =
        engine.jobs.where((j) => j.status == JobStatus.doneWithWarnings).length;
    final failed = engine.jobs.where((j) => j.status == JobStatus.failed).length;
    _notify('AndroidFiles — queue finished',
        '$done ok, $warn with warnings, $failed failed');

    unawaited(_finalizeSnapshot());

    // Freshly pushed files should show up when the tree is next viewed.
    for (final t in _pendingRestoreTargets) {
      children.remove(t);
      if (expanded.contains(t)) unawaited(expand(t));
    }
    _pendingRestoreTargets.clear();

    if (_exitWhenDrained) {
      log('Headless run complete — exiting shortly');
      Timer(const Duration(seconds: 5), () => exit(failed > 0 ? 1 : 0));
    }
    notifyListeners();
  }

  /// `--run-profile <name>`: wait for the device, run the profile, exit.
  Future<void> startHeadlessProfile(String name) async {
    _exitWhenDrained = true;
    log('Headless run of profile "$name"');
    final p = settings.profiles.where((x) => x.name == name).firstOrNull;
    if (p == null) {
      _notify('AndroidFiles backup failed', 'Profile "$name" not found');
      Timer(const Duration(seconds: 5), () => exit(2));
      return;
    }
    for (var i = 0; i < 60 && selected == null; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (selected == null) {
      _notify('AndroidFiles backup failed', 'No device connected (waited 2 min)');
      Timer(const Duration(seconds: 5), () => exit(3));
      return;
    }
    applyProfile(p);
    if (checkedEntries().isEmpty || destination.text.trim().isEmpty) {
      _notify('AndroidFiles backup failed', 'Profile "$name" is empty');
      Timer(const Duration(seconds: 5), () => exit(4));
      return;
    }
    await startBackup();
  }

  /// Queue pushes of dropped local files/folders into [targetDir] on device.
  void enqueueRestore(List<String> localPaths, String targetDir) {
    final serial = selected?.serial;
    if (serial == null || localPaths.isEmpty) return;
    for (final p in localPaths) {
      final name = p.substring(p.lastIndexOf(Platform.pathSeparator) + 1);
      engine.enqueue(BackupJob(
        source: RemoteEntry(name: name, path: targetDir, isDir: true),
        serial: serial,
        destDir: targetDir,
        localSource: p,
      ));
    }
    _pendingRestoreTargets.add(targetDir);
    log('Queued restore of ${localPaths.length} item(s) → $targetDir');
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    destination.dispose();
    super.dispose();
  }

  BackupLayout get layout => settings.layout;
  set layout(BackupLayout v) {
    settings.layout = v;
    unawaited(settings.save());
    notifyListeners();
  }

  bool get incremental => settings.incremental;
  set incremental(bool v) {
    settings.incremental = v;
    unawaited(settings.save());
    notifyListeners();
  }

  String get themeMode => settings.themeMode;
  set themeMode(String v) {
    settings.themeMode = v;
    unawaited(settings.save());
    notifyListeners();
  }

  bool get showLog => settings.showLog;
  set showLog(bool v) {
    settings.showLog = v;
    unawaited(settings.save());
    notifyListeners();
  }

  void log(String msg) {
    final t = DateTime.now();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    logLines.add('[$hh:$mm:$ss] $msg');
    if (logLines.length > 500) logLines.removeRange(0, logLines.length - 500);
    notifyListeners();
  }

  Future<void> _pollDevices() async {
    if (adbMissing) return;
    try {
      // Every ~30s, quietly reconnect known (paired) wireless devices that
      // mDNS can see — pairing is one-time, but the port changes per boot.
      if (_pollCount++ % 10 == 0) unawaited(_autoConnectKnown());
      final found = await adb.devices();
      _dedupeTransports(found);
      final changed = !listEquals(found, devices);
      devices = found;
      if (selected != null && !found.any((d) => d.serial == selected!.serial)) {
        log('Device ${selected!.label} disconnected');
        selected = null;
      }
      if (selected == null) {
        final ready = found.where((d) => d.isReady).toList();
        if (ready.isNotEmpty) {
          selected = ready.first;
          log('Connected to ${selected!.label}');
          _resetTree();
          unawaited(expand(rootPath));
        }
      }
      if (changed) notifyListeners();
    } catch (e) {
      if (devices.isNotEmpty || selected != null) {
        devices = [];
        selected = null;
        log('adb error: $e');
        notifyListeners();
      }
    }
  }

  /// One phone can appear under two Wi-Fi transports: adb's own mdns one
  /// (`<instance>._adb-tls-connect._tcp`) and an ip:port connection. Drop
  /// the mdns twin when mdns tells us both point at the same address.
  void _dedupeTransports(List<AdbDevice> found) {
    final ipByInstance = {
      for (final s in _lastMdnsServices)
        if (s.isConnect) s.instance: s.ip,
    };
    found.removeWhere((d) {
      final m =
          RegExp(r'^(.+?)\._adb-tls-connect\._tcp\.?$').firstMatch(d.serial);
      if (m == null) return false;
      final ip = ipByInstance[m.group(1)];
      return ip != null && found.any((o) => o.serial.startsWith('$ip:'));
    });
  }

  void selectDevice(AdbDevice d) {
    if (d.serial == selected?.serial) return; // re-picking is not a reload
    selected = d;
    _resetTree();
    notifyListeners();
    unawaited(expand(rootPath));
  }

  /// Explicit tree reload (toolbar refresh button).
  void refreshTree() {
    if (selected == null) return;
    final wasChecked = {...checked};
    _resetTree();
    checked.addAll(wasChecked); // a refresh shouldn't drop the selection
    notifyListeners();
    unawaited(expand(rootPath));
  }

  void _resetTree() {
    children.clear();
    expanded.clear();
    loading.clear();
    checked.clear();
    _prefetched.clear();
  }

  /// True once we know [path] is an empty directory (drives the chevron).
  bool isKnownEmpty(String path) => children[path]?.isEmpty ?? false;

  Future<void> expand(String path) async {
    final serial = selected?.serial;
    if (serial == null) return;
    expanded.add(path);
    if (children.containsKey(path) || loading.contains(path)) {
      notifyListeners();
      unawaited(_prefetchChildren(path));
      return;
    }
    loading.add(path);
    notifyListeners();
    try {
      children[path] = await adb.list(serial, path);
    } catch (e) {
      children[path] = [];
      log('Cannot list $path: $e');
    } finally {
      loading.remove(path);
      notifyListeners();
    }
    unawaited(_prefetchChildren(path));
  }

  /// Fetch listings one level below an expanded folder in the background, so
  /// empty folders lose their chevron and expanding feels instant.
  Future<void> _prefetchChildren(String parent) async {
    final serial = selected?.serial;
    if (serial == null || !_prefetched.add(parent)) return;
    final dirs = (children[parent] ?? const <RemoteEntry>[])
        .where((e) => e.isDir)
        .toList();
    if (dirs.length > 200) return; // don't hammer adb on giant folders
    for (final d in dirs) {
      if (selected?.serial != serial) return; // device changed mid-prefetch
      if (children.containsKey(d.path) || loading.contains(d.path)) continue;
      try {
        children[d.path] = await adb.list(serial, d.path);
        notifyListeners();
      } catch (_) {
        // Unknown stays unknown; the chevron remains and a manual expand
        // will surface the error in the log.
      }
    }
  }

  void collapse(String path) {
    expanded.remove(path);
    notifyListeners();
  }

  void toggleChecked(RemoteEntry entry) {
    if (checked.contains(entry.path)) {
      checked.remove(entry.path);
    } else {
      checked.add(entry.path);
      // A parent selection covers its children.
      checked.removeWhere((p) => p != entry.path && p.startsWith('${entry.path}/'));
    }
    notifyListeners();
  }

  /// Checked entries, resolved from the tree cache when possible and
  /// stubbed from the raw path otherwise (profiles can reference folders
  /// that were never expanded this session).
  List<RemoteEntry> checkedEntries() {
    final byPath = <String, RemoteEntry>{};
    for (final list in children.values) {
      for (final e in list) {
        byPath[e.path] = e;
      }
    }
    final paths = checked.toList()..sort();
    return [
      for (final p in paths)
        byPath[p] ??
            RemoteEntry(name: p.substring(p.lastIndexOf('/') + 1), path: p, isDir: true),
    ];
  }

  static final _snapshotDirRe = RegExp(r'^\d{4}-\d{2}-\d{2}_\d{6}$');

  Future<void> startBackup() async {
    final serial = selected?.serial;
    final destDir = destination.text.trim();
    if (serial == null || destDir.isEmpty) return;
    settings.lastDestination = destDir;
    unawaited(settings.save());
    final entries = checkedEntries();
    if (entries.isEmpty) {
      log('Nothing selected');
      return;
    }

    var targetDir = destDir;
    String? baseDir = destDir;
    if (layout == BackupLayout.snapshot) {
      final t = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${t.year}-${two(t.month)}-${two(t.day)}'
          '_${two(t.hour)}${two(t.minute)}${two(t.second)}';
      // Stage under .partial; renamed to the final name only when every job
      // of the run succeeds, so a half-finished snapshot is unmistakable.
      targetDir = '$destDir\\$stamp.partial';
      _snapshotPartialDir = targetDir;
      _snapshotFinalDir = '$destDir\\$stamp';
      _snapshotJobs.clear();
      baseDir = await _latestSnapshot(destDir);
    }

    for (final e in entries) {
      final job = BackupJob(
        source: e,
        serial: serial,
        destDir: targetDir,
        baseDir: baseDir,
        incremental: incremental,
      );
      if (layout == BackupLayout.snapshot) _snapshotJobs.add(job);
      engine.enqueue(job);
    }
    log('Queued ${entries.length} item(s) → $targetDir'
        '${incremental && baseDir != null ? ' (incremental vs $baseDir)' : ''}');
  }

  Future<String?> _latestSnapshot(String destDir) async {
    final root = Directory(destDir);
    if (!await root.exists()) return null;
    String? latest;
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final name = e.path.substring(e.path.lastIndexOf('\\') + 1);
      if (!_snapshotDirRe.hasMatch(name)) continue;
      if (latest == null || name.compareTo(latest) > 0) latest = name;
    }
    return latest == null ? null : '$destDir\\$latest';
  }

  Future<void> toggleDrive() async {
    if (drive.mounted) {
      await drive.unmount();
      return;
    }
    final serial = selected?.serial;
    if (serial == null) {
      log('Connect a device before mounting the drive');
      return;
    }
    await drive.mount(serial, settings.adbPath);
  }

  Future<void> wifiPair(String hostPort, String code) async {
    log('adb pair $hostPort → ${await adb.pair(hostPort, code)}');
  }

  Future<void> wifiConnect(String hostPort) async {
    log('adb connect $hostPort → ${await adb.connect(hostPort)}');
    await _pollDevices();
  }

  // --- QR pairing (Android Studio-style) ---

  String? qrPayload;
  String pairingStatus = '';
  List<MdnsService> discoveredConnectable = [];
  Timer? _qrTimer;
  String? _qrName;
  String? _qrPassword;
  String? _pairedHostIp;

  static String _randToken(int n) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rand = Random.secure();
    return [for (var i = 0; i < n; i++) chars[rand.nextInt(chars.length)]].join();
  }

  /// Show a QR code the phone can scan (Wireless debugging → Pair device
  /// with QR code); pairing and connecting then happen automatically.
  void startQrPairing() {
    _qrName = 'androidfiles-${_randToken(6)}';
    _qrPassword = _randToken(10);
    _pairedHostIp = null;
    qrPayload = 'WIFI:T:ADB;S:$_qrName;P:$_qrPassword;;';
    pairingStatus = 'Scan the code from Wireless debugging → '
        '"Pair device with QR code"';
    var busy = false;
    _qrTimer?.cancel();
    _qrTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (busy) return;
      busy = true;
      try {
        await _qrTick();
      } catch (_) {
        // transient adb hiccup; next tick retries
      } finally {
        busy = false;
      }
    });
    notifyListeners();
  }

  void stopQrPairing() {
    _qrTimer?.cancel();
    _qrTimer = null;
    qrPayload = null;
    _qrPassword = null;
    notifyListeners();
  }

  Future<void> _qrTick() async {
    final services = await adb.mdnsServices();
    discoveredConnectable = [for (final s in services) if (s.isConnect) s];

    if (_qrPassword != null) {
      final pairing = services
          .where((s) => s.isPairing && s.instance == _qrName)
          .firstOrNull;
      if (pairing != null) {
        pairingStatus = 'Phone found — pairing…';
        notifyListeners();
        final res = await adb.pair(pairing.address, _qrPassword!);
        log('adb pair ${pairing.address} → $res');
        if (res.toLowerCase().contains('success')) {
          _qrPassword = null;
          _pairedHostIp = pairing.ip;
          pairingStatus = 'Paired ✓ — connecting…';
        } else {
          pairingStatus = 'Pairing failed: $res';
        }
      }
    } else if (_pairedHostIp != null) {
      final connect = discoveredConnectable
          .where((s) => s.ip == _pairedHostIp)
          .firstOrNull;
      if (connect != null) {
        final res = await adb.connect(connect.address);
        log('adb connect ${connect.address} → $res');
        if (res.contains('connected')) {
          pairingStatus = 'Connected ✓';
          _pairedHostIp = null;
          _qrTimer?.cancel();
          _qrTimer = null;
          await _pollDevices();
        }
      }
    }
    notifyListeners();
  }

  // --- Quiet auto-connect to already-paired wireless devices ---

  final Map<String, DateTime> _autoConnectAttempts = {};
  List<MdnsService> _lastMdnsServices = [];
  int _pollCount = 0;

  Future<void> _autoConnectKnown() async {
    List<MdnsService> services;
    try {
      services = await adb.mdnsServices();
    } catch (_) {
      return;
    }
    _lastMdnsServices = services;
    for (final s in services) {
      if (!s.isConnect) continue;
      // Already connected — either as ip:port or as adb's own mdns
      // transport (serial starts with the mdns instance name).
      if (devices.any((d) =>
          d.serial.contains(s.ip) || d.serial.startsWith(s.instance))) {
        continue;
      }
      final last = _autoConnectAttempts[s.address];
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 5)) {
        continue;
      }
      _autoConnectAttempts[s.address] = DateTime.now();
      final res = await adb.connect(s.address);
      // Unpaired devices fail silently; only paired ones connect.
      if (res.contains('connected')) {
        log('Auto-connected wireless device ${s.address}');
      }
    }
  }

  // --- Profiles ---

  Profile? activeProfile;

  void applyProfile(Profile p) {
    activeProfile = p;
    checked
      ..clear()
      ..addAll(p.paths);
    destination.text = p.destination;
    settings.layout = p.layout;
    settings.incremental = p.incremental;
    log('Applied profile "${p.name}" (${p.paths.length} folders)');
    notifyListeners();
  }

  void saveProfile(String name) {
    final p = Profile(
      name: name,
      paths: checked.toList()..sort(),
      destination: destination.text.trim(),
      layout: layout,
      incremental: incremental,
    );
    settings.profiles.removeWhere((x) => x.name == name);
    settings.profiles.add(p);
    activeProfile = p;
    unawaited(settings.save());
    log('Saved profile "$name"');
    notifyListeners();
  }

  void deleteProfile(Profile p) {
    settings.profiles.remove(p);
    if (activeProfile == p) activeProfile = null;
    unawaited(settings.save());
    notifyListeners();
  }
}
