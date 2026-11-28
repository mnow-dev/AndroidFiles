import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';

import '../app_controller.dart';
import '../backup_engine.dart' show fmtBytes;
import '../sync_engine.dart';
import 'win_theme.dart';

/// Windows 11 Hybrid Fluent workspace for selective folder sync (PC ↔ phone).
class WinSyncView extends StatefulWidget {
  final AppController app;
  const WinSyncView({super.key, required this.app});

  @override
  State<WinSyncView> createState() => _WinSyncViewState();
}

class _WinSyncViewState extends State<WinSyncView> {
  AppController get app => widget.app;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _openPairEditor({
    SyncPair? existing,
    String? presetName,
    String? presetDevicePath,
    SyncMode? presetMode,
  }) async {
    final nameCtrl = TextEditingController(
      text: existing?.name ?? presetName ?? '',
    );
    final localCtrl = TextEditingController(
      text: existing?.localPath ?? '',
    );
    final deviceCtrl = TextEditingController(
      text: existing?.devicePath ?? presetDevicePath ?? '/sdcard/Music',
    );
    var mode = existing?.mode ?? presetMode ?? SyncMode.pushToPhone;
    var propagateDeletes = existing?.propagateDeletes ?? false;
    var autoSync = existing?.autoSyncOnConnect ?? false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final p = WinPalette.of(ctx);
          final canSave = nameCtrl.text.trim().isNotEmpty &&
              localCtrl.text.trim().isNotEmpty &&
              deviceCtrl.text.trim().startsWith('/');

          return ContentDialog(
            constraints: const BoxConstraints(maxWidth: 500),
            title: Text(existing == null ? 'Add Sync Pair' : 'Edit Sync Pair'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoLabel(
                    label: 'Pair Name',
                    child: TextBox(
                      controller: nameCtrl,
                      autofocus: existing == null,
                      placeholder: 'e.g. Music Library, Obsidian Vault, Books',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(height: 12),
                  InfoLabel(
                    label: 'Sync Direction',
                    child: ComboBox<SyncMode>(
                      value: mode,
                      isExpanded: true,
                      items: [
                        for (final m in SyncMode.values)
                          ComboBoxItem(value: m, child: Text(m.label)),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => mode = v);
                      },
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mode.description,
                    style: TextStyle(fontSize: 11.5, color: p.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  InfoLabel(
                    label: 'Computer Folder',
                    child: Row(
                      children: [
                        Expanded(
                          child: TextBox(
                            controller: localCtrl,
                            placeholder: r'C:\Users\You\Music',
                            style: const TextStyle(fontFamily: winMonoFont),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Button(
                          onPressed: () async {
                            final picked = await FilePicker.getDirectoryPath(
                              dialogTitle: 'Select folder to sync',
                            );
                            if (picked != null) {
                              setState(() {
                                localCtrl.text = picked;
                                if (nameCtrl.text.trim().isEmpty) {
                                  final seg = picked
                                      .replaceAll('\\', '/')
                                      .split('/')
                                      .last;
                                  if (seg.isNotEmpty) nameCtrl.text = seg;
                                }
                              });
                            }
                          },
                          child: const Text('Browse…'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  InfoLabel(
                    label: 'Phone Folder',
                    child: TextBox(
                      controller: deviceCtrl,
                      placeholder: '/sdcard/Music',
                      style: const TextStyle(fontFamily: winMonoFont),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final quick in const [
                        '/sdcard/Music',
                        '/sdcard/Documents',
                        '/sdcard/Books',
                        '/sdcard/Audiobooks',
                        '/sdcard/Podcasts',
                      ])
                        Button(
                          onPressed: () =>
                              setState(() => deviceCtrl.text = quick),
                          child: Text(
                            quick,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: winMonoFont,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Checkbox(
                    checked: autoSync,
                    onChanged: (v) => setState(() => autoSync = v ?? false),
                    content: const Text(
                      'Auto-sync when phone connects (USB or Wi-Fi)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Checkbox(
                    checked: propagateDeletes,
                    onChanged: (v) =>
                        setState(() => propagateDeletes = v ?? false),
                    content: const Text(
                      'Mirror deletions (off by default for safety)',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              Button(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: canSave ? () => Navigator.pop(ctx, true) : null,
                child: Text(existing == null ? 'Add Pair' : 'Save'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true) {
      final pair = SyncPair(
        id: existing?.id ?? 'sync_${DateTime.now().microsecondsSinceEpoch}',
        name: nameCtrl.text.trim(),
        localPath: localCtrl.text.trim(),
        devicePath: deviceCtrl.text.trim(),
        mode: mode,
        propagateDeletes: propagateDeletes,
        autoSyncOnConnect: autoSync,
        lastSyncAt: existing?.lastSyncAt,
        lastSummary: existing?.lastSummary,
      );
      if (existing == null) {
        app.sync.addPair(pair);
      } else {
        app.sync.updatePair(pair);
      }
    }
    nameCtrl.dispose();
    localCtrl.dispose();
    deviceCtrl.dispose();
  }

  Future<void> _runWithSafety(SyncPair pair, {SyncPlan? existingPlan}) async {
    final serial = app.selected?.serial;
    if (serial == null) return;
    final plan = existingPlan ?? await app.sync.previewPair(pair, serial);
    if (plan == null || !mounted) return;

    var allowLargeDeletes = false;
    if (plan.requiresDeleteConfirmation) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => ContentDialog(
          title: Text('Confirm ${plan.totalDeletes} deletions?'),
          content: Text(
            'This sync would remove ${plan.totalDeletes} files (over 20% of "${pair.name}"). '
            'Verify both folders point to the right locations before continuing.',
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue Sync'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      allowLargeDeletes = true;
    }

    await app.sync.runPair(
      pair,
      serial,
      plan: plan,
      allowLargeDeletes: allowLargeDeletes,
    );
  }

  Future<void> _syncAll() async {
    final serial = app.selected?.serial;
    if (serial == null) return;
    for (final p in List<SyncPair>.from(app.sync.pairs)) {
      if (!mounted) break;
      await _runWithSafety(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final pairs = app.sync.pairs;
    final hasDevice = app.selected != null;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: WinBentoCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.borderSoft)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Folder Sync',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Push folders like Music or Books to your phone, or keep Obsidian vaults & Notes synced two-way with conflict safety.',
                          style: TextStyle(
                            fontSize: 12,
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (pairs.isNotEmpty) ...[
                    Button(
                      onPressed:
                          hasDevice && !app.sync.busy ? _syncAll : null,
                      child: const Text('Sync All'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton(
                    onPressed: () => _openPairEditor(),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.add, size: 12),
                        SizedBox(width: 6),
                        Text('Add Sync Pair'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (!hasDevice)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: p.warnBg,
                child: Row(
                  children: [
                    Icon(FluentIcons.info, size: 13, color: p.warnFg),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connect a phone over USB or Wi-Fi to preview or run sync pairs. You can configure pairs offline anytime.',
                        style: TextStyle(fontSize: 11.5, color: p.warnFg),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: pairs.isEmpty
                  ? _buildEmptyState(p)
                  : ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: pairs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, idx) => _WinSyncPairCard(
                        app: app,
                        pair: pairs[idx],
                        onPreview: () {
                          final s = app.selected?.serial;
                          if (s != null) app.sync.previewPair(pairs[idx], s);
                        },
                        onRun: (plan) =>
                            _runWithSafety(pairs[idx], existingPlan: plan),
                        onEdit: () => _openPairEditor(existing: pairs[idx]),
                        onDelete: () => app.sync.removePair(pairs[idx].id),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(WinPalette p) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: p.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(FluentIcons.sync, size: 22, color: p.accent),
              ),
              const SizedBox(height: 12),
              Text(
                'No synced folders yet',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Pick a quick template below or add any custom PC ↔ phone folder pair.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _WinPresetCard(
                      icon: FluentIcons.music_in_collection,
                      title: 'Music → Phone',
                      subtitle: 'Push new tracks to /sdcard/Music',
                      onTap: () => _openPairEditor(
                        presetName: 'Music',
                        presetDevicePath: '/sdcard/Music',
                        presetMode: SyncMode.pushToPhone,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _WinPresetCard(
                      icon: FluentIcons.page,
                      title: 'Obsidian / Notes ⇄',
                      subtitle: 'Two-way sync with conflict copies',
                      onTap: () => _openPairEditor(
                        presetName: 'Obsidian Vault',
                        presetDevicePath: '/sdcard/Documents/Vault',
                        presetMode: SyncMode.twoWay,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _WinPresetCard(
                      icon: FluentIcons.library,
                      title: 'Books & PDFs →',
                      subtitle: 'Push ebooks to /sdcard/Books',
                      onTap: () => _openPairEditor(
                        presetName: 'Books',
                        presetDevicePath: '/sdcard/Books',
                        presetMode: SyncMode.pushToPhone,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WinPresetCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _WinPresetCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_WinPresetCard> createState() => _WinPresetCardState();
}

class _WinPresetCardState extends State<_WinPresetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _hovered ? p.rowHoverBg : p.cardSubBg,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: _hovered ? p.accentBorder : p.borderSoft,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 18, color: p.accent),
              const SizedBox(height: 8),
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.subtitle,
                style: TextStyle(fontSize: 11, color: p.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WinSyncPairCard extends StatelessWidget {
  final AppController app;
  final SyncPair pair;
  final VoidCallback onPreview;
  final ValueChanged<SyncPlan?> onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _WinSyncPairCard({
    required this.app,
    required this.pair,
    required this.onPreview,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final sync = app.sync;
    final isActive = sync.activePairId == pair.id;
    final plan = sync.previews[pair.id];
    final hasDevice = app.selected != null;

    final (pillFg, pillBg) = switch (pair.mode) {
      SyncMode.pushToPhone => (p.accentSoftFg, p.accentSoft),
      SyncMode.pullToComputer => (
          p.dark ? const Color(0xFF99D1FF) : const Color(0xFF0D478A),
          p.dark ? const Color(0xFF1B334D) : const Color(0xFFD8EAFC),
        ),
      SyncMode.twoWay => (
          p.dark ? const Color(0xFFD0A8FF) : const Color(0xFF6B21A8),
          p.dark ? const Color(0xFF2E1B47) : const Color(0xFFF3E8FF),
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardSubBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: isActive ? p.accent : p.borderSoft,
          width: isActive ? 1.25 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        pair.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    WinPill(
                      label: pair.mode.shortLabel,
                      color: pillFg,
                      background: pillBg,
                    ),
                    if (pair.autoSyncOnConnect) ...[
                      const SizedBox(width: 6),
                      WinPill(
                        label: 'Auto on connect',
                        color: p.neutralPillFg,
                        background: p.neutralPillBg,
                      ),
                    ],
                    if (pair.propagateDeletes) ...[
                      const SizedBox(width: 6),
                      WinPill(
                        label: 'Mirror deletes',
                        color: p.warnFg,
                        background: p.warnBg,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isActive)
                Button(
                  onPressed: sync.cancel,
                  child: const Text('Cancel'),
                )
              else ...[
                Button(
                  onPressed: hasDevice && !sync.busy ? onPreview : null,
                  child: const Text('Preview'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed:
                      hasDevice && !sync.busy ? () => onRun(plan) : null,
                  child: const Text('Sync Now'),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Edit pair',
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.edit,
                      size: 13,
                      color: p.textSecondary,
                    ),
                    onPressed: sync.busy ? null : onEdit,
                  ),
                ),
                Tooltip(
                  message: 'Delete pair',
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.delete,
                      size: 13,
                      color: p.textSecondary,
                    ),
                    onPressed: sync.busy ? null : onDelete,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: p.borderSoft),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.folder, size: 13, color: p.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pair.localPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: winMonoFont,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    switch (pair.mode) {
                      SyncMode.pushToPhone => '→',
                      SyncMode.pullToComputer => '←',
                      SyncMode.twoWay => '⇄',
                    },
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: pillFg,
                    ),
                  ),
                ),
                Icon(FluentIcons.cell_phone, size: 13, color: p.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pair.cleanDevicePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: winMonoFont,
                      color: p.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isActive) ...[
            const SizedBox(height: 10),
            ProgressBar(
              value: sync.scanning ? null : sync.progress * 100,
            ),
            const SizedBox(height: 5),
            Text(
              sync.running
                  ? '${sync.statusText} (${sync.doneItems}/${sync.totalItems})'
                  : sync.statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: p.textSecondary,
                fontFeatures: winTabularFigures,
              ),
            ),
          ] else if (plan != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: p.cardBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: plan.requiresDeleteConfirmation
                      ? p.warnFg
                      : p.accentBorder,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          plan.isEmpty
                              ? 'Preview: ${plan.summary()}'
                              : 'Preview: ${plan.summary()} (${fmtBytes(plan.totalBytesToTransfer)})',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                      ),
                      if (!plan.isEmpty)
                        FilledButton(
                          onPressed: hasDevice ? () => onRun(plan) : null,
                          child: const Text('Apply'),
                        ),
                    ],
                  ),
                  if (!plan.isEmpty) ...[
                    const SizedBox(height: 6),
                    for (final item in _winPreviewLines(plan).take(8))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          item,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: winMonoFont,
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                    if (plan.totalActions > 8)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '…and ${plan.totalActions - 8} more item(s)',
                          style: TextStyle(fontSize: 11, color: p.textTertiary),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ] else if (pair.lastSummary != null) ...[
            const SizedBox(height: 6),
            Text(
              'Last sync: ${pair.lastSummary}${pair.lastSyncAt != null ? ' · ${_winFmtLastSync(pair.lastSyncAt!)}' : ''}',
              style: TextStyle(fontSize: 11, color: p.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _winPreviewLines(SyncPlan plan) => [
      for (final f in plan.toPush) '↑ Push   ${f.relPath} (${fmtBytes(f.size)})',
      for (final f in plan.toPull) '↓ Pull   ${f.relPath} (${fmtBytes(f.size)})',
      for (final c in plan.conflicts)
        '⚠ Both   ${c.relPath} → keep ${c.conflictRelPath}',
      for (final f in plan.toDeleteOnDevice) '✕ Phone  ${f.relPath}',
      for (final f in plan.toDeleteLocal) '✕ Local  ${f.relPath}',
    ];

String _winFmtLastSync(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}
