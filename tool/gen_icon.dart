// Generates windows/runner/resources/app_icon.ico.
//
//   dart run tool/gen_icon.dart [--preview]
//
// Every frame is drawn at its own target size rather than downscaled from one
// master: an icon that is legible at 256 is mush at 16, so the small frames
// drop detail instead of shrinking it. Each frame is rendered 8x oversampled
// and box-filtered down, which is what antialiases the edges.
import 'dart:io';

import 'package:image/image.dart';

/// Windows asks for these; 16 is the titlebar, 24/32 the taskbar (depending on
/// DPI), 48/256 Explorer, the rest are for scaled displays.
const sizes = [256, 128, 96, 64, 48, 40, 32, 24, 20, 16];

const ss = 8; // oversampling factor

// Tile gradient. Android green at the top, deepened toward the bottom so the
// white glyph keeps contrast (pure #3DDC84 under white is nearly invisible).
final tileTop = ColorRgba8(0x3D, 0xDC, 0x84, 255);
final tileBottom = ColorRgba8(0x0E, 0x9F, 0x5B, 255);

final white = ColorRgba8(255, 255, 255, 255);
final black = ColorRgba8(0, 0, 0, 255);

Image renderFrame(int size) {
  final s = size * ss;
  int px(double f) => (f * s).round();

  // ---- tile: rounded square, full bleed, vertical gradient ----
  final tile = Image(width: s, height: s, numChannels: 4);
  fillRect(tile,
      x1: 0, y1: 0, x2: s - 1, y2: s - 1, color: white, radius: px(0.225));
  for (final p in tile) {
    if (p.a == 0) continue;
    final t = p.y / (s - 1);
    p.setRgba(
      tileTop.r + (tileBottom.r - tileTop.r) * t,
      tileTop.g + (tileBottom.g - tileTop.g) * t,
      tileTop.b + (tileBottom.b - tileTop.b) * t,
      255,
    );
  }

  // ---- glyph mask: white = paint white, black = let the tile show ----
  final mask = Image(width: s, height: s, numChannels: 4);
  fillRect(mask, x1: 0, y1: 0, x2: s - 1, y2: s - 1, color: black);

  if (size <= 24) {
    // A phone with an arrow inside it is two nested shapes, and at 24px and
    // below the inner one has no pixels left to be read with — it silts up
    // into a blob. Keep the half of the idea that survives: the arrow, drawn
    // white and big enough to be unmistakable in a titlebar.
    fillRect(mask,
        x1: px(0.42), y1: px(0.20), x2: px(0.58), y2: px(0.60), color: white);
    fillPolygon(mask, vertices: [
      Point(px(0.31), px(0.55)),
      Point(px(0.69), px(0.55)),
      Point(px(0.5), px(0.80)),
    ], color: white);
  } else {
    // Filled phone with the arrow knocked out of it. Solid mass survives
    // downscaling in a way thin outlines do not.
    fillRect(mask,
        x1: px(0.27),
        y1: px(0.155),
        x2: px(0.73),
        y2: px(0.845),
        color: white,
        radius: px(0.075));

    fillRect(mask,
        x1: px(0.435), y1: px(0.27), x2: px(0.565), y2: px(0.56),
        color: black);
    fillPolygon(mask, vertices: [
      Point(px(0.365), px(0.55)),
      Point(px(0.635), px(0.55)),
      Point(px(0.5), px(0.735)),
    ], color: black);

    // Speaker slit and home bar only where there are pixels to spare; below 48
    // they collapse into the phone edge and just read as dirt.
    if (size >= 48) {
      fillRect(mask,
          x1: px(0.45), y1: px(0.19), x2: px(0.55), y2: px(0.213),
          color: black, radius: px(0.011));
      fillRect(mask,
          x1: px(0.435), y1: px(0.787), x2: px(0.565), y2: px(0.81),
          color: black, radius: px(0.011));
    }
  }

  for (final p in tile) {
    if (mask.getPixel(p.x, p.y).r > 127) p.setRgba(255, 255, 255, p.a);
  }

  return copyResize(tile,
      width: size, height: size, interpolation: Interpolation.average);
}

void main(List<String> args) {
  final frames = [for (final s in sizes) renderFrame(s)];

  if (args.contains('--preview')) {
    // Contact sheet of the sizes that actually decide whether this works,
    // pixel-doubled on light and dark, plus 256 at 1:1 for the shape.
    const zoom = 12;
    const shown = [16, 20, 24, 32, 40, 48, 64];
    final picked = [for (final s in shown) frames[sizes.indexOf(s)]];
    const pad = 16;
    final w = shown.fold(pad, (a, s) => a + s * zoom + pad) + 256 + pad;
    final h = 64 * zoom + pad * 2;
    final sheet = Image(width: w, height: h * 2, numChannels: 4);
    fillRect(sheet,
        x1: 0, y1: 0, x2: w - 1, y2: h - 1,
        color: ColorRgba8(243, 243, 243, 255));
    fillRect(sheet,
        x1: 0, y1: h, x2: w - 1, y2: h * 2 - 1,
        color: ColorRgba8(32, 32, 32, 255));
    var x = pad;
    for (var i = 0; i < shown.length; i++) {
      final big = copyResize(picked[i],
          width: shown[i] * zoom,
          height: shown[i] * zoom,
          interpolation: Interpolation.nearest);
      final y = h - pad - big.height; // sit them on a common baseline
      compositeImage(sheet, big, dstX: x, dstY: y);
      compositeImage(sheet, big, dstX: x, dstY: h + y);
      x += big.width + pad;
    }
    final full = frames[sizes.indexOf(256)];
    compositeImage(sheet, full, dstX: x, dstY: h - pad - 256);
    compositeImage(sheet, full, dstX: x, dstY: h * 2 - pad - 256);
    File('preview_icon.png').writeAsBytesSync(encodePng(sheet));
    stdout.writeln('Wrote preview_icon.png');
    return;
  }

  final ico = IcoEncoder().encodeImages(frames);
  File('windows/runner/resources/app_icon.ico').writeAsBytesSync(ico);
  stdout.writeln('Wrote app_icon.ico (${ico.length} bytes, sizes: $sizes)');
}
