#!/usr/bin/env bash
# Renders a 1024x1024 macOS app icon SVG (e.g. tool/macos_icon.svg or
# tool/macos_icon_f2_lean.svg) into all 7 PNG sizes under
# macos/Runner/Assets.xcassets/AppIcon.appiconset/ with true alpha transparency.
#
# Usage:
#   ./tool/render_macos_icon.sh [path/to/icon.svg]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG_ARG="${1:-$ROOT/tool/macos_icon.svg}"
SVG="$(cd "$(dirname "$SVG_ARG")" && pwd)/$(basename "$SVG_ARG")"
OUT_DIR="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

if [[ ! -f "$SVG" ]]; then
  echo "SVG not found: $SVG" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/af_icon_render.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

{
  cat <<'HTML_TOP'
<!doctype html>
<html>
<head><meta charset="utf-8"><style>
  html, body { margin: 0; padding: 0; width: 1024px; height: 1024px; background: transparent !important; overflow: hidden; }
  svg { display: block; width: 1024px; height: 1024px; }
</style></head>
<body>
HTML_TOP
  cat "$SVG"
  cat <<'HTML_BOT'
</body>
</html>
HTML_BOT
} > "$TMP_DIR/render.html"

"$CHROME" \
  --headless=new \
  --no-sandbox \
  --disable-gpu \
  --default-background-color=00000000 \
  --user-data-dir="$TMP_DIR/profile" \
  --window-size=1024,1024 \
  --force-device-scale-factor=1 \
  --screenshot="$OUT_DIR/app_icon_1024.png" \
  "file://$TMP_DIR/render.html" 2>/dev/null

for sz in 512 256 128 64 32 16; do
  sips -z "$sz" "$sz" "$OUT_DIR/app_icon_1024.png" --out "$OUT_DIR/app_icon_${sz}.png" >/dev/null
done

# Also generate Windows app_icon.ico and website docs/favicon.ico from the same
# SVG, cropped tightly (888x888 centered around the 824px squircle) so the icon
# fills ~93% of the Windows taskbar, Explorer, and browser tab tiles cleanly.
WIN_ICO="$ROOT/windows/runner/resources/app_icon.ico"
FAV_ICO="$ROOT/docs/favicon.ico"
WIN_BASE="$TMP_DIR/win_base.png"
sips -c 888 888 "$OUT_DIR/app_icon_1024.png" --out "$WIN_BASE" >/dev/null

for sz in 256 128 64 48 32 24 16; do
  sips -z "$sz" "$sz" "$WIN_BASE" --out "$TMP_DIR/win_${sz}.png" >/dev/null
done

python3 - "$TMP_DIR" "$WIN_ICO" "$FAV_ICO" <<'PY'
import os, struct, sys

tmp_dir, win_ico, fav_ico = sys.argv[1:4]

def build_ico(out_path, sizes):
    entries = []
    for sz in sizes:
        with open(os.path.join(tmp_dir, f"win_{sz}.png"), "rb") as f:
            entries.append((sz, f.read()))
    header = struct.pack("<HHH", 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    directory = bytearray()
    payload = bytearray()
    for sz, png in entries:
        dim = 0 if sz >= 256 else sz
        directory += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset)
        payload += png
        offset += len(png)
    with open(out_path, "wb") as f:
        f.write(header + directory + payload)

build_ico(win_ico, [16, 24, 32, 48, 64, 128, 256])
build_ico(fav_ico, [16, 32, 48])
PY

echo "Generated macOS AppIcon PNGs, Windows app_icon.ico, and docs/favicon.ico from $SVG"
ls -lh "$OUT_DIR"/app_icon_*.png "$WIN_ICO" "$FAV_ICO"
