import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../drive_manager.dart';
import '../models.dart';
import '../settings.dart';
import 'dialogs.dart';
import 'queue_panel.dart';
import 'tree_panel.dart';
import 'win_cleanup_view.dart';
import 'win_theme.dart';

enum WinWorkspaceMode { backup, cleanup }

/// Windows 11 Hybrid Fluent workspace:
///   • Left Mica navigation pane (Workspace, Device, Profiles, Explorer Drive)
///   • Context top bar (Storage switcher, selection pill, Wireless, Refresh,
///     Log, Settings) — keeps the native Win32 window titlebar untouched
///   • Three Bento cards (Device Folders with Last Modified & Backup Status,
///     Backup Destination, Transfer Queue) — or the Clean Up Space studio
class HomeScreen extends StatefulWidget {
  final AppController app;

  const HomeScreen({super.key, required this.app});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get app => widget.app;
  late double _split = app.settings.splitRatio;
  WinWorkspaceMode _mode = WinWorkspaceMode.backup;
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
      if (mounted && app.update != null) showUpdateDialog(context, app);
    });
  }

  Future<void> _saveProfileDialog(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final name = TextEditingController(text: app.activeProfile?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: Text(l.saveProfileTitle),
        content: TextBox(
          controller: name,
          autofocus: true,
          placeholder: l.profileNamePlaceholder,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: Text(l.save),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      app.saveProfile(result.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final p = WinPalette.of(context);
        return Container(
          color: p.micaBg,
          child: Row(
            children: [
              _WinSidebar(
                app: app,
                mode: _mode,
                onModeChanged: (m) => setState(() => _mode = m),
                onSaveProfile: () => _saveProfileDialog(context),
              ),
              Container(width: 1, color: p.borderSoft),
              Expanded(
                child: Column(
                  children: [
                    _WinContextTopBar(app: app, mode: _mode),
                    Expanded(
                      child: _mode == WinWorkspaceMode.cleanup
                          ? WinCleanupView(app: app)
                          : Padding(
                              padding: const EdgeInsets.all(14),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final total = constraints.maxWidth;
                                  final minLeft = 320.0.clamp(0.0, total * 0.6);
                                  final maxLeft =
                                      (total - 330).clamp(minLeft, total);
                                  final leftWidth = (total * _split.clamp(0.45, 0.72))
                                      .clamp(minLeft, maxLeft);
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      SizedBox(
                                        width: leftWidth,
                                        child: TreePanel(app: app),
                                      ),
                                      _SplitHandle(
                                        onDrag: (dx) => setState(
                                          () => _split = ((leftWidth + dx) / total)
                                              .clamp(0.35, 0.75),
                                        ),
                                        onDragEnd: () {
                                          app.settings.splitRatio = _split;
                                          app.settings.save();
                                        },
                                      ),
                                      Expanded(child: QueuePanel(app: app)),
                                    ],
                                  );
                                },
                              ),
                            ),
                    ),
                    if (app.showLog) _LogPane(app: app),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Left Windows 11 Mica navigation pane (Proposal A layout).
class _WinSidebar extends StatelessWidget {
  final AppController app;
  final WinWorkspaceMode mode;
  final ValueChanged<WinWorkspaceMode> onModeChanged;
  final VoidCallback onSaveProfile;

  const _WinSidebar({
    required this.app,
    required this.mode,
    required this.onModeChanged,
    required this.onSaveProfile,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    final cleanupBusy = app.cleanup.scanning ||
        app.cleanup.scanningDuplicates ||
        app.cleanup.executing;

    return Container(
      width: 224,
      color: p.micaBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 0, 6, 6),
                  child: WinSectionLabel('Workspace'),
                ),
                _SidebarNavTile(
                  icon: FluentIcons.download,
                  label: 'Back Up',
                  selected: mode == WinWorkspaceMode.backup,
                  busy: app.engine.isRunning,
                  onTap: () => onModeChanged(WinWorkspaceMode.backup),
                ),
                _SidebarNavTile(
                  icon: FluentIcons.broom,
                  label: 'Clean Up Space',
                  selected: mode == WinWorkspaceMode.cleanup,
                  busy: cleanupBusy,
                  badge: app.cleanup.selectedPaths.isNotEmpty
                      ? '${app.cleanup.selectedPaths.length}'
                      : null,
                  onTap: () => onModeChanged(WinWorkspaceMode.cleanup),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 6, 6),
                  child: WinSectionLabel(l.deviceLabel),
                ),
                if (app.devices.isEmpty)
                  _EmptyDeviceCard(
                    onTap: () => showWifiDialog(context, app),
                  )
                else
                  for (final d in app.devices)
                    _SidebarDeviceTile(
                      device: d,
                      selected: app.selected?.serial == d.serial,
                      parallelStreams: app.settings.parallelStreams,
                      onTap: d.isReady ? () => app.selectDevice(d) : null,
                    ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 4, 6),
                  child: WinSectionLabel(
                    l.sectionProfile,
                    trailing: Tooltip(
                      message: l.saveProfileTooltip,
                      child: IconButton(
                        icon: Icon(
                          FluentIcons.add,
                          size: 13,
                          color: app.checked.isNotEmpty
                              ? p.accent
                              : p.textTertiary.withValues(alpha: 0.45),
                        ),
                        onPressed:
                            app.checked.isEmpty ? null : onSaveProfile,
                      ),
                    ),
                  ),
                ),
                if (app.settings.profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      l.profilesPlaceholder,
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                    ),
                  )
                else
                  for (final profile in app.settings.profiles)
                    _SidebarProfileTile(
                      profile: profile,
                      active: app.activeProfile == profile,
                      onSelect: () {
                        app.applyProfile(profile);
                        onModeChanged(WinWorkspaceMode.backup);
                      },
                      onSchedule: () {
                        app.applyProfile(profile);
                        showScheduleDialog(context, app);
                      },
                      onDelete: () => app.deleteProfile(profile),
                    ),
              ],
            ),
          ),
          if (DriveManager.supported)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              child: _ExplorerDriveCard(app: app),
            ),
        ],
      ),
    );
  }
}

class _SidebarNavTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool busy;
  final String? badge;
  final VoidCallback onTap;

  const _SidebarNavTile({
    required this.icon,
    required this.label,
    required this.selected,
    this.busy = false,
    this.badge,
    required this.onTap,
  });

  @override
  State<_SidebarNavTile> createState() => _SidebarNavTileState();
}

class _SidebarNavTileState extends State<_SidebarNavTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.navActiveBg
                : (_hovered ? p.navHoverBg : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
            border: widget.selected
                ? Border.all(color: p.borderSoft, width: 1)
                : null,
          ),
          child: Row(
            children: [
              // Windows 11 Fluent left accent pill
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 3,
                height: widget.selected ? 16 : 0,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Icon(
                widget.icon,
                size: 14,
                color: widget.selected ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
              ),
              if (widget.busy) ...[
                const SizedBox(width: 6),
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: ProgressRing(strokeWidth: 2),
                ),
              ],
              if (widget.badge != null) ...[
                const SizedBox(width: 6),
                WinPill(
                  label: widget.badge!,
                  color: p.accentSoftFg,
                  background: p.accentSoft,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDeviceCard extends StatefulWidget {
  final VoidCallback onTap;
  const _EmptyDeviceCard({required this.onTap});

  @override
  State<_EmptyDeviceCard> createState() => _EmptyDeviceCardState();
}

class _EmptyDeviceCardState extends State<_EmptyDeviceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? p.navHoverBg : const Color(0x00000000),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                FluentIcons.plug_disconnected,
                size: 15,
                color: p.textTertiary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.noDevice,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: p.textSecondary,
                      ),
                    ),
                    Text(
                      'USB or pair via Wi-Fi…',
                      style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarDeviceTile extends StatefulWidget {
  final AdbDevice device;
  final bool selected;
  final int parallelStreams;
  final VoidCallback? onTap;

  const _SidebarDeviceTile({
    required this.device,
    required this.selected,
    required this.parallelStreams,
    required this.onTap,
  });

  @override
  State<_SidebarDeviceTile> createState() => _SidebarDeviceTileState();
}

class _SidebarDeviceTileState extends State<_SidebarDeviceTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final d = widget.device;
    final name = d.model.isNotEmpty ? d.model : d.serial;
    final transport = d.isWireless
        ? (widget.parallelStreams > 1
            ? 'Wi-Fi · ${widget.parallelStreams} streams'
            : 'Wi-Fi')
        : 'USB';
    final sub = d.isReady ? '$transport · Ready' : '$transport · ${d.state}';

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.navActiveBg
                : (_hovered && widget.onTap != null
                    ? p.navHoverBg
                    : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
            border: widget.selected
                ? Border.all(color: p.borderSoft, width: 1)
                : null,
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 3,
                height: widget.selected ? 22 : 0,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Icon(
                d.isWireless ? FluentIcons.wifi : FluentIcons.cell_phone,
                size: 14,
                color: widget.selected ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            widget.selected ? FontWeight.w600 : FontWeight.w500,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: d.isReady ? p.textSecondary : p.warnFg,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarProfileTile extends StatefulWidget {
  final Profile profile;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onSchedule;
  final VoidCallback onDelete;

  const _SidebarProfileTile({
    required this.profile,
    required this.active,
    required this.onSelect,
    required this.onSchedule,
    required this.onDelete,
  });

  @override
  State<_SidebarProfileTile> createState() => _SidebarProfileTileState();
}

class _SidebarProfileTileState extends State<_SidebarProfileTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    final pr = widget.profile;
    final hasSched = pr.scheduleTime != null;
    final layoutLabel =
        pr.layout == BackupLayout.snapshot ? l.layoutSnapshot : l.layoutMirror;
    final sub = hasSched
        ? '${pr.scheduleTime} · $layoutLabel'
        : '${pr.paths.length} folder(s) · $layoutLabel';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6.5),
          decoration: BoxDecoration(
            color: widget.active
                ? p.navActiveBg
                : (_hovered ? p.navHoverBg : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                FluentIcons.bookmarks,
                size: 13.5,
                color: widget.active ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pr.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            widget.active ? FontWeight.w600 : FontWeight.w500,
                        color: p.textPrimary,
                      ),
                    ),
                    Row(
                      children: [
                        if (hasSched) ...[
                          Icon(FluentIcons.clock,
                              size: 10, color: p.accentSoftFg),
                          const SizedBox(width: 3),
                        ],
                        Expanded(
                          child: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: hasSched
                                  ? p.accentSoftFg
                                  : p.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_hovered || widget.active) ...[
                Tooltip(
                  message: hasSched
                      ? l.scheduledDailyEdit(pr.scheduleTime!)
                      : l.scheduleProfileTooltip,
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.clock,
                      size: 12,
                      color: hasSched ? p.accent : p.textSecondary,
                    ),
                    onPressed: widget.onSchedule,
                  ),
                ),
                Tooltip(
                  message: l.deleteProfileTooltip,
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.delete,
                      size: 12,
                      color: p.textSecondary,
                    ),
                    onPressed: widget.onDelete,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplorerDriveCard extends StatelessWidget {
  final AppController app;
  const _ExplorerDriveCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    final mounted = app.drive.mounted;
    final writable = app.settings.driveWritable;
    final statusColor =
        mounted ? (writable ? p.warnFg : p.accentSoftFg) : p.textTertiary;

    return Tooltip(
      message: mounted
          ? l.unmountDrive(app.drive.mountPoint)
          : l.mountDrive(app.drive.mountPoint),
      child: WinBentoCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Icon(
              FluentIcons.hard_drive,
              size: 15,
              color: mounted ? (writable ? p.warnFg : p.accent) : p.textSecondary,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Explorer Drive (${app.drive.mountPoint}\\ )'
                        .replaceAll(' )', ')'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                  Text(
                    mounted
                        ? (writable
                            ? 'Mounted · Writable'
                            : 'Mounted · Read-only')
                        : 'Not mounted',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: statusColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            ToggleSwitch(
              checked: mounted,
              onChanged: (mounted || app.selected != null)
                  ? (_) => app.toggleDrive()
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Proposal C-style context top bar inside the main area (below Win32 titlebar).
class _WinContextTopBar extends StatelessWidget {
  final AppController app;
  final WinWorkspaceMode mode;

  const _WinContextTopBar({required this.app, required this.mode});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    final device = app.selected;

    final selCount = mode == WinWorkspaceMode.cleanup
        ? app.cleanup.selectedPaths.length
        : app.checked.length;
    final selBytes = mode == WinWorkspaceMode.cleanup
        ? app.cleanup.selectedBytes
        : app.selectionBytes;
    String? selectionLabel;
    if (selCount > 0) {
      if (mode == WinWorkspaceMode.backup && app.measuringSelection) {
        selectionLabel = '$selCount selected · ${l.measuringSize}';
      } else if (selBytes != null && selBytes > 0) {
        selectionLabel = mode == WinWorkspaceMode.cleanup
            ? '$selCount to clean · ${fmtBytes(selBytes)}'
            : '$selCount selected · ${fmtBytes(selBytes)}';
      } else {
        selectionLabel = '$selCount selected';
      }
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: p.ctxBarBg,
        border: Border(bottom: BorderSide(color: p.borderSoft, width: 1)),
      ),
      child: Row(
        children: [
          if (device != null && app.volumes.length > 1)
            _StoragePillSwitcher(app: app)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device == null
                      ? 'AndroidFiles'
                      : (device.model.isNotEmpty ? device.model : device.serial),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                if (device != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                      FluentIcons.chevron_right,
                      size: 10,
                      color: p.textTertiary,
                    ),
                  ),
                  Text(
                    mode == WinWorkspaceMode.cleanup
                        ? 'Clean Up Space'
                        : app.activeRootPath,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: mode == WinWorkspaceMode.cleanup
                          ? null
                          : winMonoFont,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          if (selectionLabel != null) ...[
            const SizedBox(width: 10),
            WinPill(
              label: selectionLabel,
              color: p.accentSoftFg,
              background: p.accentSoft,
              borderColor: p.accentBorder,
            ),
          ],
          const Spacer(),
          Tooltip(
            message: l.tooltipWireless,
            child: Button(
              onPressed: () => showWifiDialog(context, app),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.wifi, size: 13),
                  SizedBox(width: 6),
                  Text('Wireless', style: TextStyle(fontSize: 12.5)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: l.tooltipRefresh,
            child: IconButton(
              icon: const Icon(FluentIcons.refresh, size: 15),
              onPressed: app.selected == null ? null : app.refreshTree,
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: app.showLog ? l.tooltipHideLog : l.tooltipShowLog,
            child: IconButton(
              icon: Icon(
                FluentIcons.documentation,
                size: 15,
                color: app.showLog ? p.accent : null,
              ),
              onPressed: () => app.showLog = !app.showLog,
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: l.tooltipSettings,
            child: IconButton(
              icon: const Icon(FluentIcons.settings, size: 15),
              onPressed: () => showSettingsDialog(context, app),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill storage switcher in the context top bar when an external SD card exists.
class _StoragePillSwitcher extends StatelessWidget {
  final AppController app;
  const _StoragePillSwitcher({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: p.segTrack,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in app.volumes) _buildVolumeChip(p, v),
        ],
      ),
    );
  }

  Widget _buildVolumeChip(WinPalette p, StorageVolume v) {
    final active = app.activeVolume.path == v.path;
    final count = app.checkedCountForVolume(v);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => app.selectVolume(v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4.5),
          decoration: BoxDecoration(
            color: active ? p.segThumb : const Color(0x00000000),
            borderRadius: BorderRadius.circular(999),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: p.dark
                          ? const Color(0x33000000)
                          : const Color(0x14000000),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                v.isExternal ? FluentIcons.hard_drive : FluentIcons.cell_phone,
                size: 12,
                color: active ? p.accent : p.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                v.isExternal ? 'SD card' : 'Internal',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? p.textPrimary : p.textSecondary,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                v.isExternal ? v.volumeId : v.path,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: winMonoFont,
                  color: p.textTertiary,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                WinPill(
                  label: '$count',
                  color: p.accentSoftFg,
                  background: p.accentSoft,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitHandle extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;

  const _SplitHandle({required this.onDrag, required this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: const SizedBox(width: 14),
      ),
    );
  }
}

class _LogPane extends StatelessWidget {
  final AppController app;
  const _LogPane({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Container(
      height: 150,
      decoration: BoxDecoration(
        color: p.cardSubBg,
        border: Border(top: BorderSide(color: p.border, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.borderSoft, width: 1)),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.documentation, size: 12, color: p.textTertiary),
                const SizedBox(width: 6),
                Text(
                  'Activity Log',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: p.textSecondary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(FluentIcons.chrome_close,
                      size: 10, color: p.textSecondary),
                  onPressed: () => app.showLog = false,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              itemCount: app.logLines.length,
              itemBuilder: (_, i) => SelectableText(
                app.logLines[app.logLines.length - 1 - i],
                style: TextStyle(
                  fontFamily: winMonoFont,
                  fontSize: 11.5,
                  color: p.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
