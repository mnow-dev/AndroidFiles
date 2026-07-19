import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_controller.dart';
import '../scheduler.dart';
import '../settings.dart';
import '../update_checker.dart';

Future<String?> _pickExe(String title) async {
  final r = await FilePicker.pickFiles(
      dialogTitle: title, type: FileType.custom, allowedExtensions: ['exe']);
  return r?.files.firstOrNull?.path;
}

/// Free drive letters, plus whatever is already configured so the combo box
/// always has its own value to show (the mount point is in use precisely when
/// the drive is mounted). A–D are skipped: A/B are floppies by convention and
/// C/D are almost always taken.
List<String> _driveLetterOptions(String current) {
  // A letter is a candidate mount point only if nothing occupies it. Note
  // existsSync() THROWS for a letter assigned to a not-ready device (an empty
  // card reader, a disconnected network or optical drive) rather than
  // returning true — treat that as occupied, not free, and never let it
  // propagate: it would abort building the whole Settings dialog.
  bool isFree(String root) {
    try {
      return !Directory(root).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  final letters = <String>{
    for (var c = 'E'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++)
      if (isFree('${String.fromCharCode(c)}:\\')) '${String.fromCharCode(c)}:',
    if (current.isNotEmpty) current,
  };
  return letters.toList()..sort();
}

Future<void> showSettingsDialog(BuildContext context, AppController app) async {
  final adbPath = TextEditingController(text: app.settings.adbPath);
  final driveExe = TextEditingController(text: app.settings.driveExePath);
  var mountPoint = app.settings.driveMountPoint;
  final mountOptions = _driveLetterOptions(mountPoint);
  var writable = app.settings.driveWritable;
  var checkUpdates = app.settings.checkForUpdates;
  String? testResult;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 540),
        title: const Text('Settings'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          InfoLabel(
            label: 'adb path',
            child: Row(children: [
              Expanded(child: TextBox(controller: adbPath)),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(FluentIcons.open_folder_horizontal, size: 16),
                onPressed: () async {
                  final p = await _pickExe('Locate adb.exe');
                  if (p != null) setState(() => adbPath.text = p);
                },
              ),
              Button(
                onPressed: () async {
                  final r = await Process.run(adbPath.text.trim(), ['version']);
                  setState(() => testResult = r.exitCode == 0
                      ? (r.stdout as String).split('\n').first.trim()
                      : 'Failed: ${r.stderr}');
                },
                child: const Text('Test'),
              ),
            ]),
          ),
          if (testResult != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(testResult!,
                  style: FluentTheme.of(ctx).typography.caption),
            ),
          const SizedBox(height: 12),
          InfoLabel(
            label: 'Explorer drive host (AdbDrive.exe)',
            child: Row(children: [
              Expanded(child: TextBox(controller: driveExe)),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(FluentIcons.open_folder_horizontal, size: 16),
                onPressed: () async {
                  final p = await _pickExe('Locate AdbDrive.exe');
                  if (p != null) setState(() => driveExe.text = p);
                },
              ),
            ]),
          ),
          const SizedBox(height: 12),
          InfoLabel(
            label: 'Drive letter',
            child: ComboBox<String>(
              value: mountPoint,
              isExpanded: true,
              items: [
                for (final d in mountOptions)
                  ComboBoxItem(value: d, child: Text(d)),
              ],
              onChanged: (v) =>
                  v != null ? setState(() => mountPoint = v) : null,
            ),
          ),
          const SizedBox(height: 12),
          InfoLabel(
            label: 'Theme',
            child: ComboBox<String>(
              value: app.themeMode,
              isExpanded: true,
              items: const [
                ComboBoxItem(value: 'light', child: Text('Light')),
                ComboBoxItem(value: 'dark', child: Text('Dark')),
                ComboBoxItem(value: 'system', child: Text('Follow Windows')),
              ],
              onChanged: (v) => v != null ? app.themeMode = v : null,
            ),
          ),
          const SizedBox(height: 12),
          Checkbox(
            checked: checkUpdates,
            content: const Text('Check GitHub for new versions on launch'),
            onChanged: (v) => setState(() => checkUpdates = v ?? true),
          ),
          const SizedBox(height: 12),
          Checkbox(
            checked: writable,
            content: Expanded(
              child: Text(
                'Writable drive (danger): Explorer changes modify the PHONE. '
                'A bug or interrupted transfer can lose data on the device.',
                // Not Colors.red: a fixed mid-red goes muddy against the dark
                // theme's surface. This token is defined per brightness.
                style: TextStyle(
                  color: FluentTheme.of(ctx).resources.systemFillColorCritical,
                ),
              ),
            ),
            onChanged: (v) async {
              if (v != true) {
                setState(() => writable = false);
                return;
              }
              final ok = await showDialog<bool>(
                context: ctx,
                builder: (c2) => ContentDialog(
                  title: const Text('Enable writable drive?'),
                  content: const Text(
                      'Files deleted or overwritten through the drive letter '
                      'are deleted or overwritten ON YOUR PHONE, with no '
                      'recycle bin. Keep backups current. Takes effect on the '
                      'next mount.'),
                  actions: [
                    Button(
                        onPressed: () => Navigator.pop(c2, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c2, true),
                        child: const Text('I understand the risk')),
                  ],
                ),
              );
              setState(() => writable = ok ?? false);
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('adb path changes take effect after an app restart.',
                style: FluentTheme.of(ctx).typography.caption),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('AndroidFiles v$appVersion',
                style: FluentTheme.of(ctx).typography.caption),
          ),
        ]),
        actions: [
          Button(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              app.settings.adbPath = adbPath.text.trim();
              app.settings.driveExePath = driveExe.text.trim();
              app.settings.driveWritable = writable;
              app.settings.driveMountPoint = mountPoint;
              app.settings.checkForUpdates = checkUpdates;
              app.settings.save();
              app.log('Settings saved');
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

Future<void> showRestoreDialog(
    BuildContext context, AppController app, List<String> paths) async {
  final defaultTarget =
      app.checked.length == 1 ? app.checked.first : '/sdcard/Download';
  final target = TextEditingController(text: defaultTarget);

  await showDialog<void>(
    context: context,
    builder: (ctx) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 500),
      title: Text('Push ${paths.length} item(s) to the phone'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final p in paths)
                Text(p, overflow: TextOverflow.ellipsis, maxLines: 1),
            ],
          ),
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: 'Device target folder',
          child: TextBox(controller: target),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('Existing files with the same names are overwritten.',
              style: FluentTheme.of(ctx).typography.caption),
        ),
      ]),
      actions: [
        Button(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            app.enqueueRestore(paths, target.text.trim());
            Navigator.pop(ctx);
          },
          child: const Text('Push'),
        ),
      ],
    ),
  );
}

Future<void> showScheduleDialog(BuildContext context, AppController app) async {
  final profile = app.activeProfile;
  if (profile == null) return;
  final time = TextEditingController(text: profile.scheduleTime ?? '03:00');
  final scheduled = await TaskScheduler.isScheduled(profile.name);
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => ContentDialog(
      title: Text('Schedule "${profile.name}"'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(scheduled
              ? 'Currently scheduled daily at ${profile.scheduleTime ?? '?'}.'
              : 'Not scheduled.'),
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: 'Daily at (HH:MM, 24h)',
          child: TextBox(controller: time),
        ),
        const SizedBox(height: 8),
        Text(
          'Runs via Windows Task Scheduler while you are logged in; the phone '
          'must be connected (USB or Wi-Fi debugging).',
          style: FluentTheme.of(ctx).typography.caption,
        ),
      ]),
      actions: [
        if (scheduled)
          Button(
            onPressed: () async {
              final err = await TaskScheduler.unschedule(profile.name);
              _finishSchedule(app, profile, err, null);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Remove schedule'),
          ),
        Button(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final t = time.text.trim();
            if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t)) return;
            final err = await TaskScheduler.schedule(profile.name, t);
            _finishSchedule(app, profile, err, t);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Schedule daily'),
        ),
      ],
    ),
  );
}

void _finishSchedule(AppController app, Profile profile, String? err, String? time) {
  if (err != null) {
    app.log('schtasks failed: $err');
    return;
  }
  profile.scheduleTime = time;
  app.settings.save();
  app.log(time == null
      ? 'Removed schedule for "${profile.name}"'
      : 'Scheduled "${profile.name}" daily at $time');
}

Future<void> showWifiDialog(BuildContext context, AppController app) async {
  final pairHost = TextEditingController();
  final pairCode = TextEditingController();
  final connectHost = TextEditingController();

  app.startQrPairing();
  await showDialog<void>(
    context: context,
    builder: (ctx) => ContentDialog(
      constraints: const BoxConstraints(maxWidth: 480),
      title: const Text('Wireless debugging'),
      content: ListenableBuilder(
        listenable: app,
        builder: (ctx, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          if (app.qrPayload != null) ...[
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(data: app.qrPayload!, size: 190),
            ),
            const SizedBox(height: 8),
            Text(app.pairingStatus, textAlign: TextAlign.center),
          ],
          if (app.discoveredConnectable.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Discovered on the network:')),
            for (final s in app.discoveredConnectable)
              Row(children: [
                Expanded(
                  child: Text('${s.instance} (${s.address})',
                      overflow: TextOverflow.ellipsis,
                      style: FluentTheme.of(ctx).typography.caption),
                ),
                Button(
                  onPressed: () => app.wifiConnect(s.address),
                  child: const Text('Connect'),
                ),
              ]),
          ],
          const SizedBox(height: 8),
          Expander(
            header: const Text('Manual pair / connect'),
            content: Column(children: [
              Row(children: [
                Expanded(
                  flex: 3,
                  child: InfoLabel(
                    label: 'Pairing ip:port',
                    child: TextBox(controller: pairHost),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: InfoLabel(
                    label: 'Code',
                    child: TextBox(controller: pairCode),
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: () =>
                      app.wifiPair(pairHost.text.trim(), pairCode.text.trim()),
                  child: const Text('Pair'),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: InfoLabel(
                    label: 'Connect ip:port',
                    child: TextBox(controller: connectHost),
                  ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: () => app.wifiConnect(connectHost.text.trim()),
                  child: const Text('Connect'),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      actions: [
        Button(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
  app.stopQrPairing();
}
