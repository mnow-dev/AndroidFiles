import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../models.dart';
import '../preview_service.dart';
import '../tree_filter.dart';
import 'dialogs.dart';
import 'quick_look_dialog.dart';
import 'win_theme.dart';

/// Left Bento Card: Lazy-loading device folder table with `Last Modified` and
/// `Backup Status` columns (Proposal B), Select All header, and Windows
/// Explorer drag-and-drop restore target.
class TreePanel extends StatefulWidget {
  final AppController app;

  const TreePanel({super.key, required this.app});

  @override
  State<TreePanel> createState() => _TreePanelState();
}

class _TreePanelState extends State<TreePanel> {
  AppController get app => widget.app;
  bool _dragging = false;
  bool _onlyUnbackedUp = false;
  final _scroll = ScrollController();
  final _treeFocus = FocusNode();
  final _searchController = TextEditingController();
  String? _focusedFilePath;

  TreeFilter get _filter => TreeFilter(
        query: _searchController.text,
        onlyUnbackedUp: _onlyUnbackedUp,
      );

  @override
  void dispose() {
    _scroll.dispose();
    _treeFocus.dispose();
    _searchController.dispose();
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
      macStyle: false,
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
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);

    if (app.adbMissing || app.adbDownloadProgress != null) {
      return WinBentoCard(child: _AdbBootstrapPane(app: app));
    }
    if (app.selected == null) {
      return WinBentoCard(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.cell_phone, size: 32, color: p.textTertiary),
                const SizedBox(height: 12),
                Text(
                  l.connectPhonePrompt,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: p.textSecondary),
                ),
                const SizedBox(height: 14),
                Button(
                  onPressed: () => showWifiDialog(context, app),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(FluentIcons.wifi, size: 13),
                      const SizedBox(width: 6),
                      Text(l.wirelessDebugging),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final root = app.activeRootPath;
    final filter = _filter;
    final rows = <Widget>[];
    _buildRows(context, root, 0, rows, filter: filter);
    final rootItems = app.children[root]?.length ?? 0;
    final isLoadingRoot = app.loading.contains(root);

    return Focus(
      focusNode: _treeFocus,
      onKeyEvent: _handleKey,
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          setState(() => _dragging = false);
          final paths = [for (final f in detail.files) f.path];
          if (paths.isNotEmpty) showRestoreDialog(context, app, paths);
        },
        child: WinBentoCard(
        child: Container(
          color: _dragging ? p.accentSoft : p.cardBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Card header: Device Folders /sdcard | Select all
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      app.hasExternalStorage
                          ? app.activeVolume.label
                          : 'Device Folders',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        root,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: winMonoFont,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                    if (app.canSelectAll)
                      Tooltip(
                        message: app.allSelected
                            ? l.deselectAllTooltip
                            : l.selectAllTooltip,
                        child: HyperlinkButton(
                          onPressed: app.toggleAll,
                          child: Text(
                            app.allSelected ? l.deselectAll : l.selectAll,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: p.accentSoftFg,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Search & status filter strip
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.cardBg,
                  border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 28,
                        child: TextBox(
                          controller: _searchController,
                          onChanged: (_) => setState(() {}),
                          placeholder: 'Filter files or folders…',
                          style: const TextStyle(fontSize: 12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          prefix: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Icon(
                              FluentIcons.search,
                              size: 12,
                              color: p.textTertiary,
                            ),
                          ),
                          suffix: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: Icon(
                                    FluentIcons.chrome_close,
                                    size: 10,
                                    color: p.textTertiary,
                                  ),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          'Show only items not yet backed up, modified, or partial',
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => setState(
                            () => _onlyUnbackedUp = !_onlyUnbackedUp,
                          ),
                          child: Container(
                            height: 26,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: _onlyUnbackedUp
                                  ? p.accentSoft
                                  : p.cardSubBg,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: _onlyUnbackedUp
                                    ? p.accent.withValues(alpha: 0.55)
                                    : p.border,
                                width: 1,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Not backed up',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: _onlyUnbackedUp
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: _onlyUnbackedUp
                                    ? p.accentSoftFg
                                    : p.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Column header row (Proposal B): Folder / Name | Last Modified | Backup Status
              Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: p.cardSubBg,
                  border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Folder / Name',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 96,
                      child: Text(
                        'Last Modified',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 118,
                      child: Text(
                        'Backup Status',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: filter.isActive && rows.isEmpty && !isLoadingRoot
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              FluentIcons.search,
                              size: 22,
                              color: p.textTertiary,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'No matching files or folders',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: p.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Button(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _onlyUnbackedUp = false);
                              },
                              child: const Text('Clear filter'),
                            ),
                          ],
                        ),
                      )
                    : RawScrollbar(
                        controller: _scroll,
                        thumbVisibility: true,
                        interactive: true,
                        thickness: 7,
                        minThumbLength: 48,
                        radius: const Radius.circular(4),
                        thumbColor: p.textTertiary.withValues(alpha: 0.35),
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: ListView(
                            controller: _scroll,
                            padding: const EdgeInsets.only(bottom: 4),
                            children: rows,
                          ),
                        ),
                      ),
              ),
              // Bottom drop-zone & item count strip
              Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: p.cardSubBg,
                  border: Border(
                    top: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dragging
                            ? 'Release to push files to phone…'
                            : 'Drop files from Windows Explorer here to push to phone',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              _dragging ? FontWeight.w600 : FontWeight.w400,
                          color: _dragging ? p.accentSoftFg : p.textTertiary,
                        ),
                      ),
                    ),
                    if (filter.isActive) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${rows.length} matching',
                        style: TextStyle(
                          fontSize: 11,
                          color: p.accentSoftFg,
                          fontFeatures: winTabularFigures,
                        ),
                      ),
                    ] else if (rootItems > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '$rootItems items',
                        style: TextStyle(
                          fontSize: 11,
                          color: p.textTertiary,
                          fontFeatures: winTabularFigures,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _buildRows(
    BuildContext context,
    String path,
    int depth,
    List<Widget> out, {
    required TreeFilter filter,
    bool ancestorMatchedQuery = false,
  }) {
    if (!app.expanded.contains(path)) return;
    if (app.loading.contains(path)) {
      out.add(Padding(
        padding: EdgeInsets.only(left: 24.0 * (depth + 1), top: 8, bottom: 8),
        child: Row(children: [
          const SizedBox(
              width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(AppLocalizations.of(context).loadingEllipsis),
        ]),
      ));
      return;
    }
    for (final e in app.children[path] ?? const <RemoteEntry>[]) {
      if (!filter.matches(
        e,
        statuses: app.entryBackupStatus,
        children: app.children,
        ancestorMatchedQuery: ancestorMatchedQuery,
      )) {
        continue;
      }
      out.add(_EntryRow(
        app: app,
        entry: e,
        depth: depth,
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
          filter: filter,
          ancestorMatchedQuery:
              ancestorMatchedQuery || filter.nameMatchesQuery(e),
        );
      }
    }
  }
}

class _AdbBootstrapPane extends StatelessWidget {
  final AppController app;
  const _AdbBootstrapPane({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = app.adbDownloadProgress;
    return Center(
      child: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (app.adbBootstrapError != null) ...[
            Text(l.adbDownloadFailed),
            const SizedBox(height: 6),
            Text(app.adbBootstrapError!,
                style: FluentTheme.of(context).typography.caption,
                textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton(onPressed: app.downloadAdb, child: Text(l.retry)),
          ] else if (p != null) ...[
            Text(l.adbDownloading((p * 100).round())),
            const SizedBox(height: 8),
            ProgressBar(value: p * 100),
          ] else ...[
            Text(l.adbSettingUp),
            const SizedBox(height: 8),
            const ProgressBar(),
          ],
        ]),
      ),
    );
  }
}

class _EntryRow extends StatefulWidget {
  final AppController app;
  final RemoteEntry entry;
  final int depth;
  final bool focused;
  final VoidCallback? onFocusFile;
  final VoidCallback? onQuickLook;

  const _EntryRow({
    required this.app,
    required this.entry,
    required this.depth,
    this.focused = false,
    this.onFocusFile,
    this.onQuickLook,
  });

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final app = widget.app;
    final entry = widget.entry;
    final open = app.expanded.contains(entry.path);
    final knownEmpty = entry.isDir && app.isKnownEmpty(entry.path);
    final selected = app.isSelected(entry.path);
    final canExpand = entry.isDir && !knownEmpty;
    final status = knownEmpty
        ? EntryBackupStatus.unknown
        : (app.entryBackupStatus[entry.path] ?? EntryBackupStatus.unknown);

    final rowBg = selected || widget.focused
        ? p.rowSelectedBg
        : (_hovered ? p.rowHoverBg : const Color(0x00000000));

    return MouseRegion(
      cursor: (canExpand || !entry.isDir)
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: canExpand
            ? () => open ? app.collapse(entry.path) : app.expand(entry.path)
            : widget.onFocusFile,
        onDoubleTap: widget.onQuickLook,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: rowBg,
            border: Border(
              bottom: BorderSide(
                color: widget.focused ? p.accent : p.borderSoft,
                width: widget.focused ? 1.25 : 0.75,
              ),
            ),
          ),
          child: Row(
            children: [
              // Folder / Name cell
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 18.0 * widget.depth),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        child: canExpand
                            ? Icon(
                                open
                                    ? FluentIcons.chevron_down
                                    : FluentIcons.chevron_right,
                                size: 11,
                                color: p.textTertiary,
                              )
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Checkbox(
                        checked: selected,
                        onChanged: (_) => app.toggleChecked(entry),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        entry.isDir
                            ? (entry.isLink
                                ? FluentIcons.folder_open
                                : FluentIcons.folder_fill)
                            : iconForPreviewKind(
                                PreviewService.classifyKind(entry.name),
                                mac: false,
                              ),
                        size: 15,
                        color: entry.isDir
                            ? (knownEmpty
                                ? p.textTertiary.withValues(alpha: 0.45)
                                : const Color(0xFFF2B824))
                            : p.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: app.checked.contains(entry.path)
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: knownEmpty ? p.textTertiary : p.textPrimary,
                          ),
                        ),
                      ),
                      if (!entry.isDir &&
                          widget.onQuickLook != null &&
                          (_hovered || widget.focused)) ...[
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
                                FluentIcons.view,
                                size: 13.5,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (!entry.isDir) ...[
                        const SizedBox(width: 6),
                        Text(
                          fmtBytes(entry.size),
                          style: TextStyle(
                            fontSize: 11,
                            color: p.textTertiary,
                            fontFeatures: winTabularFigures,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Last Modified cell
              SizedBox(
                width: 96,
                child: Text(
                  knownEmpty
                      ? 'Empty'
                      : formatShortModified(entry.modified),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: knownEmpty ? p.textTertiary : p.textSecondary,
                    fontFeatures: winTabularFigures,
                  ),
                ),
              ),
              // Backup Status cell
              SizedBox(
                width: 118,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: buildBackupStatusBadge(context, status),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
