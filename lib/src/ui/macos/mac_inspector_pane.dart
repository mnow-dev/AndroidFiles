import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../../l10n/app_localizations.dart';
import '../../app_controller.dart';
import '../../backup_engine.dart';
import '../../disk_space.dart';
import '../../models.dart';
import '../../os.dart';
import 'mac_theme.dart';

/// Proposal A right inspector: Backup Target card (destination, visual capacity
/// bar, Mirror/Snapshot segmented control, native toggle switches, emerald CTA)
/// stacked cleanly above the Transfer Queue (or 3-step onboarding card).
class MacInspectorPane extends StatelessWidget {
  final AppController app;
  const MacInspectorPane({super.key, required this.app});

  Future<void> _browse() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Backup destination',
    );
    if (dir != null) app.setDestination(dir);
  }

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    final selectedCount = app.checked.length;
    final missingVol = unmountedVolume(app.destination.text);
    final space = driveSpaceForPath(app.destination.text);
    final selBytes = app.selectionBytes;
    final tooBig =
        space != null && selBytes != null && selBytes > space.freeBytes;
    final canStart = selectedCount > 0 &&
        app.destination.text.trim().isNotEmpty &&
        app.selected != null &&
        missingVol == null;

    final spaceStatusText = missingVol != null
        ? l.driveNotConnected(missingVol)
        : space != null
            ? (tooBig
                ? '${l.driveFree(fmtBytes(space.freeBytes), space.root)} · ${l.selectionMayNotFit}'
                : l.driveFree(fmtBytes(space.freeBytes), space.root))
            : null;
    final spaceStatusColor =
        (missingVol != null || tooBig) ? p.amber : p.green;

    return Container(
      color: p.inspectorBg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
        children: [
          // --- BACKUP TARGET CARD ---
          Container(
            padding: const EdgeInsets.all(12),
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
                    Text(
                      l.sectionBackup,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.55,
                        color: p.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (spaceStatusText != null)
                      Expanded(
                        child: Text(
                          spaceStatusText,
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: spaceStatusColor,
                            fontFeatures: tabularFigures,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Expanded(
                      child: MacTextField(
                        controller: app.destination,
                        placeholder: l.destinationPlaceholderMac,
                        prefix: const MacFolderIcon(width: 14, height: 11.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Tooltip(
                      message: l.browseDestination,
                      child: MacPushButton(
                        onPressed: _browse,
                        child: const Text('Choose…'),
                      ),
                    ),
                  ],
                ),
                if (space != null && space.totalBytes > 0) ...[
                  const SizedBox(height: 9),
                  _CapacityBar(
                    space: space,
                    selectedBytes: selBytes ?? 0,
                    tooBig: tooBig,
                  ),
                ],
                const SizedBox(height: 10),
                MacSegmentedControl<BackupLayout>(
                  value: app.layout,
                  items: [
                    (BackupLayout.mirror, l.layoutMirror),
                    (BackupLayout.snapshot, l.layoutSnapshot),
                  ],
                  onChanged: (v) => app.layout = v,
                ),
                const SizedBox(height: 6),
                Text(
                  app.layout == BackupLayout.mirror
                      ? l.mirrorHint
                      : l.snapshotHint,
                  style: TextStyle(
                    fontSize: 11,
                    color: p.textTertiary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                _OptionToggleRow(
                  title: l.incremental,
                  value: app.incremental,
                  onChanged: (v) => app.incremental = v,
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: l.skipClutterTooltip(
                    app.settings.clutterPatterns.join(', '),
                  ),
                  child: _OptionToggleRow(
                    title: l.skipClutter,
                    subtitle: app.settings.clutterPatterns.take(2).join(', ') +
                        (app.settings.clutterPatterns.length > 2 ? '…' : ''),
                    value: app.skipClutter,
                    onChanged: (v) => app.skipClutter = v,
                  ),
                ),
                const SizedBox(height: 8),
                Tooltip(
                  message: l.verifyAfterBackupHint,
                  child: _OptionToggleRow(
                    title: l.verifyAfterBackup,
                    value: app.autoVerify,
                    onChanged: (v) => app.autoVerify = v,
                  ),
                ),
                const SizedBox(height: 12),
                MacPrimaryButton(
                  onPressed: canStart ? app.startBackup : null,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(CupertinoIcons.arrow_down_to_line, size: 15),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          selectedCount == 0
                              ? l.selectFoldersToBackUp
                              : l.backUpItems(selectedCount),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // --- TRANSFER QUEUE HEADER ---
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              children: [
                Text(
                  l.sectionQueue,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.55,
                    color: p.textTertiary,
                  ),
                ),
                const Spacer(),
                if (app.engine.jobs.any((j) => j.status.isTerminal))
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: app.engine.clearFinished,
                      child: Text(
                        l.clearFinished,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          if (app.engine.jobs.isEmpty)
            _MacOnboardingCard(app: app)
          else
            for (final job in app.engine.jobs) ...[
              _MacJobCard(engine: app.engine, job: job),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _CapacityBar extends StatelessWidget {
  final DriveSpace space;
  final int selectedBytes;
  final bool tooBig;

  const _CapacityBar({
    required this.space,
    required this.selectedBytes,
    required this.tooBig,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final total = space.totalBytes.toDouble();
    final used = (space.totalBytes - space.freeBytes).clamp(0, space.totalBytes);
    final usedFrac = (used / total).clamp(0.0, 1.0);
    final freeFrac = (1.0 - usedFrac).clamp(0.0, 1.0);
    final selFrac = selectedBytes > 0
        ? (selectedBytes / total).clamp(0.015, freeFrac)
        : 0.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            return Stack(
              children: [
                Container(color: p.segTrack),
                Row(
                  children: [
                    Container(width: w * usedFrac, color: p.capacityUsed),
                    if (selFrac > 0)
                      Container(
                        width: w * selFrac,
                        color: tooBig ? p.amber : p.green,
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _OptionToggleRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _OptionToggleRow({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(fontSize: 12, color: p.textPrimary),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        MacSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _MacOnboardingCard extends StatelessWidget {
  final AppController app;
  const _MacOnboardingCard({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final l = AppLocalizations.of(context);
    final deviceOk = app.selected != null;
    final foldersOk = app.checked.isNotEmpty;
    final destOk = app.destination.text.trim().isNotEmpty &&
        unmountedVolume(app.destination.text) == null;

    Widget step(int n, bool done, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(top: 0.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? p.green : const Color(0x00000000),
                  border: done ? null : Border.all(color: p.borderStrong, width: 1.2),
                ),
                alignment: Alignment.center,
                child: done
                    ? Icon(
                        CupertinoIcons.check_mark,
                        size: 10.5,
                        color: p.greenButtonText,
                      )
                    : Text(
                        '$n',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: p.textSecondary,
                        ),
                      ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: done ? p.textSecondary : p.textPrimary,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.backupIn3Steps,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          step(
            1,
            deviceOk,
            deviceOk ? l.stepPhoneConnected : l.stepConnectPhone,
          ),
          step(2, foldersOk, l.stepTickFolders),
          step(3, destOk, l.stepChooseDestination),
          const SizedBox(height: 10),
          Container(height: 1, color: p.border),
          const SizedBox(height: 8),
          Text(
            l.onboardingTipsMac,
            style: TextStyle(
              fontSize: 11,
              color: p.textTertiary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _MacJobCard extends StatelessWidget {
  final BackupEngine engine;
  final BackupJob job;

  const _MacJobCard({required this.engine, required this.job});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final p = MacPalette.of(context);
        final l = AppLocalizations.of(context);
        final active = job.status == JobStatus.running;
        final verifying = job.status == JobStatus.verifying;

        final (statusColor, statusBg, statusLabel, liveDot) =
            _statusVisuals(p, l, job.status, job.paused);

        final progressValue = job.deviceFileCount > 0 && job.verifiedFiles > 0
            ? job.verifiedFiles / job.deviceFileCount
            : job.deviceFileCount > 0 && job.hashedFiles > 0
                ? job.hashedFiles / job.deviceFileCount
                : (active ? job.progress : null);

        return Container(
          padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active ? p.greenBorder : p.border,
              width: 0.8,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (job.isRestore)
                    Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Icon(
                        CupertinoIcons.arrow_up_to_line,
                        size: 12,
                        color: p.textSecondary,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      job.isRestore
                          ? '${job.localSource} → ${job.source.path}'
                          : job.source.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  MacStatusPill(
                    label: statusLabel,
                    color: statusColor,
                    background: statusBg,
                    showDot: liveDot,
                  ),
                  if (job.canPause || job.paused)
                    _SmallJobAction(
                      icon: job.paused
                          ? CupertinoIcons.play_fill
                          : CupertinoIcons.pause_fill,
                      tooltip: job.paused ? l.resume : l.pause,
                      onPressed: job.paused ? job.resume : job.pause,
                    ),
                  if (!job.status.isTerminal)
                    _SmallJobAction(
                      icon: CupertinoIcons.xmark,
                      tooltip: l.cancelJob,
                      onPressed: job.cancel,
                    ),
                  if (job.status == JobStatus.failed ||
                      job.status == JobStatus.cancelled)
                    _SmallJobAction(
                      icon: CupertinoIcons.refresh,
                      tooltip: l.retry,
                      onPressed: () => engine.retry(job),
                    ),
                  if (!job.isRestore &&
                      (job.status == JobStatus.done ||
                          job.status == JobStatus.doneWithWarnings))
                    _SmallJobAction(
                      icon: job.deepVerified
                          ? CupertinoIcons.checkmark_seal_fill
                          : CupertinoIcons.checkmark_seal,
                      color: job.deepVerified ? p.green : null,
                      tooltip: job.deepVerified
                          ? l.verifiedTooltip
                          : l.deepVerifyTooltip,
                      onPressed: () => engine.deepVerify(job),
                    ),
                ],
              ),
              if (active || verifying) ...[
                const SizedBox(height: 7),
                _MacProgressBar(value: progressValue),
                const SizedBox(height: 6),
                _buildActiveStats(p, l, active),
                if (job.currentFile != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    job.currentFile!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: macMonoFont,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ],
              if (job.status == JobStatus.queued) ...[
                const SizedBox(height: 4),
                Text(
                  l.statusQueued,
                  style: TextStyle(fontSize: 11, color: p.textTertiary),
                ),
              ],
              if (job.status == JobStatus.done ||
                  job.status == JobStatus.doneWithWarnings) ...[
                const SizedBox(height: 5),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (job.filesStreamed > 0)
                            l.transferredFiles(
                              job.filesStreamed,
                              fmtBytes(job.doneBytes),
                            )
                          else
                            l.transferredBytes(fmtBytes(job.doneBytes)),
                          if (job.skippedFiles > 0)
                            l.unchangedSkipped(job.skippedFiles),
                          if (job.ignoredFiles > 0)
                            l.filesIgnored(job.ignoredFiles),
                          if (job.linkedFiles > 0)
                            l.hardlinked(job.linkedFiles),
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: p.textSecondary,
                          fontFeatures: tabularFigures,
                        ),
                      ),
                    ),
                    if (job.deepVerified) ...[
                      const SizedBox(width: 8),
                      Text(
                        'MD5 OK',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: p.green,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
              if (job.error != null) ...[
                const SizedBox(height: 5),
                Text(
                  job.error!,
                  style: TextStyle(fontSize: 11, color: p.red),
                ),
              ],
              if (job.warnings.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  job.warnings.join('\n'),
                  style: TextStyle(fontSize: 11, color: p.amber),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildActiveStats(MacPalette p, AppLocalizations l, bool active) {
    final style = TextStyle(
      fontSize: 11,
      color: p.textSecondary,
      fontFeatures: tabularFigures,
    );
    if (active) {
      final eta = fmtEta(job.etaSeconds);
      final left = [
        '${fmtBytes(job.doneBytes)} / ${fmtBytes(job.totalBytes)}',
        fmtSpeed(job.bytesPerSec),
        if (job.deviceFileCount - job.skippedFiles > 0)
          l.filesProgress(
            job.filesStreamed,
            job.deviceFileCount - job.skippedFiles,
          ),
        if (job.skippedFiles > 0) l.filesSkipped(job.skippedFiles),
        if (job.ignoredFiles > 0) l.filesIgnored(job.ignoredFiles),
      ].join(' · ');
      return Row(
        children: [
          Expanded(
            child: Text(
              left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (eta.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(l.etaLabel(eta), style: style),
          ],
        ],
      );
    }

    final text = job.verifiedFiles > 0
        ? [
            l.verifyingMd5(job.verifiedFiles, job.deviceFileCount),
            if (fmtEta(job.verifyEtaSeconds).isNotEmpty)
              l.etaLabel(fmtEta(job.verifyEtaSeconds)),
          ].join(' · ')
        : job.hashedFiles > 0
            ? [
                l.hashingOnDevice(
                  job.hashedFiles,
                  job.deviceFileCount > 0 ? job.deviceFileCount : '?',
                ),
                if (fmtEta(job.verifyEtaSeconds).isNotEmpty)
                  l.etaLabel(fmtEta(job.verifyEtaSeconds)),
              ].join(' · ')
            : job.linkedFiles > 0
                ? l.linkingUnchanged(job.linkedFiles)
                : l.preparingEllipsis;
    return Text(text, style: style);
  }

  (Color, Color, String, bool) _statusVisuals(
    MacPalette p,
    AppLocalizations l,
    JobStatus status,
    bool paused,
  ) {
    if (paused) return (p.textSecondary, p.segTrack, l.statusPaused, false);
    return switch (status) {
      JobStatus.running => (p.green, p.greenSoft, l.statusCopying, true),
      JobStatus.verifying => (p.green, p.greenSoft, l.statusVerifying, true),
      JobStatus.measuring => (p.textSecondary, p.segTrack, l.statusMeasuring, false),
      JobStatus.queued => (p.textSecondary, p.segTrack, l.statusQueued, false),
      JobStatus.done => (p.green, p.greenSoft, l.statusDone, false),
      JobStatus.doneWithWarnings =>
        (p.amber, p.amberSoft, l.statusDoneWarnings, false),
      JobStatus.failed => (p.red, p.redSoft, l.statusFailed, false),
      JobStatus.cancelled => (p.textSecondary, p.segTrack, l.statusCancelled, false),
    };
  }
}

class _MacProgressBar extends StatelessWidget {
  final double? value;
  const _MacProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final v = value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 5,
        child: Stack(
          children: [
            Container(color: p.segTrack),
            if (v != null)
              FractionallySizedBox(
                widthFactor: v.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [p.green, p.greenBright],
                    ),
                  ),
                ),
              )
            else
              Container(color: p.green.withValues(alpha: 0.45)),
          ],
        ),
      ),
    );
  }
}

class _SmallJobAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onPressed;

  const _SmallJobAction({
    required this.icon,
    required this.tooltip,
    this.color,
    required this.onPressed,
  });

  @override
  State<_SmallJobAction> createState() => _SmallJobActionState();
}

class _SmallJobActionState extends State<_SmallJobAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceHover : const Color(0x00000000),
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 12,
              color: widget.color ?? (_hovered ? p.textPrimary : p.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
