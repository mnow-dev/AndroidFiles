import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_controller.dart';
import '../../backup_engine.dart' show fmtBytes;
import '../../os.dart';
import 'mac_cleanup_view.dart';
import 'mac_dialogs.dart';
import 'mac_inspector_pane.dart';
import 'mac_sidebar.dart';
import 'mac_theme.dart';
import 'mac_tree_pane.dart';

/// Proposal A root screen for macOS: Native Finder & Inspector 3-zone split
/// with integrated macOS menu bar, unified toolbar, resizable tree/inspector
/// split, and collapsible SF Mono console drawer.
class MacHomeScreen extends StatefulWidget {
  final AppController app;
  const MacHomeScreen({super.key, required this.app});

  @override
  State<MacHomeScreen> createState() => _MacHomeScreenState();
}

class _MacHomeScreenState extends State<MacHomeScreen> {
  AppController get app => widget.app;
  late double _inspectorWidth = 344;
  MacWorkspaceMode _mode = MacWorkspaceMode.backup;
  bool _updatePrompted = false;

  @override
  void initState() {
    super.initState();
    app.addListener(_maybePromptUpdate);
    _maybePromptUpdate();
  }

  @override
  void dispose() {
    app.removeListener(_maybePromptUpdate);
    super.dispose();
  }

  void _maybePromptUpdate() {
    if (_updatePrompted || app.update == null || !mounted) return;
    _updatePrompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && app.update != null) showMacUpdateDialog(context, app);
    });
  }

  Future<void> _browseDestination() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Backup destination',
    );
    if (dir != null) app.setDestination(dir);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final p = MacPalette.of(context);
        final l = AppLocalizations.of(context);
        final canStartBackup = app.checked.isNotEmpty &&
            app.destination.text.trim().isNotEmpty &&
            app.selected != null &&
            unmountedVolume(app.destination.text) == null;

        final body = CupertinoPageScaffold(
          backgroundColor: p.windowBg,
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 13,
              color: p.textPrimary,
              decoration: TextDecoration.none,
            ),
            child: Row(
              children: [
                MacSidebar(
                  app: app,
                  mode: _mode,
                  onModeChanged: (m) => setState(() => _mode = m),
                ),
                Container(width: 1, color: p.border),
                Expanded(
                  child: Column(
                    children: [
                      _MacUnifiedToolbar(app: app, mode: _mode),
                      Expanded(
                        child: _mode == MacWorkspaceMode.cleanup
                            ? MacCleanupView(app: app)
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  final maxInsp = (constraints.maxWidth - 260)
                                      .clamp(290.0, 440.0);
                                  final inspW =
                                      _inspectorWidth.clamp(290.0, maxInsp);
                                  return Row(
                                    children: [
                                      Expanded(child: MacTreePane(app: app)),
                                      _MacVerticalSplitHandle(
                                        onDrag: (dx) => setState(() {
                                          _inspectorWidth =
                                              (inspW - dx).clamp(290.0, maxInsp);
                                        }),
                                      ),
                                      SizedBox(
                                        width: inspW,
                                        child: MacInspectorPane(app: app),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                      if (app.showLog) _MacConsoleDrawer(app: app),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );

        final hasMacMenus = PlatformProvidedMenuItem.hasMenu(
          PlatformProvidedMenuItemType.about,
        );
        if (!hasMacMenus) return body;

        return PlatformMenuBar(
          menus: [
            PlatformMenu(
              label: 'AndroidFiles',
              menus: [
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.about,
                ),
                PlatformMenuItemGroup(
                  members: [
                    PlatformMenuItem(
                      label: '${l.settingsTitle}…',
                      shortcut: const SingleActivator(
                        LogicalKeyboardKey.comma,
                        meta: true,
                      ),
                      onSelected: () => showMacSettingsDialog(context, app),
                    ),
                  ],
                ),
                const PlatformMenuItemGroup(
                  members: [
                    PlatformProvidedMenuItem(
                      type: PlatformProvidedMenuItemType.hide,
                    ),
                    PlatformProvidedMenuItem(
                      type: PlatformProvidedMenuItemType.hideOtherApplications,
                    ),
                    PlatformProvidedMenuItem(
                      type: PlatformProvidedMenuItemType.showAllApplications,
                    ),
                  ],
                ),
                const PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.quit,
                ),
              ],
            ),
            PlatformMenu(
              label: 'File',
              menus: [
                PlatformMenuItem(
                  label: app.checked.isEmpty
                      ? l.selectFoldersToBackUp
                      : l.backUpItems(app.checked.length),
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyB,
                    meta: true,
                  ),
                  onSelected: canStartBackup ? app.startBackup : null,
                ),
                PlatformMenuItem(
                  label: '${l.browseDestination}…',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyO,
                    meta: true,
                  ),
                  onSelected: _browseDestination,
                ),
                PlatformMenuItem(
                  label: '${l.saveProfileTitle}…',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyS,
                    meta: true,
                  ),
                  onSelected: app.checked.isEmpty
                      ? null
                      : () => showMacSaveProfileDialog(context, app),
                ),
                PlatformMenuItemGroup(
                  members: [
                    PlatformMenuItem(
                      label: '${l.wirelessDebugging}…',
                      shortcut: const SingleActivator(
                        LogicalKeyboardKey.keyW,
                        meta: true,
                        shift: true,
                      ),
                      onSelected: () => showMacWifiDialog(context, app),
                    ),
                  ],
                ),
              ],
            ),
            PlatformMenu(
              label: 'View',
              menus: [
                PlatformMenuItemGroup(
                  members: [
                    PlatformMenuItem(
                      label: 'Back Up',
                      shortcut: const SingleActivator(
                        LogicalKeyboardKey.digit1,
                        meta: true,
                      ),
                      onSelected: () =>
                          setState(() => _mode = MacWorkspaceMode.backup),
                    ),
                    PlatformMenuItem(
                      label: 'Clean Up Space',
                      shortcut: const SingleActivator(
                        LogicalKeyboardKey.digit2,
                        meta: true,
                      ),
                      onSelected: () =>
                          setState(() => _mode = MacWorkspaceMode.cleanup),
                    ),
                  ],
                ),
                PlatformMenuItem(
                  label: l.tooltipRefresh,
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyR,
                    meta: true,
                  ),
                  onSelected: app.selected == null ? null : app.refreshTree,
                ),
                PlatformMenuItem(
                  label: app.allSelected ? l.deselectAll : l.selectAll,
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyA,
                    meta: true,
                    shift: true,
                  ),
                  onSelected: app.canSelectAll ? app.toggleAll : null,
                ),
                PlatformMenuItemGroup(
                  members: [
                    PlatformMenuItem(
                      label: app.showLog ? l.tooltipHideLog : l.tooltipShowLog,
                      shortcut: const SingleActivator(
                        LogicalKeyboardKey.keyL,
                        meta: true,
                        alt: true,
                      ),
                      onSelected: () => app.showLog = !app.showLog,
                    ),
                  ],
                ),
                if (PlatformProvidedMenuItem.hasMenu(
                  PlatformProvidedMenuItemType.toggleFullScreen,
                ))
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.toggleFullScreen,
                  ),
              ],
            ),
            PlatformMenu(
              label: 'Window',
              menus: [
                if (PlatformProvidedMenuItem.hasMenu(
                  PlatformProvidedMenuItemType.minimizeWindow,
                ))
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.minimizeWindow,
                  ),
                if (PlatformProvidedMenuItem.hasMenu(
                  PlatformProvidedMenuItemType.zoomWindow,
                ))
                  const PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.zoomWindow,
                  ),
              ],
            ),
          ],
          child: body,
        );
      },
    );
  }
}

class _MacUnifiedToolbar extends StatelessWidget {
  final AppController app;
  final MacWorkspaceMode mode;
  const _MacUnifiedToolbar({required this.app, required this.mode});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    final device = app.selected;
    final deviceTitle = device == null
        ? 'AndroidFiles'
        : (device.model.isNotEmpty ? device.model : device.serial);

    final selCount = mode == MacWorkspaceMode.cleanup
        ? app.cleanup.selectedPaths.length
        : app.checked.length;
    final selBytes = mode == MacWorkspaceMode.cleanup
        ? app.cleanup.selectedBytes
        : app.selectionBytes;
    String? selectionPill;
    if (selCount > 0) {
      if (mode == MacWorkspaceMode.backup && app.measuringSelection) {
        selectionPill = '$selCount selected · ${l.measuringSize}';
      } else if (selBytes != null && selBytes > 0) {
        selectionPill = mode == MacWorkspaceMode.cleanup
            ? '$selCount to clean · ${fmtBytes(selBytes)}'
            : '$selCount selected · ${fmtBytes(selBytes)}';
      } else {
        selectionPill = '$selCount selected';
      }
    }

    return MacWindowDragArea(
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: p.toolbarBg,
          border: Border(bottom: BorderSide(color: p.border, width: 1)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      deviceTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  if (device != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(
                        CupertinoIcons.chevron_right,
                        size: 11,
                        color: p.textTertiary,
                      ),
                    ),
                    Text(
                      mode == MacWorkspaceMode.cleanup
                          ? (app.activeVolume.isExternal
                              ? 'Clean Up Space · ${app.activeVolume.label}'
                              : 'Clean Up Space')
                          : app.activeRootPath,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: mode == MacWorkspaceMode.cleanup
                            ? null
                            : macMonoFont,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                  if (selectionPill != null) ...[
                    const SizedBox(width: 10),
                    MacStatusPill(
                      label: selectionPill,
                      color: p.green,
                      background: p.greenSoft,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            MacToolbarButton(
              icon: CupertinoIcons.refresh,
              tooltip: l.tooltipRefresh,
              onPressed: app.selected == null ? null : app.refreshTree,
            ),
            const SizedBox(width: 2),
            MacToolbarButton(
              icon: CupertinoIcons.wifi,
              label: 'Wireless',
              tooltip: l.tooltipWireless,
              onPressed: () => showMacWifiDialog(context, app),
            ),
            const SizedBox(width: 2),
            MacToolbarButton(
              icon: CupertinoIcons.doc_plaintext,
              tooltip: app.showLog ? l.tooltipHideLog : l.tooltipShowLog,
              active: app.showLog,
              onPressed: () => app.showLog = !app.showLog,
            ),
            const SizedBox(width: 2),
            MacToolbarButton(
              icon: CupertinoIcons.slider_horizontal_3,
              tooltip: '${l.tooltipSettings} (⌘,)',
              onPressed: () => showMacSettingsDialog(context, app),
            ),
          ],
        ),
      ),
    );
  }
}

class _MacVerticalSplitHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;
  const _MacVerticalSplitHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        child: SizedBox(
          width: 7,
          child: Center(child: Container(width: 1, color: p.border)),
        ),
      ),
    );
  }
}

class _MacConsoleDrawer extends StatelessWidget {
  final AppController app;
  const _MacConsoleDrawer({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Container(
      height: 112,
      width: double.infinity,
      decoration: BoxDecoration(
        color: p.logBg,
        border: Border(top: BorderSide(color: p.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: ListView.builder(
        reverse: true,
        itemCount: app.logLines.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            app.logLines[app.logLines.length - 1 - i],
            style: TextStyle(
              fontFamily: macMonoFont,
              fontSize: 11,
              color: p.textSecondary,
              fontFeatures: tabularFigures,
            ),
          ),
        ),
      ),
    );
  }
}
