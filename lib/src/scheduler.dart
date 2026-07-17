import 'dart:io';

/// Registers daily backup runs in the Windows Task Scheduler. The task
/// launches this app with `--run-profile <name>`, which backs up headlessly
/// and exits.
class TaskScheduler {
  static String taskName(String profile) => 'AndroidFiles backup - $profile';

  /// Returns null on success, otherwise schtasks' error text.
  static Future<String?> schedule(String profile, String hhmm) async {
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
    final r = await Process.run(
        'schtasks', ['/Delete', '/F', '/TN', taskName(profile)]);
    return r.exitCode == 0 ? null : '${r.stdout}${r.stderr}'.trim();
  }

  static Future<bool> isScheduled(String profile) async {
    final r = await Process.run('schtasks', ['/Query', '/TN', taskName(profile)]);
    return r.exitCode == 0;
  }
}
