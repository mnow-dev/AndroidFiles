import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../app_controller.dart';
import '../../backup_engine.dart' show fmtBytes;
import '../../cleanup_engine.dart';
import '../../models.dart';
import '../../os.dart';
import '../../preview_service.dart';
import '../quick_look_dialog.dart';
import 'mac_dialogs.dart';
import 'mac_theme.dart';

enum _CleanupTab { proposals, large, duplicates, review }

/// Proposal A native macOS Space Cleanup studio: storage overview, intelligent
/// cleanup proposals (DCIM videos, retention windows, backed-up data), large
/// folders & files explorer, duplicate finder, and safe "Back up first, then
/// clean up" execution bar.
class MacCleanupView extends StatefulWidget {
  final AppController app;
  const MacCleanupView({super.key, required this.app});

  @override
  State<MacCleanupView> createState() => _MacCleanupViewState();
}

class _MacCleanupViewState extends State<MacCleanupView> {
  AppController get app => widget.app;
  CleanupController get cleanup => app.cleanup;

  _CleanupTab _tab = _CleanupTab.proposals;
  bool _backupFirst = true;
  bool _verifyMd5 = true;
  String? _autoScannedKey;

  @override
  void initState() {
    super.initState();
    _maybeAutoScan();
  }

  @override
  void didUpdateWidget(covariant MacCleanupView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeAutoScan();
  }

  void _maybeAutoScan() {
    final serial = app.selected?.serial;
    final root = app.activeRootPath;
    final key = serial == null ? null : '$serial|$root';
    if (serial != null &&
        !cleanup.hasScan &&
        !cleanup.scanning &&
        _autoScannedKey != key) {
      _autoScannedKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            app.selected?.serial == serial &&
            app.activeRootPath == root) {
          cleanup.scan(serial, app.destination.text, rootPath: root);
        }
      });
    }
  }

  void _openQuickLook(List<ScannedFile> files, int index) {
    final items = [
      for (final f in files)
        PreviewItem(
          name: f.name,
          devicePath: f.absPath,
          size: f.size,
          modified:
              '${f.modified.year}-${f.modified.month.toString().padLeft(2, '0')}-${f.modified.day.toString().padLeft(2, '0')} '
              '${f.modified.hour.toString().padLeft(2, '0')}:${f.modified.minute.toString().padLeft(2, '0')}',
          backupStatus: f.backedUp
              ? EntryBackupStatus.backedUp
              : EntryBackupStatus.notBackedUp,
          isChecked: () => cleanup.selectedPaths.contains(f.relPath),
          onToggleChecked: () => cleanup.toggleFile(f.relPath),
          checkLabel: 'Select for cleanup',
        ),
    ];
    showQuickLookDialog(
      context,
      app: app,
      items: items,
      initialIndex: index,
      macStyle: true,
    );
  }

  Future<void> _pickBackupDir() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Backup destination',
    );
    if (dir != null) {
      app.setDestination(dir);
      final serial = app.selected?.serial;
      if (serial != null) {
        await cleanup.scan(serial, dir, rootPath: app.activeRootPath);
      }
    }
  }

  Future<void> _confirmAndRun() async {
    final serial = app.selected?.serial;
    if (serial == null || cleanup.selectedPaths.isEmpty) return;

    final needBackup = _backupFirst && cleanup.selectedNotBackedUpCount > 0;
    if (needBackup && app.destination.text.trim().isEmpty) {
      await _pickBackupDir();
      if (app.destination.text.trim().isEmpty) return;
    }

    if (!mounted) return;
    final dest = app.destination.text.trim();
    if (needBackup && unmountedVolume(dest) != null) {
      return;
    }

    final totalCount = cleanup.selectedFiles.length;
    final totalSize = fmtBytes(cleanup.selectedBytes);
    final toBackUpCount = needBackup ? cleanup.selectedNotBackedUpCount : 0;
    final unbackedDirect =
        !_backupFirst ? cleanup.selectedNotBackedUpCount : 0;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final p = MacPalette.of(ctx);
        return MacDialogFrame(
          title: needBackup
              ? 'Back up and remove $totalCount file(s)?'
              : 'Remove $totalCount file(s) from phone?',
          subtitle: 'Reclaims $totalSize of phone storage.',
          maxWidth: 440,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (toBackUpCount > 0) ...[
                _ConfirmInfoRow(
                  icon: CupertinoIcons.arrow_down_to_line,
                  color: p.green,
                  text:
                      '$toBackUpCount file(s) will be backed up first to:\n$dest',
                ),
                const SizedBox(height: 8),
              ],
              if (_verifyMd5 && (needBackup || cleanup.selectedBackedUpCount > 0)) ...[
                _ConfirmInfoRow(
                  icon: CupertinoIcons.checkmark_seal,
                  color: p.green,
                  text:
                      'MD5 hashes will be verified against your Mac backup before any file is deleted.',
                ),
                const SizedBox(height: 8),
              ],
              _ConfirmInfoRow(
                icon: CupertinoIcons.exclamationmark_triangle_fill,
                color: unbackedDirect > 0 ? p.red : p.amber,
                text: unbackedDirect > 0
                    ? '$unbackedDirect selected file(s) have NO local backup and will be permanently deleted from your phone (no Trash bin).'
                    : 'Deleted files are removed permanently from the phone (Android has no Trash bin for ADB removals).',
              ),
            ],
          ),
          actions: [
            MacPushButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            if (needBackup)
              MacPrimaryButton(
                expand: false,
                height: 28,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Back Up & Free $totalSize'),
              )
            else
              MacPushButton(
                destructive: true,
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Delete $totalSize'),
              ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;
    await cleanup.executeCleanup(
      serial: serial,
      backupDest: dest,
      backupFirst: _backupFirst,
      verifyMd5: _verifyMd5,
    );
    app.refreshTree();
  }

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final device = app.selected;

    if (device == null) {
      return Container(
        color: p.windowBg,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
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
                CupertinoIcons.sparkles,
                size: 24,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Connect an Android phone to analyze storage',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Find large files, duplicates, and backed-up videos you can safely offload.',
              style: TextStyle(fontSize: 12, color: p.textSecondary),
            ),
            const SizedBox(height: 14),
            MacPushButton(
              onPressed: () => showMacWifiDialog(context, app),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(CupertinoIcons.wifi, size: 13),
                  SizedBox(width: 6),
                  Text('Wireless debugging'),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final reviewLabel = cleanup.selectedPaths.isEmpty
        ? 'Review'
        : 'Review (${cleanup.selectedPaths.length})';

    return Container(
      color: p.windowBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Storage Header & Tab Bar ---
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: p.inspectorBg,
              border: Border(bottom: BorderSide(color: p.border, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StorageSummaryStrip(
                  app: app,
                  cleanup: cleanup,
                  onScan: () => cleanup.scan(
                    device.serial,
                    app.destination.text,
                    rootPath: app.activeRootPath,
                  ),
                  onPickBackup: _pickBackupDir,
                ),
                const SizedBox(height: 11),
                MacSegmentedControl<_CleanupTab>(
                  value: _tab,
                  items: [
                    (_CleanupTab.proposals, 'Smart Proposals'),
                    (_CleanupTab.large, 'Large Files & Folders'),
                    (_CleanupTab.duplicates, 'Duplicates'),
                    (_CleanupTab.review, reviewLabel),
                  ],
                  onChanged: (v) => setState(() => _tab = v),
                ),
              ],
            ),
          ),

          if (cleanup.lastSummary != null)
            _SummaryBanner(
              summary: cleanup.lastSummary!,
              onDismiss: () {
                cleanup.lastSummary = null;
                setState(() {});
              },
            ),

          // --- Main Body ---
          Expanded(
            child: cleanup.scanning
                ? _ScanningState(
                    title: 'Scanning ${app.activeRootPath} on ${device.model.isNotEmpty ? device.model : device.serial}…',
                    subtitle: 'Indexing file sizes, dates, and comparing against your local backup folder.',
                  )
                : cleanup.scanError != null
                    ? _ErrorState(
                        message: cleanup.scanError!,
                        onRetry: () => cleanup.scan(
                          device.serial,
                          app.destination.text,
                          rootPath: app.activeRootPath,
                        ),
                      )
                    : !cleanup.hasScan
                        ? _IdleScanState(
                            onScan: () => cleanup.scan(
                              device.serial,
                              app.destination.text,
                              rootPath: app.activeRootPath,
                            ),
                          )
                        : switch (_tab) {
                            _CleanupTab.proposals =>
                              _SmartProposalsTab(cleanup: cleanup),
                            _CleanupTab.large => _LargeFilesTab(
                                cleanup: cleanup,
                                onPreview: _openQuickLook,
                              ),
                            _CleanupTab.duplicates => _DuplicatesTab(
                                cleanup: cleanup,
                                onFind: () =>
                                    cleanup.findDuplicates(device.serial),
                                onPreview: _openQuickLook,
                              ),
                            _CleanupTab.review => _ReviewTab(
                                cleanup: cleanup,
                                onPreview: _openQuickLook,
                              ),
                          },
          ),

          // --- Sticky Bottom Cleanup Action Bar ---
          if (cleanup.selectedPaths.isNotEmpty || cleanup.executing)
            _CleanupActionBar(
              app: app,
              cleanup: cleanup,
              backupFirst: _backupFirst,
              verifyMd5: _verifyMd5,
              onToggleBackupFirst: (v) => setState(() => _backupFirst = v),
              onToggleVerifyMd5: (v) => setState(() => _verifyMd5 = v),
              onRun: _confirmAndRun,
            ),
        ],
      ),
    );
  }
}

class _StorageSummaryStrip extends StatelessWidget {
  final AppController app;
  final CleanupController cleanup;
  final VoidCallback onScan;
  final VoidCallback onPickBackup;

  const _StorageSummaryStrip({
    required this.app,
    required this.cleanup,
    required this.onScan,
    required this.onPickBackup,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final space = cleanup.deviceSpace;
    final destText = app.destination.text.trim();
    final backedUpMatchCount = cleanup.files.where((f) => f.backedUp).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Phone Storage',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                      if (space != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${fmtBytes(space.usedBytes)} used of ${fmtBytes(space.totalBytes)} · ${fmtBytes(space.freeBytes)} free',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: p.textSecondary,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        destText.isNotEmpty
                            ? CupertinoIcons.checkmark_shield
                            : CupertinoIcons.folder,
                        size: 12,
                        color: destText.isNotEmpty ? p.green : p.textTertiary,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          destText.isEmpty
                              ? 'No backup folder set — choose one to detect already backed-up files'
                              : cleanup.hasScan
                                  ? 'Comparing against $destText · $backedUpMatchCount backed-up file(s) matched'
                                  : 'Backup folder: $destText',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: p.textTertiary,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            MacPushButton(
              onPressed: cleanup.scanning || cleanup.executing ? null : onPickBackup,
              child: Text(destText.isEmpty ? 'Set Backup Folder…' : 'Backup Folder…'),
            ),
            const SizedBox(width: 6),
            MacPushButton(
              onPressed: cleanup.scanning || cleanup.executing ? null : onScan,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.refresh, size: 12),
                  const SizedBox(width: 5),
                  Text(cleanup.hasScan ? 'Rescan' : 'Scan'),
                ],
              ),
            ),
          ],
        ),
        if (space != null && space.totalBytes > 0) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 7,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final usedFrac =
                      (space.usedBytes / space.totalBytes).clamp(0.0, 1.0);
                  final selFrac = cleanup.selectedBytes > 0
                      ? (cleanup.selectedBytes / space.totalBytes)
                          .clamp(0.0, usedFrac)
                      : 0.0;
                  final keptUsedFrac = (usedFrac - selFrac).clamp(0.0, 1.0);
                  return Stack(
                    children: [
                      Container(color: p.segTrack),
                      Row(
                        children: [
                          Container(
                            width: w * keptUsedFrac,
                            color: usedFrac > 0.85 ? p.amber : p.capacityUsed,
                          ),
                          if (selFrac > 0)
                            Container(width: w * selFrac, color: p.green),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SmartProposalsTab extends StatelessWidget {
  final CleanupController cleanup;
  const _SmartProposalsTab({required this.cleanup});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final proposals = cleanup.proposals;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Filter strip: Retention window pills + Backed up only switch
        Wrap(
          spacing: 6,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Retention:',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: p.textSecondary,
              ),
            ),
            for (final w in RetentionWindow.values)
              _FilterPill(
                label: w.label,
                active: cleanup.retention == w,
                onTap: () => cleanup.setRetention(w),
              ),
            const SizedBox(width: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Backed up only',
                  style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                ),
                const SizedBox(width: 6),
                MacSwitch(
                  value: cleanup.onlyBackedUpProposals,
                  onChanged: cleanup.setOnlyBackedUpProposals,
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (proposals.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: p.inspectorBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Column(
              children: [
                Icon(CupertinoIcons.checkmark_circle, size: 28, color: p.green),
                const SizedBox(height: 8),
                Text(
                  'No matching cleanup proposals for this filter',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  cleanup.onlyBackedUpProposals
                      ? 'Try turning off "Backed up only" (you can still back up before deleting) or widening the retention window.'
                      : 'Try choosing a shorter retention window or "Include all".',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: p.textSecondary),
                ),
              ],
            ),
          )
        else
          for (final prop in proposals) ...[
            _ProposalCard(
              proposal: prop,
              selected: cleanup.isProposalSelected(prop),
              onToggle: () => cleanup.toggleProposal(prop),
            ),
            const SizedBox(height: 10),
          ],
      ],
    );
  }
}

class _ProposalCard extends StatefulWidget {
  final SmartProposal proposal;
  final bool selected;
  final VoidCallback onToggle;

  const _ProposalCard({
    required this.proposal,
    required this.selected,
    required this.onToggle,
  });

  @override
  State<_ProposalCard> createState() => _ProposalCardState();
}

class _ProposalCardState extends State<_ProposalCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final prop = widget.proposal;
    final backupPill = prop.allBackedUp
        ? MacStatusPill(
            label: 'All ${prop.backedUpCount} backed up',
            color: p.green,
            background: p.greenSoft,
          )
        : prop.backedUpCount > 0
            ? MacStatusPill(
                label:
                    '${prop.backedUpCount} backed up · ${prop.notBackedUpCount} not yet',
                color: p.amber,
                background: p.amberSoft,
              )
            : MacStatusPill(
                label: 'Not backed up yet',
                color: p.amber,
                background: p.amberSoft,
              );

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: widget.selected ? p.surfaceSelected : p.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: widget.selected ? p.greenBorder : p.border,
          width: widget.selected ? 1.1 : 0.85,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: MacCheckbox(
                  checked: widget.selected,
                  onTap: widget.onToggle,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            prop.title,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          fmtBytes(prop.totalBytes),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: p.green,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      prop.subtitle,
                      style: TextStyle(fontSize: 12, color: p.textSecondary),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 5,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        MacStatusPill(
                          label: '${prop.files.length} file(s)',
                          color: p.textSecondary,
                          background: p.segTrack,
                        ),
                        backupPill,
                        Text(
                          prop.reason,
                          style: TextStyle(fontSize: 11, color: p.textTertiary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      _expanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      size: 13,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_expanded) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: p.inspectorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.border, width: 0.75),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final f in prop.files.take(8))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.5),
                      child: Row(
                        children: [
                          Icon(
                            _iconForKind(f.kind),
                            size: 12,
                            color: p.textTertiary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              f.relPath,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: macMonoFont,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (f.backedUp)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(
                                CupertinoIcons.checkmark_shield_fill,
                                size: 11,
                                color: p.green,
                              ),
                            ),
                          Text(
                            fmtBytes(f.size),
                            style: TextStyle(
                              fontSize: 11,
                              color: p.textSecondary,
                              fontFeatures: tabularFigures,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (prop.files.length > 8)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '…and ${prop.files.length - 8} more file(s)',
                        style: TextStyle(fontSize: 11, color: p.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LargeFilesTab extends StatelessWidget {
  final CleanupController cleanup;
  final void Function(List<ScannedFile> files, int index) onPreview;
  const _LargeFilesTab({required this.cleanup, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final folders = cleanup.folders;
    final maxFolderBytes = folders.isNotEmpty ? folders.first.totalBytes : 1;
    final largeFiles = cleanup.filteredLargeFiles;

    return Row(
      children: [
        // Left column: Largest Folders
        SizedBox(
          width: 270,
          child: Container(
            decoration: BoxDecoration(
              color: p.inspectorBg,
              border: Border(right: BorderSide(color: p.border, width: 1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: Row(
                    children: [
                      const Expanded(child: MacSectionHeader('Largest Folders')),
                      if (cleanup.folderFilter != null)
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => cleanup.setFolderFilter(null),
                            child: Text(
                              'Show all',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: p.green,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    itemCount: folders.length,
                    itemBuilder: (_, i) {
                      final f = folders[i];
                      final active = cleanup.folderFilter == f.relPath;
                      final frac = maxFolderBytes > 0
                          ? (f.totalBytes / maxFolderBytes).clamp(0.03, 1.0)
                          : 0.0;
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => cleanup.setFolderFilter(
                            active ? null : f.relPath,
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: active ? p.surfaceSelected : p.surface,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: active ? p.greenBorder : p.border,
                                width: 0.75,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const MacFolderIcon(width: 14, height: 11.5),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Text(
                                        f.relPath,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: p.textPrimary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      fmtBytes(f.totalBytes),
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                        color: p.textPrimary,
                                        fontFeatures: tabularFigures,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: SizedBox(
                                    height: 4,
                                    child: Stack(
                                      children: [
                                        Container(color: p.segTrack),
                                        FractionallySizedBox(
                                          widthFactor: frac,
                                          child: Container(color: p.green),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${f.fileCount} files${f.videoBytes > 0 ? ' · ${fmtBytes(f.videoBytes)} video' : ''}',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: p.textTertiary,
                                    fontFeatures: tabularFigures,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        // Right column: Largest Files list
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: p.border, width: 1)),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _FilterPill(
                      label: 'All sizes',
                      active: cleanup.minLargeBytes == 0,
                      onTap: () => cleanup.setMinLargeBytes(0),
                    ),
                    _FilterPill(
                      label: '20 MB+',
                      active: cleanup.minLargeBytes == 20 * 1024 * 1024,
                      onTap: () => cleanup.setMinLargeBytes(20 * 1024 * 1024),
                    ),
                    _FilterPill(
                      label: '50 MB+',
                      active: cleanup.minLargeBytes == 50 * 1024 * 1024,
                      onTap: () => cleanup.setMinLargeBytes(50 * 1024 * 1024),
                    ),
                    _FilterPill(
                      label: '100 MB+',
                      active: cleanup.minLargeBytes == 100 * 1024 * 1024,
                      onTap: () => cleanup.setMinLargeBytes(100 * 1024 * 1024),
                    ),
                    const SizedBox(width: 6),
                    _FilterPill(
                      label: 'Videos only',
                      active: cleanup.largeVideosOnly,
                      onTap: () =>
                          cleanup.setLargeVideosOnly(!cleanup.largeVideosOnly),
                    ),
                    Text(
                      '${largeFiles.length} shown',
                      style: TextStyle(
                        fontSize: 11,
                        color: p.textTertiary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: largeFiles.isEmpty
                    ? Center(
                        child: Text(
                          'No files match this size / folder filter.',
                          style: TextStyle(fontSize: 12, color: p.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: largeFiles.length.clamp(0, 400),
                        itemBuilder: (_, i) {
                          final f = largeFiles[i];
                          final checked =
                              cleanup.selectedPaths.contains(f.relPath);
                          return _FileCheckRow(
                            file: f,
                            checked: checked,
                            onTap: () => cleanup.toggleFile(f.relPath),
                            onPreview: () => onPreview(largeFiles, i),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DuplicatesTab extends StatelessWidget {
  final CleanupController cleanup;
  final VoidCallback onFind;
  final void Function(List<ScannedFile> files, int index) onPreview;

  const _DuplicatesTab({
    required this.cleanup,
    required this.onFind,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);

    if (cleanup.scanningDuplicates) {
      final frac = cleanup.dupTotalToHash > 0
          ? (cleanup.dupHashed / cleanup.dupTotalToHash).clamp(0.0, 1.0)
          : 0.0;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CupertinoActivityIndicator(radius: 10),
              const SizedBox(height: 12),
              Text(
                cleanup.dupTotalToHash > 0
                    ? 'Hashing candidate duplicates (${cleanup.dupHashed}/${cleanup.dupTotalToHash})…'
                    : 'Grouping files by exact size…',
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
                        widthFactor: frac,
                        child: Container(color: p.green),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (!cleanup.duplicatesScanned) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.doc_on_doc,
                size: 32,
                color: p.textSecondary,
              ),
              const SizedBox(height: 10),
              Text(
                'Find exact duplicate files',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Filters by exact byte size first, then MD5-hashes only matching candidates on the phone.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: p.textSecondary),
              ),
              const SizedBox(height: 14),
              MacPrimaryButton(
                expand: false,
                height: 32,
                onPressed: onFind,
                child: const Text('Find Duplicates'),
              ),
            ],
          ),
        ),
      );
    }

    if (cleanup.duplicates.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.checkmark_circle, size: 30, color: p.green),
            const SizedBox(height: 8),
            Text(
              'No duplicate files found (≥ 100 KB)',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            MacPushButton(
              onPressed: onFind,
              child: const Text('Scan Again'),
            ),
          ],
        ),
      );
    }

    final totalWasted =
        cleanup.duplicates.fold(0, (s, g) => s + g.wastedBytes);
    final allRedundant = [
      for (final g in cleanup.duplicates) ...g.redundantCopies,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border, width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${cleanup.duplicates.length} duplicate group(s) · ${fmtBytes(totalWasted)} wasted',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
              MacPushButton(
                onPressed: () => cleanup.selectFiles(allRedundant),
                child: const Text('Select All Extra Copies'),
              ),
              const SizedBox(width: 6),
              MacPushButton(onPressed: onFind, child: const Text('Rescan')),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(14),
            itemCount: cleanup.duplicates.length,
            itemBuilder: (_, i) {
              final g = cleanup.duplicates[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: p.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.border, width: 0.8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _iconForKind(g.recommendedKeep.kind),
                          size: 13,
                          color: p.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            g.recommendedKeep.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                        ),
                        Text(
                          '${g.files.length} copies · ${fmtBytes(g.fileSize)} each',
                          style: TextStyle(
                            fontSize: 11,
                            color: p.textSecondary,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    for (var idx = 0; idx < g.files.length; idx++) ...[
                      _DuplicateCopyRow(
                        file: g.files[idx],
                        recommendedKeep: idx == 0,
                        checked: cleanup.selectedPaths.contains(
                          g.files[idx].relPath,
                        ),
                        onTap: () => cleanup.toggleFile(g.files[idx].relPath),
                        onPreview: () => onPreview(g.files, idx),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DuplicateCopyRow extends StatelessWidget {
  final ScannedFile file;
  final bool recommendedKeep;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback? onPreview;

  const _DuplicateCopyRow({
    required this.file,
    required this.recommendedKeep,
    required this.checked,
    required this.onTap,
    this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        onDoubleTap: onPreview,
        child: Container(
          margin: const EdgeInsets.only(top: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: checked ? p.surfaceSelected : p.inspectorBg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              MacCheckbox(checked: checked, onTap: onTap),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.relPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: macMonoFont,
                    color: p.textPrimary,
                  ),
                ),
              ),
              if (onPreview != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Quick Look',
                  child: GestureDetector(
                    onTap: onPreview,
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
              const SizedBox(width: 8),
              if (recommendedKeep)
                MacStatusPill(
                  label: 'Recommended Keep',
                  color: p.green,
                  background: p.greenSoft,
                )
              else if (file.backedUp)
                MacStatusPill(
                  label: 'Backed up',
                  color: p.green,
                  background: p.greenSoft,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewTab extends StatelessWidget {
  final CleanupController cleanup;
  final void Function(List<ScannedFile> files, int index) onPreview;
  const _ReviewTab({required this.cleanup, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final selected = cleanup.selectedFiles;
    if (selected.isEmpty) {
      return Center(
        child: Text(
          'No files selected for cleanup yet. Pick a Smart Proposal, Large Files, or Duplicates.',
          style: TextStyle(fontSize: 12, color: p.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.border, width: 1)),
          ),
          child: Row(
            children: [
              Text(
                '${selected.length} file(s) queued for cleanup · ${fmtBytes(cleanup.selectedBytes)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                  fontFeatures: tabularFigures,
                ),
              ),
              const Spacer(),
              MacPushButton(
                onPressed: cleanup.clearSelection,
                child: const Text('Clear Selection'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(10),
            itemCount: selected.length,
            itemBuilder: (_, i) {
              final f = selected[i];
              return _FileCheckRow(
                file: f,
                checked: true,
                onTap: () => cleanup.toggleFile(f.relPath),
                onPreview: () => onPreview(selected, i),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FileCheckRow extends StatelessWidget {
  final ScannedFile file;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback? onPreview;

  const _FileCheckRow({
    required this.file,
    required this.checked,
    required this.onTap,
    this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final dt = file.modified;
    final dateStr =
        '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        onDoubleTap: onPreview,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: checked ? p.surfaceSelected : const Color(0x00000000),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              MacCheckbox(checked: checked, onTap: onTap),
              const SizedBox(width: 8),
              Icon(_iconForKind(file.kind), size: 14, color: p.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      file.parentDir.isEmpty
                          ? file.rootPath
                          : '${file.rootPath}/${file.parentDir}',
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
              if (onPreview != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Quick Look',
                  child: GestureDetector(
                    onTap: onPreview,
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
              const SizedBox(width: 8),
              if (file.backedUp)
                Tooltip(
                  message: 'Matched in local backup folder',
                  child: MacStatusPill(
                    label: 'Backed up',
                    color: p.isDark
                        ? const Color(0xFF6EF09B)
                        : const Color(0xFF0E6B34),
                    background: p.isDark
                        ? const Color(0x3330D158)
                        : const Color(0xFFDCF5E7),
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                dateStr,
                style: TextStyle(
                  fontSize: 11,
                  color: p.textTertiary,
                  fontFeatures: tabularFigures,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 68,
                child: Text(
                  fmtBytes(file.size),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CleanupActionBar extends StatelessWidget {
  final AppController app;
  final CleanupController cleanup;
  final bool backupFirst;
  final bool verifyMd5;
  final ValueChanged<bool> onToggleBackupFirst;
  final ValueChanged<bool> onToggleVerifyMd5;
  final VoidCallback onRun;

  const _CleanupActionBar({
    required this.app,
    required this.cleanup,
    required this.backupFirst,
    required this.verifyMd5,
    required this.onToggleBackupFirst,
    required this.onToggleVerifyMd5,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final totalBytes = cleanup.selectedBytes;
    final notBacked = cleanup.selectedNotBackedUpCount;
    final willBackUp = backupFirst && notBacked > 0;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 11),
      decoration: BoxDecoration(
        color: p.toolbarBg,
        border: Border(top: BorderSide(color: p.borderStrong, width: 1)),
      ),
      child: cleanup.executing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const CupertinoActivityIndicator(radius: 7),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        cleanup.executionPhase,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${(cleanup.executionProgress * 100).round()}%',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textSecondary,
                        fontFeatures: tabularFigures,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 5,
                    child: Stack(
                      children: [
                        Container(color: p.segTrack),
                        FractionallySizedBox(
                          widthFactor: cleanup.executionProgress.clamp(0.0, 1.0),
                          child: Container(color: p.green),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${cleanup.selectedFiles.length} file(s) · ${fmtBytes(totalBytes)} to free',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                      Text(
                        notBacked == 0
                            ? 'All selected files are already backed up locally'
                            : willBackUp
                                ? '$notBacked file(s) will be backed up first before deleting'
                                : '$notBacked file(s) have no local backup (will be permanently deleted)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: !willBackUp && notBacked > 0
                              ? p.amber
                              : p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Back up first',
                      style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                    ),
                    const SizedBox(width: 5),
                    MacSwitch(value: backupFirst, onChanged: onToggleBackupFirst),
                  ],
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Verify MD5',
                      style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                    ),
                    const SizedBox(width: 5),
                    MacSwitch(value: verifyMd5, onChanged: onToggleVerifyMd5),
                  ],
                ),
                const SizedBox(width: 12),
                if (willBackUp)
                  MacPrimaryButton(
                    expand: false,
                    height: 30,
                    onPressed: onRun,
                    child: Text('Back Up & Free ${fmtBytes(totalBytes)}'),
                  )
                else
                  MacPushButton(
                    destructive: true,
                    height: 30,
                    onPressed: onRun,
                    child: Text('Free ${fmtBytes(totalBytes)}'),
                  ),
              ],
            ),
    );
  }
}

class _SummaryBanner extends StatelessWidget {
  final CleanupExecutionSummary summary;
  final VoidCallback onDismiss;

  const _SummaryBanner({required this.summary, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final hasErrors = summary.errors.isNotEmpty;
    final bg = hasErrors ? p.amberSoft : p.greenSoft;
    final fg = hasErrors ? p.amber : p.green;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: p.border, width: 1)),
      ),
      child: Row(
        children: [
          Icon(
            hasErrors
                ? CupertinoIcons.exclamationmark_triangle_fill
                : CupertinoIcons.checkmark_circle_fill,
            size: 14,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Freed ${fmtBytes(summary.freedBytes)} — ${summary.deletedCount} removed'
              '${summary.backedUpCount > 0 ? ', ${summary.backedUpCount} backed up first' : ''}'
              '${summary.skippedCount > 0 ? ', ${summary.skippedCount} kept safe' : ''}'
              '${hasErrors ? ' (${summary.errors.first})' : ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: p.textPrimary,
                fontFeatures: tabularFigures,
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onDismiss,
              child: Icon(CupertinoIcons.xmark, size: 12, color: p.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: active ? p.greenSoft : p.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active ? p.greenBorder : p.borderStrong,
              width: 0.75,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? p.green : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfirmInfoRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _ConfirmInfoRow({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: p.textSecondary, height: 1.38),
          ),
        ),
      ],
    );
  }
}

class _ScanningState extends StatelessWidget {
  final String title;
  final String subtitle;
  const _ScanningState({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CupertinoActivityIndicator(radius: 11),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.exclamationmark_triangle, size: 28, color: p.amber),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(fontSize: 12, color: p.textSecondary)),
          const SizedBox(height: 12),
          MacPushButton(onPressed: onRetry, child: const Text('Try Again')),
        ],
      ),
    );
  }
}

class _IdleScanState extends StatelessWidget {
  final VoidCallback onScan;
  const _IdleScanState({required this.onScan});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(CupertinoIcons.sparkles, size: 30, color: p.green),
          const SizedBox(height: 10),
          Text(
            'Analyze phone storage',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          MacPrimaryButton(
            expand: false,
            height: 32,
            onPressed: onScan,
            child: const Text('Scan Storage'),
          ),
        ],
      ),
    );
  }
}

IconData _iconForKind(CleanupMediaKind kind) => switch (kind) {
      CleanupMediaKind.video => CupertinoIcons.film,
      CleanupMediaKind.photo => CupertinoIcons.photo,
      CleanupMediaKind.audio => CupertinoIcons.music_note,
      CleanupMediaKind.archive => CupertinoIcons.archivebox,
      CleanupMediaKind.document => CupertinoIcons.doc_text,
      CleanupMediaKind.other => CupertinoIcons.doc,
    };
