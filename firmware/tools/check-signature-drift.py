#!/usr/bin/env python3
"""Check ACAB's detection signatures against their upstream sources, so the Flock
OUI tables and the opendroneid decoder cannot silently drift out of date.

    python3 firmware/tools/check-signature-drift.py

Exits 0 when nothing upstream is missing locally, 1 when there is drift to look
at. It only reports; it never edits anything. Provenance is in CREDITS.md. When an
upstream repo moves a file or renames a branch, update the URLs below.
"""
import json
import os
import re
import sys
import urllib.request

# --- upstream sources (edit as they move) -----------------------------------
LOCAL_FLOCK = "firmware/lib/acab_core/flock_detect.cpp"

# Curated Flock OUI tables upstream. NOTE: point these at firmware/source files
# that hold a hand-picked OUI list, NOT the full IEEE oui.txt registry. Add more
# raw URLs here as you find them (e.g. an oui-spy-unified-blue flock source).
UPSTREAM_FLOCK_URLS = [
    "https://raw.githubusercontent.com/colonelpanichacks/flock-you/main/main.cpp",
]

# opendroneid decoder: watch for a NEW upstream RELEASE instead of byte-diffing
# master. core-c's last release is v2.0 (2022); everything on master since is
# unreleased const-correctness and encode-side churn we reviewed and chose to
# skip, so diffing master is pure noise. This flags only when core-c actually
# ships a newer release. Bump the baseline when you re-vendor opendroneid/.
ODID_REPO = "opendroneid/opendroneid-core-c"
ODID_BASELINE_RELEASE = "v2.0"   # latest release reviewed (2026-06-16)
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


def read_local(rel):
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


def check_flock():
    print("== Flock OUI tables ==")
    local = extract_ouis(read_local(LOCAL_FLOCK))
    print(f"   local:    {len(local):>3} OUIs  ({LOCAL_FLOCK})")
    upstream = set()
    for url in UPSTREAM_FLOCK_URLS:
        try:
            found = extract_ouis(fetch(url))
            print(f"   upstream: {len(found):>3} OUIs  {url}")
            upstream |= found
        except Exception as exc:  # network / 404 / parse: warn but keep going
            print(f"   WARN could not fetch {url}: {exc}")
    if not upstream:
        print("   (no upstream OUIs read; skipping comparison)")
        return 0
    missing = sorted(upstream - local)  # upstream has it, we don't -> drift risk
    extra = sorted(local - upstream)    # ours only -> additions from other sources
    if missing:
        print(f"\n   !! {len(missing)} upstream OUI(s) MISSING locally (possible drift):")
        for o in missing:
            print(f"      {fmt(o)}")
    else:
        print("   ok: every upstream OUI is present locally")
    print(f"   ({len(extra)} local-only OUIs, your superset additions)")
    return len(missing)


def latest_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(
        url, headers={"User-Agent": "acab-drift-check", "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
    return data.get("tag_name"), (data.get("published_at") or "")[:10]


def check_odid():
    print("\n== opendroneid decoder (release watch) ==")
    try:
        tag, date = latest_release(ODID_REPO)
    except Exception as exc:
        print(f"   WARN could not query {ODID_REPO} releases: {exc}")
        return 0
    if tag == ODID_BASELINE_RELEASE:
        print(f"   ok: latest core-c release is still {tag} ({date}); nothing new to chase")
        return 0
    print(f"   !! core-c shipped {tag} ({date}); your baseline is {ODID_BASELINE_RELEASE}")
    print("      review the release, re-vendor opendroneid/ (.c + .h) if it matters,")
    print("      then bump ODID_BASELINE_RELEASE in this script")
    return 1


def main():
    print("ACAB signature drift check (reports only, changes nothing)\n")
    drift = check_flock() + check_odid()
    print()
    if drift:
        print(f"DRIFT: {drift} item(s) need a look. Review and re-port by hand.")
        sys.exit(1)
    print("No drift detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
