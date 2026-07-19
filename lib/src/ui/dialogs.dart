import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show showLicensePage;
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import '../scheduler.dart';
import '../settings.dart';
import '../update_checker.dart';

Future<String?> _pickExe(String title) async {
  final r = await FilePicker.pickFiles(
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: ['exe'],
  );
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
  final clutterPatterns = TextEditingController(
    text: app.settings.clutterPatterns.join('\n'),
  );
  final scrollController = ScrollController();
  String? testResult;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = FluentTheme.of(ctx);
        final l = AppLocalizations.of(ctx);
        final caption = theme.typography.caption;
        final sectionCaption = caption?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: theme.resources.textFillColorPrimary,
        );
        Widget section(String title, List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 14, bottom: 4),
              child: Text(title.toUpperCase(), style: sectionCaption),
            ),
            Card(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ],
        );
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 480),
          title: Text(l.settingsTitle),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 440,
              maxWidth: 440,
              maxHeight: MediaQuery.of(ctx).size.height * 0.62,
            ),
            // Always-visible, grabbable scrollbar (the fluent overlay one is
            // thin and fiddly); equal left/right gutters keep it centred.
            child: RawScrollbar(
              controller: scrollController,
              thumbVisibility: true,
              interactive: true,
              thickness: 8,
              minThumbLength: 40,
              radius: const Radius.circular(4),
              thumbColor: theme.resources.textFillColorSecondary.withValues(
                alpha: 0.4,
              ),
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  ctx,
                ).copyWith(scrollbars: false),
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      section(l.settingsDevice, [
                        InfoLabel(
                          label: l.settingsAdbPath,
                          child: Row(
                            children: [
                              Expanded(child: TextBox(controller: adbPath)),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(
                                  FluentIcons.open_folder_horizontal,
                                  size: 16,
                                ),
                                onPressed: () async {
                                  final p = await _pickExe(l.locateAdbExe);
                                  if (p != null) {
                                    setState(() => adbPath.text = p);
                                  }
                                },
                              ),
                              Button(
                                onPressed: () async {
                                  final r = await Process.run(
                                    adbPath.text.trim(),
                                    ['version'],
                                  );
                                  setState(
                                    () => testResult = r.exitCode == 0
                                        ? (r.stdout as String)
                                              .split('\n')
                                              .first
                                              .trim()
                                        : l.testFailed('${r.stderr}'),
                                  );
                                },
                                child: Text(l.test),
                              ),
                            ],
                          ),
                        ),
                        if (testResult != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(testResult!, style: caption),
                            ),
                          ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(l.adbRestartNote, style: caption),
                        ),
                      ]),
                      section(l.settingsExplorerDrive, [
                        InfoLabel(
                          label: l.driveHost,
                          child: Row(
                            children: [
                              Expanded(child: TextBox(controller: driveExe)),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(
                                  FluentIcons.open_folder_horizontal,
                                  size: 16,
                                ),
                                onPressed: () async {
                                  final p = await _pickExe(l.locateDriveExe);
                                  if (p != null) {
                                    setState(() => driveExe.text = p);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        InfoLabel(
                          label: l.driveLetter,
                          child: ComboBox<String>(
                            value: mountPoint,
                            isExpanded: true,
                            items: [
                              for (final d in mountOptions)
                                ComboBoxItem(value: d, child: Text(d)),
                            ],
                            onChanged: (v) => v != null
                                ? setState(() => mountPoint = v)
                                : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Checkbox(
                          checked: writable,
                          content: Expanded(
                            child: Text(
                              l.writableDriveWarning,
                              // Not Colors.red: a fixed mid-red goes muddy against
                              // the dark theme's surface. This token is per-brightness.
                              style: TextStyle(
                                color: theme.resources.systemFillColorCritical,
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
                                title: Text(l.enableWritableTitle),
                                content: Text(l.enableWritableBody),
                                actions: [
                                  Button(
                                    onPressed: () => Navigator.pop(c2, false),
                                    child: Text(l.cancel),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c2, true),
                                    child: Text(l.understandRisk),
                                  ),
                                ],
                              ),
                            );
                            setState(() => writable = ok ?? false);
                          },
                        ),
                      ]),
                      section(l.settingsBackups, [
                        InfoLabel(
                          label: l.clutterLabel,
                          child: TextBox(
                            controller: clutterPatterns,
                            maxLines: 4,
                            placeholder: '.thumbnails\nAndroid/data',
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(l.clutterNote, style: caption),
                        ),
                      ]),
                      section(l.settingsAppearance, [
                        InfoLabel(
                          label: l.language,
                          child: ComboBox<String>(
                            value: app.localeCode,
                            isExpanded: true,
                            items: [
                              ComboBoxItem(
                                value: '',
                                child: Text(l.systemDefault),
                              ),
                              for (final loc
                                  in AppLocalizations.supportedLocales)
                                ComboBoxItem(
                                  value: loc.languageCode,
                                  child: Text(
                                    lookupAppLocalizations(loc).languageName,
                                  ),
                                ),
                            ],
                            onChanged: (v) =>
                                v != null ? app.localeCode = v : null,
                          ),
                        ),
                        const SizedBox(height: 10),
                        InfoLabel(
                          label: l.theme,
                          child: ComboBox<String>(
                            value: app.themeMode,
                            isExpanded: true,
                            items: [
                              ComboBoxItem(
                                value: 'light',
                                child: Text(l.themeLight),
                              ),
                              ComboBoxItem(
                                value: 'dark',
                                child: Text(l.themeDark),
                              ),
                              ComboBoxItem(
                                value: 'system',
                                child: Text(l.themeSystem),
                              ),
                            ],
                            onChanged: (v) =>
                                v != null ? app.themeMode = v : null,
                          ),
                        ),
                      ]),
                      section(l.settingsUpdates, [
                        Checkbox(
                          checked: checkUpdates,
                          content: Text(l.checkUpdatesLabel),
                          onChanged: (v) =>
                              setState(() => checkUpdates = v ?? true),
                        ),
                      ]),
                      section(l.settingsAbout, [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            l.aboutLicensed(appVersion),
                            style: caption,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: HyperlinkButton(
                            onPressed: () => showLicensePage(
                              context: ctx,
                              applicationName: 'AndroidFiles',
                              applicationVersion: 'v$appVersion',
                            ),
                            child: Text(l.openSourceLicenses),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
          actions: [
            Button(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
            FilledButton(
              onPressed: () {
                app.settings.adbPath = adbPath.text.trim();
                app.settings.driveExePath = driveExe.text.trim();
                app.settings.driveWritable = writable;
                app.settings.driveMountPoint = mountPoint;
                app.settings.checkForUpdates = checkUpdates;
                app.settings.clutterPatterns = clutterPatterns.text
                    .split('\n')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
                app.settings.save();
                app.log('Settings saved');
                Navigator.pop(ctx);
              },
              child: Text(l.save),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> showRestoreDialog(
  BuildContext context,
  AppController app,
  List<String> paths,
) async {
  final defaultTarget = app.checked.length == 1
      ? app.checked.first
      : '/sdcard/Download';
  final target = TextEditingController(text: defaultTarget);

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final l = AppLocalizations.of(ctx);
      return ContentDialog(
        constraints: const BoxConstraints(maxWidth: 500),
        title: Text(l.pushItemsTitle(paths.length)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              label: l.deviceTargetFolder,
              child: TextBox(controller: target),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l.overwriteNote,
                style: FluentTheme.of(ctx).typography.caption,
              ),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              app.enqueueRestore(paths, target.text.trim());
              Navigator.pop(ctx);
            },
            child: Text(l.push),
          ),
        ],
      );
    },
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
    builder: (ctx) {
      final l = AppLocalizations.of(ctx);
      return ContentDialog(
        title: Text(l.scheduleTitle(profile.name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                scheduled
                    ? l.currentlyScheduled(profile.scheduleTime ?? '?')
                    : l.notScheduled,
              ),
            ),
            const SizedBox(height: 12),
            InfoLabel(
              label: l.dailyAtLabel,
              child: TextBox(controller: time),
            ),
            const SizedBox(height: 8),
            Text(
              l.scheduleNote,
              style: FluentTheme.of(ctx).typography.caption,
            ),
          ],
        ),
        actions: [
          if (scheduled)
            Button(
              onPressed: () async {
                final err = await TaskScheduler.unschedule(profile.name);
                _finishSchedule(app, profile, err, null);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(l.removeSchedule),
            ),
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final t = time.text.trim();
              if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(t)) return;
              final err = await TaskScheduler.schedule(profile.name, t);
              _finishSchedule(app, profile, err, t);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: Text(l.scheduleDaily),
          ),
        ],
      );
    },
  );
}

void _finishSchedule(
  AppController app,
  Profile profile,
  String? err,
  String? time,
) {
  if (err != null) {
    app.log('schtasks failed: $err');
    return;
  }
  profile.scheduleTime = time;
  app.settings.save();
  app.log(
    time == null
        ? 'Removed schedule for "${profile.name}"'
        : 'Scheduled "${profile.name}" daily at $time',
  );
}

Future<void> showWifiDialog(BuildContext context, AppController app) async {
  final pairHost = TextEditingController();
  final pairCode = TextEditingController();
  final connectHost = TextEditingController();

  app.startQrPairing();
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final l = AppLocalizations.of(ctx);
      return ContentDialog(
        constraints: const BoxConstraints(maxWidth: 480),
        title: Text(l.wirelessDebugging),
        content: ListenableBuilder(
          listenable: app,
          builder: (ctx, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(l.discoveredOnNetwork),
                ),
                for (final s in app.discoveredConnectable)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${s.instance} (${s.address})',
                          overflow: TextOverflow.ellipsis,
                          style: FluentTheme.of(ctx).typography.caption,
                        ),
                      ),
                      Button(
                        onPressed: () => app.wifiConnect(s.address),
                        child: Text(l.connect),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 8),
              Expander(
                header: Text(l.manualPairConnect),
                content: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: InfoLabel(
                            label: l.pairingIpPort,
                            child: TextBox(controller: pairHost),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: InfoLabel(
                            label: l.code,
                            child: TextBox(controller: pairCode),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          onPressed: () => app.wifiPair(
                            pairHost.text.trim(),
                            pairCode.text.trim(),
                          ),
                          child: Text(l.pair),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: InfoLabel(
                            label: l.connectIpPort,
                            child: TextBox(controller: connectHost),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          onPressed: () =>
                              app.wifiConnect(connectHost.text.trim()),
                          child: Text(l.connect),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          Button(onPressed: () => Navigator.pop(ctx), child: Text(l.close)),
        ],
      );
    },
  );
  app.stopQrPairing();
}
