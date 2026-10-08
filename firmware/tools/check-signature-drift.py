#!/usr/bin/env python3
"""Watch ACAB's one vendored dependency for upstream drift: the opendroneid decoder.
The Flock OUI table is own-sourced (own field captures plus Flock's IEEE block) and is
no longer diffed against any third-party curated list.

    python3 firmware/tools/check-signature-drift.py
    python3 firmware/tools/check-signature-drift.py --offline   # skip the network watch

Exits 0 when nothing upstream is missing locally, 1 when there is drift to look
at. It only reports; it never edits anything. Provenance is in CREDITS.md. When the
upstream repo moves, update ODID_REPO below.

A network failure is NOT a pass here (see check_odid). Pass --offline to state on
purpose that a run is not watching upstream.
"""
import argparse
import fractions
import hashlib
import json
import os
import re
import sys
import urllib.request

# --- upstream sources (edit as they move) -----------------------------------
# opendroneid decoder: watch for a NEW upstream RELEASE instead of byte-diffing
# master. core-c's last release is v2.0 (2022); everything on master since is
# unreleased const-correctness and encode-side churn we reviewed and chose to
# skip, so diffing master is pure noise. This flags only when core-c actually
# ships a newer release. Bump the baseline when you re-vendor opendroneid/.
ODID_REPO = "opendroneid/opendroneid-core-c"
ODID_BASELINE_RELEASE = "v2.0"   # latest release reviewed (2026-06-16)

# The two enums whose faqKey values ARE the keys of faq-content.json's relatedHelp map.
IOS_DEVICE_TYPE = "ios/Beacons/Models/DeviceType.swift"
AND_DEVICE_TYPE = "android/app/src/main/java/tech/acab/app/model/Models.kt"

# The app files carrying constants that must read the same on both platforms (see
# SHARED_CONSTANTS).
IOS_CONTRIBUTION_CSV = "ios/Beacons/BLE/ContributionCsv.swift"
IOS_BLE_MANAGER = "ios/Beacons/BLE/BLEManager.swift"
IOS_BLE_OTA = "ios/Beacons/BLE/BLEManager+OTA.swift"
IOS_BLE_NRF_DFU = "ios/Beacons/BLE/BLEManager+NrfDFU.swift"
AND_BLE_MANAGER = "android/app/src/main/java/tech/acab/app/ble/AcabBleManager.kt"
AND_NRF_DFU = "android/app/src/main/java/tech/acab/app/ble/NrfDfuCoordinator.kt"
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
IOS_THEME = "ios/Beacons/Views/Theme.swift"
AND_COMPONENTS = "android/app/src/main/java/tech/acab/app/ui/Components.kt"
# The instrument layer's shared constants (decisions R16) live in the theme file on both sides.
AND_THEME = "android/app/src/main/java/tech/acab/app/ui/theme/Theme.kt"
IOS_OUI_VENDORS = "ios/Beacons/Models/OUIVendors.swift"
AND_OUI_VENDORS = "android/app/src/main/java/tech/acab/app/model/OuiVendors.kt"
IOS_BEACON_PRESENTATION = "ios/Beacons/Models/BeaconPresentation.swift"
IOS_DASHBOARD_VIEW = "ios/Beacons/Views/DashboardView.swift"
IOS_DETECTION_DETAIL = "ios/Beacons/Views/DetectionDetailView.swift"
AND_DETAIL_SCREEN = "android/app/src/main/java/tech/acab/app/ui/DetailScreen.kt"
IOS_DETECTION_ROW = "ios/Beacons/Views/DetectionRow.swift"
IOS_FIRST_RUN_TOUR = "ios/Beacons/Views/FirstRunTourView.swift"
AND_FIRST_RUN_TOUR = "android/app/src/main/java/tech/acab/app/ui/FirstRunTour.kt"
# The Help + support screen the dossier's Related help pushes to on iOS (its navigation title is
# the twin of Android's DOSSIER_HELP_TITLE in DetailScreen.kt).
IOS_HELP_VIEW = "ios/Beacons/Views/HelpView.swift"
# The checklist's state sentences live beside the sheet on iOS (ChecklistRows) and in
# FirstRunTour.kt on Android; the ALPR callout headline lives with the dataset on iOS
# (ALPRAttribution) and in MapAlpr.kt on Android; Detection.titleName sits on the model on iOS.
IOS_CHECKLIST = "ios/Beacons/Views/ChecklistView.swift"
IOS_ALPR_DATASET = "ios/Beacons/Models/ALPRDataset.swift"
AND_MAP_ALPR = "android/app/src/main/java/tech/acab/app/ui/MapAlpr.kt"
IOS_DETECTION = "ios/Beacons/Models/Detection.swift"
# The board kind (decisions R14: which product the owner holds, for copy only) and the remembered
# board's row copy. The kind table and its resolvers live in one file per app; the remembered row
# copy lives beside the remembered-board rules on iOS and in AcabBleManager.kt on Android.
IOS_BOARD_KIND = "ios/Beacons/Models/BoardKind.swift"
AND_BOARD_KIND = "android/app/src/main/java/tech/acab/app/ble/BoardKind.kt"
IOS_REMEMBERED_BOARD = "ios/Beacons/BLE/RememberedBoard.swift"
# The bundled FAQ, shipped as ONE file copied into both resource trees (check_faq_copies
# asserts the two are byte-identical; SHARED_SHAPES pins the promises inside them).
IOS_FAQ = "ios/Beacons/Resources/faq-content.json"
AND_FAQ = "android/app/src/main/assets/faq-content.json"
# The firmware and protocol-doc sides of a rule the apps seed from (see SHARED_SHAPES).
FW_BEACON_MAIN = "firmware/src/beacon-board/main.cpp"
FW_MESH_MAIN = "firmware/src/mesh-detect/main.cpp"
FW_PLATFORMIO = "firmware/platformio.ini"
DOCS_BLE_PROTOCOL = "docs/ble-protocol.md"
CANONICAL_PRIVACY = "web/privacy.html"
CANONICAL_PRIVACY_URL = (
    "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html"
)
# ----------------------------------------------------------------------------


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def read_local(rel):
    with open(os.path.join(repo_root(), rel), encoding="utf-8") as f:
        return f.read()


def latest_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {"User-Agent": "acab-drift-check", "Accept": "application/vnd.github+json"}
    # Unauthenticated api.github.com allows 60 requests/hour per SOURCE IP, and Actions runners
    # share egress IPs, so an unauthenticated call from CI hits a 403 fairly often. The workflow
    # hands us the job's own GITHUB_TOKEN, which raises that to the repo's own budget and removes
    # the usual reason this watch fails. Sent ONLY to api.github.com.
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


def _faq_case_drift(faq):
    """The questions and support row titles in `faq` (the parsed JSON) that break the sentence-case
    rule, each as one message. A question starts with a capital, and so does every sentence inside
    it (a lowercase letter after '. ', '? ' or '! ' is the miss); a support row title starts with a
    capital. Answers are not read: they stay lowercase-first on purpose."""
    bad = []
    for sec in faq.get("sections", []):
        for q in sec.get("questions", []):
            text = q.get("q", "")
            if not text[:1].isupper():
                bad.append(f"question '{text}' does not start with a capital")
            inner = re.search(r"[.?!] ([a-z])", text)
            if inner:
                bad.append(f"question '{text}' starts a sentence in lowercase at '{inner.group(0)}'")
    for row in faq.get("support", []):
        title = row.get("title", "")
        if not title[:1].isupper():
            bad.append(f"support row title '{title}' does not start with a capital")
    return bad


def check_faq_copies():
    """The bundled FAQ ships as ONE file copied into both app resource trees. Assert byte equality.

    faq-content.json is the shared answer set that must read identically on iOS and Android. Keeping it as a
    Swift literal and a Kotlin literal would be two hand-maintained copies of the same prose, and
    cross-platform copy drift is the most recurring defect class in this repo. So it is one file,
    duplicated verbatim into two resource trees because neither build system will reach outside its
    own tree, and this check is what makes the duplication safe: edit one, the build tells you.
    """
    root = repo_root()
    rel_a, rel_b = IOS_FAQ, AND_FAQ
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
    # Case rule (decisions R19 and R20): FAQ QUESTIONS and the Help SUPPORT ROW TITLES are
    # sentence case (the first letter up, and a sentence that starts inside a question gets its
    # capital too: "...isn't detecting it. Is it broken?"); answers stay lowercase-first. Both
    # apps draw these strings as written, so a lowercase question or row title ships as typed.
    wrong_case = _faq_case_drift(d)
    if wrong_case:
        for msg in wrong_case:
            print(f"   !! {msg}")
        print("      questions and support row titles are sentence case (CLAUDE.md Copy rules)")
        return 1
    print(f"   ok: every question and support row title is sentence case")
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
def _toggle_title_rows():
    """One "string" row per Beacon sub-screen toggle title that both phones draw (P3-11): the
    title hole `"([^"]*)"` is read from the radioToggle / ToggleRow call whose subtitle opens with
    `anchor` (iOS writes its middle dots as \\u{00B7}, Android as the character, so the anchor
    stops before the first dot). `and_anchor` is the Android subtitle's opening when it is not a
    literal (a val, an if)."""
    rows = []
    for what, anchor, and_anchor in (
        ("Scan radios Bluetooth toggle title", "ALPR ", None),
        ("Scan radios Wi-Fi toggle title", "2\\.4 GHz", None),
        ("Scan radios 5 GHz Wi-Fi toggle title", "9 channels ", None),
        ("Detectors drones toggle title", "FAA remote ID", None),
        ("Detectors non-broadcasting drones toggle title", "OUI match only", None),
        ("Detectors body cams toggle title", "Axon ", None),
        ("Detectors Motorola sub-toggle title", "vendor match only", None),
        ("Detectors trackers toggle title", "AirTag", None),
        ("Detectors glasses toggle title", "Ray-Ban", None),
        ("Detectors network cameras toggle title", "known IP-camera", None),
        ("Offline buffer toggle title", "board buffers while away", r"bufferSubtitle,"),
        ("Desert mode toggle title", "show \\+ log ANY", None),
        ("Board LED lights-out toggle title", "no LEDs", None),
        ("Display higher-contrast toggle title", "brighter secondary text",
         r"if \(ContrastMode\.systemHasControl\)"),
    ):
        rows.append({
            "what": what,
            "kind": "string",
            "why": "a Beacon sub-screen row title, sentence case and the same bytes on both phones"
                   " (P3-11, decisions R20); read from the call whose subtitle opens '"
                   + anchor.replace("\\", "") + "'",
            "ios": (IOS_SETTINGS, r'radioToggle\("([^"]*)",\s*"' + anchor),
            "android": (AND_DEVICE_SCREEN,
                        r'ToggleRow\(\s*"([^"]*)",\s*' + (and_anchor if and_anchor else '"' + anchor)),
        })
    return tuple(rows)


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
        # A TEMPLATE since decisions R14 ("turn the {noun} off and on"): the template is compared,
        # and renderBoardCopy fills it on each side (the "board kind table" check pins that).
        "why": "user-facing recovery copy: the same failure has to read the same on both phones",
        "ios": (IOS_BLE_MANAGER, r'static\s+let\s+pairWindowHint\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_BLE_MANAGER,
                    r'\bconst\s+val\s+PAIR_WINDOW_HINT_TEMPLATE\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    # The two update-quarantine lines (a retry on the link that owned a quarantined attempt) are
    # TEMPLATES since 2026-09-25: the iOS pair said "board" and the Android pair "beacon" in
    # different sentences. Settled to one lowercase-first {noun} template per update, filled by
    # renderBoardCopy with the connected board's kind on each side.
    {
        "what": "board update quarantine line",
        "kind": "string",
        "why": "user-facing recovery copy: a retried board update that must reconnect first reads"
               " the same on both phones",
        "ios": (IOS_BLE_OTA,
                r'static\s+let\s+otaReconnectBeforeRetryTemplate\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_BLE_MANAGER,
                    r'\bconst\s+val\s+OTA_RECONNECT_BEFORE_RETRY_TEMPLATE\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "co-processor update quarantine line",
        "kind": "string",
        "why": "user-facing recovery copy: a retried co-processor update that must reconnect first"
               " reads the same on both phones",
        "ios": (IOS_BLE_NRF_DFU,
                r'static\s+let\s+nrfReconnectBeforeRetryTemplate\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_NRF_DFU,
                    r'\bconst\s+val\s+NRF_DFU_RECONNECT_BEFORE_RETRY_TEMPLATE\s*=\s*"((?:[^"\\]|\\.)*)"'),
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
        "android": (AND_MAP_SCREEN, r'SectionLabel\("(REFERENCE[^"]*)"'),
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
    # Same REQUIRED shapes as the Log's two whole-declaration rows (contracts 5.2 and 5.4): the
    # Android label is an expression body `= when (scope) {` closed at column 0, and the iOS
    # headline is a single-expression body with no `return`.
    {
        "what": "map scope segment labels",
        "kind": "fragments",
        "why": "the Map's active / recent / all control names each scope and its count in the"
               " same words on both phones; unlike the Log, the Map's All carries a count",
        "ios": (IOS_MAP_TAB,
                r"(func mapScopeSegmentLabel\(_ scope: MapHistoryScope, count: Int\) -> String \{.*?\n\})"),
        "android": (AND_MAP_PROJECTION,
                    r"(internal fun mapScopeSegmentLabel\(scope: MapHistoryScope, count: Int\): String ="
                    r" when \(scope\) \{.*?\n\})"),
    },
    {
        "what": "map honesty headline",
        "kind": "fragments",
        "why": "'N on the map · M without a location' is the line that stops a map with few pins"
               " reading as few detections; a phone that words it differently hides what the"
               " other one admits",
        "ios": (IOS_MAP_TAB,
                r'func mapHonestyHeadline\(onMap: Int, withoutLocation: Int\) -> String \{\s*("[^\n]*")\s*\n\}'),
        "android": (AND_MAP_PROJECTION,
                    r'internal fun mapHonestyHeadline\(onMap: Int, withoutLocation: Int\): String =\s*("[^\n]*")'),
    },
    {
        "what": "export base filename",
        "kind": "string",
        "why": "the file a share sheet hands out is named the same on both phones; the slug"
               " words below are appended to it",
        # iOS names the prefix once (ExportTempCache.logExportPrefix) so Clear log's sweep and the
        # writer cannot disagree; the writer interpolates that constant ahead of the slug.
        "ios": (IOS_BLE_MANAGER, r'static let logExportPrefix = "(acab-detections)"'),
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
    # "log header kicker" was retired with the Logbook header (Route A C10, both apps): the
    # counts it carried are the active / new / all segment labels below.
    # The Log lens summary is TWO rows, one per template. A single region over both compared the
    # union of their text, so a clause dropped from only the spoken form still passed on the drawn
    # one. iOS builds the category tail once (`let category`) and hands it to both templates, so
    # each iOS pattern takes that line as its first group and one template as its second, and the
    # second must end on the `category` hole: a template that stops interpolating the tail is
    # reported as unreadable instead of passing on the shared line.
    {
        "what": "log lens summary (shown)",
        "kind": "fragments",
        "why": "'5 of 5 paused' under a 'new · 200' segment must not read as 195 lost sightings"
               " on either phone",
        # Both sides are now pure functions of the same four inputs (the category arrives as its
        # drawn chip label, never the filter key), so both are anchored the same way.
        "ios": (IOS_DETECTIONS_VIEW, r"(func logLensSummaryText\(.*?)\n\n"),
        "android": (AND_LOG_SCREEN, r"(internal fun logLensSummaryText\(.*?)\n\n"),
    },
    {
        "what": "log lens summary (spoken)",
        "kind": "fragments",
        "why": "the screen-reader form of the same line has to say the same thing in the same"
               " words on both phones",
        "ios": (IOS_DETECTIONS_VIEW, r"(func logLensSummaryDescription\(.*?)\n\n"),
        "android": (AND_LOG_SCREEN, r"(internal fun logLensSummaryDescription\(.*?)\n\n"),
    },
    # "log card heading" was retired too (C10): the time-section headers below replaced it.
    #
    # The Log's time sections under the Newest sort (contracts 3.4). The Active header lives
    # beside the window it names on both phones and is anchored on that hole, so the number keeps
    # coming from activeNearbyInterval / ACTIVE_NEARBY_WINDOW_MS rather than a literal 45.
    {
        "what": "log active section header",
        "kind": "fragments",
        "why": "the header over rows heard inside the recently-heard window names that window;"
               " a phone that words it differently, or types the number in, describes a"
               " different cut of the same Log",
        "ios": (IOS_BLE_MANAGER,
                r'static let activeSectionHeader = ("heard in the last \\\(Int\(activeNearbyInterval\)\) s")'),
        "android": (AND_BLE_MANAGER,
                    r'internal val LOG_ACTIVE_SECTION_HEADER = ("heard in the last'
                    r' \$\{ACTIVE_NEARBY_WINDOW_MS / 1_000L\} s")'),
    },
    {
        "what": "log earlier-today section header",
        "kind": "string",
        "why": "the header over rows last heard earlier on this calendar day reads the same on"
               " both phones",
        "ios": (IOS_DETECTIONS_VIEW, r'static let earlierTodaySectionHeader = "([^"]*)"'),
        "android": (AND_LOG_SCREEN, r'internal const val LOG_EARLIER_TODAY_HEADER = "([^"]*)"'),
    },
    {
        "what": "log older section header",
        "kind": "string",
        "why": "the header over older rows, and over every row whose time cannot be trusted,"
               " reads the same on both phones",
        "ios": (IOS_DETECTIONS_VIEW, r'static let olderSectionHeader = "([^"]*)"'),
        "android": (AND_LOG_SCREEN, r'internal const val LOG_OLDER_HEADER = "([^"]*)"'),
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
        "ios": (IOS_DETECTIONS_VIEW, r'Button\("(Clear Filters)"\)'),
        "android": (AND_LOG_SCREEN, r'Text\("(Clear Filters)",'),
    },
    {
        "what": "log search placeholder",
        "kind": "string",
        "why": "the empty search field's hint reads the same on both phones",
        # iOS moved the field into the system search bar (C10), so the prompt is pinned at the
        # one .searchable call bound to the Log's own search text. Since R19 (review P2-7) that
        # call carries an optional `placement:` argument of up to three lines before the prompt.
        "ios": (IOS_DETECTIONS_VIEW,
                r'\.searchable\(text: \$searchText,\s*(?:placement:(?:[^\n]*\n){1,3}?\s*)?'
                r'prompt: "((?:[^"\\]|\\.)*)"\)'),
        # The literal lives in LOG_SEARCH_PLACEHOLDER, which the fit rule measures and the
        # placeholder slot draws (Text(LOG_SEARCH_PLACEHOLDER, ...)); pin the constant.
        "android": (AND_LOG_SCREEN, r'internal const val LOG_SEARCH_PLACEHOLDER = "((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "log select-mode count",
        "kind": "fragments",
        # Anchored on the hole on both sides, so the number is the live selection's own count.
        "why": "'N SELECTED' in the select bar says how many rows its mute button is about to"
               " act on; it reads the same on both phones",
        "ios": (IOS_DETECTIONS_VIEW, r'Kicker\(("\\\(selection\.count\) SELECTED")\)'),
        "android": (AND_LOG_SCREEN, r'Kicker\(("\$count SELECTED")\)'),
    },
    # The two whole-declaration rows below rely on the REQUIRED source shapes (contracts 3.2 and
    # 3.6): a multi-line switch / `when` closed by a brace at column 0 (column 4 for the iOS
    # computed property). A one-line Android body or a block body with `return when` stops matching.
    {
        "what": "log scope segment labels",
        "kind": "fragments",
        "why": "the Log's active / new / all control names each cut and its count in the same"
               " words on both phones; All carries no count on either",
        "ios": (IOS_DETECTIONS_VIEW,
                r"(func logScopeSegmentLabel\(_ scope: StatusScope, count: Int\) -> String \{.*?\n\})"),
        "android": (AND_LOG_SCREEN,
                    r"(internal fun logScopeSegmentLabel\(scope: LogScope, count: Int\): String ="
                    r" when \(scope\) \{.*?\n\})"),
    },
    {
        "what": "confidence verdict words",
        "kind": "fragments",
        "why": "the spoken verdict a Log row gives with its confidence number; a screen reader"
               " user hears 'weak match, verify' on both phones or the row is hedged on one only",
        "ios": (IOS_DETECTION_ROW, r"(private var confidenceWord: String \{.*?\n    \})"),
        "android": (AND_LOG_SCREEN, r"(internal fun confidenceWord\(pct: Int\): String = when \{.*?\n\})"),
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
        # A TEMPLATE since decisions R14 ("desert mode ended on the {noun}"); each side renders
        # it with the kind its surface names.
        "ios": (IOS_SETTINGS, r'\blet\s+desertRestoreOffer\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_DEVICE_SCREEN,
                    r'\bconst\s+val\s+DESERT_RESTORE_OFFER_TEMPLATE\s*=\s*"((?:[^"\\]|\\.)*)"'),
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
        "why": "two words are all a screen reader gets from the label, so this sentence"
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
    # The connect screen (C14: one shared screen, contracts 9.5). Each row is anchored on its
    # sentence's first words, so a second copy left beside a rewrite matches twice and fails.
    # Decisions R15 (2026-09-26): the hero's passive subtitle is gone. The hero is the wordmark
    # and the tagline, and the scope footnote below is the screen's ONE passive statement (the
    # SHARED_SHAPES rule "connect screen says passive once" holds the count).
    {
        "what": "connect tagline",
        "kind": "string",
        "why": "the line under the wordmark names the product line on both phones and never takes"
               " a kind; a board-named tagline on one phone would read as a different product",
        # Anchored on the call that draws it, so a comment that quotes the words never counts.
        "ios": (IOS_CONNECT_VIEW, r'Kicker\("(ALL CAMERAS ARE [^"]*)"\)'),
        "android": (AND_ACAB_APP, r'Kicker\("(ALL CAMERAS ARE [^"]*)",'),
    },
    {
        "what": "connect tagline spoken",
        "kind": "string",
        "why": "a screen reader hears the tagline as words, not letter by letter, and the same"
               " words on both phones",
        "ios": (IOS_CONNECT_VIEW, r'\.accessibilityLabel\("(all cameras are [^"]*)"\)'),
        "android": (AND_ACAB_APP, r'contentDescription = "(all cameras are [^"]*)"'),
    },
    {
        "what": "connect opt-in sentence",
        "kind": "string",
        "why": "the line saying trackers and network cameras start off, and where to turn them on;"
               " a phone that drops it leaves two categories silently missing",
        "ios": (IOS_CONNECT_VIEW, r'"(trackers and network cameras are opt-in[^"]*)"'),
        "android": (AND_ACAB_APP, r'"(trackers and network cameras are opt-in[^"]*)"'),
    },
    {
        "what": "connect scope footnote",
        "kind": "string",
        "why": "the footnote that says the board never jams, spoofs or interferes reads the same"
               " on both phones",
        # Settled 2026-09-25 (decisions R14): both opened "Passive ... The", against the
        # lowercase-first rule. Anchored lowercase, so a side that reverts matches 0 times.
        "ios": (IOS_CONNECT_VIEW, r'"(passive detection only[^"]*)"'),
        "android": (AND_ACAB_APP, r'"(passive detection only[^"]*)"'),
    },
    # The connect screen's per-kind TEMPLATES (decisions R14): one literal per surface on each
    # side, holes {noun} / {a_noun} / {plural} / {NOUN} / {os_pairing_request} filled only by
    # renderBoardCopy, so the templates themselves are compared. Anchored on each sentence's first
    # words like the rows above, so an untemplated leftover ("power on your beacon ...") beside
    # the template matches twice and fails. Rows whose iOS literal writes a character as an
    # escape (\u{2026}, \u{00B7}) are "fragments" rows, which decode escapes before comparing.
    {
        "what": "connect setup sentence",
        "kind": "string",
        "why": "the first instruction a new owner reads, naming the board they hold (decisions"
               " R15: one line; the pairing step is said where it applies, not here)",
        "ios": (IOS_CONNECT_VIEW, r'"(power on your [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(power on your [^"]*)"'),
    },
    {
        "what": "connect rationale rest",
        "kind": "string",
        "why": "why the app asks for the radio permission, after the platform's bold permission"
               " name; the promise (the board listens, not the phone) is the same on both",
        "ios": (IOS_CONNECT_VIEW, r'"(connects your phone to your [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(connects your phone to your [^"]*)"'),
    },
    {
        "what": "connect bluetooth off",
        "kind": "string",
        "why": "the Bluetooth-off panel's one instruction",
        "ios": (IOS_CONNECT_VIEW, r'"(turn on Bluetooth to find your [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(turn on Bluetooth to find your [^"]*)"'),
    },
    {
        "what": "connect looking line",
        "kind": "fragments",
        "why": "the line under the scan while nothing is heard yet",
        "ios": (IOS_CONNECT_VIEW, r'("looking for your [^"]*")'),
        "android": (AND_ACAB_APP, r'("looking for your [^"]*")'),
    },
    {
        "what": "connect none found",
        "kind": "string",
        "why": "the empty-scan panel (drawn, and spoken on iOS): what to check before scanning"
               " again",
        "ios": (IOS_CONNECT_VIEW, r'"(no [^"]* found\. make sure your [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(no [^"]* found\. make sure your [^"]*)"'),
    },
    {
        "what": "connect secure pairing note",
        "kind": "string",
        "why": "the note above the heard boards: a tap pairs, and pairing encrypts the link",
        "ios": (IOS_CONNECT_VIEW, r'"(tap your [^"]*pairing encrypts[^"]*)"'),
        "android": (AND_ACAB_APP, r'"(tap your [^"]*pairing encrypts[^"]*)"'),
    },
    {
        "what": "connect connecting body",
        "kind": "string",
        "why": "the guidance under each platform's own status word while a connect or pairing"
               " runs",
        "ios": (IOS_CONNECT_VIEW, r'"(keep your [^"]* powered on and nearby\. approve [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(keep your [^"]* powered on and nearby\. approve [^"]*)"'),
    },
    {
        "what": "reconnect panel title",
        "kind": "fragments",
        "why": "the pre-shell reconnect panel names the board that dropped",
        "ios": (IOS_CONNECT_VIEW, r'("reconnecting to your [^"\\]*\\u\{2026\}")'),
        "android": (AND_ACAB_APP, r'("reconnecting to your [^"]*\u2026")'),
    },
    {
        "what": "reconnect panel body",
        "kind": "string",
        "why": "what the reconnect does on its own, and the way out, on both phones",
        "ios": (IOS_CONNECT_VIEW, r'"(it reconnects on its own [^"]*)"'),
        "android": (AND_ACAB_APP, r'"(it reconnects on its own [^"]*)"'),
    },
    {
        "what": "reconnect banner",
        "kind": "fragments",
        # The title (no ellipsis, unlike the panel's) and the body, as two groups.
        "why": "the banner over the tabs during a drop names the board and says the open screen"
               " and capture survive it",
        "ios": (IOS_CONNECT_VIEW, r'static let reconnectBannerTitle = ("reconnecting to your [^"\\]*")'
                r'\s*\n\s*static let reconnectBannerSubtitle = ("[^"]*")'),
        "android": (AND_MAIN_SCREEN, r'const val RECONNECT_BANNER_TITLE_TEMPLATE = ("reconnecting to your [^"]*")'
                    r'\s*\n\s*internal const val RECONNECT_BANNER_BODY = ("[^"]*")'),
    },
    {
        "what": "connect hears row",
        "kind": "string",
        "why": "the row that opens what the board can hear, in place under the row on both"
               " phones (decisions R15 retired the iOS sheet and its C2 header)",
        # Anchored on the names: a doc comment on iOS quotes the row's words.
        "ios": (IOS_CONNECT_VIEW, r'static let hearsRow = "([^"]*)"'),
        "android": (AND_ACAB_APP, r'const val CONNECT_HEARS_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "connect hears show action",
        "kind": "string",
        "why": "the hears row's spoken action while it is closed; a screen reader hears the same"
               " words on both phones",
        "ios": (IOS_CONNECT_VIEW, r'static let hearsShow = "([^"]*)"'),
        "android": (AND_ACAB_APP, r'const val CONNECT_HEARS_SHOW_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "connect hears hide action",
        "kind": "string",
        "why": "the hears row's spoken action while it is open",
        "ios": (IOS_CONNECT_VIEW, r'static let hearsHide = "([^"]*)"'),
        "android": (AND_ACAB_APP, r'const val CONNECT_HEARS_HIDE_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "connect saved log kicker",
        "kind": "fragments",
        "why": "the saved log needs no board, and says so the same way on both phones",
        "ios": (IOS_CONNECT_VIEW, r'("history on this phone [^"]*")'),
        "android": (AND_ACAB_APP, r'("history on this phone [^"]*")'),
    },
    {
        "what": "connect help row title",
        "kind": "string",
        # Settled 2026-09-25 (decisions R14, L3): iOS read "setup + pairing help", a sentence-case
        # row everywhere else.
        "why": "the row title is a row, sentence case like its neighbours, and the same words on"
               " both phones",
        "ios": (IOS_CONNECT_VIEW, r'connectRow\("questionmark\.circle", "([^"]*)"'),
        "android": (AND_ACAB_APP, r'GroupedRow\(\s*"([Ss]etup \+ pairing help)"'),
    },
    {
        "what": "connect help row subtitle",
        "kind": "string",
        # Settled 2026-09-25 (decisions R14) to Android's line; iOS read "power, secure pairing,
        # and recovery \u00b7 works offline".
        "why": "the line under 'Setup + pairing help' says what the help covers and that it works"
               " offline, in the same words on both phones",
        "ios": (IOS_CONNECT_VIEW, r'static let setupHelpSubtitle = "([^"]*)"'),
        "android": (AND_ACAB_APP, r'\bconst\s+val\s+CONNECT_SETUP_HELP_SUBTITLE\s*=\s*"([^"]*)"'),
    },
    {
        "what": "connect failure panel title",
        "kind": "string",
        # Settled 2026-09-25 (decisions R14): Android read "Connection didn't finish".
        "why": "the title above either phone's own failure hint",
        "ios": (IOS_CONNECT_VIEW, r'Text\("(connection did[^"]*)"\)'),
        "android": (AND_ACAB_APP, r'\bconst\s+val\s+CONNECTION_HINT_TITLE\s*=\s*"([^"]*)"'),
    },
    {
        "what": "connect failure pair-window note",
        "kind": "string",
        # Decisions R15: the note left the idle screen and rests under a failed connect's hint.
        # The pinned "pairing-window hint" template follows this lead on both sides, so the row
        # is anchored on the concatenation itself: a side that drops the hint or swaps it for
        # another line matches 0 times.
        "why": "the second-phone rule under a failed connect reads the same on both phones; the"
               " board hangs up before it can explain itself, so this line is the only"
               " explanation a user who missed the window gets",
        "ios": (IOS_CONNECT_VIEW, r'Text\("(already paired to another phone\? )"\s*'
                r'\+ renderBoardCopy\(BLEManager\.pairWindowHint, kind\)\)'),
        "android": (AND_ACAB_APP, r'"(already paired to another phone\? )" \+ AcabBleManager\.pairWindowHint\(kind\)'),
    },
    {
        "what": "remembered row title",
        "kind": "string",
        "why": "the remembered board's row names its kind ('your OUI-Spy'); never the raw"
               " advertised name, which every board of one kind shares",
        "ios": (IOS_REMEMBERED_BOARD, r'static let labelTemplate = "([^"]*)"'),
        "android": (AND_BLE_MANAGER, r'const val LABEL_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "remembered row subtitles",
        "kind": "fragments",
        "why": "the remembered row's second line: whether an advert is live, then the tap",
        "ios": (IOS_REMEMBERED_BOARD, r'static let noSignal = ("(?:[^"\\]|\\.)*")'
                r'\s*\n\s*static let seen = ("[^"]*")'),
        "android": (AND_BLE_MANAGER, r'const val NO_SIGNAL = ("(?:[^"\\]|\\.)*")'
                    r'\s*\n\s*const val SEEN = ("[^"]*")'),
    },
    # The post-connect checklist and what an empty radar means (C14, contracts 9.2): one home per
    # string on each platform, on FirstRunTour / object FirstRunTour.
    {
        "what": "quiet-does-not-mean-clear sentence",
        "kind": "fragments",
        # Anchored on the window hole on both sides, like the Log's active header.
        "why": "the sentence Status shows for a connected session with nothing nearby, and the"
               " checklist's footer: zero is not all clear, and the gear it cannot hear is named."
               " A phone that words it differently, or types the window in, tells its owner a"
               " different thing about an empty radar",
        "ios": (IOS_FIRST_RUN_TOUR,
                r'static let quietSentence = ("quiet does not mean clear\. zero nearby means[^"]*'
                r'\\\(Int\(activeNearbyInterval\)\) seconds\.[^"]*")'),
        "android": (AND_FIRST_RUN_TOUR,
                    r'val QUIET_SENTENCE = ("quiet does not mean clear\. zero nearby means[^"]*'
                    r'\$\{ACTIVE_NEARBY_WINDOW_MS / 1_000L\} seconds\.[^"]*")'),
    },
    # The title, subtitle and preview note are TEMPLATES since decisions R14 ("your {noun} is
    # listening"), rendered with the checklist's board kind on each side.
    {
        "what": "checklist title",
        "kind": "string",
        "why": "the post-connect checklist's title reads the same on both phones",
        "ios": (IOS_FIRST_RUN_TOUR, r'static let checklistTitle = "([^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'const val CHECKLIST_TITLE_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "checklist subtitle",
        "kind": "string",
        "why": "the line that says detection already runs and the rest is optional reads the"
               " same on both phones",
        "ios": (IOS_FIRST_RUN_TOUR, r'static let checklistSubtitle = "([^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'const val CHECKLIST_SUBTITLE_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "checklist preview note",
        "kind": "string",
        "why": "the replay's line saying the sheet is a preview of the post-connect state, so its"
               " unticked rows do not read as a failed setup",
        "ios": (IOS_FIRST_RUN_TOUR, r'static let checklistPreviewNote = "([^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'const val CHECKLIST_PREVIEW_NOTE_TEMPLATE = "([^"]*)"'),
    },
    {
        "what": "checklist detectors note",
        "kind": "string",
        "why": "which detectors start on, which start off and why, and that desert mode should"
               " go back off; the same facts on both phones",
        "ios": (IOS_FIRST_RUN_TOUR, r'static let detectorsNote = "([^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'const val DETECTORS_NOTE = "([^"]*)"'),
    },
    {
        "what": "checklist location rationale (shared tail)",
        "kind": "string",
        # Each side's LEAD is literal text outside the group, so a lead that drifts matches 0
        # times; only the shared tail is compared. The leads differ by design: only iPhone needs
        # Location to keep Live Mode current in the background (docs/app-guide.md).
        "why": "the consent line under the Location request, ending on the canonical 'nothing is"
               " uploaded automatically.'; a phone that words what Location is used for"
               " differently asks for the same permission on a different promise",
        "ios": (IOS_FIRST_RUN_TOUR,
                r'static let locationRationale = "Location is optional\. it keeps Live Mode current'
                r' in the background, ([^"]*)"'),
        # Both sides are {noun} templates since 2026-09-25 (decisions R14): the tail names the
        # checklist's board ("lets the {noun} label buffered hits").
        "android": (AND_FIRST_RUN_TOUR,
                    r'const val LOCATION_RATIONALE_TEMPLATE = "Location is optional\. it ([^"]*)"'),
    },
    {
        "what": "checklist fixed row titles",
        "kind": "list",
        "why": "the checklist's fixed rows, in order; a row renamed on one phone sends a support"
               " answer to a row the other phone does not have",
        "ios": (IOS_FIRST_RUN_TOUR, r"static let checklistRowTitles = \[(.*?)\]"),
        "android": (AND_FIRST_RUN_TOUR, r"val CHECKLIST_ROW_TITLES = listOf\((.*?)\)"),
    },
    # Sample data (decisions U1): one banner, one pill word, one "new" baseline on both phones.
    # Where each word is DRAWN, and that the pill word leads, is pinned in SHARED_SHAPES below.
    {
        "what": "sample link pill word",
        "kind": "string",
        # iOS names it once on LinkChip (BeaconRadioPresentation.chipLabel reads the same
        # constant); Android writes it as linkChipAppearance's FIRST arm, so the pattern takes the
        # arm only in that slot.
        "why": "the pill that says the screen is not a live beacon; the tour's last card and"
               " both banners call it sample data, so a phone that still says DEMO names one"
               " mode two ways",
        "ios": (IOS_COMPONENTS, r'\bstatic let sampleLabel = "([^"]*)"'),
        "android": (AND_COMPONENTS, r'val label = when \{\s*demo -> "([^"]*)"'),
    },
    {
        "what": "sample banner message",
        "kind": "string",
        "why": "the banner over every tab in sample data says the rows are not nearby devices;"
               " the same words on both phones",
        "ios": (IOS_ROOT_VIEW, r'\blet sampleBannerMessage = "((?:[^"\\]|\\.)*)"'),
        "android": (AND_MAIN_SCREEN, r'\bconst val SAMPLE_BANNER_MESSAGE = "((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "status motto, first half",
        "kind": "string",
        "why": "the brand line under the radar caption (owner decision R12); the same words on both"
               " phones",
        "ios": (IOS_COMPONENTS, r'struct PunkLine: View \{.*?Text\("((?:[^"\\]|\\.)*)"\)\.foregroundStyle\(ACABTheme\.dim\)'),
        "android": (AND_STATUS_SCREEN, r'fun PunkLine\(.*?SpanStyle\(color = dim\)\) \{ append\("((?:[^"\\]|\\.)*)"\)'),
    },
    {
        "what": "status motto, second half",
        "kind": "string",
        "why": "the crimson half of the brand line under the radar caption (owner decision R12)",
        "ios": (IOS_COMPONENTS, r'struct PunkLine: View \{.*?Text\("((?:[^"\\]|\\.)*)"\)\.foregroundStyle\(ACABTheme\.accentText\)'),
        "android": (AND_STATUS_SCREEN, r'fun PunkLine\(.*?SpanStyle\(color = crimson\)\) \{ append\("((?:[^"\\]|\\.)*)"\)'),
    },
    {
        "what": "sample banner exit label",
        "kind": "string",
        "why": "the one way out of sample data, named the way the tour's last card names it;"
               " a phone that labels it differently sends the reader looking for another control",
        "ios": (IOS_ROOT_VIEW, r'\blet sampleBannerExitLabel = "((?:[^"\\]|\\.)*)"'),
        "android": (AND_MAIN_SCREEN, r'\bconst val SAMPLE_BANNER_EXIT_LABEL = "((?:[^"\\]|\\.)*)"'),
    },
    # The two offsets that make the sample Log open on "new 4 of 6" on both phones: an unflagged
    # row is first seen 2 s before the seed and the watermark sits 1 s before it, so exactly the
    # rows the seed flags new sit above it. Each pattern takes the minus sign and the flag's arm
    # as literal text, so a flipped sign or an arm that stamps every row alike stops matching.
    {
        "what": "sample unflagged first-seen offset",
        "kind": "string",
        "scale": {"ios": 1000, "android": 1},
        "unit": "ms",
        "why": "how far before the seed an unflagged sample row was first seen; with the"
               " watermark below, it decides which sample rows read new, and the two phones"
               " must open the sample Log on the same count",
        "ios": (IOS_BLE_MANAGER,
                r"flaggedNew \? seededAt : seededAt\.addingTimeInterval\(-([0-9][0-9_.]*)\)"),
        "android": (AND_BLE_MANAGER,
                    r"if \(flaggedNew\) seededAtMs else seededAtMs - ([0-9][0-9_]*)L\b"),
    },
    {
        "what": "sample seen watermark offset",
        "kind": "string",
        "scale": {"ios": 1000, "android": 1},
        "unit": "ms",
        "why": "how far before the seed the sample watermark sits; it has to fall between an"
               " unflagged row and a flagged one on both phones, or the sample New lens counts"
               " differently on each",
        "ios": (IOS_BLE_MANAGER,
                r"func sampleSeenWatermark\(seededAt: Date\) -> Date \{"
                r" seededAt\.addingTimeInterval\(-([0-9][0-9_.]*)\) \}"),
        "android": (AND_BLE_MANAGER,
                    r"fun sampleSeenWatermarkMs\(seededAtMs: Long\): Long = seededAtMs - ([0-9][0-9_]*)L\b"),
    },
    # The sample netcam is the seed's only Wi-Fi (s=1) row, so its only "ch". Keyed on the detail
    # so a row that lost "ch" on one phone reads as unreadable, not as a pass.
    {
        "what": "sample Wi-Fi row channel",
        "kind": "string",
        "why": "the sample tour's Wi-Fi channel row and its wifi_channel/wifi_band_ghz CSV cells"
               " read this value, so both phones must seed the same channel",
        "ios": (IOS_BLE_MANAGER, r'"det": "Hikvision on wifi", "ch": ([0-9]+),'),
        "android": (AND_BLE_MANAGER, r'"det":"Hikvision on wifi","ch":([0-9]+),'),
    },
    # The radar sweep (decisions M3): one turn every 4.5 s on both phones, from the clock.
    {
        "what": "radar sweep period",
        "kind": "string",
        "scale": {"ios": 1000, "android": 1},
        "unit": "ms",
        "why": "one sweep turn on both phones; iOS declares it in seconds and Android in"
               " milliseconds, and a different period reads as a different scanner",
        "ios": (IOS_COMPONENTS, r"\bstatic let sweepPeriod: TimeInterval = ([0-9][0-9_.]*)\b"),
        "android": (AND_STATUS_SCREEN, r"\bconst val RADAR_SWEEP_PERIOD_MS = ([0-9][0-9_]*)L\b"),
    },
    # The dossier (decisions U3). The case-insensitive equality each helper tests, and where each
    # is drawn, are pinned in SHARED_SHAPES; these rows compare the words.
    {
        "what": "dossier flagged line",
        "kind": "fragments",
        "why": "'Flagged by <method> over <source>.', said once when the two are the same word, and"
               " 'Heard over <source> in desert mode.' for a Desert row; the same sentences on both"
               " phones",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func dossierFlaggedLine\(type: DeviceType, methodLabel: String, sourceLabel: String\)"
                r" -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun dossierFlaggedLine\(type: DeviceType, methodLabel: String,"
                    r" sourceLabel: String\): String = when \{.*?\n\})"),
    },
    {
        "what": "dossier confidence line",
        "kind": "fragments",
        "why": "the MATCH QUALITY 'confidence' value: '<verdict> · <n>%' in three bands, and 'Not a"
               " match' for a Desert row; the same words on both phones (Android keeps the bands"
               " in verdictLabel)",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func dossierConfidenceLine\(type: DeviceType, confidence: Int\) -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun dossierConfidenceLine\(type: DeviceType, confidence: Int\): String =.*?)\n\n"
                    r"(private fun verdictLabel\(pct: Int\): String = when \{.*?\n\})"),
    },
    {
        "what": "dossier hero subtitle",
        "kind": "fragments",
        "why": "'NODE <node> · <maker>' under the dossier title, the maker dropped when it is the"
               " title; the same line on both phones",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func dossierHeroSubtitle\(node: String, makerOrVendor: String, headline: String\)"
                r" -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun dossierHeroSubtitle\(node: String, makerOrVendor: String,"
                    r" headline: String\): String =.*?)\n\n"),
    },
    {
        "what": "dossier body-cam fallback lines",
        "kind": "fragments",
        "why": "what MATCH QUALITY says about a body cam with no recognized signature; only a"
               " replayed record blames the offline buffer, in the same words on both phones",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func dossierBodyCamFallbackLine\(isReplay: Bool\) -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun dossierBodyCamFallbackLine\(replay: Boolean\): String =.*?)\n\n"),
    },
    {
        "what": "dossier nearby-device explainer",
        "kind": "fragments",
        "why": "what MATCH QUALITY says about a Desert-mode row: no signature matched, then a gloss"
               " on the firmware's address label, keyed on the same three labels on both phones",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func dossierNearbyDeviceLine\(detail: String\?\) -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun dossierNearbyDeviceLine\(detail: String\?\): String \{.*?\n\})"),
    },
    {
        "what": "tracker offline note",
        "kind": "string",
        "why": "the app's gloss under a tracker's firmware '(offline)': separated from its owner,"
               " not replayed; a phone that words it differently explains the same word two ways",
        "ios": (IOS_DETECTION_DETAIL,
                r'func trackerOfflineNote\(type: DeviceType, detail: String\?\) -> String\? \{.*?\n'
                r'    return "((?:[^"\\]|\\.)*)"\n\}'),
        "android": (AND_DETAIL_SCREEN,
                    r'internal fun trackerOfflineNote\(type: DeviceType, detail: String\?\): String\? =.*?\n'
                    r'        "((?:[^"\\]|\\.)*)"\n    else null'),
    },
    {
        "what": "matched-on method telegrams",
        "kind": "fragments",
        "why": "the Desert-mode answer and the two OUI answers in the dossier's 'matched on' row,"
               " the OUI pair quoted by the FAQ; every other method passes its own label through"
               " (pinned in SHARED_SHAPES)",
        "ios": (IOS_DETECTION_DETAIL,
                r"(func methodChipLabel\(type: DeviceType, method: DetectionMethod, maker: String\?\)"
                r" -> String \{.*?\n\})"),
        "android": (AND_DETAIL_SCREEN,
                    r"(internal fun methodChipLabel\(type: DeviceType, method: Int, maker: String\?,"
                    r" methodLabel: String\): String = when \{.*?\n\})"),
    },
    {
        "what": "signal graph floor (dBm)",
        "kind": "string",
        "why": "the WEAK edge of the dossier's fixed signal scale; a different floor on one phone"
               " draws the same history at a different height",
        "ios": (IOS_COMPONENTS, r"\blet signalGraphFloorDbm = (-?\d+)\b"),
        "android": (AND_DETAIL_SCREEN, r"\bconst val SIGNAL_GRAPH_FLOOR_DBM = (-?\d+)\b"),
    },
    {
        "what": "signal graph ceiling (dBm)",
        "kind": "string",
        "why": "the STRONG edge of the same scale",
        "ios": (IOS_COMPONENTS, r"\blet signalGraphCeilingDbm = (-?\d+)\b"),
        "android": (AND_DETAIL_SCREEN, r"\bconst val SIGNAL_GRAPH_CEILING_DBM = (-?\d+)\b"),
    },
    {
        "what": "drone operator caption",
        "kind": "string",
        "why": "the caption under a drone thumbnail that draws the operator marker; the same"
               " words on both phones",
        "ios": (IOS_DETECTION_DETAIL, r'\blet droneOperatorCaption = "((?:[^"\\]|\\.)*)"'),
        "android": (AND_DETAIL_SCREEN, r'\bconst val DRONE_OPERATOR_CAPTION = "((?:[^"\\]|\\.)*)"'),
    },
    # The Map (decisions U2 and U3). Each legend pattern is anchored on the key's first word, so a
    # reworded tail reads as a difference and a second copy reads as two matches.
    {
        "what": "map drone operator legend key",
        "kind": "string",
        "why": "the legend names the operator marker in the same words on both phones",
        "ios": (IOS_MAP_TAB, r'legendEntry\("(Drone [^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'Text\("(Drone [^"]*)", style'),
    },
    {
        "what": "map known-ALPR legend key",
        "kind": "string",
        "why": "the solid ring's key reads the same on both phones",
        "ios": (IOS_MAP_TAB, r'legendEntry\("(Known ALPR[^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'"(Known ALPR[^"]*)", hollow = true'),
    },
    {
        "what": "map lower-confidence legend key",
        "kind": "string",
        "why": "the amber ring's key reads the same on both phones",
        "ios": (IOS_MAP_TAB, r'legendEntry\("(ALPR \(lower[^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'"(ALPR \(lower[^"]*)", hollow = true'),
    },
    # The Map legend's floating info button and card (owner decision 2026-09-26, decisions R17).
    {
        "what": "map legend loading state",
        "kind": "string",
        "why": "a first known-ALPR download no longer opens the legend; the info button's spinner"
               " badge and this spoken suffix are how it shows, in the same words on both phones",
        "ios": (IOS_MAP_TAB, r'\bstatic let legendLoadingValue = "((?:[^"\\]|\\.)*)"'),
        "android": (AND_MAP_SCREEN, r'\bconst val MAP_LEGEND_LOADING_STATE = "((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "map legend close label",
        "kind": "string",
        "why": "the open legend card's close control is named the same on both phones",
        "ios": (IOS_MAP_TAB, r'accessibilityLabel\("(close map [^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'contentDescription = "(close map [^"]*)"'),
    },
    {
        "what": "map lower-confidence toggle title",
        "kind": "string",
        "why": "the Map options switch for the tier nobody could name a maker for; the legend"
               " key above and this switch have to name one tier",
        "ios": (IOS_MAP_TAB, r'Toggle\("(lower-confidence [^"]*)",'),
        "android": (AND_MAP_SCREEN, r'GroupedSwitchRow\(\s*"(lower-confidence [^"]*)",'),
    },
    {
        "what": "map lower-confidence line",
        "kind": "fragments",
        # From `one` on: the count's grouping is each language's own call (count.formatted() /
        # "%,d"), which the anchors pin, and "%,d" is not a sentence fragment.
        "why": "the line under that switch says what the tier MEANS, hidden or shown, and agrees"
               " in number; the same words on both phones",
        "ios": (IOS_MAP_TAB,
                r"func alprLowerConfidenceLine\(count: Int, showing: Bool\) -> String \{\s*"
                r"let n = count\.formatted\(\)\s*(let one = .*?\n\})"),
        "android": (AND_MAP_SCREEN,
                    r'internal fun alprLowerConfidenceLine\(.*?\): String \{\s*'
                    r'val n = String\.format\(locale, "%,d", count\)\s*(val one = .*?\n\})'),
    },
    {
        "what": "map ALL chip label",
        "kind": "string",
        "why": "the fixed first chip of the Map's category row reads the same on both phones",
        "ios": (IOS_MAP_TAB, r'chip\(nil, "([^"]*)", snap\.totalLocated\)'),
        "android": (AND_MAP_SCREEN, r'MapChipModel\(null, "([^"]*)", allCount,'),
    },
    {
        "what": "map breadcrumb toggle subline",
        "kind": "string",
        "why": "the line under the Map's phone breadcrumb trails switch says the path is the"
               " phone's and lives in memory only; the same words on both phones",
        "ios": (IOS_MAP_TAB, r'\bstatic let breadcrumbToggleSubline = "((?:[^"\\]|\\.)*)"'),
        "android": (AND_MAP_SCREEN,
                    r'\bconst val MAP_BREADCRUMB_TOGGLE_SUBLINE =\s*"((?:[^"\\]|\\.)*)"'),
    },
    # The known-ALPR callout title, ONE ROW PER TIER: the fragment set cannot see which arm a
    # sentence sits in, so a row over the whole switch would pass two tiers' titles swapped.
    {
        "what": "ALPR callout title, tier 1",
        "kind": "fragments",
        "why": "the title a mapped camera's callout reads with and without a maker; the same"
               " words for the same tier on both phones",
        "ios": (IOS_ALPR_DATASET,
                r"static func headline\(tier: UInt8, maker: String\) -> String \{\s*switch tier \{\s*"
                r"case 1:\s*(return[^\n]*\n[^\n]*)\n\s*case 2:"),
        "android": (AND_MAP_ALPR,
                    r"internal fun alprAttributionHeadline\(tier: Int, maker: String\): String ="
                    r" when \(tier\) \{\s*1 -> ([^\n]*)\n\s*2 -> "),
    },
    {
        "what": "ALPR callout title, tier 2",
        "kind": "fragments",
        "why": "the legacy-tag candidate's title, the same on both phones",
        "ios": (IOS_ALPR_DATASET,
                r"static func headline\(tier: UInt8, maker: String\) -> String \{\s*switch tier \{\s*"
                r"case 1:\s*return[^\n]*\n[^\n]*\n\s*case 2:\s*(return[^\n]*\n[^\n]*)\n\s*default:"),
        "android": (AND_MAP_ALPR,
                    r"internal fun alprAttributionHeadline\(tier: Int, maker: String\): String ="
                    r" when \(tier\) \{\s*1 -> [^\n]*\n\s*2 -> ([^\n]*)\n\s*else -> "),
    },
    {
        "what": "ALPR callout title, other tiers",
        "kind": "fragments",
        "why": "the canonical-tag title every other tier reads, the same on both phones",
        "ios": (IOS_ALPR_DATASET,
                r"static func headline\(tier: UInt8, maker: String\) -> String \{.*?"
                r"\n\s*default:\s*(return[^\n]*\n[^\n]*)\n\s*\}\n    \}"),
        "android": (AND_MAP_ALPR,
                    r"internal fun alprAttributionHeadline\(tier: Int, maker: String\): String ="
                    r" when \(tier\) \{.*?\n\s*else -> ([^\n]*)\n\}"),
    },
    # The instrument layer (decisions R16, 2026-09-26): JetBrains Mono for short instrument text,
    # sized from the platform's own text style or M3 role, so the two sides share the FACTOR and
    # the tracking, not a point size. The face itself is spelled per platform (a PostScript name
    # against a resource id) and is pinned by each side's own test (iOS TelemetryTypeTests,
    # Android TelemetryTypeTest).
    {
        "what": "telemetry scale (instrument face size / text style size)",
        "kind": "string",
        "why": "mono reads optically larger than the system face; one factor keeps the instrument"
               " text the same step under the copy beside it on both phones",
        "ios": (IOS_THEME, r"\bstatic\s+let\s+telemetryScale\s*:\s*CGFloat\s*=\s*([0-9.]+)\b"),
        "android": (AND_THEME, r"\bconst\s+val\s+TELEMETRY_SCALE\s*=\s*([0-9.]+)f\b"),
    },
    {
        "what": "telemetry tracking (uppercase instrument labels)",
        "kind": "string",
        "unit": "pt / sp",
        "why": "the spaced capitals of an uppercase label (a kicker, a ring word, a tile label); a"
               " different spacing on one phone wraps the same label at a different width",
        "ios": (IOS_THEME, r"\bstatic\s+let\s+telemetryTracking\s*:\s*CGFloat\s*=\s*([0-9.]+)\b"),
        "android": (AND_THEME, r"\bval\s+TELEMETRY_TRACKING\s*:\s*TextUnit\s*=\s*([0-9.]+)\.sp\b"),
    },
    {
        "what": "wordmark shrink floor (share of its full size)",
        "kind": "string",
        "why": "the Space Grotesk Bold \"beacons\" stays on one line and shrinks to fit, never below"
               " this share, on both phones (R16); a lower floor on one side clips the wordmark there",
        "ios": (IOS_COMPONENTS,
                r'Text\("beacons"\)\s*\.font\(Font\.custom\("SpaceGrotesk-Bold",[^\n]*\n'
                r'(?:[^\n]*\n){0,6}?\s*\.lineLimit\(1\)\s*\.minimumScaleFactor\(([0-9.]+)\)'),
        "android": (AND_ACAB_APP, r"\binternal\s+const\s+val\s+WORDMARK_MIN_FIT\s*=\s*([0-9.]+)f\b"),
    },
    # The 2026-09-26 UI review batch (decisions R19): the strings both apps settled to one wording
    # and case, each pinned at the literal a view draws.
    {
        "what": "map dimmed-pin legend key",
        "kind": "string",
        "why": "the legend names the dim treatment of a stale pin ('treatment: meaning',"
               " lowercase-first like every row) in the same words on both phones (R19 settled"
               " R17's open item)",
        "ios": (IOS_MAP_TAB, r'legendEntry\("(dimmed: [^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'LegendRow\(dimTone\(scheme\.onSurface\), "(dimmed: [^"]*)"\)'),
    },
    {
        "what": "map ring-peek legend key",
        "kind": "string",
        "why": "the legend names the wide ring of a live hit at a mapped camera in the same words"
               " on both phones (R19 settled R17's open item)",
        "ios": (IOS_MAP_TAB, r'legendEntry\("(wide ring: [^"]*)"\)'),
        "android": (AND_MAP_SCREEN, r'"(wide ring: [^"]*)", hollow = true, wide = true'),
    },
    {
        "what": "map legend qualifier words",
        "kind": "fragments",
        "why": "the legend's telemetry line ('N displayed · N retained · N markers · N outside"
               " display budget · simplified') uses iOS projectionSummary's words, lowercase, on"
               " both phones (R19); iOS's extra 'outside this view' clause names a count Android's"
               " projection does not report, so only the shared clauses are compared, in order",
        "ios": (IOS_MAP_TAB,
                r'var parts = \[("\\\(snap\.representedRows\) displayed"),\s*'
                r'("\\\(snap\.retainedLocated\) retained")\].*?'
                r'parts\.append\(("\\\(snap\.markerCount\) markers")\).*?'
                r'parts\.append\(("\\\(snap\.droppedRows\) outside display budget")\).*?'
                r'parts\.append\(("simplified")\)'),
        "android": (AND_MAP_SCREEN,
                    r'val parts = mutableListOf\(("\$displayed displayed"), ("\$retained retained")\).*?'
                    r'parts\.add\(("\$markers markers")\).*?'
                    r'parts\.add\(("\$omittedRows outside display budget")\).*?'
                    r'parts\.add\(("simplified")\)'),
    },
    {
        "what": "Detectors ALPR toggle title",
        "kind": "string",
        "why": "the ALPR detector row keeps the initialism uppercase inside lowercase-first copy"
               " ('ALPR radio signals'), the same bytes on both phones (R19)",
        "ios": (IOS_SETTINGS, r'radioToggle\("(ALPR radio [^"]*)", "flock over bluetooth'),
        "android": (AND_DEVICE_SCREEN, r'ToggleRow\("(ALPR radio [^"]*)", "flock over bluetooth'),
    },
    # Row titles are sentence case since the 2026-09-26 review (P3-11, decisions R20: the first
    # letter up, feature and company names keep their case). Each Beacon sub-screen toggle that
    # exists on both phones is one row here, anchored on the opening words of its OWN subtitle so
    # the title hole is read from the right call and a retitled row still matches; the platform-
    # only rows (iOS Live Activity counter / Hide counts on lock screen, Android Live counter
    # notification / Keep counts private on lock screen) have no twin and are not listed.
    *_toggle_title_rows(),
    {
        "what": "offline buffer erase row title",
        "kind": "string",
        "why": "the OFFLINE BUFFER card's erase row is a row title, sentence case on both phones"
               " (P3-11); it was 'buffered log' on Android and 'Buffered log' on iOS",
        "ios": (IOS_SETTINGS, r'Text\("([Bb]uffered log)"\)\.font\(ACABTheme\.font\(\.body, weight: \.medium\)\)'),
        "android": (AND_DEVICE_SCREEN, r'Text\("([Bb]uffered log)", color = Acab\.text, fontSize = 14\.sp'),
    },
    {
        "what": "Scan radios row value in sample data",
        "kind": "list",
        "why": "in the tour the Beacon tab's Scan radios row prints the echoed sample radio switches"
               " in the LIVE arm's four words (P3-8) instead of the presenter's SAMPLE DATA family,"
               " which the banner, the pill, the dot and the hero already carry; the four literals"
               " are read from the sample arms in switch order (both on, BLE only, Wi-Fi only,"
               " both off) and must match each other and the live arms (each app's own tests pin"
               " the live half: BeaconPagePolishTests, BeaconScanRadiosSampleTest)",
        "ios": (IOS_BEACON_PRESENTATION,
                r"\nfunc sampleRadiosRowValue\(bleOn: Bool, wifiOn: Bool\) -> String \{(.*?)\n\}"),
        "android": (AND_DEVICE_SCREEN, r"\n    if \(demo\) return when \{(.*?)\n    \}"),
    },
    {
        "what": "log radios-off empty state",
        "kind": "string",
        "why": "the Log's first-empty line with both radios off is two plain sentences ('Radios"
               " are off. Turn them on in Beacon.') on both phones (R19)",
        "ios": (IOS_DETECTIONS_VIEW, r'if radiosOff \{ return "((?:[^"\\]|\\.)*)" \}'),
        "android": (AND_LOG_SCREEN, r'radiosOff -> EmptyState\("((?:[^"\\]|\\.)*)", null\)'),
    },
    {
        "what": "sample tour kicker",
        "kind": "string",
        "why": "the tour names itself with the mono kicker beside Skip on both phones (R19,"
               " review P2-16)",
        "ios": (IOS_FIRST_RUN_TOUR, r'Kicker\("(SAMPLE DATA [^"]*)"\)'),
        "android": (AND_FIRST_RUN_TOUR, r'\binternal const val SAMPLE_TOUR_KICKER = "([^"]*)"'),
    },
    {
        "what": "sample tour card 1 note",
        "kind": "string",
        "why": "the first tour card names the post-connect sheet 'the setup checklist', the one"
               " name Help and the FAQ use (R19, review P2-13); the same bytes on both phones",
        "ios": (IOS_FIRST_RUN_TOUR, r'note: "(sample settings are safe[^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'"(sample settings are safe[^"]*)",'),
    },
    {
        "what": "sample tour card 3 body",
        "kind": "string",
        "why": "the last tour card names the Exit Sample Data banner in plain words on both"
               " phones (R19, review P2-14)",
        "ios": (IOS_FIRST_RUN_TOUR, r'body: "(an Exit Sample Data banner[^"]*)"'),
        "android": (AND_FIRST_RUN_TOUR, r'"(an Exit Sample Data banner[^"]*)",'),
    },
    {
        "what": "Live Mode sample preview sentence",
        "kind": "string",
        "why": "in sample data the Live Mode page says the switch is a preview in the same"
               " sentence on both phones (R19, review P2-12)",
        "ios": (IOS_SETTINGS, r'case "Preview on": return "((?:[^"\\]|\\.)*)"'),
        "android": (AND_DEVICE_SCREEN,
                    r'\binternal const val LIVE_MODE_PREVIEW_NOTE =\s*"((?:[^"\\]|\\.)*)"'),
    },
    {
        "what": "dossier related-help push title",
        "kind": "string",
        "why": "the screen the dossier's Related help pushes to is named 'Help + support' like"
               " every other route to it, so the screen reader announces one name (R19, review"
               " P1-5)",
        "ios": (IOS_HELP_VIEW, r'\.navigationTitle\("(Help [^"]*)"\)'),
        "android": (AND_DETAIL_SCREEN, r'\binternal const val DOSSIER_HELP_TITLE = "([^"]*)"'),
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
    # The row-title fallback (decisions U3-d): what a Log row, the Status nearest card and the
    # dossier headline say when the only name is the bare category. label itself stays the
    # CSV / GPX type column; Detection.titleName (pinned in SHARED_SHAPES) picks between them.
    ("titleFallback", IOS_DEVICE_TYPE, _ios_arm_block("titleFallback"),
     r'return "([^"]*)"', r"\breturn\b",
     AND_DEVICE_TYPE, _and_arm_block("titleFallback", "this"), r'->\s*"([^"]*)"', r"->"),
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
    byte-identity, so pin the claim. Detection.vendor (the dossier's vendor line per category),
    BodyCamSignature.vendor (the maker behind each body-cam signature) and DeviceType.titleFallback
    (a row title when the only name is the bare category, "body cam" and "network camera" among
    the title-case words) are the same shape and are pinned the same way.

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

# The shipped FAQ answer that promises the desert restore rule to the user, as a needle for the
# rule below. It used to be pinned in TWO answers, the alerts answer and the desert-mode answer,
# word for word; the owner asked for a shorter alerts answer (2026-09-30), so the promise now lives
# once, in the desert-mode answer, and the alerts answer points there. Built with re.escape from
# the sentences THEMSELVES, never hand-written as a pattern: a hand-written one drifts into
# matching a reworded promise, and the promise is the point. The two faq-content.json copies are
# already asserted byte-identical (check_faq_copies), so this is the other half of that guard:
# identical copies that both stopped saying it still pass byte equality.
#
# THE PROMISE IS SCOPED, and the scoping is the promise, not hedging. "if this phone saved a
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
    ("the desert-mode answer still promises an offer, not an automatic restore",
     re.escape("deduplication, and rate limits still apply. desert mode sets the board to silent"
               " while it runs. turning desert mode off yourself restores your previous alert"
               " mode, unless you picked a mode by hand (including silent) while desert mode was"
               " running. when the board ends desert mode on its own (after a factory reset, on an"
               " older board, or because another paired phone ended it), the app doesn't change"
               " your alert mode. if this phone saved a mode when desert mode started, the app"
               " offers to restore it: a Restore Alerts control appears on the desert card under"
               " Beacon, and under alerts when that section is shown. nothing changes until you"
               " tap it. the offer stays after app restarts. it moves to the top of the Beacon tab"
               " when board controls are unavailable, and to the connect screen when the app is"
               " scanning for a beacon again, so you can tap it with the beacon off or not"
               " connected.")),
)

# The checklist's state sentences both phones draw byte for byte (decisions U2-a), for the
# "checklist state sentences" rule below. Written ONCE here and turned into one quoted-literal
# needle per side with re.escape, so each side has to carry the same bytes: a sentence reworded on
# one phone fails that phone's needle. The platform-specific arms are pinned per side in the rule.
# The two that name the board are TEMPLATES (decisions R14); the rule also pins that each side
# renders every {noun} sentence with the checklist's kind, never draws it raw.
_CHECKLIST_SHARED_SENTENCES = (
    "optional; not decided yet",
    "off until you choose categories under Beacon",
    "active on supported system surfaces",
    "off by choice; change it later under Beacon",
    "ready to start with this {noun}",
    "on; the {noun} retains hits while this phone is away",
    "off; turn it on under Beacon if you want away-time hits retained",
)
# Shared sentences with the PLATFORM WORD as their one hole ("iOS" / "Android"), each needle
# built from the template with that side's word filled in, so the rest is still one set of bytes.
_CHECKLIST_BLOCKED_TEMPLATE = (" chosen, but {} is blocking them; turn notifications on for"
                               " beacons in Settings")
_NOTIFY_EXPLAINER_SAMPLE = ("Preview which categories you could enable. Nothing is saved and {}"
                            " won't ask permission.")
_NOTIFY_EXPLAINER_REAL = ("Pick what's worth a notification. Every category is off until you turn"
                          " it on, and {} asks permission the first time you do.")

# The Beacon tab's one-line group intros (decisions R13, 2.0.8's "BEACON HARDWARE" block), which
# both apps draw byte for byte under a group's header. Written ONCE here, as the checklist
# sentences above are, so a sentence reworded on one app fails that app's needle. Each pair is the
# full line and its short variant: the ON THE BOARD line without "alerts" on a mesh board (no
# buzzer, so no Alerts row), the help line without "setup checks" in the sample tour (no System
# readiness row). The notifications line has the device word as its one hole: iOS fills it with
# thisDeviceName ("iPhone" / "iPad"), Android with deviceWord ("phone" / "tablet"), the same hole
# the hardware note's "This ...'s preferences remain available." already has.
_BEACON_INTRO_SCAN = "radios, detectors, desert mode, and the offline buffer."
_BEACON_INTRO_BOARD = ("alerts, the board light, firmware, and managed devices.",
                       "the board light, firmware, and managed devices.")
_BEACON_INTRO_NOTIFY_TEMPLATE = "notifications, Live Mode, and display for this {}."
_BEACON_INTRO_HELP = ("setup checks, help, support, and about this app.",
                      "help, support, and about this app.")


def _quoted(sentence):
    """A needle for `sentence` written as one whole string literal, quotes included."""
    return '"' + re.escape(sentence) + '"'


SHARED_SHAPES = (
    {
        "what": "kicker captions may always wrap (neither side hugs its ideal width)",
        "why": "a kicker is drawn inside rows that cannot refuse an oversized child, and several"
               " are fed RUNTIME strings: the Beacon tab's Scan radios row prints"
               " radioPresentation.scanLabel (sampleRadiosRowValue in the tour, P3-8), 14-25 chars"
               " in every steady state but 39 while a"
               " firmware update runs and 39 again while the link is reconnecting. iOS hugged its"
               " ideal width and the whole Beacon page went wider than the screen mid-update,"
               " clipped on BOTH edges, because the .frame(maxWidth: .infinity) above it CENTERS"
               " an oversized child instead of clamping it. That hug has now broken the layout"
               " twice, once along font size and once along string length, so neither platform"
               " may reintroduce a width hug or a single-line clamp on this component",
        "sides": (
            ("iOS", IOS_THEME, None,
             (("kicker wraps rather than hugging",
               r"^\s*\.fixedSize\(horizontal: false, vertical: true\)"),
              # Anchored at the start of a code line so the cautionary comment above it, which
              # quotes the banned modifier verbatim, is not itself read as a reintroduction.
              ("no width hug", r"^\s*\.fixedSize\(horizontal: (?:true|!)", 0),
              ("no single-line clamp", r"^\s*\.lineLimit\(", 0))),
            ("Android", AND_COMPONENTS, r"(fun Kicker\(text: String.*?\n\})",
             (("no single-line clamp", r"\bmaxLines\b", 0),
              ("wrapping left on", r"\bsoftWrap\s*=\s*false", 0))),
        ),
    },
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
              # The premise of the narrowing: the row the copy sends the user to. The Beacon list
              # is presenter-driven (beaconRows, one call per file), so the gate is pinned in two
              # halves: the fact the caller hands over, and the line that drops the row. A caller
              # that hard-codes `meshBoard: false`, or a presenter that appends Alerts
              # unconditionally, fails one of them.
              ("and the Beacon presenter is handed the mesh fact",
               r"meshBoard: ble\.status\?\.isMeshDetect == true\b"),
              ("and the Alerts row it points at is mesh-gated",
               r"if !meshBoard \{ rows\.append\(\.alerts\) \}"))),
            ("Android Desert card", AND_DEVICE_SCREEN, None,
             (("saw-Desert reads the run flag", r"sawDesertOn = desertRanThisRun\b"),
              ("desert reads the card's own toggle", r"desertOn = desertOn\b"),
              ("silent means SILENT, not VIBRATE",
               r"alertsSilent = shownAlertMode == AlertMode\.SILENT\b"),
              ("mesh-detect is excluded", r"isMeshDetect = status\?\.isMeshDetect == true"),
              ("the pinned string is what it draws", r"Text\(DESERT_SILENCE_NOTICE,"),
              ("and the Beacon presenter is handed the mesh fact",
               r"meshBoard = status\?\.isMeshDetect == true\b"),
              # The row lists are memoised; the mesh fact is a key, so a board that turns out to
              # be mesh-detect after the first frame drops its Alerts row on the next pass.
              ("and the row memo re-runs when that fact changes",
               r"remember\(status\?\.isMeshDetect == true, showBanner, demo,"),
              ("and the Alerts row it points at is mesh-gated",
               r"if \(!meshBoard\) add\(BeaconRowId\.ALERTS\)"))),
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
            # copy above the cross-cutting banners at both widths, then the Board / This phone
            # control in compact width (Route A C13; it was above the stats) or the hero and the
            # two columns in regular width (the final-review order, which is Android's twoCol
            # order too), the connect screen's copy above the setup and scan
            # panels. iOS
            # used to draw its copy after the stats grid, hanging off the board-unavailable notice,
            # while Android led its slot list with it - the same silence reported in two different
            # places. The needles below span the neighbour each one leads, so a copy that slides
            # back down the page fails here rather than in a screenshot nobody takes.
            #
            # THE PRE-CONNECT CALL SITES ARE PINNED TOO, on the three sides after the two below
            # (RootView.swift and ConnectView.swift on iOS, AcabApp.kt on Android), so the render
            # sites themselves are held, not only everything they call. It matters because deleting
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
              ("a copy LEADS the compact page while the board is away, above the cross-cutting"
               " banners",
               r"if desertRestoreNeedsDetachedSurface\(restoreOffered: alertRestoreOffered,\n"
               r"\s*boardControlsAvailable: hardwareControlsEnabled\) \{\n"
               r"\s*AlertRestorePanel\(\)\n\s*\}\n\s*crossCuttingBanners"),
              # The regular-width twin is pinned from the page's own stack down to the split: the
              # gate is the FIRST child of that stack (only comment lines before it), then the
              # banners, the hero and the two columns in that order, which is Android's twoCol
              # order behind its own leading panel. A panel that slides below the banners or the
              # hero fails here, and so does anything new drawn above it. The hero is a bare
              # rowView since decisions R13: it draws its own crimson-edged card (BeaconCard), so
              # it no longer rides a .groupedCell() the way the plain Route A cell did.
              ("and leads the regular-width page too, above the banners, the hero and the"
               " two-column split",
               r"ScrollView \{\n\s*VStack\(alignment: \.leading, spacing: 16\) \{\n"
               r"(?:\s*//[^\n]*\n)*"
               r"\s*if desertRestoreNeedsDetachedSurface\(\n\s*restoreOffered: alertRestoreOffered,\n"
               r"\s*boardControlsAvailable: hardwareControlsEnabled\) \{\n"
               r"\s*AlertRestorePanel\(\)\n\s*\}\n\s*crossCuttingBanners\n"
               r"\s*rowView\(\.hero\)\n"
               r"\s*HStack\(alignment: \.top, spacing: 14\) \{", 1),
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
    # Decisions R15 (2026-09-26), the owner's middle ground for the startup screen: the passive
    # idea was said at the top AND the bottom, so it is now said once, in the scope footnote; and
    # the "already paired to another phone?" note left the idle screen for the connection-failure
    # panel. The words are compared in SHARED_CONSTANTS ("connect scope footnote", "connect failure
    # pair-window note"); this holds WHERE they are drawn.
    {
        "what": "connect screen says passive once, and the pair-window note only after a failure",
        "why": "the owner asked for the passive statement once per screen (R15); a second passive"
               " sentence, or the pair-window note back on the idle screen, is the busier screen"
               " the owner turned down",
        "sides": (
            # A string literal (not a comment line) that says passive / jams / spoofs /
            # interferes, any case: exactly the footnote's one declaration.
            ("iOS connect screen", IOS_CONNECT_VIEW, None,
             (("one passive statement, the scope footnote",
               r'^(?!\s*(?://|\*|/\*))[^\n]*"[^"\n]*(?i:passive|jams?\b|spoofs?\b|interferes)[^"\n]*"'),
              ("the pair-window note is drawn from one call site", r"\bpairWindowNote\(kind\)"))),
            ("iOS failure panel", IOS_CONNECT_VIEW,
             r"private func connectionFailurePanel\(.*?\n    \}",
             (("and that call site is the connection-failure panel", r"\bpairWindowNote\(kind\)"),)),
            ("Android connect screen", AND_ACAB_APP, None,
             (("one passive statement, the scope footnote",
               r'^(?!\s*(?://|\*|/\*))[^\n]*"[^"\n]*(?i:passive|jams?\b|spoofs?\b|interferes)[^"\n]*"'),
              ("the pair-window note is drawn from one call site", r"\bPairWindowNote\(kind\)"))),
            ("Android failure panel", AND_ACAB_APP,
             r"private fun ConnectionHintPanel\(.*?\n\}",
             (("and that call site is the connection-failure panel", r"\bPairWindowNote\(kind\)"),)),
        ),
    },
    # The row above holds WHERE the note is drawn; this one holds WHEN. Both panels ask the same
    # predicate of the hint's stage, and each suite pins it (iOS
    # OnboardingPolicyTests.testPairWindowNoteShowsOnlyForLinkAndPairingStages, Android
    # OnboardingRecoveryPolicyTest.pairWindowNoteShowsOnlyForLinkAndPairingStages), but a stage
    # flipped on one phone together with that phone's test would keep both suites green. The
    # switch is exhaustive on each side, so a new stage cannot compile without an arm; the arm
    # count below stops a third arm from splitting a stage off without this row noticing.
    {
        "what": "pair-window note stages (LINK and PAIRING show it, PROFILE and SECURE_SETUP do not)",
        "why": "the note tells the user to power-cycle for a second phone's pairing window; under a"
               " wrong-profile or secure-setup failure it sends them to do that for nothing, and"
               " missing under a link or pairing failure it hides the one recovery that works",
        "sides": (
            ("iOS", IOS_BLE_MANAGER,
             r"(func showsPairWindowNote\(for stage: ConnectFailureStage\) -> Bool \{.*?\n\})",
             (("link and pairing show the note", r"^\s*case \.link, \.pairing:\n\s*return true$"),
              ("profile and secure setup do not",
               r"^\s*case \.profile, \.secureSetup:\n\s*return false$"),
              ("no other arm", r"^\s*(?:case\b|default:)", 2))),
            ("Android", AND_BLE_MANAGER,
             r"(internal fun showsPairWindowNote\(stage: ConnectFailureStage\): Boolean ="
             r" when \(stage\) \{.*?\n\})",
             (("LINK and PAIRING show the note",
               r"^\s*ConnectFailureStage\.LINK, ConnectFailureStage\.PAIRING -> true$"),
              ("PROFILE and SECURE_SETUP do not",
               r"^\s*ConnectFailureStage\.PROFILE, ConnectFailureStage\.SECURE_SETUP -> false$"),
              ("no other arm", r"->", 2))),
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
              # The offline filter is a lens axis of its own since C10 (the tune menu), so a
              # seed that kept it would show a category's replayed rows only.
              ("offline filter cleared", r"\bofflineOnly = false\b"),
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
              ("offline filter seeds from the filter",
               r"var offlineOnly by rememberSaveable \{ mutableStateOf\(initialFilter is"
               r" LogFilter\.OfflineOnly\) \}"),
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
        "what": "Log Active segment draws no time-section header (all and new keep the three)",
        # Owner decision L6 (2026-09-24): every row under Active was heard in the last 45 s, so a
        # "heard in the last 45 s" header only repeats the segment. Both pure builders return ONE
        # untitled section for Active, first thing, before any per-row work; both lists skip the
        # header for an untitled section; and both memos key on the scope, because two segments
        # can cut EQUAL lists (sample data, where every row is active) and only the scope then
        # says whether the untitled arm applies. Each suite pins the builder with its own frames
        # (DetectionLogLensTests / LogExportLensTest); this rule is the half neither suite sees:
        # that the scope still reaches the builder and that the list still honours a nil title.
        "why": "the Log reads the same on both phones: an Active segment with no header, All and"
               " New with 'heard in the last 45 s', 'earlier today' and 'older'. A phone that"
               " drops the scope from the builder or its memo draws the redundant header again,"
               " and one that draws a header for an untitled section draws an empty one",
        "sides": (
            ("iOS builder", IOS_DETECTIONS_VIEW, None,
             (("Active returns one untitled section, before any per-row work",
               r"calendar: Calendar\) -> \[LogSection\] \{\n"
               r"\s*if scope == \.active \{ return shown\.isEmpty \? \[\] :"
               r" \[LogSection\(title: nil, rows: shown\)\] \}"),
              ("the one call hands it the segment",
               r"logSections\(shown, scope: scope, activeIDs: activeIDs,"),
              ("and the memo re-runs when the segment changes",
               r"let key = SectionsKey\(lens: lensGeneration, feed: feedGeneration, k: k,"
               r" scope: scope,"),
              ("an untitled section draws no header",
               r"\} header: \{\n\s*if let title = section\.title \{\n"
               r"\s*Kicker\(title\)"))),
            ("Android builder", AND_LOG_SCREEN, None,
             (("Active returns one untitled section, before any per-row work",
               r"zone: ZoneId,\n\): List<LogSection> \{\n"
               r"\s*if \(scope == LogScope\.Active\) return if \(shown\.isEmpty\(\)\) emptyList\(\)"
               r" else listOf\(LogSection\(null, shown\)\)"),
              ("the one call hands it the segment",
               r"logSections\(shown, scope, activeIds,"),
              ("and the memo re-runs when the segment changes",
               r"val sections = remember\(shown, scope, activeIds,"),
              ("an untitled section draws no header",
               r"val title = section\.title\n\s*if \(title != null\) \{\n"
               r"\s*stickyHeader\("))),
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
              # Two hops from the presenter to the pill: the top bar is handed the word, and
              # the chip draws it. `linkStateLabel = null` at the first hop compiles (the
              # parameter is nullable) and blanks the pill.
              ("the top bar is handed that word", r"\blinkStateLabel = linkStateLabel\b"),
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
             # The sample word is LinkChip.sampleLabel, whose literal the constants row "sample
             # link pill word" compares with Android's linkChipAppearance arm.
             (("sample mode", r'case "SAMPLE DATA":\s*return LinkChip\.sampleLabel\s*$'),
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
            # kicker and the hero, beaconRadioStatusLabel feeds the Scan radios row (in sample data
            # its demo arm prints the live arm's words, P3-8, pinned by the constants row "Scan
            # radios row value in sample data"). Both take it
            # as a named Boolean with a default, so `rebootingForUpdate = false` at either call
            # site compiles and drops the arm on that surface alone, leaving this tab reading
            # CONNECTED · WAITING FOR BOARD STATUS through a reboot the iPhone names. Since Route
            # A the tab also draws the Status pill (C7), from statusLinkChipLabel with the frame
            # gate written inline; since decisions R13 that pill sits in the hero's footer, as on
            # iOS, rather than in the top bar, so the tab still draws ONE pill and the count is 3; a statusScanPresentation call
            # on this tab would make it 4 and is not allowed (contracts 11.3 S8).
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
             (("both presenters and the hero's link pill on the tab are handed the update reboot",
               r"rebootingForUpdate = rebootingForUpdate,", 3),
              ("the pill is the shared presenter's word",
               r"val beaconLinkStateLabel = statusLinkChipLabel\("),
              ("and the scan presenter is not called here", r"statusScanPresentation\(", 0),
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
    # The Status radar's size (decisions R12): the owner cut it by a quarter on 2026-09-25. Two
    # numbers and a min, which no one-literal row carries, and iOS writes them as CGFloat statics
    # while Android writes a Float and a Dp, so each side pins its own spelling of the same rule.
    {
        "what": "status radar side is 0.75 of the column, capped at 315 (pt / dp)",
        "why": "the owner asked for the radar about 25% smaller so the caption, the motto and more"
               " of the strip reach the first screen; a different fraction or cap on one phone"
               " draws a different-sized instrument, and a side that stops using the rule (or a"
               " Status screen that stops calling it) brings the whole-column radar back",
        "sides": (
            ("iOS RadarSideLayout", IOS_COMPONENTS,
             r"\nstruct RadarSideLayout: Layout \{(.*?)\n\}",
             (("the fraction", r"^    static let fraction: CGFloat = 0\.75$"),
              ("the cap", r"^    static let cap: CGFloat = 315$"),
              ("side = min(column x fraction, cap)",
               r"return max\(0, min\(width \* fraction, cap\)\)"),
              ("the subview is proposed that square",
               r"proposal: ProposedViewSize\(width: side, height: side\)"))),
            ("iOS Status", IOS_DASHBOARD_VIEW, None,
             (("the radar sits in RadarSideLayout",
               r"^\s*RadarSideLayout \{\n\s*RadarScope\(count: snapshot\.total,"),)),
            ("Android", AND_STATUS_SCREEN, None,
             (("the fraction", r"^internal const val STATUS_RADAR_SIDE_FRACTION = 0\.75f$"),
              ("the cap", r"^internal val STATUS_RADAR_MAX_SIDE: Dp = 315\.dp$"),
              ("side = min(column x fraction, cap)",
               r"minOf\(column \* STATUS_RADAR_SIDE_FRACTION, STATUS_RADAR_MAX_SIDE\)"),
              ("the Status radar is handed that side", r"side = statusRadarSide\(maxWidth\)\)"),
              ("RadarScope draws a square that side wide",
               r"^\s*\.width\(side\)\n\s*\.aspectRatio\(1f\)$"))),
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
        "what": "main-Map breadcrumb trails are OFF by default (a stored choice still wins)",
        # Owner decision B1 (2026-09-24). Each side pins the default where it is declared, the one
        # read of the stored preference that falls back to it, and the key, so a second read with
        # its own literal default, or a renamed key that silently resets every user's choice,
        # fails here. Collection is not part of this rule and is unchanged: the dossier still
        # draws a tracker's trail whatever this toggle says. Each suite pins its own constant
        # (MapPinRulesTests / MapProjectionTest); this is the half that compares the two.
        "why": "a user's own or a family member's tag (a Tile, a Samsung tag, a partner's AirTag)"
               " rides along all day, and a default-on trail draws it across the main Map as if"
               " it were following them. A phone that defaults it on again draws that on one"
               " platform only, and the FAQ can describe one default",
        "sides": (
            ("iOS Map", IOS_MAP_TAB, None,
             (("the default is off", r"static let showBreadcrumbsDefault = false\b"),
              ("the stored choice falls back to that default",
               r'@AppStorage\("map\.showBreadcrumbs"\) private var showBreadcrumbs ='
               r" MapTabView\.showBreadcrumbsDefault\b"),
              ("and nothing else reads the key", r'"map\.showBreadcrumbs"'))),
            ("Android Map", AND_MAP_SCREEN, None,
             (("the default is off", r"internal const val MAP_SHOW_BREADCRUMBS_DEFAULT = false\b"),
              ("the stored choice falls back to that default",
               r'mapPrefs\.getBoolean\("show_breadcrumbs", MAP_SHOW_BREADCRUMBS_DEFAULT\)'),
              ("and nothing else reads the key", r'getBoolean\("show_breadcrumbs"'))),
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
        "what": "dossier shape (one panel order; Copy MAC outside Technical details; the capture"
                " note closes MATCH QUALITY)",
        "why": "docs/app-guide.md names dossier panels by where they sit, and the order is one"
               " order on both phones: Watch and Mute at the top with the match caveats right"
               " under them, Related help and Technical details closing the page, Copy MAC"
               " Address the last control. A panel that moves on one phone makes that sentence"
               " false on the other. Copy MAC Address is the sharp one: an address is what gets"
               " handed to a reporter or a records request, so it may not sit behind a collapsed"
               " section on either phone",
        # ONE ORDER, both sides pinned joint by joint (Route A C12, contracts 6.1): the hero, Watch
        # and Mute with any mute rule's rows, MATCH QUALITY, the experimental note, CONFIRM IT,
        # SIGNAL, the sightings row, the map, Seen with you, Related help, Technical details, then
        # Copy MAC Address last and outside the disclosure. iOS still carries the canonical list in
        # its body; the Android needles pin the same joints in the same sequence, so each joint
        # is held on both phones. The firmware's capture note stays folded into MATCH QUALITY.
        "sides": (
            ("iOS body", IOS_DETECTION_DETAIL, r"var body: some View \{(.*?)\n    \}",
             (("the hero, Watch and Mute, then match quality",
               r"titleBlock" + _KT_ARM_GAP + r"primaryActions" + _KT_ARM_GAP + r"matchQualityPanel"),
              ("match quality, the experimental note, CONFIRM IT, then signal",
               r"matchQualityPanel" + _KT_ARM_GAP
               + r"if d\.type\.isExperimental \{ experimentalNote \}" + _KT_ARM_GAP
               + r"if showConfirmIt \{ confirmItPanel \}" + _KT_ARM_GAP + r"signalPanel"),
              ("signal, the stat grid, location, then follow",
               r"signalPanel" + _KT_ARM_GAP + r"statGrid" + _KT_ARM_GAP
               + r"if let coord = mapCoordinate \{ locationPanel\(coord\) \}" + _KT_ARM_GAP
               + r"followPanel"),
              ("follow, Related help, Technical details, then Copy MAC last",
               r"followPanel" + _KT_ARM_GAP + r"relatedHelpPanel" + _KT_ARM_GAP
               + r"identityDisclosure" + _KT_ARM_GAP + r"copyButton"))),
            ("iOS Technical details", IOS_DETECTION_DETAIL,
             r"private var identityDisclosure: some View \{(.*?)\n    \}",
             (("Copy MAC is not inside the disclosure", r"copyButton", 0),)),
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
             (# The mute rule's rows close the Watch and Mute child, so this span is the joint
              # between the decisions and what the match rests on.
              ("Watch and Mute, then match quality",
               r"muteRule\?\.let \{ rule ->\s*\n\s*MutedStateRows\("
               r"(?:(?!Panel\()[\s\S])*?MatchQualityPanel\(d\)"),
              ("match quality, the experimental note, then CONFIRM IT",
               r"MatchQualityPanel\(d\)" + _KT_ARM_GAP
               + r"if \(d\.type\.isExperimental\) ExperimentalNote\(d\.type\)" + _KT_ARM_GAP
               + r"if \(d\.isOuiMatch \|\| d\.confidence < 50\) \{\s*\n\s*ConfirmItPanel\("),
              # The signal header's word in the middle is what makes this needle's NAME true.
              # Android's signal section is an inline Column, not a `*Panel(` call, so the panel-gap
              # span alone would say only that no OTHER panel sits between CONFIRM IT and the stat
              # grid: with the whole signal block deleted it would still match. The header's
              # SAMPLE / STALE / LIVE word (dossierSignalWord, computed then drawn) is that
              # section's own header, so it binds the slot.
              ("CONFIRM IT, the signal section, then the stat grid",
               r"ConfirmItPanel\((?:(?!Panel\()[\s\S])*?"
               r"val signalWord = dossierSignalWord\(demo = demo, stale = stale\)"
               r"(?:(?!Panel\()[\s\S])*?Text\(signalWord,"
               r"(?:(?!Panel\()[\s\S])*?StatGrid\("),
              ("the stat grid, then location",
               r"StatGrid\((?:(?!Panel\()[\s\S])*?LocationPanel\(d, lat, lon"),
              ("location, then follow",
               r"LocationPanel\(d, lat, lon, breadcrumbTrail, onOpenInMap,"
               r" headerStacked = actionsStacked\)\s*\n\s*\}\s*\n\s*"
               r"if \(d\.type == DeviceType\.TRACKER\) FollowEvidencePanel\("),
              ("follow, then Related help",
               r"FollowEvidencePanel\(d\.id, d\.type, ble, timeBasis\)"
               r"(?:(?!Panel\()[\s\S])*?RelatedHelpPanel\(d\)"),
              ("Related help, then Technical details",
               r"RelatedHelpPanel\(d\)(?:(?!Panel\()[\s\S])*?DisclosureSection\(\s*"
               r'title = "Technical details"'),
              ("and Copy MAC last, after the disclosure closes",
               r"\n            \}" + _KT_ARM_GAP + r"CopyMacButton\(d\.mac\)"),
              ("the separate capture-note panel is gone", r"FirmwareDetailNote", 0))),
            ("Android Technical details", AND_DETAIL_SCREEN,
             r'DisclosureSection\(\s*title = "Technical details",(.*?)\n            \}',
             (("Copy MAC is not inside the disclosure", r"CopyMacButton", 0),
              ("the capture note renders again as the Detail row",
               r'd\.detail\?\.takeIf \{ it\.isNotEmpty\(\) \}\?\.let \{ add\("Detail" to it\) \}'))),
            ("Android match quality", AND_DETAIL_SCREEN,
             r"private fun MatchQualityPanel\(d: Detection\) \{(.*?)\n\}",
             (# Exact, with no trailing argument: the M3 section label, as on every other flat
              # section of this screen.
              ("the panel's kicker", r'SectionLabel\("MATCH QUALITY"\)'),
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
               r"\} else \{\s*\n\s*mapThumbnail\(coord\)[\s\S]*?\n\s*\}\s*\n\s*"
               r'if hasTrackerTrail \{\s*\n\s*Label\("Phone breadcrumb trail'),
              ("and it renders once", r'"Phone breadcrumb trail · this session"'))),
            ("Android breadcrumb caption", AND_DETAIL_SCREEN,
             r"private fun LocationPanel\((.*?)\n\}",
             # Open in Map is the pill inside the same Box as the AndroidView, so a span from it to
             # the caption's trail gate crosses the whole thumbnail and fails if the caption moves
             # above it.
             (("the caption sits under the thumbnail",
               r'"Open in Map"[\s\S]*?'
               r"if \(breadcrumbTrail\.count \{ validCoord\(it\.first, it\.second\) \} >= 2\)"),
              ("and it renders once", r'"Phone breadcrumb trail · this session"'))),
        ),
    },
    # ---- decisions U1: sample data says the same thing, and counts the same rows, on both ----
    {
        "what": "one sample banner and one pill word (drawn from the pinned constants)",
        "why": "the constants rows compare the banner and pill words; these needles hold that each"
               " phone DRAWS them, so a view that goes back to its own literal cannot pass on a"
               " constant nothing renders",
        "sides": (
            ("iOS banner", IOS_ROOT_VIEW, None,
             (("the banner draws the message", r"\bText\(sampleBannerMessage\)"),
              ("and its one button", r"\bButton\(sampleBannerExitLabel\) \{ ble\.exitDemo\(\) \}"))),
            ("iOS pill", IOS_COMPONENTS, None,
             (("the pill reads the sample word first",
               r'let label = demo \? Self\.sampleLabel : stateLabel \?\?'),
              # R19 (review P2-18): the pill's mark is a small filled circle, a state light;
              # Android draws the same DOT for sample data instead of its fault triangle.
              ("its mark is an 8pt filled circle",
               r'Circle\(\)\.fill\(ink\)\s*\n\s*\.frame\(width: 8, height: 8\)'))),
            ("Android banner", AND_MAIN_SCREEN, None,
             (("the banner draws the message", r"\bAcabBanner\(SAMPLE_BANNER_MESSAGE,"),
              ("and its one button", r"\{ Text\(SAMPLE_BANNER_EXIT_LABEL\) \}"))),
            ("Android pill", AND_COMPONENTS, None,
             (("sample data takes the dot mark, before the attention triangle",
               r'demo -> LinkChipMark\.DOT\s*\n\s*tone == LinkChipTone\.ATTENTION -> LinkChipMark\.WARNING'),)),
        ),
    },
    {
        "what": "sample data opens one new baseline (the seed's flagged rows; Mark Seen in memory"
                " only; leaving the Log never marks sample rows seen)",
        "why": "the sample Log opens on the same 'new' count on both phones, Mark Seen empties it"
               " without touching the real watermark on disk, and switching tabs does not quietly"
               " mark the tour's rows seen on one phone only",
        "sides": (
            ("iOS seed", IOS_BLE_MANAGER, None,
             (("each row's first-seen comes from its flag",
               r"firstSeenAt\[d\.id\] = sampleFirstSeen\(flaggedNew: d\.isNew, seededAt: seededAt\)"),
              ("and the watermark sits between the two",
               r"\bseenWatermark = sampleSeenWatermark\(seededAt: seededAt\)"))),
            ("iOS Mark Seen", IOS_BLE_MANAGER, r"\n    func markAllSeen\(\) \{(.*?)\n    \}",
             (("moves the watermark in memory, then stops before disk in sample data",
               r"\bseenWatermark = now\b[\s\S]*?"
               r"guard seenWatermarkWritesAllowed\(isDemoMode: demoMode\) else \{ return \}\s*\n\s*"
               r"defaults\.set\(now\.timeIntervalSince1970, forKey: watermarkKey\)"),)),
            ("iOS first-run baseline", IOS_BLE_MANAGER,
             r"\n    func seedSeenWatermarkOnce\(\) \{(.*?)\n    \}",
             (("never runs in sample data, before it reads the once-only flag",
               r"^\s*if demoMode \{ return \}\s*\n\s*guard !defaults\.bool\(forKey: seenWatermarkSeededKey\)"),)),
            ("iOS leaving the Log", IOS_ROOT_VIEW, None,
             (("marks seen only outside sample data",
               r"func logTabLeaveMarksSeen\(isDemoMode: Bool\) -> Bool \{ !isDemoMode \}"),
              ("and the tab switch asks it",
               r"if old == 2 && new != 2 && logTabLeaveMarksSeen\(isDemoMode: ble\.demoMode\) \{\s*\n\s*"
               r"ble\.markAllSeen\(\)"),
              ("and nothing else here marks seen", r"markAllSeen\(\)", 1))),
            ("iOS Log tools", IOS_DETECTIONS_VIEW,
             r"private func logToolsMenu\(_ snap: LogSnapshot\) -> some View \{(.*?)\n    \}",
             (("Mark Seen is offered ungated, right after Select",
               r'Label\("Select", systemImage: "checkmark\.circle"\) \}\s*\n\s*'
               r"Button \{ markSeen\(\) \} label:"),)),
            ("Android seed", AND_BLE_MANAGER, None,
             (("each row's first-seen comes from its flag",
               r"firstSeenAt\[d\.id\] = sampleFirstSeenMs\(d\.isNew, now\)"),
              ("and the watermark sits between the two",
               r"_seenWatermark\.value = sampleSeenWatermarkMs\(now\)"))),
            ("Android Mark Seen", AND_BLE_MANAGER, r"\n    fun markAllSeen\(\) \{(.*?)\n    \}",
             (("moves the watermark in memory, then stops before disk in sample data",
               r"_seenWatermark\.value = stamps[\s\S]*?"
               r"if \(!persistedLogMutationAllowed\(_demoMode\.value\)\) return\s*\n\s*prefs\.edit\(\)"),)),
            ("Android first-run baseline", AND_BLE_MANAGER,
             r"\n    fun seedSeenWatermarkOnce\(\) \{(.*?)\n    \}",
             (("never runs in sample data, before it reads the once-only flag",
               r"^\s*if \(!persistedLogMutationAllowed\(_demoMode\.value\)\) return\s*\n\s*"
               r'if \(prefs\.getBoolean\("seenWatermarkSeeded", false\)\) return'),)),
            ("Android leaving the Log", AND_MAIN_SCREEN, None,
             (("marks seen only when the Log was not opened in sample data",
               r"val openedInDemo = demoMode\s*\n\s*DisposableEffect\(Unit\) \{\s*\n\s*"
               r"onDispose \{ if \(!openedInDemo\) ble\.markAllSeen\(\) \}"),
              ("and nothing else here marks seen", r"markAllSeen\(\)", 1))),
            ("Android Log tools", AND_LOG_SCREEN, None,
             (("Mark Seen is gated on rows alone (Clear Log is the sample-data difference)",
               r"markSeen = hasRows, export = hasRows, clear = !demo\)"),
              ("and its handler is not gated either",
               r"LogTool\.MarkSeen -> \{ ble\.markAllSeen\(\); scope = LogScope\.All \}"))),
        ),
    },
    {
        "what": "dossier signal word (SAMPLE, then STALE, then LIVE; drawn and spoken)",
        "why": "the SIGNAL header names a sample row SAMPLE rather than LIVE on both phones, and"
               " the screen reader hears the same word the header draws",
        "sides": (
            ("iOS rule", IOS_DETECTION_DETAIL,
             r"func dossierSignalWord\(isDemoMode: Bool, stale: Bool\) -> String \{(.*?)\n\}",
             (("sample first, then stale, then live",
               r'^\s*if isDemoMode \{ return "SAMPLE" \}\s*\n\s*return stale \? "STALE" : "LIVE"\s*$'),)),
            ("iOS header", IOS_DETECTION_DETAIL, r"private var signalPanel: some View \{(.*?)\n    \}",
             (("the word is the rule's",
               r"let word = dossierSignalWord\(isDemoMode: ble\.demoMode, stale: stale\)"),
              ("the header draws it", r"\bText\(word\)"),
              ("and speaks it", r'\.accessibilityLabel\("SIGNAL · \\\(word\)"\)'))),
            ("Android rule", AND_DETAIL_SCREEN,
             r"internal fun dossierSignalWord\(demo: Boolean, stale: Boolean\): String = when \{(.*?)\n\}",
             (("sample first, then stale, then live",
               r'^\s*demo -> "SAMPLE"\s*\n\s*stale -> "STALE"\s*\n\s*else -> "LIVE"\s*$'),)),
            ("Android header", AND_DETAIL_SCREEN, None,
             (("the word is the rule's",
               r"val signalWord = dossierSignalWord\(demo = demo, stale = stale\)"),
              ("the header draws it", r"\bText\(signalWord,"),
              ("and speaks it", r'contentDescription = "SIGNAL · \$signalWord"'))),
        ),
    },
    {
        "what": "Status says sample less (no bare SAMPLE DATA kicker, no suffix on the strongest"
                " header in sample data)",
        "why": "the banner and the SAMPLE pill already say it; both phones drop the same two"
               " repeats and keep the radio-variant kickers and the row's own sample line",
        "sides": (
            ("iOS rules", IOS_DASHBOARD_PRESENTATION, None,
             (("only the bare sample kicker is hidden",
               r'isDemoMode && scanLabel == "SAMPLE DATA" \? nil : scanLabel'),
              ("the strongest header drops its suffix in sample data",
               r'isDemoMode \? "STRONGEST \\\(kind\)" : "STRONGEST \\\(kind\) · RECENT"'))),
            ("iOS Status", IOS_DASHBOARD_VIEW, None,
             (("the header's kicker comes from the rule",
               r"let scanKicker = dashboardScanKicker\(scanLabel: radioPresentation\.scanLabel,"),
              ("and is drawn only when there is one",
               r"if let scanKicker \{\s*\n\s*Kicker\(scanKicker,"),
              ("the strongest header comes from the rule",
               r"SectionHeader\(dashboardStrongestHeader\(kind: kind, isDemoMode: ble\.demoMode\),"))),
            ("Android rules", AND_STATUS_SCREEN, None,
             (("only the bare sample kicker is hidden",
               r'if \(demo && label == "SAMPLE DATA"\) null else label'),
              ("the strongest header drops its suffix in sample data",
               r'return if \(demo\) base else "\$base · RECENT"'))),
            ("Android Status", AND_STATUS_SCREEN, None,
             (("the header's kicker comes from the rule",
               r"val scanKicker = statusScanKicker\(scanLabel, demo\)"),
              ("and is drawn only when there is one",
               r"if \(scanKicker != null\) Row\([\s\S]*?Kicker\(scanKicker,"),
              ("the strongest header comes from the rule",
               r"val title = statusStrongestHeader\(kind, demo\)"))),
        ),
    },
    # ---- decisions R13: the Beacon tab's group intros ----
    {
        "what": "Beacon group intro lines (the same sentences under the same groups; mesh and"
                " sample variants gated alike)",
        "why": "each Beacon group names what it holds in one lowercase-first line under its header,"
               " the same words on both apps (decisions R13); the short variants follow the rows:"
               " a mesh board has no Alerts row, so its ON THE BOARD line must not promise alerts,"
               " and the sample tour has no System readiness row, so its help line must not"
               " promise setup checks. The cards (hero, Uptime / Detections) and the saved-log and"
               " Disconnect groups carry no line",
        "sides": (
            ("iOS intros", IOS_SETTINGS, r"private func groupIntroText\(_ key: Int\) -> String\? \{(.*?)\n    \}",
             (("scan radios group", r"case BeaconRowID\.scanRadios\.sectionKey:\s*\n\s*return "
               + _quoted(_BEACON_INTRO_SCAN)),
              ("ON THE BOARD group, alerts dropped on a mesh board",
               r"case BeaconRowID\.boardLED\.sectionKey:\s*\n\s*return ble\.status\?\.isMeshDetect == true"
               r"\s*\n\s*\? " + _quoted(_BEACON_INTRO_BOARD[1]) + r"\s*\n\s*: " + _quoted(_BEACON_INTRO_BOARD[0])),
              ("notifications group, with the device word",
               r"case BeaconRowID\.notifications\.sectionKey:\s*\n\s*return "
               + re.escape('"' + _BEACON_INTRO_NOTIFY_TEMPLATE.format("\\(thisDeviceName)") + '"')),
              ("help group, setup checks dropped in the sample tour",
               r"case BeaconRowID\.helpSupport\.sectionKey:\s*\n\s*return ble\.demoMode \? "
               + _quoted(_BEACON_INTRO_HELP[1]) + r"\s*\n\s*: " + _quoted(_BEACON_INTRO_HELP[0])),
              ("every other group has none", r"default:\s*\n\s*return nil"))),
            ("iOS header", IOS_SETTINGS, None,
             (("the group header draws that line", r"let intro = groupIntroText\(group\.id\)"),
              ("the device word is the idiom's name",
               r'UIDevice\.current\.userInterfaceIdiom == \.pad \? "iPad" : "iPhone"'))),
            ("Android intros", AND_DEVICE_SCREEN,
             r"(internal fun beaconGroupIntro\(key: Int, meshBoard: Boolean, demo: Boolean, deviceWord: String\)"
             r": String\? =.*?\n    \})",
             (("scan radios group", r"beaconSectionKey\(BeaconRowId\.SCAN_RADIOS\) -> "
               + _quoted(_BEACON_INTRO_SCAN)),
              ("ON THE BOARD group, alerts dropped on a mesh board",
               r"beaconSectionKey\(BeaconRowId\.BOARD_LED\) ->\s*\n\s*if \(meshBoard\) "
               + _quoted(_BEACON_INTRO_BOARD[1]) + r"\s*\n\s*else " + _quoted(_BEACON_INTRO_BOARD[0])),
              ("notifications group, with the device word",
               r"beaconSectionKey\(BeaconRowId\.NOTIFICATIONS\) -> "
               + re.escape('"' + _BEACON_INTRO_NOTIFY_TEMPLATE.format("$deviceWord") + '"')),
              ("help group, setup checks dropped in the sample tour",
               r"beaconSectionKey\(BeaconRowId\.HELP_SUPPORT\) ->\s*\n\s*if \(demo\) "
               + _quoted(_BEACON_INTRO_HELP[1]) + r"\s*\n\s*else " + _quoted(_BEACON_INTRO_HELP[0])),
              ("every other group has none", r"else -> null"))),
            # The mesh fact goes in by position (the "desert still-silent notice gate" row pins the
            # named spelling to the one beaconRows call), so the call is pinned whole: a literal
            # false, or the phone's own demo flag in the mesh slot, compiles and still reads well.
            ("Android header", AND_DEVICE_SCREEN, None,
             (("the group header draws that line, from the same mesh and sample facts as the rows",
               r"intro = beaconGroupIntro\(group\.key, status\?\.isMeshDetect == true, demo = demo,"
               r"\s*\n\s*deviceWord = deviceWord\)"),
              ("the device word is the device class's name",
               r'val deviceWord = if \(isTablet\) "tablet" else "phone"'))),
        ),
    },
    # ---- decisions R13 (L1): the THIS-device groups get headers like the board's ----
    {
        "what": "Beacon THIS-device group headers (PREFERENCES over notifications / Live Mode /"
                " display, SUPPORT over readiness / help / about, at both widths)",
        "why": "both segments open every rows group with a C2 identifier (decisions R13): the board"
               " side's DETECTION and ON THE BOARD, this device's PREFERENCES and SUPPORT, over"
               " the groups' unchanged intro lines. iOS carries the two as header rows in its"
               " partition (sectionHeaderRow draws a Kicker at compact and a SectionHeader at"
               " regular width); Android derives them from the group key in"
               " beaconGroupHeaderLabel, which ConfigGroupLabel draws in both layouts. Same"
               " labels, same groups (keys 5 and 6)",
        "sides": (
            ("iOS partition", IOS_SETTINGS, None,
             (("the phone rows open with PREFERENCES and put SUPPORT before readiness",
               r"var rows: \[BeaconRowID\] = \[\.preferencesHeader, \.notifications, \.liveMode,"
               r" \.display,\s*\n\s*\.supportHeader\]"),
              ("PREFERENCES heads key 5",
               r"case \.preferencesHeader, \.notifications, \.liveMode, \.display:\s*return 5"),
              ("SUPPORT heads key 6",
               r"case \.supportHeader, \.systemReadiness, \.improveDetection, \.helpSupport,"
               r" \.about:\s*\n\s*return 6"),
              ("both are header rows, lifted into the group's header slot",
               r"case \.detectionHeader, \.onBoardHeader, \.preferencesHeader, \.supportHeader:"
               r" return true"),
              ("the PREFERENCES label",
               r'case \.preferencesHeader:\s*\n\s*return sectionHeaderRow\("PREFERENCES"\)'),
              ("the SUPPORT label", r'case \.supportHeader:\s*\n\s*return sectionHeaderRow\("SUPPORT"\)'),
              ("a header row draws at both widths",
               r"hSize == \.regular \? AnyView\(SectionHeader\(title\)\) : AnyView\(Kicker\(title\)\)"))),
            ("Android labels", AND_DEVICE_SCREEN,
             r"(internal fun beaconGroupHeaderLabel\(group: BeaconRowGroup\): String\? =.*?\n    \})",
             (("the board side keeps its header rows",
               r"group\.header\?\.let\(::beaconGroupLabel\)"),
              ("PREFERENCES heads the notifications group (key 5)",
               r'beaconSectionKey\(BeaconRowId\.NOTIFICATIONS\) -> "PREFERENCES"'),
              ("SUPPORT heads the help group (key 6)",
               r'beaconSectionKey\(BeaconRowId\.HELP_SUPPORT\) -> "SUPPORT"'))),
            ("Android keys", AND_DEVICE_SCREEN, None,
             (("key 5", r"BeaconRowId\.NOTIFICATIONS, BeaconRowId\.LIVE_MODE, BeaconRowId\.DISPLAY -> 5"),
              ("key 6", r"BeaconRowId\.SYSTEM_READINESS, BeaconRowId\.IMPROVE_DETECTION,"
                        r" BeaconRowId\.HELP_SUPPORT, BeaconRowId\.ABOUT -> 6"),
              ("the one group header draws the label in both layouts",
               r"label = beaconGroupHeaderLabel\(group\),"))),
        ),
    },
    # ---- decisions R14: the board kind names the owner's board (copy only) ----
    {
        "what": "board kind precedence (fw label, then live advert hint, then stored; the screen:"
                " the target, the remembered board, the rows' one kind, else beacon)",
        # Settled 2026-09-25 (decisions R14): the order was fw > stored > hint, so a remembered
        # board reflashed to another kind kept its old name until it connected.
        "why": "which name the owner reads for their own board: the firmware's own label wins;"
               " before connect a live named advert wins, so a reflashed board reads as its new"
               " kind; a nameless (stealth) advert falls back to what this phone stored from the"
               " last fw label, and the next fw label re-stamps it; a startup screen with a mixed"
               " or empty scan stays beacon. Unknown reads as beacon on both",
        "sides": (
            ("iOS", IOS_BOARD_KIND, None,
             (("one board", r"BoardKind\.fromFirmwareLabel\(firmwareLabel\) \?\? advertHint \?\? storedKind"),
              ("the screen: the target while a connect runs or failed",
               r"if targetActive \{ return targetKind \}"),
              ("then the remembered board", r"if let rememberedKind \{ return rememberedKind \}"),
              ("then the one kind every row agrees on",
               r"return rowKinds\.allSatisfy \{ \$0 == kind \} \? kind : nil"),
              ("unknown reads as beacon", r"let k = kind \?\? \.beacon"),
              ("the hero title too", r"\(kind \?\? \.beacon\)\.heroTitle"))),
            ("Android", AND_BOARD_KIND, None,
             (("one board", r"BoardKind\.fromFirmwareLabel\(firmwareLabel\) \?: advertHint \?: storedKind"),
              ("the screen: the target while a connect runs or failed",
               r"if \(targetActive\) return targetKind"),
              ("then the remembered board", r"if \(rememberedKind != null\) return rememberedKind"),
              ("then the one kind every row agrees on",
               r"return first\.takeIf \{ rowKinds\.all \{ it == first \} \}"),
              ("unknown reads as beacon", r"this \?: BoardKind\.BEACON"))),
            ("Android hero", AND_DEVICE_SCREEN, None,
             (("the hero title", r"\(kind \?: BoardKind\.BEACON\)\.heroTitle"),)),
        ),
    },
    {
        "what": "the board kind names the Beacon hero, the About link and the picker rows (never"
                " the raw advertised name)",
        "why": "the Beacon hero reads 'All Cameras Are Beacons' for a beacon or an unknown board and"
               " the product's own name for an OUI-Spy or a Mesh-Detect; the Colonel Panic About"
               " link shows for every board that is not a beacon; a remembered row reads 'your"
               " <kind>' from its live hint, else its stored kind, and a scanned row '<kind>',"
               " because every board of one kind advertises the same name and 'ACAB' told the"
               " owner nothing",
        "sides": (
            ("iOS Beacon", IOS_SETTINGS, None,
             (("hero", r"Text\(boardHeroTitle\(ble\.connectedKind\)\)"),
              ("About link", r"if ble\.connectedKind != \.beacon \{"))),
            ("iOS picker", IOS_CONNECT_VIEW, None,
             (("row titles", r"entry\.isRemembered \? RememberedBoardCopy\.label\(kind: entry\.kind\)"
                             r" : \(entry\.kind \?\? \.beacon\)\.noun"),
              ("remembered subtitle carries no name",
               r"return RememberedBoardCopy\.subtitle\(hasSignal: entry\.rssi != nil\)"))),
            ("iOS merge", IOS_REMEMBERED_BOARD, None,
             (("the remembered row: the live hint, else the stored kind",
               r"lead\.kind = row\.kind \?\? remembered\.kind"),)),
            ("Android Beacon", AND_DEVICE_SCREEN, None,
             (("hero", r"title = boardHeroTitle\(connectedKind\),"),
              ("About link", r"showColonel = connectedKind != BoardKind\.BEACON,"))),
            ("Android picker", AND_ACAB_APP, None,
             (("row titles", r"if \(board\.owned\) RememberedBoardCopy\.label\(kind\) else scannedRowTitle\(kind\)"),
              ("a scanned row's title", r"= \(kind \?: BoardKind\.BEACON\)\.noun"),
              ("the remembered row: the live hint, else the stored kind",
               r"resolveBoardKind\(firmwareLabel = null, storedKind = rememberedKind\?\.takeIf \{ owned \},"
               r" advertHint = kindHint\)"),
              ("remembered subtitle carries no name",
               r"Text\(RememberedBoardCopy\.subtitle\(board\.advertSeen\)"))),
        ),
    },
    {
        "what": "a scan row's kind hint is the last named kind it heard (a nameless frame keeps it)",
        # Settled 2026-09-25 (decisions R14): Android cleared the hint on any frame whose name
        # claimed no kind, so a scan-response frame could flip a reflashed row back to its
        # stored kind between adverts.
        "why": "the live advert hint outranks the stored kind before connect, so a row whose hint"
               " a nameless or unclaimed frame wiped would flicker between its new and its old"
               " name on one phone and not the other",
        "sides": (
            ("iOS", IOS_BLE_MANAGER, None,
             (("a new named kind replaces the hint; no name keeps it",
               r"if let kindHint \{ discovered\[i\]\.kindHint = kindHint \}"),)),
            ("Android", AND_BOARD_KIND, None,
             (("a new named kind replaces the hint; no name keeps it",
               r"BoardKind\.fromAdvertName\(advertName\) \?: previous"),)),
            ("Android scan", AND_BLE_MANAGER, None,
             (("the scan callback carries the hint forward",
               r"val kindHint = carriedAdvertHint\(advertName, prev\?\.kindHint\)"),)),
        ),
    },
    {
        "what": "offline-sync banner: the nothing-replayed arm names the board that buffered",
        # Settled 2026-09-25 (decisions R14): both read "... couldn't be replayed from the beacon"
        # for every board.
        "why": "when the board promised buffered rows and sent none, the banner says which board"
               " to reconnect; an OUI-Spy owner told 'the beacon' reads it as a different device",
        "sides": (
            ("iOS", IOS_ROOT_VIEW, None,
             (("the nothing-replayed arm",
               r'"\\\(unreplayed\) buffered \\\(bnoun\) couldn\'t be replayed from the \{noun\}"'),
              ("rendered with the connected kind",
               r"offlineSyncMessage\(count: summary\.count, unreplayed: summary\.unreplayed,"
               r"\s*kind: ble\.connectedKind\)"))),
            ("Android", AND_MAIN_SCREEN, None,
             (("the nothing-replayed arm, singular",
               r'"1 buffered detection couldn\'t be replayed from the \{noun\}"'),
              ("the nothing-replayed arm, plural",
               r'"\$unreplayed buffered detections couldn\'t be replayed from the \{noun\}"'))),
        ),
    },
    # ---- decisions U2: Android adopts the iOS words ----
    {
        "what": "checklist state sentences (shared set byte for byte; platform arms per side)",
        "why": "the checklist's rows describe the same states in the same words on both phones;"
               " where a platform has a state the other does not (restricted Location, Live"
               " Activities, an unknown buffer before the first frame), that arm is its own and is"
               " pinned on its own side; the notifications row never reads blocked in sample"
               " data, like the THIS PHONE row below",
        "sides": (
            ("iOS rows", IOS_CHECKLIST, r"\nstruct ChecklistRows \{(.*?)\n\}",
             tuple((f"shared: {s}", _quoted(s)) for s in _CHECKLIST_SHARED_SENTENCES)
             + (("shared, with the platform word: blocked notifications",
                 re.escape('"\\(count)' + _CHECKLIST_BLOCKED_TEMPLATE.format("iOS") + '"')),
                ("shared: the count agrees in number",
                 r'"\\\(count\) categor\\\(count == 1 \? "y" : "ies"\) enabled on this phone"'),
                ("notifications: OFF first, then blocked only outside sample data",
                 r'if count == 0 \{ return "off until you choose categories under Beacon" \}'
                 + _KT_ARM_GAP + r'if !ble\.demoMode, ble\.notifier\.mutedBySystem \{\s*\n\s*return "\\\(count\) chosen,'),
                ("iOS only: Location also feeds background Live Mode",
                 _quoted("allowed; Map and background Live Mode are ready")),
                ("iOS only: restricted Location",
                 _quoted("restricted by device policy; detection still works")),
                ("iOS only: denied Location", _quoted("off in iOS settings; detection still works")),
                ("iOS only: Live Activities blocked",
                 _quoted("on by default, but Live Activities are blocked by iOS")),
                ("iOS only: Live Mode waits for Location",
                 _quoted("on by default; waits for Location before showing a system surface")),
                ("every board-naming sentence is rendered with the checklist's kind",
                 r'renderBoardCopy\("[^"]*\{noun\}[^"]*", kind\)', 2))),
            ("iOS sheet", IOS_CHECKLIST, None,
             (("the sheet draws the four rows",
               r"\brows\.(?:locationDetail|notificationDetail|liveModeDetail|bufferDetail)\b", 8),)),
            ("Android rows", AND_FIRST_RUN_TOUR,
             r"(internal fun checklistLocationDetail\(.*?internal fun checklistBufferDetail\(.*?\n\})",
             tuple((f"shared: {s}", _quoted(s)) for s in _CHECKLIST_SHARED_SENTENCES)
             + (("shared, with the platform word: blocked notifications",
                 re.escape('"$count' + _CHECKLIST_BLOCKED_TEMPLATE.format("Android") + '"')),
                ("shared: the count agrees in number",
                 r'count == 1 -> "\$count category enabled on this phone"\s*\n\s*'
                 r'else -> "\$count categories enabled on this phone"'),
                ("notifications: OFF first, then blocked only outside sample data",
                 r'count == 0 -> "off until you choose categories under Beacon"\s*\n\s*'
                 r'!demo && blockedBySystem -> "\$count chosen,'),
                ("Android only: Location feeds the Map alone", _quoted("allowed; Map is ready")),
                ("Android only: the Live Mode notification blocked",
                 _quoted("on by default, but its notification is blocked by Android")),
                ("Android only: the buffer before the first frame",
                 _quoted("not known until your {noun} reports it")),
                ("every board-naming sentence is rendered with the checklist's kind",
                 r'renderBoardCopy\("[^"]*\{noun\}[^"]*", kind\)', 3))),
            ("Android sheet", AND_FIRST_RUN_TOUR, None,
             (("the sheet draws the four rows",
               r"\bKicker\(checklist(?:Location|Notification|LiveMode|Buffer)Detail\(", 4),
              ("the notifications row passes the system block and the sample-data flag",
               r"\bKicker\(checklistNotificationDetail\(phoneAlertsCount, !phoneAlertsAvailable, demo\)\)"))),
        ),
    },
    {
        "what": "THIS PHONE row values name the platform's block (never in sample data), and the"
                " notify card's two sentences",
        "why": "a notification or Live Mode the system will not deliver reads BLOCKED on both"
               " phones, in each platform's own row shape; the notify card promises the same"
               " thing about permission with the platform's name in the one hole",
        "sides": (
            ("iOS Notifications row", IOS_SETTINGS, r"private var notifyKicker: String \{(.*?)\n    \}",
             (("blocked only outside sample data, with something on",
               r'if !ble\.demoMode, ble\.notifier\.mutedBySystem, n > 0 \{\s*\n\s*'
               r'return "\\\(n\) ON \\u\{00B7\} BLOCKED BY IOS"'),
              ("otherwise OFF or the count", r'return n == 0 \? "OFF" : "\\\(n\) ON"'))),
            ("iOS Live Mode row", IOS_SETTINGS, r"private var liveModeState: String \{(.*?)\n    \}",
             (("sample data first, a preview, never live",
               r'^\s*if ble\.demoMode \{ return ble\.settingsDriveModeWanted \? "Preview on" : "Off" \}'),
              ("the system block", r'if !ble\.liveActivitiesEnabled \{ return "Blocked by iOS" \}'))),
            ("iOS notify card", IOS_SETTINGS, None,
             (("the two sentences, iOS in the hole",
               r"Text\(ble\.demoMode\s*\?\s*" + _quoted(_NOTIFY_EXPLAINER_SAMPLE.format("iOS"))
               + r"\s*:\s*" + _quoted(_NOTIFY_EXPLAINER_REAL.format("iOS")) + r"\)"),)),
            ("Android Notifications row", AND_DEVICE_SCREEN,
             r"internal fun beaconNotifyRowValue\(count: Int, blockedBySystem: Boolean, demo: Boolean\):"
             r" String = when \{(.*?)\n\}",
             (("OFF, then blocked outside sample data, then the count",
               r'count == 0 -> "OFF"\s*\n\s*!demo && blockedBySystem -> "\$count ON · BLOCKED BY ANDROID"'
               r'\s*\n\s*else -> "\$count ON"'),)),
            ("Android Live Mode row", AND_DEVICE_SCREEN,
             r"internal fun beaconLiveRowValue\((.*?)\n\}",
             (("the system block outside sample data",
               r'!demo && wanted && !deliverable -> "LIVE BLOCKED BY ANDROID"'),
              # R19 (review P2-12): sample data reads PREVIEW ON / OFF, never LIVE, the iOS
              # story ("Preview on" / "Off" through driveKicker's uppercase).
              ("sample data is a preview, never live",
               r'demo && wanted -> "PREVIEW ON"\s*\n\s*demo -> "OFF"'),
              ("then the counts", r'return "\$live · COUNTS \$counts"'))),
            ("Android notify card", AND_DEVICE_SCREEN, None,
             (("the two sentences, Android in the hole",
               r"if \(demo\) " + _quoted(_NOTIFY_EXPLAINER_SAMPLE.format("Android"))
               + r"\s*else " + _quoted(_NOTIFY_EXPLAINER_REAL.format("Android"))),
              ("the card draws them", r"\bnotifyCardExplainer\(demo\),"),
              ("the rows draw their values",
               r"val (?:notifyKicker = beaconNotifyRowValue|driveKicker = beaconLiveRowValue)\(", 2))),
        ),
    },
    {
        "what": "ALPR layer words (callout titles from the shared helper; 'cameras' as the count"
                " noun; the floating Map options button speaks the layer state)",
        "why": "the callout titles compared per tier above only matter if each phone's callout"
               " draws them; the dataset caption counts cameras, not records, on both phones; and"
               " the Map options button (a floating layers button at the lower right on both"
               " phones since the 2026-09-26 legend decision) is named the same and speaks the"
               " known-ALPR layer state in the same words, with no scope suffix",
        "sides": (
            ("iOS callout", IOS_MAP_TAB, None,
             (("the title is the shared helper's", r"\bText\(ALPRAttribution\.headline\("),)),
            ("iOS dataset caption", IOS_MAP_TAB, None,
             # Two captions count cameras: the dataset line in lowercase and the check row's
             # "Updated · N Cameras" flash in Title Case (a button label), so the C takes either case.
             (("the count noun agrees in number",
               r'[Cc]amera\\\((?:shown|n) == 1 \? "" : "s"\)', 2),
              ("and no caption counts records", r"ALPR record", 0))),
            ("Android callout", AND_MAP_ALPR, None,
             (("tiers 0, 1 and 2 take the shared helper's title",
               r"rawTier == 0 \|\| rawTier == 1 \|\| rawTier == 2 ->"
               r" alprAttributionHeadline\(rawTier, maker\)"),)),
            ("Android dataset caption", AND_MAP_SCREEN, None,
             (("the count noun agrees in number",
               r'"%,d camera%s", n, if \(n == 1\) "" else "s"'),
              ("and in the check row's Title Case flash too",
               r'"%,d Camera%s", n, if \(n == 1\) "" else "s"'),
              ("and no caption counts records", r"ALPR record", 0))),
            ("iOS layers button", IOS_MAP_TAB, None,
             (("named Map options", r'\.accessibilityLabel\("Map options"\)'),
              ("and the layer state spoken",
               r'\.accessibilityValue\(alpr\.enabled \? "known ALPR layer on" : "known ALPR layer off"\)'))),
            ("Android layers button", AND_MAP_SCREEN, None,
             (("named Map options", r'contentDescription = "Map options"'),
              ("with no scope suffix", r'(?i)"options · ', 0),
              ("and the layer state spoken",
               r'stateDescription = if \(alprEnabled\) "known ALPR layer on" else "known ALPR layer off"'))),
        ),
    },
    {
        # The 'map ALL chip label' string row above compares the word only; this is the number
        # beside it. The Android count is scopedEvidence.size at the call site (the chip model takes
        # it as a bare parameter), and the iOS count is the one tally the snapshot takes after the
        # scope guard and before the category guard.
        "what": "map ALL chip counts the located rows in scope, before the category chip",
        "why": "the ALL chip's number is what the pins represent with no category chip on, under"
               " the current scope, on both phones; a count taken after the category filter, or"
               " before the scope, would read a different number over the same map",
        "sides": (
            ("iOS ALL chip", IOS_MAP_TAB, None,
             (("the chip draws the snapshot total", r'\bchip\(nil, "ALL", snap\.totalLocated\)'),
              ("the snapshot stores the one tally", r'\btotalLocated: total,'),
              ("the tally is taken once", r'\btotal \+= 1'),
              ("after the scope guard and before the category guard",
               r'guard inScope else \{ continue \}\s*\n\s*total \+= 1\s*\n\s*'
               r'counts\[d\.type\.category, default: 0\] \+= 1'))),
            ("Android ALL chip", AND_MAP_SCREEN, None,
             (("the chip model draws the count it is given",
               r'add\(MapChipModel\(null, "ALL", allCount, selected = filter == null\)\)'),
              ("the call site gives the scoped located rows", r'\ballCount = scopedEvidence\.size,'),
              ("which are the located rows under the scope, before the category chip",
               r'val scopedEvidence = remember\(locatedEvidence, historyScope, scopedIds\) \{\s*\n\s*'
               r'mapScopedLocated\(locatedEvidence, historyScope, scopedIds\)'))),
        ),
    },
    # ---- decisions U3: dossier and Map wording ----
    {
        "what": "row titles fall back to titleFallback only for the bare category (label stays"
                " the export value)",
        "why": "a Log row, the Status nearest card and the dossier headline name a bare body cam"
               " 'body cam' on both phones, and nothing else changes: the CSV / GPX type column"
               " still reads DeviceType.label",
        "sides": (
            ("iOS rule", IOS_DETECTION, r"\n    var titleName: String \{(.*?)\n    \}",
             (("the fallback only when the display name IS the label",
               r"^\s*let n = displayName\s*\n\s*return n == type\.label \? type\.titleFallback : n\s*$"),)),
            ("iOS Log row", IOS_DETECTION_ROW, None, (("draws it", r"\bText\(d\.titleName\)"),)),
            ("iOS Status", IOS_DASHBOARD_VIEW, None, (("draws it", r"\bText\(d\.titleName\)"),)),
            ("iOS dossier", IOS_DETECTION_DETAIL, None,
             (("the headline is it", r"\blet headline = d\.titleName\b"),)),
            ("Android rule", AND_OUI_VENDORS, r"\nval Detection\.titleName: String\s*\n\s*get\(\) \{(.*?)\n    \}",
             (("the fallback only when the display name IS the label",
               r"^\s*val n = displayName\s*\n\s*return if \(n == type\.label\) type\.titleFallback else n\s*$"),)),
            ("Android Log rows", AND_LOG_SCREEN, None,
             (("both row layouts draw it", r"\bText\(d\.titleName,", 2),)),
            ("Android Status", AND_STATUS_SCREEN, None, (("draws it", r"\bText\(d\.titleName,"),)),
            ("Android dossier", AND_DETAIL_SCREEN, None,
             (("the headline is it", r"\bval headline = d\.titleName\b"),)),
        ),
    },
    {
        "what": "dossier line rules (no 'X over X', no maker repeating the title, the tracker"
                " note only under a tracker's '(offline)', the buffer blamed only for a replay, a"
                " Desert row explained before any per-method line can claim a match, and never"
                " called flagged, scored, or weak)",
        "why": "the words are compared in SHARED_CONSTANTS; these hold the conditions that pick"
               " them and the slots that draw them, so one phone cannot say 'Remote ID over Remote"
               " ID' or explain a tracker's '(offline)' under a different kind of row",
        "sides": (
            ("iOS rules", IOS_DETECTION_DETAIL, None,
             (("the source is dropped when it equals the method, ignoring case",
               r"methodLabel\.caseInsensitiveCompare\(sourceLabel\) == \.orderedSame"),
              ("the maker is dropped when it equals the headline, ignoring case",
               r"makerOrVendor\.caseInsensitiveCompare\(headline\) == \.orderedSame"),
              ("the tracker note needs a tracker and the firmware's suffix",
               r'guard type == \.tracker, let detail, detail\.hasSuffix\("\(offline\)"\) else \{ return nil \}'),
              ("a Desert row is heard, never flagged by its method",
               r'if type == \.nearbyDevice \{ return "Heard over '),
              ("a Desert row's confidence is not a match, with no percent",
               r'if type == \.nearbyDevice \{ return "Not a match" \}'),
              ("a Desert row gets no amber weak-match glyph",
               r"private var confidenceIsWeak: Bool \{ d\.confidence < 50 && d\.type != \.nearbyDevice \}"))),
            ("iOS slots", IOS_DETECTION_DETAIL, None,
             (("the flagged line", r"\bText\(dossierFlaggedLine\(type: d\.type, methodLabel: d\.method\.label,"
               r" sourceLabel: d\.source\.label\)\)"),
              ("the confidence row, handed the type, its glyph on the Desert-aware cue",
               r'dossierRow\("confidence", dossierConfidenceLine\(type: d\.type, confidence: d\.confidence\),'
               r'\s*\n\s*glyph: confidenceIsWeak \? "exclamationmark\.triangle\.fill" : "gauge\.medium",'
               r"\s*\n\s*glyphColor: confidenceIsWeak \? ACABTheme\.warn : ACABTheme\.dim\)"),
              ("the hero subtitle, handed the headline",
               r"\bText\(dossierHeroSubtitle\(node: d\.nodeName, makerOrVendor: d\.maker \?\? d\.vendor,"
               r"\s*headline: headline\)\)"),
              ("the body-cam fallback, told whether the row is a replay",
               r"return Text\(dossierBodyCamFallbackLine\(isReplay: d\.isHistory\)\)"),
              ("the nearby-device explainer, handed the detail, ahead of the per-method lines",
               r"if d\.type == \.nearbyDevice \{ return Text\(dossierNearbyDeviceLine\(detail: d\.detail\)\) \}"
               r"\s*\n\s*switch d\.method \{"))),
            ("iOS match quality", IOS_DETECTION_DETAIL,
             r"private var matchQualityPanel: some View \{(.*?)\n    \}",
             (("the tracker note sits directly under the verbatim detail",
               r"\n(\s*)Text\(detail\)\n(?:\1\s+[^\n]*\n)*\s*\}\s*\n(?:\s*//[^\n]*\n)*"
               r"\s*if let note = trackerOfflineNote\(type: d\.type, detail: d\.detail\) \{"
               r"\s*\n\s*Text\(note\)"),)),
            ("Android rules", AND_DETAIL_SCREEN, None,
             (("the source is dropped when it equals the method, ignoring case",
               r"methodLabel\.equals\(sourceLabel, ignoreCase = true\)"),
              ("the maker is dropped when it equals the headline, ignoring case",
               r"makerOrVendor\.equals\(headline, ignoreCase = true\)"),
              ("the tracker note needs a tracker and the firmware's suffix",
               r'type == DeviceType\.TRACKER && detail\?\.endsWith\("\(offline\)"\) == true'),
              ("a Desert row is heard, never flagged by its method",
               r'type == DeviceType\.NEARBY_DEVICE -> "Heard over '),
              ("a Desert row's confidence is not a match, with no percent",
               r'if \(type == DeviceType\.NEARBY_DEVICE\) "Not a match"\s*\n\s*else '),
              ("a Desert row gets no amber weak-match glyph",
               r"val weak = d\.confidence < 50 && d\.type != DeviceType\.NEARBY_DEVICE\n"))),
            ("Android slots", AND_DETAIL_SCREEN, None,
             (("the flagged line", r"\bText\(dossierFlaggedLine\(d\.type, d\.methodLabel, d\.sourceLabel\),"),
              ("the confidence row, handed the type, its glyph on the Desert-aware cue",
               r'GroupedValueRow\("confidence", dossierConfidenceLine\(d\.type, d\.confidence\), leading = \{'
               r"\s*\n\s*Icon\(if \(weak\) Icons\.Filled\.Warning else Icons\.Outlined\.Speed,"),
              ("the hero subtitle, handed the headline",
               r"\bText\(dossierHeroSubtitle\(nodeName\(d\.mac\), d\.maker \?: d\.vendor, headline\),"),
              ("the body-cam fallback, told whether the row is a replay",
               r"\bappend\(dossierBodyCamFallbackLine\(replay = d\.hist \|\| d\.offline\)\)"),
              ("the nearby-device explainer, handed the detail, ahead of the per-method lines",
               r"if \(d\.type == DeviceType\.NEARBY_DEVICE\) \{\s*\n\s*append\(dossierNearbyDeviceLine\(d\.detail\)\)"
               r"\s*\n\s*return@buildAnnotatedString\s*\n\s*\}\s*\n\s*when \(d\.method\) \{"))),
            ("Android match quality", AND_DETAIL_SCREEN,
             r"private fun MatchQualityPanel\(d: Detection\) \{(.*?)\n\}",
             (("the tracker note sits directly under the verbatim detail",
               r"d\.detail\?\.takeIf \{ it\.isNotEmpty\(\) \}\?\.let \{\s*\n\s*Text\(it, color = Acab\.text,"
               r"[^\n]*\n[^\n]*\n\s*\}\s*\n(?:\s*//[^\n]*\n)*"
               r"\s*trackerOfflineNote\(d\.type, d\.detail\)\?\.let \{"),)),
        ),
    },
    {
        "what": "matched-on keeps each method label's own casing (a Desert-mode row first, then two"
                " OUI telegrams, then the label verbatim)",
        "why": "the dossier's 'matched on' row quotes the same method words the FAQ does; a phone"
               " that lowercases them, or renames one (NAME MATCH), answers in words the FAQ never"
               " uses; a phone that keys the Desert answer on the method calls a real SSID"
               " signature 'no signature', or a Desert row 'SSID'",
        "sides": (
            ("iOS rule", IOS_DETECTION_DETAIL,
             r"func methodChipLabel\(type: DeviceType, method: DetectionMethod, maker: String\?\)"
             r" -> String \{(.*?)\n\}",
             (("a Desert-mode row, by type, before any method",
               r'if type == \.nearbyDevice \{ return "no signature" \}\s*\n\s*switch method \{'),
              ("vendor, then chipset, then the label as written",
               r'case \.oui where maker != nil: return "OUI \\u\{00B7\} VENDOR ONLY"\s*\n\s*'
               r'case \.oui:\s*return "OUI \\u\{00B7\} CHIPSET ONLY"\s*\n\s*'
               r"default:\s*return method\.label\s*$"),
              ("no case is changed", r"lowercased|uppercased|capitalized", 0))),
            ("iOS row", IOS_DETECTION_DETAIL, None,
             (("the row reads it",
               r'dossierRow\("matched on", methodChipLabel\(type: d\.type, method: d\.method, maker: d\.maker\)'),)),
            ("Android rule", AND_DETAIL_SCREEN,
             r"internal fun methodChipLabel\(type: DeviceType, method: Int, maker: String\?,"
             r" methodLabel: String\): String = when \{(.*?)\n\}",
             (("a Desert-mode row, by type, before any method",
               r'type == DeviceType\.NEARBY_DEVICE -> "no signature"\s*\n\s*method == 1 && maker != null'),
              ("vendor, then chipset, then the label as written",
               r'method == 1 && maker != null -> "OUI · VENDOR ONLY"\s*\n\s*'
               r'method == 1 -> "OUI · CHIPSET ONLY"\s*\n\s*else -> methodLabel\s*$'),
              ("no case is changed", r"lowercase|uppercase|capitalize", 0))),
            ("Android row", AND_DETAIL_SCREEN, None,
             (("the row reads it", r"\bmethodChipLabel\(d\.type, d\.method, d\.maker, d\.methodLabel\) to "),)),
        ),
    },
    {
        "what": "signal graph on one fixed dBm scale, STRONG over WEAK",
        "why": "the floor and ceiling are compared in SHARED_CONSTANTS; these hold that both"
               " phones clamp to them and place every reading by that fraction, never by the"
               " series' own min and max, and label the edges with the same two words",
        "sides": (
            ("iOS scale", IOS_COMPONENTS, None,
             (("clamped to the pinned edges",
               r"min\(max\(rssi, signalGraphFloorDbm\), signalGraphCeilingDbm\)"),
              ("each point placed by it", r"signalGraphFraction\(rssi: values\[i\]\)"))),
            ("iOS sparkline", IOS_COMPONENTS, r"\nstruct Sparkline: View \{(.*?)\n\}",
             (("no stretch to the series", r"\.min\(\)|\.max\(\)", 0),
              ("no line under two readings", r"if values\.count >= 2 \{"))),
            ("iOS edge words", IOS_DETECTION_DETAIL, None,
             (("STRONG at the top, WEAK at the bottom",
               r'Text\("STRONG"\)\s*\n\s*Spacer\(minLength: 0\)\s*\n\s*Text\("WEAK"\)'),)),
            ("Android scale", AND_DETAIL_SCREEN, None,
             (("clamped to the pinned edges",
               r"rssi\.coerceIn\(SIGNAL_GRAPH_FLOOR_DBM, SIGNAL_GRAPH_CEILING_DBM\)"),
              ("STRONG at the top, WEAK at the bottom",
               r'Kicker\("STRONG",[^\n]*\n\s*Kicker\("WEAK",'))),
            ("Android sparkline", AND_DETAIL_SCREEN,
             r"private fun DrawScope\.drawSparkline\((.*?)\n\}",
             (("each point placed by it", r"fun y\(v: Int\) = h - signalGraphFraction\(v\) \* h"),
              ("no stretch to the series", r"\.min\(\)|\.max\(\)|minOrNull|maxOrNull", 0),
              ("no line under two readings", r"if \(values\.size < 2\) return"))),
        ),
    },
    {
        "what": "drone operator keys appear only with an operator marker (Map legend and dossier"
                " caption)",
        "why": "a legend key or caption for a marker nothing draws reads as a rendering bug; both"
               " phones gate the key on the drawn markers and the caption on the pilot position",
        "sides": (
            ("iOS legend", IOS_MAP_TAB, None,
             (("the flag comes from the drawn overlays",
               r"hasOperatorPins: mapHasOperatorPins\(drones\.lazy\.map\(\\\.detection\)\)"),
              ("and gates the key",
               r'if snap\.hasOperatorPins \{\s*\n\s*Divider\(\)[^\n]*\n\s*legendEntry\("Drone operator"\)'))),
            ("iOS dossier", IOS_DETECTION_DETAIL, None,
             (("the caption needs a drone with a pilot position",
               r"if d\.type == \.drone, d\.pilotCoordinate != nil \{\s*\n\s*"
               r'Label\(droneOperatorCaption, systemImage: "person\.fill"\)'),)),
            ("Android legend", AND_MAP_SCREEN, None,
             (("the flag comes from the drawn markers",
               r"mapOperatorPinFlag\(hasOperatorPins, operatorPins\)\?\.let \{ hasOperatorPins = it \}"),
              ("and gates the key",
               r'if \(hasOperatorPins\) \{(?:(?!\bif \()[\s\S])*?Text\("Drone operator"'))),
            ("Android dossier", AND_DETAIL_SCREEN, None,
             (("the caption needs a drone with a valid pilot position",
               r"if \(d\.type == DeviceType\.DRONE && pla != null && plo != null && validCoord\(pla, plo\)\)"
               r" \{(?:(?!\bif \()[\s\S])*?Text\(DRONE_OPERATOR_CAPTION,"),)),
        ),
    },
    {
        "what": "the Map legend is a floating button and card; a download never opens it",
        "why": "owner decision 2026-09-26 (decisions R17): the legend is a round info button at"
               " the lower left that opens a card, and the map fills the tab. A docked legend that"
               " insets the map re-frames it on every toggle (the reported shift), and a download"
               " that opens the legend by itself takes the map away unasked. iOS keeps a constant"
               " bottom inset for MapKit's logo and Legal line; Android has no sheet at all",
        "sides": (
            ("iOS legend button", IOS_MAP_TAB, None,
             (("the button speaks open and downloading",
               r"mapLegendAccessibilityValue\(open: legendExpanded, downloading: alpr\.downloading\)"),
              ("and a download never opens the card", r"legendExpanded \|\| alpr\.downloading", 0),
              ("the map's bottom inset is the constant",
               r"\.safeAreaPadding\(\.bottom, mapFloatingControlsInset\)"))),
            ("Android legend button", AND_MAP_SCREEN, None,
             (("no bottom sheet", r"BottomSheetScaffold\(", 0),
              ("and nothing expands one", r"sheetState\.expand\(\)", 0),
              ("the button speaks open and downloading",
               r"stateDescription = mapLegendStateDescription\(open = legendOpen, downloading = alprDownloading\)"))),
        ),
    },
    # ---- decisions M3: the radar sweep ----
    {
        "what": "radar sweep angle comes from the absolute clock (beam kept mounted; Reduce Motion"
                " parks it at 0)",
        "why": "the owner reported the iOS beam as sporadic and resetting; the angle is now"
               " fract(time / period) x 360 of an absolute clock on both phones, so a re-render, a"
               " re-mount or a tab return continues the turn. A per-view start time or an implicit"
               " repeating animation on either phone brings the reset back",
        "sides": (
            ("iOS rule", IOS_COMPONENTS,
             r"\nfunc radarSweepDegrees\(at seconds: TimeInterval, period: TimeInterval ="
             r" RadarScope\.sweepPeriod\) -> Double \{(.*?)\n\}",
             (("fract of the absolute reading, times 360",
               r"let turns = seconds / period\s*\n\s*return \(turns - turns\.rounded\(\.down\)\) \* 360"),)),
            ("iOS beam", IOS_COMPONENTS, r"\nprivate struct SweepBeam: View \{(.*?)\n\}",
             (("a clock-driven timeline, paused when parked or under Reduce Motion",
               r"TimelineView\(\.animation\(minimumInterval: nil, paused: !running \|\| reduceMotion\)\)"),
              ("the angle is the frame date's",
               r"reduceMotion\s*\?\s*0 : radarSweepDegrees\(at: ctx\.date\.timeIntervalSinceReferenceDate\)"),
              ("no ancestor animation may interpolate it", r"\.transaction \{ \$0\.animation = nil \}"),
              ("hidden, not removed, while parked", r"\.opacity\(running \? 1 : 0\)"),
              ("no implicit repeating animation", r"repeatForever|withAnimation", 0),
              ("and no start on appear", r"onAppear", 0))),
            ("iOS scope", IOS_COMPONENTS, None,
             (("the beam is always mounted", r"^\s*SweepBeam\(size: s, running: sweeping\)\s*$"),)),
            ("Android rule", AND_STATUS_SCREEN,
             r"internal fun radarSweepDegrees\(timeMs: Long, periodMs: Long = RADAR_SWEEP_PERIOD_MS\):"
             r" Float =(.*?)\n\n",
             (("fract of the absolute reading, times 360",
               r"Math\.floorMod\(timeMs, periodMs\)\.toFloat\(\) / periodMs \* 360f"),)),
            ("Android scope", AND_STATUS_SCREEN, None,
             (("seeded from the frame clock's time base",
               r"mutableFloatStateOf\(radarSweepDegrees\(System\.nanoTime\(\) / 1_000_000\)\)"),
              ("advanced from each frame's own time",
               r"while \(true\) withFrameNanos \{ sweepAngle = radarSweepDegrees\(it / 1_000_000\) \}"),
              ("no loop while parked or under reduce motion",
               r"if \(!scanning \|\| reduceMotion\) return@LaunchedEffect"),
              ("parked at 0 under reduce motion", r"rotate\(if \(reduceMotion\) 0f else sweepAngle, c\)"),
              ("no infinite transition restarts it", r"rememberInfiniteTransition\(", 0))),
        ),
    },
    # The 2026-09-26 UI review batch (decisions R19): the two places a category name is drawn
    # beside other lowercase-first rows now read DeviceType.inlineLabel (whose arms
    # check_inline_labels pins byte for byte), never `label`, which mixes Title Case ("ALPR
    # Camera", "Body Camera") with sentence case ("Network camera") in one list.
    {
        "what": "Log row subtitle leads with inlineLabel (named rows), and the Notifications rows"
                " draw inlineLabel in row-title sentence case",
        "why": "a named Log row's subtitle and the seven Notifications row titles are one case on"
               " both phones; a side that goes back to `label` puts 'ALPR Camera' beside 'network"
               " camera' in the same list (review P2-5 and P2-11). Since P3-11 (decisions R20) every"
               " row title is sentence case, so the Notifications rows raise inlineLabel's first"
               " letter (iOS DeviceView.sentenceCaseRowTitle, Android rowTitleCase: 'Body cam',"
               " 'ALPR camera' unchanged) and the subtitle sentence keeps the bare lowercase name",
        "sides": (
            ("iOS Log row", IOS_DETECTION_ROW,
             r"\n    static func subtitle\(for d: Detection\) -> String \{(.*?)\n    \}",
             (("the named branch leads with inlineLabel",
               r'd\.hasName\s*\n\s*\? "\\\(d\.type\.inlineLabel\) \\u\{00B7\} \\\(d\.method\.label\)"'),
              ("and never with label", r"d\.type\.label", 0))),
            ("iOS Notifications rows", IOS_SETTINGS, None,
             (("the row title is inlineLabel in sentence case",
               r"\bradioToggle\(Self\.sentenceCaseRowTitle\(t\.inlineLabel\), notifySubtitle\(t\)"),
              ("never the bare lowercase name", r"\bradioToggle\(t\.inlineLabel,", 0),
              ("never label", r"\bradioToggle\((?:Self\.sentenceCaseRowTitle\()?t\.label", 0))),
            ("Android Log row", AND_LOG_SCREEN,
             r"\ninternal fun detectionRowSubtitle\(d: Detection\): String =(.*?)\n\n",
             (("the named branch leads with inlineLabel",
               r'if \(d\.hasName\) "\$\{d\.type\.inlineLabel\} · \$\{d\.methodLabel\}"'),
              ("and never with label", r"d\.type\.label", 0))),
            ("Android Notifications rows", AND_DEVICE_SCREEN, None,
             (("the row title is inlineLabel in sentence case",
               r"\bToggleRow\(rowTitleCase\(t\.inlineLabel\), notifySubtitle\(t\)"),
              ("never the bare lowercase name", r"\bToggleRow\(t\.inlineLabel,", 0),
              ("never label", r"\bToggleRow\((?:rowTitleCase\()?t\.label", 0))),
        ),
    },
    # The 2026-09-26 review's P3 batch (decisions R20).
    {
        "what": "the sample tour's dots speak the step, and no card draws it as text (P3-12)",
        "why": "'step N of 3' as text 8pt above a three-dot indicator said one thing twice, so the"
               " text is gone on both phones and the dots carry the words as their spoken value; a"
               " side that draws the text again, or drops the value, says it twice or not at all",
        "sides": (
            ("iOS words", IOS_FIRST_RUN_TOUR, None,
             (("one pure home for the words",
               r'static func tourStepValue\(page: Int, count: Int\) -> String \{ "step \\\(page \+ 1\) of \\\(count\)" \}'),
              ("the dots speak them",
               r"\.accessibilityValue\(FirstRunTour\.tourStepValue\(page: page, count: sampleCards\.count\)\)"),
              ("no card draws them", r'Text\("step ', 0))),
            ("Android words", AND_FIRST_RUN_TOUR, None,
             (("one pure home for the words",
               r'internal fun tourStepDescription\(page: Int, count: Int\): String = "step \$\{page \+ 1\} of \$count"'),
              ("the dots speak them", r"contentDescription = stepDescription"),
              ("read from that home", r"val stepDescription = tourStepDescription\(pager\.currentPage, cards\.size\)"),
              ("no card draws them", r'Text\(\s*(?:text = )?"step ', 0))),
        ),
    },
    {
        "what": "Reduce Motion is observed live on both phones (P3-13)",
        "why": "iOS reads the environment's accessibilityReduceMotion, which SwiftUI refreshes when"
               " the setting flips; Android's animator-duration-scale setting is not a"
               " configuration change, so a one-shot read on composition held the old verdict"
               " while the app stayed open. rememberReduceMotion registers a ContentObserver on"
               " the setting's URI for the ornament's composition lifetime and re-reads once after"
               " registering, so the radar sweep stops the moment the user removes animations",
        "sides": (
            ("iOS", IOS_COMPONENTS, None,
             (("the environment value, refreshed by the system",
               r"@Environment\(\\\.accessibilityReduceMotion\) private var reduceMotion"),)),
            ("Android", AND_COMPONENTS, r"\nfun rememberReduceMotion\(\): Boolean \{(.*?)\n\}",
             (("a remembered state, not a one-shot read",
               r"var reduce by remember\(resolver\) \{ mutableStateOf\(read\(\)\) \}"),
              ("an observer on the setting's own URI",
               r"Settings\.Global\.getUriFor\(Settings\.Global\.ANIMATOR_DURATION_SCALE\), false, observer\)"),
              ("that flips the state", r"override fun onChange\(selfChange: Boolean\) \{ reduce = read\(\) \}"),
              ("re-read once after registering, then released with the composition",
               r"reduce = read\(\)\s*\n\s*onDispose \{ resolver\.unregisterContentObserver\(observer\) \}"))),
        ),
    },
    # The wifi_band_ghz rule (owner request 2026-10-05); "detection CSV columns" pins the names.
    # Each needle spans the whole helper body, so a moved edge, a changed band word or an extra arm
    # on one phone fails.
    {
        "what": "Wi-Fi band thresholds (channels 1-14 are 2.4 GHz, 32-177 are 5 GHz, anything else"
                " has no band)",
        "why": "the CSV's wifi_band_ghz cell and the dossier's Wi-Fi channel row both read the band"
               " from this helper; a different edge on one phone files the same channel under a"
               " different band, or under none",
        "sides": (
            ("iOS", IOS_DETECTION,
             r"static func wifiBandGHz\(channel: Int\?\) -> String\? \{(.*?)\n    \}",
             (("the two bands and no other arm",
               r"\A\s*switch channel \{" + _KT_ARM_GAP
               + r'case \.some\(1\.\.\.14\):\s*return "2\.4"' + _KT_ARM_GAP
               + r'case \.some\(32\.\.\.177\):\s*return "5"' + _KT_ARM_GAP
               + r"default:\s*return nil" + _KT_ARM_GAP + r"\}\s*\Z"),)),
            ("Android", AND_DEVICE_TYPE,
             r"\nfun wifiBandGhz\(channel: Int\?\): String\? = when \(channel\) \{(.*?)\n\}",
             (("the two bands and no other arm",
               r"\A\s*null -> null" + _KT_ARM_GAP
               + r'in 1\.\.14 -> "2\.4"' + _KT_ARM_GAP
               + r'in 32\.\.177 -> "5"' + _KT_ARM_GAP
               + r"else -> null\s*\Z"),)),
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


# The board kind table (decisions R14): which product a board is, for COPY ONLY. Parsed per side
# rather than pinned as literals, because the two apps spell the table differently (a Swift enum
# with one switch per property, a Kotlin enum with one constructor row per kind), and then checked
# against what the firmware actually advertises and reports, so a renamed advert or fw label that
# would silently turn every OUI-Spy back into "beacon" fails here instead.
_BOARD_KIND_PROPS = (("noun", "noun"), ("aNoun", "aNoun"), ("plural", "plural"),
                     ("upperNoun", "nounUpper"), ("heroTitle", "heroTitle"))
# Every template hole, and the property that fills it on each side. {os_pairing_request} is the
# one hole that differs per app by design ("the iOS pairing request" / "Android's pairing request").
_BOARD_KIND_HOLES = {"{noun}": "noun", "{a_noun}": "aNoun", "{plural}": "plural",
                     "{NOUN}": "upperNoun", "{os_pairing_request}": None}


def _ios_board_kinds(text):
    """The iOS table as (raws in order, {prop: {raw: value}}, fw prefixes, exact names, name
    prefixes, holes), or a reason string. A Swift String enum's raw value is its case name."""
    block = re.findall(r"\nenum BoardKind: String[^{]*\{(.*?)\n\}", text, re.S)
    if len(block) != 1:
        return f"{len(block)} `enum BoardKind: String` blocks (expected exactly 1)"
    body = block[0]
    raws = re.findall(r"^    case (\w+)\s*$", body, re.M)
    props = {}
    for prop, _ in _BOARD_KIND_PROPS:
        sw = re.findall(r"var " + prop + r": String \{\s*switch self \{(.*?)\n        \}", body, re.S)
        if len(sw) != 1:
            return f"{len(sw)} `var {prop}` switches (expected exactly 1)"
        props[prop] = dict(re.findall(r'case \.(\w+): return "([^"]*)"', sw[0]))
    fw = re.findall(r'if label\.hasPrefix\("([^"]*)"\) \{ return \.(\w+) \}', body)
    exact = re.findall(r'if name == "([^"]*)" \{ return \.(\w+) \}', body)
    prefix = re.findall(r'if name\.hasPrefix\("([^"]*)"\) \{ return \.(\w+) \}', body)
    holes = dict(re.findall(r'\.replacingOccurrences\(of: "(\{\w+\})", with: (?:k\.)?(\w+)\)', text))
    return raws, props, fw, exact, prefix, holes


def _and_board_kinds(text):
    """The Android table in the same shape, raw values mapped from the enum names."""
    rows = re.findall(r'^    ([A-Z_]+)\(' + ", ".join(['"([^"]*)"'] * 6) + r'\)[,;]', text, re.M)
    if not rows:
        return "no `NAME(\"raw\", ...)` rows in enum class BoardKind"
    raw_of = {r[0]: r[1] for r in rows}
    raws = [r[1] for r in rows]
    props = {}
    for i, (prop, _) in enumerate(_BOARD_KIND_PROPS):
        props[prop] = {r[1]: r[2 + i] for r in rows}
    try:
        fw = [(p, raw_of[k]) for p, k in re.findall(r'label\.startsWith\("([^"]*)"\) -> ([A-Z_]+)', text)]
        exact = [(p, raw_of[k]) for p, k in re.findall(r'name == "([^"]*)" -> ([A-Z_]+)', text)]
        prefix = [(p, raw_of[k]) for p, k in re.findall(r'name\.startsWith\("([^"]*)"\) -> ([A-Z_]+)', text)]
    except KeyError as exc:
        return f"a resolver arm names {exc}, which is not a BoardKind row"
    and_prop = {a: i for i, a in _BOARD_KIND_PROPS}
    holes = {h: ("osPairingRequest" if v == "OS_PAIRING_REQUEST" else and_prop.get(v, v))
             for h, v in re.findall(r'\.replace\("(\{\w+\})", (?:k\.)?(\w+)\)', text)}
    return raws, props, fw, exact, prefix, holes


def _resolve_kind(name, exact, prefix):
    """What a side's fromAdvertName returns for `name`, walking its arms in source order (exact
    names first, as both sides write them)."""
    for n, raw in exact:
        if name == n:
            return raw
    for p, raw in prefix:
        if name.startswith(p):
            return raw
    return None


def check_board_kinds():
    """The board kind table and its detection rules: both apps agree, and both match the firmware."""
    print("\n== board kind table (copy only; both apps, and what the firmware sends) ==")
    sides = {}
    for label, rel, parse in (("iOS", IOS_BOARD_KIND, _ios_board_kinds),
                              ("Android", AND_BOARD_KIND, _and_board_kinds)):
        try:
            parsed = parse(read_local(rel))
        except OSError as exc:
            parsed = f"{rel} could not be read ({exc})"
        if isinstance(parsed, str):
            print(f"   !! {label} board kind table could not be read ({rel}): {parsed}")
            return 1
        sides[label] = parsed
    drift = 0
    (i_raws, i_props, i_fw, i_exact, i_prefix, i_holes) = sides["iOS"]
    (a_raws, a_props, a_fw, a_exact, a_prefix, a_holes) = sides["Android"]
    rows = [("raw values (stored; order)", i_raws, a_raws)]
    rows += [(f"{prop} per kind", i_props[prop], a_props[prop]) for prop, _ in _BOARD_KIND_PROPS]
    rows += [("fw label prefixes (in order)", i_fw, a_fw),
             ("exact advert names", i_exact, a_exact),
             ("advert name prefixes", i_prefix, a_prefix),
             ("template holes and what fills them", i_holes,
              {h: ("osPairingRequest" if v == "osPairingRequest" else v) for h, v in a_holes.items()})]
    for what, ios, android in rows:
        # An empty parse on both sides would "agree", so it is a failure, like _pinned_constant.
        if not ios or not android:
            print(f"   !! {what}: parsed to nothing on {'iOS' if not ios else 'Android'}")
            drift += 1
        elif ios != android:
            print(f"   !! {what} DIFFERS between the two apps")
            print(f"      iOS      {ios!r}")
            print(f"      Android  {android!r}")
            drift += 1
        else:
            shown = len(ios) if not isinstance(ios, dict) else ", ".join(f"{k}={v}" for k, v in ios.items())
            print(f"   ok: {what}: {shown}")
    want_holes = {h: (v or "osPairingRequest") for h, v in _BOARD_KIND_HOLES.items()}
    if i_holes != want_holes:
        print(f"   !! renderBoardCopy fills {i_holes!r}, expected {want_holes!r}")
        drift += 1
    # Against the firmware: each build's advert name and fw label must resolve to its own kind.
    # The literals are read from the two mains, so a rename there fails here.
    fw_side = []
    try:
        beacon = read_local(FW_BEACON_MAIN)
        mesh = read_local(FW_MESH_MAIN)
        names = re.findall(r'const char\* kBleName = "([^"]*)";', beacon)
        labels = re.findall(r'const char\* kFwLabel = "([^"]*)";', beacon)
        mesh_name = re.findall(r'acabBleBegin\("([^"]*)", fwLabel', mesh)
        mesh_label = re.findall(r'snprintf\(fwLabel, sizeof\(fwLabel\), "(mesh-detect[^"%]*)"\)', mesh)
        ini = read_local(FW_PLATFORMIO)
        ini_names = re.findall(r"""-DACAB_BLE_NAME='"([^"]*)"'""", ini)
        ini_labels = re.findall(r"""-DACAB_FW_LABEL='"([^"]*)"'""", ini)
    except OSError as exc:
        print(f"   !! firmware mains could not be read ({exc})")
        return drift + 1
    if len(names) != 2 or len(labels) != 2 or len(mesh_name) != 1 or len(mesh_label) != 1:
        print(f"   !! firmware identities moved: kBleName {names}, kFwLabel {labels},"
              f" mesh name {mesh_name}, mesh label {mesh_label} (expected 2, 2, 1, 1)")
        return drift + 1
    # beacon-board main.cpp declares the dual build's pair first ("beacon" / "beacon board"),
    # then the single-radio oui-spy's ("ACAB" / "ACAB-ouispy").
    expected = (("dual-radio beacon", names[0], labels[0], "beacon"),
                ("single-radio OUI-Spy", names[1], labels[1], "ouiSpy"),
                ("Mesh-Detect", mesh_name[0], mesh_label[0], "meshDetect"))
    # Beacon variants set identity by -D in platformio.ini (rev-B's label, beacon-c5's name and
    # label), which the literal search above cannot see; each must still read as a beacon.
    expected += tuple((f"beacon {l!r} (platformio.ini)", names[0], l, "beacon") for l in ini_labels)
    expected += tuple((f"beacon advert {n!r} (platformio.ini)", n, labels[0], "beacon") for n in ini_names)
    for build, name, label, raw in expected:
        for side, fw, exact, prefix in (("iOS", i_fw, i_exact, i_prefix),
                                        ("Android", a_fw, a_exact, a_prefix)):
            by_label = next((r for p, r in fw if label.startswith(p)), None)
            by_name = _resolve_kind(name, exact, prefix)
            if by_label != raw or by_name != raw:
                fw_side.append(f"{side}: the {build} build (advert {name!r}, fw {label!r}) reads"
                               f" as label {by_label}, name {by_name}; expected {raw}")
    # The app's own nameless fallback must never read as a kind.
    for side, exact, prefix in (("iOS", i_exact, i_prefix), ("Android", a_exact, a_prefix)):
        for nameless in ("", "ACAB-01", "AdaDFU"):
            if _resolve_kind(nameless, exact, prefix) is not None:
                fw_side.append(f"{side}: the advert name {nameless!r} reads as a kind")
    if fw_side:
        print("   !! the apps no longer name the firmware builds by their own kind")
        for line in fw_side:
            print(f"      {line}")
        print("      each build's advert name and fw label are what the apps read to name the board"
              " (docs/ble-protocol.md 'Board kinds'); a rename on either side makes an OUI-Spy"
              " read as a beacon, or the reverse")
        drift += 1
    else:
        print(f"   ok: every firmware build reads as its own kind on both apps"
              f" ({', '.join(f'{n}/{l}' for _, n, l, _ in expected)})")
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


def main():
    ap = argparse.ArgumentParser(
        description="ACAB signature + vendored-copy drift check (reports only, changes nothing)")
    ap.add_argument("--offline", action="store_true",
                    help="skip the upstream release watch instead of failing on an "
                         "unreachable network. For a bench run with no connectivity, NOT for CI: "
                         "a watcher that skipped itself has watched nothing.")
    args = ap.parse_args()
    print("ACAB signature drift check (reports only, changes nothing)")
    drift = (check_odid(args.offline)
             + check_faq_copies() + check_inline_labels()
             + check_shared_constants()
             + check_shared_shapes() + check_board_kinds() + check_map_refresh_ladder()
             + check_pin_priority()
             + check_privacy_contract())
    print()
    if drift:
        print(f"DRIFT: {drift} item(s) need a look. Review and re-port by hand.")
        sys.exit(1)
    print("No drift detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
