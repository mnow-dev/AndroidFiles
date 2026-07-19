import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import '../backup_engine.dart';
import '../disk_space.dart';
import '../models.dart';
import '../settings.dart';
import 'dialogs.dart';

/// Explanatory captions are the quietest text in the app: you read them once
/// and then want them out of the way, so they sit a step below the secondary
/// colour the rest of the de-emphasised text uses.
Color hintColor(BuildContext context) =>
    FluentTheme.of(context).resources.textFillColorTertiary;

/// Destination + options + profiles + the backup queue.
class QueuePanel extends StatelessWidget {
  final AppController app;

  const QueuePanel({super.key, required this.app});

  Future<void> _browse() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Backup destination',
    );
    if (dir != null) app.destination.text = dir;
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
    final l = AppLocalizations.of(context);
    final selectedCount = app.checked.length;
    final sectionCaption = FluentTheme.of(context).typography.caption?.copyWith(
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: FluentTheme.of(context).resources.textFillColorPrimary,
    );
    // The whole panel scrolls: with the log pane open (or a short window)
    // a rigid Column overflows.
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Text(l.sectionProfile, style: sectionCaption),
            ),
            Card(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    // fluent_ui #combo_box crashes if an EMPTY popup opens
                    // (clamp(0, negative) in _ComboBoxResizeClipper), so show
                    // an inert placeholder until a profile exists.
                    child: app.settings.profiles.isEmpty
                        // readOnly (not disabled): disabled placeholder text
                        // is too faint to read.
                        ? TextBox(
                            readOnly: true,
                            placeholder: l.profilesPlaceholder,
                            placeholderStyle: TextStyle(
                              color: hintColor(context),
                            ),
                          )
                        : ComboBox<Profile>(
                            value: app.activeProfile,
                            placeholder: Text(l.loadProfile),
                            isExpanded: true,
                            items: [
                              for (final p in app.settings.profiles)
                                ComboBoxItem(
                                  value: p,
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (p) =>
                                p != null ? app.applyProfile(p) : null,
                          ),
                  ),
                  Tooltip(
                    message: l.saveProfileTooltip,
                    child: IconButton(
                      icon: const Icon(FluentIcons.save, size: 16),
                      onPressed: selectedCount == 0
                          ? null
                          : () => _saveProfileDialog(context),
                    ),
                  ),
                  Tooltip(
                    message: app.activeProfile?.scheduleTime != null
                        ? l.scheduledDailyEdit(app.activeProfile!.scheduleTime!)
                        : l.scheduleProfileTooltip,
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.clock,
                        size: 16,
                        color: app.activeProfile?.scheduleTime != null
                            ? Colors.green
                            : null,
                      ),
                      onPressed: app.activeProfile == null
                          ? null
                          : () => showScheduleDialog(context, app),
                    ),
                  ),
                  Tooltip(
                    message: l.deleteProfileTooltip,
                    child: IconButton(
                      icon: const Icon(FluentIcons.delete, size: 16),
                      onPressed: app.activeProfile == null
                          ? null
                          : () => app.deleteProfile(app.activeProfile!),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 4),
              child: Text(l.sectionBackup, style: sectionCaption),
            ),
            Card(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoLabel(
                    label: l.destination,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextBox(
                            controller: app.destination,
                            placeholder: l.destinationPlaceholder,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: l.browseDestination,
                          child: IconButton(
                            icon: const Icon(
                              FluentIcons.open_folder_horizontal,
                              size: 16,
                            ),
                            onPressed: _browse,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _SpaceLine(app: app),
                  const SizedBox(height: 8),
                  Expander(
                    initiallyExpanded: true,
                    header: Text(l.options),
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 130,
                              child: ComboBox<BackupLayout>(
                                value: app.layout,
                                isExpanded: true,
                                items: [
                                  ComboBoxItem(
                                    value: BackupLayout.mirror,
                                    child: Text(l.layoutMirror),
                                  ),
                                  ComboBoxItem(
                                    value: BackupLayout.snapshot,
                                    child: Text(l.layoutSnapshot),
                                  ),
                                ],
                                onChanged: (v) =>
                                    v != null ? app.layout = v : null,
                              ),
                            ),
                            Checkbox(
                              checked: app.incremental,
                              onChanged: (v) => app.incremental = v ?? true,
                              content: Text(l.incremental),
                            ),
                            Tooltip(
                              message: l.skipClutterTooltip(
                                app.settings.clutterPatterns.join(', '),
                              ),
                              child: Checkbox(
                                checked: app.skipClutter,
                                onChanged: (v) => app.skipClutter = v ?? false,
                                content: Text(l.skipClutter),
                              ),
                            ),
                            Tooltip(
                              message: l.verifyAfterBackupHint,
                              child: Checkbox(
                                checked: app.autoVerify,
                                onChanged: (v) => app.autoVerify = v ?? false,
                                content: Text(l.verifyAfterBackup),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          app.layout == BackupLayout.mirror
                              ? l.mirrorHint
                              : l.snapshotHint,
                          style: FluentTheme.of(context).typography.caption
                              ?.copyWith(color: hintColor(context)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed:
                        selectedCount == 0 ||
                            app.destination.text.trim().isEmpty ||
                            app.selected == null
                        ? null
                        : app.startBackup,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(FluentIcons.download, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            selectedCount == 0
                                ? l.selectFoldersToBackUp
                                : l.backUpItems(selectedCount),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(l.sectionQueue, style: sectionCaption),
                const Spacer(),
                HyperlinkButton(
                  onPressed: app.engine.jobs.any((j) => j.status.isTerminal)
                      ? app.engine.clearFinished
                      : null,
                  child: Text(l.clearFinished),
                ),
              ],
            ),
          ],
        ),
        if (app.engine.jobs.isEmpty)
          _GettingStarted(app: app)
        else
          for (final job in app.engine.jobs)
            _JobTile(engine: app.engine, job: job),
      ],
    );
  }
}

/// Free space on the destination drive and the measured size of the current
/// selection — a quiet caption that turns amber when the selection may not fit.
class _SpaceLine extends StatelessWidget {
  final AppController app;
  const _SpaceLine({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final space = driveSpaceForPath(app.destination.text);
    final sel = app.selectionBytes;

    final parts = <String>[
      if (space != null) l.driveFree(fmtBytes(space.freeBytes), space.root),
      if (app.measuringSelection)
        l.measuringSize
      else if (sel != null && sel > 0)
        l.selectedSize(fmtBytes(sel)),
    ];
    if (parts.isEmpty) return const SizedBox(height: 4);

    final tooBig = space != null && sel != null && sel > space.freeBytes;
    final color = tooBig ? Colors.orange : hintColor(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Row(
        children: [
          if (tooBig) ...[
            Icon(FluentIcons.warning, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              tooBig
                  ? '${parts.join('  ·  ')}  ·  ${l.selectionMayNotFit}'
                  : parts.join('  ·  '),
              style: theme.typography.caption?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Onboarding checklist shown while the queue is empty; steps tick
/// themselves off as the user completes them.
class _GettingStarted extends StatelessWidget {
  final AppController app;
  const _GettingStarted({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = FluentTheme.of(context);
    final secondary = theme.resources.textFillColorSecondary;
    final deviceOk = app.selected != null;
    final foldersOk = app.checked.isNotEmpty;
    final destOk = app.destination.text.trim().isNotEmpty;

    Widget step(int n, bool done, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          done
              ? Icon(
                  FluentIcons.skype_circle_check,
                  size: 16,
                  color: Colors.green,
                )
              : Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: secondary),
                  ),
                  child: Text(
                    '$n',
                    style: theme.typography.caption?.copyWith(color: secondary),
                  ),
                ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: done
                  ? theme.typography.body?.copyWith(color: secondary)
                  : theme.typography.body,
            ),
          ),
        ],
      ),
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          // Lives inside the panel ListView now: must shrink-wrap, an
          // unbounded-height Column with center alignment cannot lay out.
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 24),
            Text(
              l.backupIn3Steps,
              style: theme.typography.bodyStrong,
            ),
            const SizedBox(height: 10),
            step(
              1,
              deviceOk,
              deviceOk ? l.stepPhoneConnected : l.stepConnectPhone,
            ),
            step(2, foldersOk, l.stepTickFolders),
            step(3, destOk, l.stepChooseDestination),
            const SizedBox(height: 16),
            Text(
              l.onboardingTips,
              style: theme.typography.caption?.copyWith(
                color: hintColor(context),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
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
        final theme = FluentTheme.of(context);
        final secondary = theme.resources.textFillColorSecondary;
        final active = job.status == JobStatus.running;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Card(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (job.isRestore)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(FluentIcons.upload, size: 12),
                      ),
                    Expanded(
                      child: Text(
                        job.isRestore
                            ? '${job.localSource} → ${job.source.path}'
                            : job.source.path,
                        overflow: TextOverflow.ellipsis,
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
                            size: 12,
                            color: job.deepVerified ? Colors.green : null,
                          ),
                          onPressed: () => engine.deepVerify(job),
                        ),
                      ),
                  ],
                ),
                if (active || job.status == JobStatus.verifying) ...[
                  const SizedBox(height: 6),
                  ProgressBar(
                    // Verify shows file-by-file progress (device hashing, then
                    // local checking); the transfer shows byte progress.
                    value: job.deviceFileCount > 0 && job.verifiedFiles > 0
                        ? job.verifiedFiles / job.deviceFileCount * 100
                        : job.deviceFileCount > 0 && job.hashedFiles > 0
                        ? job.hashedFiles / job.deviceFileCount * 100
                        : (active ? job.progress * 100 : null),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active
                        // Transfer: byte/file progress.
                        ? [
                            '${fmtBytes(job.doneBytes)} / ${fmtBytes(job.totalBytes)}',
                            fmtSpeed(job.bytesPerSec),
                            if (fmtEta(job.etaSeconds).isNotEmpty)
                              l.etaLabel(fmtEta(job.etaSeconds)),
                            // Count against the files actually being copied
                            // (total minus skipped), not the whole device —
                            // otherwise an incremental run looks stuck at e.g.
                            // 0/775 when it only has 14 to copy.
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
                        // Verifying: hashing on the device, then checking each
                        // local file; "Preparing…" only until the first count.
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
                    style: theme.typography.caption,
                  ),
                  if ((active || job.status == JobStatus.verifying) &&
                      job.currentFile != null)
                    Text(
                      job.currentFile!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption?.copyWith(
                        color: secondary,
                      ),
                    ),
                ],
                if (job.status == JobStatus.done ||
                    job.status == JobStatus.doneWithWarnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      [
                        // Restore (adb push) doesn't track a file count, so
                        // only fold it in when we have one.
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
                      style: theme.typography.caption?.copyWith(
                        color: secondary,
                      ),
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
                          color: Colors.green,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          l.verifiedAllMatch,
                          style: theme.typography.caption?.copyWith(
                            color: Colors.green,
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
                      style: theme.typography.caption?.copyWith(
                        color: Colors.red,
                      ),
                    ),
                  ),
                if (job.warnings.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      job.warnings.join('\n'),
                      style: theme.typography.caption?.copyWith(
                        color: Colors.orange,
                      ),
                    ),
                  ),
              ],
            ),
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
    final Color color = paused
        ? Colors.grey[80]
        : switch (status) {
            JobStatus.done => Colors.green,
            JobStatus.doneWithWarnings => Colors.orange,
            JobStatus.failed => Colors.red,
            JobStatus.cancelled => Colors.grey[80],
            _ => FluentTheme.of(context).accentColor,
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        paused ? l.statusPaused : label,
        style: FluentTheme.of(
          context,
        ).typography.caption?.copyWith(color: color),
      ),
    );
  }
}
