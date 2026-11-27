import 'package:fluent_ui/fluent_ui.dart' show FluentIcons;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../cleanup_engine.dart';
import '../models.dart';
import 'macos/mac_theme.dart';
import 'win_theme.dart';

/// Clean Up Space → **Apps** tab (shared natively by macOS and Windows).
///
/// Displays per-app storage parsed from `dumpsys diskstats` broken into:
/// - **Static (APK)** (`appBytes`)
/// - **App Data** (`dataBytes`)
/// - **Reclaimable Cache** (`cacheBytes`)
///
/// Offers one-click safe **Trim All Caches** (`pm trim-caches`), plus per-app
/// **Open App Info on Phone**, **Clear Data** (confirmed), and **Uninstall**
/// (for user-installed packages, confirmed).
class CleanupAppsTab extends StatefulWidget {
  final AppController app;
  final bool macStyle;

  const CleanupAppsTab({
    super.key,
    required this.app,
    required this.macStyle,
  });

  @override
  State<CleanupAppsTab> createState() => _CleanupAppsTabState();
}

class _CleanupAppsTabState extends State<CleanupAppsTab> {
  final _searchCtrl = TextEditingController();

  CleanupController get cleanup => widget.app.cleanup;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = cleanup.appSearchQuery;
    _maybeLoadApps();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _maybeLoadApps() {
    final serial = widget.app.selected?.serial;
    if (serial != null &&
        cleanup.appStorage == null &&
        !cleanup.loadingApps &&
        cleanup.appStorageError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.app.selected?.serial == serial) {
          cleanup.scanApps(serial);
        }
      });
    }
  }

  Future<bool> _confirmAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final p = MacPalette.of(ctx);
        return MacDialogFrame(
          title: title,
          maxWidth: 420,
          content: Text(
            message,
            style: TextStyle(fontSize: 12.5, color: p.textSecondary, height: 1.45),
          ),
          actions: [
            MacPushButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            MacPushButton(
              destructive: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _handleClearData(AppStorageEntry entry) async {
    final serial = widget.app.selected?.serial;
    if (serial == null) return;
    final ok = await _confirmAction(
      title: 'Clear data for ${entry.displayName}?',
      message:
          'This runs `pm clear ${entry.packageName}` and permanently removes '
          '${fmtBytes(entry.dataBytes)} of app data and ${fmtBytes(entry.cacheBytes)} '
          'of cache. You will be signed out of this app and its local settings/files will reset.',
      confirmLabel: 'Clear Data',
    );
    if (ok && mounted) {
      await cleanup.clearAppData(serial, entry);
    }
  }

  Future<void> _handleUninstall(AppStorageEntry entry) async {
    final serial = widget.app.selected?.serial;
    if (serial == null) return;
    final ok = await _confirmAction(
      title: 'Uninstall ${entry.displayName}?',
      message:
          'Removes ${entry.packageName} and frees roughly ${fmtBytes(entry.totalBytes)} '
          '(${fmtBytes(entry.appBytes)} APK + ${fmtBytes(entry.dataBytes)} data + '
          '${fmtBytes(entry.cacheBytes)} cache).',
      confirmLabel: 'Uninstall',
    );
    if (ok && mounted) {
      await cleanup.uninstallApp(serial, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _AppsTheme.of(context, macStyle: widget.macStyle);
    final serial = widget.app.selected?.serial;

    if (cleanup.loadingApps && cleanup.appStorage == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CupertinoActivityIndicator(radius: 11),
            const SizedBox(height: 10),
            Text(
              'Reading installed app storage from phone…',
              style: TextStyle(fontSize: 12.5, color: t.textSecondary),
            ),
          ],
        ),
      );
    }

    if (cleanup.appStorageError != null && cleanup.appStorage == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not read app storage stats',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: t.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                cleanup.appStorageError!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: t.textSecondary),
              ),
              const SizedBox(height: 12),
              if (serial != null)
                _SmallBtn(
                  label: 'Retry',
                  theme: t,
                  primary: true,
                  onTap: () => cleanup.scanApps(serial),
                ),
            ],
          ),
        ),
      );
    }

    final report = cleanup.appStorage;
    if (report == null) {
      return Center(
        child: serial == null
            ? Text(
                'Connect a phone to inspect app storage.',
                style: TextStyle(fontSize: 12.5, color: t.textSecondary),
              )
            : _SmallBtn(
                label: 'Scan Installed Apps',
                theme: t,
                primary: true,
                onTap: () => cleanup.scanApps(serial),
              ),
      );
    }

    final apps = cleanup.filteredApps;
    final maxTotal =
        apps.isNotEmpty && apps.first.totalBytes > 0 ? apps.first.totalBytes : 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- Summary strip: Static (APK + Data) vs Reclaimable (Cache) + Trim button ---
        Container(
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          decoration: BoxDecoration(
            color: t.subBg,
            border: Border(bottom: BorderSide(color: t.border, width: 1)),
          ),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _LegendMetric(
                    dotColor: t.appColor,
                    label: 'Static APK',
                    value: fmtBytes(report.totalAppBytes),
                    theme: t,
                  ),
                  _LegendMetric(
                    dotColor: t.dataColor,
                    label: 'App Data',
                    value: fmtBytes(report.totalDataBytes),
                    theme: t,
                  ),
                  _LegendMetric(
                    dotColor: t.cacheColor,
                    label: 'Reclaimable Cache',
                    value: fmtBytes(report.totalCacheBytes),
                    highlight: true,
                    theme: t,
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cleanup.actingOnApps || cleanup.loadingApps) ...[
                    const CupertinoActivityIndicator(radius: 7),
                    const SizedBox(width: 8),
                  ],
                  Tooltip(
                    message:
                        'Safely trims regenerable app caches via `pm trim-caches` without affecting logins or app data.',
                    child: _SmallBtn(
                      label:
                          'Trim All Caches (${fmtBytes(report.totalCacheBytes)})',
                      icon: widget.macStyle
                          ? CupertinoIcons.sparkles
                          : FluentIcons.broom,
                      theme: t,
                      primary: true,
                      enabled: !cleanup.actingOnApps && serial != null,
                      onTap: () => cleanup.trimAllCaches(serial!),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _SmallBtn(
                    label: 'Refresh',
                    theme: t,
                    enabled: !cleanup.loadingApps && serial != null,
                    onTap: () => cleanup.scanApps(serial!),
                  ),
                ],
              ),
            ],
          ),
        ),

        if (cleanup.appActionMessage != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: t.greenBg,
              border: Border(bottom: BorderSide(color: t.greenBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    cleanup.appActionMessage!,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: t.greenFg,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: cleanup.dismissAppActionMessage,
                  child: Icon(
                    widget.macStyle
                        ? CupertinoIcons.xmark
                        : FluentIcons.chrome_close,
                    size: 12,
                    color: t.greenFg,
                  ),
                ),
              ],
            ),
          ),

        // --- Filter & Sort bar ---
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.border, width: 1)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _FilterChip(
                label: 'User Apps (${report.userAppCount})',
                active: !cleanup.showSystemApps,
                theme: t,
                onTap: () => cleanup.setShowSystemApps(false),
              ),
              _FilterChip(
                label: 'All Apps (${report.apps.length})',
                active: cleanup.showSystemApps,
                theme: t,
                onTap: () => cleanup.setShowSystemApps(true),
              ),
              Container(width: 1, height: 16, color: t.border),
              Text(
                'Sort:',
                style: TextStyle(fontSize: 11, color: t.textTertiary),
              ),
              for (final mode in AppSortMode.values)
                _FilterChip(
                  label: mode.label,
                  active: cleanup.appSort == mode,
                  theme: t,
                  onTap: () => cleanup.setAppSort(mode),
                ),
              SizedBox(
                width: 170,
                height: 24,
                child: CupertinoTextField(
                  controller: _searchCtrl,
                  onChanged: cleanup.setAppSearchQuery,
                  placeholder: 'Filter apps…',
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
            ],
          ),
        ),

        // --- Column headers ---
        Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: t.subBg,
            border: Border(bottom: BorderSide(color: t.border, width: 0.75)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Application',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: t.textTertiary,
                  ),
                ),
              ),
              _colHeader('Static APK', 74, t),
              _colHeader('Data', 74, t),
              _colHeader('Reclaimable', 82, t),
              _colHeader('Total', 76, t),
              const SizedBox(width: 82),
            ],
          ),
        ),

        // --- App list ---
        Expanded(
          child: apps.isEmpty
              ? Center(
                  child: Text(
                    'No apps match your filter.',
                    style: TextStyle(fontSize: 12, color: t.textSecondary),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  itemCount: apps.length,
                  itemBuilder: (_, i) => _AppStorageRow(
                    entry: apps[i],
                    maxTotal: maxTotal,
                    theme: t,
                    macStyle: widget.macStyle,
                    busy: cleanup.actingOnApps,
                    onOpenInfo: serial == null
                        ? null
                        : () => cleanup.openAppSettings(serial, apps[i]),
                    onClearData: serial == null
                        ? null
                        : () => _handleClearData(apps[i]),
                    onUninstall: (serial == null || !apps[i].isUserApp)
                        ? null
                        : () => _handleUninstall(apps[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _colHeader(String label, double width, _AppsTheme t) => SizedBox(
        width: width,
        child: Text(
          label,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: t.textTertiary,
          ),
        ),
      );
}

class _AppStorageRow extends StatefulWidget {
  final AppStorageEntry entry;
  final int maxTotal;
  final _AppsTheme theme;
  final bool macStyle;
  final bool busy;
  final VoidCallback? onOpenInfo;
  final VoidCallback? onClearData;
  final VoidCallback? onUninstall;

  const _AppStorageRow({
    required this.entry,
    required this.maxTotal,
    required this.theme,
    required this.macStyle,
    required this.busy,
    this.onOpenInfo,
    this.onClearData,
    this.onUninstall,
  });

  @override
  State<_AppStorageRow> createState() => _AppStorageRowState();
}

class _AppStorageRowState extends State<_AppStorageRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final a = widget.entry;
    final totalFrac =
        widget.maxTotal > 0 ? (a.totalBytes / widget.maxTotal).clamp(0.0, 1.0) : 0.0;
    final appFlex = a.totalBytes > 0 ? ((a.appBytes * 1000) ~/ a.totalBytes) : 0;
    final dataFlex =
        a.totalBytes > 0 ? ((a.dataBytes * 1000) ~/ a.totalBytes) : 0;
    final cacheFlex =
        a.totalBytes > 0 ? ((a.cacheBytes * 1000) ~/ a.totalBytes) : 0;
    final bigCache = a.cacheBytes >= 10 * 1024 * 1024;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: _hovered ? t.hoverBg : const Color(0x00000000),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          a.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: t.textPrimary,
                          ),
                        ),
                      ),
                      if (!a.isUserApp) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: t.subBg,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: t.border, width: 0.75),
                          ),
                          child: Text(
                            'System',
                            style: TextStyle(
                              fontSize: 9.5,
                              color: t.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    a.packageName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: t.monoFont,
                      color: t.textTertiary,
                    ),
                  ),
                  if (a.totalBytes > 0) ...[
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 4,
                      child: FractionallySizedBox(
                        widthFactor: totalFrac.clamp(0.02, 1.0),
                        alignment: Alignment.centerLeft,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: Row(
                            children: [
                              if (appFlex > 0)
                                Expanded(
                                  flex: appFlex,
                                  child: Container(color: t.appColor),
                                ),
                              if (dataFlex > 0)
                                Expanded(
                                  flex: dataFlex,
                                  child: Container(color: t.dataColor),
                                ),
                              if (cacheFlex > 0)
                                Expanded(
                                  flex: cacheFlex,
                                  child: Container(color: t.cacheColor),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _numCell(fmtBytes(a.appBytes), 74, t.textSecondary, t),
            _numCell(fmtBytes(a.dataBytes), 74, t.textSecondary, t),
            SizedBox(
              width: 82,
              child: Align(
                alignment: Alignment.centerRight,
                child: bigCache
                    ? Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: t.greenBg,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: t.greenBorder, width: 0.75),
                        ),
                        child: Text(
                          fmtBytes(a.cacheBytes),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: t.greenFg,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      )
                    : Text(
                        fmtBytes(a.cacheBytes),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 11,
                          color: t.textTertiary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
              ),
            ),
            _numCell(
              fmtBytes(a.totalBytes),
              76,
              t.textPrimary,
              t,
              bold: true,
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 74,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _RowIconBtn(
                    icon: widget.macStyle
                        ? CupertinoIcons.info_circle
                        : FluentIcons.info,
                    tooltip: 'Open App Info on phone',
                    theme: t,
                    enabled: !widget.busy && widget.onOpenInfo != null,
                    onTap: widget.onOpenInfo,
                  ),
                  _RowIconBtn(
                    icon: widget.macStyle
                        ? CupertinoIcons.clear_circled
                        : FluentIcons.erase_tool,
                    tooltip: 'Clear app data & cache (resets app)',
                    theme: t,
                    enabled: !widget.busy && widget.onClearData != null,
                    onTap: widget.onClearData,
                  ),
                  _RowIconBtn(
                    icon: widget.macStyle
                        ? CupertinoIcons.trash
                        : FluentIcons.delete,
                    tooltip: a.isUserApp
                        ? 'Uninstall app'
                        : 'System app cannot be uninstalled',
                    theme: t,
                    destructive: true,
                    enabled: !widget.busy && widget.onUninstall != null,
                    onTap: widget.onUninstall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _numCell(
    String text,
    double width,
    Color color,
    _AppsTheme t, {
    bool bold = false,
  }) =>
      SizedBox(
        width: width,
        child: Text(
          text,
          textAlign: TextAlign.right,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: color,
            fontFeatures: tabularFigures,
          ),
        ),
      );
}

class _AppsTheme {
  final Color bg;
  final Color subBg;
  final Color border;
  final Color hoverBg;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color greenBg;
  final Color greenFg;
  final Color greenBorder;
  final Color red;
  final Color appColor;
  final Color dataColor;
  final Color cacheColor;
  final String monoFont;

  const _AppsTheme({
    required this.bg,
    required this.subBg,
    required this.border,
    required this.hoverBg,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.greenBg,
    required this.greenFg,
    required this.greenBorder,
    required this.red,
    required this.appColor,
    required this.dataColor,
    required this.cacheColor,
    required this.monoFont,
  });

  factory _AppsTheme.of(BuildContext context, {required bool macStyle}) {
    if (macStyle) {
      final p = MacPalette.of(context);
      return _AppsTheme(
        bg: p.windowBg,
        subBg: p.inspectorBg,
        border: p.border,
        hoverBg: p.surfaceHover,
        textPrimary: p.textPrimary,
        textSecondary: p.textSecondary,
        textTertiary: p.textTertiary,
        accent: p.green,
        greenBg: p.isDark ? const Color(0xFF173624) : const Color(0xFFD6F5E3),
        greenFg: p.isDark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
        greenBorder:
            p.isDark ? const Color(0xFF285E3D) : const Color(0xFFA3E4BF),
        red: p.red,
        appColor: p.isDark ? const Color(0xFF64B5F6) : const Color(0xFF1E70BF),
        dataColor: p.isDark ? const Color(0xFFFFB74D) : const Color(0xFFD97706),
        cacheColor: p.isDark ? const Color(0xFF34D399) : const Color(0xFF16A34A),
        monoFont: macMonoFont,
      );
    }
    final p = WinPalette.of(context);
    return _AppsTheme(
      bg: p.cardBg,
      subBg: p.cardSubBg,
      border: p.borderSoft,
      hoverBg: p.rowHoverBg,
      textPrimary: p.textPrimary,
      textSecondary: p.textSecondary,
      textTertiary: p.textTertiary,
      accent: p.accent,
      greenBg: p.dark ? const Color(0xFF173624) : const Color(0xFFD6F5E3),
      greenFg: p.dark ? const Color(0xFF7AF2A3) : const Color(0xFF0B5D2C),
      greenBorder: p.dark ? const Color(0xFF285E3D) : const Color(0xFFA3E4BF),
      red: p.red,
      appColor: p.dark ? const Color(0xFF64B5F6) : const Color(0xFF0067C0),
      dataColor: p.dark ? const Color(0xFFFFB74D) : const Color(0xFFD97706),
      cacheColor: p.dark ? const Color(0xFF34D399) : const Color(0xFF16A34A),
      monoFont: winMonoFont,
    );
  }
}

class _LegendMetric extends StatelessWidget {
  final Color dotColor;
  final String label;
  final String value;
  final bool highlight;
  final _AppsTheme theme;

  const _LegendMetric({
    required this.dotColor,
    required this.label,
    required this.value,
    this.highlight = false,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: TextStyle(fontSize: 11.5, color: theme.textSecondary),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: highlight ? theme.greenFg : theme.textPrimary,
            fontFeatures: tabularFigures,
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final _AppsTheme theme;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.active,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
          decoration: BoxDecoration(
            color: active ? theme.greenBg : theme.bg,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: active ? theme.greenBorder : theme.border,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? theme.greenFg : theme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallBtn extends StatefulWidget {
  final String label;
  final IconData? icon;
  final _AppsTheme theme;
  final bool primary;
  final bool enabled;
  final VoidCallback onTap;

  const _SmallBtn({
    required this.label,
    this.icon,
    required this.theme,
    this.primary = false,
    this.enabled = true,
    required this.onTap,
  });

  @override
  State<_SmallBtn> createState() => _SmallBtnState();
}

class _SmallBtnState extends State<_SmallBtn> {
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

class _RowIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final _AppsTheme theme;
  final bool enabled;
  final bool destructive;
  final VoidCallback? onTap;

  const _RowIconBtn({
    required this.icon,
    required this.tooltip,
    required this.theme,
    required this.enabled,
    this.destructive = false,
    required this.onTap,
  });

  @override
  State<_RowIconBtn> createState() => _RowIconBtnState();
}

class _RowIconBtnState extends State<_RowIconBtn> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final color = !widget.enabled
        ? t.textTertiary.withValues(alpha: 0.35)
        : (widget.destructive && _hovered ? t.red : t.textSecondary);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.enabled && _hovered
                  ? t.hoverBg
                  : const Color(0x00000000),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(widget.icon, size: 13.5, color: color),
          ),
        ),
      ),
    );
  }
}
