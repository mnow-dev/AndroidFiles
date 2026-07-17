import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Drives the bundled AndroidFilesUpdater.exe, which wraps Velopack's official
/// .NET SDK. This is only meaningful in a Velopack-installed build; in the dev
/// build or the portable ZIP the helper reports "not installed" and callers
/// fall back to opening the release page.
class Updater {
  /// AndroidFilesUpdater.exe sits next to the app exe in a shipped build (it
  /// must live inside Velopack's current\ dir to find its install context). In
  /// development it may not be present at all — that's expected.
  static String get exePath {
    final dir = File(Platform.resolvedExecutable).parent.path;
    return '$dir\\AndroidFilesUpdater.exe';
  }

  static bool get available => File(exePath).existsSync();

  /// Whether this is a Velopack install that can self-update. Uses --version,
  /// which reports the installed version (non-empty) purely from the on-disk
  /// install context — no network, so a private repo or being offline doesn't
  /// make a real install look unmanaged. False on any error.
  static Future<bool> get isManagedInstall async {
    if (!available) return false;
    try {
      final r = await Process.run(exePath, ['--version']);
      return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Download and apply the update, then relaunch the app. Streams 0..100
  /// [onProgress]. On success the helper replaces this app (so [onExiting] is
  /// the app's cue to shut itself down and this future never completes
  /// normally). Returns false if there's nothing to apply or the helper isn't
  /// a managed install, so the caller can fall back to the release page.
  static Future<bool> applyAndRestart({
    required int appPid,
    void Function(int percent)? onProgress,
    required Future<void> Function() onExiting,
  }) async {
    if (!available) return false;
    final proc = await Process.start(
      exePath,
      ['--apply', '--wait-pid', '$appPid'],
    );

    var handledExit = false;
    final done = Completer<bool>();

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
      if (line.startsWith('progress ')) {
        final p = int.tryParse(line.substring(9).trim());
        if (p != null) onProgress?.call(p);
      } else if (line == 'ready-to-apply' && !handledExit) {
        // The helper is about to replace current\ — get out of its way. It
        // survives our exit and finishes the swap, then relaunches us.
        handledExit = true;
        await onExiting();
        exit(0);
      } else if (line == 'no-update') {
        if (!done.isCompleted) done.complete(false);
      }
    });

    unawaited(proc.exitCode.then((code) {
      // We only reach here without a restart when nothing was applied.
      if (!done.isCompleted) done.complete(false);
    }));

    return done.future;
  }
}
