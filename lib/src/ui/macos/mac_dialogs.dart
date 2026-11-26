import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show LicensePage, Material, Theme, ThemeData;
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/app_localizations.dart';
import '../../app_controller.dart';
import '../../scheduler.dart';
import '../../settings.dart';
import '../../update_checker.dart';
import 'mac_theme.dart';

Future<T?> _showMacModal<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool barrierDismissible = true,
}) {
  return showCupertinoDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: builder,
  );
}

Future<String?> _pickAdbBinary(String title) async {
  final r = await FilePicker.pickFiles(
    dialogTitle: title,
    type: FileType.any,
  );
  return r?.files.firstOrNull?.path;
}

Future<void> showMacSaveProfileDialog(
  BuildContext context,
  AppController app,
) async {
  final l = AppLocalizations.of(context);
  final name = TextEditingController(text: app.activeProfile?.name ?? '');
  final result = await _showMacModal<String>(
    context,
    (ctx) => MacDialogFrame(
      title: l.saveProfileTitle,
      maxWidth: 380,
      content: MacTextField(
        controller: name,
        autofocus: true,
        placeholder: l.profileNamePlaceholder,
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        MacPushButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(l.cancel),
        ),
        MacPrimaryButton(
          expand: false,
          height: 28,
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

Future<void> showMacSettingsDialog(
  BuildContext context,
  AppController app,
) async {
  final adbPath = TextEditingController(text: app.settings.adbPath);
  final clutterPatterns = TextEditingController(
    text: app.settings.clutterPatterns.join('\n'),
  );
  final scrollController = ScrollController();
  String? testResult;

  await _showMacModal<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final p = MacPalette.of(ctx);
        final l = AppLocalizations.of(ctx);

        Widget group(String title, List<Widget> children) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, top: 12, bottom: 5),
                  child: MacSectionHeader(title),
                ),
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: p.inspectorBg,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: p.border, width: 0.75),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ],
            );

        return MacDialogFrame(
          title: l.settingsTitle,
          maxWidth: 500,
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.62,
            ),
            child: CupertinoScrollbar(
              controller: scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    group(l.settingsDevice, [
                      Text(
                        l.settingsAdbPath,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: MacTextField(
                              controller: adbPath,
                              monospace: true,
                            ),
                          ),
                          const SizedBox(width: 6),
                          MacPushButton(
                            onPressed: () async {
                              final picked = await _pickAdbBinary(l.locateAdb);
                              if (picked != null) {
                                setState(() => adbPath.text = picked);
                              }
                            },
                            child: const Text('Browse…'),
                          ),
                          const SizedBox(width: 6),
                          MacPushButton(
                            onPressed: () async {
                              try {
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
                              } catch (e) {
                                setState(() => testResult = l.testFailed('$e'));
                              }
                            },
                            child: Text(l.test),
                          ),
                        ],
                      ),
                      if (testResult != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          testResult!,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: macMonoFont,
                            color: p.green,
                          ),
                        ),
                      ],
                      const SizedBox(height: 5),
                      Text(
                        l.adbRestartNote,
                        style: TextStyle(fontSize: 11, color: p.textTertiary),
                      ),
                    ]),
                    group(l.settingsBackups, [
                      Text(
                        l.clutterLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      MacTextField(
                        controller: clutterPatterns,
                        maxLines: 4,
                        monospace: true,
                        placeholder: '.thumbnails\nAndroid/data',
                      ),
                      const SizedBox(height: 5),
                      Text(
                        l.clutterNote,
                        style: TextStyle(fontSize: 11, color: p.textTertiary),
                      ),
                    ]),
                    group(l.settingsAppearance, [
                      Text(
                        l.theme,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          color: p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      MacSegmentedControl<String>(
                        value: app.themeMode,
                        items: [
                          ('light', l.themeLight),
                          ('dark', l.themeDark),
                          ('system', l.themeSystemMac),
                        ],
                        onChanged: (v) {
                          app.themeMode = v;
                          setState(() {});
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            l.language,
                            style: TextStyle(
                              fontSize: 12,
                              color: p.textPrimary,
                            ),
                          ),
                          const Spacer(),
                          MacPushButton(
                            onPressed: () => _showLanguagePicker(ctx, app, () {
                              setState(() {});
                            }),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  app.localeCode.isEmpty
                                      ? l.systemDefault
                                      : lookupAppLocalizations(
                                          Locale(app.localeCode),
                                        ).languageName,
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  CupertinoIcons.chevron_up_chevron_down,
                                  size: 11,
                                  color: p.textTertiary,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ]),
                    group(l.settingsAbout, [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l.aboutLicensed(appVersion),
                              style: TextStyle(
                                fontSize: 11.5,
                                color: p.textSecondary,
                              ),
                            ),
                          ),
                          MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () => Navigator.of(ctx).push(
                                CupertinoPageRoute<void>(
                                  builder: (_) => Theme(
                                    data: p.isDark
                                        ? ThemeData.dark()
                                        : ThemeData.light(),
                                    child: Material(
                                      child: LicensePage(
                                        applicationName: 'AndroidFiles',
                                        applicationVersion: 'v$appVersion',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              child: Text(
                                l.openSourceLicenses,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w500,
                                  color: p.green,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            MacPushButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l.cancel),
            ),
            MacPrimaryButton(
              expand: false,
              height: 28,
              onPressed: () {
                app.settings.adbPath = adbPath.text.trim();
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
  scrollController.dispose();
}

Future<void> _showLanguagePicker(
  BuildContext context,
  AppController app,
  VoidCallback onPicked,
) async {
  final l = AppLocalizations.of(context);
  await _showMacModal<void>(
    context,
    (ctx) {
      final p = MacPalette.of(ctx);
      final items = <(String, String)>[
        ('', l.systemDefault),
        for (final loc in AppLocalizations.supportedLocales)
          (loc.languageCode, lookupAppLocalizations(loc).languageName),
      ];
      return MacDialogFrame(
        title: l.language,
        maxWidth: 320,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (code, name) in items)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      app.localeCode = code;
                      onPicked();
                      Navigator.pop(ctx);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: app.localeCode == code
                            ? p.surfaceSelected
                            : const Color(0x00000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: app.localeCode == code
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: p.textPrimary,
                              ),
                            ),
                          ),
                          if (app.localeCode == code)
                            Icon(
                              CupertinoIcons.check_mark,
                              size: 13,
                              color: p.green,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          MacPushButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.close),
          ),
        ],
      );
    },
  );
}

Future<void> showMacRestoreDialog(
  BuildContext context,
  AppController app,
  List<String> paths,
) async {
  final defaultTarget = app.checked.length == 1
      ? app.checked.first
      : (app.activeVolume.isExternal ? app.activeRootPath : '/sdcard/Download');
  final target = TextEditingController(text: defaultTarget);

  await _showMacModal<void>(
    context,
    (ctx) {
      final p = MacPalette.of(ctx);
      final l = AppLocalizations.of(ctx);
      return MacDialogFrame(
        title: l.pushItemsTitle(paths.length),
        maxWidth: 480,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: p.inspectorBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.border, width: 0.75),
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final path in paths)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: macMonoFont,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              l.deviceTargetFolder,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            MacTextField(controller: target, monospace: true),
            const SizedBox(height: 6),
            Text(
              l.overwriteNote,
              style: TextStyle(fontSize: 11, color: p.textTertiary),
            ),
          ],
        ),
        actions: [
          MacPushButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          MacPrimaryButton(
            expand: false,
            height: 28,
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

Future<void> showMacScheduleDialog(
  BuildContext context,
  AppController app,
  Profile profile,
) async {
  final time = TextEditingController(text: profile.scheduleTime ?? '03:00');
  final scheduled = await TaskScheduler.isScheduled(profile.name);
  if (!context.mounted) return;

  await _showMacModal<void>(
    context,
    (ctx) {
      final p = MacPalette.of(ctx);
      final l = AppLocalizations.of(ctx);
      return MacDialogFrame(
        title: l.scheduleTitle(profile.name),
        subtitle: scheduled
            ? l.currentlyScheduled(profile.scheduleTime ?? '?')
            : l.notScheduled,
        maxWidth: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.dailyAtLabel,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: 5),
            MacTextField(controller: time, monospace: true),
            const SizedBox(height: 8),
            Text(
              l.scheduleNoteMac,
              style: TextStyle(
                fontSize: 11,
                color: p.textTertiary,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          if (scheduled)
            MacPushButton(
              destructive: true,
              onPressed: () async {
                final err = await TaskScheduler.unschedule(profile.name);
                _finishSchedule(app, profile, err, null);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: Text(l.removeSchedule),
            ),
          MacPushButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          MacPrimaryButton(
            expand: false,
            height: 28,
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
    app.log('launchd schedule failed: $err');
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

Future<void> showMacWifiDialog(BuildContext context, AppController app) async {
  final pairHost = TextEditingController();
  final pairCode = TextEditingController();
  final connectHost = TextEditingController();
  var showManual = false;

  app.startQrPairing();
  await _showMacModal<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final p = MacPalette.of(ctx);
        final l = AppLocalizations.of(ctx);
        return MacDialogFrame(
          title: l.wirelessDebugging,
          maxWidth: 460,
          content: ListenableBuilder(
            listenable: app,
            builder: (ctx, _) => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (app.qrPayload != null) ...[
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFFFFF),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0x14000000),
                            width: 1,
                          ),
                        ),
                        child: QrImageView(data: app.qrPayload!, size: 176),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      app.pairingStatus,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: app.pairingStatus.contains('✓')
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: app.pairingStatus.contains('✓')
                            ? p.green
                            : p.textSecondary,
                      ),
                    ),
                  ],
                  if (app.discoveredConnectable.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    MacSectionHeader(l.discoveredOnNetwork),
                    const SizedBox(height: 6),
                    for (final s in app.discoveredConnectable)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: p.inspectorBg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: p.border, width: 0.75),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.instance,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: p.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    s.address,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFamily: macMonoFont,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            MacPushButton(
                              onPressed: () => app.wifiConnect(s.address),
                              child: Text(l.connect),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 10),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => setState(() => showManual = !showManual),
                      child: Row(
                        children: [
                          Icon(
                            showManual
                                ? CupertinoIcons.chevron_down
                                : CupertinoIcons.chevron_right,
                            size: 12,
                            color: p.green,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            l.manualPairConnect,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: p.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (showManual) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: p.inspectorBg,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: p.border, width: 0.75),
                      ),
                      child: Column(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.pairingIpPort,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    MacTextField(
                                      controller: pairHost,
                                      monospace: true,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.code,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    MacTextField(
                                      controller: pairCode,
                                      monospace: true,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              MacPushButton(
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
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.connectIpPort,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: p.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    MacTextField(
                                      controller: connectHost,
                                      monospace: true,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              MacPushButton(
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
                ],
              ),
            ),
          ),
          actions: [
            MacPushButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l.close),
            ),
          ],
        );
      },
    ),
  );
  app.stopQrPairing();
}

Future<void> showMacUpdateDialog(
  BuildContext context,
  AppController app,
) async {
  final info = app.update;
  if (info == null) return;
  await _showMacModal<void>(
    context,
    barrierDismissible: false,
    (ctx) => ListenableBuilder(
      listenable: app,
      builder: (ctx, _) {
        final p = MacPalette.of(ctx);
        final l = AppLocalizations.of(ctx);
        final progress = app.updateProgress;
        final installing = progress != null;
        return MacDialogFrame(
          title: l.updateAvailable(info.version),
          subtitle: l.runningCurrent(appVersion),
          maxWidth: 380,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (app.updateError != null && !installing)
                Text(
                  l.updateFailed,
                  style: TextStyle(fontSize: 12, color: p.red),
                ),
              if (installing) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 6,
                    child: Stack(
                      children: [
                        Container(color: p.segTrack),
                        FractionallySizedBox(
                          widthFactor: (progress / 100).clamp(0.0, 1.0),
                          child: Container(color: p.green),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.downloadingPercent(progress),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: p.textSecondary,
                    fontFeatures: tabularFigures,
                  ),
                ),
              ],
            ],
          ),
          actions: installing
              ? [
                  MacPrimaryButton(
                    expand: false,
                    height: 28,
                    onPressed: null,
                    child: Text(l.updateButton),
                  ),
                ]
              : [
                  MacPushButton(
                    onPressed: () {
                      app.dismissUpdate();
                      Navigator.pop(ctx);
                    },
                    child: Text(l.updateLater),
                  ),
                  MacPrimaryButton(
                    expand: false,
                    height: 28,
                    onPressed: app.installUpdate,
                    child: Text(l.updateButton),
                  ),
                ],
        );
      },
    ),
  );
}
