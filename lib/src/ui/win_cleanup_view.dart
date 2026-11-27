import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../cleanup_engine.dart';
import '../models.dart';
import '../os.dart';
import '../preview_service.dart';
import 'dialogs.dart';
import 'quick_look_dialog.dart';
import 'win_theme.dart';

enum _WinCleanupTab { proposals, large, duplicates, review }

/// Native Windows 11 Fluent Clean Up Space studio — feature parity with macOS:
/// storage usage bar, intelligent proposals (DCIM videos only, retention
/// windows, downloads, messenger media, caches), largest folders & files,
/// MD5 duplicate finder, and safe "Back up first + verify MD5" execution bar.
class WinCleanupView extends StatefulWidget {
  final AppController app;
  const WinCleanupView({super.key, required this.app});

  @override
  State<WinCleanupView> createState() => _WinCleanupViewState();
}

class _WinCleanupViewState extends State<WinCleanupView> {
  AppController get app => widget.app;
  CleanupController get cleanup => app.cleanup;

  _WinCleanupTab _tab = _WinCleanupTab.proposals;
  bool _backupFirst = true;
  bool _verifyMd5 = true;
  String? _autoScannedKey;

  @override
  void initState() {
    super.initState();
    _maybeAutoScan();
  }

  @override
  void didUpdateWidget(covariant WinCleanupView oldWidget) {
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
      macStyle: false,
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
    if (needBackup && unmountedVolume(dest) != null) return;

    final totalCount = cleanup.selectedFiles.length;
    final totalSize = fmtBytes(cleanup.selectedBytes);
    final toBackUpCount = needBackup ? cleanup.selectedNotBackedUpCount : 0;
    final unbackedDirect = !_backupFirst ? cleanup.selectedNotBackedUpCount : 0;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = WinPalette.of(ctx);
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 460),
          title: Text(
            needBackup
                ? 'Back up and remove $totalCount file(s)?'
                : 'Remove $totalCount file(s) from phone?',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Reclaims $totalSize on ${app.activeVolume.label} (${app.activeRootPath}).',
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
              ),
              const SizedBox(height: 12),
              if (toBackUpCount > 0) ...[
                _InfoNoteRow(
                  icon: FluentIcons.download,
                  color: p.accent,
                  text:
                      '$toBackUpCount file(s) will be backed up first to:\n$dest',
                ),
                const SizedBox(height: 8),
              ],
              if (_verifyMd5 &&
                  (needBackup || cleanup.selectedBackedUpCount > 0)) ...[
                _InfoNoteRow(
                  icon: FluentIcons.verified_brand,
                  color: p.accent,
                  text:
                      'MD5 hashes will be verified against your local backup before any file is deleted.',
                ),
                const SizedBox(height: 8),
              ],
              _InfoNoteRow(
                icon: FluentIcons.warning,
                color: unbackedDirect > 0 ? p.red : p.warnFg,
                text: unbackedDirect > 0
                    ? '$unbackedDirect selected file(s) have NO local backup and will be permanently deleted (Android has no Recycle Bin for ADB removals).'
                    : 'Deleted files are removed permanently from the phone (no Recycle Bin for ADB removals).',
              ),
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: unbackedDirect > 0
                  ? ButtonStyle(
                      backgroundColor: WidgetStateProperty.all(p.red),
                    )
                  : null,
              child: Text(
                needBackup ? 'Back Up & Clean $totalSize' : 'Remove $totalSize',
              ),
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
  }

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final device = app.selected;

    if (device == null) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: WinBentoCard(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.broom, size: 32, color: p.textTertiary),
                const SizedBox(height: 12),
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
                  'Spot large folders, MD5 duplicates, and backed-up DCIM videos you can safely offload.',
                  style: TextStyle(fontSize: 12, color: p.textSecondary),
                ),
                const SizedBox(height: 14),
                Button(
                  onPressed: () => showWifiDialog(context, app),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.wifi, size: 13),
                      SizedBox(width: 6),
                      Text('Wireless debugging'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final reviewLabel = cleanup.selectedPaths.isEmpty
        ? 'Review'
        : 'Review (${cleanup.selectedPaths.length})';

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Storage Summary & Tabs Bento Card ---
          WinBentoCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StorageHeader(
                  app: app,
                  cleanup: cleanup,
                  onScan: () => cleanup.scan(
                    device.serial,
                    app.destination.text,
                    rootPath: app.activeRootPath,
                  ),
                  onPickBackup: _pickBackupDir,
                ),
                const SizedBox(height: 12),
                WinSegmentedControl<_WinCleanupTab>(
                  value: _tab,
                  items: [
                    (_WinCleanupTab.proposals, 'Smart Proposals'),
                    (_WinCleanupTab.large, 'Large Files & Folders'),
                    (_WinCleanupTab.duplicates, 'Duplicates'),
                    (_WinCleanupTab.review, reviewLabel),
                  ],
                  onChanged: (v) => setState(() => _tab = v),
                ),
              ],
            ),
          ),

          if (cleanup.lastSummary != null) ...[
            const SizedBox(height: 10),
            _SummaryCard(
              summary: cleanup.lastSummary!,
              onDismiss: () {
                cleanup.lastSummary = null;
                setState(() {});
              },
            ),
          ],

          const SizedBox(height: 12),

          // --- Main Content Bento Card ---
          Expanded(
            child: WinBentoCard(
              child: cleanup.scanning
                  ? _BusyPane(
                      title:
                          'Scanning ${app.activeRootPath} on ${device.model.isNotEmpty ? device.model : device.serial}…',
                      subtitle:
                          'Indexing file sizes, dates, and comparing against your local backup folder.',
                    )
                  : cleanup.scanError != null
                      ? _ErrorPane(
                          message: cleanup.scanError!,
                          onRetry: () => cleanup.scan(
                            device.serial,
                            app.destination.text,
                            rootPath: app.activeRootPath,
                          ),
                        )
                      : !cleanup.hasScan
                          ? _IdlePane(
                              onScan: () => cleanup.scan(
                                device.serial,
                                app.destination.text,
                                rootPath: app.activeRootPath,
                              ),
                            )
                          : switch (_tab) {
                              _WinCleanupTab.proposals =>
                                _ProposalsTab(cleanup: cleanup),
                              _WinCleanupTab.large => _LargeFilesTab(
                                  cleanup: cleanup,
                                  onPreview: _openQuickLook,
                                ),
                              _WinCleanupTab.duplicates => _DuplicatesTab(
                                  cleanup: cleanup,
                                  onFind: () =>
                                      cleanup.findDuplicates(device.serial),
                                  onPreview: _openQuickLook,
                                ),
                              _WinCleanupTab.review => _ReviewTab(
                                  cleanup: cleanup,
                                  onPreview: _openQuickLook,
                                ),
                            },
            ),
          ),

          // --- Sticky Bottom Cleanup Action Bar ---
          if (cleanup.selectedPaths.isNotEmpty || cleanup.executing) ...[
            const SizedBox(height: 12),
            _CleanupActionBar(
              app: app,
              cleanup: cleanup,
              backupFirst: _backupFirst,
              verifyMd5: _verifyMd5,
              onBackupFirstChanged: (v) => setState(() => _backupFirst = v),
              onVerifyMd5Changed: (v) => setState(() => _verifyMd5 = v),
              onPickBackup: _pickBackupDir,
              onRun: _confirmAndRun,
            ),
          ],
        ],
      ),
    );
  }
}

class _StorageHeader extends StatelessWidget {
  final AppController app;
  final CleanupController cleanup;
  final VoidCallback onScan;
  final VoidCallback onPickBackup;

  const _StorageHeader({
    required this.app,
    required this.cleanup,
    required this.onScan,
    required this.onPickBackup,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final sp = cleanup.deviceSpace;
    final usedFrac =
        sp != null && sp.totalBytes > 0 ? (sp.usedBytes / sp.totalBytes).clamp(0.0, 1.0) : 0.0;
    final selFrac = sp != null && sp.totalBytes > 0
        ? (cleanup.selectedBytes / sp.totalBytes).clamp(0.0, usedFrac)
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              app.activeVolume.isExternal
                  ? FluentIcons.hard_drive
                  : FluentIcons.cell_phone,
              size: 15,
              color: p.accent,
            ),
            const SizedBox(width: 8),
            Text(
              '${app.activeVolume.label} (${app.activeRootPath})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(width: 10),
            if (sp != null)
              Text(
                '${fmtBytes(sp.usedBytes)} used of ${fmtBytes(sp.totalBytes)} · ${fmtBytes(sp.freeBytes)} free',
                style: TextStyle(
                  fontSize: 12,
                  color: p.textSecondary,
                  fontFeatures: winTabularFigures,
                ),
              ),
            const Spacer(),
            Button(
              onPressed: onPickBackup,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.open_folder_horizontal, size: 13),
                  const SizedBox(width: 6),
                  Text(
                    cleanup.scannedBackupDir != null
                        ? 'Backup matched'
                        : 'Set backup folder…',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: cleanup.scanning ? null : onScan,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.refresh, size: 13),
                  SizedBox(width: 6),
                  Text('Rescan', style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        if (sp != null && sp.totalBytes > 0) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 7,
              child: LayoutBuilder(
                builder: (_, c) => Stack(
                  children: [
                    Container(color: p.barTrack),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: c.maxWidth * (usedFrac - selFrac).clamp(0.0, 1.0),
                      child: Container(color: p.barUsed),
                    ),
                    if (selFrac > 0)
                      Positioned(
                        left: c.maxWidth * (usedFrac - selFrac).clamp(0.0, 1.0),
                        top: 0,
                        bottom: 0,
                        width: (c.maxWidth * selFrac).clamp(4.0, c.maxWidth),
                        child: Container(color: p.accent),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProposalsTab extends StatelessWidget {
  final CleanupController cleanup;
  const _ProposalsTab({required this.cleanup});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final proposals = cleanup.proposals;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: p.cardSubBg,
            border: Border(bottom: BorderSide(color: p.borderSoft, width: 1)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Retention:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              WinSegmentedControl<RetentionWindow>(
                pill: true,
                value: cleanup.retention,
                items: [
                  for (final w in RetentionWindow.values) (w, w.label),
                ],
                onChanged: cleanup.setRetention,
              ),
              ToggleSwitch(
                checked: cleanup.onlyBackedUpProposals,
                onChanged: cleanup.setOnlyBackedUpProposals,
                content: Text(
                  'Only already backed up',
                  style: TextStyle(fontSize: 12, color: p.textSecondary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: proposals.isEmpty
              ? Center(
                  child: Text(
                    'No cleanup proposals match the current retention filter.',
                    style: TextStyle(fontSize: 13, color: p.textSecondary),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(14),
                  itemCount: proposals.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final prop = proposals[i];
                    final selected = cleanup.isProposalSelected(prop);
                    return Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: selected ? p.rowSelectedBg : p.cardSubBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? p.accentBorder : p.border,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Checkbox(
                            checked: selected,
                            onChanged: (_) => cleanup.toggleProposal(prop),
                          ),
                          const SizedBox(width: 12),
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
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: p.textPrimary,
                                        ),
                                      ),
                                    ),
                                    WinPill(
                                      label: fmtBytes(prop.totalBytes),
                                      color: p.accentSoftFg,
                                      background: p.accentSoft,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  prop.subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: p.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  children: [
                                    WinPill(
                                      label: '${prop.files.length} files',
                                      color: p.neutralPillFg,
                                      background: p.neutralPillBg,
                                    ),
                                    if (prop.backedUpCount > 0)
                                      WinPill(
                                        label: prop.allBackedUp
                                            ? 'All backed up'
                                            : '${prop.backedUpCount} backed up',
                                        color: p.accentSoftFg,
                                        background: p.accentSoft,
                                      ),
                                    if (prop.notBackedUpCount > 0)
                                      WinPill(
                                        label:
                                            '${prop.notBackedUpCount} need backup',
                                        color: p.warnFg,
                                        background: p.warnBg,
                                      ),
                                    Text(
                                      prop.reason,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p.textTertiary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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

class _LargeFilesTab extends StatelessWidget {
  final CleanupController cleanup;
  final void Function(List<ScannedFile> files, int index) onPreview;
  const _LargeFilesTab({required this.cleanup, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final files = cleanup.filteredLargeFiles;
    final totalFolderBytes =
        cleanup.folders.fold<int>(0, (s, f) => s + f.totalBytes);

    return Row(
      children: [
        // Left: Largest folders breakdown
        SizedBox(
          width: 270,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.cardSubBg,
                  border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 1),
                    right: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      'Largest Folders',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    if (cleanup.folderFilter != null)
                      HyperlinkButton(
                        onPressed: () => cleanup.setFolderFilter(null),
                        child: const Text('All', style: TextStyle(fontSize: 11)),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: p.borderSoft, width: 1),
                    ),
                  ),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: cleanup.folders.length,
                    itemBuilder: (_, i) {
                      final f = cleanup.folders[i];
                      final active = cleanup.folderFilter == f.relPath;
                      final frac = totalFolderBytes > 0
                          ? (f.totalBytes / totalFolderBytes).clamp(0.0, 1.0)
                          : 0.0;
                      return GestureDetector(
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
                            color: active
                                ? p.rowSelectedBg
                                : const Color(0x00000000),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    FluentIcons.folder_fill,
                                    size: 13,
                                    color: Color(0xFFF2B824),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      f.relPath,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: p.textPrimary,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    fmtBytes(f.totalBytes),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: p.textSecondary,
                                      fontFeatures: winTabularFigures,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: SizedBox(
                                  height: 4,
                                  child: Stack(
                                    children: [
                                      Container(color: p.barTrack),
                                      FractionallySizedBox(
                                        widthFactor: frac,
                                        child: Container(color: p.accent),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        // Right: Filtered large files
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: p.cardSubBg,
                  border: Border(
                    bottom: BorderSide(color: p.borderSoft, width: 1),
                  ),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    WinSegmentedControl<int>(
                      pill: true,
                      value: cleanup.minLargeBytes,
                      items: const [
                        (0, 'All'),
                        (5 * 1024 * 1024, '≥ 5 MB'),
                        (20 * 1024 * 1024, '≥ 20 MB'),
                        (100 * 1024 * 1024, '≥ 100 MB'),
                      ],
                      onChanged: cleanup.setMinLargeBytes,
                    ),
                    ToggleSwitch(
                      checked: cleanup.largeVideosOnly,
                      onChanged: cleanup.setLargeVideosOnly,
                      content: Text(
                        'Videos only',
                        style: TextStyle(fontSize: 12, color: p.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: files.isEmpty
                    ? Center(
                        child: Text(
                          'No files match this filter.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: p.textSecondary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: files.length,
                        itemBuilder: (_, i) => _ScannedFileRow(
                          file: files[i],
                          checked:
                              cleanup.selectedPaths.contains(files[i].relPath),
                          onToggle: () => cleanup.toggleFile(files[i].relPath),
                          onPreview: () => onPreview(files, i),
                        ),
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
    final p = WinPalette.of(context);
    if (cleanup.scanningDuplicates) {
      final frac = cleanup.dupTotalToHash > 0
          ? cleanup.dupHashed / cleanup.dupTotalToHash
          : null;
      return Center(
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Hashing size-matched candidates (MD5)…',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              ProgressBar(value: frac != null ? frac * 100 : null),
              const SizedBox(height: 6),
              Text(
                '${cleanup.dupHashed} / ${cleanup.dupTotalToHash} files',
                style: TextStyle(fontSize: 11.5, color: p.textSecondary),
              ),
            ],
          ),
        ),
      );
    }

    if (!cleanup.duplicatesScanned) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.copy, size: 30, color: p.textTertiary),
            const SizedBox(height: 10),
            Text(
              'Find exact duplicate files (MD5)',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Only files ≥ 100 KB that share an exact byte size are hashed on the device.',
              style: TextStyle(fontSize: 12, color: p.textSecondary),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: onFind,
              child: const Text('Find Duplicates'),
            ),
          ],
        ),
      );
    }

    if (cleanup.duplicates.isEmpty) {
      return Center(
        child: Text(
          'No duplicate files found.',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
      );
    }

    final wasted =
        cleanup.duplicates.fold<int>(0, (s, g) => s + g.wastedBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: p.cardSubBg,
            border: Border(bottom: BorderSide(color: p.borderSoft, width: 1)),
          ),
          child: Row(
            children: [
              Text(
                '${cleanup.duplicates.length} duplicate group(s) · ${fmtBytes(wasted)} reclaimable',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const Spacer(),
              Button(
                onPressed: () {
                  cleanup.selectFiles([
                    for (final g in cleanup.duplicates) ...g.redundantCopies,
                  ]);
                },
                child: const Text(
                  'Select all redundant copies',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: cleanup.duplicates.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final g = cleanup.duplicates[i];
              return Container(
                decoration: BoxDecoration(
                  color: p.cardSubBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.border, width: 1),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                      child: Row(
                        children: [
                          Text(
                            '${g.files.length} identical copies · ${fmtBytes(g.fileSize)} each',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: p.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          WinPill(
                            label: 'Save ${fmtBytes(g.wastedBytes)}',
                            color: p.accentSoftFg,
                            background: p.accentSoft,
                          ),
                        ],
                      ),
                    ),
                    for (var j = 0; j < g.files.length; j++)
                      _ScannedFileRow(
                        file: g.files[j],
                        checked:
                            cleanup.selectedPaths.contains(g.files[j].relPath),
                        keepRecommended: j == 0,
                        onToggle: () => cleanup.toggleFile(g.files[j].relPath),
                        onPreview: () => onPreview(g.files, j),
                      ),
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

class _ReviewTab extends StatelessWidget {
  final CleanupController cleanup;
  final void Function(List<ScannedFile> files, int index) onPreview;
  const _ReviewTab({required this.cleanup, required this.onPreview});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final selected = cleanup.selectedFiles;
    if (selected.isEmpty) {
      return Center(
        child: Text(
          'No files selected for cleanup yet.',
          style: TextStyle(fontSize: 13, color: p.textSecondary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: p.cardSubBg,
            border: Border(bottom: BorderSide(color: p.borderSoft, width: 1)),
          ),
          child: Row(
            children: [
              Text(
                '${selected.length} file(s) selected · ${fmtBytes(cleanup.selectedBytes)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const Spacer(),
              HyperlinkButton(
                onPressed: cleanup.clearSelection,
                child: const Text('Clear all', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: selected.length,
            itemBuilder: (_, i) => _ScannedFileRow(
              file: selected[i],
              checked: true,
              onToggle: () => cleanup.toggleFile(selected[i].relPath),
              onPreview: () => onPreview(selected, i),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScannedFileRow extends StatelessWidget {
  final ScannedFile file;
  final bool checked;
  final bool keepRecommended;
  final VoidCallback onToggle;
  final VoidCallback? onPreview;

  const _ScannedFileRow({
    required this.file,
    required this.checked,
    this.keepRecommended = false,
    required this.onToggle,
    this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final dirText = file.parentDir.isEmpty
        ? file.rootPath
        : '${file.rootPath}/${file.parentDir}';
    return GestureDetector(
      onDoubleTap: onPreview,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: checked ? p.rowSelectedBg : const Color(0x00000000),
          border: Border(bottom: BorderSide(color: p.borderSoft, width: 0.75)),
        ),
        child: Row(
          children: [
            Checkbox(checked: checked, onChanged: (_) => onToggle()),
            const SizedBox(width: 10),
            Icon(
              switch (file.kind) {
                CleanupMediaKind.video => FluentIcons.play,
                CleanupMediaKind.photo => FluentIcons.photo2,
                CleanupMediaKind.audio => FluentIcons.music_in_collection,
                CleanupMediaKind.archive => FluentIcons.archive,
                _ => FluentIcons.page,
              },
              size: 14,
              color: p.textSecondary,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: p.textPrimary,
                    ),
                  ),
                  Text(
                    dirText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: winMonoFont,
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
                child: IconButton(
                  icon: Icon(
                    FluentIcons.view,
                    size: 13.5,
                    color: p.textSecondary,
                  ),
                  onPressed: onPreview,
                ),
              ),
            ],
            if (keepRecommended) ...[
              const SizedBox(width: 8),
              WinPill(
                label: 'Keep',
                color: p.accentSoftFg,
                background: p.accentSoft,
              ),
            ],
            if (file.backedUp) ...[
              const SizedBox(width: 8),
              WinPill(
                label: 'Backed up',
                color: p.accentSoftFg,
                background: p.accentSoft,
              ),
            ],
            const SizedBox(width: 10),
            Text(
              fmtBytes(file.size),
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
                fontFeatures: winTabularFigures,
              ),
            ),
          ],
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
  final ValueChanged<bool> onBackupFirstChanged;
  final ValueChanged<bool> onVerifyMd5Changed;
  final VoidCallback onPickBackup;
  final VoidCallback onRun;

  const _CleanupActionBar({
    required this.app,
    required this.cleanup,
    required this.backupFirst,
    required this.verifyMd5,
    required this.onBackupFirstChanged,
    required this.onVerifyMd5Changed,
    required this.onPickBackup,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    if (cleanup.executing) {
      return WinBentoCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    cleanup.executionPhase,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                Text(
                  '${(cleanup.executionProgress * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    color: p.textSecondary,
                    fontFeatures: winTabularFigures,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ProgressBar(value: cleanup.executionProgress * 100),
          ],
        ),
      );
    }

    final needBackup = backupFirst && cleanup.selectedNotBackedUpCount > 0;
    final sizeStr = fmtBytes(cleanup.selectedBytes);
    return WinBentoCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          ToggleSwitch(
            checked: backupFirst,
            onChanged: onBackupFirstChanged,
            content: const Text('Back up first', style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 14),
          ToggleSwitch(
            checked: verifyMd5,
            onChanged: onVerifyMd5Changed,
            content: const Text('Verify MD5', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          Text(
            '${cleanup.selectedPaths.length} selected · $sizeStr',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
              fontFeatures: winTabularFigures,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onRun,
            child: Text(
              needBackup ? 'Back Up & Clean ($sizeStr)' : 'Clean Up ($sizeStr)',
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final CleanupExecutionSummary summary;
  final VoidCallback onDismiss;
  const _SummaryCard({required this.summary, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final hasErr = summary.errors.isNotEmpty;
    return WinBentoCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(
            hasErr ? FluentIcons.warning : FluentIcons.completed_solid,
            size: 16,
            color: hasErr ? p.warnFg : p.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Freed ${fmtBytes(summary.freedBytes)} — ${summary.deletedCount} removed, ${summary.backedUpCount} backed up, ${summary.skippedCount} skipped'
              '${hasErr ? ' (${summary.errors.first})' : ''}',
              style: TextStyle(fontSize: 12.5, color: p.textPrimary),
            ),
          ),
          IconButton(
            icon: const Icon(FluentIcons.chrome_close, size: 11),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _BusyPane extends StatelessWidget {
  final String title;
  final String subtitle;
  const _BusyPane({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ProgressRing(),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            style: TextStyle(fontSize: 12, color: p.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(FluentIcons.warning, size: 28, color: p.warnFg),
          const SizedBox(height: 10),
          Text(message, style: TextStyle(fontSize: 12.5, color: p.textPrimary)),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _IdlePane extends StatelessWidget {
  final VoidCallback onScan;
  const _IdlePane({required this.onScan});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton(
        onPressed: onScan,
        child: const Text('Scan Storage'),
      ),
    );
  }
}

class _InfoNoteRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _InfoNoteRow({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 14, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: p.textPrimary, height: 1.4),
          ),
        ),
      ],
    );
  }
}
