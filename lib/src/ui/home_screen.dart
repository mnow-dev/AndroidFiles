import 'package:fluent_ui/fluent_ui.dart';

import '../../l10n/app_localizations.dart';
import '../app_controller.dart';
import 'dialogs.dart';
import 'queue_panel.dart';
import 'tree_panel.dart';

class HomeScreen extends StatefulWidget {
  final AppController app;

  const HomeScreen({super.key, required this.app});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  AppController get app => widget.app;
  late double _split = app.settings.splitRatio;
  bool _updatePrompted = false;

  @override
  void initState() {
    super.initState();
    app.addListener(_maybePromptUpdate);
    // An update may already have been found before this widget mounted.
    _maybePromptUpdate();
  }

  @override
  void dispose() {
    app.removeListener(_maybePromptUpdate);
    super.dispose();
  }

  /// Pop the update dialog once, the first time a newer release is detected.
  void _maybePromptUpdate() {
    if (_updatePrompted || app.update == null || !mounted) return;
    _updatePrompted = true;
    // Defer past the current notify/build so we never showDialog mid-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && app.update != null) showUpdateDialog(context, app);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => ScaffoldPage(
        padding: EdgeInsets.zero,
        header: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // The title is the only flex member: it absorbs all slack (and
              // fades when tight), keeping the controls hard-right.
              Expanded(
                child: Text(
                  'AndroidFiles',
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: FluentTheme.of(context).typography.subtitle,
                ),
              ),
              _DevicePicker(app: app),
              Tooltip(
                message: l.tooltipRefresh,
                child: IconButton(
                  icon: const Icon(FluentIcons.refresh, size: 16),
                  onPressed: app.selected == null ? null : app.refreshTree,
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: app.drive.mounted
                    ? l.unmountDrive(app.drive.mountPoint)
                    : l.mountDrive(app.drive.mountPoint),
                child: IconButton(
                  icon: Icon(
                    FluentIcons.hard_drive,
                    size: 16,
                    color: app.drive.mounted
                        ? (app.settings.driveWritable
                              ? Colors.orange
                              : Colors.green)
                        : null,
                  ),
                  onPressed: app.drive.mounted || app.selected != null
                      ? app.toggleDrive
                      : null,
                ),
              ),
              Tooltip(
                message: l.tooltipWireless,
                child: IconButton(
                  icon: const Icon(FluentIcons.wifi, size: 16),
                  onPressed: () => showWifiDialog(context, app),
                ),
              ),
              Tooltip(
                message: app.showLog ? l.tooltipHideLog : l.tooltipShowLog,
                child: IconButton(
                  icon: Icon(
                    FluentIcons.command_prompt,
                    size: 16,
                    color: app.showLog
                        ? FluentTheme.of(context).accentColor
                        : null,
                  ),
                  onPressed: () => app.showLog = !app.showLog,
                ),
              ),
              Tooltip(
                message: l.tooltipSettings,
                child: IconButton(
                  icon: const Icon(FluentIcons.settings, size: 16),
                  onPressed: () => showSettingsDialog(context, app),
                ),
              ),
            ],
          ),
        ),
        content: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final total = constraints.maxWidth;
                  final leftWidth = (total * _split).clamp(
                    200.0,
                    (total - 340).clamp(200.0, total),
                  );
                  return Row(
                    children: [
                      SizedBox(
                        width: leftWidth,
                        child: TreePanel(app: app),
                      ),
                      _SplitHandle(
                        onDrag: (dx) => setState(
                          () => _split = ((leftWidth + dx) / total).clamp(
                            0.15,
                            0.85,
                          ),
                        ),
                        onDragEnd: () {
                          app.settings.splitRatio = _split;
                          app.settings.save();
                        },
                      ),
                      Expanded(child: QueuePanel(app: app)),
                    ],
                  );
                },
              ),
            ),
            if (app.showLog) _LogPane(app: app),
          ],
        ),
      ),
    );
  }
}

/// Draggable vertical divider between the tree and the queue.
class _SplitHandle extends StatelessWidget {
  final void Function(double dx) onDrag;
  final VoidCallback onDragEnd;

  const _SplitHandle({required this.onDrag, required this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 1,
              color: FluentTheme.of(
                context,
              ).resources.dividerStrokeColorDefault,
            ),
          ),
        ),
      ),
    );
  }
}

class _DevicePicker extends StatelessWidget {
  final AppController app;
  const _DevicePicker({required this.app});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final caption = FluentTheme.of(context).typography.caption?.copyWith(
      color: FluentTheme.of(context).resources.textFillColorSecondary,
    );
    if (app.devices.isEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(FluentIcons.plug_disconnected, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              l.noDevice,
              overflow: TextOverflow.fade,
              softWrap: false,
              style: caption,
            ),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          app.selected?.serial.contains(':') ?? false
              ? FluentIcons.wifi
              : FluentIcons.cell_phone,
          size: 16,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            l.deviceLabel,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: caption,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          flex: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: ComboBox<String>(
              value: app.selected?.serial,
              placeholder: Text(l.selectDevice),
              isExpanded: true,
              items: [
                for (final d in app.devices)
                  ComboBoxItem(
                    value: d.serial,
                    enabled: d.isReady,
                    child: Row(
                      children: [
                        Icon(
                          d.isWireless ? FluentIcons.wifi : FluentIcons.usb,
                          size: 12,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            d.isReady
                                ? (d.model.isEmpty ? d.serial : d.model)
                                : '${d.model.isEmpty ? d.serial : d.model} — ${d.state}',
                            textAlign: TextAlign.left,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (serial) {
                final d = app.devices
                    .where((d) => d.serial == serial)
                    .firstOrNull;
                if (d != null && d.isReady) app.selectDevice(d);
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _LogPane extends StatelessWidget {
  final AppController app;
  const _LogPane({required this.app});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 110,
      child: Container(
        width: double.infinity,
        color: FluentTheme.of(context).resources.solidBackgroundFillColorBase,
        padding: const EdgeInsets.all(8),
        child: ListView.builder(
          reverse: true,
          itemCount: app.logLines.length,
          itemBuilder: (_, i) => Text(
            app.logLines[app.logLines.length - 1 - i],
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
          ),
        ),
      ),
    );
  }
}
