#!/usr/bin/env bash
# ACAB release orchestrator: preflight -> tests -> build-and-stage -> verify -> STOP.
#
# WHAT THIS IS FOR. Cutting a release touches two repositories, two staging scripts, three test
# suites and a verifier, and the order matters. Doing it by hand is how 2.0.3 shipped with stale
# artifacts and how the 2.0.4 firmware version nearly shipped un-bumped. This script makes the
# sequence one command and refuses to continue when a precondition is not met.
#
# WHAT IT DELIBERATELY DOES NOT DO: publish. It stops after verification and prints both repos'
# status for a human to review. Tagging, pushing and releasing stay manual, on purpose - they are
# the irreversible steps.
#
# INTERIM SEQUENCE, and why it is not the ideal one. web/build-flasher.sh and
# ../soyboi.tech/firmware/build-beacon-flasher.sh each run `pio` themselves, so this script must
# NOT build first or every image gets compiled twice. The right end state is
#   build once -> stage from the build dir -> verify a temp release dir -> promote (atomic move)
# which needs both stagers refactored. Until then the order below is the correct one for the
# scripts as they actually exist.
#
# Ordinary iteration is untouched: `pio run`, USB flashing and the bench flow do not go through
# here. This gates RELEASES, not development.
#
#   ./release.sh --profile beacon              # the dual-radio board
#   ./release.sh --profile colonel-panic       # oui-spy + mesh-detect
#   ./release.sh --profile all --with-apps     # everything, including the phone test suites
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"
SITE="$(cd "$REPO/../soyboi.tech" 2>/dev/null && pwd || true)"

PROFILE=""
ALLOW_DIRTY=0
WITH_APPS=0
UNSIGNED_USB_ONLY=0

die() { echo "!! $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --with-apps) WITH_APPS=1; shift ;;
        --unsigned-usb-only) UNSIGNED_USB_ONLY=1; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Named PROFILES rather than a free-form target list: the two staging scripts have fixed target
# sets baked in, so a free-form list would imply a granularity that does not exist.
case "$PROFILE" in
    beacon|colonel-panic|all) ;;
    "") die "--profile is required (beacon | colonel-panic | all)" ;;
    *)  die "unknown profile '$PROFILE' (beacon | colonel-panic | all)" ;;
esac

# ---------------------------------------------------------------------------
step "1/5 preflight"
# ---------------------------------------------------------------------------
# A dirty tree means the commit SHA does not identify the bytes being shipped. Allowed, but then
# the provenance has to record a digest of exactly what was dirty.
dirty="$(git -C "$REPO" status --porcelain)"
if [ -n "$dirty" ]; then
    if [ "$ALLOW_DIRTY" -eq 0 ]; then
        echo "$dirty"
        die "working tree is dirty. Commit, or re-run with --allow-dirty (provenance will record a digest)."
    fi
    digest="$(printf '%s' "$dirty" | shasum -a 256 | cut -c1-12)"
    echo "   dirty tree ALLOWED; provenance digest ${digest}"
    git -C "$REPO" status --porcelain
fi

# The site repo is not optional for the beacon profile: silently skipping it is how a release ships
# with the phone-facing OTA manifest still pointing at the previous version.
if [ "$PROFILE" = "beacon" ] || [ "$PROFILE" = "all" ]; then
    [ -n "$SITE" ] || die "../soyboi.tech not found; the beacon profile stages its OTA artifacts there"
    [ -f "$SITE/firmware/build-beacon-flasher.sh" ] || die "$SITE/firmware/build-beacon-flasher.sh missing"
fi

# An unsigned OTA image is one the board will refuse in the field, so a signing key that is missing
# has to stop the run unless the operator is explicitly cutting a USB-only build.
KEY="$REPO/firmware/tools/ota_signing/beacon_ota_key.pem"
if [ ! -f "$KEY" ] && [ "$UNSIGNED_USB_ONLY" -eq 0 ]; then
    die "OTA signing key not found at ${KEY#$REPO/}. Re-run with --unsigned-usb-only for a flasher-only build."
fi
echo "   profile=$PROFILE apps=$WITH_APPS signed=$([ -f "$KEY" ] && echo yes || echo NO)"

# ---------------------------------------------------------------------------
step "2/5 tests"
# ---------------------------------------------------------------------------
./host-tests/run.sh
python3 ./check-signature-drift.py   # signatures.md must still describe the shipped tables

if [ "$WITH_APPS" -eq 1 ]; then
    # --rerun-tasks is MANDATORY, not tidiness: a bare `gradlew test` reports UP-TO-DATE and runs
    # ZERO tests, which looks identical to a green suite in the log.
    ( cd "$REPO/android" && ./gradlew testDebugUnitTest --rerun-tasks )
    # `test`, not `build`: the app target compiles fine without the test target, so building the
    # app proves nothing about the tests.
    ( cd "$REPO/ios" && xcodebuild -scheme Beacons -sdk iphonesimulator \
        -destination 'platform=iOS Simulator,name=iPhone 17' test )
fi

# ---------------------------------------------------------------------------
step "3/5 build and stage"
# ---------------------------------------------------------------------------
# The stagers BUILD. Do not add a `pio run` here or everything compiles twice.
if [ "$PROFILE" = "colonel-panic" ] || [ "$PROFILE" = "all" ]; then
    ( cd "$REPO/web" && ./build-flasher.sh )
fi
if [ "$PROFILE" = "beacon" ] || [ "$PROFILE" = "all" ]; then
    ( cd "$SITE/firmware" && ./build-beacon-flasher.sh )
fi

# ---------------------------------------------------------------------------
step "4/5 verify"
# ---------------------------------------------------------------------------
# --production turns absence into failure and requires signatures to actually verify.
python3 ./verify-release-artifacts.py --production

# ---------------------------------------------------------------------------
step "5/5 review (publishing is a human action)"
# ---------------------------------------------------------------------------
echo "--- $REPO"
git -C "$REPO" status --short
echo "--- $SITE"
[ -n "$SITE" ] && git -C "$SITE" status --short || true
echo
echo "Verified. NOTHING has been committed, tagged, or published."
echo "Review both diffs, then tag and push by hand."
