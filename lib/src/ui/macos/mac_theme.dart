import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';

/// Native-feeling macOS HIG palette & atoms for Proposal A (Finder & Inspector).
class MacPalette {
  final Brightness brightness;
  final Color green;
  final Color greenBright;
  final Color greenSoft;
  final Color greenBorder;
  final Color greenButtonText;
  final Color amber;
  final Color amberSoft;
  final Color red;
  final Color redSoft;
  final Color folderTop;
  final Color folderBody;
  final Color windowBg;
  final Color sidebarBg;
  final Color toolbarBg;
  final Color inspectorBg;
  final Color surface;
  final Color surfaceHover;
  final Color surfaceSelected;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color controlBg;
  final Color segTrack;
  final Color segThumb;
  final Color logBg;
  final Color checkboxBorder;
  final Color capacityUsed;

  const MacPalette({
    required this.brightness,
    required this.green,
    required this.greenBright,
    required this.greenSoft,
    required this.greenBorder,
    required this.greenButtonText,
    required this.amber,
    required this.amberSoft,
    required this.red,
    required this.redSoft,
    required this.folderTop,
    required this.folderBody,
    required this.windowBg,
    required this.sidebarBg,
    required this.toolbarBg,
    required this.inspectorBg,
    required this.surface,
    required this.surfaceHover,
    required this.surfaceSelected,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.controlBg,
    required this.segTrack,
    required this.segThumb,
    required this.logBg,
    required this.checkboxBorder,
    required this.capacityUsed,
  });

  bool get isDark => brightness == Brightness.dark;

  static const light = MacPalette(
    brightness: Brightness.light,
    green: Color(0xFF22A055),
    greenBright: Color(0xFF28C858),
    greenSoft: Color(0x2122A055),
    greenBorder: Color(0x4D22A055),
    greenButtonText: Color(0xFFFFFFFF),
    amber: Color(0xFFD97706),
    amberSoft: Color(0x21D97706),
    red: Color(0xFFE5484D),
    redSoft: Color(0x21E5484D),
    folderTop: Color(0xFF6CC4FF),
    folderBody: Color(0xFF3AA5F5),
    windowBg: Color(0xFFFFFFFF),
    sidebarBg: Color(0xFFF3F4F6),
    toolbarBg: Color(0xFFF9F9FB),
    inspectorBg: Color(0xFFF6F7F9),
    surface: Color(0xFFFFFFFF),
    surfaceHover: Color(0x0B000000),
    surfaceSelected: Color(0x1F22A055),
    border: Color(0x17000000),
    borderStrong: Color(0x24000000),
    textPrimary: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF636366),
    textTertiary: Color(0xFF8E8E93),
    controlBg: Color(0xFFFFFFFF),
    segTrack: Color(0x0F000000),
    segThumb: Color(0xFFFFFFFF),
    logBg: Color(0xFFF5F6F8),
    checkboxBorder: Color(0x40000000),
    capacityUsed: Color(0x59787D87),
  );

  static const dark = MacPalette(
    brightness: Brightness.dark,
    green: Color(0xFF30D158),
    greenBright: Color(0xFF34D960),
    greenSoft: Color(0x2930D158),
    greenBorder: Color(0x5230D158),
    greenButtonText: Color(0xFF06210E),
    amber: Color(0xFFFF9F0A),
    amberSoft: Color(0x29FF9F0A),
    red: Color(0xFFFF453A),
    redSoft: Color(0x29FF453A),
    folderTop: Color(0xFF74C7FF),
    folderBody: Color(0xFF399BE8),
    windowBg: Color(0xFF1E1F23),
    sidebarBg: Color(0xFF26282E),
    toolbarBg: Color(0xFF222429),
    inspectorBg: Color(0xFF24262B),
    surface: Color(0xFF292B31),
    surfaceHover: Color(0x0FFFFFFF),
    surfaceSelected: Color(0x2630D158),
    border: Color(0x17FFFFFF),
    borderStrong: Color(0x29FFFFFF),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0xFFA1A1A6),
    textTertiary: Color(0xFF6E6E73),
    controlBg: Color(0x14FFFFFF),
    segTrack: Color(0x14FFFFFF),
    segThumb: Color(0x29FFFFFF),
    logBg: Color(0xFF17181C),
    checkboxBorder: Color(0x47FFFFFF),
    capacityUsed: Color(0x598E95A3),
  );

  static MacPalette of(BuildContext context) =>
      CupertinoTheme.brightnessOf(context) == Brightness.dark ? dark : light;
}

const tabularFigures = [FontFeature.tabularFigures()];

const macMonoFont = 'SF Mono';

/// Channel wired to [MainFlutterWindow] for native titlebar drag and zoom.
const _windowChannel = MethodChannel('androidfiles/window');

class MacWindowDragArea extends StatelessWidget {
  final Widget child;
  const MacWindowDragArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _windowChannel.invokeMethod<void>('startDrag'),
      onDoubleTap: () =>
          _windowChannel.invokeMethod<void>('titlebarDoubleClick'),
      child: child,
    );
  }
}

/// Uppercase subtle macOS section header (e.g. DEVICES, PROFILES, BACKUP TARGET).
class MacSectionHeader extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const MacSectionHeader(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
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

/// Crisp macOS toolbar icon/label button with subtle hover pill.
class MacToolbarButton extends StatefulWidget {
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool active;
  final Color? iconColor;
  final VoidCallback? onPressed;

  const MacToolbarButton({
    super.key,
    required this.icon,
    this.label,
    this.tooltip,
    this.active = false,
    this.iconColor,
    required this.onPressed,
  });

  @override
  State<MacToolbarButton> createState() => _MacToolbarButtonState();
}

class _MacToolbarButtonState extends State<MacToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final enabled = widget.onPressed != null;
    final bg = widget.active
        ? p.greenSoft
        : (_hovered && enabled ? p.surfaceHover : const Color(0x00000000));
    final fg = !enabled
        ? p.textTertiary.withValues(alpha: 0.5)
        : widget.iconColor ??
            (widget.active
                ? p.green
                : (_hovered ? p.textPrimary : p.textSecondary));

    final btn = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          height: 28,
          padding: EdgeInsets.symmetric(
            horizontal: widget.label != null ? 9 : 7,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 15, color: fg),
              if (widget.label != null) ...[
                const SizedBox(width: 5),
                Text(
                  widget.label!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (widget.tooltip == null) return btn;
    return Tooltip(message: widget.tooltip!, child: btn);
  }
}

/// Classic bordered macOS secondary push button.
class MacPushButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final bool destructive;
  final double height;
  final EdgeInsetsGeometry padding;

  const MacPushButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.destructive = false,
    this.height = 28,
    this.padding = const EdgeInsets.symmetric(horizontal: 11),
  });

  @override
  State<MacPushButton> createState() => _MacPushButtonState();
}

class _MacPushButtonState extends State<MacPushButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final enabled = widget.onPressed != null;
    final textColor = !enabled
        ? p.textTertiary
        : widget.destructive
            ? p.red
            : p.textPrimary;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: Container(
          height: widget.height,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: !enabled
                ? p.controlBg.withValues(alpha: 0.6)
                : _pressed
                    ? p.surfaceHover
                    : _hovered
                        ? (p.isDark
                            ? const Color(0x1FFFFFFF)
                            : const Color(0xFFF7F8FA))
                        : p.controlBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: p.borderStrong, width: 0.75),
            boxShadow: p.isDark || !enabled
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 1.5,
                      offset: Offset(0, 1),
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
            child: IconTheme.merge(
              data: IconThemeData(size: 14, color: textColor),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Emerald green macOS primary CTA button.
class MacPrimaryButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double height;
  final bool expand;

  const MacPrimaryButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.height = 34,
    this.expand = true,
  });

  @override
  State<MacPrimaryButton> createState() => _MacPrimaryButtonState();
}

class _MacPrimaryButtonState extends State<MacPrimaryButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final enabled = widget.onPressed != null;

    final topColor = p.isDark
        ? (_pressed
            ? const Color(0xFF28B84E)
            : _hovered
                ? const Color(0xFF3CE068)
                : const Color(0xFF32D15E))
        : (_pressed
            ? const Color(0xFF1D8E49)
            : _hovered
                ? const Color(0xFF2DC56A)
                : const Color(0xFF28B862));
    final bottomColor = p.isDark
        ? (_pressed ? const Color(0xFF1F9A40) : const Color(0xFF24B24C))
        : (_pressed ? const Color(0xFF177B3E) : const Color(0xFF1F9A50));

    final fg = enabled ? p.greenButtonText : p.textTertiary;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onPressed,
        child: Container(
          width: widget.expand ? double.infinity : null,
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: enabled ? null : p.segTrack,
            gradient: enabled
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [topColor, bottomColor],
                  )
                : null,
            borderRadius: BorderRadius.circular(8),
            border: enabled
                ? Border.all(
                    color: p.isDark
                        ? const Color(0x33FFFFFF)
                        : const Color(0x26000000),
                    width: 0.5,
                  )
                : Border.all(color: p.border, width: 0.5),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: p.isDark
                          ? const Color(0x55000000)
                          : const Color(0x45188242),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
            child: IconTheme.merge(
              data: IconThemeData(size: 15, color: fg),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Crisp 14x14 rounded macOS checkbox.
class MacCheckbox extends StatelessWidget {
  final bool checked;
  final VoidCallback onTap;
  const MacCheckbox({super.key, required this.checked, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          width: 14.5,
          height: 14.5,
          decoration: BoxDecoration(
            color: checked ? p.green : p.controlBg,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: checked ? p.green : p.checkboxBorder,
              width: 1.15,
            ),
          ),
          alignment: Alignment.center,
          child: checked
              ? Icon(
                  CupertinoIcons.check_mark,
                  size: 10,
                  color: p.greenButtonText,
                )
              : null,
        ),
      ),
    );
  }
}

/// Compact macOS toggle switch (28x16) for Inspector rows.
class MacSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const MacSwitch({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          width: 28,
          height: 16,
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            color: value ? p.green : p.segTrack,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: value ? const Color(0x00000000) : p.borderStrong,
              width: 0.7,
            ),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: Color(0xFFFFFFFF),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x38000000),
                    blurRadius: 2,
                    offset: Offset(0, 0.8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// macOS pill segmented control (e.g. Mirror | Snapshot, Light | Dark | System).
class MacSegmentedControl<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  const MacSegmentedControl({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.segTrack,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          for (final (itemValue, label) in items)
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => onChanged(itemValue),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 130),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4.5,
                    ),
                    decoration: BoxDecoration(
                      color: value == itemValue
                          ? p.segThumb
                          : const Color(0x00000000),
                      borderRadius: BorderRadius.circular(5.5),
                      boxShadow: value == itemValue
                          ? [
                              BoxShadow(
                                color: p.isDark
                                    ? const Color(0x4D000000)
                                    : const Color(0x1E000000),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: value == itemValue
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: value == itemValue
                            ? p.textPrimary
                            : p.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Layered aqua-blue macOS folder icon.
class MacFolderIcon extends StatelessWidget {
  final double width;
  final double height;
  final bool dimmed;
  const MacFolderIcon({
    super.key,
    this.width = 16,
    this.height = 13,
    this.dimmed = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    final opacity = dimmed ? 0.55 : 1.0;
    return Opacity(
      opacity: opacity,
      child: CustomPaint(
        size: Size(width, height),
        painter: _MacFolderPainter(top: p.folderTop, body: p.folderBody),
      ),
    );
  }
}

class _MacFolderPainter extends CustomPainter {
  final Color top;
  final Color body;
  const _MacFolderPainter({required this.top, required this.body});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final tabPath = Path()
      ..moveTo(0, h * 0.22)
      ..quadraticBezierTo(0, 0, w * 0.14, 0)
      ..lineTo(w * 0.36, 0)
      ..quadraticBezierTo(w * 0.43, 0, w * 0.48, h * 0.12)
      ..lineTo(w * 0.54, h * 0.20)
      ..lineTo(w * 0.88, h * 0.20)
      ..quadraticBezierTo(w, h * 0.20, w, h * 0.34)
      ..lineTo(w, h * 0.86)
      ..quadraticBezierTo(w, h, w * 0.88, h)
      ..lineTo(w * 0.12, h)
      ..quadraticBezierTo(0, h, 0, h * 0.86)
      ..close();

    canvas.drawPath(tabPath, Paint()..color = top);

    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, h * 0.28, w, h * 0.72),
      Radius.circular(h * 0.14),
    );
    canvas.drawRRect(bodyRect, Paint()..color = body);
  }

  @override
  bool shouldRepaint(_MacFolderPainter old) =>
      old.top != top || old.body != body;
}

/// Compact pill chip with optional live dot.
class MacStatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Color background;
  final Color? borderColor;
  final bool showDot;

  const MacStatusPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
    this.borderColor,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7.5, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: borderColor != null
            ? Border.all(color: borderColor!, width: 0.75)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 5.5,
              height: 5.5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4.5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: tabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

/// Crisp macOS text field with subtle border and optional leading widget.
class MacTextField extends StatelessWidget {
  final TextEditingController controller;
  final String? placeholder;
  final Widget? prefix;
  final int maxLines;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final bool monospace;

  const MacTextField({
    super.key,
    required this.controller,
    this.placeholder,
    this.prefix,
    this.maxLines = 1,
    this.autofocus = false,
    this.onSubmitted,
    this.monospace = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return CupertinoTextField(
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
      placeholder: placeholder,
      onSubmitted: onSubmitted,
      prefix: prefix != null
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: prefix,
            )
          : null,
      padding: EdgeInsets.symmetric(
        horizontal: prefix != null ? 6 : 9,
        vertical: maxLines > 1 ? 7 : 5.5,
      ),
      style: TextStyle(
        fontSize: 12,
        fontFamily: monospace ? macMonoFont : null,
        color: p.textPrimary,
      ),
      placeholderStyle: TextStyle(
        fontSize: 12,
        color: p.textTertiary,
      ),
      decoration: BoxDecoration(
        color: p.controlBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.borderStrong, width: 0.75),
      ),
    );
  }
}

/// Clean macOS modal dialog sheet frame.
class MacDialogFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;

  const MacDialogFrame({
    super.key,
    required this.title,
    this.subtitle,
    required this.content,
    required this.actions,
    this.maxWidth = 460,
  });

  @override
  Widget build(BuildContext context) {
    final p = MacPalette.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: p.windowBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.borderStrong, width: 0.8),
            boxShadow: [
              BoxShadow(
                color: p.isDark
                    ? const Color(0x99000000)
                    : const Color(0x3D000000),
                blurRadius: 48,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 13,
              color: p.textPrimary,
              decoration: TextDecoration.none,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: p.textPrimary,
                      letterSpacing: -0.15,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: p.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Flexible(child: content),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        actions[i],
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
