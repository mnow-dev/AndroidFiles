import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart' show FluentIcons;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show SelectionArea, Tooltip;
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../preview_service.dart';
import 'macos/mac_theme.dart';
import 'quick_look_window.dart';
import 'win_theme.dart';

/// Choose a crisp platform-appropriate icon for a [PreviewKind] (shared by the
/// Quick Look header and file rows in the macOS and Windows trees).
IconData iconForPreviewKind(PreviewKind kind, {required bool mac}) {
  if (mac) {
    return switch (kind) {
      PreviewKind.image || PreviewKind.heicImage => CupertinoIcons.photo,
      PreviewKind.video => CupertinoIcons.film,
      PreviewKind.audio => CupertinoIcons.music_note,
      PreviewKind.pdf => CupertinoIcons.doc_richtext,
      PreviewKind.markdown ||
      PreviewKind.html ||
      PreviewKind.json ||
      PreviewKind.text =>
        CupertinoIcons.doc_text,
      PreviewKind.unsupported => CupertinoIcons.doc,
    };
  }
  return switch (kind) {
    PreviewKind.image || PreviewKind.heicImage => FluentIcons.photo2,
    PreviewKind.video => FluentIcons.video,
    PreviewKind.audio => FluentIcons.music_in_collection,
    PreviewKind.pdf => FluentIcons.pdf,
    PreviewKind.markdown ||
    PreviewKind.html ||
    PreviewKind.json ||
    PreviewKind.text =>
      FluentIcons.text_document,
    PreviewKind.unsupported => FluentIcons.page,
  };
}

/// Show Quick Look for [items] starting at [initialIndex].
///
/// On macOS, opens a **separate, freely resizable, fullscreen-capable native
/// macOS Quick Look window** (`QLPreviewView`) that can grow larger than the
/// main window and move across displays. On Windows (and in Flutter widget
/// tests), opens the Fluent lightbox with a **Pop Out** button to launch an
/// independent resizable window.
Future<void> showQuickLookDialog(
  BuildContext context, {
  required AppController app,
  required List<PreviewItem> items,
  required int initialIndex,
  bool? macStyle,
}) async {
  if (items.isEmpty) return;
  final clamped = initialIndex.clamp(0, items.length - 1);
  final useMac = macStyle ?? Platform.isMacOS;

  if (useMac && Platform.isMacOS) {
    final openedNatively = await NativeQuickLookWindow.open(
      app: app,
      items: items,
      initialIndex: clamped,
    );
    if (openedNatively) return;
  }

  if (!context.mounted) return;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close Quick Look',
    barrierColor: const Color(0x99000000),
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (ctx, _, _) => _QuickLookLightbox(
      app: app,
      items: items,
      initialIndex: clamped,
      macStyle: useMac,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Full-window Quick Look view used when AndroidFiles is launched in
/// standalone preview window mode (`--preview-spec <jsonPath>`, e.g. via the
/// Windows **Pop Out** button so the preview window can be resized larger than
/// the main window or maximized).
class QuickLookStandaloneView extends StatelessWidget {
  final AppController app;
  final List<PreviewItem> items;
  final int initialIndex;
  final bool macStyle;

  const QuickLookStandaloneView({
    super.key,
    required this.app,
    required this.items,
    required this.initialIndex,
    required this.macStyle,
  });

  @override
  Widget build(BuildContext context) {
    return _QuickLookLightbox(
      app: app,
      items: items,
      initialIndex: initialIndex,
      macStyle: macStyle,
      standaloneWindow: true,
    );
  }
}

class _QuickLookTheme {
  final bool isDark;
  final bool macStyle;
  final Color bg;
  final Color headerBg;
  final Color stageBg;
  final Color cardBg;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color accentSoft;
  final Color accentFg;
  final Color greenBg;
  final Color greenFg;
  final Color greenBorder;
  final Color warnBg;
  final Color warnFg;
  final Color hoverBg;
  final String monoFont;

  const _QuickLookTheme({
    required this.isDark,
    required this.macStyle,
    required this.bg,
    required this.headerBg,
    required this.stageBg,
    required this.cardBg,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.accentFg,
    required this.greenBg,
    required this.greenFg,
    required this.greenBorder,
    required this.warnBg,
    required this.warnFg,
    required this.hoverBg,
    required this.monoFont,
  });

  factory _QuickLookTheme.of(BuildContext context, {required bool macStyle}) {
    if (macStyle) {
      final p = MacPalette.of(context);
      return _QuickLookTheme(
        isDark: p.isDark,
        macStyle: true,
        bg: p.windowBg,
        headerBg: p.toolbarBg,
        stageBg: p.isDark ? const Color(0xFF141518) : const Color(0xFFF3F4F6),
        cardBg: p.inspectorBg,
        border: p.border,
        textPrimary: p.textPrimary,
        textSecondary: p.textSecondary,
        textTertiary: p.textTertiary,
        accent: p.green,
        accentSoft: p.greenSoft,
        accentFg: p.isDark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
        greenBg: p.isDark ? const Color(0xFF173624) : const Color(0xFFD6F5E3),
        greenFg: p.isDark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
        greenBorder:
            p.isDark ? const Color(0xFF285E3D) : const Color(0xFFA3E4BF),
        warnBg: p.isDark ? const Color(0xFF3A2A12) : const Color(0xFFFEECC8),
        warnFg: p.isDark ? const Color(0xFFFFCA62) : const Color(0xFF8A4300),
        hoverBg: p.surfaceHover,
        monoFont: macMonoFont,
      );
    }
    final p = WinPalette.of(context);
    return _QuickLookTheme(
      isDark: p.dark,
      macStyle: false,
      bg: p.cardBg,
      headerBg: p.cardSubBg,
      stageBg: p.dark ? const Color(0xFF141518) : const Color(0xFFF3F4F6),
      cardBg: p.cardSubBg,
      border: p.border,
      textPrimary: p.textPrimary,
      textSecondary: p.textSecondary,
      textTertiary: p.textTertiary,
      accent: p.accent,
      accentSoft: p.accentSoft,
      accentFg: p.accentSoftFg,
      greenBg: p.dark ? const Color(0xFF173624) : const Color(0xFFD6F5E3),
      greenFg: p.dark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
      greenBorder: p.dark ? const Color(0xFF285E3D) : const Color(0xFFA3E4BF),
      warnBg: p.dark ? const Color(0xFF3A2A12) : const Color(0xFFFEECC8),
      warnFg: p.dark ? const Color(0xFFFFCA62) : const Color(0xFF8A4300),
      hoverBg: p.rowHoverBg,
      monoFont: winMonoFont,
    );
  }
}

class _QuickLookLightbox extends StatefulWidget {
  final AppController app;
  final List<PreviewItem> items;
  final int initialIndex;
  final bool macStyle;
  final bool standaloneWindow;

  const _QuickLookLightbox({
    required this.app,
    required this.items,
    required this.initialIndex,
    required this.macStyle,
    this.standaloneWindow = false,
  });

  @override
  State<_QuickLookLightbox> createState() => _QuickLookLightboxState();
}

class _QuickLookLightboxState extends State<_QuickLookLightbox> {
  late int _index = widget.initialIndex;
  int _loadToken = 0;
  bool _loading = true;
  PreviewData? _data;

  // Image / PDF zoom state
  final _transform = TransformationController();
  double _zoom = 1.0;

  // Text / Markdown / HTML / JSON viewer state
  bool _renderedMode = true;
  bool _wrapLines = true;
  bool _showFind = false;
  final _findController = TextEditingController();
  final _findFocus = FocusNode();
  bool _copied = false;
  bool _busyAction = false;
  String? _statusNotice;

  final _rootFocus = FocusNode();

  PreviewItem get _current => widget.items[_index];

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    _findController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadCurrent();
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _findController.dispose();
    _findFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final s = _transform.value.getMaxScaleOnAxis();
    if ((s - _zoom).abs() > 0.01 && mounted) {
      setState(() => _zoom = s);
    }
  }

  void _resetZoom() {
    _transform.value = Matrix4.identity();
    if (mounted) setState(() => _zoom = 1.0);
  }

  void _stepZoom(double factor) {
    final next = (_zoom * factor).clamp(0.5, 6.0);
    _transform.value = Matrix4.diagonal3Values(next, next, 1.0);
    if (mounted) setState(() => _zoom = next);
  }

  Future<void> _loadCurrent({bool forceDownload = false}) async {
    final token = ++_loadToken;
    final item = _current;
    _resetZoom();
    setState(() {
      _loading = true;
      _data = null;
      _statusNotice = null;
      _copied = false;
      _renderedMode = true;
    });

    final serial = widget.app.selected?.serial;
    if (serial == null) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _data = PreviewData(
          item: item,
          error: 'No device connected.',
        );
      });
      return;
    }

    final result = await widget.app.preview.loadPreview(
      serial,
      item,
      destRoot: widget.app.destination.text,
      forceDownload: forceDownload,
    );
    if (!mounted || token != _loadToken) return;
    setState(() {
      _loading = false;
      _data = result;
    });

    // Speculatively warm the next small sibling image in the background so
    // stepping with the right arrow feels instantaneous.
    if (_index + 1 < widget.items.length) {
      final next = widget.items[_index + 1];
      if (next.kind == PreviewKind.image &&
          next.size > 0 &&
          next.size <= 10 * 1024 * 1024) {
        unawaited(
          widget.app.preview
              .loadPreview(serial, next, destRoot: widget.app.destination.text)
              .catchError((_) => PreviewData(item: next)),
        );
      }
    }
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.items.length) return;
    setState(() => _index = next);
    _loadCurrent();
  }

  Future<void> _openExternally() async {
    final serial = widget.app.selected?.serial;
    if (serial == null || _busyAction) return;
    setState(() {
      _busyAction = true;
      _statusNotice = 'Preparing file…';
    });
    try {
      final file = _data?.localFile ??
          await widget.app.preview.ensureLocalFile(
            serial,
            _current,
            destRoot: widget.app.destination.text,
          );
      await PreviewService.openExternally(file);
      if (mounted) {
        setState(() => _statusNotice = 'Opened in system app');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusNotice = 'Could not open: $e');
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _saveCopy() async {
    final serial = widget.app.selected?.serial;
    if (serial == null || _busyAction) return;
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Copy',
      fileName: _current.name,
    );
    if (savePath == null || !mounted) return;
    setState(() {
      _busyAction = true;
      _statusNotice = 'Saving copy…';
    });
    try {
      final srcFile = _data?.localFile ??
          await widget.app.preview.ensureLocalFile(
            serial,
            _current,
            destRoot: widget.app.destination.text,
          );
      await srcFile.copy(savePath);
      if (mounted) {
        setState(() => _statusNotice = 'Saved copy to $savePath');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusNotice = 'Save failed: $e');
      }
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  void _closeView() {
    if (widget.standaloneWindow) {
      exit(0);
    }
    Navigator.of(context).pop();
  }

  Future<void> _popOutWindow() async {
    final serial = widget.app.selected?.serial;
    if (serial == null || _busyAction) return;
    try {
      final spec = {
        'serial': serial,
        'model': widget.app.selected?.model ?? '',
        'dest': widget.app.destination.text,
        'index': _index,
        'items': [
          for (final it in widget.items)
            {
              'name': it.name,
              'devicePath': it.devicePath,
              'size': it.size,
              'modified': it.modified,
            },
        ],
      };
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'af_preview_${DateTime.now().microsecondsSinceEpoch}.json',
      );
      await file.writeAsString(jsonEncode(spec), flush: true);
      await Process.start(
        Platform.resolvedExecutable,
        ['--preview-spec', file.path],
        mode: ProcessStartMode.detached,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _statusNotice = 'Pop out failed: $e');
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final primaryMod = Platform.isMacOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;

    if (key == LogicalKeyboardKey.escape) {
      if (_showFind) {
        setState(() {
          _showFind = false;
          _findController.clear();
        });
        _rootFocus.requestFocus();
        return KeyEventResult.handled;
      }
      _closeView();
      return KeyEventResult.handled;
    }

    if (primaryMod &&
        key == LogicalKeyboardKey.keyF &&
        PreviewService.isTextLike(_current.kind)) {
      setState(() => _showFind = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _findFocus.requestFocus();
      });
      return KeyEventResult.handled;
    }

    // Do not intercept typing keys while the Find text box is focused.
    if (_findFocus.hasFocus) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.space) {
      _closeView();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _go(1);
      return KeyEventResult.handled;
    }
    if (_data?.imageBytes != null) {
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd) {
        _stepZoom(1.25);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        _stepZoom(0.8);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.digit0 ||
          key == LogicalKeyboardKey.numpad0) {
        _resetZoom();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = _QuickLookTheme.of(context, macStyle: widget.macStyle);
    final item = _current;
    final hasMultiple = widget.items.length > 1;
    final canPrev = _index > 0;
    final canNext = _index < widget.items.length - 1;
    final radius = widget.macStyle ? 12.0 : 10.0;

    final content = DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: 13,
        color: t.textPrimary,
        decoration: TextDecoration.none,
      ),
      child: Container(
        decoration: widget.standaloneWindow
            ? BoxDecoration(color: t.bg)
            : BoxDecoration(
                color: t.bg,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: t.border, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 36,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
        clipBehavior:
            widget.standaloneWindow ? Clip.none : Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Header Bar ---
            _buildHeader(t, item, hasMultiple, canPrev, canNext),
            // --- Main Preview Stage ---
            Expanded(child: _buildStage(t, item)),
            // --- Footer Bar ---
            _buildFooter(t, item, hasMultiple),
          ],
        ),
      ),
    );

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: widget.standaloneWindow
          ? content
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 960,
                    maxHeight: 720,
                    minWidth: 520,
                    minHeight: 380,
                  ),
                  child: content,
                ),
              ),
            ),
    );
  }

  Widget _buildHeader(
    _QuickLookTheme t,
    PreviewItem item,
    bool hasMultiple,
    bool canPrev,
    bool canNext,
  ) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.headerBg,
        border: Border(bottom: BorderSide(color: t.border, width: 1)),
      ),
      child: Row(
        children: [
          Icon(
            iconForPreviewKind(item.kind, mac: t.macStyle),
            size: 16,
            color: t.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Text(
                      fmtBytes(item.size),
                      style: TextStyle(
                        fontSize: 11,
                        color: t.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                    if (item.modified.isNotEmpty) ...[
                      Text(
                        '  ·  ${formatShortModified(item.modified)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: t.textTertiary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ],
                    if (_data != null && !_loading) ...[
                      const SizedBox(width: 8),
                      _PillTag(
                        label: _data!.fromLocalBackup
                            ? 'Local backup'
                            : 'From phone',
                        fg: _data!.fromLocalBackup ? t.greenFg : t.textSecondary,
                        bg: _data!.fromLocalBackup ? t.greenBg : t.hoverBg,
                        border: _data!.fromLocalBackup
                            ? t.greenBorder
                            : t.border,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (hasMultiple) ...[
            const SizedBox(width: 8),
            _HeaderIconBtn(
              icon: t.macStyle
                  ? CupertinoIcons.chevron_left
                  : FluentIcons.chevron_left,
              tooltip: 'Previous file (←)',
              enabled: canPrev,
              theme: t,
              onTap: () => _go(-1),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '${_index + 1} / ${widget.items.length}',
                style: TextStyle(
                  fontSize: 11.5,
                  color: t.textSecondary,
                  fontFeatures: tabularFigures,
                ),
              ),
            ),
            _HeaderIconBtn(
              icon: t.macStyle
                  ? CupertinoIcons.chevron_right
                  : FluentIcons.chevron_right,
              tooltip: 'Next file (→)',
              enabled: canNext,
              theme: t,
              onTap: () => _go(1),
            ),
            const SizedBox(width: 8),
            Container(width: 1, height: 18, color: t.border),
          ],
          const SizedBox(width: 8),
          if (!widget.standaloneWindow &&
              Platform.isWindows &&
              !Platform.environment.containsKey('FLUTTER_TEST')) ...[
            _HeaderIconBtn(
              icon: FluentIcons.mini_expand,
              tooltip: 'Open in separate resizable window',
              enabled: !_busyAction,
              theme: t,
              onTap: _popOutWindow,
            ),
            const SizedBox(width: 6),
          ],
          _ActionButton(
            label: 'Save Copy…',
            icon: t.macStyle
                ? CupertinoIcons.arrow_down_to_line
                : FluentIcons.save,
            theme: t,
            enabled: !_busyAction,
            onTap: _saveCopy,
          ),
          const SizedBox(width: 6),
          _ActionButton(
            label: 'Open',
            icon: t.macStyle
                ? CupertinoIcons.arrow_up_right_square
                : FluentIcons.open_in_new_window,
            theme: t,
            enabled: !_busyAction,
            onTap: _openExternally,
          ),
          if (!widget.standaloneWindow) ...[
            const SizedBox(width: 6),
            _HeaderIconBtn(
              icon: t.macStyle ? CupertinoIcons.xmark : FluentIcons.chrome_close,
              tooltip: 'Close (Esc / Space)',
              enabled: true,
              theme: t,
              onTap: _closeView,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStage(_QuickLookTheme t, PreviewItem item) {
    if (_loading) {
      return Container(
        color: t.stageBg,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 12),
            const SizedBox(height: 12),
            Text(
              'Loading preview…',
              style: TextStyle(fontSize: 12.5, color: t.textSecondary),
            ),
          ],
        ),
      );
    }

    final data = _data;
    if (data == null) return const SizedBox.shrink();

    if (data.needsDownloadConfirm) {
      return _buildLargeDownloadPrompt(t, item);
    }

    if (data.error != null) {
      return _buildMetadataCard(
        t,
        item,
        subtitle: data.error!,
        isWarning: true,
      );
    }

    if (item.kind == PreviewKind.image || item.kind == PreviewKind.heicImage) {
      if (data.imageBytes != null) {
        return _buildImageStage(t, data.imageBytes!);
      }
    }

    if (PreviewService.isTextLike(item.kind) && data.textContent != null) {
      return _buildTextStage(t, item, data);
    }

    if (item.kind == PreviewKind.pdf) {
      return _buildPdfStage(t, item, data);
    }

    if (item.kind == PreviewKind.video) {
      return _buildVideoStage(t, item, data);
    }

    return _buildMetadataCard(
      t,
      item,
      subtitle: item.kind == PreviewKind.audio
          ? 'Audio file — click Open to play in your default music player.'
          : 'No inline preview for this file type. Click Open to view with your system app, or Save Copy… to export it.',
    );
  }

  Widget _buildImageStage(_QuickLookTheme t, Uint8List bytes) {
    return Container(
      color: const Color(0xFF141518),
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 6.0,
              boundaryMargin: const EdgeInsets.all(120),
              child: Center(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Text(
                    'Unable to decode image.',
                    style: TextStyle(color: Color(0xFFCCCCCC)),
                  ),
                ),
              ),
            ),
          ),
          // Floating zoom controls
          Positioned(
            right: 14,
            bottom: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xCC1E2025),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0x33FFFFFF)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DarkZoomBtn(label: '−', onTap: () => _stepZoom(0.8)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${(_zoom * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFEAECEF),
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ),
                  _DarkZoomBtn(label: '+', onTap: () => _stepZoom(1.25)),
                  const SizedBox(width: 4),
                  _DarkZoomBtn(label: 'Fit', onTap: _resetZoom),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextStage(
    _QuickLookTheme t,
    PreviewItem item,
    PreviewData data,
  ) {
    final raw = data.textContent ?? '';
    final canToggleMode = item.kind == PreviewKind.markdown ||
        item.kind == PreviewKind.html ||
        item.kind == PreviewKind.json;
    final renderedLabel = switch (item.kind) {
      PreviewKind.markdown => 'Rendered',
      PreviewKind.html => 'Readable',
      PreviewKind.json => 'Formatted',
      _ => 'Rendered',
    };
    final sourceLabel = item.kind == PreviewKind.json ? 'Raw' : 'Source';

    final displaySource = (item.kind == PreviewKind.json && _renderedMode)
        ? (PreviewService.prettyPrintJson(raw) ?? raw)
        : raw;

    final showRichBlocks = _renderedMode &&
        (item.kind == PreviewKind.markdown || item.kind == PreviewKind.html);

    final query = _showFind ? _findController.text.trim() : '';
    final matchCount = query.isEmpty
        ? 0
        : RegExp(RegExp.escape(query), caseSensitive: false)
            .allMatches(displaySource)
            .length;

    return Container(
      color: t.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Sub-toolbar for text/code/Markdown/HTML/JSON
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: t.cardBg,
              border: Border(bottom: BorderSide(color: t.border, width: 1)),
            ),
            child: Row(
              children: [
                if (canToggleMode) ...[
                  _MiniSegmented(
                    leftLabel: renderedLabel,
                    rightLabel: sourceLabel,
                    leftSelected: _renderedMode,
                    theme: t,
                    onChanged: (v) => setState(() => _renderedMode = v),
                  ),
                  const SizedBox(width: 10),
                ],
                if (!showRichBlocks) ...[
                  _ActionButton(
                    label: _wrapLines ? 'Wrap: On' : 'Wrap: Off',
                    theme: t,
                    enabled: true,
                    onTap: () => setState(() => _wrapLines = !_wrapLines),
                  ),
                  const SizedBox(width: 6),
                ],
                _ActionButton(
                  label: 'Find',
                  icon: t.macStyle
                      ? CupertinoIcons.search
                      : FluentIcons.search,
                  theme: t,
                  enabled: true,
                  onTap: () {
                    setState(() => _showFind = !_showFind);
                    if (_showFind) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _findFocus.requestFocus();
                      });
                    } else {
                      _findController.clear();
                      _rootFocus.requestFocus();
                    }
                  },
                ),
                if (_showFind) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 180,
                    height: 24,
                    child: CupertinoTextField(
                      controller: _findController,
                      focusNode: _findFocus,
                      placeholder: 'Find in file…',
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      style: TextStyle(fontSize: 11.5, color: t.textPrimary),
                      placeholderStyle:
                          TextStyle(fontSize: 11.5, color: t.textTertiary),
                      decoration: BoxDecoration(
                        color: t.bg,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: t.border),
                      ),
                    ),
                  ),
                  if (query.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$matchCount match${matchCount == 1 ? '' : 'es'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: t.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ],
                const Spacer(),
                _ActionButton(
                  label: _copied ? 'Copied' : 'Copy',
                  icon: _copied
                      ? (t.macStyle
                          ? CupertinoIcons.checkmark
                          : FluentIcons.check_mark)
                      : (t.macStyle
                          ? CupertinoIcons.doc_on_doc
                          : FluentIcons.copy),
                  theme: t,
                  enabled: true,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: displaySource));
                    if (!mounted) return;
                    setState(() => _copied = true);
                    Future<void>.delayed(const Duration(milliseconds: 1500), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
                ),
              ],
            ),
          ),
          if (data.truncated)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: t.warnBg,
              child: Text(
                'Showing the first ${fmtBytes(PreviewService.maxTextPreviewBytes)} of ${fmtBytes(item.size)}. Click Open or Save Copy… for the complete file.',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: t.warnFg,
                ),
              ),
            ),
          Expanded(
            child: showRichBlocks
                ? _buildRichReader(
                    t,
                    item.kind == PreviewKind.markdown
                        ? PreviewService.parseMarkdownBlocks(raw)
                        : PreviewService.stripHtmlToBlocks(raw),
                    query: query,
                  )
                : _buildSourceViewer(t, displaySource, query: query),
          ),
        ],
      ),
    );
  }

  Widget _buildRichReader(
    _QuickLookTheme t,
    List<RichBlock> blocks, {
    required String query,
  }) {
    if (blocks.isEmpty) {
      return Center(
        child: Text(
          '(Empty document)',
          style: TextStyle(fontSize: 12.5, color: t.textTertiary),
        ),
      );
    }
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final b in blocks) ...[
              switch (b.type) {
                RichBlockType.h1 => Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Text.rich(
                      _inlineSpan(
                        b.text,
                        TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                          height: 1.3,
                        ),
                        t,
                        query: query,
                      ),
                    ),
                  ),
                RichBlockType.h2 => Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 6),
                    child: Text.rich(
                      _inlineSpan(
                        b.text,
                        TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700,
                          color: t.textPrimary,
                          height: 1.35,
                        ),
                        t,
                        query: query,
                      ),
                    ),
                  ),
                RichBlockType.h3 => Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Text.rich(
                      _inlineSpan(
                        b.text,
                        TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: t.textPrimary,
                          height: 1.4,
                        ),
                        t,
                        query: query,
                      ),
                    ),
                  ),
                RichBlockType.paragraph => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text.rich(
                      _inlineSpan(
                        b.text,
                        TextStyle(
                          fontSize: 13.5,
                          color: t.textPrimary,
                          height: 1.55,
                        ),
                        t,
                        query: query,
                      ),
                    ),
                  ),
                RichBlockType.listItem => Padding(
                    padding: const EdgeInsets.only(left: 10, bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '•  ',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: t.accent,
                            height: 1.5,
                          ),
                        ),
                        Expanded(
                          child: Text.rich(
                            _inlineSpan(
                              b.text,
                              TextStyle(
                                fontSize: 13.5,
                                color: t.textPrimary,
                                height: 1.5,
                              ),
                              t,
                              query: query,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                RichBlockType.quote => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    decoration: BoxDecoration(
                      color: t.cardBg,
                      border: Border(
                        left: BorderSide(color: t.accent, width: 3),
                      ),
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(6),
                      ),
                    ),
                    child: Text.rich(
                      _inlineSpan(
                        b.text,
                        TextStyle(
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                          color: t.textSecondary,
                          height: 1.5,
                        ),
                        t,
                        query: query,
                      ),
                    ),
                  ),
                RichBlockType.code => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: t.cardBg,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: t.border),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        b.text,
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: t.monoFont,
                          color: t.textPrimary,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                RichBlockType.rule => Container(
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    height: 1,
                    color: t.border,
                  ),
              },
            ],
          ],
        ),
      ),
    );
  }

  /// Build inline TextSpan supporting `**bold**`, `*italic*`, `` `code` ``,
  /// and optional case-insensitive search highlighting.
  TextSpan _inlineSpan(
    String text,
    TextStyle base,
    _QuickLookTheme t, {
    required String query,
  }) {
    final tokenRe = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)');
    final spans = <TextSpan>[];
    var pos = 0;

    void pushHighlighted(String chunk, TextStyle style) {
      if (query.isEmpty) {
        spans.add(TextSpan(text: chunk, style: style));
        return;
      }
      final qRe = RegExp(RegExp.escape(query), caseSensitive: false);
      var last = 0;
      for (final m in qRe.allMatches(chunk)) {
        if (m.start > last) {
          spans.add(TextSpan(text: chunk.substring(last, m.start), style: style));
        }
        spans.add(
          TextSpan(
            text: chunk.substring(m.start, m.end),
            style: style.copyWith(
              backgroundColor: const Color(0xFFFFD54F),
              color: const Color(0xFF1A1A1A),
            ),
          ),
        );
        last = m.end;
      }
      if (last < chunk.length) {
        spans.add(TextSpan(text: chunk.substring(last), style: style));
      }
    }

    for (final m in tokenRe.allMatches(text)) {
      if (m.start > pos) {
        pushHighlighted(text.substring(pos, m.start), base);
      }
      final tok = m.group(0)!;
      if (tok.startsWith('**') && tok.endsWith('**')) {
        pushHighlighted(
          tok.substring(2, tok.length - 2),
          base.copyWith(fontWeight: FontWeight.w700),
        );
      } else if (tok.startsWith('`') && tok.endsWith('`')) {
        pushHighlighted(
          tok.substring(1, tok.length - 1),
          base.copyWith(
            fontFamily: t.monoFont,
            fontSize: (base.fontSize ?? 13) - 1,
            backgroundColor: t.cardBg,
          ),
        );
      } else if (tok.startsWith('*') && tok.endsWith('*')) {
        pushHighlighted(
          tok.substring(1, tok.length - 1),
          base.copyWith(fontStyle: FontStyle.italic),
        );
      }
      pos = m.end;
    }
    if (pos < text.length) {
      pushHighlighted(text.substring(pos), base);
    }
    return TextSpan(children: spans, style: base);
  }

  Widget _buildSourceViewer(
    _QuickLookTheme t,
    String source, {
    required String query,
  }) {
    final style = TextStyle(
      fontSize: 12,
      fontFamily: t.monoFont,
      color: t.textPrimary,
      height: 1.5,
    );

    final TextSpan contentSpan;
    if (query.isEmpty) {
      contentSpan = TextSpan(text: source, style: style);
    } else {
      final qRe = RegExp(RegExp.escape(query), caseSensitive: false);
      final spans = <TextSpan>[];
      var last = 0;
      for (final m in qRe.allMatches(source)) {
        if (m.start > last) {
          spans.add(TextSpan(text: source.substring(last, m.start)));
        }
        spans.add(
          TextSpan(
            text: source.substring(m.start, m.end),
            style: const TextStyle(
              backgroundColor: Color(0xFFFFD54F),
              color: Color(0xFF1A1A1A),
            ),
          ),
        );
        last = m.end;
      }
      if (last < source.length) {
        spans.add(TextSpan(text: source.substring(last)));
      }
      contentSpan = TextSpan(children: spans, style: style);
    }

    final textWidget = Padding(
      padding: const EdgeInsets.all(16),
      child: Text.rich(contentSpan),
    );

    if (_wrapLines) {
      return SelectionArea(child: SingleChildScrollView(child: textWidget));
    }
    return SelectionArea(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: textWidget,
        ),
      ),
    );
  }

  Widget _buildPdfStage(
    _QuickLookTheme t,
    PreviewItem item,
    PreviewData data,
  ) {
    final pageLabel = data.pdfPageCount != null
        ? '${data.pdfPageCount} page${data.pdfPageCount == 1 ? '' : 's'}'
        : 'PDF document';

    if (data.imageBytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: t.cardBg,
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: [
                Text(
                  'Page 1 preview  ·  $pageLabel',
                  style: TextStyle(fontSize: 11.5, color: t.textSecondary),
                ),
                const Spacer(),
                _ActionButton(
                  label: Platform.isMacOS
                      ? 'Open Full PDF in Preview'
                      : 'Open in PDF Viewer',
                  theme: t,
                  enabled: !_busyAction,
                  primary: true,
                  onTap: _openExternally,
                ),
              ],
            ),
          ),
          Expanded(child: _buildImageStage(t, data.imageBytes!)),
        ],
      );
    }

    return _buildMetadataCard(
      t,
      item,
      subtitle:
          '$pageLabel — ready to open in your default PDF viewer.',
      primaryActionLabel: 'Open PDF',
      onPrimaryAction: _openExternally,
    );
  }

  Widget _buildVideoStage(
    _QuickLookTheme t,
    PreviewItem item,
    PreviewData data,
  ) {
    if (data.imageBytes != null) {
      return Container(
        color: const Color(0xFF141518),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Image.memory(
                data.imageBytes!,
                fit: BoxFit.contain,
              ),
            ),
            // Centered Play button overlay
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _openExternally,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC141518),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: const Color(0x55FFFFFF),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        t.macStyle
                            ? CupertinoIcons.play_fill
                            : FluentIcons.play_solid,
                        size: 16,
                        color: const Color(0xFFFFFFFF),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        Platform.isMacOS
                            ? 'Play in Default Player'
                            : 'Play Video',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return _buildMetadataCard(
      t,
      item,
      subtitle: 'Video file ready — play it with full hardware decoding & audio in your system player.',
      primaryActionLabel: 'Play in Default Player',
      onPrimaryAction: _openExternally,
    );
  }

  Widget _buildLargeDownloadPrompt(_QuickLookTheme t, PreviewItem item) {
    final kindLabel = switch (item.kind) {
      PreviewKind.video => 'video',
      PreviewKind.pdf => 'PDF',
      _ => 'file',
    };
    return _buildMetadataCard(
      t,
      item,
      subtitle:
          'This $kindLabel is ${fmtBytes(item.size)} and is not in your local backup folder yet. Download it to a temporary preview cache?',
      primaryActionLabel: 'Download & Preview (${fmtBytes(item.size)})',
      onPrimaryAction: () => _loadCurrent(forceDownload: true),
    );
  }

  Widget _buildMetadataCard(
    _QuickLookTheme t,
    PreviewItem item, {
    required String subtitle,
    bool isWarning = false,
    String? primaryActionLabel,
    VoidCallback? onPrimaryAction,
  }) {
    return Container(
      color: t.stageBg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: isWarning ? t.warnBg : t.cardBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  iconForPreviewKind(item.kind, mac: t.macStyle),
                  size: 26,
                  color: isWarning ? t.warnFg : t.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                item.name,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.devicePath,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: t.monoFont,
                  color: t.textTertiary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: t.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (primaryActionLabel != null && onPrimaryAction != null)
                    _ActionButton(
                      label: primaryActionLabel,
                      theme: t,
                      enabled: !_busyAction,
                      primary: true,
                      onTap: onPrimaryAction,
                    )
                  else
                    _ActionButton(
                      label: 'Open with System App',
                      theme: t,
                      enabled: !_busyAction,
                      primary: true,
                      onTap: _openExternally,
                    ),
                  _ActionButton(
                    label: 'Save Copy…',
                    theme: t,
                    enabled: !_busyAction,
                    onTap: _saveCopy,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(
    _QuickLookTheme t,
    PreviewItem item,
    bool hasMultiple,
  ) {
    final canToggle = item.isChecked != null && item.onToggleChecked != null;
    final checked = canToggle ? item.isChecked!() : false;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.headerBg,
        border: Border(top: BorderSide(color: t.border, width: 1)),
      ),
      child: Row(
        children: [
          if (canToggle) ...[
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () {
                  item.onToggleChecked!();
                  setState(() {});
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MacCheckbox(
                      checked: checked,
                      onTap: () {
                        item.onToggleChecked!();
                        setState(() {});
                      },
                    ),
                    const SizedBox(width: 7),
                    Text(
                      item.checkLabel ?? 'Selected',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: t.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            Expanded(
              child: Text(
                item.devicePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: t.monoFont,
                  color: t.textTertiary,
                ),
              ),
            ),
          ],
          if (_statusNotice != null) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _statusNotice!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: t.accentFg),
              ),
            ),
          ] else if (canToggle) ...[
            const Spacer(),
          ],
          const SizedBox(width: 12),
          Text(
            hasMultiple
                ? '← → navigate  ·  Space / Esc close'
                : 'Space / Esc close',
            style: TextStyle(fontSize: 11, color: t.textTertiary),
          ),
        ],
      ),
    );
  }
}

class _PillTag extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final Color border;

  const _PillTag({
    required this.label,
    required this.fg,
    required this.bg,
    required this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border, width: 0.75),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

class _HeaderIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final _QuickLookTheme theme;
  final VoidCallback onTap;

  const _HeaderIconBtn({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_HeaderIconBtn> createState() => _HeaderIconBtnState();
}

class _HeaderIconBtnState extends State<_HeaderIconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.enabled && _hovered
                  ? t.hoverBg
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 13.5,
              color: widget.enabled
                  ? t.textPrimary
                  : t.textTertiary.withValues(alpha: 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final _QuickLookTheme theme;
  final bool enabled;
  final bool primary;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    this.icon,
    required this.theme,
    required this.enabled,
    this.primary = false,
    required this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final bg = widget.primary
        ? t.accent
        : (_hovered && widget.enabled ? t.hoverBg : t.bg);
    final fg = widget.primary ? const Color(0xFFFFFFFF) : t.textPrimary;

    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.45,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: widget.primary ? t.accent : t.border,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 12, color: fg),
                  const SizedBox(width: 5),
                ],
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniSegmented extends StatelessWidget {
  final String leftLabel;
  final String rightLabel;
  final bool leftSelected;
  final _QuickLookTheme theme;
  final ValueChanged<bool> onChanged;

  const _MiniSegmented({
    required this.leftLabel,
    required this.rightLabel,
    required this.leftSelected,
    required this.theme,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = theme;
    Widget tab(String label, bool active, bool value) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => onChanged(value),
            child: Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? t.bg : const Color(0x00000000),
                borderRadius: BorderRadius.circular(5),
                border: active ? Border.all(color: t.border, width: 0.75) : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? t.textPrimary : t.textSecondary,
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.hoverBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tab(leftLabel, leftSelected, true),
          tab(rightLabel, !leftSelected, false),
        ],
      ),
    );
  }
}

class _DarkZoomBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _DarkZoomBtn({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0x22FFFFFF),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFFFFFFFF),
            ),
          ),
        ),
      ),
    );
  }
}
