import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:local_notifier/local_notifier.dart';

import 'l10n/app_localizations.dart';
import 'src/app_controller.dart';
import 'src/settings.dart';
import 'src/ui/home_screen.dart';

Future<void> main(List<String> args) async {
  // Velopack dispatches install/update/uninstall hooks to the main exe as
  // --veloapp-* arguments and blocks on it. We register no custom hooks, so
  // exit at once instead of spinning up the whole UI. Must be the very first
  // thing main() does.
  if (args.any((a) => a.startsWith('--veloapp-'))) {
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  await localNotifier.setup(appName: 'AndroidFiles');
  final settings = await Settings.load();
  final controller = AppController(settings);
  final i = args.indexOf('--run-profile');
  if (i != -1 && i + 1 < args.length) {
    // Scheduled/headless mode: run the profile and exit when drained.
    // ignore: unawaited_futures
    controller.startHeadlessProfile(args[i + 1]);
  }
  runApp(AndroidFilesApp(controller: controller));
}

/// Explicit Segoe UI: DirectWrite may otherwise resolve a Light variant on
/// some locales, which makes everything thin.
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
    fontFamily: 'Segoe UI',
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

class AndroidFilesApp extends StatelessWidget {
  final AppController controller;

  const AndroidFilesApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => FluentApp(
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
      ),
    );
  }
}
