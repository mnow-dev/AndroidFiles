import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;

import '../../app_controller.dart';
import '../../backup_engine.dart' show fmtBytes;
import '../../sync_engine.dart';
import 'mac_theme.dart';

/// Native macOS HIG workspace for selective folder sync (computer ↔ phone).
class MacSyncView extends StatefulWidget {
  final AppController app;
  const MacSyncView({super.key, required this.app});

  @override
  State<MacSyncView> createState() => _MacSyncViewState();
}

class _MacSyncViewState extends State<MacSyncView> {
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

    final saved = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => ListenableBuilder(
          listenable: Listenable.merge([nameCtrl, localCtrl, deviceCtrl]),
          builder: (ctx, _) {
          final p = MacPalette.of(ctx);
          final canSave = nameCtrl.text.trim().isNotEmpty &&
              localCtrl.text.trim().isNotEmpty &&
              deviceCtrl.text.trim().startsWith('/');

          return MacDialogFrame(
            title: existing == null ? 'Add Sync Pair' : 'Edit Sync Pair',
            subtitle:
                'Choose a computer folder and phone folder to keep in sync.',
            maxWidth: 480,
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Pair Name',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  MacTextField(
                    controller: nameCtrl,
                    autofocus: existing == null,
                    placeholder: 'e.g. Music Library, Obsidian Vault, Books',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Sync Direction',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  MacSegmentedControl<SyncMode>(
                    value: mode,
                    items: const [
                      (SyncMode.pushToPhone, 'Push → Phone'),
                      (SyncMode.pullToComputer, 'Pull ← Phone'),
                      (SyncMode.twoWay, '⇄ Two-Way'),
                    ],
                    onChanged: (v) => setState(() => mode = v),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    mode.description,
                    style: TextStyle(fontSize: 11, color: p.textTertiary),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Mac Folder',
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
                          controller: localCtrl,
                          monospace: true,
                          placeholder: '/Users/you/Music',
                        ),
                      ),
                      const SizedBox(width: 6),
                      MacPushButton(
                        onPressed: () async {
                          final picked = await FilePicker.getDirectoryPath(
                            dialogTitle: 'Select folder to sync',
                          );
                          if (picked != null) {
                            setState(() {
                              localCtrl.text = picked;
                              if (nameCtrl.text.trim().isEmpty) {
                                final seg = picked.split('/').last;
                                if (seg.isNotEmpty) nameCtrl.text = seg;
                              }
                            });
                          }
                        },
                        child: const Text('Choose…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Phone Folder',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  MacTextField(
                    controller: deviceCtrl,
                    monospace: true,
                    placeholder: '/sdcard/Music',
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
                        MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => setState(() => deviceCtrl.text = quick),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: deviceCtrl.text.trim() == quick
                                    ? p.greenSoft
                                    : p.segTrack,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: deviceCtrl.text.trim() == quick
                                      ? p.greenBorder
                                      : p.border,
                                  width: 0.75,
                                ),
                              ),
                              child: Text(
                                quick,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontFamily: macMonoFont,
                                  color: deviceCtrl.text.trim() == quick
                                      ? p.green
                                      : p.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
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
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Auto-sync when phone connects',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: p.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    'Runs automatically over USB or Wi-Fi (5 min cooldown)',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            MacSwitch(
                              value: autoSync,
                              onChanged: (v) => setState(() => autoSync = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Mirror deletions',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: propagateDeletes
                                          ? p.amber
                                          : p.textPrimary,
                                    ),
                                  ),
                                  Text(
                                    'Off by default — deleted files stay safe unless enabled',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            MacSwitch(
                              value: propagateDeletes,
                              onChanged: (v) =>
                                  setState(() => propagateDeletes = v),
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
              MacPushButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              MacPrimaryButton(
                expand: false,
                height: 28,
                onPressed: canSave ? () => Navigator.pop(ctx, true) : null,
                child: Text(existing == null ? 'Add Pair' : 'Save'),
              ),
            ],
          );
          },
        ),
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
      final ok = await showCupertinoDialog<bool>(
        context: context,
        builder: (ctx) => MacDialogFrame(
          title: 'Confirm ${plan.totalDeletes} deletions?',
          subtitle:
              'This sync would remove ${plan.totalDeletes} files (over 20% of "${pair.name}").',
          maxWidth: 400,
          content: Text(
            'Double-check that your local folder and phone folder are mounted and pointing to the right locations before continuing.',
            style: TextStyle(
              fontSize: 12,
              color: MacPalette.of(ctx).textSecondary,
            ),
          ),
          actions: [
            MacPushButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            MacPrimaryButton(
              expand: false,
              height: 28,
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
    final p = MacPalette.of(context);
    final pairs = app.sync.pairs;
    final hasDevice = app.selected != null;

    return Container(
      color: p.windowBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
            decoration: BoxDecoration(
              color: p.toolbarBg,
              border: Border(bottom: BorderSide(color: p.border, width: 1)),
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
                  MacPushButton(
                    onPressed: hasDevice && !app.sync.busy ? _syncAll : null,
                    child: const Text('Sync All'),
                  ),
                  const SizedBox(width: 8),
                ],
                MacPrimaryButton(
                  expand: false,
                  height: 28,
                  onPressed: () => _openPairEditor(),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(CupertinoIcons.add, size: 13),
                      SizedBox(width: 5),
                      Text('Add Sync Pair'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (!hasDevice)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: p.amberSoft,
                border: Border(bottom: BorderSide(color: p.border, width: 0.75)),
              ),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.info_circle,
                    size: 14,
                    color: p.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Connect a phone over USB or Wi-Fi to preview or run sync pairs. You can configure pairs offline anytime.',
                      style: TextStyle(fontSize: 11.5, color: p.amber),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: pairs.isEmpty
                ? _buildEmptyState(p)
                : CupertinoScrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.separated(
                      controller: _scroll,
                      padding: const EdgeInsets.all(18),
                      itemCount: pairs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, idx) => _MacSyncPairCard(
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
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(MacPalette p) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: p.greenSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  CupertinoIcons.arrow_2_circlepath,
                  size: 24,
                  color: p.green,
                ),
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
                'Pick a quick template below or add any custom computer ↔ phone folder pair.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: p.textSecondary),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _PresetCard(
                      icon: CupertinoIcons.music_note_2,
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
                    child: _PresetCard(
                      icon: CupertinoIcons.doc_text,
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
                    child: _PresetCard(
                      icon: CupertinoIcons.book,
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

class _PresetCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _PresetCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceHover : p.inspectorBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hovered ? p.greenBorder : p.border,
              width: 0.75,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 18, color: p.green),
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

class _MacSyncPairCard extends StatelessWidget {
  final AppController app;
  final SyncPair pair;
  final VoidCallback onPreview;
  final ValueChanged<SyncPlan?> onRun;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MacSyncPairCard({
    required this.app,
    required this.pair,
    required this.onPreview,
    required this.onRun,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final sync = app.sync;
    final isActive = sync.activePairId == pair.id;
    final plan = sync.previews[pair.id];
    final hasDevice = app.selected != null;

    final (pillFg, pillBg) = switch (pair.mode) {
      SyncMode.pushToPhone => (p.green, p.greenSoft),
      SyncMode.pullToComputer => (
          p.isDark ? const Color(0xFF99D1FF) : const Color(0xFF0D478A),
          p.isDark ? const Color(0xFF1B334D) : const Color(0xFFD8EAFC),
        ),
      SyncMode.twoWay => (
          p.isDark ? const Color(0xFFD0A8FF) : const Color(0xFF6B21A8),
          p.isDark ? const Color(0xFF2E1B47) : const Color(0xFFF3E8FF),
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.inspectorBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive ? p.greenBorder : p.border,
          width: isActive ? 1.2 : 0.75,
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
                    MacStatusPill(
                      label: pair.mode.shortLabel,
                      color: pillFg,
                      background: pillBg,
                    ),
                    if (pair.autoSyncOnConnect) ...[
                      const SizedBox(width: 6),
                      MacStatusPill(
                        label: 'Auto on connect',
                        color: p.textSecondary,
                        background: p.segTrack,
                      ),
                    ],
                    if (pair.propagateDeletes) ...[
                      const SizedBox(width: 6),
                      MacStatusPill(
                        label: 'Mirror deletes',
                        color: p.amber,
                        background: p.amberSoft,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isActive)
                MacPushButton(
                  onPressed: sync.cancel,
                  child: const Text('Cancel'),
                )
              else ...[
                MacPushButton(
                  onPressed: hasDevice && !sync.busy ? onPreview : null,
                  child: const Text('Preview'),
                ),
                const SizedBox(width: 6),
                MacPrimaryButton(
                  expand: false,
                  height: 26,
                  onPressed: hasDevice && !sync.busy ? () => onRun(plan) : null,
                  child: const Text('Sync Now'),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Edit pair',
                  child: MacToolbarButton(
                    icon: CupertinoIcons.pencil,
                    tooltip: 'Edit pair',
                    onPressed: sync.busy ? null : onEdit,
                  ),
                ),
                Tooltip(
                  message: 'Delete pair',
                  child: MacToolbarButton(
                    icon: CupertinoIcons.trash,
                    tooltip: 'Delete pair',
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
              color: p.windowBg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: p.border, width: 0.75),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.folder, size: 13, color: p.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pair.localPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: macMonoFont,
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
                Icon(
                  CupertinoIcons.device_phone_portrait,
                  size: 13,
                  color: p.textTertiary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    pair.cleanDevicePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontFamily: macMonoFont,
                      color: p.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (isActive) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 5,
                child: Stack(
                  children: [
                    Container(color: p.segTrack),
                    FractionallySizedBox(
                      widthFactor: sync.scanning ? 0.35 : sync.progress,
                      child: Container(color: p.green),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              sync.running
                  ? '${sync.statusText} (${sync.doneItems}/${sync.totalItems})'
                  : sync.statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: p.textSecondary,
                fontFeatures: tabularFigures,
              ),
            ),
          ] else if (plan != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: p.windowBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: plan.requiresDeleteConfirmation
                      ? p.amber
                      : p.greenBorder,
                  width: 0.75,
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
                        MacPrimaryButton(
                          expand: false,
                          height: 24,
                          onPressed: hasDevice ? () => onRun(plan) : null,
                          child: const Text('Apply'),
                        ),
                    ],
                  ),
                  if (!plan.isEmpty) ...[
                    const SizedBox(height: 6),
                    for (final item in _previewLines(plan).take(8))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          item,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: macMonoFont,
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
              'Last sync: ${pair.lastSummary}${pair.lastSyncAt != null ? ' · ${_fmtLastSync(pair.lastSyncAt!)}' : ''}',
              style: TextStyle(fontSize: 11, color: p.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _previewLines(SyncPlan plan) => [
      for (final f in plan.toPush) '↑ Push   ${f.relPath} (${fmtBytes(f.size)})',
      for (final f in plan.toPull) '↓ Pull   ${f.relPath} (${fmtBytes(f.size)})',
      for (final c in plan.conflicts)
        '⚠ Both   ${c.relPath} → keep ${c.conflictRelPath}',
      for (final f in plan.toDeleteOnDevice) '✕ Phone  ${f.relPath}',
      for (final f in plan.toDeleteLocal) '✕ Local  ${f.relPath}',
    ];

String _fmtLastSync(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}
