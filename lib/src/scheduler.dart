import 'dart:io';

/// Registers daily backup runs with the OS scheduler — Task Scheduler on
/// Windows, a launchd LaunchAgent on macOS. The job launches this app with
/// `--run-profile <name>`, which backs up headlessly and exits.
class TaskScheduler {
  static String taskName(String profile) => 'AndroidFiles backup - $profile';

  /// Whether daily scheduling is available on this platform.
  static bool get supported => Platform.isWindows || Platform.isMacOS;

  /// Returns null on success, otherwise the scheduler's error text.
  static Future<String?> schedule(String profile, String hhmm) async {
    if (Platform.isMacOS) return _Launchd.schedule(profile, hhmm);
    final exe = Platform.resolvedExecutable;
    final r = await Process.run('schtasks', [
      '/Create', '/F',
      '/TN', taskName(profile),
      '/TR', '"$exe" --run-profile "$profile"',
      '/SC', 'DAILY',
      '/ST', hhmm,
    ]);
    return r.exitCode == 0 ? null : '${r.stdout}${r.stderr}'.trim();
  }

  static Future<String?> unschedule(String profile) async {
    if (Platform.isMacOS) return _Launchd.unschedule(profile);
    final r = await Process.run(
        'schtasks', ['/Delete', '/F', '/TN', taskName(profile)]);
    return r.exitCode == 0 ? null : '${r.stdout}${r.stderr}'.trim();
  }

  static Future<bool> isScheduled(String profile) async {
    if (Platform.isMacOS) return _Launchd.plist(profile).exists();
    final r = await Process.run('schtasks', ['/Query', '/TN', taskName(profile)]);
    return r.exitCode == 0;
  }
}

/// A per-profile LaunchAgent in ~/Library/LaunchAgents, loaded into the
/// user's GUI session so the app can show its window and notification.
/// launchd runs a StartCalendarInterval job missed during sleep once the Mac
/// wakes, so a backup due at 03:00 on a sleeping laptop happens on wake.
class _Launchd {
  /// Percent-encoding keeps any profile name a valid, collision-free label
  /// and file name.
  static String label(String profile) =>
      'dev.mnow.androidfiles.backup.${Uri.encodeComponent(profile)}';

  static File plist(String profile) => File(
      '${Platform.environment['HOME']}/Library/LaunchAgents/${label(profile)}.plist');

  static Future<String> _domain() async {
    final r = await Process.run('id', ['-u']);
    return 'gui/${(r.stdout as String).trim()}';
  }

  static String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static Future<String?> schedule(String profile, String hhmm) async {
    final parts = hhmm.split(':');
    final hour = int.tryParse(parts.first);
    final minute = parts.length > 1 ? int.tryParse(parts[1]) : null;
    if (hour == null || minute == null) return 'Invalid time "$hhmm"';
    final f = plist(profile);
    await f.parent.create(recursive: true);
    await f.writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xml(label(profile))}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${_xml(Platform.resolvedExecutable)}</string>
    <string>--run-profile</string>
    <string>${_xml(profile)}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
''', flush: true);
    final domain = await _domain();
    // Re-scheduling replaces the job: bootstrap refuses one already loaded.
    // bootout returns before the old job is fully gone, during which
    // bootstrap fails with "Input/output error" — so retry briefly.
    await Process.run('launchctl', ['bootout', '$domain/${label(profile)}']);
    late ProcessResult r;
    for (var attempt = 0; attempt < 10; attempt++) {
      r = await Process.run('launchctl', ['bootstrap', domain, f.path]);
      if (r.exitCode == 0) return null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await f.delete().catchError((_) => f);
    return 'launchctl bootstrap failed (${r.exitCode}): '
        '${'${r.stdout}${r.stderr}'.trim()}';
  }

  static Future<String?> unschedule(String profile) async {
    final domain = await _domain();
    // Not loaded (e.g. after a manual launchctl bootout) is fine: the goal is
    // that it no longer runs.
    await Process.run('launchctl', ['bootout', '$domain/${label(profile)}']);
    final f = plist(profile);
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      return 'Could not remove ${f.path}: $e';
    }
    return null;
  }
}
