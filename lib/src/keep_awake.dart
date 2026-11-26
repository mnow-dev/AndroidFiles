import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps a Mac from idle-sleeping (and the app from being App-Napped) while
/// a backup runs. A sleeping Mac stops the transfer, and App Nap throttles a
/// backgrounded app's timers and disk I/O — both easy to hit on a laptop
/// during a multi-hour backup. Backed by an NSProcessInfo activity in the
/// macOS runner (MainFlutterWindow.swift); a no-op on other platforms.
/// The display may still sleep.
class KeepAwake {
  static const _channel = MethodChannel('androidfiles/power');
  static bool _on = false;

  static Future<void> set(bool on) async {
    if (!Platform.isMacOS || on == _on) return;
    _on = on;
    try {
      await _channel.invokeMethod<void>('keepAwake', on);
    } catch (_) {
      // Best effort: a backup that might pause on sleep beats no backup.
    }
  }
}
