#!/usr/bin/env bash
# Regenerate ACAB firmware parts for the web flasher (ESP Web Tools).
# Builds the three PlatformIO envs, then stages bootloader + partitions + boot_app0 +
# app as SEPARATE parts, each flashed at its own offset. Keeping them separate (rather
# than one merged blob from 0x0) leaves the NVS partition (0x9000) untouched, so a
# no-erase web-flash PRESERVES the BLE bond + ignore list (no re-pair on a firmware update).
#
# NOTE: this script handles oui-spy + mesh-detect only. The v2 beacon-board build +
# manifest + OTA stamping lives in the sibling site repo, at
# soyboi.tech/firmware/build-beacon-flasher.sh (the OTA-deploy tooling is split across the
# two repos). Run that one to refresh the beacon-board flasher and firmware-latest.json entry.
set -euo pipefail

# --unsigned-usb-only: explicitly stage an UNSIGNED cut (empty manifest sigs, in-app OTA disabled).
# Without it, a missing signing key ABORTS instead of warn-and-continue, matching release.sh's
# posture: the two entry points must not disagree, or the lenient one quietly publishes a manifest
# whose empty sig makes every in-app OTA fail in the field.
UNSIGNED_OK=0
for arg in "$@"; do
  case "$arg" in
    --unsigned-usb-only) UNSIGNED_OK=1 ;;
    *) echo "unknown argument: $arg (only --unsigned-usb-only is accepted)"; exit 1 ;;
  esac
done

# Vendor guard. web/index.html loads ./vendor/esp-web-tools/install-button.js as a module, and
# .github/workflows/pages.yml deploys `path: web` on any push touching web/**. All 28 files under
# web/vendor/esp-web-tools/ were UNTRACKED, with no .gitignore rule covering them, so a deploy
# published a flasher whose install button never loads: this script rewrites tracked files
# (index.html, manifest-*.json, firmware/*.bin) and the vendor graph they depend on silently
# stayed local. The sibling soyboi.tech repo does track its copy, so this was a one-repo gap.
# Refuse to stage a release against a vendor graph that will not ship.
# Checks HEAD, not the index, on purpose: `git ls-files` is satisfied by a bare `git add`, but
# Pages builds from the PUSHED COMMIT, so a staged-only vendor graph still deploys missing.
#
# Checks the WHOLE DIRECTORY, not just install-button.js, also on purpose. install-button.js is
# the only filename in there that is NOT content-hashed, so an esp-web-tools refresh keeps that
# one name and renames the other 26 JS chunks (28 files in all: 27 JS plus the LICENSE).
# `git commit -a` / `git add -u` pick up modifications to tracked paths and ignore new
# untracked ones, so the entry point alone lands in HEAD, an
# entry-point-only check passes, Pages deploys, and the flash button 404s partway through its
# dynamic imports - the exact runtime failure this guard was written for. Compare content, not
# just names: a chunk that is tracked but edited-and-uncommitted ships its OLD bytes, which an
# existence test cannot see either.
_VENDOR_DIR="web/vendor/esp-web-tools"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
_IN_HEAD="$(git -C "$ROOT" ls-tree -r --name-only HEAD -- "$_VENDOR_DIR" 2>/dev/null || true)"
# One `git status` answers both directions and the bytes: empty output means HEAD, the index and
# the disk agree. --ignored on purpose: a chunk that an ignore rule hides is still a chunk Pages
# would omit; the exclude pathspec keeps Finder's .DS_Store out of that. Keep the call a plain
# assignment (no pipe, no `|| true`) so a git failure aborts here under `set -e`. The -d test is
# for a sparse checkout, where status reports nothing for the absent directory.
# ponytail: status trusts the index, so an edited chunk with the assume-unchanged or
# skip-worktree bit set passes; hash the disk bytes against HEAD if that ever matters.
_DRIFT="$(git -C "$ROOT" status --porcelain --untracked-files=all --ignored -- "$_VENDOR_DIR" ':(exclude,glob)**/.DS_Store')"
if [ ! -d "$ROOT/$_VENDOR_DIR" ] || [ -z "$_IN_HEAD" ] || [ -n "$_DRIFT" ]; then
  echo "!! $_VENDOR_DIR on disk is not exactly what HEAD would deploy"
  echo "!! ( D = missing on disk, ?? = not committed, M = edited, A/M in column 1 = staged only, !! = gitignored):"
  echo "${_DRIFT:-(directory missing, or nothing committed under $_VENDOR_DIR)}" | sed 's/^/!!   /'
  echo "!! Fix: restore deleted chunks or add new ones, commit the complete vendor graph (see web/README.md), then re-run."
  exit 1
fi

FW="$ROOT/firmware"
# Signed OTA is the default contract. Check the key before even building, and sign frozen build
# outputs before arming the served-tree transaction below. A missing, encrypted/passphrase-only,
# or corrupt key must leave BOTH repositories byte-for-byte as they were when this command began.
OTA_KEY="$FW/tools/ota_signing/beacon_ota_key.pem"
if [ "$UNSIGNED_OK" != "1" ] && [ ! -f "$OTA_KEY" ]; then
  echo "!! OTA signing key not found at $OTA_KEY."
  echo "!! Restore the offline key, or pass --unsigned-usb-only for an explicitly unsigned cut."
  exit 1
fi
# Prefer PlatformIO's venv python, but fall back to system python3: a Homebrew upgrade of
# python@3.x leaves the penv symlink dangling, and the heredocs below are stdlib-only anyway.
PY="$HOME/.platformio/penv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
BOOT_APP0="$(find "$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions" -name boot_app0.bin | head -1)"

[ -x "$PY" ] || { echo "PlatformIO python not found at $PY"; exit 1; }

# A syntactically valid private key can still belong to another checkout/trust root. Prove the
# key's derived public DER is exactly what ota_pubkey.h bakes into every board before any build or
# served-tree mutation. The one exception is the declared rotation cut (release_tools.OTA_ROTATION):
# for that release the header bakes the NEW root and the key must be the RETIRING signer, so the
# line below reports the baked root, not a key match. USB-only mode intentionally has no
# signing-key dependency.
if [ "$UNSIGNED_OK" != "1" ]; then
  "$PY" - "$FW/tools" "$OTA_KEY" "$FW/lib/acab_core/ota_pubkey.h" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_tools import ReleaseToolError, require_ota_signing_key_identity
try:
    digest = require_ota_signing_key_identity(sys.argv[2], sys.argv[3])
except ReleaseToolError as exc:
    print(f"!! {exc}", file=sys.stderr)
    raise SystemExit(1)
print(f">> OTA signing key accepted for baked trust root ({digest[:12]})")
PY
fi

[ -n "$BOOT_APP0" ] || { echo "boot_app0.bin not found - build the firmware once first"; exit 1; }

STAGE_TMP="$(mktemp -d)"
STAGE_COMMITTED=0
ROLLBACK_ARMED=0
TRANSACTION_FILES=()

begin_served_transaction() {
  local rollback="$STAGE_TMP/rollback"
  mkdir -p "$rollback"
  local i target
  for i in "${!TRANSACTION_FILES[@]}"; do
    target="${TRANSACTION_FILES[$i]}"
    if [ -e "$target" ]; then
      cp -p "$target" "$rollback/$i"
      printf 'present\n' > "$rollback/$i.state"
    else
      printf 'missing\n' > "$rollback/$i.state"
    fi
  done
  ROLLBACK_ARMED=1
}

cleanup_stage() {
  local exit_status=$?
  trap - EXIT
  set +e
  if [ "$ROLLBACK_ARMED" = "1" ] && [ "$STAGE_COMMITTED" != "1" ]; then
    echo "!! staging failed; restoring both served trees to their previous coherent release"
    local rollback="$STAGE_TMP/rollback"
    local i target
    for i in "${!TRANSACTION_FILES[@]}"; do
      target="${TRANSACTION_FILES[$i]}"
      if [ "$(< "$rollback/$i.state")" = "present" ]; then
        cp -p "$rollback/$i" "$target"
      else
        rm -f "$target"
      fi
    done
  fi
  rm -rf "$STAGE_TMP"
  exit "$exit_status"
}
trap cleanup_stage EXIT

echo ">> building firmware (oui-spy, mesh-detect, mesh-detect-ch1)"
( cd "$FW" && pio run -e oui-spy -e mesh-detect -e mesh-detect-ch1 )

# Stamp the firmware version (single source of truth: acab_version.h) into the web
# manifests + page footer, so the flasher's displayed version can never drift from
# what the firmware actually reports.
#
# Use the same complete grammar as release.sh, the rev-B stager, and the production verifier.
# Prefix parsing is not validation: the board reads only three numeric fields, while both apps
# reject empty/nonnumeric fields and compare a fourth field if one is allowed through. A label
# such as 2..6, 2.0.x, 2.0.6+meta or 2.0.6.1 must die before fresh binaries are copied under it.
if ! VER="$("$PY" - "$FW" <<'PY'
import os, sys
firmware = sys.argv[1]
sys.path.insert(0, os.path.join(firmware, "tools"))
from release_tools import ReleaseToolError, declared_versions
try:
    print(declared_versions(firmware)[0])
except (OSError, ReleaseToolError) as exc:
    print(f"!! {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
  echo "!! could not read a single OTA-compatible ACAB_FW_VERSION from acab_version.h."
  echo "!! Refusing to stage: the binaries would be new while the manifests and the page footer"
  echo "!! still advertise the previous version, and a plain push to Pages runs no verifier."
  exit 1
fi

# Freeze every build output once. Signatures, hashes and both served copies consume these bytes,
# so a concurrent/retried PlatformIO build cannot create a check-then-copy generation split.
PAYLOAD_DIR="$STAGE_TMP/payloads"
mkdir -p "$PAYLOAD_DIR"
cp "$BOOT_APP0" "$PAYLOAD_DIR/boot_app0.bin"
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  B="$FW/.pio/build/$ENV"
  for PART in bootloader partitions firmware; do
    [ -f "$B/$PART.bin" ] || { echo "!! missing $B/$PART.bin after build"; exit 1; }
  done
  cp "$B/bootloader.bin" "$PAYLOAD_DIR/acab-$ENV-bootloader.bin"
  cp "$B/partitions.bin" "$PAYLOAD_DIR/acab-$ENV-partitions.bin"
  cp "$PAYLOAD_DIR/boot_app0.bin" "$PAYLOAD_DIR/acab-$ENV-boot_app0.bin"
  cp "$B/firmware.bin" "$PAYLOAD_DIR/acab-$ENV-app.bin"
done

# Locate and validate the app-facing sibling manifest before replacing a single served byte. The
# sibling is optional for the standalone public-USB builder, but when present its schema, keys and
# exact artifact URLs are part of this transaction.
SIBLING="$(cd "$ROOT/.." && cd soyboi.tech/firmware 2>/dev/null && pwd || true)"
SIBLING_ACTIVE=0
if [ -n "$SIBLING" ] && [ -f "$SIBLING/firmware-latest.json" ]; then
  SIBLING_ACTIVE=1
  "$PY" - "$SIBLING/firmware-latest.json" "$FW/tools" <<'PY'
import json, sys
manifest_path, tools_dir = sys.argv[1], sys.argv[2]
sys.path.insert(0, tools_dir)
from release_tools import require_manifest_builds, require_ota_firmware_url
required = {
    "ACAB-ouispy": "acab-oui-spy-app.bin",
    "mesh-detect-ACAB": "acab-mesh-detect-app.bin",
    "mesh-detect-ACAB-ch1": "acab-mesh-detect-ch1-app.bin",
}
manifest = json.load(open(manifest_path))
builds = require_manifest_builds(manifest, required, manifest_path)
for label, filename in required.items():
    app = builds[label].get("app")
    if not isinstance(app, dict):
        raise SystemExit("!! %s build %r has no app object" % (manifest_path, label))
    require_ota_firmware_url(app.get("url"), filename, "%s build %r" % (manifest_path, label))
PY
fi

# Sign the frozen app payloads BEFORE mutation. `-passin pass:` deliberately makes an encrypted
# key fail non-interactively: release tooling has no passphrase channel, and waiting on a hidden
# terminal prompt halfway through a cut is neither usable nor fail-closed.
sig_hex() {
  if [ "$UNSIGNED_OK" = "1" ]; then return 0; fi
  local input="$1" tmp="$STAGE_TMP/$(basename "$1").sig" err="$STAGE_TMP/$(basename "$1").err"
  if openssl dgst -sha256 -passin pass: -sign "$OTA_KEY" "$input" > "$tmp" 2> "$err"; then
    if [ ! -s "$tmp" ]; then
      echo "!! openssl returned success but produced an empty signature for $(basename "$input")" >&2
      return 1
    fi
    if ! xxd -p "$tmp" | tr -d '\n'; then
      echo "!! could not hex-encode the signature for $(basename "$input")" >&2
      return 1
    fi
    return 0
  fi
  {
    echo "!! could not sign $(basename "$input") with $OTA_KEY:"
    sed 's/^/!!   /' "$err"
    echo "!! No served artifact has changed. Fix the key, or pass --unsigned-usb-only for an"
    echo "!! explicitly unsigned USB-only cut."
  } >&2
  return 1
}

if [ "$UNSIGNED_OK" = "1" ]; then
  echo "!! --unsigned-usb-only: signatures deliberately empty and in-app OTA disabled"
fi
SIG_OUISPY="$(sig_hex "$PAYLOAD_DIR/acab-oui-spy-app.bin")" || exit 1
SIG_MESH="$(sig_hex "$PAYLOAD_DIR/acab-mesh-detect-app.bin")" || exit 1
SIG_MESH_CH1="$(sig_hex "$PAYLOAD_DIR/acab-mesh-detect-ch1-app.bin")" || exit 1

# From here on, every path the command may replace is covered by one cross-repository rollback.
# The manifests are included along with their payloads; a late stamp/copy failure therefore cannot
# leave either hosting tree in a publishable old-metadata/new-bytes mixture.
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  for PART in bootloader partitions boot_app0 app; do
    TRANSACTION_FILES+=("$ROOT/web/firmware/acab-$ENV-$PART.bin")
  done
done
TRANSACTION_FILES+=(
  "$ROOT/web/manifest-oui-spy.json"
  "$ROOT/web/manifest-mesh-detect.json"
  "$ROOT/web/manifest-mesh-detect-ch1.json"
  "$ROOT/web/index.html"
)
if [ "$SIBLING_ACTIVE" = "1" ]; then
  TRANSACTION_FILES+=(
    "$SIBLING/acab-oui-spy-app.bin"
    "$SIBLING/acab-mesh-detect-app.bin"
    "$SIBLING/acab-mesh-detect-ch1-app.bin"
    "$SIBLING/firmware-latest.json"
  )
fi
begin_served_transaction

echo ">> stamping version $VER into manifests + footer"
"$PY" - "$VER" "$ROOT" <<'PY'
import sys, re, glob, os
ver, root = sys.argv[1], sys.argv[2]
# subn, not sub: a substitution that matched NOTHING rewrote the file unchanged and the success
# line below still printed, so a footer or a manifest whose wording drifted off these patterns
# would keep advertising the PREVIOUS release to the person about to flash a board, with nothing
# to say so. verify-release-artifacts.py checks both halves (the manifest versions and the
# index.html footer), but only under --production --profile colonel-panic|all, i.e. only when
# release.sh drives it; the ordinary build-and-push path documented in web/README.md runs no
# verifier, and pages.yml deploys web/ without one either. The writer has to fail where it writes.
# Exactly one hit per file is the rule: each manifest carries a single "version", and index.html
# has one footer span. Dying here matches the version-parse abort above rather than carrying on.
expected = {
    os.path.join(root, "web", "manifest-oui-spy.json"),
    os.path.join(root, "web", "manifest-mesh-detect.json"),
    os.path.join(root, "web", "manifest-mesh-detect-ch1.json"),
}
found = set(glob.glob(os.path.join(root, "web", "manifest-*.json")))
if found != expected:
    missing = sorted(os.path.basename(path) for path in expected - found)
    extra = sorted(os.path.basename(path) for path in found - expected)
    sys.exit("!! web USB manifests must be exactly the three shipping profiles; missing=%s, "
             "unexpected=%s" % (missing or "-", extra or "-"))
for m in sorted(found):
    s = open(m).read()
    s, n = re.subn(r'("version":\s*")[^"]*(")', lambda mo: mo.group(1) + ver + mo.group(2), s)
    if n != 1:
        sys.exit("!! %s: expected exactly one \"version\" field to stamp, matched %d; "
                 "fix the manifest or the pattern." % (os.path.basename(m), n))
    open(m, "w").write(s)
idx = os.path.join(root, "web", "index.html")
h = open(idx).read()
h, n = re.subn(r'(All Cameras Are Beacons v)[0-9][0-9A-Za-z.+-]*', lambda mo: mo.group(1) + ver, h)
if n != 1:
    sys.exit("!! web/index.html: expected exactly one \"All Cameras Are Beacons v<ver>\" footer "
             "marker, matched %d; fix the footer or the pattern." % n)
open(idx, "w").write(h)
print("   manifests + footer set to", ver)
PY

mkdir -p "$ROOT/web/firmware"
# Stage the four flash parts SEPARATELY (not one merged blob). esp-web-tools writes
# each at its own offset, so the NVS partition (0x9000, the gap between partitions and
# boot_app0) is never overwritten and a no-erase web-flash keeps the BLE bond + whitelist.
for ENV in oui-spy mesh-detect mesh-detect-ch1; do
  echo ">> staging parts for $ENV"
  for PART in bootloader partitions boot_app0 app; do
    cp "$PAYLOAD_DIR/acab-$ENV-$PART.bin" "$ROOT/web/firmware/acab-$ENV-$PART.bin"
  done
  echo "   -> acab-$ENV-{bootloader,partitions,boot_app0,app}.bin"
done

# Stamp the app-facing firmware manifest in the sibling soyboi.tech clone, if present.
# The iOS/Android apps poll https://soyboi.tech/firmware/firmware-latest.json for
# "update available" (so a firmware release needs no App Store / Play update) and for the
# OTA image hash. Keys are the fw labels the boards report in Status: "ACAB-ouispy" for
# the oui-spy build, "mesh-detect-ACAB" for public-channel mesh, "mesh-detect-ACAB-ch1" for
# the private-channel mesh build. Remember to push soyboi.tech after.
if [ "$SIBLING_ACTIVE" = "1" ]; then
  echo ">> stamping firmware-latest.json in $SIBLING"

  # Copy the frozen app images into the sibling clone so the bytes the manifest hashes
  # are EXACTLY the bytes soyboi.tech serves for in-app OTA. Without this the manifest sha256
  # drifts from the co-hosted file on the next release (a hash-vs-bytes desync). Only the
  # *-app.bin is hosted for OTA; the other flash parts are served from the GitHub Pages flasher.
  for BN in acab-oui-spy-app.bin acab-mesh-detect-app.bin acab-mesh-detect-ch1-app.bin; do
    cp "$PAYLOAD_DIR/$BN" "$SIBLING/$BN"
  done

  "$PY" - "$VER" "$ROOT/web/firmware" "$SIBLING/firmware-latest.json" "$SIG_OUISPY" "$SIG_MESH" "$SIG_MESH_CH1" <<'PY'
import sys, json, hashlib, os, datetime
ver, bindir, lpath = sys.argv[1], sys.argv[2], sys.argv[3]
sigs = {"ACAB-ouispy": sys.argv[4], "mesh-detect-ACAB": sys.argv[5],
        "mesh-detect-ACAB-ch1": sys.argv[6]}
m = json.load(open(lpath))
for label, binname in (("ACAB-ouispy", "acab-oui-spy-app.bin"),
                       ("mesh-detect-ACAB", "acab-mesh-detect-app.bin"),
                       ("mesh-detect-ACAB-ch1", "acab-mesh-detect-ch1-app.bin")):
    b = m["builds"][label]
    p = os.path.join(bindir, binname)
    if not os.path.exists(p):
        sys.exit("!! required staged image is missing: " + p)
    if not isinstance(b.get("app"), dict):
        sys.exit("!! firmware-latest.json build %r has no app object" % label)
    data = open(p, "rb").read()
    b["version"] = ver
    b["app"]["sha256"] = hashlib.sha256(data).hexdigest()
    b["app"]["size"] = len(data)
    b["app"]["sig"] = sigs[label]  # hex DER ECDSA sig, or "" when the offline key is absent
    # Keep `ota` tied to the signature, exactly as stage_beacon_revb.py does for the beacon
    # entries. The two scripts maintain ONE file, so they must not maintain it under two
    # different rules: this stamper used to leave `ota` untouched, which after an
    # --unsigned-usb-only cut published the self-contradictory pair ota:true + sig:"" , and in
    # the other direction let an `ota` that was once false stay false through every later signed
    # release (both apps gate on `ota` AND a non-empty sig, so that label would be offered no
    # firmware ever again). Deriving it here means the flag cannot outlive the fact it describes.
    b["ota"] = bool(sigs[label])
    print("   %-18s %s  %d bytes  %s" %
          (label, ver, len(data), "signed" if sigs[label] else "UNSIGNED"))
m["updated"] = datetime.date.today().isoformat()
json.dump(m, open(lpath, "w"), indent=2)
open(lpath, "a").write("\n")
PY
else
  echo ">> note: sibling soyboi.tech clone not found; firmware-latest.json not stamped"
fi

STAGE_COMMITTED=1
echo ">> done. Serve web/ over localhost or HTTPS to flash."
