import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../preview_service.dart';
import 'win_theme.dart' show formatShortModified;

/// Bridges Flutter to the native separate resizable macOS Quick Look window
/// (`NativeQuickLookWindowController` in `MainFlutterWindow.swift`).
///
/// The native window can be resized larger than the main window, moved to a
/// second display, or zoomed to full screen, and embeds Apple's `QLPreviewView`
/// for full video playback, multi-page PDFs, HEIC/RAW photos, HTML, Markdown,
/// text, audio, and Office files.
class NativeQuickLookWindow {
  static const _channel = MethodChannel('androidfiles/quicklook');

  static bool _handlerRegistered = false;
  static AppController? _app;
  static List<PreviewItem> _items = const [];
  static int _index = 0;
  static int _loadToken = 0;
  static File? _currentLocalFile;

  static void _ensureHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onNavigate':
          final delta = (call.arguments as int?) ?? 0;
          _go(delta);
        case 'onToggleChecked':
          if (_index >= 0 && _index < _items.length) {
            final item = _items[_index];
            item.onToggleChecked?.call();
            await _pushCurrentState(
              filePath: _currentLocalFile?.path,
              loading: false,
            );
          }
        case 'onForceDownload':
          unawaited(_loadCurrent(forceDownload: true));
        case 'onSaveCopy':
          unawaited(_saveCopy());
        case 'onOpenExternal':
          unawaited(_openExternal());
        case 'onClosed':
          _loadToken++;
          _currentLocalFile = null;
      }
    });
  }

  /// Open (or update) the separate native macOS Quick Look window.
  /// Returns `true` if handled natively, `false` to fall back to the Flutter
  /// in-app lightbox (e.g. on Windows or inside `flutter test`).
  static Future<bool> open({
    required AppController app,
    required List<PreviewItem> items,
    required int initialIndex,
  }) async {
    if (!Platform.isMacOS ||
        Platform.environment.containsKey('FLUTTER_TEST') ||
        items.isEmpty) {
      return false;
    }
    _ensureHandler();
    _app = app;
    _items = items;
    _index = initialIndex.clamp(0, items.length - 1);
    try {
      await _loadCurrent();
      return true;
    } on MissingPluginException {
      return false;
    }
  }

  static void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _items.length) return;
    _index = next;
    unawaited(_loadCurrent());
  }

  static Future<void> _loadCurrent({bool forceDownload = false}) async {
    final app = _app;
    if (app == null || _index < 0 || _index >= _items.length) return;
    final token = ++_loadToken;
    final item = _items[_index];
    _currentLocalFile = null;

    final serial = app.selected?.serial;
    if (serial == null) {
      await _pushCurrentState(
        loading: false,
        message: 'No device connected.',
      );
      return;
    }

    // Fast path: check local backup before even showing a spinner!
    final localBackup = await PreviewService.resolveLocalBackupFile(
      item.devicePath,
      item.size,
      app.destination.text,
    );
    if (token != _loadToken) return;

    if (localBackup != null) {
      _currentLocalFile = localBackup;
      await _pushCurrentState(
        filePath: localBackup.path,
        fromLocalBackup: true,
        loading: false,
      );
      _prefetchNext(app, serial);
      return;
    }

    // Guard huge remote unbacked media/files before saturating Wi-Fi.
    final limit = (item.kind == PreviewKind.image ||
            item.kind == PreviewKind.heicImage)
        ? PreviewService.autoImageLimitBytes
        : PreviewService.autoMediaLimitBytes;
    if (!forceDownload &&
        (item.kind == PreviewKind.video ||
            item.kind == PreviewKind.pdf ||
            item.kind == PreviewKind.image ||
            item.kind == PreviewKind.heicImage) &&
        item.size > limit) {
      await _pushCurrentState(
        loading: false,
        message:
            '${item.name} is ${fmtBytes(item.size)} and is not in your local backup folder yet.\nDownload it into the temporary preview cache?',
        actionLabel: 'Download & Preview (${fmtBytes(item.size)})',
      );
      return;
    }

    await _pushCurrentState(
      loading: true,
      message: 'Loading ${item.name} (${fmtBytes(item.size)}) from phone…',
    );

    try {
      final file = await app.preview.ensureLocalFile(
        serial,
        item,
        destRoot: app.destination.text,
      );
      if (token != _loadToken) return;
      _currentLocalFile = file;
      await _pushCurrentState(
        filePath: file.path,
        fromLocalBackup: false,
        loading: false,
      );
      _prefetchNext(app, serial);
    } catch (e) {
      if (token != _loadToken) return;
      await _pushCurrentState(
        loading: false,
        message: 'Could not load preview:\n$e',
      );
    }
  }

  static void _prefetchNext(AppController app, String serial) {
    if (_index + 1 >= _items.length) return;
    final next = _items[_index + 1];
    if ((next.kind == PreviewKind.image ||
            next.kind == PreviewKind.heicImage) &&
        next.size > 0 &&
        next.size <= 10 * 1024 * 1024) {
      unawaited(
        app.preview
            .ensureLocalFile(serial, next, destRoot: app.destination.text)
            .catchError((_) => File('')),
      );
    }
  }

  static Future<void> _pushCurrentState({
    String? filePath,
    bool fromLocalBackup = false,
    required bool loading,
    String? message,
    String? actionLabel,
  }) async {
    if (_index < 0 || _index >= _items.length) return;
    final item = _items[_index];
    final parts = <String>[
      fmtBytes(item.size),
      if (item.modified.isNotEmpty) formatShortModified(item.modified),
      if (!loading && filePath != null)
        (fromLocalBackup ? 'Local backup' : 'From phone'),
    ];
    final canCheck = item.isChecked != null && item.onToggleChecked != null;
    await _channel.invokeMethod('show', {
      'title': item.name,
      'subtitle': parts.join('  ·  '),
      'index': _index,
      'total': _items.length,
      'filePath': filePath,
      'loading': loading,
      'message': message,
      'actionLabel': actionLabel,
      'canCheck': canCheck,
      'checked': canCheck ? item.isChecked!() : false,
      'checkLabel': item.checkLabel ?? 'Selected',
      'isMedia': item.kind == PreviewKind.video || item.kind == PreviewKind.audio,
    });
  }

  static Future<void> _saveCopy() async {
    final app = _app;
    if (app == null || _index < 0 || _index >= _items.length) return;
    final serial = app.selected?.serial;
    if (serial == null) return;
    final item = _items[_index];
    final dest = await FilePicker.saveFile(
      dialogTitle: 'Save Copy',
      fileName: item.name,
    );
    if (dest == null) return;
    final src = _currentLocalFile ??
        await app.preview.ensureLocalFile(
          serial,
          item,
          destRoot: app.destination.text,
        );
    await src.copy(dest);
  }

  static Future<void> _openExternal() async {
    final app = _app;
    if (app == null || _index < 0 || _index >= _items.length) return;
    final serial = app.selected?.serial;
    if (serial == null) return;
    final item = _items[_index];
    final src = _currentLocalFile ??
        await app.preview.ensureLocalFile(
          serial,
          item,
          destRoot: app.destination.text,
        );
    await PreviewService.openExternally(src);
  }
}
