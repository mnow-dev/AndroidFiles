import 'package:fluent_ui/fluent_ui.dart';

import '../app_controller.dart';
import '../models.dart';

/// Windows 11 Hybrid Fluent Design palette & shared visual primitives (Light &
/// Dark) used across the redesigned Windows workspace and Clean Up Space view.
class WinPalette {
  final bool dark;
  final Color micaBg;
  final Color ctxBarBg;
  final Color cardBg;
  final Color cardSubBg;
  final Color navActiveBg;
  final Color navHoverBg;
  final Color rowSelectedBg;
  final Color rowHoverBg;
  final Color border;
  final Color borderSoft;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color accent;
  final Color accentFg;
  final Color accentSoft;
  final Color accentSoftFg;
  final Color accentBorder;
  final Color warnBg;
  final Color warnFg;
  final Color red;
  final Color redSoft;
  final Color neutralPillBg;
  final Color neutralPillFg;
  final Color segTrack;
  final Color segThumb;
  final Color barTrack;
  final Color barUsed;

  const WinPalette({
    required this.dark,
    required this.micaBg,
    required this.ctxBarBg,
    required this.cardBg,
    required this.cardSubBg,
    required this.navActiveBg,
    required this.navHoverBg,
    required this.rowSelectedBg,
    required this.rowHoverBg,
    required this.border,
    required this.borderSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentFg,
    required this.accentSoft,
    required this.accentSoftFg,
    required this.accentBorder,
    required this.warnBg,
    required this.warnFg,
    required this.red,
    required this.redSoft,
    required this.neutralPillBg,
    required this.neutralPillFg,
    required this.segTrack,
    required this.segThumb,
    required this.barTrack,
    required this.barUsed,
  });

  static const light = WinPalette(
    dark: false,
    micaBg: Color(0xFFF1F4F7),
    ctxBarBg: Color(0xFFF8FAFC),
    cardBg: Color(0xFFFFFFFF),
    cardSubBg: Color(0xFFF8FAFC),
    navActiveBg: Color(0xFFFFFFFF),
    navHoverBg: Color(0x88FFFFFF),
    rowSelectedBg: Color(0xFFEEF9F2),
    rowHoverBg: Color(0xFFF5F7FA),
    border: Color(0xFFDDE3EA),
    borderSoft: Color(0xFFEDF1F5),
    textPrimary: Color(0xFF1A1D20),
    textSecondary: Color(0xFF5F6872),
    textTertiary: Color(0xFF8C959F),
    accent: Color(0xFF107C41),
    accentFg: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFDCF5E7),
    accentSoftFg: Color(0xFF0F6B36),
    accentBorder: Color(0xFFB7E4C7),
    warnBg: Color(0xFFFFF4E5),
    warnFg: Color(0xFFB45309),
    red: Color(0xFFC42B1C),
    redSoft: Color(0xFFFDE7E9),
    neutralPillBg: Color(0xFFF0F3F6),
    neutralPillFg: Color(0xFF656D76),
    segTrack: Color(0xFFE9EEF3),
    segThumb: Color(0xFFFFFFFF),
    barTrack: Color(0xFFE6EBF0),
    barUsed: Color(0xFFBCC6D0),
  );

  static const darkTheme = WinPalette(
    dark: true,
    micaBg: Color(0xFF191C20),
    ctxBarBg: Color(0xFF1C2026),
    cardBg: Color(0xFF22272E),
    cardSubBg: Color(0xFF1C2026),
    navActiveBg: Color(0xFF262C34),
    navHoverBg: Color(0xFF20252C),
    rowSelectedBg: Color(0x1E3DDC84),
    rowHoverBg: Color(0xFF282E36),
    border: Color(0xFF2F3640),
    borderSoft: Color(0xFF282E36),
    textPrimary: Color(0xFFF0F3F6),
    textSecondary: Color(0xFF9AA4B0),
    textTertiary: Color(0xFF727C88),
    accent: Color(0xFF3DDC84),
    accentFg: Color(0xFF072210),
    accentSoft: Color(0x243DDC84),
    accentSoftFg: Color(0xFF5CE89A),
    accentBorder: Color(0x5C3DDC84),
    warnBg: Color(0x29F59E0B),
    warnFg: Color(0xFFFBBF24),
    red: Color(0xFFFF6B6B),
    redSoft: Color(0x26FF6B6B),
    neutralPillBg: Color(0xFF2B313A),
    neutralPillFg: Color(0xFF8D97A5),
    segTrack: Color(0xFF171A1E),
    segThumb: Color(0xFF2E353E),
    barTrack: Color(0xFF171A1E),
    barUsed: Color(0xFF4A5462),
  );

  static WinPalette of(BuildContext context) =>
      FluentTheme.of(context).brightness == Brightness.dark ? darkTheme : light;
}

const winMonoFont = 'Cascadia Code';

const winTabularFigures = [FontFeature.tabularFigures()];

/// Elevated Bento card container used for the 3 workspace sections.
class WinBentoCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool clip;

  const WinBentoCard({
    super.key,
    required this.child,
    this.padding,
    this.clip = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Container(
      padding: padding,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border, width: 1),
        boxShadow: [
          BoxShadow(
            color: p.dark
                ? const Color(0x33000000)
                : const Color(0x0D000000),
            blurRadius: p.dark ? 12 : 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Compact uppercase sidebar/card section heading with optional trailing widget.
class WinSectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const WinSectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.55,
              color: p.textTertiary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Soft rounded status pill (Backup Status, selection summary, badges).
class WinPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  final Color? borderColor;
  final IconData? icon;

  const WinPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.borderColor,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: borderColor != null ? Border.all(color: borderColor!, width: 1) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
                fontFeatures: winTabularFigures,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fluent-styled segmented control (used for Mirror/Snapshot and Clean Up tabs).
class WinSegmentedControl<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final bool pill;

  const WinSegmentedControl({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.pill = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = WinPalette.of(context);
    final outerRadius = pill ? 999.0 : 7.0;
    final innerRadius = pill ? 999.0 : 5.0;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.segTrack,
        borderRadius: BorderRadius.circular(outerRadius),
        border: Border.all(color: p.borderSoft, width: 1),
      ),
      child: Row(
        mainAxisSize: pill ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final (v, label) in items)
            if (pill)
              _buildItem(p, v, label, innerRadius)
            else
              Expanded(child: _buildItem(p, v, label, innerRadius)),
        ],
      ),
    );
  }

  Widget _buildItem(WinPalette p, T v, String label, double radius) {
    final active = v == value;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? p.segThumb : const Color(0x00000000),
            borderRadius: BorderRadius.circular(radius),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: p.dark
                          ? const Color(0x33000000)
                          : const Color(0x14000000),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              color: active ? p.textPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Format an Android `ls -lA` modified string (`YYYY-MM-DD HH:MM`) into a
/// compact human-friendly timestamp (`Today 22:05`, `Yesterday`, `Oct 12`).
String formatShortModified(String raw, {DateTime? now}) {
  final dt = AppController.parseRemoteModified(raw);
  if (dt == null) return raw;
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  String two(int n) => n.toString().padLeft(2, '0');
  if (diff == 0) return 'Today ${two(dt.hour)}:${two(dt.minute)}';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return '$diff days ago';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  if (dt.year == ref.year) return '${months[dt.month - 1]} ${dt.day}';
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
}

/// Render a Backup Status badge for an entry in the Device Folders table.
Widget buildBackupStatusBadge(
  BuildContext context,
  EntryBackupStatus status,
) {
  final p = WinPalette.of(context);
  return switch (status) {
    EntryBackupStatus.backedUp => WinPill(
        label: 'Backed up',
        color: p.accentSoftFg,
        background: p.accentSoft,
      ),
    EntryBackupStatus.modified => WinPill(
        label: 'Modified',
        color: p.warnFg,
        background: p.warnBg,
      ),
    EntryBackupStatus.partial => WinPill(
        label: 'Partial',
        color: p.dark ? const Color(0xFF99D1FF) : const Color(0xFF0D478A),
        background: p.dark ? const Color(0xFF1B334D) : const Color(0xFFD8EAFC),
        borderColor: p.dark ? const Color(0xFF2F567D) : const Color(0xFFA6CDF5),
      ),
    EntryBackupStatus.notBackedUp => WinPill(
        label: 'Not backed up',
        color: p.neutralPillFg,
        background: p.neutralPillBg,
      ),
    EntryBackupStatus.checking => const Padding(
        padding: EdgeInsets.only(left: 4),
        child: SizedBox(
          width: 11,
          height: 11,
          child: ProgressRing(strokeWidth: 1.6),
        ),
      ),
    EntryBackupStatus.unknown => Text(
        '—',
        style: TextStyle(fontSize: 11.5, color: p.textTertiary),
      ),
  };
}
