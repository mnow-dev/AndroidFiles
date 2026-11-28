import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../../l10n/app_localizations.dart';
import '../../app_controller.dart';
import '../../drive_manager.dart';
import '../../models.dart';
import '../../settings.dart';
import 'mac_dialogs.dart';
import 'mac_theme.dart';

enum MacWorkspaceMode { backup, sync, cleanup }

/// Proposal A left sidebar: integrated traffic-light header, Workspace mode
/// switcher (Back Up / Clean Up Space), connected Devices list, and saved
/// Profiles list (with inline schedule & delete controls).
class MacSidebar extends StatelessWidget {
  final AppController app;
  final MacWorkspaceMode mode;
  final ValueChanged<MacWorkspaceMode> onModeChanged;

  const MacSidebar({
    super.key,
    required this.app,
    required this.mode,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);

    return Container(
      width: 210,
      color: p.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Unified titlebar drag zone above the sidebar lists (native macOS
          // traffic lights occupy the left ~76px).
          const MacWindowDragArea(
            child: SizedBox(height: 48),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 2, 4, 6),
                  child: MacSectionHeader('Workspace'),
                ),
                _NavModeRow(
                  icon: CupertinoIcons.arrow_down_doc,
                  label: 'Back Up',
                  busy: app.engine.isRunning,
                  selected: mode == MacWorkspaceMode.backup,
                  onTap: () => onModeChanged(MacWorkspaceMode.backup),
                ),
                _NavModeRow(
                  icon: CupertinoIcons.arrow_2_circlepath,
                  label: 'Folder Sync',
                  busy: app.sync.busy,
                  badge: app.sync.pairs.isNotEmpty
                      ? '${app.sync.pairs.length}'
                      : null,
                  selected: mode == MacWorkspaceMode.sync,
                  onTap: () => onModeChanged(MacWorkspaceMode.sync),
                ),
                _NavModeRow(
                  icon: CupertinoIcons.sparkles,
                  label: 'Clean Up Space',
                  busy: app.cleanup.scanning ||
                      app.cleanup.scanningDuplicates ||
                      app.cleanup.executing,
                  badge: app.cleanup.selectedPaths.isNotEmpty
                      ? '${app.cleanup.selectedPaths.length}'
                      : null,
                  selected: mode == MacWorkspaceMode.cleanup,
                  onTap: () => onModeChanged(MacWorkspaceMode.cleanup),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 4, 6),
                  child: MacSectionHeader(l.deviceLabel),
                ),
                if (app.devices.isEmpty)
                  _EmptyDevicesTile(
                    onPairWireless: () => showMacWifiDialog(context, app),
                  )
                else
                  for (final d in app.devices)
                    _DeviceRow(
                      device: d,
                      selected: app.selected?.serial == d.serial,
                      parallelStreams: app.settings.parallelStreams,
                      wifiLink:
                          app.selected?.serial == d.serial ? app.wifiLink : null,
                      onTap: d.isReady ? () => app.selectDevice(d) : null,
                    ),
                if (app.selected != null && app.volumes.length > 1) ...[
                  const SizedBox(height: 16),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 2, 4, 6),
                    child: MacSectionHeader('Storage'),
                  ),
                  for (final v in app.volumes)
                    _VolumeRow(
                      volume: v,
                      selected: app.activeVolume.path == v.path,
                      checkedCount: app.checkedCountForVolume(v),
                      onTap: () => app.selectVolume(v),
                    ),
                ],
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 4, 6),
                  child: MacSectionHeader(
                    l.sectionProfile,
                    trailing: Tooltip(
                      message: l.saveProfileTooltip,
                      child: MouseRegion(
                        cursor: app.checked.isNotEmpty
                            ? SystemMouseCursors.click
                            : MouseCursor.defer,
                        child: GestureDetector(
                          onTap: app.checked.isEmpty
                              ? null
                              : () => showMacSaveProfileDialog(context, app),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            child: Icon(
                              CupertinoIcons.add,
                              size: 14,
                              color: app.checked.isNotEmpty
                                  ? p.green
                                  : p.textTertiary.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (app.settings.profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      l.profilesPlaceholder,
                      style: TextStyle(fontSize: 11.5, color: p.textTertiary),
                    ),
                  )
                else
                  for (final profile in app.settings.profiles)
                    _ProfileRow(
                      profile: profile,
                      active: app.activeProfile == profile,
                      onSelect: () {
                        app.applyProfile(profile);
                        onModeChanged(MacWorkspaceMode.backup);
                      },
                      onSchedule: () =>
                          showMacScheduleDialog(context, app, profile),
                      onDelete: () => app.deleteProfile(profile),
                    ),
              ],
            ),
          ),
          if (DriveManager.supported)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: _DriveMountCard(app: app),
            ),
        ],
      ),
    );
  }
}

class _VolumeRow extends StatefulWidget {
  final StorageVolume volume;
  final bool selected;
  final int checkedCount;
  final VoidCallback onTap;

  const _VolumeRow({
    required this.volume,
    required this.selected,
    required this.checkedCount,
    required this.onTap,
  });

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final v = widget.volume;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.surfaceSelected
                : (_hovered ? p.surfaceHover : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                v.isExternal
                    ? CupertinoIcons.tray_full
                    : CupertinoIcons.device_phone_portrait,
                size: 15,
                color: widget.selected ? p.green : p.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            widget.selected ? FontWeight.w600 : FontWeight.w500,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      v.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: macMonoFont,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.checkedCount > 0) ...[
                const SizedBox(width: 4),
                MacStatusPill(
                  label: '${widget.checkedCount}',
                  color: p.green,
                  background: p.greenSoft,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavModeRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final String? badge;
  final bool busy;
  final bool selected;
  final VoidCallback onTap;

  const _NavModeRow({
    required this.icon,
    required this.label,
    this.badge,
    this.busy = false,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavModeRow> createState() => _NavModeRowState();
}

class _NavModeRowState extends State<_NavModeRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6.5),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.surfaceSelected
                : (_hovered ? p.surfaceHover : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 15,
                color: widget.selected ? p.green : p.textSecondary,
              ),
              const SizedBox(width: 8),
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
                const CupertinoActivityIndicator(radius: 6.5),
              ],
              if (widget.badge != null) ...[
                const SizedBox(width: 6),
                MacStatusPill(
                  label: widget.badge!,
                  color: p.green,
                  background: p.greenSoft,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyDevicesTile extends StatefulWidget {
  final VoidCallback onPairWireless;
  const _EmptyDevicesTile({required this.onPairWireless});

  @override
  State<_EmptyDevicesTile> createState() => _EmptyDevicesTileState();
}

class _EmptyDevicesTileState extends State<_EmptyDevicesTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPairWireless,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceHover : const Color(0x00000000),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.device_phone_portrait,
                size: 16,
                color: p.textTertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.selectDevice,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: p.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 1),
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

class _DeviceRow extends StatefulWidget {
  final AdbDevice device;
  final bool selected;
  final int parallelStreams;
  final WifiLinkInfo? wifiLink;
  final VoidCallback? onTap;

  const _DeviceRow({
    required this.device,
    required this.selected,
    required this.parallelStreams,
    this.wifiLink,
    required this.onTap,
  });

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final d = widget.device;
    final name = d.model.isNotEmpty ? d.model : d.serial;
    final transport = d.isWireless
        ? (widget.parallelStreams > 1
            ? 'Wi-Fi · ${widget.parallelStreams} streams'
            : 'Wi-Fi')
        : 'USB';
    final subtitle = d.isReady ? '$transport · Ready' : '$transport · ${d.state}';

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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6.5),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.surfaceSelected
                : (_hovered && widget.onTap != null
                    ? p.surfaceHover
                    : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                d.isWireless
                    ? CupertinoIcons.wifi
                    : CupertinoIcons.device_phone_portrait,
                size: 16,
                color: widget.selected
                    ? p.green
                    : (d.isReady ? p.textSecondary : p.textTertiary),
              ),
              const SizedBox(width: 8),
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
                        color: d.isReady ? p.textPrimary : p.textTertiary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: d.isReady ? p.textTertiary : p.amber,
                      ),
                    ),
                    if (widget.wifiLink != null) ...[
                      const SizedBox(height: 4),
                      Tooltip(
                        message: widget.wifiLink!.detailTooltip,
                        child: MacStatusPill(
                          label: widget.wifiLink!.shortLabel,
                          color: widget.wifiLink!.isSlow24Ghz
                              ? (p.isDark
                                  ? const Color(0xFFFFCA62)
                                  : const Color(0xFF8A4300))
                              : (p.isDark
                                  ? const Color(0xFF7AF2A3)
                                  : const Color(0xFF0B5D2C)),
                          background: widget.wifiLink!.isSlow24Ghz
                              ? (p.isDark
                                  ? const Color(0xFF3A2A12)
                                  : const Color(0xFFFEECC8))
                              : (p.isDark
                                  ? const Color(0xFF173624)
                                  : const Color(0xFFD6F5E3)),
                          borderColor: widget.wifiLink!.isSlow24Ghz
                              ? (p.isDark
                                  ? const Color(0xFF6B4D1E)
                                  : const Color(0xFFF6CE83))
                              : (p.isDark
                                  ? const Color(0xFF285E3D)
                                  : const Color(0xFFA3E4BF)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.selected && d.isReady)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: p.green,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileRow extends StatefulWidget {
  final Profile profile;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onSchedule;
  final VoidCallback onDelete;

  const _ProfileRow({
    required this.profile,
    required this.active,
    required this.onSelect,
    required this.onSchedule,
    required this.onDelete,
  });

  @override
  State<_ProfileRow> createState() => _ProfileRowState();
}

class _ProfileRowState extends State<_ProfileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    final prof = widget.profile;
    final layoutLabel = prof.layout == BackupLayout.mirror
        ? l.layoutMirror
        : l.layoutSnapshot;
    final schedLabel = prof.scheduleTime != null
        ? 'Daily ${prof.scheduleTime}'
        : '${prof.paths.length} folder${prof.paths.length == 1 ? '' : 's'}';
    final showActions = _hovered || widget.active;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onSelect,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6.5),
          decoration: BoxDecoration(
            color: widget.active
                ? p.surfaceSelected
                : (_hovered ? p.surfaceHover : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.bookmark,
                size: 14,
                color: widget.active ? p.green : p.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      prof.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            widget.active ? FontWeight.w600 : FontWeight.w500,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      '$schedLabel · $layoutLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: prof.scheduleTime != null
                            ? p.green
                            : p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              if (showActions) ...[
                Tooltip(
                  message: prof.scheduleTime != null
                      ? l.scheduledDailyEdit(prof.scheduleTime!)
                      : l.scheduleProfileTooltip,
                  child: GestureDetector(
                    onTap: widget.onSchedule,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        CupertinoIcons.clock,
                        size: 13,
                        color: prof.scheduleTime != null
                            ? p.green
                            : p.textSecondary,
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: l.deleteProfileTooltip,
                  child: GestureDetector(
                    onTap: widget.onDelete,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        CupertinoIcons.trash,
                        size: 13,
                        color: p.textSecondary,
                      ),
                    ),
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

class _DriveMountCard extends StatelessWidget {
  final AppController app;
  const _DriveMountCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final mounted = app.drive.mounted;
    final writable = app.settings.driveWritable;
    final statusColor = mounted ? (writable ? p.amber : p.green) : p.textTertiary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: p.border, width: 0.75),
      ),
      child: Row(
        children: [
          Icon(CupertinoIcons.tray_full, size: 16, color: statusColor),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Finder Volume',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                Text(
                  mounted
                      ? (writable ? 'Mounted · Writable' : 'Mounted · Read-Only')
                      : 'Not mounted',
                  style: TextStyle(fontSize: 10.5, color: statusColor),
                ),
              ],
            ),
          ),
          MacSwitch(
            value: mounted,
            onChanged: (_) {
              if (mounted || app.selected != null) app.toggleDrive();
            },
          ),
        ],
      ),
    );
  }
}

