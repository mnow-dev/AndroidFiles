import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:local_notifier/local_notifier.dart';

import 'l10n/app_localizations.dart';
import 'src/app_controller.dart';
import 'src/settings.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/macos/mac_home_screen.dart';
import 'src/ui/macos/mac_theme.dart';

Future<void> main(List<String> args) async {
  // Velopack dispatches install/update/uninstall hooks to the main exe as
  // --veloapp-* arguments and blocks on it. We register no custom hooks, so
  // exit at once instead of spinning up the whole UI. Must be the very first
  // thing main() does.
  if (args.any((a) => a.startsWith('--veloapp-'))) {
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    // App Sandbox is intentionally disabled (we spawn adb and write to user-
    // chosen volumes), so tell file_picker not to reject missing sandbox
    // user-selected file entitlements when opening NSOpenPanel.
    await FilePicker.skipEntitlementsChecks();
  }
  await localNotifier.setup(appName: 'AndroidFiles');
  final settings = await Settings.load();
  // Get out of the install dir (Velopack launches us in current\). Every child
  // inherits our working directory, and the adb server outlives us: left in
  // current\, it pins the folder so Velopack can't swap it and every update
  // fails with "running processes prevented it". After Settings.load, whose
  // dev-build drive path fallback resolves against the original directory.
  try {
    Directory.current = Directory.systemTemp;
  } catch (_) {}
  final controller = AppController(settings);
  final i = args.indexOf('--run-profile');
  if (i != -1 && i + 1 < args.length) {
    // Scheduled/headless mode: run the profile and exit when drained.
    // ignore: unawaited_futures
    controller.startHeadlessProfile(args[i + 1]);
  }
  runApp(AndroidFilesApp(controller: controller));
}

/// Explicit Segoe UI on Windows: DirectWrite may otherwise resolve a Light
/// variant on some locales, which makes everything thin. Elsewhere the
/// platform's own UI font is used.
///
/// Flutter renders text with grayscale AA and no ClearType, so body text comes
/// out lighter than in native DirectWrite apps — plain w400 reads thin, and
/// thins to the point of illegibility when a screenshot is downscaled. So body
/// and caption sit a step up at w500, and bodyStrong at w600 to stay ahead of
/// them. (A full bump everywhere earlier looked semibold; w400 everywhere then
/// looked thin — w500 is the middle that actually holds up.)
///
/// The weights are applied via copyWith on the BUILT theme's typography —
/// replacing styles wholesale drops their colors.
FluentThemeData _theme(Brightness brightness) {
  final base = FluentThemeData(
    brightness: brightness,
    accentColor: Colors.green,
    visualDensity: VisualDensity.compact,
    fontFamily: Platform.isWindows ? 'Segoe UI' : null,
  );
  final t = base.typography;
  return base.copyWith(
    typography: Typography.raw(
      display: t.display,
      titleLarge: t.titleLarge,
      title: t.title,
      subtitle: t.subtitle,
      bodyLarge: t.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      bodyStrong: t.bodyStrong?.copyWith(fontWeight: FontWeight.w600),
      body: t.body?.copyWith(fontWeight: FontWeight.w500),
      caption: t.caption?.copyWith(fontWeight: FontWeight.w500),
    ),
  );
}

class AndroidFilesApp extends StatefulWidget {
  final AppController controller;

  const AndroidFilesApp({super.key, required this.controller});

  @override
  State<AndroidFilesApp> createState() => _AndroidFilesAppState();
}

class _AndroidFilesAppState extends State<AndroidFilesApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        widget.controller.shutdown();
        return AppExitResponse.exit;
      },
      onDetach: () => widget.controller.shutdown(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (Platform.isMacOS) {
          final brightness = switch (controller.themeMode) {
            'dark' => Brightness.dark,
            'light' => Brightness.light,
            _ => null, // Follow macOS system appearance
          };
          return CupertinoApp(
            title: 'AndroidFiles',
            debugShowCheckedModeBanner: false,
            locale: controller.locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: CupertinoThemeData(
              brightness: brightness,
              primaryColor: brightness == Brightness.dark
                  ? MacPalette.dark.green
                  : MacPalette.light.green,
            ),
            home: MacHomeScreen(app: controller),
          );
        }

        return FluentApp(
          title: 'AndroidFiles',
          debugShowCheckedModeBanner: false,
          locale: controller.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FluentLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: switch (controller.themeMode) {
            'dark' => ThemeMode.dark,
            'system' => ThemeMode.system,
            _ => ThemeMode.light,
          },
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: HomeScreen(app: controller),
        );
      },
    );
  }
}
