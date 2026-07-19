import 'dart:convert';
import 'dart:io';

import 'manifest.dart';
import 'models.dart';

/// A saved backup configuration for one-click re-runs.
class Profile {
  String name;
  List<String> paths;
  String destination;
  BackupLayout layout;
  bool incremental;

  /// "HH:MM" when a daily Task Scheduler run is registered (display cache;
  /// schtasks is the source of truth).
  String? scheduleTime;

  Profile({
    required this.name,
    required this.paths,
    required this.destination,
    this.layout = BackupLayout.mirror,
    this.incremental = true,
    this.scheduleTime,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'paths': paths,
        'destination': destination,
        'layout': layout.name,
        'incremental': incremental,
        if (scheduleTime != null) 'scheduleTime': scheduleTime,
      };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
        name: j['name'] as String,
        paths: (j['paths'] as List).cast<String>(),
        destination: j['destination'] as String? ?? '',
        layout: BackupLayout.values.asNameMap()[j['layout']] ?? BackupLayout.mirror,
        incremental: j['incremental'] as bool? ?? true,
        scheduleTime: j['scheduleTime'] as String?,
      );
}

/// Tiny JSON-file settings store (%APPDATA%\AndroidFiles\settings.json).
class Settings {
  String adbPath;
  String lastDestination;

  /// Serial of the last device that was selected; re-selected on launch when
  /// it's connected again (handy with more than one phone). USB serials are
  /// stable; wireless ip:port ones change per boot, so they simply won't match.
  String lastDeviceSerial;

  BackupLayout layout;
  bool incremental;
  String driveExePath;
  String driveMountPoint;

  /// Explorer drive writes through to the phone. Opt-in and risky —
  /// guarded by a warning in the settings dialog.
  bool driveWritable;

  /// 'light' | 'dark' | 'system'
  String themeMode;

  /// UI language code (e.g. 'en', 'es'); empty = follow the system locale.
  String locale;
  bool showLog;

  /// Fraction of the window width given to the folder tree (drag to resize).
  double splitRatio;

  /// Check GitHub Releases for a newer version on launch. On by default; the
  /// only thing it sends is an unauthenticated GET to a public endpoint.
  bool checkForUpdates;

  /// Skip known clutter (caches/system files, see [clutterPatterns]) during
  /// backups. Off by default so a backup is complete unless the user opts in.
  bool skipClutter;

  /// Run a deep (md5) verify automatically after each backup.
  bool autoVerify;

  /// Glob patterns pruned when [skipClutter] is on; user-editable in Settings.
  List<String> clutterPatterns;

  final List<Profile> profiles;

  Settings({
    required this.adbPath,
    this.lastDestination = '',
    this.lastDeviceSerial = '',
    this.layout = BackupLayout.mirror,
    this.incremental = true,
    String? driveExePath,
    this.driveMountPoint = 'P:',
    this.driveWritable = false,
    this.themeMode = 'light',
    this.locale = '',
    this.showLog = false,
    this.splitRatio = 0.4,
    this.checkForUpdates = true,
    this.skipClutter = false,
    this.autoVerify = false,
    List<String>? clutterPatterns,
    List<Profile>? profiles,
  })  : driveExePath = driveExePath ?? defaultDriveExePath(),
        clutterPatterns = clutterPatterns ?? List.of(defaultClutterPatterns),
        profiles = profiles ?? [];

  /// In a shipped package AdbDrive.exe sits in drive\ next to the app exe. In
  /// development it lives in the repo's drive\publish, which `flutter run`
  /// finds via the working directory — never hardcode a path here, it ends up
  /// written into every user's settings.json.
  static String defaultDriveExePath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final shipped = '$exeDir\\drive\\AdbDrive.exe';
    if (File(shipped).existsSync()) return shipped;
    final dev = '${Directory.current.path}\\drive\\publish\\AdbDrive.exe';
    if (File(dev).existsSync()) return dev;
    // Nothing found: name the shipped location so the "not found" message in
    // DriveManager points somewhere meaningful.
    return shipped;
  }

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return File('$appData\\AndroidFiles\\settings.json');
  }

  static Future<Settings> load() async {
    var adbPath = 'adb';
    for (final candidate in [
      r'D:\Dev\tools\platform-tools\adb.exe',
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
    ]) {
      if (await File(candidate).exists()) {
        adbPath = candidate;
        break;
      }
    }
    final settings = Settings(adbPath: adbPath);
    try {
      final f = _file();
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final saved = json['adbPath'] as String?;
        if (saved != null && await File(saved).exists()) settings.adbPath = saved;
        settings.lastDestination = json['lastDestination'] as String? ?? '';
        settings.lastDeviceSerial = json['lastDeviceSerial'] as String? ?? '';
        settings.layout =
            BackupLayout.values.asNameMap()[json['layout']] ?? BackupLayout.mirror;
        settings.incremental = json['incremental'] as bool? ?? true;
        settings.driveExePath =
            json['driveExePath'] as String? ?? settings.driveExePath;
        settings.driveMountPoint =
            json['driveMountPoint'] as String? ?? settings.driveMountPoint;
        settings.driveWritable = json['driveWritable'] as bool? ?? false;
        settings.themeMode = json['themeMode'] as String? ?? 'light';
        settings.locale = json['locale'] as String? ?? '';
        settings.showLog = json['showLog'] as bool? ?? false;
        settings.splitRatio =
            (json['splitRatio'] as num?)?.toDouble().clamp(0.15, 0.85) ?? 0.4;
        settings.checkForUpdates = json['checkForUpdates'] as bool? ?? true;
        settings.skipClutter = json['skipClutter'] as bool? ?? false;
        settings.autoVerify = json['autoVerify'] as bool? ?? false;
        final cp = json['clutterPatterns'];
        if (cp is List) settings.clutterPatterns = cp.cast<String>();
        for (final p in (json['profiles'] as List? ?? const [])) {
          settings.profiles.add(Profile.fromJson(p as Map<String, dynamic>));
        }
      }
    } catch (_) {
      // Corrupt settings are not worth failing startup over.
    }
    return settings;
  }

  Future<void> save() async {
    final f = _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({
      'adbPath': adbPath,
      'lastDestination': lastDestination,
      'lastDeviceSerial': lastDeviceSerial,
      'layout': layout.name,
      'incremental': incremental,
      'driveExePath': driveExePath,
      'driveMountPoint': driveMountPoint,
      'driveWritable': driveWritable,
      'themeMode': themeMode,
      'locale': locale,
      'showLog': showLog,
      'splitRatio': splitRatio,
      'checkForUpdates': checkForUpdates,
      'skipClutter': skipClutter,
      'autoVerify': autoVerify,
      'clutterPatterns': clutterPatterns,
      'profiles': [for (final p in profiles) p.toJson()],
    }));
  }
}
