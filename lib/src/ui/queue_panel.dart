import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import '../backup_engine.dart';
import '../disk_space.dart';
import '../models.dart';
import '../os.dart';
import 'win_theme.dart';

/// Explanatory captions helper retained for dialogs.dart compatibility.
Color hintColor(BuildContext context) =>
    FluentTheme.of(context).resources.textFillColorTertiary;

/// Right column of the 3-Bento-Card workspace:
///   • Section 2 (top Bento card): Backup Destination, capacity bar, Mirror /
///     Snapshot segmented control, Fluent ToggleSwitches, emerald CTA
///   • Section 3 (bottom Bento card): Transfer Queue (or 3-step onboarding)
class QueuePanel extends StatelessWidget {
  final AppController app;

  const QueuePanel({super.key, required this.app});

  Future<void> _browse() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Backup destination',
    );
    if (dir != null) app.setDestination(dir);
  }

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final l = AppLocalizations.of(context);
    final selectedCount = app.checked.length;
    final space = driveSpaceForPath(app.destination.text);
    final missing = unmountedVolume(app.destination.text);
    final selBytes = app.selectionBytes;
    final tooBig =
        space != null && selBytes != null && selBytes > space.freeBytes;

    final spaceText = missing != null
        ? l.driveNotConnected(missing)
        : space != null
            ? (tooBig
                ? '${l.driveFree(fmtBytes(space.freeBytes), space.root)} · ${l.selectionMayNotFit}'
                : l.driveFree(fmtBytes(space.freeBytes), space.root))
            : null;
    final spaceColor = (missing != null || tooBig) ? p.warnFg : p.accentSoftFg;

    final canStart = selectedCount > 0 &&
        app.destination.text.trim().isNotEmpty &&
        app.selected != null &&
        missing == null;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        // --- Section 2: Backup Destination Bento Card ---
        WinBentoCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WinSectionLabel(
                l.sectionBackup,
                trailing: spaceText != null
                    ? Flexible(
                        child: Text(
                          spaceText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: spaceColor,
                            fontFeatures: winTabularFigures,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextBox(
                      controller: app.destination,
                      placeholder: Platform.isMacOS
                          ? l.destinationPlaceholderMac
                          : l.destinationPlaceholder,
                      prefix: const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(
                          FluentIcons.folder_fill,
                          size: 14,
                          color: Color(0xFFF2B824),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: l.browseDestination,
                    child: Button(
                      onPressed: _browse,
                      child: const Text('Browse…'),
                    ),
                  ),
                ],
              ),
              if (space != null && space.totalBytes > 0) ...[
                const SizedBox(height: 10),
                _WinCapacityBar(
                  space: space,
                  selectedBytes: selBytes ?? 0,
                  tooBig: tooBig,
                ),
              ],
              const SizedBox(height: 10),
              WinSegmentedControl<BackupLayout>(
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
                  color: p.textSecondary,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              _OptionSwitchRow(
                title: l.incremental,
                checked: app.incremental,
                onChanged: (v) => app.incremental = v,
              ),
              Tooltip(
                message: l.skipClutterTooltip(
                  app.settings.clutterPatterns.join(', '),
                ),
                child: _OptionSwitchRow(
                  title: l.skipClutter,
                  subtitle: app.settings.clutterPatterns.take(2).join(', '),
                  checked: app.skipClutter,
                  onChanged: (v) => app.skipClutter = v,
                ),
              ),
              Tooltip(
                message: l.verifyAfterBackupHint,
                child: _OptionSwitchRow(
                  title: l.verifyAfterBackup,
                  checked: app.autoVerify,
                  onChanged: (v) => app.autoVerify = v,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: canStart ? app.startBackup : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(FluentIcons.download, size: 15),
                      const SizedBox(width: 7),
                      Text(
                        selectedCount == 0
                            ? l.selectFoldersToBackUp
                            : l.backUpItems(selectedCount),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // --- Section 3: Transfer Queue Bento Card ---
        WinBentoCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WinSectionLabel(
                l.sectionQueue,
                trailing: HyperlinkButton(
                  onPressed: app.engine.jobs.any((j) => j.status.isTerminal)
                      ? app.engine.clearFinished
                      : null,
                  child: Text(
                    l.clearFinished,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (app.engine.jobs.isEmpty)
                _GettingStarted(app: app)
              else
                for (final job in app.engine.jobs)
                  _JobTile(engine: app.engine, job: job),
            ],
          ),
        ),
      ],
    );
  }
}

class _OptionSwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool checked;
  final ValueChanged<bool> onChanged;

  const _OptionSwitchRow({
    required this.title,
    this.subtitle,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 12.5, color: p.textPrimary),
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
          const SizedBox(width: 8),
          ToggleSwitch(checked: checked, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _WinCapacityBar extends StatelessWidget {
  final DriveSpace space;
  final int selectedBytes;
  final bool tooBig;

  const _WinCapacityBar({
    required this.space,
    required this.selectedBytes,
    required this.tooBig,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final total = space.totalBytes.toDouble();
    final usedFrac = ((space.totalBytes - space.freeBytes) / total).clamp(0.0, 1.0);
    final selFrac = (selectedBytes / total).clamp(0.0, 1.0 - usedFrac);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 5,
        child: LayoutBuilder(
          builder: (_, c) => Stack(
            children: [
              Container(color: p.barTrack),
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: c.maxWidth * usedFrac,
                child: Container(color: p.barUsed),
              ),
              if (selFrac > 0)
                Positioned(
                  left: c.maxWidth * usedFrac,
                  top: 0,
                  bottom: 0,
                  width: (c.maxWidth * selFrac).clamp(3.0, c.maxWidth),
                  child: Container(color: tooBig ? p.warnFg : p.accent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Onboarding checklist shown while the queue is empty.
class _GettingStarted extends StatelessWidget {
  final AppController app;
  const _GettingStarted({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = WinPalette.of(context);
    final deviceOk = app.selected != null;
    final foldersOk = app.checked.isNotEmpty;
    final destOk = app.destination.text.trim().isNotEmpty;

    Widget step(int n, bool done, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              done
                  ? Icon(
                      FluentIcons.completed_solid,
                      size: 16,
                      color: p.accent,
                    )
                  : Container(
                      width: 17,
                      height: 17,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: p.textTertiary),
                      ),
                      child: Text(
                        '$n',
                        style: TextStyle(fontSize: 10.5, color: p.textSecondary),
                      ),
                    ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: done ? p.textSecondary : p.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.backupIn3Steps,
            style: TextStyle(
              fontSize: 13,
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
          Text(
            Platform.isMacOS ? l.onboardingTipsMac : l.onboardingTips,
            style: TextStyle(fontSize: 11, color: p.textTertiary, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final BackupEngine engine;
  final BackupJob job;

  const _JobTile({required this.engine, required this.job});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final l = AppLocalizations.of(context);
        final p = WinPalette.of(context);
        final active = job.status == JobStatus.running;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: p.cardSubBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? p.accentBorder : p.border,
              width: 1,
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
                        FluentIcons.upload,
                        size: 12,
                        color: p.textSecondary,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      job.isRestore
                          ? '${job.localSource} → ${job.source.path}'
                          : job.source.path,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  _StatusChip(status: job.status, paused: job.paused),
                  if (job.canPause || job.paused)
                    Tooltip(
                      message: job.paused ? l.resume : l.pause,
                      child: IconButton(
                        icon: Icon(
                          job.paused ? FluentIcons.play : FluentIcons.pause,
                          size: 12,
                        ),
                        onPressed: job.paused ? job.resume : job.pause,
                      ),
                    ),
                  if (!job.status.isTerminal)
                    Tooltip(
                      message: l.cancelJob,
                      child: IconButton(
                        icon: const Icon(FluentIcons.chrome_close, size: 12),
                        onPressed: job.cancel,
                      ),
                    ),
                  if (job.status == JobStatus.failed ||
                      job.status == JobStatus.cancelled)
                    Tooltip(
                      message: l.retry,
                      child: IconButton(
                        icon: const Icon(FluentIcons.refresh, size: 12),
                        onPressed: () => engine.retry(job),
                      ),
                    ),
                  if (!job.isRestore &&
                      (job.status == JobStatus.done ||
                          job.status == JobStatus.doneWithWarnings))
                    Tooltip(
                      message: job.deepVerified
                          ? l.verifiedTooltip
                          : l.deepVerifyTooltip,
                      child: IconButton(
                        icon: Icon(
                          FluentIcons.verified_brand,
                          size: 13,
                          color: job.deepVerified ? p.accent : null,
                        ),
                        onPressed: () => engine.deepVerify(job),
                      ),
                    ),
                ],
              ),
              if (active || job.status == JobStatus.verifying) ...[
                const SizedBox(height: 7),
                ProgressBar(
                  value: job.deviceFileCount > 0 && job.verifiedFiles > 0
                      ? job.verifiedFiles / job.deviceFileCount * 100
                      : job.deviceFileCount > 0 && job.hashedFiles > 0
                          ? job.hashedFiles / job.deviceFileCount * 100
                          : (active ? job.progress * 100 : null),
                ),
                const SizedBox(height: 5),
                Text(
                  active
                      ? [
                          '${fmtBytes(job.doneBytes)} / ${fmtBytes(job.totalBytes)}',
                          fmtSpeed(job.bytesPerSec),
                          if (fmtEta(job.etaSeconds).isNotEmpty)
                            l.etaLabel(fmtEta(job.etaSeconds)),
                          if (job.deviceFileCount - job.skippedFiles > 0)
                            l.filesProgress(
                              job.filesStreamed,
                              job.deviceFileCount - job.skippedFiles,
                            ),
                          if (job.skippedFiles > 0)
                            l.filesSkipped(job.skippedFiles),
                          if (job.ignoredFiles > 0)
                            l.filesIgnored(job.ignoredFiles),
                        ].join(' · ')
                      : job.verifiedFiles > 0
                          ? [
                              l.verifyingMd5(
                                job.verifiedFiles,
                                job.deviceFileCount,
                              ),
                              if (fmtEta(job.verifyEtaSeconds).isNotEmpty)
                                l.etaLabel(fmtEta(job.verifyEtaSeconds)),
                            ].join(' · ')
                          : job.hashedFiles > 0
                              ? [
                                  l.hashingOnDevice(
                                    job.hashedFiles,
                                    job.deviceFileCount > 0
                                        ? job.deviceFileCount
                                        : '?',
                                  ),
                                  if (fmtEta(job.verifyEtaSeconds).isNotEmpty)
                                    l.etaLabel(fmtEta(job.verifyEtaSeconds)),
                                ].join(' · ')
                              : job.linkedFiles > 0
                                  ? l.linkingUnchanged(job.linkedFiles)
                                  : l.preparingEllipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textSecondary,
                    fontFeatures: winTabularFigures,
                  ),
                ),
                if (job.currentFile != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      job.currentFile!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: winMonoFont,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
              ],
              if (job.status == JobStatus.done ||
                  job.status == JobStatus.doneWithWarnings)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
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
                    style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                  ),
                ),
              if (job.deepVerified)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        FluentIcons.completed_solid,
                        size: 12,
                        color: p.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l.verifiedAllMatch,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: p.accentSoftFg,
                        ),
                      ),
                    ],
                  ),
                ),
              if (job.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    job.error!,
                    style: TextStyle(fontSize: 11.5, color: p.red),
                  ),
                ),
              if (job.warnings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    job.warnings.join('\n'),
                    style: TextStyle(fontSize: 11.5, color: p.warnFg),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  final JobStatus status;
  final bool paused;
  const _StatusChip({required this.status, this.paused = false});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final p = WinPalette.of(context);
    final (Color fg, Color bg) = paused
        ? (p.neutralPillFg, p.neutralPillBg)
        : switch (status) {
            JobStatus.done => (p.accentSoftFg, p.accentSoft),
            JobStatus.doneWithWarnings => (p.warnFg, p.warnBg),
            JobStatus.failed => (p.red, p.redSoft),
            JobStatus.cancelled => (p.neutralPillFg, p.neutralPillBg),
            _ => (p.accentSoftFg, p.accentSoft),
          };
    final label = switch (status) {
      JobStatus.queued => l.statusQueued,
      JobStatus.measuring => l.statusMeasuring,
      JobStatus.running => l.statusCopying,
      JobStatus.verifying => l.statusVerifying,
      JobStatus.done => l.statusDone,
      JobStatus.doneWithWarnings => l.statusDoneWarnings,
      JobStatus.failed => l.statusFailed,
      JobStatus.cancelled => l.statusCancelled,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: WinPill(
        label: paused ? l.statusPaused : label,
        color: fg,
        background: bg,
      ),
    );
  }
}
