#!/usr/bin/env bash
# Regenerate ACAB firmware parts for the web flasher (ESP Web Tools).
# Builds the three PlatformIO envs, then stages bootloader + partitions + boot_app0 +
# app as SEPARATE parts, each flashed at its own offset. Keeping them separate (rather
# than one merged blob from 0x0) leaves the NVS partition (0x9000) untouched, so a
# no-erase web-flash PRESERVES the BLE bond + ignore list (no re-pair on a firmware update).
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
# Stage the four flash parts SEPARATELY (not one merged blob). esp-web-tools writes
# each at its own offset, so the NVS partition (0x9000, the gap between partitions and
# boot_app0) is never overwritten and a no-erase web-flash keeps the BLE bond + whitelist.
rm -f "$ROOT/web/firmware"/acab-*.bin
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  B="$FW/.pio/build/$ENV"
  echo ">> staging parts for $ENV"
  cp "$B/bootloader.bin" "$ROOT/web/firmware/acab-$ENV-bootloader.bin"
  cp "$B/partitions.bin" "$ROOT/web/firmware/acab-$ENV-partitions.bin"
  cp "$BOOT_APP0"        "$ROOT/web/firmware/acab-$ENV-boot_app0.bin"
  cp "$B/firmware.bin"   "$ROOT/web/firmware/acab-$ENV-app.bin"
  echo "   -> acab-$ENV-{bootloader,partitions,boot_app0,app}.bin"
done
echo ">> done. Serve web/ over localhost or HTTPS to flash."
