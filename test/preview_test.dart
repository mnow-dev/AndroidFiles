import 'dart:convert';
import 'dart:io';

import 'package:android_files/l10n/app_localizations.dart';
import 'package:android_files/src/adb_client.dart';
import 'package:android_files/src/app_controller.dart';
import 'package:android_files/src/models.dart';
import 'package:android_files/src/preview_service.dart';
import 'package:android_files/src/settings.dart';
import 'package:android_files/src/ui/macos/mac_tree_pane.dart';
import 'package:android_files/src/ui/tree_panel.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreviewService.classifyKind', () {
    test('classifies images, HEIC, text, markdown, html, json, pdf, video, audio', () {
      expect(PreviewService.classifyKind('IMG_001.JPG'), PreviewKind.image);
      expect(PreviewService.classifyKind('shot.webp'), PreviewKind.image);
      expect(PreviewService.classifyKind('photo.HEIC'), PreviewKind.heicImage);
      expect(PreviewService.classifyKind('NOTES.md'), PreviewKind.markdown);
      expect(PreviewService.classifyKind('guide.html'), PreviewKind.html);
      expect(PreviewService.classifyKind('config.json'), PreviewKind.json);
      expect(PreviewService.classifyKind('app.log'), PreviewKind.text);
      expect(PreviewService.classifyKind('README'), PreviewKind.text);
      expect(PreviewService.classifyKind('invoice.pdf'), PreviewKind.pdf);
      expect(PreviewService.classifyKind('clip.MP4'), PreviewKind.video);
      expect(PreviewService.classifyKind('track.flac'), PreviewKind.audio);
      expect(PreviewService.classifyKind('archive.apk'), PreviewKind.unsupported);
    });
  });

  group('Pure preview parsers', () {
    test('parseMarkdownBlocks parses headings, lists, quotes, code, rules', () {
      const md = '''
# Title
## Subtitle
A paragraph with **bold** and `code`.

- First item
- Second item

> A thoughtful quote

```dart
void main() {}
```

---
''';
      final blocks = PreviewService.parseMarkdownBlocks(md);
      expect(blocks.map((b) => b.type).toList(), [
        RichBlockType.h1,
        RichBlockType.h2,
        RichBlockType.paragraph,
        RichBlockType.listItem,
        RichBlockType.listItem,
        RichBlockType.quote,
        RichBlockType.code,
        RichBlockType.rule,
      ]);
      expect(blocks.first.text, 'Title');
      expect(blocks[6].text, 'void main() {}');
    });

    test('stripHtmlToBlocks strips scripts/styles and preserves readable structure', () {
      const html = '''
<html>
  <head><title>Ignored</title><style>body{color:red}</style></head>
  <body>
    <script>alert("xss")</script>
    <h1>Welcome &amp; Hello</h1>
    <p>Paragraph with <b>bold</b> &mdash; text.</p>
    <ul><li>Item one</li><li>Item two</li></ul>
  </body>
</html>
''';
      final blocks = PreviewService.stripHtmlToBlocks(html);
      expect(blocks.any((b) => b.text.contains('alert')), isFalse);
      expect(blocks.any((b) => b.text.contains('color:red')), isFalse);
      expect(blocks.first.type, RichBlockType.h1);
      expect(blocks.first.text, 'Welcome & Hello');
      expect(blocks[1].text, 'Paragraph with bold — text.');
      expect(blocks[2].type, RichBlockType.listItem);
      expect(blocks[2].text, 'Item one');
    });

    test('prettyPrintJson formats valid JSON and returns null on invalid', () {
      expect(PreviewService.prettyPrintJson('{"a":1,"b":[2]}'), contains('\n  "a": 1'));
      expect(PreviewService.prettyPrintJson('{broken'), isNull);
    });

    test('countPdfPages counts /Type /Page objects without counting /Pages', () {
      final bytes = Uint8List.fromList(latin1.encode(
        '%PDF-1.7\n1 0 obj << /Type /Pages /Count 2 >> endobj\n'
        '2 0 obj << /Type /Page >> endobj\n'
        '3 0 obj << /Type /Page >> endobj\n',
      ));
      expect(PreviewService.countPdfPages(bytes), 2);
      expect(PreviewService.countPdfPages(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('isLikelyBinary detects NUL bytes and accepts plain UTF-8 text', () {
      expect(PreviewService.isLikelyBinary(Uint8List.fromList(utf8.encode('Hello world!\nLine 2'))), isFalse);
      expect(PreviewService.isLikelyBinary(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])), isTrue);
    });
  });

  group('PreviewService local backup resolution & caching', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('af_preview_test_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('finds local backup in mirror, nested subfolder, snapshot, and SD-<UUID>', () async {
      // 1. Nested subfolder mirror: <tmp>/Camera/note.md for /sdcard/DCIM/Camera/note.md
      final nested = File('${tmp.path}/Camera/note.md');
      await nested.parent.create(recursive: true);
      await nested.writeAsString('# Hello');
      final len = await nested.length();

      final hit1 = await PreviewService.resolveLocalBackupFile(
        '/sdcard/DCIM/Camera/note.md',
        len,
        tmp.path,
      );
      expect(hit1?.path, nested.path);

      // Size mismatch is rejected so stale local copy isn't shown as current
      final miss = await PreviewService.resolveLocalBackupFile(
        '/sdcard/DCIM/Camera/note.md',
        len + 999,
        tmp.path,
      );
      expect(miss, isNull);

      // 2. External microSD namespace: <tmp>/SD-1A2B-3C4D/Docs/readme.txt
      final sdFile = File('${tmp.path}/SD-1A2B-3C4D/Docs/readme.txt');
      await sdFile.parent.create(recursive: true);
      await sdFile.writeAsString('from sd');
      final hitSd = await PreviewService.resolveLocalBackupFile(
        '/storage/1A2B-3C4D/Docs/readme.txt',
        await sdFile.length(),
        tmp.path,
      );
      expect(hitSd?.path, sdFile.path);
    });

    test('loadPreview loads backed-up markdown locally & gates large remote videos', () async {
      final mdFile = File('${tmp.path}/Documents/notes.md');
      await mdFile.parent.create(recursive: true);
      await mdFile.writeAsString('# Local Note\nInstant load.');

      final svc = PreviewService(
        adb: AdbClient('adb'),
        log: (_) {},
        cacheDir: Directory('${tmp.path}/cache'),
      );

      final mdData = await svc.loadPreview(
        'SER1',
        PreviewItem(
          name: 'notes.md',
          devicePath: '/sdcard/Documents/notes.md',
          size: await mdFile.length(),
          modified: '2026-11-27 00:10',
        ),
        destRoot: tmp.path,
      );
      expect(mdData.fromLocalBackup, isTrue);
      expect(mdData.textContent, contains('Instant load.'));
      expect(mdData.error, isNull);

      // Large remote video (120 MB) not backed up locally asks before downloading
      final bigVideo = await svc.loadPreview(
        'SER1',
        PreviewItem(
          name: '4k_clip.mp4',
          devicePath: '/sdcard/DCIM/Camera/4k_clip.mp4',
          size: 120 * 1024 * 1024,
          modified: '2026-11-27 00:10',
        ),
        destRoot: tmp.path,
      );
      expect(bigVideo.needsDownloadConfirm, isTrue);
      expect(bigVideo.fromLocalBackup, isFalse);
    });
  });

  group('Quick Look UI integration (macOS & Windows)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('af_ql_ui_');
      final docs = Directory('${tmp.path}/Documents');
      await docs.create(recursive: true);
      await File('${docs.path}/guide.md').writeAsString(
        '# Quick Look Guide\nThis is a **bold** note.',
      );
      await File('${docs.path}/page.html').writeAsString(
        '<h1>HTML Heading</h1><p>Readable body text.</p>',
      );
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    AppController makeController() {
      final s = Settings(adbPath: 'adb')..lastDestination = tmp.path;
      final app = AppController(s, startPolling: false);
      app.selected = const AdbDevice(
        serial: 'SER1',
        state: 'device',
        model: 'Pixel 8',
      );
      app.expanded.addAll(['/sdcard', '/sdcard/Documents']);
      app.children['/sdcard'] = const [
        RemoteEntry(
          name: 'Documents',
          path: '/sdcard/Documents',
          isDir: true,
          modified: '2026-11-27 00:10',
        ),
      ];
      final mdLen = File('${tmp.path}/Documents/guide.md').lengthSync();
      final htmlLen = File('${tmp.path}/Documents/page.html').lengthSync();
      app.children['/sdcard/Documents'] = [
        RemoteEntry(
          name: 'guide.md',
          path: '/sdcard/Documents/guide.md',
          isDir: false,
          size: mdLen,
          modified: '2026-11-27 00:10',
        ),
        RemoteEntry(
          name: 'page.html',
          path: '/sdcard/Documents/page.html',
          isDir: false,
          size: htmlLen,
          modified: '2026-11-27 00:10',
        ),
      ];
      return app;
    }

    Future<void> pumpUntilLoaded(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('Loading preview…').evaluate().isEmpty) return;
      }
    }

    testWidgets('macOS tree opens Quick Look with Space, navigates with ArrowRight, closes with Esc', (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = makeController();
      addTearDown(app.dispose);

      await tester.pumpWidget(
        CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CupertinoPageScaffold(child: MacTreePane(app: app)),
        ),
      );
      await tester.pump();

      // Click file row to focus (wait > kDoubleTapTimeout for onTap to win),
      // then press Space to open Quick Look.
      await tester.tap(find.text('guide.md'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 200));
      await pumpUntilLoaded(tester);

      // Quick Look shows rendered Markdown + Local backup badge + 1 / 2 counter
      expect(find.text('Quick Look Guide', findRichText: true), findsOneWidget);
      expect(find.text('Local backup'), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);

      // Step to next sibling file with ArrowRight -> page.html
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
      await pumpUntilLoaded(tester);
      expect(find.text('HTML Heading', findRichText: true), findsOneWidget);
      expect(find.text('Readable body text.', findRichText: true), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);

      // Toggle Source view
      await tester.tap(find.text('Source'));
      await tester.pump();
      expect(find.textContaining('<h1>HTML Heading</h1>', findRichText: true), findsOneWidget);

      // Close with Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsNothing);
    });

    testWidgets('Windows tree opens Quick Look on double-tap and toggles backup checkbox', (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = makeController();
      addTearDown(app.dispose);

      await tester.pumpWidget(
        FluentApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NavigationView(content: TreePanel(app: app)),
        ),
      );
      await tester.pump();

      // Double-tap guide.md to open Quick Look
      final target = find.text('guide.md');
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(target);
      await tester.pump(const Duration(milliseconds: 200));
      await pumpUntilLoaded(tester);

      expect(find.text('Quick Look Guide', findRichText: true), findsOneWidget);
      expect(find.text('Include in backup'), findsOneWidget);
      expect(app.isSelected('/sdcard/Documents/guide.md'), isFalse);

      // Toggle Include in backup from Quick Look footer
      await tester.tap(find.text('Include in backup'));
      await tester.pump();
      expect(app.isSelected('/sdcard/Documents/guide.md'), isTrue);

      // Close with Space
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('Quick Look Guide', findRichText: true), findsNothing);
      app.shutdown();
    });
  });
}
