#!/usr/bin/env bash
# Regenerate ACAB merged firmware images for the web flasher (ESP Web Tools).
# Builds both PlatformIO envs, then merges bootloader + partitions + boot_app0 +
# app into one image to be flashed at offset 0x0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/firmware"
PY="$HOME/.platformio/penv/bin/python"
ESPTOOL="$HOME/.platformio/packages/tool-esptoolpy/esptool.py"
BOOT_APP0="$(find "$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions" -name boot_app0.bin | head -1)"

[ -x "$PY" ] || { echo "PlatformIO python not found at $PY"; exit 1; }
[ -n "$BOOT_APP0" ] || { echo "boot_app0.bin not found - build the firmware once first"; exit 1; }

echo ">> building firmware (oui-spy, mesh-detect, mesh-detect-ch1)"
( cd "$FW" && pio run -e oui-spy -e mesh-detect -e mesh-detect-ch1 )

# Stamp the firmware version (single source of truth: acab_version.h) into the web
# manifests + page footer, so the flasher's displayed version can never drift from
# what the firmware actually reports.
VER="$(sed -nE 's/.*ACAB_FW_VERSION[[:space:]]*"([^"]+)".*/\1/p' "$FW/lib/acab_core/acab_version.h")"
if [ -n "$VER" ]; then
  echo ">> stamping version $VER into manifests + footer"
  "$PY" - "$VER" "$ROOT" <<'PY'
import sys, re, glob, os
ver, root = sys.argv[1], sys.argv[2]
for m in glob.glob(os.path.join(root, "web", "manifest-*.json")):
    s = open(m).read()
    s = re.sub(r'("version":\s*")[^"]*(")', lambda mo: mo.group(1) + ver + mo.group(2), s)
    open(m, "w").write(s)
idx = os.path.join(root, "web", "index.html")
h = open(idx).read()
h = re.sub(r'(All Cameras Are Beacons v)[0-9][0-9A-Za-z.+-]*', lambda mo: mo.group(1) + ver, h)
open(idx, "w").write(h)
print("   manifests + footer set to", ver)
PY
else
  echo ">> WARNING: could not read ACAB_FW_VERSION; manifests/footer left unchanged"
fi

mkdir -p "$ROOT/web/firmware"
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  B="$FW/.pio/build/$ENV"
  OUT="$ROOT/web/firmware/acab-$ENV.bin"
  echo ">> merging $ENV"
  "$PY" "$ESPTOOL" --chip esp32s3 merge_bin -o "$OUT" \
    --flash_mode dio --flash_freq 80m --flash_size 8MB \
    0x0     "$B/bootloader.bin" \
    0x8000  "$B/partitions.bin" \
    0xe000  "$BOOT_APP0" \
    0x10000 "$B/firmware.bin"
  echo "   -> $OUT"
done
echo ">> done. Serve web/ over localhost or HTTPS to flash."
