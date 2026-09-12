#!/usr/bin/env python3
"""Watch ACAB's one vendored dependency for upstream drift: the opendroneid decoder.
The Flock OUI table is own-sourced (own field captures plus Flock's IEEE block) and is
no longer diffed against any third-party curated list.

    python3 firmware/tools/check-signature-drift.py
    python3 firmware/tools/check-signature-drift.py --offline   # skip the network watch

Exits 0 when nothing upstream is missing locally, 1 when there is drift to look
at. It only reports; it never edits anything. Provenance is in CREDITS.md. When an
upstream repo moves a file or renames a branch, update the URLs below.

A network failure is NOT a pass here (see check_odid). Pass --offline to state on
purpose that a run is not watching upstream.
"""
import argparse
import fractions
import glob
import hashlib
import json
import os
import re
import sys
import urllib.request

# --- upstream sources (edit as they move) -----------------------------------
LOCAL_FLOCK = "firmware/lib/acab_core/flock_detect.cpp"

# We no longer mirror any third-party curated Flock OUI list. The shipped Flock WiFi
# OUIs are our own field captures plus Flock's own IEEE block (see docs/signatures.md).
# This list stays empty on purpose: a curated upstream selection is not ours to track,
# and matching it was the source of the field false positives we since dropped.
UPSTREAM_FLOCK_URLS = []

# opendroneid decoder: watch for a NEW upstream RELEASE instead of byte-diffing
# master. core-c's last release is v2.0 (2022); everything on master since is
# unreleased const-correctness and encode-side churn we reviewed and chose to
# skip, so diffing master is pure noise. This flags only when core-c actually
# ships a newer release. Bump the baseline when you re-vendor opendroneid/.
ODID_REPO = "opendroneid/opendroneid-core-c"
ODID_BASELINE_RELEASE = "v2.0"   # latest release reviewed (2026-06-16)

# The real clamp every attacker-supplied advert name, SSID and ODID id passes through, plus the
# host tests that carry a link-stub copy of it (see check_ascii_clamp_copies).
LOCAL_ASCII_CLAMP = "firmware/lib/acab_core/acab_scanner.cpp"
HOST_TESTS_GLOB = "firmware/tools/host-tests/test_*.cpp"

# The two enums whose faqKey values ARE the keys of faq-content.json's relatedHelp map.
IOS_DEVICE_TYPE = "ios/Beacons/Models/DeviceType.swift"
AND_DEVICE_TYPE = "android/app/src/main/java/tech/acab/app/model/Models.kt"

# The app files carrying constants that must read the same on both platforms (see
# SHARED_CONSTANTS).
IOS_CONTRIBUTION_CSV = "ios/Beacons/BLE/ContributionCsv.swift"
IOS_BLE_MANAGER = "ios/Beacons/BLE/BLEManager.swift"
AND_BLE_MANAGER = "android/app/src/main/java/tech/acab/app/ble/AcabBleManager.kt"
IOS_SETTINGS = "ios/Beacons/Views/SettingsView.swift"
AND_DEVICE_SCREEN = "android/app/src/main/java/tech/acab/app/ui/DeviceScreen.kt"
IOS_ROOT_VIEW = "ios/Beacons/Views/RootView.swift"
IOS_CONNECT_VIEW = "ios/Beacons/Views/ConnectView.swift"
AND_ACAB_APP = "android/app/src/main/java/tech/acab/app/ui/AcabApp.kt"
IOS_DASHBOARD_PRESENTATION = "ios/Beacons/Models/DashboardPresentation.swift"
AND_STATUS_SCREEN = "android/app/src/main/java/tech/acab/app/ui/StatusScreen.kt"
IOS_MAP_TAB = "ios/Beacons/Views/MapTabView.swift"
AND_MAP_SCREEN = "android/app/src/main/java/tech/acab/app/ui/MapScreen.kt"
AND_MAP_PROJECTION = "android/app/src/main/java/tech/acab/app/ui/MapProjection.kt"
IOS_DETECTIONS_VIEW = "ios/Beacons/Views/DetectionsView.swift"
AND_LOG_SCREEN = "android/app/src/main/java/tech/acab/app/ui/LogScreen.kt"
AND_MAIN_SCREEN = "android/app/src/main/java/tech/acab/app/ui/MainScreen.kt"
IOS_COMPONENTS = "ios/Beacons/Views/Components.swift"
IOS_OUI_VENDORS = "ios/Beacons/Models/OUIVendors.swift"
AND_OUI_VENDORS = "android/app/src/main/java/tech/acab/app/model/OuiVendors.kt"
IOS_BEACON_PRESENTATION = "ios/Beacons/Models/BeaconPresentation.swift"
IOS_DASHBOARD_VIEW = "ios/Beacons/Views/DashboardView.swift"
IOS_DETECTION_DETAIL = "ios/Beacons/Views/DetectionDetailView.swift"
AND_DETAIL_SCREEN = "android/app/src/main/java/tech/acab/app/ui/DetailScreen.kt"
# The bundled FAQ, shipped as ONE file copied into both resource trees (check_faq_copies
# asserts the two are byte-identical; SHARED_SHAPES pins the promises inside them).
IOS_FAQ = "ios/Beacons/Resources/faq-content.json"
AND_FAQ = "android/app/src/main/assets/faq-content.json"
# The firmware and protocol-doc sides of a rule the apps seed from (see SHARED_SHAPES).
FW_BEACON_MAIN = "firmware/src/beacon-board/main.cpp"
FW_MESH_MAIN = "firmware/src/mesh-detect/main.cpp"
DOCS_BLE_PROTOCOL = "docs/ble-protocol.md"
CANONICAL_PRIVACY = "web/privacy.html"
CANONICAL_PRIVACY_URL = (
    "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html"
)
# The workflow that runs this script in CI. check_ci_trigger_paths holds its path filter to the
# files this script reads.
FIRMWARE_CI = ".github/workflows/firmware-ci.yml"
# ----------------------------------------------------------------------------

# A 3-byte OUI written as 0xNN,0xNN,0xNN (our C arrays) or NN:NN:NN (most lists).
# Lookarounds keep us from grabbing the first three bytes of a longer MAC.
OUI_CARR = re.compile(
    r"(?<![0-9A-Fa-f])0x([0-9A-Fa-f]{2})\s*,\s*0x([0-9A-Fa-f]{2})\s*,\s*0x([0-9A-Fa-f]{2})"
)
OUI_COLON = re.compile(
    r"(?<![0-9A-Fa-f:])([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})(?![0-9A-Fa-f:])"
)


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "acab-drift-check"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")


# Every repo-relative path this run reads, for check_ci_trigger_paths. read_local adds its own;
# the two checks that hash files without it (check_odid_copies, check_faq_copies) add theirs.
_READS = set()


def read_local(rel):
    _READS.add(rel)
    with open(os.path.join(repo_root(), rel), encoding="utf-8") as f:
        return f.read()


def extract_ouis(text):
    out = set()
    for groups in OUI_CARR.findall(text):
        out.add("".join(g.upper() for g in groups))
    for groups in OUI_COLON.findall(text):
        out.add("".join(g.upper() for g in groups))
    return out


def fmt(oui):
    return f"{oui[0:2]}:{oui[2:4]}:{oui[4:6]}"


def check_flock(offline=False):
    print("== Flock OUI tables ==")
    local = extract_ouis(read_local(LOCAL_FLOCK))
    print(f"   local:    {len(local):>3} OUIs  ({LOCAL_FLOCK})")
    # Empty by CONFIGURATION, which is a real answer, unlike an empty result from failed fetches.
    # Those two used to collapse into the same "no third-party list is mirrored" line further
    # down, so the moment anyone re-added a URL a dead network would have read as no drift.
    if not UPSTREAM_FLOCK_URLS:
        print("   Flock OUIs are own-sourced; no third-party list is mirrored (see docs/signatures.md)")
        return 0
    if offline:
        print(f"   --   skipped (--offline): {len(UPSTREAM_FLOCK_URLS)} upstream list(s) not fetched")
        return 0
    upstream = set()
    unfetched = 0
    for url in UPSTREAM_FLOCK_URLS:
        try:
            found = extract_ouis(fetch(url))
            print(f"   upstream: {len(found):>3} OUIs  {url}")
            upstream |= found
        except Exception as exc:
            # A fetch that failed is a comparison that did not happen. Count it, or the run
            # reports "every upstream OUI is present locally" about a list it never read.
            print(f"   !! could not fetch {url}: {exc}")
            unfetched += 1
    missing = sorted(upstream - local)  # upstream has it, we don't -> drift risk
    extra = sorted(local - upstream)    # ours only -> additions from other sources
    if missing:
        print(f"\n   !! {len(missing)} upstream OUI(s) MISSING locally (possible drift):")
        for o in missing:
            print(f"      {fmt(o)}")
    elif unfetched == 0:
        print("   ok: every upstream OUI is present locally")
    if upstream:
        # Only meaningful against a list we actually read. With every fetch failed this would
        # report the entire local table as "superset additions", which is not what happened.
        print(f"   ({len(extra)} local-only OUIs, your superset additions)")
    return len(missing) + unfetched


def latest_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {"User-Agent": "acab-drift-check", "Accept": "application/vnd.github+json"}
    # Unauthenticated api.github.com allows 60 requests/hour per SOURCE IP, and Actions runners
    # share egress IPs, so an unauthenticated call from CI hits a 403 fairly often. The workflow
    # hands us the job's own GITHUB_TOKEN, which raises that to the repo's own budget and removes
    # the usual reason this watch fails. Sent ONLY to api.github.com, never to fetch()'s
    # arbitrary upstream URLs.
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
    return data.get("tag_name"), (data.get("published_at") or "")[:10]


def check_odid(offline=False):
    print("\n== opendroneid decoder (release watch) ==")
    if offline:
        print(f"   --   skipped (--offline): {ODID_REPO} was not queried, so a new upstream")
        print("        release would not be seen by this run")
        return 0
    try:
        tag, date = latest_release(ODID_REPO)
    except Exception as exc:
        # NOT a pass. This request is the ONLY thing watching for a new core-c release, and
        # answering "nothing new to chase" about a question that was never asked is how an
        # upstream release goes unnoticed for a year while CI stays green. It used to WARN and
        # return 0, which is exactly that. Rate limits were the usual cause; GITHUB_TOKEN above
        # removes them, and --offline is the deliberate, visible opt-out.
        print(f"   !! could not query {ODID_REPO} releases: {exc}")
        print("      the release watch DID NOT RUN. Retry, set GITHUB_TOKEN, or pass --offline")
        print("      to record on purpose that this run is not watching upstream.")
        print("      (from a release cut: release.sh --offline forwards that flag here.)")
        return 1
    if tag == ODID_BASELINE_RELEASE:
        print(f"   ok: latest core-c release is still {tag} ({date}); nothing new to chase")
        return 0
    print(f"   !! core-c shipped {tag} ({date}); your baseline is {ODID_BASELINE_RELEASE}")
    print("      review the release, re-vendor opendroneid/ (.c + .h) if it matters,")
    print("      then bump ODID_BASELINE_RELEASE in this script")
    return 1


def check_odid_copies():
    """The opendroneid decoder is vendored TWICE, on purpose.

    lib/acab_core/opendroneid/ is what the product links; src/odid-sim/ carries its own copy so
    the bench simulator stays self-contained and does not drag in the rest of acab_core (see the
    odid-sim env in platformio.ini). That layout is fine, but it has one failure mode: check_odid
    above says to re-vendor "opendroneid/" in the SINGULAR, and a re-vendor that updates one copy
    and forgets the other leaves a bench simulator that silently disagrees with the receiver it
    exists to test. A test tool that lies is worse than no test tool.

    So assert byte-identity instead of trusting whoever does the next re-vendor to remember.
    """
    print("\n== opendroneid vendored copies (must stay identical) ==")
    pairs = [
        ("lib/acab_core/opendroneid/opendroneid.c", "src/odid-sim/opendroneid.c"),
        ("lib/acab_core/opendroneid/opendroneid.h", "src/odid-sim/opendroneid.h"),
    ]
    drift = 0
    for a, b in pairs:
        _READS.update((f"firmware/{a}", f"firmware/{b}"))
        pa = os.path.join(repo_root(), "firmware", a)
        pb = os.path.join(repo_root(), "firmware", b)
        if not os.path.exists(pa) or not os.path.exists(pb):
            print(f"   WARN missing: {a if not os.path.exists(pa) else b}")
            drift += 1
            continue
        ha = hashlib.sha256(open(pa, "rb").read()).hexdigest()
        hb = hashlib.sha256(open(pb, "rb").read()).hexdigest()
        if ha == hb:
            print(f"   ok: {os.path.basename(pa):15} identical ({ha[:12]})")
        else:
            print(f"   !! {os.path.basename(pa)} DIFFERS between the two vendored copies")
            print(f"      {a}  {ha[:12]}")
            print(f"      {b}  {hb[:12]}")
            print("      re-vendor BOTH, or the bench simulator no longer matches the receiver")
            drift += 1
    return drift


# The body of `void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap) { ... }`.
# Non-greedy up to a closing brace in COLUMN ZERO, which is the function's own; every brace inside
# it is indented.
ASCII_CLAMP_RE = re.compile(r"void\s+acabSanitizeAscii\s*\([^)]*\)\s*\{(.*?)\n\}", re.S)


def _clamp_body(rel):
    """acabSanitizeAscii's body in `rel`, comments stripped and whitespace collapsed, or None."""
    m = ASCII_CLAMP_RE.search(read_local(rel))
    if not m:
        return None
    return " ".join(re.sub(r"//[^\n]*", "", m.group(1)).split())


def check_ascii_clamp_copies():
    """The ingest clamp is duplicated into the host tests, on purpose. Assert byte equality.

    run.sh compiles exactly ONE classifier source next to each test, so a suite whose classifier
    calls acabSanitizeAscii (acab_scanner.cpp's, which the harness never compiles) has to carry a
    link stub, and several do. Those copies are NOT inert: the tests assert the exact clamped
    output strings, so if the real clamp changes - a wider printable range, a different truncation
    rule, a rejection instead of a substitution - the host suite keeps asserting the OLD firmware
    behaviour and reports PASS on strings the board would now emit differently.

    Same guard, same reasoning as the vendored opendroneid copies and the two FAQ copies. Discovered
    by glob rather than listed, so a NEW suite that copies the function is covered the day it lands.
    """
    print("\n== acabSanitizeAscii copies (host-test stubs must match the real clamp) ==")
    real = _clamp_body(LOCAL_ASCII_CLAMP)
    if real is None:
        print(f"   !! could not find acabSanitizeAscii in {LOCAL_ASCII_CLAMP}")
        print("      it moved (update LOCAL_ASCII_CLAMP) or changed shape; until then this is blind")
        return 1
    root = repo_root()
    drift = 0
    copies = 0
    for path in sorted(glob.glob(os.path.join(root, HOST_TESTS_GLOB))):
        rel = os.path.relpath(path, root)
        body = _clamp_body(rel)
        if body is None:
            continue                      # this suite links nothing that needs the stub
        copies += 1
        if body == real:
            print(f"   ok: {os.path.basename(path):22} matches")
        else:
            print(f"   !! {rel} has DRIFTED from {LOCAL_ASCII_CLAMP}")
            print("      that suite is asserting the OLD clamp's output; re-copy the body verbatim")
            drift += 1
    if copies == 0:
        print("   no host-test copies found (correct if the clamp now lives in a shared header)")
    return drift


# A relatedHelp key as both apps write it: SCREAMING_CASE, DIGITS ALLOWED after the first
# character. Both parsers below used to bake a digit-free name class into the match itself, and
# that does not truncate a name carrying a digit - it fails the whole match, because what follows
# the name (a closing quote on iOS, an open paren on Android) then no longer lines up. So
# AXON_FLEET3 would vanish from BOTH sides at once: the two sets still agree, the mismatch guard
# below stays quiet, and the new category ships with a silently hidden Related Help panel on both
# platforms. That is the exact commit shape this check exists to catch.
#
# So: match names PERMISSIVELY, then validate against this. A token the validator rejects is
# REPORTED, never dropped. A key this file cannot read is a key the coverage loop never checks,
# and a silent drop reads downstream as a pass.
FAQ_KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*")


def _ios_faq_keys():
    """iOS's DeviceType.faqKey keys, as (keys, unreadable).

    "" is not a key: those arms are the deliberate no-panel ones. (None, []) when the faqKey
    block itself cannot be found. `unreadable` carries one line per thing this parser saw but
    could not turn into a key, so the caller fails loudly instead of checking a short list.
    """
    m = re.search(r"var faqKey: String \{(.*?)\n    \}", read_local(IOS_DEVICE_TYPE), re.S)
    if not m:
        return None, []
    body = m.group(1)
    keys, unreadable = set(), []
    literals = re.findall(r'return "([^"]*)"', body)
    for literal in literals:
        if not literal:
            continue
        if FAQ_KEY_RE.fullmatch(literal):
            keys.add(literal)
        else:
            unreadable.append(f"faqKey returns {literal!r}, which is not a SCREAMING_CASE key")
    # Every arm has to BE a plain string literal for the line above to see it. An arm returning a
    # constant, an interpolation or a call is a key this parser is blind to: the same hole in a
    # different shape, so count the arms rather than trusting the shape to stay.
    arms = len(re.findall(r"\breturn\b", body))
    if arms != len(literals):
        unreadable.append(f"{arms - len(literals)} faqKey arm(s) return something other than a "
                          "string literal, so their key was not read")
    return keys, unreadable


def _android_faq_keys():
    """Android's keys ARE the enum constant names, minus the ones faqKey maps to "".

    Same (keys, unreadable) contract as _ios_faq_keys. Comments come out of the constant list
    first: they are prose, and a capitalised word in prose is not an enum constant.
    """
    text = read_local(AND_DEVICE_TYPE)
    enum = re.search(r"enum class DeviceType\(val raw: Int\) \{(.*?);", text, re.S)
    getter = re.search(r"val faqKey: String\s*\n\s*get\(\) = when \(this\) \{(.*?)\n\s*\}", text, re.S)
    if not enum or not getter:
        return None, []
    body = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", enum.group(1), flags=re.S))
    keys, unreadable = set(), []
    names = re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\d+\s*\)", body)
    for name in names:
        if FAQ_KEY_RE.fullmatch(name):
            keys.add(name)
        else:
            unreadable.append(f"enum constant {name} is not a SCREAMING_CASE key")
    # Same blindness check as the iOS side: count what LOOKS like a constant declaration against
    # what actually parsed, so a raw value written as 0x0B or as an expression gets reported
    # instead of quietly taking its name with it.
    declared = len(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\(", body))
    if declared != len(names):
        unreadable.append(f"{declared - len(names)} DeviceType constant declaration(s) did not "
                          "parse, so their key was not read")
    for line in getter.group(1).splitlines():
        if "->" in line and '""' in line:
            keys -= set(re.findall(r"\b([A-Z][A-Z0-9_]*)\b", line.split("->")[0]))
    return keys, unreadable


def check_faq_copies():
    """The bundled FAQ ships as ONE file copied into both app resource trees. Assert byte equality.

    faq-content.json is the shared answer set that must read identically on iOS and Android. Keeping it as a
    Swift literal and a Kotlin literal would be two hand-maintained copies of the same prose, and
    cross-platform copy drift is the most recurring defect class in this repo. So it is one file,
    duplicated verbatim into two resource trees because neither build system will reach outside its
    own tree, and this check is what makes the duplication safe: edit one, the build tells you.

    Same guard, same reasoning as the vendored opendroneid copies above.
    """
    root = repo_root()
    rel_a, rel_b = IOS_FAQ, AND_FAQ
    _READS.update((rel_a, rel_b))
    a, b = os.path.join(root, rel_a), os.path.join(root, rel_b)
    print("\n== bundled FAQ content (both app copies must be identical) ==")
    missing = [p for p in (a, b) if not os.path.exists(p)]
    if missing:
        for p in missing:
            print(f"   !! MISSING: {os.path.relpath(p, root)}")
        return len(missing)
    ha = hashlib.sha256(open(a, "rb").read()).hexdigest()
    hb = hashlib.sha256(open(b, "rb").read()).hexdigest()
    if ha != hb:
        print("   !! DRIFT: the two faq-content.json copies differ")
        print(f"      ios     {ha[:12]}")
        print(f"      android {hb[:12]}")
        print("      fix: copy the intended one over the other, they are meant to be byte-identical")
        return 1
    # A parse check too: a syntactically broken JSON degrades to an EMPTY help screen at runtime
    # on both platforms (both parsers swallow the error by design), so the build is the only place
    # it can be caught.
    try:
        d = json.loads(open(a, encoding="utf-8").read())
        nq = sum(len(sec.get("questions", [])) for sec in d.get("sections", []))
        print(f"   ok: identical ({ha[:12]}), {len(d.get('sections', []))} sections, {nq} questions, "
              f"{len(d.get('support', []))} support rows")
    except Exception as e:
        print(f"   !! faq-content.json does not parse: {e}")
        return 1
    # Related-help coverage: both apps key the detail screen's Related Help panel off the
    # DeviceType faq key into relatedHelp. A key with no entry HIDES the panel silently at
    # runtime (both apps skip rendering on an empty lookup), so a category can lose its help
    # with nothing failing anywhere - the build is the only place it can be caught.
    #
    # DERIVED from the two DeviceType enums, never hand-listed. A hardcoded list is checked
    # against the JSON but not against the apps, so a NEW category with no relatedHelp row passed
    # silently: the one commit this check exists for. Reading both sources also catches the two
    # enums disagreeing about a key, which the shared JSON has no way to express.
    ios_keys, ios_unreadable = _ios_faq_keys()
    and_keys, and_unreadable = _android_faq_keys()
    if ios_keys is None or and_keys is None:
        blind = IOS_DEVICE_TYPE if ios_keys is None else AND_DEVICE_TYPE
        print(f"   !! could not read the faqKey list out of {blind}")
        print("      relatedHelp coverage cannot be checked; fix the source or the parser above")
        return 1
    # A key that did not parse is a key nothing below checks, and the two sets would still AGREE
    # about it, because both parsers would miss it in the same way. Say so instead of printing an
    # "ok" derived from a short list.
    if ios_unreadable or and_unreadable:
        print("   !! a DeviceType faq key did not parse, so it was NOT checked for coverage:")
        for msg in ios_unreadable:
            print(f"      iOS      {msg}")
        for msg in and_unreadable:
            print(f"      Android  {msg}")
        print("      keys are SCREAMING_CASE (digits allowed after the first character). Rename")
        print("      it, or teach FAQ_KEY_RE and the parsers in this file the new shape.")
        return 1
    if ios_keys != and_keys:
        print("   !! the two DeviceType enums disagree about the relatedHelp keys")
        print(f"      iOS only:     {sorted(ios_keys - and_keys) or '-'}")
        print(f"      Android only: {sorted(and_keys - ios_keys) or '-'}")
        print("      the JSON is shared, so one platform would silently lose its panel")
        return 1
    faq_keys = sorted(ios_keys)
    related = d.get("relatedHelp", {})
    known_q = {q.get("id") for sec in d.get("sections", []) for q in sec.get("questions", [])}
    bad = 0
    for key in faq_keys:
        rows = related.get(key, [])
        if not rows:
            print(f"   !! relatedHelp has no entries for {key}: both apps silently hide the panel")
            bad += 1
            continue
        for qid in rows:
            if qid not in known_q:
                print(f"   !! relatedHelp[{key}] points at unknown question id '{qid}'")
                bad += 1
    if not bad:
        print(f"   ok: relatedHelp covers all {len(faq_keys)} categories, every id resolves")
    return bad


# Constants each app declares SEPARATELY and whose source literal must stay byte-identical. Both
# sides of every row already say so in their own comments, and a comment is not a check: this is the
# faq-content.json guard above extended to the strings that could NOT move into that shared file,
# because they are code constants rather than content.
#
# WHAT A ROW MAY PIN. The comparison is of the literal AS WRITTEN, so a constant whose two sides
# need different escaping (a Swift interpolation, a "$" Kotlin has to escape) does not belong here:
# it would report drift between two correct copies, and a guard that cries wolf gets ignored.
#
# `kind` is "string" for one literal, "list" for an ordered list of them, where ORDER is part of
# the contract, and "fragments" for an INTERPOLATED template: the captured region is parsed into
# its string literals, each literal is cut at its interpolation holes (`\(x)` on iOS, `$x` and
# `${x}` on Android), literals the source joins with `+` are re-joined, and the SET of text runs
# between the holes is compared (see _literal_fragments). That is what two templates share when
# their holes are spelled per language and one side splits a sentence across several literals.
# The set cannot see a hole's NAME, so a row that must also pin where a word comes from anchors its
# pattern on that hole. A fragments pattern may carry several groups; their text is compared
# together, which lets a row take a line two templates share (the iOS Log summary's `category`)
# without also taking the other template.
#
# Optional per row: `strip_prefix` {"ios": ..., "android": ...} on a string row when the two sides
# differ by ONE declared leading word (each side must start with its prefix; the remainders are
# compared), `fold_case` on a fragments row when one side lowercases the value later (the export
# slug), and `scale` {"ios": n, "android": m} with a `unit` on a string row when the two sides
# declare one number in different units (each value times its factor must be exactly equal). An
# option on a kind it does not apply to is reported, never ignored.
SHARED_CONSTANTS = (
    {
        "what": "detection CSV columns",
        "kind": "list",
        "why": "the redaction policy names these columns as STRINGS, so a rename on one platform"
               " ships a coordinate under a new name in a file whose disclosure says it was removed",
        "ios": (IOS_CONTRIBUTION_CSV,
                r"static\s+let\s+detectionColumns\s*:\s*\[String\]\s*=\s*\[(.*?)\]"),
        "android": (AND_BLE_MANAGER,
                    r"\bval\s+DETECTION_CSV_COLUMNS\s*:\s*List<String>\s*=\s*listOf\((.*?)\)"),
    },
    {
        "what": "pairing-window hint",
        "kind": "string",
        "why": "user-facing recovery copy: the same failure has to read the same on both phones",
        "ios": (IOS_BLE_MANAGER, r'static\s+let\s+pairWindowHint\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_BLE_MANAGER,
                    r'\bconst\s+val\s+PAIR_WINDOW_HINT\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "location-fix freshness window (seconds)",
        "kind": "string",
        "why": "one window decides which phone fix and which board-relayed fix may stamp a"
               " detection or pin it; a longer window on one phone stamps evidence with a"
               " place the phone had already left",
        "ios": (IOS_BLE_MANAGER,
                r"\blet\s+currentLocationFixMaxAge\s*:\s*TimeInterval\s*=\s*(\d+)\b"),
        "android": (AND_BLE_MANAGER, r"\bconst\s+val\s+FIX_MAX_AGE_SEC\s*=\s*(\d+)\b"),
    },
    {
        "what": "stale capture-era pin floor (RSSI)",
        "kind": "string",
        "why": "the floor a stale replayed coordinate is parked at must sit below every real"
               " BLE reading on both phones, or a home fix outranks a later live sighting",
        "ios": (IOS_BLE_MANAGER, r"\blet\s+staleFixPinRSSI\s*:\s*Int\s*=\s*(-?\d+)\b"),
        "android": (AND_BLE_MANAGER, r"\bconst\s+val\s+STALE_FIX_PIN_RSSI\s*=\s*(-?\d+)\b"),
    },
    {
        "what": "status radar dot cap",
        "kind": "string",
        "why": "the radar caption names the cap and both suites pin the literal; a different"
               " cap on one phone makes '14 of N' mean different things",
        "ios": (IOS_DASHBOARD_PRESENTATION, r"\bstatic\s+let\s+dotLimit\s*=\s*(\d+)\b"),
        "android": (AND_STATUS_SCREEN, r"\bconst\s+val\s+STATUS_RADAR_DOT_CAP\s*=\s*(\d+)\b"),
    },
    {
        "what": "status radar caption detail line",
        "kind": "string",
        "why": "the clause that tells the user the dot cap does not cap the counters has to"
               " exist on both phones in the same words",
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r'\bstatic\s+let\s+radarCaptionDetail\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_STATUS_SCREEN,
                    r'\bconst\s+val\s+STATUS_RADAR_CAPTION_DETAIL\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "status count cards",
        "kind": "list",
        "why": "the two cards that split TOTAL NEARBY, each a title then a detail, matched card"
               " first; a card worded differently on one phone reads as a different count",
        # Four adjacent declarations per side in a fixed name order, so a value moved to another
        # name reads as a different order, and a declaration moved away reads as unreadable.
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r'(static let matchedCardTitle = "[^"]*"\s*\n\s*static let matchedCardDetail = "[^"]*"'
                r'\s*\n\s*static let ambientCardTitle = "[^"]*"\s*\n\s*static let ambientCardDetail'
                r' = "[^"]*")'),
        "android": (AND_STATUS_SCREEN,
                    r'(internal const val STATUS_MATCHED_CARD_TITLE = "[^"]*"\s*\n\s*internal const val'
                    r' STATUS_MATCHED_CARD_DETAIL = "[^"]*"\s*\n\s*internal const val'
                    r' STATUS_AMBIENT_CARD_TITLE = "[^"]*"\s*\n\s*internal const val'
                    r' STATUS_AMBIENT_CARD_DETAIL = "[^"]*")'),
    },
    {
        "what": "status nearby breakdown lines",
        "kind": "fragments",
        "why": "the lines under the count cards say what the counts hold (a category this app"
               " does not recognize, a star counted as a match) in the same words on both phones",
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r"(var unclassifiedLine: String\? \{.*?\n    \}\n    var watchedLine: String\? \{"
                r".*?\n    \})"),
        "android": (AND_STATUS_SCREEN,
                    r"(val unclassifiedLine: String\?\s*\n\s*get\(\) = .*?val watchedLine: String\?"
                    r"\s*\n\s*get\(\) = [^\n]*)"),
    },
    {
        "what": "status strip tiles",
        "kind": "list",
        "why": "the six category tiles in strip order, each drawn label then its spoken name; which"
               " board toggle each tile reads is pinned by both suites with the same frames, not here",
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r"static let stripTiles: \[DashboardStripTile\] = \[(.*?)\n    \]"),
        "android": (AND_STATUS_SCREEN,
                    r"internal val STATUS_STRIP_TILES: List<StatusStripTile> = listOf\((.*?)\n\)"),
    },
    {
        "what": "status tile spoken sentence",
        "kind": "fragments",
        "why": "a tile's screen-reader sentence (name, recent count, detector off) has to say the"
               " same thing on both phones",
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r"(func dashboardTileAccessibilityLabel\(spoken: String, count: Int, off: Bool\)"
                r" -> String \{.*?\n\})"),
        "android": (AND_STATUS_SCREEN,
                    r'(contentDescription = "\$spokenLabel, \$count recently heard" \+\s*'
                    r'if \(off\) "[^"]*" else "",)'),
    },
    # The nearest card is the one place Status names a single device, and each of its lines is one
    # drawn Text per side. The spoken forms above are pinned; these are what the eye reads.
    {
        "what": "status nearest card identity line",
        "kind": "fragments",
        # Anchored on both holes, so the category keeps coming from inlineCategory (whose arms
        # check_inline_labels pins) and the node from the MAC's last four, not from a full label
        # one phone could swap in: the fragment set cannot see a hole's name.
        "why": "the line naming what the strongest nearby device is and which beacon heard it;"
               " a phone that words it differently names the same device differently",
        "ios": (IOS_DASHBOARD_VIEW,
                r'Text\(("\\\(d\.type\.inlineCategory\) · NODE \\\(d\.nodeName\)")\)'),
        "android": (AND_STATUS_SCREEN,
                    r'Text\(("\$\{d\.type\.inlineCategory\} · NODE \$\{nodeName\(d\.mac\)\}"),'),
    },
    {
        "what": "status nearest card source line",
        "kind": "fragments",
        "why": "which radio heard that device and how many times, in the same words on both phones",
        "ios": (IOS_DASHBOARD_VIEW, r'Text\(("\\\(d\.source\.label\) · seen \\\(d\.count\)×")\)'),
        "android": (AND_STATUS_SCREEN, r'Text\(("\$\{d\.sourceLabel\} · seen \$\{d\.count\}×"),'),
    },
    {
        "what": "status nearest card signal unit",
        "kind": "string",
        "why": "the unit under the nearest card's RSSI number; a phone that labels it differently"
               " reads as a different measurement",
        "ios": (IOS_DASHBOARD_VIEW, r'Text\("(dBm)"\)\.font'),
        "android": (AND_STATUS_SCREEN, r'Text\("(dBm)", color'),
    },
    {
        "what": "status count tile detector-off marker",
        "kind": "string",
        # Both patterns take the condition with the word, so a marker drawn when the detector is
        # ON, or on a tile that is merely empty, reads as unreadable rather than as a match.
        "why": "the marker that says a tile reads 0 because its detector is off rather than"
               " because nothing is out there; the spoken form of the same fact is pinned above",
        "ios": (IOS_DASHBOARD_VIEW, r'Text\(off \? "(OFF)" : ""\)'),
        "android": (AND_STATUS_SCREEN, r'Text\(if \(off\) "(OFF)" else "",'),
    },
    {
        "what": "active nearby window",
        "kind": "string",
        "scale": {"ios": 1000, "android": 1},
        "unit": "ms",
        "why": "one recently-heard window behind the Status counts and the dossier's LIVE/STALE"
               " kicker; iOS declares it in seconds and Android in milliseconds",
        "ios": (IOS_BLE_MANAGER,
                r"\blet\s+activeNearbyInterval\s*:\s*TimeInterval\s*=\s*([0-9][0-9_.]*)\b"),
        "android": (AND_BLE_MANAGER,
                    r"\bconst\s+val\s+ACTIVE_NEARBY_WINDOW_MS\s*=\s*([0-9][0-9_]*)L\b"),
    },
    {
        "what": "status seen-window kicker",
        "kind": "fragments",
        # Anchored on the hole on both sides, so the number keeps coming from the window pinned
        # above instead of a literal one phone could retune alone.
        "why": "'SEEN < 45s' names the window every Status count is filtered to",
        "ios": (IOS_DASHBOARD_PRESENTATION,
                r'static let seenWindowKicker = ("SEEN < \\\(Int\(activeNearbyInterval\)\)s")'),
        "android": (AND_STATUS_SCREEN,
                    r'internal val STATUS_SEEN_WINDOW_KICKER = ("SEEN < \$\{ACTIVE_NEARBY_WINDOW_MS'
                    r' / 1_000L\}s")'),
    },
    {
        "what": "map options reference header",
        "kind": "string",
        "why": "this header is the only thing telling the user the group under it is NOT a"
               " filter; a phone whose header says only 'layers' invites the reader to switch"
               " one off expecting fewer detections, and the guide can describe one sheet only",
        # Anchored on REFERENCE rather than on the whole call, because both files hold several
        # section headers: an outright rename of the first word reads as "could not be read",
        # which this check already reports as drift.
        "ios": (IOS_MAP_TAB, r'mapOptionsSection\("(REFERENCE[^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'Kicker\("(REFERENCE[^"]*)"\)'),
    },
    {
        "what": "known-ALPR layer note",
        "kind": "string",
        "why": "the only place either app tells the user the community layer is ON BY DEFAULT,"
               " that the download attaches nothing about them, and that its pins are mapped"
               " locations rather than live detections; a phone missing a clause of that is"
               " a consent disclosure that exists on one platform only",
        "ios": (IOS_MAP_TAB, r'"(draws community-mapped[^"]*)"'),
        "android": (AND_MAP_SCREEN, r'"(draws community-mapped[^"]*)"'),
    },
    {
        "what": "same-spot pin tolerance (degrees)",
        "kind": "string",
        "why": "the cell size that decides which sightings share one map pin; a coarser cell on"
               " one phone merges cameras the other phone draws apart",
        "ios": (IOS_MAP_TAB, r"\bstatic\s+let\s+sameSpotDegrees\s*=\s*([0-9.e-]+)\b"),
        "android": (AND_MAP_SCREEN, r"\bconst\s+val\s+PIN_GROUP_EPSILON_DEG\s*=\s*([0-9.e-]+)\b"),
    },
    {
        "what": "export base filename",
        "kind": "string",
        "why": "the file a share sheet hands out is named the same on both phones; the slug"
               " words below are appended to it",
        "ios": (IOS_BLE_MANAGER, r'appendingPathComponent\("(acab-detections)\\\(slug\)'),
        "android": (AND_LOG_SCREEN, r'File\(dir, "(acab-detections)\$slug'),
    },
    {
        "what": "export filename slug words",
        "kind": "fragments",
        "fold_case": True,
        "why": "the qualifier a Log export carries in its filename (category, new or offline,"
               " search, strongest, paused) tells the recipient what left the phone; iOS"
               " lowercases the whole slug in writeDetections, so case is folded here",
        "ios": (IOS_DETECTIONS_VIEW, r"(private var exportQualifier: String\? \{.*?\n    \})"),
        "android": (AND_LOG_SCREEN,
                    r"(val slugParts = if \(wholeLog\) emptyList\(\) else buildList \{"
                    r".*?joinToString\([^\n]*)"),
    },
    {
        "what": "log header kicker",
        "kind": "fragments",
        "why": "'N SELECTED' and 'N DETECTED · M NEW' are the one line that tells the user the"
               " Log counts the live store even while paused",
        "ios": (IOS_DETECTIONS_VIEW, r'Kicker\((selecting \? ".*?NEW")\)'),
        "android": (AND_LOG_SCREEN, r'Kicker\(\s*(if \(selectMode\) ".*?NEW")\s*\)'),
    },
    # The Log lens summary is TWO rows, one per template. A single region over both compared the
    # union of their text, so a clause dropped from only the spoken form still passed on the drawn
    # one. iOS builds the category tail once (`let category`) and hands it to both templates, so
    # each iOS pattern takes that line as its first group and one template as its second, and the
    # second must end on the `category` hole: a template that stops interpolating the tail is
    # reported as unreadable instead of passing on the shared line.
    {
        "what": "log lens summary (shown)",
        "kind": "fragments",
        "why": "'5 of 5 paused' under '200 NEW' must not read as 195 lost sightings on either"
               " phone",
        "ios": (IOS_DETECTIONS_VIEW,
                r'(let category = filter\.map \{ "[^"]*" \} \?\? "")\s*\n\s*'
                r'return Text\(("\\\(snap\.shown\.count\) of [^\n]*\\\(category\)")\)'),
        "android": (AND_LOG_SCREEN, r"(internal fun logLensSummaryText\(.*?)\n\n"),
    },
    {
        "what": "log lens summary (spoken)",
        "kind": "fragments",
        "why": "the screen-reader form of the same line has to say the same thing in the same"
               " words on both phones",
        "ios": (IOS_DETECTIONS_VIEW,
                r'(let category = filter\.map \{ "[^"]*" \} \?\? "")\s*\n(?:[^\n]*\n){1,6}?\s*'
                r'\.accessibilityLabel\(("\\\(snap\.shown\.count\) matching detections of [^\n]*'
                r'\\\(category\)")\)'),
        "android": (AND_LOG_SCREEN, r"(internal fun logLensSummaryDescription\(.*?)\n\n"),
    },
    {
        "what": "log card heading",
        "kind": "fragments",
        "why": "'ALL DETECTIONS' and '<category> · NEW' name both lens axes in one heading;"
               " a phone that words the scope differently reads as a different lens",
        "ios": (IOS_DETECTIONS_VIEW, r"(private var logHeading: String \{.*?\n    \})"),
        "android": (AND_LOG_SCREEN, r"(val scopeTag = when \(scope\) \{.*?val label = [^\n]*)"),
    },
    {
        "what": "no-match panel copy",
        "kind": "fragments",
        "why": "the title and body a filtered-empty Log shows, including the ALPR line that says"
               " a quiet lens is expected; the icons are each platform's own and are not compared",
        "ios": (IOS_DETECTIONS_VIEW,
                r"(private var noMatchTitle: String \{.*?private var noMatchBody: String \{.*?\n    \})"),
        "android": (AND_LOG_SCREEN, r"(private fun NoMatchState\(.*?\n    Column\()"),
    },
    {
        "what": "no-match clear-filters button",
        "kind": "string",
        "why": "the one tap that resets search, category and scope reads the same on both phones",
        "ios": (IOS_DETECTIONS_VIEW, r'Button\("(Clear filters)"\)'),
        "android": (AND_LOG_SCREEN, r'Text\("(Clear filters)",'),
    },
    {
        "what": "log search placeholder",
        "kind": "string",
        "why": "the empty search field's hint reads the same on both phones",
        "ios": (IOS_DETECTIONS_VIEW, r'TextField\("((?:[^"\\]|\\.)*)", text: \$searchText\)'),
        "android": (AND_LOG_SCREEN, r'placeholder = \{[^{}]*?Text\("((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "phone-notification dead-switch warning",
        "kind": "fragments",
        # Both patterns are anchored on the DeviceType.inlineLabel hole, so the SOURCE of the
        # category name is pinned as well as the words around it: the fragment set cannot see a
        # hole's name, and a lowercased `label` in that hole spelled ALPR "alpr". inlineLabel's
        # own arms are pinned by check_inline_labels.
        "why": "the line under a notification toggle whose detector is off has to explain itself"
               " the same way on both phones",
        "ios": (IOS_SETTINGS, r'Text\(("the \\\(t\.inlineLabel\) detector is off[^"]*")\)'),
        "android": (AND_DEVICE_SCREEN, r'("the \$\{t\.inlineLabel\} detector is off[^"]*")'),
    },
    {
        "what": "desert still-silent notice",
        "kind": "string",
        # Both apps declare it as a NAMED constant so each suite can pin the bytes, and both do.
        # Those are two literals written in two test files, so a platform that reworded its source
        # and its own test together still goes green; this row is the half neither suite can see.
        "why": "the only line telling a user whose Desert run just ended why the board is still"
               " quiet, and where to undo it; a phone that words the way out differently sends its"
               " owner looking for a control under another name, and the silence keeps reading as"
               " a dead detector",
        "ios": (IOS_SETTINGS, r'\blet\s+desertSilenceNotice\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_DEVICE_SCREEN,
                    r'\bconst\s+val\s+DESERT_SILENCE_NOTICE\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "desert restore offer",
        "kind": "string",
        # The sentence that REPLACES the notice above whenever the app is holding a mode to give
        # back. Both apps declare it as a named constant beside that notice and both suites pin the
        # bytes, which is two literals in two test files: a platform that reworded its source and
        # its own test together still goes green, and this row is the half neither suite can see.
        "why": "the only line that tells an owner the board ended desert mode by itself, that the"
               " app deliberately left the alert mode where it was, and what the control beside it"
               " will do; a phone that words the offer differently is describing a different"
               " promise about who decides whether the detector makes sound",
        "ios": (IOS_SETTINGS, r'\blet\s+desertRestoreOffer\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_DEVICE_SCREEN,
                    r'\bconst\s+val\s+DESERT_RESTORE_OFFER\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "desert restore action label",
        "kind": "string",
        "why": "the words on the control that sentence names; a phone that labels the way back"
               " differently sends its owner looking for a control under another name, which is"
               " the same failure the notice's own wording row exists for",
        "ios": (IOS_SETTINGS, r'\blet\s+desertRestoreOfferAction\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_DEVICE_SCREEN,
                    r'\bconst\s+val\s+DESERT_RESTORE_OFFER_ACTION\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "desert restore action spoken hint",
        "kind": "string",
        # Pinned AT THE CONTROL rather than as a bare literal: each pattern starts at the restore
        # control's own tap and walks forward to the hint attached to it, so a hint that drifts
        # onto some other button stops matching instead of comparing equal from elsewhere on the
        # screen. Neither literal is a named constant, so neither app suite pins these bytes at
        # all; this row is the only place they are compared.
        "why": "two uppercase words are all a screen reader gets from the label, so this sentence"
               " is where 'puts back the mode you had' actually reaches a VoiceOver or TalkBack"
               " user; a phone that describes the tap differently describes a different action",
        "ios": (IOS_SETTINGS,
                r'takePendingAlertModeRestore\(\)(?:[^\n]*\n){0,20}?\s*'
                r'\.accessibilityHint\("((?:[^"\\]|\\.)*)"\)'),
        "android": (AND_DEVICE_SCREEN,
                    r'DESERT_RESTORE_OFFER_ACTION,(?:[^\n]*\n){0,20}?\s*'
                    r'\.clickable\(onClickLabel = "((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "collapsed alerts row",
        "kind": "fragments",
        # FRAGMENTS, not string: the three arms interpolate a volume, and iOS spells the separator
        # \u{00B7} where Android writes the character, so only the decoded text runs compare. The
        # whole `when`/`switch` is captured rather than the one new arm, so an arm that quietly
        # loses the restore segment on one phone shows up as a missing fragment.
        "why": "this is the ONLY thing a user sees without opening the row, and 'SILENT' alone is"
               " what a user who CHOSE silence sees. A phone that does not say a restore is waiting"
               " is reporting a silence its owner asked for, when the app is the one holding their"
               " mode, and the way back is a row they have no reason to open",
        "ios": (IOS_SETTINGS, r'private var alertsKicker: String \{(.*?)\n    \}'),
        "android": (AND_DEVICE_SCREEN,
                    r'val alertsKicker = when \(shownAlertMode\) \{(.*?)\n    \}'),
    },
    {
        "what": "status radar spoken label",
        "kind": "fragments",
        "why": "the one sentence a screen reader gets for the whole scope: count, dots drawn, the"
               " cap, and that the radar shows strength rather than direction",
        "ios": (IOS_COMPONENTS,
                r'\.accessibilityLabel\(("\\\(count\) recently heard device.*?not direction\.")\)'),
        "android": (AND_STATUS_SCREEN,
                    r'(val radarContentDescription: String\s*\n\s*get\(\) = .*?not direction\.")'),
    },
    {
        "what": "connected, no status yet kicker",
        "kind": "string",
        "why": "the Beacon fold rows and the Status header name the same board state in the same"
               " words while the first status frame is still in flight",
        "ios": (IOS_BEACON_PRESENTATION, r'scanLabel:\s*"(CONNECTED · WAITING FOR BOARD STATUS)"'),
        "android": (AND_DEVICE_SCREEN, r'status == null -> "(CONNECTED · WAITING FOR BOARD STATUS)"'),
    },
    {
        "what": "phone-Bluetooth-off kicker",
        "kind": "string",
        "strip_prefix": {"ios": "IPHONE ", "android": "PHONE "},
        "why": "the phone's own adapter being off must never read as the beacon powering off;"
               " exactly one word (IPHONE / PHONE) differs by design",
        "ios": (IOS_BEACON_PRESENTATION, r'scanLabel:\s*"(IPHONE BLUETOOTH OFF · [^"]*)"'),
        "android": (AND_DEVICE_SCREEN, r'"(PHONE BLUETOOTH OFF · [^"]*)"'),
    },
    {
        "what": "phone-Bluetooth-off connection label",
        "kind": "string",
        "strip_prefix": {"ios": "IPHONE ", "android": "PHONE "},
        "why": "same state as the kicker above, on the hero line; no 'last reported' qualifier,"
               " because the beacon reported nothing",
        "ios": (IOS_BEACON_PRESENTATION, r'connectionLabel:\s*"(IPHONE BLUETOOTH OFF)"'),
        "android": (AND_DEVICE_SCREEN, r'"(PHONE BLUETOOTH OFF)",'),
    },
    {
        "what": "dossier breadcrumb caption",
        "kind": "string",
        "why": "the one line saying the dashed trail on the dossier thumbnail is the PHONE's own"
               " path this session; worded differently on one phone, that map starts reading as"
               " the tracked device's route",
        # Anchored on the rendered caption, not on any label: the iOS screen also speaks two
        # accessibility strings that open with the same words, and the accessibilityLabel spelling
        # ends in "Label(" too.
        "ios": (IOS_DETECTION_DETAIL, r'(?<![A-Za-z])Label\("(Phone breadcrumb trail[^"]*)"'),
        "android": (AND_DETAIL_SCREEN, r'Text\(\s*"(Phone breadcrumb trail[^"]*)"'),
    },
)


# ---------------------------------------------------------------------------------------------
# String-literal fragments, for the "fragments" rows above.
_HOLE = None   # marker for an interpolation hole inside a literal's part list


def _code_only(line, lang):
    """`line` cut at its first `//` outside every string literal. Literals are stepped over with
    _parse_literal, interpolation holes and the literals nested in them included, so a URL inside
    any literal survives and a quoted comment after the code is never read as code."""
    i, n = 0, len(line)
    while i < n:
        if line[i] == '"':
            _, i = _parse_literal(line, i + 1, lang, [])
            continue
        if line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def _strip_comments(code, lang):
    """Comments out, so a comment quoting a label is never read as one: `/* */`, whole-line `//`,
    and a trailing `//` outside every literal on its line (see _code_only)."""
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    return "\n".join(_code_only(line, lang) for line in code.splitlines()
                     if not line.lstrip().startswith("//"))


def _skip_hole(code, i, open_ch, close_ch, lang, nested):
    """Index just past the hole whose opener is at code[i-1]. Literals met inside it are parsed
    and appended to `nested`, because a ternary in a hole still puts words on screen."""
    depth, n = 1, len(code)
    while i < n and depth:
        c = code[i]
        if c == '"':
            inner, i = _parse_literal(code, i + 1, lang, nested)
            nested.append(inner)
            continue
        if c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
        i += 1
    return i


def _parse_literal(code, i, lang, nested):
    """One literal whose opening quote is at code[i-1], as (parts, index past the closing quote).
    `parts` alternates text runs with _HOLE markers. Escapes are decoded, so a `\\u{00B7}` on iOS
    compares equal to a literal middle dot on Android."""
    parts, buf, n = [], [], len(code)

    def flush():
        if buf:
            parts.append("".join(buf))
            buf.clear()

    while i < n:
        c = code[i]
        if c == '"':
            flush()
            return parts, i + 1
        if c == "\\":
            nxt = code[i + 1] if i + 1 < n else ""
            if lang == "swift" and nxt == "(":
                flush()
                parts.append(_HOLE)
                i = _skip_hole(code, i + 2, "(", ")", lang, nested)
                continue
            if nxt == "u":
                m = (re.match(r"u\{([0-9A-Fa-f]+)\}", code[i + 1:]) if lang == "swift"
                     else re.match(r"u([0-9A-Fa-f]{4})", code[i + 1:]))
                if m:
                    buf.append(chr(int(m.group(1), 16)))
                    i += 1 + m.end()
                    continue
            buf.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(nxt, nxt))
            i += 2
            continue
        if lang == "kotlin" and c == "$":
            nxt = code[i + 1] if i + 1 < n else ""
            if nxt == "{":
                flush()
                parts.append(_HOLE)
                i = _skip_hole(code, i + 2, "{", "}", lang, nested)
                continue
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", code[i + 1:])
            if m:
                flush()
                parts.append(_HOLE)
                i += 1 + m.end()
                continue
        buf.append(c)
        i += 1
    flush()
    return parts, i        # unterminated; the caller sees whatever text was read


def _literal_fragments(code, lang):
    """The set of non-empty text runs the string literals in `code` put on screen: every
    top-level literal cut at its holes, literals the source joins with `+` re-joined first, and
    literals found inside holes counted on their own."""
    code = _strip_comments(code, lang)
    literals, nested, i, n = [], [], 0, len(code)
    while i < n:
        if code[i] == '"':
            parts, j = _parse_literal(code, i + 1, lang, nested)
            literals.append((i, j, parts))
            i = j
        else:
            i += 1
    merged = []
    for start, end, parts in literals:
        if merged and code[merged[-1][1]:start].strip() == "+":
            merged[-1] = (merged[-1][0], end, merged[-1][2] + parts)
        else:
            merged.append((start, end, list(parts)))
    out = set()
    for parts in [m[2] for m in merged] + nested:
        run = []
        for p in parts + [_HOLE]:
            if p is _HOLE:
                text = "".join(run)
                if text:
                    out.add(text)
                run = []
            else:
                run.append(p)
    return out


def _inline_labels(rel, block_re, arm_re, arm_count_re, prop):
    """The arms of one INLINE_LABEL_TABLES row (`prop` names it), IN WRITTEN ORDER, as (labels,
    unreadable).

    Order is the comparison key rather than the case name, because the two platforms spell their
    cases differently (.flockCamera vs FLOCK_CAMERA, .axonBodyCam vs BODY_CAM) but write the arms
    in the same order, in the DeviceType getters, the Detection.vendor `switch type` / `when (type)`
    and the BodyCamSignature getters alike. That makes an arm added to one platform only show up as
    a length mismatch, which is the failure this exists to catch. (None, []) when the block itself
    cannot be found.
    """
    m = re.search(block_re, read_local(rel), re.S)
    if not m:
        return None, []
    # Comments out first, trailing ones included: the Detection.vendor blocks carry a comment
    # quoting "<vendor> on wifi", and a comment writing a literal or an arrow is prose. Both counts
    # below must see code only, and the last-literal arm regexes must never read a quoted comment
    # after an arm.
    body = _strip_comments(m.group(1), "swift" if rel.endswith(".swift") else "kotlin")
    labels = re.findall(arm_re, body, re.M)
    unreadable = []
    arms = len(re.findall(arm_count_re, body, re.M))
    if arms != len(labels):
        unreadable.append(f"{arms - len(labels)} {prop} arm(s) do not return a plain string "
                          "literal, so their text was not read")
    return labels, unreadable


def _ios_arm_block(prop):
    return rf"var {prop}: String \{{(.*?)\n    \}}"


def _and_arm_block(prop, subject):
    return rf"val {prop}: String\s*\n\s*get\(\) = when \({subject}\) \{{(.*?)\n\s*\}}"


# One row per per-arm literal table: (what, iOS file, block, arm, arm count, Android file, block,
# arm, arm count). The two DeviceType rows take a plain `return "..."` / `-> "..."` per arm.
# Detection.vendor has one arm that is an EXPRESSION ending in its fallback literal
# (`bodyCamSignature?.vendor ?? "Axon / Utility / Motorola"` on iOS, the same with `?:` on
# Android), so its arm regexes take the last literal on the arm's line once comments are cut, and
# the arm count stays one per `return` / `->`, which keeps the arm-count-versus-literal-count guard
# in _inline_labels meaningful for that table too.
INLINE_LABEL_TABLES = (
    ("inlineLabel", IOS_DEVICE_TYPE, _ios_arm_block("inlineLabel"),
     r'return "([^"]*)"', r"\breturn\b",
     AND_DEVICE_TYPE, _and_arm_block("inlineLabel", "this"), r'->\s*"([^"]*)"', r"->"),
    ("inlineCategory", IOS_DEVICE_TYPE, _ios_arm_block("inlineCategory"),
     r'return "([^"]*)"', r"\breturn\b",
     AND_DEVICE_TYPE, _and_arm_block("inlineCategory", "this"), r'->\s*"([^"]*)"', r"->"),
    ("Detection.vendor", IOS_COMPONENTS, _ios_arm_block("vendor"),
     r'\breturn\b[^\n]*?"([^"]*)"[ \t]*$', r"\breturn\b",
     AND_DEVICE_TYPE, _and_arm_block(r"Detection\.vendor", "type"),
     r'->[^\n]*?"([^"]*)"[ \t]*$', r"->"),
    ("BodyCamSignature.vendor", IOS_OUI_VENDORS, _ios_arm_block("vendor"),
     r'return "([^"]*)"', r"\breturn\b",
     AND_OUI_VENDORS, _and_arm_block("vendor", "this"), r'->\s*"([^"]*)"', r"->"),
)


def check_inline_labels():
    """Per-arm display tables must read identically on both phones, arm for arm.

    DeviceType.inlineLabel and .inlineCategory are the only two places a category name is written
    into lowercase display text: the Related help disclosure's "3 answers for ALPR camera", the
    dossier badge pill, and the Status nearest card. Both are hand-written per case precisely
    because no transform gets them right. `label.lowercased()` flattened "Flock Raven" to "flock
    raven", and `category.lowercased()` spelled the ALPR initialism "alpr". Hand-written on two
    platforms is exactly the shape that drifts, and all four doc comments already CLAIM
    byte-identity, so pin the claim. Detection.vendor (the dossier's vendor line per category) and
    BodyCamSignature.vendor (the maker behind each body-cam signature) are the same shape and are
    pinned the same way.

    NOTE these are display strings only. `category` itself is untouched and remains the key the
    filters, counts, widget rows and drive surface match on; do NOT fold the two together.
    """
    print("\n== per-arm display tables (both phones write the same text) ==")
    drift = 0
    for (prop, ios_file, ios_block, ios_arm, ios_count,
         and_file, and_block, and_arm, and_count) in INLINE_LABEL_TABLES:
        ios, ios_bad = _inline_labels(ios_file, ios_block, ios_arm, ios_count, prop)
        and_, and_bad = _inline_labels(and_file, and_block, and_arm, and_count, prop)
        if ios is None or and_ is None:
            blind = ios_file if ios is None else and_file
            print(f"   !! could not read the {prop} block out of {blind}")
            drift += 1
            continue
        if ios_bad or and_bad:
            for msg in ios_bad:
                print(f"   !! iOS      {msg}")
            for msg in and_bad:
                print(f"   !! Android  {msg}")
            drift += 1
            continue
        if ios != and_:
            print(f"   !! the two platforms write different {prop} text")
            for i in range(max(len(ios), len(and_))):
                a = ios[i] if i < len(ios) else "<missing>"
                b = and_[i] if i < len(and_) else "<missing>"
                if a != b:
                    print(f"      arm {i}: iOS {a!r} vs Android {b!r}")
            print("      one phone would name the category differently in the same sentence")
            drift += 1
            continue
        print(f"   ok: {prop:23s} identical ({len(ios)} arms) - {', '.join(ios)}")
    return drift


def _pinned_constant(rel, pattern, kind):
    """The pinned value in `rel` as (value, reason). value is None when it could not be read.

    Zero matches and two matches are BOTH failures, and so is a list or a template that parsed
    to nothing: a pin this parser cannot read is a pin nothing compares, and both sides would then
    be missing it in the same way, so the sets would still "agree". Same rule as the faqKey
    parsers above.
    """
    try:
        text = read_local(rel)
    except OSError as exc:
        return None, f"{rel} could not be read ({exc})"
    found = re.findall(pattern, text, re.S)
    if len(found) != 1:
        return None, f"{len(found)} declarations matched in {rel} (expected exactly 1)"
    region = found[0]
    if isinstance(region, tuple):
        if kind != "fragments":
            return None, f"the {rel} pattern has several groups, which only a fragments row reads"
        region = "\n".join(region)
    if kind == "string":
        return region, None
    if kind == "fragments":
        frags = _literal_fragments(region, "swift" if rel.endswith(".swift") else "kotlin")
        if not frags:
            return None, f"the region in {rel} holds no string text"
        return frags, None
    items = re.findall(r'"([^"]*)"', region)
    if not items:
        return None, f"the declaration in {rel} parsed to an empty list"
    return items, None


def _scaled(value, factor):
    """`value` as written (digits, an optional point, `_` separators) times `factor`, as an exact
    number string, or None when it is not a plain number."""
    if not re.fullmatch(r"[0-9][0-9_]*(?:\.[0-9_]+)?", value):
        return None
    return str(fractions.Fraction(value.replace("_", "")) * factor)


def check_shared_constants():
    """One rule, two declarations. Assert the literals themselves, not the comments claiming them."""
    print("\n== cross-platform constants (iOS and Android must declare the same literal) ==")
    drift = 0
    for pin in SHARED_CONSTANTS:
        what, kind = pin["what"], pin["kind"]
        # An option on a kind it cannot apply to would crash or compare the wrong thing (fold_case
        # over a string walks its characters), so the row is reported instead of half-applied.
        misplaced = [opt for opt, kinds in (("strip_prefix", ("string",)), ("scale", ("string",)),
                                            ("fold_case", ("fragments",)))
                     if pin.get(opt) and kind not in kinds]
        if misplaced:
            print(f"   !! {what}: {', '.join(misplaced)} does not apply to a {kind} row, so it was"
                  " NOT compared")
            drift += 1
            continue
        ios_value, ios_reason = _pinned_constant(pin["ios"][0], pin["ios"][1], kind)
        and_value, and_reason = _pinned_constant(pin["android"][0], pin["android"][1], kind)
        prefixes = pin.get("strip_prefix")
        if prefixes:
            # A declared one-word difference: each side must still START with its own word, and
            # only the remainder is compared. A side that dropped or changed the word is reported
            # as unreadable, which is drift, not a pass.
            if ios_value is not None and not ios_value.startswith(prefixes["ios"]):
                ios_value, ios_reason = None, (f"the iOS literal no longer starts with "
                                               f"{prefixes['ios']!r}")
            if and_value is not None and not and_value.startswith(prefixes["android"]):
                and_value, and_reason = None, (f"the Android literal no longer starts with "
                                               f"{prefixes['android']!r}")
        scale = pin.get("scale")
        if scale:
            # Exact arithmetic, so 45.5 s against 45_000 ms is drift rather than a rounding match.
            ios_scaled = _scaled(ios_value, scale["ios"]) if ios_value is not None else None
            and_scaled = _scaled(and_value, scale["android"]) if and_value is not None else None
            if ios_value is not None and ios_scaled is None:
                ios_reason = "the iOS value is not a plain number"
            if and_value is not None and and_scaled is None:
                and_reason = "the Android value is not a plain number"
            ios_value, and_value = ios_scaled, and_scaled
        if ios_value is None or and_value is None:
            print(f"   !! {what}: could not be read, so it was NOT compared")
            for reason in (ios_reason, and_reason):
                if reason:
                    print(f"      {reason}")
            print("      it moved or changed shape; fix the source or the pattern in"
                  " SHARED_CONSTANTS")
            drift += 1
            continue
        if prefixes:
            ios_value = ios_value[len(prefixes["ios"]):]
            and_value = and_value[len(prefixes["android"]):]
        if pin.get("fold_case"):
            ios_value = {v.lower() for v in ios_value}
            and_value = {v.lower() for v in and_value}
        if ios_value == and_value:
            if kind == "string":
                shown = ios_value if not prefixes else f"<{'/'.join(prefixes.values())}>{ios_value}"
                if pin.get("unit"):
                    shown = f"{shown} {pin['unit']}"
            elif kind == "list":
                shown = f"{len(ios_value)} entries, in order"
            else:
                shown = f"{len(ios_value)} text fragment(s)"
            print(f"   ok: {what:24} identical ({shown})")
            continue
        print(f"   !! {what} DIFFERS between the two apps")
        print(f"      {pin['ios'][0]}")
        print(f"      {pin['android'][0]}")
        if kind in ("list", "fragments"):
            only_ios = sorted(v for v in ios_value if v not in and_value)
            only_and = sorted(v for v in and_value if v not in ios_value)
            print(f"      iOS only:     {only_ios or '-'}")
            print(f"      Android only: {only_and or '-'}")
            if kind == "list" and not only_ios and not only_and:
                print("      same entries, DIFFERENT ORDER, which is the same defect here")
        else:
            print(f"      iOS      {ios_value!r}")
            print(f"      Android  {and_value!r}")
            if scale:
                print(f"      (both in {pin.get('unit', 'the shared unit')}: iOS as written times"
                      f" {scale['ios']}, Android times {scale['android']})")
        print(f"      {pin['why']}")
        drift += 1
    return drift


# Rules whose two (or more) sides are CODE SHAPES rather than one literal: a seed value, a
# guard, a default. Each side names a file, an optional block (matched exactly once; the
# requirements are then searched inside it) and the lines that make the rule true there, each of
# which must match exactly once, or as many times as its optional third element says. A side that
# lost its line is reported by name, and a block that moved is reported as unreadable, the same
# "cannot read is not a pass" rule as above.
#
# A rule that pins ARM ORDER needs one regex spanning those arms in order, and the gap between two
# of them may hold comment lines. _KT_ARM_GAP is that gap, and nothing else: a gap written as
# `[\s\S]*?` would pass an arm INSERTED between the two being pinned, which is the ordering defect
# such a rule exists to catch. Swift writes its line comments the same way, so the dossier-order
# rule below spans its panel list with this too.
_KT_ARM_GAP = r"\s*(?://[^\n]*\s*)*"

# The two shipped FAQ answers that promise the desert restore rule to the user, as needles for the
# rule below. Built with re.escape from the sentences THEMSELVES, never hand-written as a pattern:
# a hand-written one drifts into matching a reworded promise, and the promise is the point. The two
# faq-content.json copies are already asserted byte-identical (check_faq_copies), so this is the
# other half of that guard: identical copies that both stopped saying it still pass byte equality.
#
# BOTH SENTENCES ARE SCOPED, and the scoping is the promise, not hedging. "if this phone saved a
# mode" is there because a phone that never enabled Desert itself holds nothing and gets no control;
# "when that section is shown" is there because a mesh-detect board draws no Alerts row at all; and
# the waiting clause is the durability the offer actually has (persisted beside the pre-Desert mode,
# republished at launch) plus the two panel surfaces that carry it when the cards cannot. A copy
# that drops any of the three is promising a control that can fail to appear.
#
# THE CLOSING CLAUSE IS NOW TWO ARMS, and it was one arm too few: it promised the Beacon tab while
# the beacon was disconnected, and with no session at all there IS no Beacon tab - neither app
# mounts it - so the sentence was false in the exact state the durable offer was built for. The
# second arm names the connect screen, which is the screen those owners are actually looking at.
# Both arms are now surfaces the code draws (AlertRestorePanel, from the two gates pinned below),
# so a side that deletes either surface has to delete its half of this promise too.
_FAQ_DESERT_PROMISES = (
    ("the alerts answer still promises an offer, not an automatic restore",
     re.escape("trackers never beep on the board in any mode, and desert mode drops the board to"
               " silent while it runs. when you switch desert mode off yourself, your previous"
               " mode comes back, unless you picked a mode by hand while it was running, silent"
               " included. when the board ends desert mode on its own, after a factory reset, on"
               " an older board, or because another paired phone ended it, the app does not change"
               " your alert mode. if this phone saved a mode on the way into desert mode, it offers"
               " that one back instead. a restore alerts control appears on the desert card under"
               " Beacon, and under alerts as well when that section is shown. nothing changes until"
               " you tap it. the offer waits through app restarts. it moves to the top of the"
               " Beacon tab whenever board controls are unavailable, and onto the connect screen"
               " when the app is back to looking for a beacon, so it stays tappable with the"
               " beacon off or gone.")),
    ("the desert-mode answer still promises the same thing",
     re.escape("desert mode automatically silences the board while it runs. switching it off"
               " yourself restores your prior alert mode, unless you picked a mode by hand while"
               " desert mode was running, silent included. if the board ends desert mode on its"
               " own, your alert mode is left alone, and if this phone saved a mode on the way in,"
               " a restore alerts control appears on the desert card under Beacon, and under alerts"
               " as well when that section is shown, so the choice stays yours. the offer waits"
               " through app restarts. it moves to the top of the Beacon tab whenever board"
               " controls are unavailable, and onto the connect screen when the app is back to"
               " looking for a beacon, so it stays tappable with the beacon off or gone.")),
)

SHARED_SHAPES = (
    {
        "what": "Motorola vendor-proxy default (OFF on every board; absent key means pre-split, on)",
        "why": "both Beacon tabs seed the sub-toggle before the first status frame; a seed that"
               " claims ON contradicts what a fresh board ships and what ble-protocol.md says",
        "sides": (
            ("firmware beacon-board", FW_BEACON_MAIN, None,
             (("ships the proxy OFF", r"\bpoliceRestoreEnabled\(false\)"),)),
            ("firmware mesh-detect", FW_MESH_MAIN, None,
             (("ships the proxy OFF", r"\bpoliceRestoreEnabled\(false\)"),)),
            ("protocol doc", DOCS_BLE_PROTOCOL, r"(?m)^(\| `motorola` \|[^\n]*)",
             (("names the default", r"Default off on every target"),)),
            ("iOS", IOS_SETTINGS, None,
             (("no-frame seed is OFF", r"@State private var motorolaOn = false\b"),)),
            ("iOS", IOS_BLE_MANAGER, None,
             (("absent moto key reads as on", r"\bmotorolaOn = moto \?\? true\b"),)),
            ("Android", AND_DEVICE_SCREEN, None,
             (("no-frame seed is OFF", r"mutableStateOf\(status\?\.moto == true\)"),)),
            ("Android", AND_DEVICE_TYPE, None,
             (("absent moto key reads as on", r'optBoolean\("moto", true\)'),)),
        ),
    },
    {
        "what": "body-cam category default (ON on every board; the seed matches what ships)",
        "why": "both Beacon tabs seed the category switch before the first status frame, and the"
               " firmware ships that category ON, so a seed claiming OFF draws a switch that"
               " animates itself on when the frame lands and reads, until it does, as if the"
               " detector the user came for were off",
        "sides": (
            ("firmware beacon-board", FW_BEACON_MAIN, None,
             (("ships the category ON", r"\baxonRestoreEnabled\(true\)"),)),
            ("firmware mesh-detect", FW_MESH_MAIN, None,
             (("ships the category ON", r"\baxonRestoreEnabled\(true\)"),)),
            ("protocol doc", DOCS_BLE_PROTOCOL, r"(?m)^(\| `axon` \| enable/disable[^\n]*)",
             (("names the default", r"on by default"),)),
            # The seed is a PLACEHOLDER, so each app side pins the line that retires it too:
            # seeding ON is only honest while the first status frame still overwrites it, which is
            # how a board with the category genuinely off stops reading as on. What an ABSENT
            # `axon` key means is deliberately NOT part of this rule, unlike the `moto` row above:
            # every supported firmware writes that key on every status frame.
            ("iOS", IOS_SETTINGS, None,
             (("no-frame seed is ON", r"@State private var bodyCamOn = true\b"),
              ("and the first frame still decides", r"else \{ bodyCamOn = s\.axon \}"))),
            ("Android", AND_DEVICE_SCREEN, None,
             (("no-frame seed is ON", r"mutableStateOf\(status\?\.bodyCam \?: true\)"),
              ("and the first frame still decides",
               r"\{ s -> bodyCamOn = s\?\.bodyCam \?: bodyCamOn \}"))),
        ),
    },
    {
        "what": "desert still-silent notice gate (a real Desert run this app run, Desert now off,"
                " alerts still Silent, not a mesh board)",
        # The four inputs are pinned where they are READ, not only where they are declared: the
        # gate is one boolean expression, so a side that wired the right expression to the wrong
        # source (the saved restore token instead of the run flag, Vibrate folded into silent)
        # would keep its own suite green and still show or hide the notice on one phone only.
        # The arming sides pin the other half of "this app run": the flag is in-memory, starts
        # false, and has exactly one assignment, inside reconcileDesert's Desert-on branch. The
        # gap in those two patterns is brace-free lines only, so an arm moved out from under the
        # branch stops matching instead of sliding down to the next line that looks right.
        "why": "the notice explains a silence the user did not choose. A phone that shows it"
               " without a Desert run this session calls a hand-picked Silent a fault, a phone"
               " that misses it leaves an owner who came back from Desert expecting beeps hearing"
               " nothing, and on a mesh board it names an Alerts row that board does not draw",
        "sides": (
            ("iOS gate", IOS_SETTINGS, r"(func shouldShowDesertSilenceNotice\(.*?\n\})",
             (("all four inputs, one expression",
               r"sawDesertOn && !desertOn && alertsSilent && !isMeshDetect"),)),
            ("Android gate", AND_DEVICE_SCREEN,
             r"(internal fun shouldShowDesertSilenceNotice\(.*?\): Boolean = [^\n]*)",
             (("all four inputs, one expression",
               r"sawDesertOn && !desertOn && alertsSilent && !isMeshDetect"),)),
            ("iOS Desert card", IOS_SETTINGS, None,
             (("saw-Desert reads the run flag", r"sawDesertOn: ble\.desertRanThisRun\b"),
              ("desert reads the card's own toggle", r"desertOn: desertOn\b"),
              ("silent means Silent, not Vibrate", r"alertsSilent: ble\.alertMode == \.silent\b"),
              ("mesh-detect is excluded", r"isMeshDetect: ble\.status\?\.isMeshDetect == true"),
              ("the pinned string is what it draws", r"Text\(desertSilenceNotice\)"),
              # The premise of the narrowing: the row the copy sends the user to.
              ("and the Alerts row it points at is mesh-gated",
               r"if ble\.status\?\.isMeshDetect != true \{"))),
            ("Android Desert card", AND_DEVICE_SCREEN, None,
             (("saw-Desert reads the run flag", r"sawDesertOn = desertRanThisRun\b"),
              ("desert reads the card's own toggle", r"desertOn = desertOn\b"),
              ("silent means SILENT, not VIBRATE",
               r"alertsSilent = shownAlertMode == AlertMode\.SILENT\b"),
              ("mesh-detect is excluded", r"isMeshDetect = status\?\.isMeshDetect == true"),
              ("the pinned string is what it draws", r"Text\(DESERT_SILENCE_NOTICE,"),
              ("and the Alerts row it points at is mesh-gated",
               r"if \(status\?\.isMeshDetect != true\) \{"))),
            ("iOS run flag", IOS_BLE_MANAGER, None,
             (("in-memory, starts false",
               r"@Published private\(set\) var desertRanThisRun = false"),
              ("armed inside reconcileDesert's Desert-on branch",
               r"if s\.desertMode \{\n(?:[^}\n]*\n)*?\s*"
               r"if !desertRanThisRun \{ desertRanThisRun = true \}"),
              # Two: the declaration above and that one arm. A reset anywhere, or a second arming
              # site, moves this count.
              ("and assigned nowhere else",
               r"\bdesertRanThisRun\s*=\s*(?:true|false)\b", 2))),
            ("Android run flag", AND_BLE_MANAGER, None,
             (("in-memory, starts false",
               r"private val _desertRanThisRun = MutableStateFlow\(false\)"),
              ("armed inside reconcileDesert's Desert-on branch",
               r"if \(s\.desertMode\) \{\n(?:[^}\n]*\n)*?\s*_desertRanThisRun\.value = true"),
              ("and assigned nowhere else",
               r"_desertRanThisRun\.value\s*=\s*(?:true|false)\b"))),
        ),
    },
    {
        "what": "desert restore offer (a board-ended desert run never moves the alert mode; the app"
                " offers the mode back on every surface the user can reach, four on iOS and five on"
                " Android, leading the page on the ones that are cards of their own, and the offer"
                " clears when answered)",
        # THE ABSENCE IS THE RULE, which is why it is pinned here and not left to the suites.
        # reconcileDesert used to call the alert-mode setter, so a factory reset, an older board
        # that does not persist Desert, or a second paired phone could put the board back on sound
        # with nobody in the loop. Nothing in the code that replaced it says so out loud: what says
        # it is that the setter is GONE from both bodies, and a suite asserts what a call did, not
        # that no call is there. Hence the two needles counted at ZERO. They skip comment lines on
        # purpose: the comment inside each body still quotes the old call by name, and a rule a
        # comment could satisfy would be worth nothing.
        #
        # The transition sides carry the other half. `.boardEndedDesert` / BOARD_ENDED_DESERT can
        # only move the saved mode into `offered`, and the one arm that restores is the one with a
        # tap behind it, so the restore count is pinned at 1 on both. `.userPickedMode` empties the
        # state WHATEVER mode was picked, Silent included, which is what makes a silence the user
        # chose outrank a mode the app is still holding.
        "why": "a device that makes noise while its owner believes it is silent is the worst"
               " failure this product has, and restoring on a board-reported desert-off is exactly"
               " that: nobody tapped anything. A side that restores there un-mutes a"
               " counter-surveillance detector behind its owner's back; a side that drops an offer"
               " surface leaves the way back on a screen the user cannot reach (the last one to be"
               " added was Android's OTA wait screen, where a reboot window its own copy puts at up"
               " to a minute used to show nothing at all); a side that moves the"
               " panel copy back down its"
               " page reports the same silence in two different places on the two phones; and a"
               " shipped FAQ that still promises more than the surfaces deliver is the app telling"
               " its owner something the code does not do",
        "sides": (
            ("iOS reconcileDesert", IOS_BLE_MANAGER,
             r"func reconcileDesert\(_ s: DeviceStatus\) \{(.*?)\n    \}",
             (("a board-ended desert run only arms the offer",
               r"applyDesertAlertModeEvent\(\.boardEndedDesert\)"),
              ("desert running again answers an offer already armed",
               r"if pendingAlertModeRestore != nil \{ applyDesertAlertModeEvent\(\.boardReportsDesertOn\) \}"),
              # Both the setter and a bare assignment: reconcileBuzzer writes `alertMode = .silent`
              # directly, so counting only the setter would miss the same defect written the other
              # way. `\balertMode` is case-sensitive on purpose, so pendingAlertModeRestore and
              # applyDesertAlertModeEvent do not read as writes.
              ("and NOTHING here writes the alert mode",
               r"^(?!\s*(?://|\*))[^\n]*(?:setAlertMode\(|\balertMode\s*=[^=])", 0))),
            ("Android reconcileDesert", AND_BLE_MANAGER,
             r"private fun reconcileDesert\(s: DeviceStatus\) \{(.*?)\n    \}",
             (("a board-ended desert run only arms the offer",
               r"applyDesertAlertModeEvent\(DesertAlertModeEvent\.BOARD_ENDED_DESERT\)"),
              ("desert running again answers an offer already armed",
               r"applyDesertAlertModeEvent\(DesertAlertModeEvent\.BOARD_REPORTS_DESERT_ON\)"),
              ("and NOTHING here writes the alert mode",
               r"^(?!\s*(?://|\*))[^\n]*(?:setAlertMode\(|_alertMode\.value\s*=[^=])", 0))),
            ("iOS transition", IOS_BLE_MANAGER,
             r"func desertAlertModeTransition\(state: DesertAlertModeState,(.*?)\n\}",
             (("a mode picked by hand empties the state, whatever mode it was",
               r"case \.userPickedMode:\n(?:\s*//[^\n]*\n)*\s*"
               r"return DesertAlertModeOutcome\(state: \.empty,"),
              ("exactly one arm restores", r"effect: \.restore", 1),
              ("and it is the ending with a tap behind it",
               r"case \.userEndedDesert:[\s\S]*?effect: \.restore, restoreTo: prior\)"),
              ("the board's ending only moves the saved mode into the offer",
               r"case \.boardEndedDesert:[\s\S]*?DesertAlertModeState\(saved: nil, offered: prior\)"),
              ("desert starting again closes an offer from the last run",
               r"case \.boardReportsDesertOn:[\s\S]*?"
               r"DesertAlertModeState\(saved: state\.saved, offered: nil\)"),
              ("and so does enabling it from this phone",
               r"case \.userEnabledDesert:[\s\S]*?"
               r"DesertAlertModeState\(saved: current, offered: nil\)"))),
            ("Android transition", AND_BLE_MANAGER,
             r"internal fun desertAlertModeTransition\((.*?)\n\}",
             (("a mode picked by hand empties the state, whatever mode it was",
               r"DesertAlertModeEvent\.USER_PICKED_MODE ->\n\s*"
               r"DesertAlertModeOutcome\(DesertAlertModeState\.EMPTY,"),
              ("exactly one arm restores", r"DesertAlertModeEffect\.RESTORE", 1),
              ("and it is the ending with a tap behind it",
               r"DesertAlertModeEvent\.USER_ENDED_DESERT ->[\s\S]*?"
               r"DesertAlertModeEffect\.RESTORE, state\.saved\)"),
              ("the board's ending only moves the saved mode into the offer",
               r"DesertAlertModeEvent\.BOARD_ENDED_DESERT ->[\s\S]*?"
               r"DesertAlertModeState\(offered = state\.saved\)"),
              # These two name only `saved`, so what clears the offer is the data class default
              # pinned on the side below. Android states it that way and iOS writes `offered: nil`
              # out; the two shapes are the same rule.
              ("desert starting again closes an offer from the last run",
               r"DesertAlertModeEvent\.BOARD_REPORTS_DESERT_ON ->[\s\S]*?"
               r"DesertAlertModeState\(saved = state\.saved\)"),
              ("and so does enabling it from this phone",
               r"DesertAlertModeEvent\.USER_ENABLED_DESERT ->[\s\S]*?"
               r"DesertAlertModeState\(saved = current\)"))),
            ("Android offer state", AND_BLE_MANAGER,
             r"internal data class DesertAlertModeState\((.*?)\n\)",
             (("the saved half defaults to nothing held", r"val saved: AlertMode\? = null,"),
              ("and so does the offered half", r"val offered: AlertMode\? = null,"))),
            ("iOS setAlertMode", IOS_BLE_MANAGER,
             r"func setAlertMode\(_ m: AlertMode, origin: AlertModeOrigin\) \{(.*?)\n    \}",
             (("the origin decides, so a mode picked by hand clears the offer here",
               r"applyDesertAlertModeEvent\(origin == \.user \? \.userPickedMode : \.appSetMode\)"),)),
            ("Android setAlertMode", AND_BLE_MANAGER,
             r"fun setAlertMode\(mode: AlertMode, origin: AlertModeOrigin\) \{(.*?)\n    \}",
             (("the origin decides, so a mode picked by hand clears the offer here",
               r"if \(origin == AlertModeOrigin\.USER\) DesertAlertModeEvent\.USER_PICKED_MODE\n\s*"
               r"else DesertAlertModeEvent\.APP_SET_MODE,"),)),
            ("iOS take the offer", IOS_BLE_MANAGER,
             r"func takePendingAlertModeRestore\(\) \{(.*?)\n    \}",
             (("nothing pending, nothing happens",
               r"guard let prior = pendingAlertModeRestore else \{ return \}"),
              ("and taking it is a user pick, which is what clears it",
               r"setAlertMode\(prior, origin: \.user\)"))),
            ("Android take the offer", AND_BLE_MANAGER,
             r"fun takePendingAlertModeRestore\(\) \{(.*?)\n    \}",
             (("nothing pending, nothing happens",
               r"val prior = _pendingAlertModeRestore\.value \?: return"),
              ("and taking it is a user pick, which is what clears it",
               r"setAlertMode\(prior, AlertModeOrigin\.USER\)"))),
            # FOUR surfaces on iOS, FIVE on Android, from ONE offer definition and ONE panel
            # definition each. The tap counts differ by platform and that is structural, not drift:
            # iOS reads the manager from the environment inside the single view (1), Android passes
            # the action in, from the Desert card's inline lambda, the Alerts card's hoisted one,
            # and the panel every detached surface shares (3). Either number moving is a surface
            # that grew its own action or lost the offer.
            #
            # THE PANEL SURFACES ARE PINNED BY POSITION, not only by existence. They are the same
            # card (AlertRestorePanel) and it LEADS its page on both platforms: the Beacon screen's
            # copy above the stats, the connect screen's copy above the setup and scan panels. iOS
            # used to draw its copy after the stats grid, hanging off the board-unavailable notice,
            # while Android led its slot list with it - the same silence reported in two different
            # places. The needles below span the neighbour each one leads, so a copy that slides
            # back down the page fails here rather than in a screenshot nobody takes.
            #
            # THE PRE-CONNECT CALL SITES ARE NOW PINNED TOO, on the three sides after the two below
            # (RootView.swift and ConnectView.swift on iOS, AcabApp.kt on Android). They used to be
            # left out, and said so here, because a file this script reads has to be in both
            # firmware-ci.yml path lists; adding those three paths is what let the render sites
            # themselves be held, instead of only everything they call. It matters because deleting
            # a render site is exactly the regression this rule exists to catch, and the gate, the
            # panel, the offer, the strings and the take all survive that deletion untouched.
            ("iOS offer surfaces", IOS_SETTINGS, None,
             (("one definition of the offer", r"struct AlertRestoreOffer: View \{", 1),
              ("one card for the surfaces that are not inside another card",
               r"struct AlertRestorePanel: View \{", 1),
              ("the desert card's silence slot carries it",
               r"case \.offer:\n\s*AlertRestoreOffer\(\)\n"),
              ("the alerts card carries the same one",
               r"if alertRestoreOffered \{ AlertRestoreOffer\(\) \}"),
              ("every tap is the one take action", r"ble\.takePendingAlertModeRestore\(\)", 1),
              ("and the sample tour offers nothing",
               r"func alertRestoreIsOffered\(isDemoMode: Bool, pending: AlertMode\?\) -> Bool \{\n"
               r"\s*!isDemoMode && pending != nil\n\}"),
              ("which is the gate this screen reads",
               r"private var alertRestoreOffered: Bool \{\n\s*alertRestoreIsOffered\("
               r"isDemoMode: ble\.demoMode, pending: ble\.pendingAlertModeRestore\)\n\s*\}"),
              ("the offer outranks the notice in that one slot",
               r"if restoreOffered \{ return \.offer \}"),
              # The board gate and the collapsed row, the two ways the offer went missing at a
              # glance. iOS disables the whole hardware panel as ONE unit and a SwiftUI disable
              # cannot be opted out of by a child, so this copy has to live outside that panel.
              ("a copy LEADS the compact page while the board is away, above the stats",
               r"if desertRestoreNeedsDetachedSurface\(restoreOffered: alertRestoreOffered,\n"
               r"\s*boardControlsAvailable: hardwareControlsEnabled\) \{\n"
               r"\s*AlertRestorePanel\(\)\n\s*\}\n\s*statsGrid"),
              ("and leads the regular-width page too, above the two-column split",
               r"if desertRestoreNeedsDetachedSurface\(\n\s*restoreOffered: alertRestoreOffered,\n"
               r"\s*boardControlsAvailable: hardwareControlsEnabled\) \{\n"
               r"\s*AlertRestorePanel\(\)\n\s*\}\n\s*HStack\(alignment: \.top, spacing: 14\) \{"),
              # The screen under all of them. Its gate is the negation of the one that draws the tab
              # shell, so this surface and the three above can never draw together, and with no
              # session at all it is the ONLY one of the four on the phone. ONE screen reads it
              # here, where Android has two: the iOS shell stays visible through an OTA reboot, so
              # the detached copy above covers that window and no wait screen of its own exists.
              ("and a fourth gate exists for the screen that has no Beacon tab at all",
               r"func desertRestoreNeedsPreConnectSurface\(restoreOffered: Bool, "
               r"mainShellVisible: Bool\) -> Bool \{\n\s*restoreOffered && !mainShellVisible\n\}"),
              ("and the collapsed alerts row says a restore is owed",
               r'alertRestoreOffered \? "SILENT \\u\{00B7\} RESTORE WAITING" : "SILENT"'))),
            ("Android offer surfaces", AND_DEVICE_SCREEN, None,
             (("one definition of the offer",
               r"internal fun AlertRestoreOffer\(onRestore: \(\) -> Unit\) \{", 1),
              ("one card for the surfaces that are not inside another card",
               r"internal fun AlertRestorePanel\(ble: AcabBleManager\) \{", 1),
              ("the desert card's silence slot carries it",
               r"DesertSilenceSlot\.OFFER -> AlertRestoreOffer \{ ble\.takePendingAlertModeRestore\(\) \}"),
              ("the alerts card carries the same one",
               r"if \(restoreOffered\) AlertRestoreOffer\(onRestore\)"),
              # THREE spellings of the call: the desert card's inline lambda, the hoisted one the
              # alerts card takes, and the one inside AlertRestorePanel that both panel surfaces
              # reach. A fourth spelling is a surface that grew its own take - including the connect
              # screen, which must call the panel and never the manager.
              ("every tap is the one take action", r"ble\.takePendingAlertModeRestore\(\)", 3),
              ("and the sample tour offers nothing",
               r"internal fun alertRestoreIsOffered\(demoMode: Boolean, pending: AlertMode\?\): "
               r"Boolean =\n\s*!demoMode && pending != null"),
              ("which is the gate this screen reads",
               r"val alertRestoreOffered = alertRestoreIsOffered\(demo, pendingAlertRestore\)"),
              ("the offer outranks the notice in that one slot",
               r"restoreOffered -> DesertSilenceSlot\.OFFER"),
              # Android's fold rows COLLAPSE when the board is away (FoldRow's displayedExpanded),
              # so both in-panel copies stop rendering at all; this panel is the one that does not,
              # and it LEADS the page above the one-or-two-column split, which is the position iOS
              # now matches. It is deliberately NOT a `slots` entry: a slot gets split into one of
              # two columns at >=840dp, which would demote a silence this app imposed to half a page
              # beside the stats, and its presence would move where the slot list divides.
              ("a copy LEADS the page while the board is away, above the column split",
               r"if \(desertRestoreNeedsDetachedSurface\(alertRestoreOffered, "
               r"boardControlsAvailable\)\) \{\n\s*AlertRestorePanel\(ble\)\n\s*\}"
               + _KT_ARM_GAP + r"if \(twoCol\) \{"),
              ("and it is not a column slot", r'"restore" to ', 0),
              # The screens under all of them. This gate is the negation of the one that hands off
              # to the tab shell, so its surfaces and the three above can never draw together, and
              # with no session at all one of them is the ONLY copy on the phone. TWO screens read
              # it on this side: the connect screen, and the locked OTA wait screen that covers the
              # parked shell during a reboot. They sit on opposite sides of one early return in
              # AcabApp, which is what keeps them exclusive; both call sites are pinned below.
              ("and a fourth gate exists for the two screens that have no Beacon tab at all",
               r"internal fun desertRestoreNeedsPreConnectSurface\(\n\s*restoreOffered: Boolean,\n"
               r"\s*mainShellVisible: Boolean,\n\s*\): Boolean = restoreOffered && !mainShellVisible"),
              ("and the collapsed alerts row says a restore is owed",
               r'if \(alertRestoreOffered\) "SILENT \u00b7 RESTORE WAITING" else "SILENT"'))),
            # THE RENDER SITES THEMSELVES, one side per file that draws a pre-connect copy. The
            # gates above are decisions; these are the three places a decision becomes pixels, and
            # the severe defect they close is that deleting any one of them changes no gate, no
            # string and no take, so every other needle in this rule stays green while the offer
            # stops reaching the screen the user is looking at.
            #
            # EACH SIDE ALSO PINS WHY ITS PLATFORM NEEDS THE SURFACES IT HAS, because that is the
            # asymmetry a reader would otherwise call drift: RootView keeps the tab shell up through
            # an OTA reboot (isRebootingForUpdate), so iOS needs one pre-connect screen; AcabApp
            # withholds the reconnect shell for that window (shouldUseReconnectShell's !otaActive)
            # and parks the shell pointer-disabled with its semantics cleared, so Android needs two.
            ("iOS pre-connect decision", IOS_ROOT_VIEW, None,
             (("the decision is taken where the shell is a real input",
               r"private var connectScreenCarriesRestore: Bool \{\n"
               r"\s*desertRestoreNeedsPreConnectSurface\(\n"
               r"\s*restoreOffered: alertRestoreIsOffered\(isDemoMode: ble\.demoMode,\n"
               r"\s*pending: ble\.pendingAlertModeRestore\),\n"
               r"\s*mainShellVisible: mainIsUsable\)\n\s*\}"),
              ("and handed to the one screen that draws it",
               r"ConnectView\(showAlertRestore: connectScreenCarriesRestore,"),
              ("the shell stays up through an OTA reboot, so no wait screen of its own is needed",
               r"hasUsableSession \|\| \(hasMountedMain && \(ble\.isReconnecting"
               r" \|\| ble\.isRebootingForUpdate\)\)"),
              ("and when it is down it is hidden, not unmounted",
               r"\.opacity\(mainIsUsable \? 1 : 0\)\n"
               r"\s*\.allowsHitTesting\(mainIsUsable\)\n"
               r"\s*\.accessibilityHidden\(!mainIsUsable\)"))),
            ("iOS connect screen", IOS_CONNECT_VIEW, None,
             (("the screen takes the decision rather than making one",
               r"var showAlertRestore = false", 1),
              ("and the panel LEADS the page, above the setup card",
               r"if showAlertRestore \{ AlertRestorePanel\(\) \}"
               r"(?:\s*//[^\n]*)*\s*setupIntro"),
              ("with no take of its own", r"takePendingAlertModeRestore", 0))),
            ("Android pre-connect decision", AND_ACAB_APP, None,
             (("the decision is taken where the shell is a real input",
               r"val preConnectRestoreOffer = desertRestoreNeedsPreConnectSurface\(\n"
               r"\s*restoreOffered = alertRestoreIsOffered\(demoMode, pendingAlertRestore\),\n"
               r"\s*mainShellVisible = state == ConnState\.READY \|\| reconnectUsable,\n\s*\)"),
              ("the pre-connect list LEADS with it, above the per-state panels",
               r"if \(preConnectRestoreOffer\) item \{ AlertRestorePanel\(ble\) \}"
               + _KT_ARM_GAP + r"when \(state\) \{"),
              ("the OTA wait screen takes the same flag",
               r"OtaWaitScreen\(ota, showAlertRestore = preConnectRestoreOffer, ble = ble\)"),
              ("and draws the same panel inside its own column",
               r"if \(showAlertRestore\) \{\n\s*AlertRestorePanel\(ble\)\n"
               r"\s*Spacer\(Modifier\.height\(28\.dp\)\)\n\s*\}"),
              # The two reasons the wait screen has to carry it: the reconnect shell is withheld
              # while an update runs, and the shell underneath is inert. Together they are why the
              # gate above computes true in that window with nothing else on screen to answer it.
              ("the reconnect shell is withheld while an update runs",
               r"\): Boolean = shellEstablished && hadLink && state == ConnState\.CONNECTING"
               r" && !otaActive"),
              ("and the parked shell is neither tappable nor readable",
               r"if \(shellCovered\) \{\n\s*Modifier\n\s*\.clearAndSetSemantics \{ \}\n"
               r"\s*\.pointerInput\(Unit\)"),
              ("with no take of its own", r"takePendingAlertModeRestore", 0))),
            # DURABILITY. The offer is the app's own silence, so it has to outlive the process that
            # imposed it: a key of its own beside the pre-Desert mode, and a republish at launch.
            # Without both, a force-quit leaves alerts silent with no offer, no notice and no saved
            # mode (arming CONSUMES the saved half) - the exact hole the offer was built to close.
            ("iOS durable offer", IOS_BLE_MANAGER, None,
             (("the offer has a key of its own",
               r'private let pendingAlertModeRestoreKey = "acab\.pendingAlertModeRestore"'),
              ("and launch republishes it",
               r"pendingAlertModeRestore = desertAlertModeStateFromStorage\("
               r"storedDesertAlertModeState\)\.offered"))),
            ("Android durable offer", AND_BLE_MANAGER, None,
             (("the offer has a key of its own",
               r'internal const val PREF_PENDING_ALERT_MODE_RESTORE = "pending_alert_mode_restore"'),
              ("and construction republishes it",
               r"MutableStateFlow\(\n\s*desertAlertModeStateFromStorage\("
               r"storedDesertAlertModeState\(\)\)\.offered,"))),
            ("bundled FAQ (iOS copy)", IOS_FAQ, None, _FAQ_DESERT_PROMISES),
            ("bundled FAQ (Android copy)", AND_FAQ, None, _FAQ_DESERT_PROMISES),
        ),
    },
    {
        "what": "Log seed positions one axis and resets the rest",
        # NOT the no-match panel: it renders only when the shown list is empty (iOS draws it under
        # `snap.shown.isEmpty`), and a stale search or category usually leaves a POPULATED list
        # that silently lacks the promised rows. A surviving sort hides nothing at all, it buries.
        # The iOS seedLens doc says it that way. This line is what gets printed to whoever has to
        # fix the side that failed, so it has to send them somewhere real.
        "why": "a Status tile or a NEW deep link promises rows; a surviving search or frozen"
               " snapshot on one phone would leave them out of the list, and a surviving sort"
               " would bury them",
        "sides": (
            ("iOS seedLens", IOS_DETECTIONS_VIEW,
             r"private func seedLens\(scope newScope: StatusScope, category: String\?\) \{(.*?)\n    \}",
             (("category axis", r"\bfilter = category\b"),
              ("scope axis", r"\bscope = newScope\b"),
              ("sort back to newest", r"\bsortOrder = \.newest\b"),
              ("search cleared", r'\bsearchText = ""'),
              ("paused feed resumed", r"\bresumeFeed\(\)"),
              # A seed ends select mode and closes the dossier for the same reason it clears the
              # search: what the last visit left behind now points at rows the user never picked.
              # A carried-in selection aims MUTE N at a list whose contents just changed under the
              # checkboxes, and at regular width the open pane holds a dossier the seeded lens does
              # not list. iOS writes all three here.
              ("select mode ended", r"\bselecting = false\b"),
              ("selection cleared", r"\bselection\.removeAll\(\)"),
              ("dossier closed", r"\bselectedDetail = nil\b"))),
            ("Android LogScreen defaults", AND_LOG_SCREEN, None,
             (("category axis seeds from the filter",
               r"mutableStateOf\(\(initialFilter as\? LogFilter\.Category\)\?\.key\)"),
              ("search starts empty",
               r'var searchQuery by rememberSaveable \{ mutableStateOf\(""\) \}'),
              ("sort starts at Newest",
               r"var sort by rememberSaveable \{ mutableStateOf\(LogSort\.Newest\) \}"))),
            # Android reaches the first two iOS resets structurally instead of writing them:
            # selectMode and selected are plain `remember` state INSIDE LogScreen, which sits in
            # key(logScreenKey), so each seed's logScreenKey++ rebuilds them at their defaults. The
            # open dossier is the one that survives that, because the selection lives in MainScreen
            # outside the key, so it is the write each seed has to make and the one pinned here.
            ("Android MainScreen tile seed", AND_MAIN_SCREEN,
             r"val openLogCategory: \(String\) -> Unit = \{ key ->(.*?)\n    \}",
             (("re-keys LogScreen", r"\blogScreenKey\+\+"),
              ("resumes a paused feed", r"\blogPauseVm\.resume\(\)"),
              ("closes the dossier", r"setSelected\(null\)"))),
            ("Android MainScreen NEW deep link", AND_MAIN_SCREEN,
             r"LaunchedEffect\(openLogNew\) \{(.*?)\n    \}",
             (("re-keys LogScreen", r"\blogScreenKey\+\+"),
              ("resumes a paused feed", r"\blogPauseVm\.resume\(\)"),
              ("closes the dossier", r"setSelected\(null\)"))),
        ),
    },
    {
        "what": "checkpoint observer pin (a pair only with its peak; drone never from the wire;"
                " in-window age ranks; a stale age floors only a replayed row)",
        "why": "a stale board fix the live ingest refused came back from a checkpoint as the"
               " strongest observer pin. The window and floor literals are pinned above; this pins"
               " the routing, the live versus replayed split, that a persisted peak is clamped to"
               " int16 on both phones before it ranks, and that each restore writes the helper's"
               " coordinate and the helper's peak and nothing else",
        "sides": (
            ("iOS helper", IOS_BLE_MANAGER,
             r"func checkpointObserverPin\(type: DeviceType,(.*?)\n\}",
             (("a pair restores only with its peak", r"if let peak, let pairLat, let pairLon,"),
              ("the pair ranks at its own peak", r"\? \(pair, peak\) : nil"),
              ("a persisted peak is clamped to int16 before it ranks",
               r"let peak = min\(32_767, max\(-32_768, peak\)\)"),
              ("a drone row never seeds from the wire", r"guard type != \.drone, let wire"),
              ("in-window age ranks on the row's RSSI",
               r"case \.ranked:(?:(?!case \.floor:)[\s\S])*?candidateRSSI: rssi\)"),
              ("a stale age floors only a replayed row",
               r"case \.floor:\s*\n\s*guard replayed else \{ return nil \}\s*\n\s*"
               r"return staleObserverPinFill\("))),
            ("iOS restore", IOS_BLE_MANAGER,
             r"private func restoreObserverPin\(from row: StoredRow\) \{(.*?)\n    \}",
             (("the helper decides", r"checkpointObserverPin\("),
              ("the peak is the row's own saved peak", r"peak: row\.bestRssi,"),
              ("the replay flag is the one the map gate reads", r"replayed: d\.isHistory,"),
              # The writes below are only as good as what the helper was ASKED. Feeding it a
              # different age or a different pair reproduces the same defect with every write
              # still verbatim, so the inputs the decision turns on are pinned beside them: the
              # live-versus-stale gate reads gpsAgeSec, the ranked arm reads the wire fix and
              # ranks it at the row's own rssi, and the row's own stored pair is judged twice
              # (hence 2), once by the pin helper and once by the keep rule below. BOTH halves of
              # that pair, because a pair is a coordinate: a latitude out of the checkpoint
              # crossed with a longitude off the row is a point nobody ever stood at, and it still
              # passes the validity check, still ranks, and still reaches the map pin, the dossier
              # LOCATION panel and the exported approx_lat and approx_lon. The pin and peak
              # already held are pinned for the same reason: hand the helper nil there and a
              # restore stops having to outrank what the session holds. The rssi is what the
              # ranked arm weighs against that held peak: hand it the row's all-time peak instead
              # and every relaunch re-pins the capture-era fix at a value no later live sighting
              # can outrank. The type is what the helper's drone guard reads, and a drone's wire
              # fix is the aircraft's own broadcast GPS, so a drone row seeded from it says the
              # sighting was observed where the aircraft was flying. Both land on the map pin, in
              # the dossier LOCATION panel and in the exported approx_lat and approx_lon, so the
              # Android load below pins the same two arguments.
              ("the age the live-fix gate reads is the row's own", r"gpsAgeSec: d\.gpsAgeSec,"),
              ("the wire fix is the row's own", r"wire: d\.coordinate,"),
              ("the candidate RSSI is the row's own", r"rssi: d\.rssi,"),
              ("the type the drone guard reads is the row's own", r"type: d\.type,"),
              ("both arms judge the row's own stored pair", r"pairLat: row\.lat,", 2),
              ("and both halves of that pair", r"pairLon: row\.lon,", 2),
              ("the pin already held is what a restore has to outrank",
               r"existingCoordinate: capturedLoc\[d\.id\], existingRSSI: bestRssi\[d\.id\]\)"),
              # The two writes are pinned AS WRITTEN, not merely counted. A count alone passed
              # `bestRssi[d.id] = d.rssi` (the row's RSSI in place of the helper's peak, which is
              # a floor-restored stale fix outranking every later live sighting) and
              # `capturedLoc[d.id] = d.coordinate ?? pin.coordinate` (the wire fix in place of the
              # pin). The counts stay beside them, so a SECOND write anywhere in the body is drift.
              ("the restore writes the helper's coordinate",
               r"capturedLoc\[d\.id\] = pin\.coordinate$"),
              ("the restore writes the helper's peak", r"bestRssi\[d\.id\] = pin\.rssi$"),
              ("and writes no other pin",
               r"capturedLoc\[[^\]]+\] =(?!=)|consider\w*ObserverPin\("),
              ("and writes no other peak", r"bestRssi\[[^\]]+\] =(?!=)"),
              # iOS only, and load-bearing: without this line the shipped peakless pair the helper
              # refuses is erased at the next checkpoint instead of kept for the standard export.
              # Its two arguments are pinned for the same reason the pin helper's are: passing nil
              # for the row's kept fields, or claiming the pair has no peak, loses or invents a
              # pair while this call site still reads correctly. The last needle counts the map
              # writes at 1, so a restore can only ADD a pair here, never clear one already held.
              ("a refused shipped pair is kept", r"legacyObserverPairToKeep\("),
              ("a pair carrying a peak belongs to the paired arm, not to the keep rule",
               r"pairHasPeak: row\.bestRssi != nil,"),
              ("a pair already preserved beside a pin comes back from the row's kept fields",
               r"keptLat: row\.keptLat, keptLon: row\.keptLon\)"),
              ("and the kept pair is stored", r"legacyObserverPair\[d\.id\] = kept$"),
              ("and nothing else here touches the kept pair", r"legacyObserverPair\[", 1))),
            ("Android helper", AND_BLE_MANAGER, r"internal fun checkpointObserverPin\((.*?)\n\}",
             (("a pair restores only with its peak",
               r"if \(pairPeak != null && validCoord\(pairLat, pairLon\)\)"),
              ("the pair ranks at its own peak",
               r"selectStrongestLocatedSample\(current, pairLat!! to pairLon!!, peak\)"),
              ("a persisted peak is clamped to int16 before it ranks",
               r"pairPeak\.coerceIn\(Short\.MIN_VALUE\.toInt\(\), Short\.MAX_VALUE\.toInt\(\)\)"),
              ("a drone row never seeds from the wire", r"type == DeviceType\.DRONE"),
              ("in-window age ranks on the row's RSSI",
               r"ReplayPinContest\.RANKED -> selectStrongestLocatedSample\(current, coord, rssi\)"),
              ("a stale age floors only a replayed row",
               r"ReplayPinContest\.FLOOR -> if \(replayed\) staleLocatedPinFill\("))),
            ("Android load", AND_BLE_MANAGER,
             r"private suspend fun loadPersistedDetections\(\) \{(.*?)\n    \}",
             (("the helper decides", r"checkpointObserverPin\("),
              ("the replay flag is the persisted offline flag", r"replayed = d\.offline,"),
              # Same reason as the iOS restore above, and this is the side with no test behind it
              # at all: the pin the map draws, the dossier LOCATION panel and the exported
              # approx_lat / approx_lon all come out of this one call. A null age reads as a live
              # fix in liveWireCoordinateIsFresh, so every capture-era fix would rank instead of
              # being refused or floored, and a pair taken from the row's own coordinate turns
              # that coordinate into its own rival pin. HALF a pair does the same damage: a
              # latitude out of the checkpoint crossed with a longitude off the row passes
              # validCoord and ranks as a located sample, so the relaunch pins a coordinate that
              # never existed, on the map, in the dossier and in the exported approx_lat and
              # approx_lon. Both halves are pinned, here and on the iOS restore above. The type
              # rides with them: it is the argument the helper's drone guard reads, and a drone's
              # wire fix is the aircraft's own broadcast GPS rather than an observer position, so
              # a drone row seeded from it pins the sighting where the aircraft was flying.
              ("the age the live-fix gate reads is the row's own", r"gpsAgeSec = d\.gpsAgeSec,"),
              ("the wire fix is the row's own", r"lat = d\.lat,"),
              ("both halves of it", r"lon = d\.lon,"),
              ("the candidate RSSI is the row's own", r"rssi = d\.rssi,"),
              ("the type the drone guard reads is the row's own", r"^\s*d\.type,$"),
              ("the pair is the persisted pair", r'pairLat = o\.optDouble\("_clat"'),
              ("and both halves of the pair are persisted", r'pairLon = o\.optDouble\("_clon"'),
              ("and it ranks at its persisted peak", r'pairPeak = if \(o\.has\("_crssi"\)\)'),
              ("the pin already held is what a load has to outrank",
               r"existingCoord = capturedLoc\[d\.id\],"),
              ("and the peak already held rides with it", r"existingRssi = bestRssi\[d\.id\],"),
              # Pinned as written, for the reason spelled out on the iOS restore above.
              ("the load writes the helper's coordinate", r"capturedLoc\[d\.id\] = it\.coord$"),
              ("the load writes the helper's peak", r"bestRssi\[d\.id\] = it\.rssi$"),
              ("and writes no other pin",
               r"capturedLoc\[[^\]]+\] =(?!=)|consider\w*LocatedSample\("),
              ("and writes no other peak", r"bestRssi\[[^\]]+\] =(?!=)"))),
        ),
    },
    {
        "what": "Status link facts and pill order (sample, reconnect, update reboot, first frame,"
                " update, radio fault, connected)",
        "why": "the Status header pill and the scan kicker rank the same link facts on both"
               " phones: the board's own update reboot reads UPDATING and claims no radio line,"
               " and a first-frame gap outside that window reads WAITING; iOS reaches the word"
               " through the connection label its presenter picks",
        # The update-reboot arm is a twin on BOTH phones since 2026-09-11 (iOS isRebootingForUpdate,
        # Android rebootingForUpdate fed by otaPhaseIsUpdateReboot), so the Android needles below pin
        # it in its slot between the reconnect and the first-frame guard, in the pill AND in the
        # kicker. The kicker order is pinned too because the two Android presenters rank the same
        # facts separately: with only the pill pinned, a kicker that promoted the coordinator's flag
        # above the missing frame read UPDATING FIRMWARE · DETECTION MAY PAUSE under a WAITING pill,
        # where iOS reads CONNECTED · WAITING FOR BOARD STATUS.
        "sides": (
            ("Android pill", AND_STATUS_SCREEN, r"internal fun statusLinkChipLabel\((.*?)\n\}",
             (("the arms in the shared order",
               r'demo -> null\s*\n\s*reconnecting -> "RECONNECTING"\s*\n\s*'
               r'rebootingForUpdate -> "UPDATING"\s*\n\s*!hasStatus -> "WAITING"'
               r'\s*\n\s*firmwareUpdateRunning \|\| bleUpdating -> "UPDATING"\s*\n\s*'
               r'bleFault -> "RADIO FAULT"\s*\n\s*else -> "CONNECTED"'),)),
            ("Android Status header", AND_STATUS_SCREEN, None,
             (("the header computes the pill with it", r"val linkStateLabel = statusLinkChipLabel\("),
              ("the header draws that word", r"\bstateLabel = linkStateLabel\b"),
              # Both presenters can only rank a fact they are GIVEN, and both take it as a named
              # argument, so `rebootingForUpdate = false` at either call site compiles, keeps every
              # needle above matching, and drops the arm for the whole reboot-to-confirm window:
              # the screen then reads WAITING while rollback is still armed. Hence both call sites
              # (the scan kicker's and the pill's), and the flow the value is collected from.
              ("both presenters are handed the update reboot",
               r"rebootingForUpdate = rebootingForUpdate,", 2),
              ("and the fact is the OTA engine's own reboot window",
               r"ble\.otaProgress\.map \{ otaPhaseIsUpdateReboot\(it\.phase\) \}"))),
            ("Android scan kicker", AND_STATUS_SCREEN,
             r"internal fun statusScanPresentation\((.*?)\n\}",
             (("the two link facts compose one frameSpeaks gate",
               r"val frameSpeaks = !reconnecting && !rebootingForUpdate && hasStatus"),
              # The definition alone promises nothing: what keeps a radio line from being claimed
              # through a link fact is that every flag is gated on it. Re-gate one on hasStatus
              # and the radar sweeps through the CONFIRMING half of an update reboot, where a
              # frame IS in hand and rebootingForUpdate is still true, under a label that says
              # detection may pause, while iOS parks its beam for the same state. So bind all four.
              ("the co-processor update flag is claimed through it",
               r"val bleUpdating = frameSpeaks &&"),
              ("the listening flag is claimed through it", r"val bleListening = frameSpeaks &&"),
              ("the radio fault flag is claimed through it", r"val bleFault = frameSpeaks &&"),
              ("the Wi-Fi flag is claimed through it", r"val wifiUp = frameSpeaks &&"),
              # One regex over the arms in order (see _KT_ARM_GAP), which is what makes an arm
              # MOVED past another fail here. The iOS side reaches the same order by returning
              # early, arm by arm, which its own needles below pin pair by pair.
              ("the link facts, then the board's update bit, then the coordinator",
               r'reconnecting -> "RECONNECTING · BOARD STATUS UNAVAILABLE"' + _KT_ARM_GAP
               + r'rebootingForUpdate -> "UPDATING FIRMWARE · DETECTION MAY PAUSE"' + _KT_ARM_GAP
               + r'!hasStatus -> "CONNECTED · WAITING FOR BOARD STATUS"' + _KT_ARM_GAP
               + r'bleUpdating && wifiUp -> "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR"'
               + _KT_ARM_GAP + r'bleUpdating -> "UPDATING CO-PROCESSOR · NOT SCANNING"'
               + _KT_ARM_GAP
               + r'genericFirmwareUpdate -> "UPDATING FIRMWARE · DETECTION MAY PAUSE"'))),
            ("iOS presenter", IOS_BEACON_PRESENTATION,
             r"func beaconRadioPresentation\(connectionState: BLEConnectionState,(.*?)\n\}",
             (("sample mode before the reconnect", r"if isDemoMode \{[\s\S]*?\n    if isReconnecting \{"),
              ("the reconnect before the first-frame guard",
               r'if isReconnecting \{\s*return BeaconRadioPresentation\(\s*connectionLabel: "RECONNECTING"'
               r'[\s\S]*?guard let status else \{\s*return BeaconRadioPresentation\(\s*'
               r'connectionLabel: "CONNECTED · WAITING FOR STATUS"'),
              ("the first-frame guard before the board's update bit",
               r'guard let status else \{[\s\S]*?if status\.nrfUpdating == true \{\s*if status\.wifi \{'
               r'\s*return BeaconRadioPresentation\(\s*connectionLabel: "CONNECTED · UPDATING"'),
              ("the update bit before the coordinator",
               r'if status\.nrfUpdating == true \{[\s\S]*?if combinedUpdateRunning \{\s*'
               r'return BeaconRadioPresentation\(\s*connectionLabel: "UPDATING FIRMWARE"'),
              ("the coordinator before the radio fault",
               r'if combinedUpdateRunning \{[\s\S]*?connectionLabel: "CONNECTED · RADIO FAULT"'),
              # iOS writes two of these pill facts TWICE, once per Wi-Fi state, and the ordering
              # needles above bind only the first copy of each: the nrfup pair binds the Wi-Fi-on
              # return, and the fault needle's lazy span binds whichever fault arm still carries
              # the label. So bind the second copy of each to its own case. Without these three,
              # the Wi-Fi-off co-processor update or one Wi-Fi state of a BLE radio fault could
              # lose its word and read CONNECTED while Android read UPDATING or RADIO FAULT.
              ("the Wi-Fi-off co-processor update keeps the update word",
               r'return BeaconRadioPresentation\(\s*connectionLabel: "CONNECTED · UPDATING",\s*'
               r'scanLabel: "UPDATING CO-PROCESSOR'),
              ("the Wi-Fi-on fault arm keeps the fault word",
               r'case \(false, true\) where bluetoothFault:\s*return BeaconRadioPresentation\(\s*'
               r'connectionLabel: "CONNECTED · RADIO FAULT"'),
              ("the Wi-Fi-off fault arm keeps the fault word",
               r'case \(false, false\) where bluetoothFault:\s*return BeaconRadioPresentation\(\s*'
               r'connectionLabel: "CONNECTED · RADIO FAULT"'))),
            ("iOS pill words", IOS_BEACON_PRESENTATION, r"var chipLabel: String \{(.*?)\n    \}",
             (("sample mode", r'case "SAMPLE DATA":\s*return "DEMO"'),
              ("reconnect", r'case "RECONNECTING":\s*return "RECONNECTING"'),
              ("first frame", r'case "CONNECTED · WAITING FOR STATUS":\s*return "WAITING"'),
              ("either update label",
               r'case "CONNECTED · UPDATING", "UPDATING FIRMWARE":\s*return "UPDATING"'),
              ("radio fault", r'case "CONNECTED · RADIO FAULT":\s*return "RADIO FAULT"'),
              ("connected", r'case "CONNECTED OVER BLE":\s*return "CONNECTED"'))),
            ("iOS Status header", IOS_DASHBOARD_VIEW, None,
             (("the header draws chipLabel", r"\bstateLabel: radioPresentation\.chipLabel\b"),
              # beaconRadioPresentation DEFAULTS isRebootingForUpdate to false, so a view that
              # stops passing it still compiles and simply loses the arm. The presenter's own doc
              # comment names this view and the Beacon tab below as the two that must pass it;
              # these two needles are that sentence made checkable.
              ("and its presenter is handed the app's update reboot",
               r"isRebootingForUpdate: ble\.isRebootingForUpdate\)"))),
            ("iOS Beacon tab header", IOS_SETTINGS, None,
             (("its presenter is handed the app's update reboot",
               r"isRebootingForUpdate: ble\.isRebootingForUpdate\)"),)),
            # The Android twin of the side above, and the fourth surface that ranks this fact. TWO
            # presenters on this one tab take it: beaconConnectionPresentation feeds the header
            # kicker and the hero, beaconRadioStatusLabel feeds the Scan radios row. Both take it
            # as a named Boolean with a default, so `rebootingForUpdate = false` at either call
            # site compiles and drops the arm on that surface alone, leaving this tab reading
            # CONNECTED · WAITING FOR BOARD STATUS through a reboot the iPhone names. Hence 2.
            # Those two counts say the fact ARRIVES, not that anything ranks it. Nothing else
            # holds beaconConnectionPresentation's reboot arm: every call to it under
            # android/app/src/test passes four positional arguments or names only demo,
            # reconnecting, state and hasStatus, so rebootingForUpdate takes its false default
            # everywhere and the arm is never entered. Deleting it, or rewording its two lines,
            # would leave both presentation suites green while the top of this tab read CONNECTED
            # · WAITING FOR BOARD STATUS for the whole reboot-to-confirm window. So the third
            # needle pins the arm as written and in its slot above the missing-frame arm, which is
            # where beaconRadioStatusLabel and statusScanPresentation rank the same fact.
            ("Android Beacon tab header", AND_DEVICE_SCREEN, None,
             (("both presenters on the tab are handed the update reboot",
               r"rebootingForUpdate = rebootingForUpdate,", 2),
              ("and the fact is the OTA engine's own reboot window",
               r"ble\.otaProgress\.map \{ otaPhaseIsUpdateReboot\(it\.phase\) \}"),
              ("the tab's own reboot arm, above the missing frame",
               r"rebootingForUpdate -> BeaconConnectionPresentation\(\s*\n\s*"
               r'"UPDATING FIRMWARE · DETECTION MAY PAUSE",\s*\n\s*'
               r'"UPDATING FIRMWARE · detection may pause",[\s\S]*?'
               r"!hasStatus -> BeaconConnectionPresentation\(\s*\n\s*"
               r'"CONNECTED · WAITING FOR BOARD STATUS",'))),
        ),
    },
    {
        "what": "radar spoken label is singular at exactly one (devices and dots)",
        "why": "a screen reader hears '1 dot drawn' and '2 dots drawn' on both phones; the plural"
               " rule is a condition and two literals the fragment row above cannot see",
        "sides": (
            ("iOS RadarScope", IOS_COMPONENTS,
             r'\.accessibilityLabel\(("\\\(count\) recently heard device.*?not direction\.")\)',
             (("device, devices", r'device\\\(count == 1 \? "" : "s"\) nearby'),
              ("dot, dots", r'dot\\\(dots\.count == 1 \? "" : "s"\) drawn'))),
            ("Android radar", AND_STATUS_SCREEN,
             r'(val radarContentDescription: String\s*\n\s*get\(\) = .*?not direction\.")',
             (("device, devices", r'device\$\{if \(total == 1\) "" else "s"\} nearby'),
              ("dot, dots", r'dot\$\{if \(dots\.size == 1\) "" else "s"\} drawn'))),
        ),
    },
    {
        "what": "no-GPS drone ring radius (pow(10, (-50 - rssi) / 25), clamped to 5 to 600 m)",
        "why": "both maps draw a drone with no GPS fix as a ring around the observer, sized by this"
               " estimate; a different formula or clamp on one phone draws the same reading nearer"
               " or farther",
        "sides": (
            ("iOS", IOS_MAP_TAB,
             r"private func rssiRadiusMeters\(_ rssi: Int\) -> Double \{(.*?)\n    \}",
             (("the path-loss formula", r"pow\(10\.0, \(-50\.0 - Double\(rssi\)\) / 25\.0\)"),
              ("the 5 to 600 m clamp", r"min\(max\(d, 5\), 600\)"))),
            ("Android", AND_MAP_SCREEN, r"private fun rssiRadiusMeters\(rssi: Int\): Double =(\s*[^\n]*)",
             (("the formula and the 5 to 600 m clamp",
               r"Math\.pow\(10\.0, \(-50\.0 - rssi\) / 25\.0\)\.coerceIn\(5\.0, 600\.0\)"),)),
        ),
    },
    {
        "what": "same-spot member order (priority, then most recent with undated last, then"
                " arrival order)",
        "why": "which member a shared pin draws as and the order its member list shows; the"
               " priority table itself is pinned below",
        "sides": (
            ("iOS", IOS_MAP_TAB, r"static func ordered<T>\((.*?)\n    \}",
             (("ranks by priority", r"p: priority\(type\(\$0\.element\)\)"),
              ("an undated member sorts as the oldest",
               r"\(lastSeen\(\$0\.element\) \?\? \.distantPast\)"),
              ("priority ascending first", r"if \$0\.p != \$1\.p \{ return \$0\.p < \$1\.p \}"),
              ("then most recent first", r"if \$0\.t != \$1\.t \{ return \$0\.t > \$1\.t \}"),
              ("then arrival order", r"return \$0\.i < \$1\.i"))),
            ("Android comparator", AND_MAP_PROJECTION, r"internal fun <T> sameSpotOrder\((.*?)\n\n",
             (("priority, then most recent, undated as the oldest",
               r"compareBy<T> \{ infraPinPriority\(typeOf\(it\)\) \}\.thenByDescending "
               r"\{ lastSeenOf\(it\) \?: Long\.MIN_VALUE \}"),)),
            # Kotlin's sortedWith is a stable sort, which is what supplies arrival order on a tie.
            ("Android draw loop", AND_MAP_PROJECTION, r"internal fun orderSameSpotMembers\((.*?)\n\n",
             (("a stable sort keeps arrival order on a tie",
               r"members\.sortedWith\(sameSpotOrder\(\{ it\.type \}, \{ lastSeenOf\(it\.id\) \}\)\)"),)),
        ),
    },
    {
        "what": "dossier time labels (ago: now under 5 s, then s, m, h, d; span: floored at 1 s)",
        "why": "the dossier's ago labels and CONFIRM IT's sighting span name the same bucket at"
               " the same age on both phones, and the dossier measures every one of them against"
               " its own 1 s tick: a call that reads the wall clock instead freezes at the last"
               " composition, so the screen holds SIGNAL · LIVE and a stale age at exactly the"
               " moment someone is checking whether a device really went quiet",
        "sides": (
            ("iOS ago", IOS_DETECTION_DETAIL,
             r"func dossierRelativeAgo\(_ date: Date\?, now: Date\) -> String \{(.*?)\n\}",
             (("no stamp reads '-'", r'guard let date else \{ return "-" \}'),
              ("a future stamp reads as now", r"let secs = max\(0, "),
              ("under 5 s", r'case \.\.<5:\s*return "now"'),
              ("seconds", r'case \.\.<60:\s*return "\\\(secs\)s ago"'),
              ("minutes", r'case \.\.<3600:\s*return "\\\(secs / 60\)m ago"'),
              ("hours", r'case \.\.<86_400:\s*return "\\\(secs / 3600\)h ago"'),
              ("days", r'default:\s*return "\\\(secs / 86_400\)d ago"'))),
            ("iOS span", IOS_DETECTION_DETAIL,
             r"func dossierSightingSpan\(since first: Date, now: Date\) -> String \{(.*?)\n\}",
             (("floored at 1 s", r"let secs = max\(1, "),
              ("seconds", r'case \.\.<60:\s*return "\\\(secs\)s"'),
              ("minutes", r'case \.\.<3600:\s*return "\\\(secs / 60\)m"'),
              ("hours", r'case \.\.<86_400:\s*return "\\\(secs / 3600\)h"'),
              ("days", r'default:\s*return "\\\(secs / 86_400\)d"'))),
            ("Android ago", AND_DETAIL_SCREEN,
             r"internal fun relativeAgo\(ms: Long\?, nowMs: Long(?: = [^\n{]*)?\): String \{(.*?)\n\}",
             (("no stamp reads '-'", r'if \(ms == null\) return "-"'),
              ("a future stamp reads as now", r"\.coerceAtLeast\(0\)"),
              ("under 5 s", r'secs < 5 -> "now"'),
              ("seconds", r'secs < 60 -> "\$\{secs\}s ago"'),
              ("minutes", r'secs < 3600 -> "\$\{secs / 60\}m ago"'),
              ("hours", r'secs < 86_400 -> "\$\{secs / 3600\}h ago"'),
              ("days", r'else -> "\$\{secs / 86_400\}d ago"'))),
            ("Android span", AND_DETAIL_SCREEN,
             r"internal fun seenSpan\(ms: Long\?, nowMs: Long\): String\? \{(.*?)\n\}",
             (("floored at 1 s", r"\.coerceAtLeast\(1\)"),
              ("seconds", r'secs < 60 -> "\$\{secs\}s"'),
              ("minutes", r'secs < 3600 -> "\$\{secs / 60\}m"'),
              ("hours", r'secs < 86_400 -> "\$\{secs / 3600\}h"'),
              ("days", r'else -> "\$\{secs / 86_400\}d"'))),
            # The bodies above are pure, so they can only go wrong at the CALL. Both screens keep a
            # 1 s tick and hand it to every clock-derived reading; the 2026-09-10 freeze was a call
            # reading the clock itself, which is invisible to the two suites and to the bodies here.
            # Pinned per call site, because each is one line and each can regress alone.
            ("iOS dossier call sites", IOS_DETECTION_DETAIL, None,
             (("the screen keeps a 1 s tick", r"@State private var now = Date\(\)"),
              # A DECLARED tick is not a tick. Drop the line that advances it (it sits directly
              # under followTick's own onReceive, so it reads as a duplicate of one) or slow its
              # publisher down, and every reading still measures against a variable that no longer
              # moves, which is exactly the 2026-09-10 freeze: the kicker holds SIGNAL · LIVE and
              # the age holds still. Neither suite sees it, because both call the pure bodies with
              # an explicit `now`.
              ("the tick's publisher fires once a second",
               r"@State private var staleTick = Timer\.publish\(every: 1, on: \.main, in: \.common\)"
               r"\.autoconnect\(\)"),
              ("and the screen advances the tick on it",
               r"\.onReceive\(staleTick\) \{ now = \$0 \}"),
              ("the ago delegate measures against the tick",
               r"private func relativeAgo\(_ date: Date\?\) -> String"
               r" \{ dossierRelativeAgo\(date, now: now\) \}"),
              ("CONFIRM IT's span measures against the tick",
               r"dossierSightingSpan\(since: first, now: now\)"),
              ("the LIVE/STALE kicker measures against the tick",
               r"ble\.isStale\(for: d\.id, asOf: now\)"))),
            # Android's relativeAgo keeps a wall-clock DEFAULT for MapScreen checkedAgo, so a
            # dossier call that drops `nowMs` still compiles and still reads. Hence the pair of
            # counts: five calls carrying the tick, and six spellings of the name in the file
            # (those five plus the definition). Dropping the tick from one call moves the first
            # number; adding a sixth call without it moves the second. A call whose argument is
            # itself a call needs the inner pattern widened, and says so by failing.
            ("Android dossier call sites", AND_DETAIL_SCREEN, None,
             (("the screen keeps a 1 s tick",
               r"var nowMs by remember \{ mutableLongStateOf\(System\.currentTimeMillis\(\)\) \}"),
              # The twin of the iOS pair above, and the same freeze: the declaration keeps `nowMs`
              # readable, so deleting the loop or stretching its delay leaves every needle below
              # matching while nothing moves. One regex, so the loop, its cadence and the
              # assignment cannot be pinned apart from each other.
              ("and advances it once a second",
               r"LaunchedEffect\(Unit\) \{" + _KT_ARM_GAP + r"while \(true\) \{" + _KT_ARM_GAP
               + r"delay\(1_000\)" + _KT_ARM_GAP + r"nowMs = System\.currentTimeMillis\(\)"),
              ("every ago call passes the tick",
               r"relativeAgo\((?:[^()]|\([^()]*\))*, nowMs\)", 5),
              ("and no ago call site is missing from that count", r"\brelativeAgo\(", 6),
              ("CONFIRM IT's span measures against the tick", r"seenSpan\(firstSeen, nowMs\)"),
              ("the LIVE/STALE kicker measures against the tick",
               r"ble\.isStale\(d\.id, nowMs = nowMs\)"))),
        ),
    },
    {
        "what": "dossier shape (one panel order; COPY MAC outside Technical details; the capture"
                " note closes MATCH QUALITY)",
        "why": "docs/app-guide.md names dossier panels by where they sit (Related help and the"
               " map near the top, Technical details further down), so a panel that moves on one"
               " phone makes that sentence false on the other. COPY MAC ADDRESS is the sharp one:"
               " an address is what gets handed to a reporter or a records request, so it may not"
               " sit behind a collapsed section on either phone",
        # iOS owns the order (its body carries the canonical list and says so), so its needles pin
        # the sequence and the Android ones pin that the three panels settled on 2026-09-11 stayed
        # where they were put: COPY MAC out of the disclosure, CONFIRM IT after the stat grid, and
        # the firmware's capture note folded into MATCH QUALITY with its own panel deleted.
        "sides": (
            ("iOS body", IOS_DETECTION_DETAIL, r"var body: some View \{(.*?)\n    \}",
             (# This span runs THROUGH the Related help joint on purpose. The three spans used to
              # stop at relatedHelpPanel and pick up again at the location panel, which left that
              # one seam unpinned on the side this rule calls canonical, and the seam is where a
              # new panel naturally lands: directly under the help block and above the map. The
              # Android twin needle ("Related help, then location") already covers the same joint.
              ("match quality, the experimental note, Related help, then location",
               r"matchQualityPanel" + _KT_ARM_GAP
               + r"if d\.type\.isExperimental \{ experimentalNote \}" + _KT_ARM_GAP
               + r"relatedHelpPanel" + _KT_ARM_GAP
               + r"if let coord = mapCoordinate \{ locationPanel\(coord\) \}"),
              ("location, follow, signal, then the stat grid",
               r"if let coord = mapCoordinate \{ locationPanel\(coord\) \}" + _KT_ARM_GAP
               + r"followPanel" + _KT_ARM_GAP + r"signalPanel" + _KT_ARM_GAP + r"statGrid"),
              ("CONFIRM IT after the stat grid, then Technical details, then COPY MAC last",
               r"statGrid" + _KT_ARM_GAP + r"if showConfirmIt \{ confirmItPanel \}" + _KT_ARM_GAP
               + r"identityDisclosure" + _KT_ARM_GAP + r"copyButton"))),
            ("iOS Technical details", IOS_DETECTION_DETAIL,
             r"private var identityDisclosure: some View \{(.*?)\n    \}",
             (("COPY MAC is not inside the disclosure", r"copyButton", 0),)),
            ("iOS match quality", IOS_DETECTION_DETAIL,
             r"private var matchQualityPanel: some View \{(.*?)\n    \}",
             (("the panel's kicker", r'Kicker\("MATCH QUALITY"\)'),
              ("closes with the capture note verbatim",
               r"if let detail = d\.detail, !detail\.isEmpty \{\s*\n\s*Text\(detail\)"),
              ("and that note gets no kicker of its own", r'Kicker\("CAPTURE NOTE"\)', 0))),
            # The second render is deliberate on both phones (recorded in round 1): the same string
            # is also a row in Technical details, so a reader who expands the raw fields finds it
            # there too. Pinned so a later tidy-up cannot read one of the two as a duplicate.
            ("iOS Detail row", IOS_DETECTION_DETAIL, None,
             (("the capture note renders again as the Detail row",
               r'if let det = d\.detail, !det\.isEmpty \{ idRow\("Detail", det\) \}'),)),
            # `(?:(?!Panel\()[\s\S])*?` is _KT_ARM_GAP's idea over a body whose panels are
            # separated by real code rather than comments: the span may cross anything EXCEPT
            # another panel call, so a panel inserted between the two named ones fails here.
            ("Android body", AND_DETAIL_SCREEN, None,
             (("match quality, the experimental note, then Related help",
               r"MatchQualityPanel\(d\)" + _KT_ARM_GAP
               + r"if \(d\.type\.isExperimental\) ExperimentalNote\(d\.type\)" + _KT_ARM_GAP
               + r"RelatedHelpPanel\(d\)"),
              ("Related help, then location",
               r"RelatedHelpPanel\(d\)(?:(?!Panel\()[\s\S])*?LocationPanel\(d, lat, lon"),
              ("location, then follow",
               r"LocationPanel\(d, lat, lon, breadcrumbTrail, onOpenInMap\)\s*\n\s*\}\s*\n\s*"
               r"if \(d\.type == DeviceType\.TRACKER\) FollowEvidencePanel\("),
              # The kicker literal in the middle is what makes this needle's NAME true. Android's
              # signal section is an inline Column, not a `*Panel(` call, so the panel-gap span
              # alone said only that no OTHER panel sits between follow and the stat grid: with
              # the whole signal block deleted, kicker, RSSI number, band and history graph, it
              # still matched. The kicker is that section's own first line, so it binds the slot.
              ("follow and the signal panel, then the stat grid",
               r"FollowEvidencePanel\(d\.id, d\.type, ble, timeBasis\)"
               r"(?:(?!Panel\()[\s\S])*?"
               r'Kicker\(if \(stale\) "SIGNAL · STALE" else "SIGNAL · LIVE"'
               r"(?:(?!Panel\()[\s\S])*?StatGrid\("),
              ("CONFIRM IT after the stat grid",
               r"StatGrid\((?:(?!Panel\()[\s\S])*?ConfirmItPanel\("),
              ("then Technical details",
               r"ConfirmItPanel\((?:(?!Panel\()[\s\S])*?DisclosureSection\(\s*"
               r'title = "Technical details"'),
              ("and COPY MAC last, after the disclosure closes",
               r"\n            \}" + _KT_ARM_GAP + r"CopyMacButton\(d\.mac\)"),
              ("the separate capture-note panel is gone", r"FirmwareDetailNote", 0))),
            ("Android Technical details", AND_DETAIL_SCREEN,
             r'DisclosureSection\(\s*title = "Technical details",(.*?)\n            \}',
             (("COPY MAC is not inside the disclosure", r"CopyMacButton", 0),
              ("the capture note renders again as the Detail row",
               r'd\.detail\?\.takeIf \{ it\.isNotEmpty\(\) \}\?\.let \{ add\("Detail" to it\) \}'))),
            ("Android match quality", AND_DETAIL_SCREEN,
             r"private fun MatchQualityPanel\(d: Detection\) \{(.*?)\n\}",
             (("the panel's kicker", r'Kicker\("MATCH QUALITY"\)'),
              ("closes with the capture note verbatim",
               r"d\.detail\?\.takeIf \{ it\.isNotEmpty\(\) \}\?\.let \{\s*\n\s*"
               r"Text\(it, color = Acab\.text"),
              ("and that note gets no kicker of its own", r'Kicker\("CAPTURE NOTE"\)', 0))),
            # PLACEMENT, which neither rule above reaches: the caption names the dashed line drawn
            # ON the thumbnail, so it has to sit under it. Above the map it captions whatever it
            # lands over instead, which on android is the corroboration line or the amber fix-age
            # line, so the sentence ends up calling a mapped-camera distance or a board's fix age
            # the phone's own path. The constants check compares this caption's WORDING across the
            # two phones and never its position, and the body needles stop outside the location
            # panel, so the two spans below are the only pin on where it sits.
            ("iOS breadcrumb caption", IOS_DETECTION_DETAIL,
             r"private func locationPanel\(_ coord: CLLocationCoordinate2D\) -> some View \{(.*?)\n    \}",
             # Anchored on the else branch, which is the LAST of the panel's two thumbnail renders
             # (tappable when a Map tab is mounted to receive the handoff, plain when none is), so
             # the caption is pinned after both rather than after whichever comes first. The span
             # ends at that branch's own closing brace, so the caption has to be a SIBLING of the
             # whole if/else and not a child of either arm. Inside the else it would render only
             # on the board-less saved-log sheet, and the ordinary dossier, where a Map tab is
             # mounted to take the handoff, would keep drawing the dashed trail over the thumbnail
             # with nothing saying it is the phone's own path.
             (("the caption sits under the thumbnail",
               r"\} else \{\s*\n\s*mapThumbnail\(coord\)[\s\S]*?"
               r"lineWidth: 1\)\)\s*\n\s*\}\s*\n\s*"
               r'if hasTrackerTrail \{\s*\n\s*Label\("Phone breadcrumb trail'),
              ("and it renders once", r'"Phone breadcrumb trail · this session"'))),
            ("Android breadcrumb caption", AND_DETAIL_SCREEN,
             r"private fun LocationPanel\((.*?)\n\}",
             # OPEN IN MAP is the pill inside the same Box as the AndroidView, so a span from it to
             # the caption's trail gate crosses the whole thumbnail and fails if the caption moves
             # above it.
             (("the caption sits under the thumbnail",
               r'"OPEN IN MAP"[\s\S]*?'
               r"if \(breadcrumbTrail\.count \{ validCoord\(it\.first, it\.second\) \} >= 2\)"),
              ("and it renders once", r'"Phone breadcrumb trail · this session"'))),
        ),
    },
)


def check_shared_shapes():
    """One rule, several declarations, in shapes no single literal carries."""
    print("\n== cross-platform rules (each side still carries the line that makes it true) ==")
    drift = 0
    for rule in SHARED_SHAPES:
        bad = []
        for label, rel, block_re, needs in rule["sides"]:
            try:
                text = read_local(rel)
            except OSError as exc:
                bad.append(f"{label}: {rel} could not be read ({exc})")
                continue
            if block_re is not None:
                blocks = re.findall(block_re, text, re.S)
                if len(blocks) != 1:
                    bad.append(f"{label}: {len(blocks)} blocks matched in {rel} (expected exactly 1)")
                    continue
                text = blocks[0]
            for name, need, *count in needs:
                # A need is (name, regex) and must match exactly once. The optional third element
                # is a different expected count, for a line REPEATED once per call site: "every
                # dossier ago call passes the tick" is the count of the good shape pinned beside
                # the count of every call site, so dropping the tick from one call and adding a
                # call that never had it each move one of the two numbers.
                want = count[0] if count else 1
                hits = len(re.findall(need, text, re.M))
                if hits != want:
                    bad.append(f"{label}: '{name}' matched {hits} times in {rel}"
                               f" (expected exactly {want})")
        if bad:
            print(f"   !! {rule['what']}: a side no longer carries the rule")
            for line in bad:
                print(f"      {line}")
            print(f"      {rule['why']}")
            drift += 1
        else:
            print(f"   ok: {rule['what']} ({len(rule['sides'])} sides)")
    return drift


def check_map_refresh_ladder():
    """The row-count ladder that meters detection-driven map rebuilds, rung for rung.

    iOS declares it in seconds (`mapDetectionRefreshInterval`), Android in milliseconds
    (`mapDetectionRefreshIntervalMs`), so the literals cannot be compared as written; parse both
    into (threshold, milliseconds) and compare those, default rung included. Both suites pin their
    own side at the boundaries; this pins the two sides to each other.
    """
    print("\n== map detection refresh ladder (same rungs on both phones) ==")
    ios_text = read_local(IOS_MAP_TAB)
    and_text = read_local(AND_MAP_PROJECTION)
    m_ios = re.search(r"func mapDetectionRefreshInterval\(rowCount: Int\) -> TimeInterval \{(.*?)\n\}",
                      ios_text, re.S)
    m_and = re.search(r"fun mapDetectionRefreshIntervalMs\(rowCount: Int\): Long = when \{(.*?)\n\}",
                      and_text, re.S)
    if not m_ios or not m_and:
        blind = IOS_MAP_TAB if not m_ios else AND_MAP_PROJECTION
        print(f"   !! could not read the ladder out of {blind}; it moved or changed shape")
        return 1
    ios_arms = re.findall(r"case (\d[\d_]*)\.\.\.:\s*return ([\d.]+)", m_ios.group(1))
    ios_default = re.search(r"default:\s*return ([\d.]+)", m_ios.group(1))
    and_arms = re.findall(r"rowCount >= (\d[\d_]*) -> (\d[\d_]*)L", m_and.group(1))
    and_default = re.search(r"else -> (\d[\d_]*)L", m_and.group(1))
    # Blindness guard, as everywhere in this file: every arm has to have parsed.
    ios_returns = len(re.findall(r"\breturn\b", m_ios.group(1)))
    and_arrows = len(re.findall(r"->", m_and.group(1)))
    if (not ios_default or not and_default or ios_returns != len(ios_arms) + 1
            or and_arrows != len(and_arms) + 1):
        print("   !! a ladder rung did not parse, so the two sides were NOT compared")
        print(f"      iOS: {len(ios_arms)} rung(s) + {'a' if ios_default else 'NO'} default of"
              f" {ios_returns} return(s)")
        print(f"      Android: {len(and_arms)} rung(s) + {'a' if and_default else 'NO'} default of"
              f" {and_arrows} arm(s)")
        return 1
    ios = [(int(t.replace("_", "")), round(float(v) * 1000)) for t, v in ios_arms]
    ios.append(("default", round(float(ios_default.group(1)) * 1000)))
    and_ = [(int(t.replace("_", "")), int(v.replace("_", ""))) for t, v in and_arms]
    and_.append(("default", int(and_default.group(1).replace("_", ""))))
    if ios != and_:
        print("   !! the two phones meter map rebuilds on DIFFERENT ladders")
        print(f"      iOS     {ios}")
        print(f"      Android {and_}")
        print("      one phone would redraw a dense map more or less often than the other")
        return 1
    print(f"   ok: {len(ios)} rungs identical - "
          + ", ".join(f"{t}: {ms} ms" for t, ms in ios))
    return 0


def _device_type_raw_values():
    """Case name -> wire value for both DeviceType enums, so an arm written `.axonBodyCam` on iOS
    and `BODY_CAM` on Android can be matched by the value both declare rather than by a hand-kept
    name map. (None, reason) when either enum cannot be read."""
    ios_enum = re.search(r"enum DeviceType: Int[^\n]*\{(.*?)\n\}", read_local(IOS_DEVICE_TYPE), re.S)
    and_enum = re.search(r"enum class DeviceType\(val raw: Int\) \{(.*?);", read_local(AND_DEVICE_TYPE), re.S)
    if not ios_enum or not and_enum:
        return None, None, ("the DeviceType enum could not be read out of "
                            + (IOS_DEVICE_TYPE if not ios_enum else AND_DEVICE_TYPE))
    ios = {n: int(v) for n, v in re.findall(r"^\s*case (\w+)\s*=\s*(\d+)", ios_enum.group(1), re.M)}
    and_body = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", and_enum.group(1), flags=re.S))
    and_ = {n: int(v) for n, v in re.findall(r"\b([A-Za-z_]\w*)\s*\(\s*(\d+)\s*\)", and_body)}
    if not ios or not and_:
        return None, None, "a DeviceType enum parsed to no cases"
    return ios, and_, None


def check_pin_priority():
    """Which member of a same-spot map group draws its pin: the same rank per category on both
    phones (iOS `MapPinRules.priority`, Android `infraPinPriority`), matched by wire value.

    Comma arms are read on both sides (`case .a, .b: return 1`, `DeviceType.A, DeviceType.B -> 1`),
    one rank per name, and the first arm naming a type wins, as it does at runtime. Comments come
    out first. Two blindness guards then hold each side to code this parser read in full: every
    `return` / `->` belongs to a parsed arm or the default, and every case name the table writes
    was read into an arm. Reading only the last name of a comma arm used to pass silently.
    """
    print("\n== same-spot pin priority (which category draws the pin) ==")
    ios_raw, and_raw, reason = _device_type_raw_values()
    if reason:
        print(f"   !! {reason}; the priority tables were NOT compared")
        return 1
    m_ios = re.search(r"static func priority\(_ type: DeviceType\) -> Int \{(.*?)\n    \}",
                      read_local(IOS_MAP_TAB), re.S)
    m_and = re.search(r"fun infraPinPriority\(type: DeviceType\): Int = when \(type\) \{(.*?)\n\}",
                      read_local(AND_MAP_SCREEN), re.S)
    if not m_ios or not m_and:
        blind = IOS_MAP_TAB if not m_ios else AND_MAP_SCREEN
        print(f"   !! could not read the priority table out of {blind}; it moved or changed shape")
        return 1
    ios_body = _strip_comments(m_ios.group(1), "swift")
    and_body = _strip_comments(m_and.group(1), "kotlin")
    ios_arms = [(re.findall(r"\.(\w+)", names), int(rank)) for names, rank in re.findall(
        r"^\s*case\s+(\.\w+(?:\s*,\s*\.\w+)*)\s*:\s*return\s+(\d+)\b", ios_body, re.M)]
    and_arms = [(re.findall(r"DeviceType\.(\w+)", names), int(rank)) for names, rank in re.findall(
        r"^\s*(DeviceType\.\w+(?:\s*,\s*DeviceType\.\w+)*)\s*->\s*(\d+)\b", and_body, re.M)]
    ios_default = re.search(r"^\s*default\s*:\s*return\s+(\d+)\b", ios_body, re.M)
    and_default = re.search(r"^\s*else\s*->\s*(\d+)\b", and_body, re.M)
    unknown = ([f"iOS .{n}" for names, _ in ios_arms for n in names if n not in ios_raw]
               + [f"Android {n}" for names, _ in and_arms for n in names if n not in and_raw])
    ios_returns = len(re.findall(r"\breturn\b", ios_body))
    and_arrows = len(re.findall(r"->", and_body))
    ios_names = len(re.findall(r"(?<![\w.])\.[A-Za-z_]\w*", ios_body))
    and_names = len(re.findall(r"\bDeviceType\.\w+", and_body))
    ios_read = sum(len(names) for names, _ in ios_arms)
    and_read = sum(len(names) for names, _ in and_arms)
    if (unknown or not ios_default or not and_default
            or ios_returns != len(ios_arms) + 1 or and_arrows != len(and_arms) + 1
            or ios_names != ios_read or and_names != and_read):
        print("   !! a priority arm did not parse, so the two sides were NOT compared")
        for u in unknown:
            print(f"      {u} is not a DeviceType case")
        print(f"      iOS: {len(ios_arms)} arm(s) naming {ios_read} of {ios_names} case name(s),"
              f" {'a' if ios_default else 'NO'} default, of {ios_returns} return(s)")
        print(f"      Android: {len(and_arms)} arm(s) naming {and_read} of {and_names} case name(s),"
              f" {'an' if and_default else 'NO'} else, of {and_arrows} arm(s)")
        return 1
    ios, and_ = {}, {}
    for names, rank in ios_arms:
        for n in names:
            ios.setdefault(ios_raw[n], rank)
    for names, rank in and_arms:
        for n in names:
            and_.setdefault(and_raw[n], rank)
    ios_d, and_d = int(ios_default.group(1)), int(and_default.group(1))
    if ios != and_ or ios_d != and_d:
        print("   !! the two phones rank same-spot pins DIFFERENTLY")
        for raw in sorted(set(ios) | set(and_)):
            a, b = ios.get(raw, "<default>"), and_.get(raw, "<default>")
            if a != b:
                print(f"      wire type {raw}: iOS {a} vs Android {b}")
        if ios_d != and_d:
            print(f"      default: iOS {ios_d} vs Android {and_d}")
        print("      a body cam could draw under a lesser sighting on one phone only")
        return 1
    shown = ", ".join(f"t={raw}: {ios[raw]}" for raw in sorted(ios))
    print(f"   ok: {len(ios)} ranked types identical ({shown}; default {ios_d})")
    return 0


def check_privacy_contract():
    """Keep both apps on the one truthful privacy page and pin its seizure/location disclosures.

    The product previously had two hand-maintained policies. Both apps opened the stale one, which
    claimed the phone fix never left the phone after firmware had begun storing that fix in the
    offline buffer. Pinning only iOS == Android would let both drift together, so compare each to
    the expected canonical URL and verify the canonical page still carries the facts that made the
    old copy materially false.
    """
    print("\n== canonical privacy contract (one app-linked policy) ==")
    drift = 0
    for label, rel in (("iOS", IOS_SETTINGS), ("Android", AND_DEVICE_SCREEN)):
        text = read_local(rel)
        count = text.count(CANONICAL_PRIVACY_URL)
        if count == 1:
            print(f"   ok: {label:7} opens {CANONICAL_PRIVACY_URL}")
        else:
            print(f"   !! {label} contains the canonical privacy URL {count} times (expected 1)")
            print(f"      {rel}")
            drift += 1

    policy = read_local(CANONICAL_PRIVACY).lower()
    required = (
        "sends its current fix",
        "about 18 hours",
        "keeps a copy of that key",
        "not sealed against a seized board",
        "site host sees the request",
    )
    missing = [fact for fact in required if fact not in policy]
    if missing:
        print(f"   !! {CANONICAL_PRIVACY} lost required disclosure(s):")
        for fact in missing:
            print(f"      {fact!r}")
        drift += len(missing)
    else:
        print("   ok: canonical policy discloses GPS transfer/retention and seized-board key risk")
    # soyboi.tech currently sits behind Cloudflare, while this canonical document itself is
    # deployed by GitHub Pages. Naming the latter as the receiver of firmware/dataset requests is
    # materially wrong and already regressed once; keep the request disclosure host-neutral.
    if "github pages" in policy:
        print(f"   !! {CANONICAL_PRIVACY} misidentifies the host receiving app requests")
        drift += 1
    return drift


def _glob_to_re(pattern):
    """A GitHub `paths` pattern as a regex: `**` crosses directories and `*` does not. None for any
    other glob syntax (`?`, `[...]`, `{...}`, `+`, a leading `!` negation), which this reader would
    get wrong, so the caller reports it instead of guessing."""
    if pattern.startswith("!") or re.search(r"[?\[\]{}+]", pattern):
        return None
    parts = re.split(r"(\*\*|\*)", pattern)
    return re.compile("".join(".*" if p == "**" else "[^/]*" if p == "*" else re.escape(p)
                              for p in parts) + r"\Z")


def _workflow_trigger_paths(text):
    """{event: [path patterns]} from the `paths:` block lists under a workflow's top-level `on:`,
    as (events, problems). Line-based, because CI installs no YAML library. A shape this reader
    does not follow (a flow-style list, `paths-ignore`, an entry it cannot unquote) is a problem,
    never a skip."""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if re.fullmatch(r"on:\s*", l)), None)
    if start is None:
        return {}, ["no top-level `on:` block"]
    events, problems = {}, []
    event_indent = event = paths_indent = None
    for line in lines[start + 1:]:
        body = line.strip()
        if not body or body.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            break
        if paths_indent is not None and indent > paths_indent and body.startswith("- "):
            item = re.fullmatch(r"- (?:'([^']*)'|\"([^\"]*)\"|([^\s'\"#]+))", body)
            if item:
                events[event].append(next(g for g in item.groups() if g is not None))
            else:
                problems.append(f"{event}: path entry {body!r} is not one plain or quoted path")
            continue
        paths_indent = None
        key = re.match(r"([A-Za-z_-]+):", body)
        if not key:
            problems.append(f"{body!r} under `on:` was not understood")
            continue
        if event_indent is None:
            event_indent = indent
        if indent == event_indent:
            event = key.group(1)
        elif key.group(1) == "paths":
            if body != "paths:":
                problems.append(f"{event}: `paths` is not a block list")
            events[event] = []
            paths_indent = indent
        elif key.group(1) == "paths-ignore":
            problems.append(f"{event}: `paths-ignore` is set, which this reader does not apply")
    return events, problems


# The workflow line that runs this script for real: no --offline, no other argument.
_CI_DRIFT_RUN_RE = re.compile(r"\s*run:\s*python3 firmware/tools/check-signature-drift\.py\s*")
# The two keys that leave a step listed in the workflow while it stops failing the run.
_CI_SKIP_KEY_RE = re.compile(r"(if|continue-on-error)\s*:")


def _ci_drift_step(text):
    """The job that runs this script, as (job name, problems). None with a problem when unreadable.

    Counting `run:` lines is not enough, and used to be all this did: `continue-on-error: true`
    added to keep a red CI moving, or `if: false` to park the step, left every cross-platform
    guard present, running or not, and not failing anything, while the line below still printed
    ok. That is the shape this whole file exists to refuse.

    Line-based, like _workflow_trigger_paths, because CI installs no YAML library: it walks out
    from the `run:` line to the `- ` step bullet above it and to the job header above that, and
    reports either key on either. It cannot tell an always-true `if:` from `if: false`, so it
    reports both and whoever wants one changes this check on purpose. The job NAME is returned
    rather than required to be `build`, so a step moved to another job changes what the caller
    prints instead of outliving a sentence that named the old one. It does not see a step
    disabled from outside its own keys: a `strategy`, a reusable workflow, a `needs:` on a job
    that can be skipped, or a repository setting.
    """
    lines = text.splitlines()
    hits = [i for i, line in enumerate(lines) if _CI_DRIFT_RUN_RE.fullmatch(line)]
    if len(hits) != 1:
        return None, [f"a step runs this script without --offline {len(hits)} times (expected 1)"]
    run_at = hits[0]
    run_indent = len(lines[run_at]) - len(lines[run_at].lstrip())
    problems = []

    def keys_of(start, own_indent, key_indent, first=None):
        """The keys of the block opened at `start`: `first` (the key written on a step's own
        bullet line) plus each following line at key_indent, until the block dedents."""
        out = [first] if first else []
        for line in lines[start + 1:]:
            body = line.strip()
            if not body or body.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            if indent <= own_indent:
                break
            if indent == key_indent:
                out.append(body)
        return out

    step_at = next((i for i in range(run_at, -1, -1)
                    if lines[i].lstrip().startswith("- ")
                    and len(lines[i]) - len(lines[i].lstrip()) < run_indent), None)
    if step_at is None:
        return None, ["the line running this script is not inside a `- ` step"]
    step_indent = len(lines[step_at]) - len(lines[step_at].lstrip())
    for key in keys_of(step_at, step_indent, run_indent, lines[step_at].strip()[2:]):
        if _CI_SKIP_KEY_RE.match(key):
            problems.append(f"the step running this script carries `{key}`, so it can stop"
                            " failing the run while still being listed")
    job_at = next((i for i in range(step_at, -1, -1)
                   if re.fullmatch(r"  ([A-Za-z0-9_-]+):\s*", lines[i])), None)
    top_at = next((i for i in range(step_at, -1, -1)
                   if lines[i][:1] not in ("", " ", "#")), None)
    if job_at is None or top_at is None or lines[top_at].rstrip() != "jobs:":
        return None, problems + ["the step running this script is not under a `jobs:` entry this"
                                 " reader can name"]
    job = lines[job_at].strip()[:-1]
    for key in keys_of(job_at, 2, 4):
        if _CI_SKIP_KEY_RE.match(key):
            problems.append(f"the `{job}` job carries `{key}`, so the step running this script"
                            " can be skipped whole")
    return job, problems


def check_ci_trigger_paths():
    """The one CI runner of this script must run it on a commit that touches ANY file it reads,
    in a step that can still fail the run.

    firmware-ci.yml filters on explicit `paths:` lists, and most guards above exist to catch the
    commit that edits one of their files alone. A file this script reads that is missing from
    either list is a guard CI never runs on that commit, and a green run cannot show it. So hold
    both lists to the files this run actually read (_READS), and read the step that runs the
    script (_ci_drift_step), which names the job and reports an `if:` or a `continue-on-error:`
    on the step or its job. Runs LAST, so every read above is counted. It does not see the push
    `branches:` filter, the other workflows, a file opened without read_local or _READS, or the
    ways of disabling a step that live outside the step's and the job's own keys.
    """
    print("\n== CI trigger paths (firmware-ci.yml runs this script on every file it reads) ==")
    try:
        text = read_local(FIRMWARE_CI)
    except OSError as exc:
        print(f"   !! {FIRMWARE_CI} could not be read ({exc}), so CI coverage was NOT checked")
        return 1
    events, problems = _workflow_trigger_paths(text)
    job, step_problems = _ci_drift_step(text)
    problems += step_problems
    reads = sorted(_READS)
    missing = []
    for event in ("push", "pull_request"):
        patterns = events.get(event)
        if not patterns:
            problems.append(f"{event}: no `paths:` list was read")
            continue
        compiled = []
        for pattern in patterns:
            rx = _glob_to_re(pattern)
            if rx is None:
                problems.append(f"{event}: {pattern!r} uses glob syntax this reader does not apply")
            else:
                compiled.append(rx)
        missing += [(event, rel) for rel in reads if not any(rx.match(rel) for rx in compiled)]
    if problems or missing:
        print(f"   !! {FIRMWARE_CI} would not run this script on every commit it exists to catch")
        for msg in problems:
            print(f"      {msg}")
        for event, rel in missing:
            print(f"      {event:12} does not list {rel}")
        print("      a guard whose file CI does not trigger on runs only on some later, unrelated")
        print("      commit; add the path to BOTH lists, or fix the workflow shape")
        return 1
    print(f"   ok: all {len(reads)} files this run read are in both path lists")
    print(f"   ok: the `{job}` job runs this script without --offline, in a step carrying no"
          " `if:` and no `continue-on-error:`")
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="ACAB signature + vendored-copy drift check (reports only, changes nothing)")
    ap.add_argument("--offline", action="store_true",
                    help="skip the upstream release/list watch instead of failing on an "
                         "unreachable network. For a bench run with no connectivity, NOT for CI: "
                         "a watcher that skipped itself has watched nothing.")
    args = ap.parse_args()
    print("ACAB signature drift check (reports only, changes nothing)\n")
    drift = (check_flock(args.offline) + check_odid(args.offline) + check_odid_copies()
             + check_faq_copies() + check_inline_labels()
             + check_ascii_clamp_copies() + check_shared_constants()
             + check_shared_shapes() + check_map_refresh_ladder() + check_pin_priority()
             + check_privacy_contract())
    # Last, so it sees every file the checks above read.
    drift += check_ci_trigger_paths()
    print()
    if drift:
        print(f"DRIFT: {drift} item(s) need a look. Review and re-port by hand.")
        sys.exit(1)
    print("No drift detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
