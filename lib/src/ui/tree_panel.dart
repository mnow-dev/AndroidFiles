import 'package:desktop_drop/desktop_drop.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../models.dart';
import 'dialogs.dart';

/// Lazy-loading device folder tree with checkboxes. Accepts files dropped
/// from Explorer and pushes them back to the phone (restore).
class TreePanel extends StatefulWidget {
  final AppController app;

  const TreePanel({super.key, required this.app});

  @override
  State<TreePanel> createState() => _TreePanelState();
}

class _TreePanelState extends State<TreePanel> {
  AppController get app => widget.app;
  bool _dragging = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (app.adbMissing || app.adbDownloadProgress != null) {
      return _AdbBootstrapPane(app: app);
    }
    if (app.selected == null) {
      return const Center(
        child: Text('Connect a phone over USB\n(enable USB debugging)',
            textAlign: TextAlign.center),
      );
    }
    final rows = <Widget>[];
    _buildRows(context, AppController.rootPath, 0, rows);
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        final paths = [for (final f in detail.files) f.path];
        if (paths.isNotEmpty) showRestoreDialog(context, app, paths);
      },
      child: Container(
        color: _dragging
            ? FluentTheme.of(context).accentColor.withValues(alpha: 0.08)
            : null,
        // RawScrollbar: always visible and draggable — the fluent overlay
        // scrollbar is too fiddly for a long tree. The built-in scrollbar
        // is suppressed below so only this one renders.
        child: RawScrollbar(
          controller: _scroll,
          thumbVisibility: true,
          interactive: true,
          thickness: 8,
          minThumbLength: 48,
          radius: const Radius.circular(4),
          thumbColor: FluentTheme.of(context)
              .resources
              .textFillColorSecondary
              .withValues(alpha: 0.35),
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.only(top: 4, bottom: 4, right: 10),
              children: [
                _RootRow(app: app),
                ...rows,
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _buildRows(BuildContext context, String path, int depth, List<Widget> out) {
    if (!app.expanded.contains(path)) return;
    if (app.loading.contains(path)) {
      out.add(Padding(
        padding: EdgeInsets.only(left: 28.0 * (depth + 1), top: 4, bottom: 4),
        child: const Row(children: [
          SizedBox(width: 14, height: 14, child: ProgressRing(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('loading…'),
        ]),
      ));
      return;
    }
    for (final e in app.children[path] ?? const <RemoteEntry>[]) {
      out.add(_EntryRow(app: app, entry: e, depth: depth));
      if (e.isDir) _buildRows(context, e.path, depth + 1, out);
    }
  }
}

class _AdbBootstrapPane extends StatelessWidget {
  final AppController app;
  const _AdbBootstrapPane({required this.app});

  @override
  Widget build(BuildContext context) {
    final p = app.adbDownloadProgress;
    return Center(
      child: SizedBox(
        width: 280,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (app.adbBootstrapError != null) ...[
            const Text('Could not download adb automatically.'),
            const SizedBox(height: 6),
            Text(app.adbBootstrapError!,
                style: FluentTheme.of(context).typography.caption,
                textAlign: TextAlign.center),
            const SizedBox(height: 10),
            FilledButton(onPressed: app.downloadAdb, child: const Text('Retry')),
          ] else if (p != null) ...[
            Text('Downloading adb (platform-tools)… ${(p * 100).round()}%'),
            const SizedBox(height: 8),
            ProgressBar(value: p * 100),
          ] else ...[
            const Text('Setting up adb…'),
            const SizedBox(height: 8),
            const ProgressBar(),
          ],
        ]),
      ),
    );
  }
}

class _RootRow extends StatelessWidget {
  final AppController app;
  const _RootRow({required this.app});

  @override
  Widget build(BuildContext context) {
    final open = app.expanded.contains(AppController.rootPath);
    return GestureDetector(
      onTap: () =>
          open ? app.collapse(AppController.rootPath) : app.expand(AppController.rootPath),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(children: [
            Icon(open ? FluentIcons.chevron_down : FluentIcons.chevron_right, size: 16),
            const SizedBox(width: 6),
            const Icon(FluentIcons.cell_phone, size: 16),
            const SizedBox(width: 6),
            Text('/sdcard',
                style: FluentTheme.of(context).typography.bodyStrong),
          ]),
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final AppController app;
  final RemoteEntry entry;
  final int depth;

  const _EntryRow({required this.app, required this.entry, required this.depth});

  @override
  Widget build(BuildContext context) {
    final open = app.expanded.contains(entry.path);
    final knownEmpty = entry.isDir && app.isKnownEmpty(entry.path);
    final implicitlySelected =
        app.checked.any((p) => entry.path == p || entry.path.startsWith('$p/'));
    final secondary =
        FluentTheme.of(context).resources.textFillColorSecondary;
    return GestureDetector(
      onTap: entry.isDir && !knownEmpty
          ? () => open ? app.collapse(entry.path) : app.expand(entry.path)
          : null,
      child: MouseRegion(
        cursor: entry.isDir && !knownEmpty
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: Padding(
          padding:
              EdgeInsets.only(left: 8 + 20.0 * depth, top: 1, bottom: 1, right: 8),
          child: Row(children: [
            SizedBox(
              width: 18,
              child: entry.isDir && !knownEmpty
                  ? Icon(open ? FluentIcons.chevron_down : FluentIcons.chevron_right, size: 16)
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 8, top: 4, bottom: 4),
              child: Checkbox(
                checked: app.checked.contains(entry.path) || implicitlySelected,
                onChanged: implicitlySelected && !app.checked.contains(entry.path)
                    ? null // covered by a checked ancestor
                    : (_) => app.toggleChecked(entry),
              ),
            ),
            Icon(
              entry.isDir
                  ? (entry.isLink ? FluentIcons.folder_open : FluentIcons.folder_fill)
                  : FluentIcons.page,
              size: 16,
              color: entry.isDir ? const Color(0xFFF6C244) : secondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
                style: knownEmpty ? TextStyle(color: secondary) : null,
              ),
            ),
            if (!entry.isDir) ...[
              const SizedBox(width: 12),
              Text(fmtBytes(entry.size),
                  style: FluentTheme.of(context)
                      .typography
                      .caption
                      ?.copyWith(color: secondary)),
            ],
          ]),
        ),
      ),
    );
  }
}
