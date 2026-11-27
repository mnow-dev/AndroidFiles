import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_controller.dart';
import '../../backup_engine.dart' show fmtBytes;
import '../../models.dart';
import '../../preview_service.dart';
import '../quick_look_dialog.dart';
import '../win_theme.dart' show formatShortModified;
import 'mac_dialogs.dart';
import 'mac_theme.dart';

/// Proposal A center pane: macOS Outline View of `/sdcard` with checkboxes,
/// aqua-blue folder icons, Select All header, Finder drop target for restore,
/// and subtle footer strip.
class MacTreePane extends StatefulWidget {
  final AppController app;
  const MacTreePane({super.key, required this.app});

  @override
  State<MacTreePane> createState() => _MacTreePaneState();
}

class _MacTreePaneState extends State<MacTreePane> {
  AppController get app => widget.app;
  final _scroll = ScrollController();
  final _treeFocus = FocusNode();
  bool _dragging = false;
  String? _focusedFilePath;

  @override
  void dispose() {
    _scroll.dispose();
    _treeFocus.dispose();
    super.dispose();
  }

  void _openQuickLook(RemoteEntry target, String parentPath) {
    final siblings = (app.children[parentPath] ?? const <RemoteEntry>[])
        .where((e) => !e.isDir)
        .toList();
    if (siblings.isEmpty) return;
    final idx = siblings.indexWhere((e) => e.path == target.path);
    final items = [
      for (final e in siblings)
        PreviewItem(
          name: e.name,
          devicePath: e.path,
          size: e.size,
          modified: e.modified,
          backupStatus:
              app.entryBackupStatus[e.path] ?? EntryBackupStatus.unknown,
          isChecked: () => app.isSelected(e.path),
          onToggleChecked: () => app.toggleChecked(e),
          checkLabel: 'Include in backup',
        ),
    ];
    showQuickLookDialog(
      context,
      app: app,
      items: items,
      initialIndex: idx < 0 ? 0 : idx,
      macStyle: true,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.space &&
        _focusedFilePath != null) {
      final targetPath = _focusedFilePath!;
      for (final kv in app.children.entries) {
        for (final e in kv.value) {
          if (!e.isDir && e.path == targetPath) {
            _openQuickLook(e, kv.key);
            return KeyEventResult.handled;
          }
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);

    if (app.adbMissing || app.adbDownloadProgress != null) {
      return _AdbBootstrapView(app: app);
    }

    if (app.selected == null) {
      return _DisconnectedView(
        onPairWireless: () => showMacWifiDialog(context, app),
      );
    }

    final rootItems = app.children[app.activeRootPath]?.length ?? 0;

    return Focus(
      focusNode: _treeFocus,
      onKeyEvent: _handleKey,
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          setState(() => _dragging = false);
          final paths = [for (final f in detail.files) f.path];
          if (paths.isNotEmpty) showMacRestoreDialog(context, app, paths);
        },
        child: LayoutBuilder(
        builder: (context, constraints) {
          final showModified = constraints.maxWidth >= 430;
          final showStatus = constraints.maxWidth >= 340;
          final rows = <Widget>[];
          _buildRows(
            context,
            app.activeRootPath,
            0,
            rows,
            showModified: showModified,
            showStatus: showStatus,
          );
          return Container(
            color: _dragging ? p.greenSoft : p.windowBg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Subheader bar: Device Folders (or active volume) | Select All
                Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: p.border, width: 1)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        app.hasExternalStorage
                            ? app.activeVolume.label
                            : 'Device Folders',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: p.textSecondary,
                        ),
                      ),
                      const Spacer(),
                      if (app.canSelectAll)
                        Tooltip(
                          message: app.allSelected
                              ? l.deselectAllTooltip
                              : l.selectAllTooltip,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: app.toggleAll,
                              child: Text(
                                app.allSelected ? l.deselectAll : l.selectAll,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: p.green,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Column header row: Name | Last Modified | Backup Status
                if (showStatus)
                  Container(
                    height: 26,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: p.toolbarBg,
                      border: Border(
                        bottom: BorderSide(color: p.border, width: 0.75),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Name',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                        if (showModified)
                          SizedBox(
                            width: 86,
                            child: Text(
                              'Modified',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: p.textTertiary,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: 96,
                          child: Text(
                            'Backup',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: CupertinoScrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(6),
                      children: rows,
                    ),
                  ),
                ),
                // Bottom drop-zone & item count strip
                Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: p.toolbarBg,
                    border:
                        Border(top: BorderSide(color: p.border, width: 1)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _dragging
                              ? 'Release to push files to phone…'
                              : 'Drop files from Finder here to push to phone',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: _dragging
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _dragging ? p.green : p.textTertiary,
                          ),
                        ),
                      ),
                      if (rootItems > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '$rootItems items',
                          style: TextStyle(
                            fontSize: 11,
                            color: p.textTertiary,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }

  void _buildRows(
    BuildContext context,
    String path,
    int depth,
    List<Widget> out, {
    required bool showModified,
    required bool showStatus,
  }) {
    if (!app.expanded.contains(path)) return;
    if (app.loading.contains(path)) {
      final p = MacPalette.of(context);
      out.add(
        Padding(
          padding: EdgeInsets.only(
            left: 14.0 + depth * 20.0,
            top: 8,
            bottom: 8,
          ),
          child: Row(
            children: [
              const CupertinoActivityIndicator(radius: 7),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context).loadingEllipsis,
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
            ],
          ),
        ),
      );
      return;
    }
    for (final e in app.children[path] ?? const <RemoteEntry>[]) {
      out.add(_MacTreeRow(
        app: app,
        entry: e,
        depth: depth,
        showModified: showModified,
        showStatus: showStatus,
        focused: !e.isDir && _focusedFilePath == e.path,
        onFocusFile: !e.isDir
            ? () {
                setState(() => _focusedFilePath = e.path);
                _treeFocus.requestFocus();
              }
            : null,
        onQuickLook: !e.isDir ? () => _openQuickLook(e, path) : null,
      ));
      if (e.isDir) {
        _buildRows(
          context,
          e.path,
          depth + 1,
          out,
          showModified: showModified,
          showStatus: showStatus,
        );
      }
    }
  }
}

class _MacTreeRow extends StatefulWidget {
  final AppController app;
  final RemoteEntry entry;
  final int depth;
  final bool showModified;
  final bool showStatus;
  final bool focused;
  final VoidCallback? onFocusFile;
  final VoidCallback? onQuickLook;

  const _MacTreeRow({
    required this.app,
    required this.entry,
    required this.depth,
    required this.showModified,
    required this.showStatus,
    this.focused = false,
    this.onFocusFile,
    this.onQuickLook,
  });

  @override
  State<_MacTreeRow> createState() => _MacTreeRowState();
}

class _MacTreeRowState extends State<_MacTreeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final e = widget.entry;
    final open = widget.app.expanded.contains(e.path);
    final knownEmpty = e.isDir && widget.app.isKnownEmpty(e.path);
    final selected = widget.app.isSelected(e.path);
    final explicitlyChecked = widget.app.checked.contains(e.path);
    final canExpand = e.isDir && !knownEmpty;
    final status = knownEmpty
        ? EntryBackupStatus.unknown
        : (widget.app.entryBackupStatus[e.path] ?? EntryBackupStatus.unknown);

    final rowBg = explicitlyChecked || widget.focused
        ? p.surfaceSelected
        : (_hovered ? p.surfaceHover : const Color(0x00000000));

    return MouseRegion(
      cursor: (canExpand || !e.isDir)
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: canExpand
            ? () =>
                open ? widget.app.collapse(e.path) : widget.app.expand(e.path)
            : widget.onFocusFile,
        onDoubleTap: widget.onQuickLook,
        child: Container(
          height: 29,
          margin: const EdgeInsets.only(bottom: 1),
          padding: EdgeInsets.only(
            left: 8.0 + widget.depth * 20.0,
            right: 8,
          ),
          decoration: BoxDecoration(
            color: rowBg,
            borderRadius: BorderRadius.circular(6),
            border: widget.focused
                ? Border.all(
                    color: p.green.withValues(alpha: 0.55),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: canExpand
                    ? Icon(
                        open
                            ? CupertinoIcons.chevron_down
                            : CupertinoIcons.chevron_right,
                        size: 11,
                        color: p.textTertiary,
                      )
                    : null,
              ),
              const SizedBox(width: 5),
              MacCheckbox(
                checked: selected,
                onTap: () => widget.app.toggleChecked(e),
              ),
              const SizedBox(width: 8),
              if (e.isDir)
                MacFolderIcon(dimmed: knownEmpty)
              else
                SizedBox(
                  width: 16,
                  child: Icon(
                    iconForPreviewKind(
                      PreviewService.classifyKind(e.name),
                      mac: true,
                    ),
                    size: 14,
                    color: p.textSecondary,
                  ),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: knownEmpty ? p.textTertiary : p.textPrimary,
                  ),
                ),
              ),
              if (!e.isDir && widget.onQuickLook != null && (_hovered || widget.focused)) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Quick Look (Space)',
                  child: GestureDetector(
                    onTap: widget.onQuickLook,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Icon(
                        CupertinoIcons.eye,
                        size: 13.5,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
              if (!e.isDir) ...[
                const SizedBox(width: 8),
                Text(
                  fmtBytes(e.size),
                  style: TextStyle(
                    fontSize: 11,
                    color: p.textTertiary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
              if (widget.showModified) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 86,
                  child: Text(
                    knownEmpty ? 'Empty' : formatShortModified(e.modified),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: knownEmpty ? p.textTertiary : p.textSecondary,
                      fontFeatures: tabularFigures,
                    ),
                  ),
                ),
              ],
              if (widget.showStatus)
                SizedBox(
                  width: 96,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _MacBackupStatusPill(status: status),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MacBackupStatusPill extends StatelessWidget {
  final EntryBackupStatus status;
  const _MacBackupStatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final dark = p.isDark;
    return switch (status) {
      EntryBackupStatus.backedUp => MacStatusPill(
          label: 'Backed up',
          color: dark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
          background: dark ? const Color(0xFF173624) : const Color(0xFFD6F5E3),
          borderColor: dark ? const Color(0xFF285E3D) : const Color(0xFFA3E4BF),
        ),
      EntryBackupStatus.modified => MacStatusPill(
          label: 'Modified',
          color: dark ? const Color(0xFFFFCA62) : const Color(0xFF8A4300),
          background: dark ? const Color(0xFF3A2A12) : const Color(0xFFFEECC8),
          borderColor: dark ? const Color(0xFF6B4D1E) : const Color(0xFFF6CE83),
        ),
      EntryBackupStatus.partial => MacStatusPill(
          label: 'Partial',
          color: dark ? const Color(0xFF99D1FF) : const Color(0xFF0D478A),
          background: dark ? const Color(0xFF1B334D) : const Color(0xFFD8EAFC),
          borderColor: dark ? const Color(0xFF2F567D) : const Color(0xFFA6CDF5),
        ),
      EntryBackupStatus.notBackedUp => MacStatusPill(
          label: 'Not backed up',
          color: dark ? const Color(0xFFC2C8D1) : const Color(0xFF3F4854),
          background: dark ? const Color(0xFF2E323A) : const Color(0xFFE8ECF1),
          borderColor: dark ? const Color(0xFF424854) : const Color(0xFFD0D7E0),
        ),
      EntryBackupStatus.checking => const Padding(
          padding: EdgeInsets.only(left: 4),
          child: CupertinoActivityIndicator(radius: 5.5),
        ),
      EntryBackupStatus.unknown => Text(
          '—',
          style: TextStyle(fontSize: 11, color: p.textTertiary),
        ),
    };
  }
}

class _DisconnectedView extends StatelessWidget {
  final VoidCallback onPairWireless;
  const _DisconnectedView({required this.onPairWireless});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    return Container(
      color: p.windowBg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: p.segTrack,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                CupertinoIcons.device_phone_portrait,
                size: 24,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l.connectPhonePrompt,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: p.textPrimary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
            MacPushButton(
              onPressed: onPairWireless,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.wifi, size: 13),
                  const SizedBox(width: 6),
                  Text(l.wirelessDebugging),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdbBootstrapView extends StatelessWidget {
  final AppController app;
  const _AdbBootstrapView({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    final progress = app.adbDownloadProgress;

    return Container(
      color: p.windowBg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (app.adbBootstrapError != null) ...[
              Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 26,
                color: p.amber,
              ),
              const SizedBox(height: 10),
              Text(
                l.adbDownloadFailed,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                app.adbBootstrapError!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: p.textSecondary),
              ),
              const SizedBox(height: 14),
              MacPrimaryButton(
                expand: false,
                height: 30,
                onPressed: app.downloadAdb,
                child: Text(l.retry),
              ),
            ] else if (progress != null) ...[
              Text(
                l.adbDownloading((progress * 100).round()),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: p.textPrimary,
                  fontFeatures: tabularFigures,
                ),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 6,
                  child: Stack(
                    children: [
                      Container(color: p.segTrack),
                      FractionallySizedBox(
                        widthFactor: progress.clamp(0.0, 1.0),
                        child: Container(color: p.green),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              const CupertinoActivityIndicator(radius: 10),
              const SizedBox(height: 10),
              Text(
                l.adbSettingUp,
                style: TextStyle(fontSize: 13, color: p.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
