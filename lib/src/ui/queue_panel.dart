import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../app_controller.dart';
import '../backup_engine.dart';
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
    final name = TextEditingController(text: app.activeProfile?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Save profile'),
        content: TextBox(
          controller: name,
          autofocus: true,
          placeholder: 'Profile name',
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text),
            child: const Text('Save'),
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
              child: Text('PROFILE', style: sectionCaption),
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
                            placeholder:
                                'Profiles (saved selections) appear here',
                            placeholderStyle: TextStyle(
                              color: hintColor(context),
                            ),
                          )
                        : ComboBox<Profile>(
                            value: app.activeProfile,
                            placeholder: const Text('Load a saved profile'),
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
                    message: 'Save current selection as profile',
                    child: IconButton(
                      icon: const Icon(FluentIcons.save, size: 16),
                      onPressed: selectedCount == 0
                          ? null
                          : () => _saveProfileDialog(context),
                    ),
                  ),
                  Tooltip(
                    message: app.activeProfile?.scheduleTime != null
                        ? 'Scheduled daily at ${app.activeProfile!.scheduleTime} — edit'
                        : 'Schedule daily backup of this profile',
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
                    message: 'Delete profile',
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
              child: Text('BACKUP', style: sectionCaption),
            ),
            Card(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoLabel(
                    label: 'Destination',
                    child: Row(
                      children: [
                        Expanded(
                          child: TextBox(
                            controller: app.destination,
                            placeholder:
                                r'Folder on this PC, e.g. E:\PhoneBackup',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'Browse for a destination folder',
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
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 130,
                        child: ComboBox<BackupLayout>(
                          value: app.layout,
                          isExpanded: true,
                          items: const [
                            ComboBoxItem(
                              value: BackupLayout.mirror,
                              child: Text('Mirror'),
                            ),
                            ComboBoxItem(
                              value: BackupLayout.snapshot,
                              child: Text('Snapshot'),
                            ),
                          ],
                          onChanged: (v) => v != null ? app.layout = v : null,
                        ),
                      ),
                      Checkbox(
                        checked: app.incremental,
                        onChanged: (v) => app.incremental = v ?? true,
                        content: const Text('Incremental (skip unchanged)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    app.layout == BackupLayout.mirror
                        ? 'Mirror: keeps one up-to-date copy in the destination.'
                        : 'Snapshot: a new dated folder per run — unchanged files are '
                              'linked, not copied, so history costs almost no space.',
                    style: FluentTheme.of(context).typography.caption?.copyWith(
                      color: hintColor(context),
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
                                ? 'Select folders to back up'
                                : 'Back up $selectedCount item(s)',
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
                Text('QUEUE', style: sectionCaption),
                const Spacer(),
                HyperlinkButton(
                  onPressed: app.engine.jobs.any((j) => j.status.isTerminal)
                      ? app.engine.clearFinished
                      : null,
                  child: const Text('Clear finished'),
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

/// Onboarding checklist shown while the queue is empty; steps tick
/// themselves off as the user completes them.
class _GettingStarted extends StatelessWidget {
  final AppController app;
  const _GettingStarted({required this.app});

  @override
  Widget build(BuildContext context) {
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
              'Back up your phone in 3 steps',
              style: theme.typography.bodyStrong,
            ),
            const SizedBox(height: 10),
            step(
              1,
              deviceOk,
              deviceOk
                  ? 'Phone connected'
                  : 'Connect your phone (USB or the Wi-Fi icon above)',
            ),
            step(
              2,
              foldersOk,
              'Tick the folders to save in the tree on the left',
            ),
            step(3, destOk, 'Choose where to store them, then press Back up'),
            const SizedBox(height: 16),
            Text(
              'Tips: drag files from Explorer onto the tree to copy them TO the '
              'phone · save your selection as a profile for one-click re-runs '
              'and daily scheduling · the disk icon up top shows the phone '
              'directly in Explorer',
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
                        message: job.paused ? 'Resume' : 'Pause',
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
                        message: 'Cancel',
                        child: IconButton(
                          icon: const Icon(FluentIcons.chrome_close, size: 12),
                          onPressed: job.cancel,
                        ),
                      ),
                    if (job.status == JobStatus.failed ||
                        job.status == JobStatus.cancelled)
                      Tooltip(
                        message: 'Retry',
                        child: IconButton(
                          icon: const Icon(FluentIcons.refresh, size: 12),
                          onPressed: () => engine.retry(job),
                        ),
                      ),
                    if (!job.isRestore &&
                        (job.status == JobStatus.done ||
                            job.status == JobStatus.doneWithWarnings))
                      Tooltip(
                        message: 'Deep verify (md5 of every file — slow)',
                        child: IconButton(
                          icon: const Icon(
                            FluentIcons.verified_brand,
                            size: 12,
                          ),
                          onPressed: () => engine.deepVerify(job),
                        ),
                      ),
                  ],
                ),
                if (active || job.status == JobStatus.verifying) ...[
                  const SizedBox(height: 6),
                  ProgressBar(value: active ? job.progress * 100 : null),
                  const SizedBox(height: 4),
                  Text(
                    [
                      '${fmtBytes(job.doneBytes)} / ${fmtBytes(job.totalBytes)}',
                      if (active) fmtSpeed(job.bytesPerSec),
                      if (active && fmtEta(job.etaSeconds).isNotEmpty)
                        'ETA ${fmtEta(job.etaSeconds)}',
                      if (job.deviceFileCount > 0)
                        '${job.filesStreamed}/${job.deviceFileCount} files',
                      if (job.linkedFiles > 0) '${job.linkedFiles} linked',
                    ].join(' · '),
                    style: theme.typography.caption,
                  ),
                  if (active && job.currentFile != null)
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
                        '${fmtBytes(job.doneBytes)} transferred',
                        if (job.skippedFiles > 0)
                          '${job.skippedFiles} unchanged skipped',
                        if (job.linkedFiles > 0)
                          '${job.linkedFiles} hardlinked',
                      ].join(' · '),
                      style: theme.typography.caption?.copyWith(
                        color: secondary,
                      ),
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
    final Color color = paused
        ? Colors.grey[80]
        : switch (status) {
            JobStatus.done => Colors.green,
            JobStatus.doneWithWarnings => Colors.orange,
            JobStatus.failed => Colors.red,
            JobStatus.cancelled => Colors.grey[80],
            _ => FluentTheme.of(context).accentColor,
          };
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        paused ? 'paused' : status.label,
        style: FluentTheme.of(
          context,
        ).typography.caption?.copyWith(color: color),
      ),
    );
  }
}
