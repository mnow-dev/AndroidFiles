import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' show Locale, TextEditingController;
import 'package:local_notifier/local_notifier.dart';

import 'adb_client.dart';
import 'adb_installer.dart';
import 'backup_engine.dart';
import 'cleanup_engine.dart';
import 'drive_manager.dart';
import 'keep_awake.dart';
import 'models.dart';
import 'os.dart';
import 'preview_service.dart';
import 'selection.dart';
import 'settings.dart';
import 'update_checker.dart';
import 'updater.dart';

/// Root state: device polling, directory tree cache, selection, log.
class AppController extends ChangeNotifier {
  final Settings settings;
  final AdbClient adb;
  late final BackupEngine engine =
      BackupEngine(adb, log: log, parallelStreams: settings.parallelStreams);
  late final DriveManager drive = DriveManager(settings: settings, log: log);
  late final CleanupController cleanup =
      CleanupController(adb: adb, log: log);
  late final PreviewService preview = PreviewService(adb: adb, log: log);

  static const rootPath = '/sdcard';

  List<AdbDevice> devices = [];
  AdbDevice? selected;

  /// Live Wi-Fi link speed & band for [selected] when connected wirelessly.
  WifiLinkInfo? wifiLink;
  int _wifiPollCounter = 0;

  /// Browsable storage volumes on [selected] (internal `/sdcard` plus any
  /// mounted external microSD / USB volumes under `/storage/<UUID>`).
  List<StorageVolume> volumes = const [StorageVolume.internal];
  StorageVolume activeVolume = StorageVolume.internal;
  String get activeRootPath => activeVolume.path;
  bool get hasExternalStorage => volumes.any((v) => v.isExternal);

  /// Count of explicitly checked items inside [volume].
  int checkedCountForVolume(StorageVolume volume) =>
      checked.where(volume.containsPath).length;

  final Map<String, List<RemoteEntry>> children = {};
  final Map<String, EntryBackupStatus> entryBackupStatus = {};
  final Set<String> expanded = {};
  final Set<String> loading = {};
  final Set<String> checked = {};

  /// Paths carved back OUT of a checked ancestor's subtree (unticking a child
  /// under a selected folder). The nearest checked/excluded prefix wins.
  final Set<String> excluded = {};
  final Set<String> _prefetched = {};
  final Set<String> _prefetchingParents = {};
  /// Directories currently being recursively listed to verify whether a
  /// locally-present backup folder is completely backed up or only partial.
  final Set<String> _verifyingDirs = {};

  final List<String> logLines = [];

  late final TextEditingController destination =
      TextEditingController(text: settings.lastDestination);

  Timer? _pollTimer;
  Timer? _destSaveDebounce;
  final Map<String, String> _hwSerialCache = {};

  AppController(this.settings, {bool startPolling = true, AdbClient? adb})
      : adb = adb ?? AdbClient(settings.adbPath) {
    engine.addListener(notifyListeners);
    engine.addListener(() => KeepAwake.set(engine.isRunning));
    engine.onFilesProgress = (_) => unawaited(refreshBackupStatuses());
    engine.onJobFinished = (_) => unawaited(refreshBackupStatuses());
    engine.onDrained = _onQueueDrained;
    drive.addListener(notifyListeners);
    cleanup.addListener(notifyListeners);
    destination.addListener(_onDestinationChanged);
    if (startPolling) {
      unawaited(_ensureAdb());
      _pollTimer =
          Timer.periodic(const Duration(seconds: 3), (_) => _pollDevices());
      _checkPendingUpdate();
      if (settings.checkForUpdates && (Platform.isWindows || Platform.isMacOS)) {
        unawaited(_checkForUpdate());
      }
    }
  }

  void _onDestinationChanged() {
    notifyListeners(); // keeps the Run button state fresh
    final trimmed = destination.text.trim();
    if (trimmed == settings.lastDestination) return;
    _destSaveDebounce?.cancel();
    _destSaveDebounce = Timer(const Duration(milliseconds: 400), () {
      if (settings.lastDestination != trimmed) {
        settings.lastDestination = trimmed;
        unawaited(settings.save());
      }
      unawaited(refreshBackupStatuses());
    });
  }

  /// Update the backup destination folder and persist it immediately so it is
  /// remembered on the next launch even before starting a backup.
  void setDestination(String path) {
    final trimmed = path.trim();
    _destSaveDebounce?.cancel();
    if (settings.lastDestination != trimmed) {
      settings.lastDestination = trimmed;
      unawaited(settings.save());
    }
    if (destination.text != path) {
      destination.text = path;
    } else {
      notifyListeners();
    }
    unawaited(refreshBackupStatuses());
  }

  // --- update handling (see UpdateChecker for detection, Updater for apply) ---

  /// A newer release, once found. Surfaced as a dismissible bar on the home
  /// screen; cleared for the session by [dismissUpdate].
  UpdateInfo? update;

  /// 0..100 while an in-place update is downloading; null otherwise.
  int? updateProgress;

  /// Set when an in-place update failed, so the update dialog can say so
  /// rather than looking like the button did nothing.
  String? updateError;

  /// The apply step runs after this app has exited, so its failure can only
  /// be noticed on the relaunch that follows: still older than the version we
  /// left to install means it didn't take.
  void _checkPendingUpdate() {
    final pending = settings.pendingUpdate;
    if (pending.isEmpty) return;
    settings.pendingUpdate = '';
    unawaited(settings.save());
    if (UpdateChecker.isRemoteNewer(pending, appVersion)) {
      updateError = 'Installing $pending did not complete';
      log('Update to $pending failed to apply; still running $appVersion. '
          'Details: %LOCALAPPDATA%\\velopack\\velopack_AndroidFiles.log');
    }
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateChecker.latestIfNewer();
    if (info == null) return;
    update = info;
    log('Update available: ${info.version} (running $appVersion)');
    notifyListeners();
  }

  /// Manually check GitHub Releases for a newer version. Returns the newer
  /// [UpdateInfo] if found, or `null` if already on the latest version (or
  /// offline).
  Future<UpdateInfo?> checkForUpdatesNow() async {
    final info = await UpdateChecker.latestIfNewer();
    if (info != null) {
      update = info;
      log('Update available: ${info.version} (running $appVersion)');
      notifyListeners();
    } else {
      log('AndroidFiles v$appVersion is up to date');
    }
    return info;
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
      updateError = null;
      notifyListeners();
      var applied = false;
      try {
        applied = await Updater.applyAndRestart(
          appPid: pid,
          onProgress: (p) {
            updateProgress = p;
            notifyListeners();
          },
          onExiting: () async {
            settings.pendingUpdate = info.version;
            await settings.save();
            await drive.unmount(); // null-safe; frees the P: mount before restart
            // An adb server started by an older build may still have its
            // working directory in current\, which blocks the swap. The app
            // reconnects known wireless devices on relaunch.
            await adb.killServer();
          },
        );
      } on UpdateFailed catch (e) {
        updateError = e.message;
        log('Update failed: ${e.message}');
      }
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
      log('Snapshot kept as ${localBaseName(partial)} — the run did not '
          'complete; the next run will not use it as a base.');
      return;
    }
    try {
      await Directory(partial).rename(finalDir);
      log('Snapshot finalized: ${localBaseName(finalDir)}');
      unawaited(refreshBackupStatuses());
    } catch (e) {
      log('Could not finalize snapshot $partial: $e');
    }
  }

  static const _macNotifChannel = MethodChannel('androidfiles/notifications');

  void _notify(String title, String body) {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (Platform.isMacOS) {
      unawaited(
        _macNotifChannel
            .invokeMethod<bool>('show', {'title': title, 'body': body})
            .catchError((_) => false),
      );
      return;
    }
    LocalNotification(title: title, body: body).show();
  }

  void _onQueueDrained() {
    final done = engine.jobs.where((j) => j.status == JobStatus.done).length;
    final warn =
        engine.jobs.where((j) => j.status == JobStatus.doneWithWarnings).length;
    final failed = engine.jobs.where((j) => j.status == JobStatus.failed).length;
    _notify('AndroidFiles — queue finished',
        '$done ok, $warn with warnings, $failed failed');

    unawaited(_finalizeSnapshot().then((_) => refreshBackupStatuses()));

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
    final volume = unmountedVolume(destination.text);
    if (volume != null) {
      _notify('AndroidFiles backup failed', 'Drive "$volume" is not connected');
      Timer(const Duration(seconds: 5), () => exit(5));
      return;
    }
    await startBackup();
  }

  /// Queue pushes of dropped local files/folders into [targetDir] on device.
  void enqueueRestore(List<String> localPaths, String targetDir) {
    final serial = selected?.serial;
    if (serial == null || localPaths.isEmpty) return;
    for (final p in localPaths) {
      final name = localBaseName(p);
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

  /// Cleanly stop all background transfers, mounts, and timers on app exit.
  void shutdown() {
    _pollTimer?.cancel();
    _sizeDebounce?.cancel();
    _destSaveDebounce?.cancel();
    _qrTimer?.cancel();
    engine.cancelAll();
    unawaited(drive.unmount());
    unawaited(preview.clearCache());
  }

  @override
  void dispose() {
    shutdown();
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

  bool get skipClutter => settings.skipClutter;
  set skipClutter(bool v) {
    settings.skipClutter = v;
    unawaited(settings.save());
    notifyListeners();
  }

  bool get autoVerify => settings.autoVerify;
  set autoVerify(bool v) {
    settings.autoVerify = v;
    unawaited(settings.save());
    notifyListeners();
  }

  /// UI locale, or null to follow the system. Set via [localeCode].
  Locale? get locale =>
      settings.locale.isEmpty ? null : Locale(settings.locale);
  String get localeCode => settings.locale;
  set localeCode(String v) {
    settings.locale = v;
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
      await _populateWirelessHardwareSerials(found);
      _dedupeTransports(found);
      final changed = !listEquals(found, devices);
      devices = found;
      if (selected != null && !found.any((d) => d.serial == selected!.serial)) {
        log('Device ${selected!.label} disconnected');
        selected = null;
        wifiLink = null;
        volumes = const [StorageVolume.internal];
        activeVolume = StorageVolume.internal;
      }
      if (selected == null) {
        final ready = found.where((d) => d.isReady).toList();
        if (ready.isNotEmpty) {
          // Prefer the phone we used last time if it's back; else the first.
          selected = ready.firstWhere(
            (d) => d.serial == settings.lastDeviceSerial,
            orElse: () => ready.first,
          );
          _rememberDevice(selected!.serial);
          log('Connected to ${selected!.label}');
          _resetTree();
          unawaited(expand(activeRootPath));
          unawaited(_loadVolumes(selected!.serial));
          unawaited(_refreshWifiLink());
        }
      } else if (selected!.isReady && selected!.isWireless) {
        // Refresh Wi-Fi link speed every ~12s (4 poll ticks) while wireless.
        if ((++_wifiPollCounter) % 4 == 0) {
          unawaited(_refreshWifiLink());
        }
      } else if (wifiLink != null) {
        wifiLink = null;
        notifyListeners();
      }
      if (changed) notifyListeners();
    } catch (e) {
      if (devices.isNotEmpty || selected != null) {
        devices = [];
        selected = null;
        wifiLink = null;
        log('adb error: $e');
        notifyListeners();
      }
    }
  }

  /// Fetch current Wi-Fi link speed and band for the selected wireless device.
  Future<void> _refreshWifiLink() async {
    final dev = selected;
    if (dev == null || !dev.isReady || !dev.isWireless) {
      if (wifiLink != null) {
        wifiLink = null;
        notifyListeners();
      }
      return;
    }
    final info = await adb.wifiLinkInfo(dev.serial);
    if (selected?.serial != dev.serial) return;
    if (wifiLink != info) {
      wifiLink = info;
      notifyListeners();
    }
  }

  /// One phone can appear under multiple Wi-Fi transports at once:
  ///   1. adb's own mDNS transport (`adb-<hw>-<id>._adb-tls-connect._tcp`)
  ///      paired with an `ip:port` connection;
  ///   2. Both IPv4 (`192.168.0.117:44533`) and link-local IPv6
  ///      (`[fe80::...%en0]:44533`) endpoints on the exact same port.
  /// Drop redundant twins, preferring IPv4 `ip:port`.
  Future<void> _populateWirelessHardwareSerials(List<AdbDevice> found) async {
    final wirelessReady = [
      for (final d in found)
        if (d.isReady && d.isWireless) d,
    ];
    if (wirelessReady.length < 2) return;
    final missing = [
      for (final d in wirelessReady)
        if (!_hwSerialCache.containsKey(d.serial) &&
            parseHardwareSerialFromMdns(d.serial) == null)
          d.serial,
    ];
    if (missing.isEmpty) return;
    await Future.wait([
      for (final s in missing)
        adb.hardwareSerial(s).then((hw) {
          if (hw != null && hw.isNotEmpty) _hwSerialCache[s] = hw;
        }),
    ]);
  }

  void _dedupeTransports(List<AdbDevice> found) =>
      dedupeTransports(found, _lastMdnsServices, _hwSerialCache);

  static final _ipv4PortRe = RegExp(r'^\d+\.\d+\.\d+\.\d+:(\d+)$');
  static final _ipv6PortRe = RegExp(r'^\[[^\]]+\]:(\d+)$');
  static final _mdnsTlsConnectRe =
      RegExp(r'^(.+?)\._adb-tls-connect\._tcp\.?$');
  static final _mdnsHwSerialRe =
      RegExp(r'^adb-([A-Za-z0-9]+)-[^.]+\._adb-tls-connect\._tcp\.?$');

  /// Extract hardware serial from an ADB mDNS TLS-connect transport name like
  /// `adb-3B241FDJH002HF-G9VfIY._adb-tls-connect._tcp` -> `3B241FDJH002HF`.
  static String? parseHardwareSerialFromMdns(String serial) =>
      _mdnsHwSerialRe.firstMatch(serial)?.group(1);

  static int _wirelessTransportRank(String serial) {
    if (_ipv4PortRe.hasMatch(serial)) return 0; // best: IPv4 ip:port
    if (_mdnsTlsConnectRe.hasMatch(serial)) return 1; // next: mDNS TLS
    if (_ipv6PortRe.hasMatch(serial)) return 2; // fallback: IPv6
    return 3;
  }

  static void dedupeTransports(
    List<AdbDevice> found, [
    List<MdnsService> mdnsServices = const [],
    Map<String, String> hwSerials = const {},
  ]) {
    final ipByInstance = {
      for (final s in mdnsServices)
        if (s.isConnect) s.instance: s.ip,
    };

    // 1. Deduplicate wireless transports that share the exact same hardware
    //    serial (`ro.serialno` or parsed from `adb-<hw>-...._adb-tls-connect`),
    //    keeping the highest-priority transport (IPv4 > mDNS TLS > IPv6).
    final bestByHw = <String, AdbDevice>{};
    String? hwOf(AdbDevice d) =>
        hwSerials[d.serial] ?? parseHardwareSerialFromMdns(d.serial);
    for (final d in found) {
      if (!d.isWireless) continue;
      final hw = hwOf(d);
      if (hw == null || hw.isEmpty) continue;
      final cur = bestByHw[hw];
      if (cur == null ||
          (d.isReady && !cur.isReady) ||
          (d.isReady == cur.isReady &&
              _wirelessTransportRank(d.serial) <
                  _wirelessTransportRank(cur.serial))) {
        bestByHw[hw] = d;
      }
    }
    found.removeWhere((d) {
      if (!d.isWireless) return false;
      final hw = hwOf(d);
      return hw != null && bestByHw[hw] != null && bestByHw[hw]!.serial != d.serial;
    });

    // 2. Drop `_adb-tls-connect._tcp` twin when its `ip:port` is present via mDNS.
    found.removeWhere((d) {
      final m = _mdnsTlsConnectRe.firstMatch(d.serial);
      if (m == null) return false;
      final ip = ipByInstance[m.group(1)];
      return ip != null && found.any((o) => o.serial.startsWith('$ip:'));
    });

    // 3. Drop IPv6 `[...]:port` twin when an IPv4 entry shares the same port
    //    and device model (same phone reached over dual-stack Wi-Fi).
    found.removeWhere((d) {
      final m6 = _ipv6PortRe.firstMatch(d.serial);
      if (m6 == null) return false;
      final port = m6.group(1)!;
      return found.any((o) {
        final m4 = _ipv4PortRe.firstMatch(o.serial);
        if (m4 == null || m4.group(1) != port) return false;
        return d.model.isEmpty || o.model.isEmpty || d.model == o.model;
      });
    });
  }

  void selectDevice(AdbDevice d) {
    if (d.serial == selected?.serial) return; // re-picking is not a reload
    selected = d;
    _rememberDevice(d.serial);
    _resetTree();
    wifiLink = null;
    notifyListeners();
    unawaited(expand(activeRootPath));
    unawaited(_loadVolumes(d.serial));
    unawaited(_refreshWifiLink());
  }

  /// Discover internal + external storage volumes on [serial].
  Future<void> _loadVolumes(String serial) async {
    final found = await adb.storageVolumes(serial);
    if (selected?.serial != serial) return;
    final prevPaths = [for (final v in volumes) v.path];
    final nextPaths = [for (final v in found) v.path];
    volumes = found;
    final match = found.where((v) => v.path == activeVolume.path).firstOrNull;
    if (match != null) {
      activeVolume = match;
    } else {
      activeVolume = StorageVolume.internal;
      unawaited(expand(activeRootPath));
    }
    if (!listEquals(prevPaths, nextPaths)) {
      if (found.length > 1) {
        final ext = found.where((v) => v.isExternal).map((v) => v.path).join(', ');
        log('Detected external storage: $ext');
      }
      notifyListeners();
    }
  }

  /// Switch the active browsed/mounted/cleanup storage root (e.g. internal
  /// `/sdcard` vs external `/storage/<UUID>`). Existing selections on other
  /// volumes are preserved so a backup can span internal + SD card together.
  void selectVolume(StorageVolume volume) {
    if (volume.path == activeVolume.path) return;
    activeVolume = volume;
    if (!volumes.any((v) => v.path == volume.path)) {
      volumes = [...volumes, volume];
    }
    cleanup.resetForDevice(selected?.serial, rootPath: volume.path);
    notifyListeners();
    if (selected != null) {
      unawaited(expand(activeRootPath));
    }
  }

  /// Persist the current device so the next launch re-selects it. Not cleared
  /// on disconnect — the point is to reconnect to it when it comes back.
  void _rememberDevice(String serial) {
    if (settings.lastDeviceSerial == serial) return;
    settings.lastDeviceSerial = serial;
    unawaited(settings.save());
  }

  /// Explicit tree reload (toolbar refresh button).
  void refreshTree() {
    if (selected == null) return;
    final wasChecked = {...checked};
    final wasExcluded = {...excluded};
    final prevVolume = activeVolume;
    _resetTree(keepVolume: true);
    activeVolume = prevVolume;
    checked.addAll(wasChecked); // a refresh shouldn't drop the selection
    excluded.addAll(wasExcluded);
    _scheduleSelectionSize();
    notifyListeners();
    unawaited(expand(activeRootPath));
    unawaited(_loadVolumes(selected!.serial));
    unawaited(_refreshWifiLink());
  }

  void _resetTree({bool keepVolume = false}) {
    if (!keepVolume) {
      volumes = const [StorageVolume.internal];
      activeVolume = StorageVolume.internal;
    }
    children.clear();
    entryBackupStatus.clear();
    expanded.clear();
    loading.clear();
    checked.clear();
    excluded.clear();
    _prefetched.clear();
    _prefetchingParents.clear();
    _verifyingDirs.clear();
    _sizeDebounce?.cancel();
    _sizeToken++;
    selectionBytes = 0;
    measuringSelection = false;
    cleanup.resetForDevice(selected?.serial, rootPath: activeRootPath);
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
      unawaited(_refreshBackupStatusFor(path));
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
    unawaited(_refreshBackupStatusFor(path));
  }

  int _statusToken = 0;

  /// Recompute local backup badges (`Backed up` / `Modified` / `Not backed up`)
  /// for every currently loaded tree folder against the active destination.
  /// Purely local filesystem checks — zero extra ADB round-trips.
  Future<void> refreshBackupStatuses() async {
    final token = ++_statusToken;
    final dest = destination.text.trim();
    if (dest.isEmpty || unmountedVolume(dest) != null) {
      if (entryBackupStatus.isNotEmpty) {
        entryBackupStatus.clear();
        notifyListeners();
      }
      return;
    }
    final rootDir = Directory(dest);
    if (!await rootDir.exists()) {
      if (entryBackupStatus.isNotEmpty) {
        entryBackupStatus.clear();
        notifyListeners();
      }
      return;
    }
    final snapBase = await _latestSnapshot(dest);
    final effectiveBase = snapBase ?? dest;
    if (token != _statusToken) return;

    final next = <String, EntryBackupStatus>{};
    for (final entry in children.entries) {
      final parentPath = entry.key;
      final isPrefetching = _prefetchingParents.contains(parentPath);
      for (final e in entry.value) {
        final probed = await _probeEntryBackupStatus(e, effectiveBase);
        final unverifiedLocalDir = e.isDir &&
            probed != EntryBackupStatus.notBackedUp &&
            probed != EntryBackupStatus.unknown &&
            (_verifyingDirs.contains(e.path) ||
                (!children.containsKey(e.path) &&
                    (isPrefetching || loading.contains(e.path))));
        next[e.path] =
            unverifiedLocalDir ? EntryBackupStatus.checking : probed;
        if (token != _statusToken) return;
      }
    }
    _rollUpPartialStatuses(next);
    entryBackupStatus
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  Future<void> _refreshBackupStatusFor(String parentPath) async {
    final list = children[parentPath];
    if (list == null || list.isEmpty) return;
    final dest = destination.text.trim();
    if (dest.isEmpty || unmountedVolume(dest) != null) return;
    if (!await Directory(dest).exists()) return;
    final effectiveBase = (await _latestSnapshot(dest)) ?? dest;
    final isPrefetching = _prefetchingParents.contains(parentPath);
    var changed = false;
    for (final e in list) {
      final probed = await _probeEntryBackupStatus(e, effectiveBase);
      final unverifiedLocalDir = e.isDir &&
          probed != EntryBackupStatus.notBackedUp &&
          probed != EntryBackupStatus.unknown &&
          (_verifyingDirs.contains(e.path) ||
              (!children.containsKey(e.path) &&
                  (isPrefetching || loading.contains(e.path))));
      final s = unverifiedLocalDir ? EntryBackupStatus.checking : probed;
      if (entryBackupStatus[e.path] != s) {
        entryBackupStatus[e.path] = s;
        changed = true;
      }
    }
    if (_rollUpPartialStatuses(entryBackupStatus)) changed = true;
    if (changed) notifyListeners();
  }

  /// Roll up folder statuses bottom-up from loaded children so a directory
  /// accurately reflects partial/modified/complete state instead of relying
  /// only on the directory's own mtime.
  bool _rollUpPartialStatuses(Map<String, EntryBackupStatus> statuses) {
    // Process deepest directories first so grandchild state bubbles up cleanly
    // (e.g. /sdcard/DCIM/Camera -> /sdcard/DCIM).
    final dirs = children.keys.toList()
      ..sort((a, b) => b.split('/').length.compareTo(a.split('/').length));
    var changed = false;
    for (final parentPath in dirs) {
      if (!statuses.containsKey(parentPath)) continue;
      final kids = children[parentPath];
      if (kids == null || kids.isEmpty) continue;
      var backed = 0;
      var modified = 0;
      var partial = 0;
      var missing = 0;
      var checking = 0;
      for (final c in kids) {
        if (c.isDir && isKnownEmpty(c.path)) continue;
        final s = statuses[c.path];
        if (s == null || s == EntryBackupStatus.unknown) continue;
        switch (s) {
          case EntryBackupStatus.backedUp:
            backed++;
          case EntryBackupStatus.modified:
            modified++;
          case EntryBackupStatus.partial:
            partial++;
          case EntryBackupStatus.notBackedUp:
            missing++;
          case EntryBackupStatus.checking:
            checking++;
          case EntryBackupStatus.unknown:
            break;
        }
      }
      final total = backed + modified + partial + missing + checking;
      if (total == 0) continue;
      final EntryBackupStatus rolled;
      if (partial > 0 || (missing > 0 && (backed > 0 || modified > 0 || checking > 0))) {
        rolled = EntryBackupStatus.partial;
      } else if (checking > 0) {
        // Never flash "Backed up" while any child subfolder is still verifying.
        rolled = EntryBackupStatus.checking;
      } else if (missing == total) {
        rolled = EntryBackupStatus.notBackedUp;
      } else if (modified > 0) {
        rolled = EntryBackupStatus.modified;
      } else {
        rolled = EntryBackupStatus.backedUp;
      }
      if (statuses[parentPath] != rolled) {
        statuses[parentPath] = rolled;
        changed = true;
      }
    }
    return changed;
  }

  static Future<EntryBackupStatus> _probeEntryBackupStatus(
    RemoteEntry entry,
    String effectiveBase,
  ) async {
    return probeEntryBackupStatus(entry, effectiveBase);
  }

  /// Resolve local backup status for [entry] against [effectiveBase].
  /// Supports both full-hierarchy backups (`<dest>/DCIM/Camera`) and nested
  /// subfolder backups (`<dest>/Camera`, which is how `BackupEngine` extracts
  /// when a user ticks `/sdcard/DCIM/Camera` directly).
  static Future<EntryBackupStatus> probeEntryBackupStatus(
    RemoteEntry entry,
    String effectiveBase,
  ) async {
    final extId = externalStorageId(entry.path);
    final String rel;
    final String localBase;
    if (extId != null) {
      final prefix = '/storage/$extId/';
      if (!entry.path.startsWith(prefix)) return EntryBackupStatus.unknown;
      rel = entry.path.substring(prefix.length);
      final namespaced = localJoin(effectiveBase, 'SD-$extId');
      localBase = await Directory(namespaced).exists() ? namespaced : effectiveBase;
    } else if (entry.path.startsWith('/sdcard/')) {
      rel = entry.path.substring('/sdcard/'.length);
      localBase = effectiveBase;
    } else {
      return EntryBackupStatus.unknown;
    }

    // Try full relative path first (`DCIM/Camera/a.jpg`), then progressively
    // shorter suffix paths (`Camera/a.jpg`, `Camera`) to match backups where a
    // subfolder was selected directly as the backup root.
    final segs = rel.split('/');
    FileStat? matchedStat;
    String? matchedLocalPath;
    for (var start = 0; start < segs.length; start++) {
      final candidateRel = segs.sublist(start).join('/');
      final localPath = localJoin(localBase, candidateRel);
      final stat = await FileStat.stat(localPath);
      if (stat.type == FileSystemEntityType.notFound) continue;
      if (entry.isDir && stat.type != FileSystemEntityType.directory) continue;
      if (!entry.isDir && stat.type != FileSystemEntityType.file) continue;
      matchedStat = stat;
      matchedLocalPath = localPath;
      break;
    }

    if (matchedStat == null || matchedLocalPath == null) {
      return EntryBackupStatus.notBackedUp;
    }
    final remoteTime = parseRemoteModified(entry.modified);
    if (!entry.isDir) {
      if (matchedStat.size != entry.size) return EntryBackupStatus.modified;
      if (remoteTime != null &&
          remoteTime.difference(matchedStat.modified).inMinutes > 2) {
        return EntryBackupStatus.modified;
      }
      return EntryBackupStatus.backedUp;
    }
    // An empty local directory does not count as backed up.
    if (await Directory(matchedLocalPath).list(followLinks: false).isEmpty) {
      return EntryBackupStatus.notBackedUp;
    }
    if (remoteTime != null &&
        remoteTime.difference(matchedStat.modified).inMinutes > 2) {
      return EntryBackupStatus.modified;
    }
    return EntryBackupStatus.backedUp;
  }

  /// Parse toybox `ls -lA` timestamps (`YYYY-MM-DD HH:MM`) into local DateTime.
  static DateTime? parseRemoteModified(String raw) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})$')
        .firstMatch(raw.trim());
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
    );
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

    // Add synchronously BEFORE any await so the concurrent
    // _refreshBackupStatusFor(parent) call immediately sees checking state
    // and never flashes "Backed up" before subdirs are verified.
    _prefetchingParents.add(parent);
    try {
      // Resolve local backup root once so we can recursively verify nested
      // locally-present folders (e.g. DCIM -> Camera) while showing a spinner
      // instead of flashing "Backed up" and later flipping to "Partial".
      final dest = destination.text.trim();
      String? effectiveBase;
      if (dest.isNotEmpty &&
          unmountedVolume(dest) == null &&
          await Directory(dest).exists()) {
        effectiveBase = (await _latestSnapshot(dest)) ?? dest;
      }
      unawaited(_refreshBackupStatusFor(parent));
      for (final d in dirs) {
        if (selected?.serial != serial) return; // device changed mid-prefetch
        if (children.containsKey(d.path) || loading.contains(d.path)) continue;
        final isBackedDir = effectiveBase != null &&
            (await _probeEntryBackupStatus(d, effectiveBase)) !=
                EntryBackupStatus.notBackedUp;
        if (isBackedDir) {
          _verifyingDirs.add(d.path);
          if (entryBackupStatus[d.path] != EntryBackupStatus.checking) {
            entryBackupStatus[d.path] = EntryBackupStatus.checking;
            notifyListeners();
          }
        }
        try {
          children[d.path] = await adb.list(serial, d.path);
          if (isBackedDir) {
            await _verifyBackedSubdirs(
              serial,
              d.path,
              effectiveBase,
              depth: 1,
            );
          }
        } catch (_) {
          // Unknown stays unknown; the chevron remains and a manual expand
          // will surface the error in the log.
        } finally {
          _verifyingDirs.remove(d.path);
        }
        await _refreshBackupStatusFor(d.path);
        await _refreshBackupStatusFor(parent);
        notifyListeners();
      }
    } finally {
      _prefetchingParents.remove(parent);
      unawaited(_refreshBackupStatusFor(parent));
    }
  }

  /// Recursively list subdirectories under [dirPath] that also exist in the
  /// local backup (up to depth 4) so nested folders like `DCIM/Camera` are
  /// verified before their parent ever settles on `Backed up` vs `Partial`.
  Future<void> _verifyBackedSubdirs(
    String serial,
    String dirPath,
    String effectiveBase, {
    required int depth,
  }) async {
    if (depth > 4 || selected?.serial != serial) return;
    final subdirs = (children[dirPath] ?? const <RemoteEntry>[])
        .where((e) => e.isDir)
        .toList();
    if (subdirs.isEmpty || subdirs.length > 40) return;
    for (final sub in subdirs) {
      if (selected?.serial != serial) return;
      if (children.containsKey(sub.path) || loading.contains(sub.path)) {
        continue;
      }
      final probed = await _probeEntryBackupStatus(sub, effectiveBase);
      if (probed == EntryBackupStatus.notBackedUp ||
          probed == EntryBackupStatus.unknown) {
        continue;
      }
      _verifyingDirs.add(sub.path);
      entryBackupStatus[sub.path] = EntryBackupStatus.checking;
      try {
        children[sub.path] = await adb.list(serial, sub.path);
        await _verifyBackedSubdirs(
          serial,
          sub.path,
          effectiveBase,
          depth: depth + 1,
        );
      } catch (_) {
        // Ignore unreadable subdir; leave best-effort state.
      } finally {
        _verifyingDirs.remove(sub.path);
      }
      await _refreshBackupStatusFor(sub.path);
    }
  }

  void collapse(String path) {
    expanded.remove(path);
    notifyListeners();
  }

  /// Whether [path] is in the backup (see selection.dart for the rule).
  bool isSelected(String path) => isPathSelected(path, checked, excluded);

  void toggleChecked(RemoteEntry entry) {
    togglePath(entry.path, checked, excluded);
    _scheduleSelectionSize();
    notifyListeners();
  }

  // --- selection size (on-device `du` of the ticked paths) ---

  /// Bytes the current selection occupies on the device, or null while it's
  /// unknown (measuring, or the last measure failed). 0 when nothing is ticked.
  int? selectionBytes = 0;
  bool measuringSelection = false;
  Timer? _sizeDebounce;
  int _sizeToken = 0;

  /// Re-measure the selection after a short debounce (toggles come in bursts).
  void _scheduleSelectionSize() {
    _sizeDebounce?.cancel();
    _sizeToken++; // invalidate any in-flight measure
    if (checked.isEmpty) {
      selectionBytes = 0;
      measuringSelection = false;
      return;
    }
    selectionBytes = null;
    measuringSelection = true;
    final token = _sizeToken;
    _sizeDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _measureSelection(token),
    );
  }

  Future<void> _measureSelection(int token) async {
    final serial = selected?.serial;
    if (serial == null) return;
    final checkedPaths = checked.toList();
    final excludedPaths = excluded.toList();
    try {
      var total = await adb.sizeOfAll(serial, checkedPaths);
      if (excludedPaths.isNotEmpty) {
        total -= await adb.sizeOfAll(serial, excludedPaths);
      }
      if (token != _sizeToken) return; // superseded by a newer toggle
      selectionBytes = total < 0 ? 0 : total;
    } catch (_) {
      if (token != _sizeToken) return;
      selectionBytes = null; // leave it blank rather than show a wrong number
    } finally {
      if (token == _sizeToken) {
        measuringSelection = false;
        notifyListeners();
      }
    }
  }

  /// Whether the active volume's top-level items are loaded (so select-all is possible).
  bool get canSelectAll => (children[activeRootPath] ?? const []).isNotEmpty;

  /// Whether every top-level item under the active volume is selected.
  bool get allSelected {
    final roots = children[activeRootPath];
    if (roots == null || roots.isEmpty) return false;
    return roots.every((e) => checked.contains(e.path));
  }

  /// One control: select everything in the active volume, or clear its selection.
  void toggleAll() => allSelected ? uncheckActiveVolume() : checkAll();

  /// Select every top-level item under the active volume (each covers its subtree).
  void checkAll() {
    final roots = children[activeRootPath];
    if (roots == null || roots.isEmpty) return;
    excluded.removeWhere(activeVolume.containsPath);
    checked
      ..removeWhere(activeVolume.containsPath)
      ..addAll(roots.map((e) => e.path));
    _scheduleSelectionSize();
    notifyListeners();
  }

  /// Clear selection within the active storage volume only.
  void uncheckActiveVolume() {
    final had = checked.any(activeVolume.containsPath) ||
        excluded.any(activeVolume.containsPath);
    if (!had) return;
    checked.removeWhere(activeVolume.containsPath);
    excluded.removeWhere(activeVolume.containsPath);
    _scheduleSelectionSize();
    notifyListeners();
  }

  /// Clear the whole selection across all volumes.
  void uncheckAll() {
    if (checked.isEmpty && excluded.isEmpty) return;
    checked.clear();
    excluded.clear();
    _scheduleSelectionSize();
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
    // Never write to a /Volumes path whose drive is unplugged (macOS): it
    // would land on the startup disk instead. The UI disables the button too.
    final volume = unmountedVolume(destDir);
    if (volume != null) {
      log('Drive "$volume" is not connected — nothing was backed up');
      return;
    }
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
      targetDir = localJoin(destDir, '$stamp.partial');
      _snapshotPartialDir = targetDir;
      _snapshotFinalDir = localJoin(destDir, stamp);
      _snapshotJobs.clear();
      baseDir = await _latestSnapshot(destDir);
    }

    for (final e in entries) {
      // Excluded descendants of this entry become path-shaped ignore patterns
      // (relative to the source's parent, matching the manifest keys).
      final prefix = AdbClient.dirname(e.path).length + 1;
      // Keep external SD card backups in a dedicated `SD-<UUID>` subfolder so
      // they never collide with internal `/sdcard` folders (e.g. two DCIMs).
      final extSubdir = externalStorageBackupSubdir(e.path);
      final jobDest = extSubdir == null ? targetDir : localJoin(targetDir, extSubdir);
      final jobBase = (baseDir == null || extSubdir == null)
          ? baseDir
          : localJoin(baseDir, extSubdir);
      final job = BackupJob(
        source: e,
        serial: serial,
        destDir: jobDest,
        baseDir: jobBase,
        incremental: incremental,
        ignore: [
          if (settings.skipClutter) ...settings.clutterPatterns,
          for (final x in excluded)
            if (x.startsWith('${e.path}/')) x.substring(prefix),
        ],
        autoVerify: settings.autoVerify,
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
      final name = localBaseName(e.path);
      if (!_snapshotDirRe.hasMatch(name)) continue;
      if (latest == null || name.compareTo(latest) > 0) latest = name;
    }
    return latest == null ? null : localJoin(destDir, latest);
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
    await drive.mount(serial, settings.adbPath, rootPath: activeRootPath);
    if (drive.mounted) unawaited(_revealMount());
  }

  /// Pop open the freshly-mounted drive in Explorer. Without this the mount is
  /// silent — the letter just appears, with no window — which reads as "nothing
  /// happened". WinFsp needs a moment before the letter is browsable, so wait
  /// for it rather than racing Explorer to a not-yet-ready drive; bail if the
  /// host dies early (e.g. missing .NET runtime), so we never open a broken one.
  Future<void> _revealMount() async {
    final root = '${drive.mountPoint}\\';
    for (var i = 0; i < 20 && drive.mounted; i++) {
      if (Directory(root).existsSync()) {
        await Process.run('explorer.exe', [root]);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
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
  String? _pairedGuid;

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
    _pairedGuid = null;
    qrPayload = 'WIFI:T:ADB;S:$_qrName;P:$_qrPassword;;';
    pairingStatus = 'Scan the code from Wireless debugging → '
        '"Pair device with QR code"';
    var busy = false;
    Future<void> tick() async {
      if (busy) return;
      busy = true;
      try {
        await _qrTick();
      } catch (_) {
        // transient adb hiccup; next tick retries
      } finally {
        busy = false;
      }
    }

    _qrTimer?.cancel();
    _qrTimer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    unawaited(tick());
    notifyListeners();
  }

  void stopQrPairing() {
    _qrTimer?.cancel();
    _qrTimer = null;
    qrPayload = null;
    _qrPassword = null;
    _pairedHostIp = null;
    _pairedGuid = null;
    notifyListeners();
  }

  Future<void> _qrTick() async {
    final services = await adb.mdnsServices();
    _lastMdnsServices = services;
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
          _pairedGuid = RegExp(r'\[guid=([^\]]+)\]').firstMatch(res)?.group(1);
          pairingStatus = 'Paired ✓ — connecting…';
          notifyListeners();
        } else {
          pairingStatus = 'Pairing failed: $res';
        }
      }
    }

    if (_qrPassword == null && (_pairedHostIp != null || _pairedGuid != null)) {
      // Prefer exact mDNS guid match from `adb pair` output (works even when
      // pairing used IPv6 and connect uses IPv4), else match by host IP.
      final connect = (_pairedGuid != null
              ? discoveredConnectable
                  .where((s) => s.instance == _pairedGuid)
                  .firstOrNull
              : null) ??
          (_pairedHostIp != null
              ? discoveredConnectable
                  .where((s) => s.ip == _pairedHostIp)
                  .firstOrNull
              : null);
      if (connect != null) {
        final res = await adb.connect(connect.address);
        log('adb connect ${connect.address} → $res');
        if (res.toLowerCase().contains('connected')) {
          pairingStatus = 'Connected ✓';
          _pairedHostIp = null;
          _pairedGuid = null;
          _qrTimer?.cancel();
          _qrTimer = null;
          await _pollDevices();
        }
      } else {
        // ADB itself may have already auto-connected the phone via mDNS.
        await _pollDevices();
        final alreadyUp = devices.any(
          (d) =>
              d.isReady &&
              ((_pairedGuid != null && d.serial.startsWith(_pairedGuid!)) ||
                  (_pairedHostIp != null &&
                      d.serial.contains(_pairedHostIp!))),
        );
        if (alreadyUp) {
          pairingStatus = 'Connected ✓';
          _pairedHostIp = null;
          _pairedGuid = null;
          _qrTimer?.cancel();
          _qrTimer = null;
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
      // Already connected — as IPv4, IPv6 on the same port, or adb's own mdns
      // transport (serial starts with the mdns instance name).
      final colon = s.address.lastIndexOf(':');
      final portSuffix = colon == -1 ? '' : s.address.substring(colon);
      if (devices.any((d) =>
          d.serial.contains(s.ip) ||
          d.serial.startsWith(s.instance) ||
          (portSuffix.isNotEmpty && d.serial.endsWith(portSuffix)))) {
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
    excluded.clear();
    if (p.destination.trim().isNotEmpty) {
      setDestination(p.destination);
    } else if (destination.text.trim().isEmpty &&
        settings.lastDestination.trim().isNotEmpty) {
      destination.text = settings.lastDestination;
    }
    settings.layout = p.layout;
    settings.incremental = p.incremental;

    // If the profile targets an external SD card volume, switch the active
    // tree root to it so the user immediately sees their selected folders.
    final targetRoot = p.rootPath ??
        (p.paths.isNotEmpty && externalStorageId(p.paths.first) != null
            ? '/storage/${externalStorageId(p.paths.first)!}'
            : rootPath);
    final match = volumes.where((v) => v.path == targetRoot).firstOrNull;
    if (match != null) {
      activeVolume = match;
    } else {
      final extId = externalStorageId(targetRoot);
      activeVolume = extId != null
          ? StorageVolume(
              path: targetRoot,
              label: 'SD card ($extId)',
              isExternal: true,
            )
          : StorageVolume.internal;
    }
    if (selected != null) {
      unawaited(expand(activeRootPath));
      // Auto-expand ancestor folders of checked subpaths (e.g. /sdcard/DCIM
      // when /sdcard/DCIM/Camera is saved) so the selection is visible.
      for (final path in p.paths) {
        if (!activeVolume.containsPath(path)) continue;
        var parent = AdbClient.dirname(path);
        while (parent.length > activeRootPath.length &&
            activeVolume.containsPath(parent)) {
          unawaited(expand(parent));
          parent = AdbClient.dirname(parent);
        }
      }
    }

    _scheduleSelectionSize();
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
      rootPath: activeRootPath,
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
