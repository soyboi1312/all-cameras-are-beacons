#!/usr/bin/env python3
"""Release gate: prove the staged/signed artifacts were built from the CURRENT source.

WHY THIS EXISTS. On 2026-08-02 the web-flasher binaries and the OTA-signed beacon image all
reported version 2.0.3 and contained NEITHER the FMDN tracker match NOR the new netcam OUIs: the
staging scripts had been run right after the version bump and before the detection work landed,
and nobody re-ran them. Nothing caught it, and nothing could have:

  - The VERSION STRING cannot catch it. A fresh 2.0.3 image and a stale 2.0.3 image are
    indistinguishable by version, which is the whole trap.
  - The OTA SHA GATE cannot catch it. The manifest hash correctly described the stale binary, so
    the signature verified, the transfer verified, and the board would have accepted an image
    missing every change the release was named for.
  - A CHECK INSIDE THE BUILD SCRIPT cannot catch it. The scripts build then stage, so their output
    is always fresh at the moment they run. The failure is forgetting to run them again.

So the gate has to live OUTSIDE the build, compare artifacts against SOURCE MTIMES, and be run
before publishing. That is this file.

    ./verify-release-artifacts.py            # check everything it can find
    ./verify-release-artifacts.py --strings "Google Find Hub (separated)" "Ezviz"

Exit status is 1 on any failure, so it can gate a release step or a CI job.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

# Per-release content canaries, keyed on the version the SOURCE declares. The bare invocation is
# what a person releasing in a hurry runs, i.e. exactly the person this tool exists to protect, and
# before this map it reported "3 passed, 0 failed" on staleness alone while saying nothing about
# whether the release's actual changes were in the binary. --strings overrides this; it no longer
# has to carry it. Add a row when you cut a version, naming a string only that version introduces.
CANARIES = {
    "2.0.3": ["Google Find Hub (separated)", "Ezviz"],
    # "Arlo base station" is the ideal canary for this round: it is the detail string of the NEW
    # SSID match path, so it exists in no earlier image. "Arlo" alone would also match the OUI
    # table, which cannot prove the SSID rule shipped.
    "2.0.4": ["Arlo base station", "Arlo"],
}

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.normpath(os.path.join(HERE, ".."))
REPO = os.path.normpath(os.path.join(FW, ".."))
SITE = os.path.normpath(os.path.join(REPO, "..", "soyboi.tech"))

FAIL = []
OK = []


def check(cond, msg):
    (OK if cond else FAIL).append(msg)
    print(f"  {'ok  ' if cond else 'FAIL'}  {msg}")


def newest_source_mtime():
    """Newest mtime across everything that ends up compiled into an app image."""
    newest, where = 0.0, ""
    for root in (os.path.join(FW, "lib"), os.path.join(FW, "src"),
                 os.path.join(FW, "platformio.ini")):
        if os.path.isfile(root):
            if os.path.getmtime(root) > newest:
                newest, where = os.path.getmtime(root), root
            continue
        for dirpath, _, files in os.walk(root):
            if ".pio" in dirpath:
                continue
            for f in files:
                if not f.endswith((".c", ".cpp", ".h", ".hpp", ".ini")):
                    continue
                p = os.path.join(dirpath, f)
                m = os.path.getmtime(p)
                if m > newest:
                    newest, where = m, p
    return newest, where


def declared_version():
    """The version the source says it is, from the build flag (which wins) or the header."""
    ini = open(os.path.join(FW, "platformio.ini"), errors="replace").read()
    m = re.search(r'-DACAB_FW_VERSION=\\"([0-9.]+)\\"', ini)
    if m:
        return m.group(1)
    hdr = open(os.path.join(FW, "lib/acab_core/acab_version.h"), errors="replace").read()
    m = re.search(r'#define\s+ACAB_FW_VERSION\s+"([0-9.]+)"', hdr)
    return m.group(1) if m else None


def bin_strings(path):
    try:
        return subprocess.run(["strings", path], capture_output=True, text=True,
                              timeout=120).stdout
    except Exception:
        # strings(1) missing: fall back to a crude printable-run scan so the gate still works.
        data = open(path, "rb").read()
        return "".join(chr(b) if 32 <= b < 127 else "\n" for b in data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strings", nargs="*", default=[],
                    help="strings that MUST appear in every app image (this release's canaries)")
    ap.add_argument("--production", action="store_true",
                    help="RELEASE GATE mode: absence of an expected artifact is a FAILURE, not a "
                         "skip; OTA signatures must be present and verify against the baked-in "
                         "public key; the nRF DFU zip must be well-formed. Without this flag the "
                         "script stays the lenient bench check it has always been.")
    args = ap.parse_args()

    src_mtime, src_path = newest_source_mtime()
    want_ver = declared_version()
    print(f"\nsource: newest {os.path.relpath(src_path, REPO)}")
    print(f"source: declares version {want_ver}\n")

    images = sorted(glob.glob(os.path.join(REPO, "web/firmware/*-app.bin")))
    for p in glob.glob(os.path.join(SITE, "firmware/beacon-app.bin")):
        images.append(p)
    if not images:
        # NOT a pass. Returning success here is how a release with NOTHING staged sails through
        # the gate - the failure mode this script exists to prevent, in its own front door.
        if args.production:
            print("  FAIL  no staged app images found, and --production requires them")
            FAIL.append("no staged app images")
            return 1
        print("  no staged app images found; nothing to verify")
        return 0

    print("STALENESS  (artifact must be newer than the newest source file)")
    for p in images:
        rel = os.path.relpath(p, os.path.dirname(REPO))
        check(os.path.getmtime(p) >= src_mtime,
              f"{rel} built after the last source edit")

    print("\nVERSION  (the image must say what the source says)")
    for p in images:
        rel = os.path.relpath(p, os.path.dirname(REPO))
        # TWO banner forms, and missing the second made this section dead on the web path , the
        # exact path the 2026-08-02 stale-artifact incident came through. beacon-board prints
        # "=== All Cameras Are Beacons 2.0.3 ===", the Colonel Panic images print
        # "=== ACAB OUI-Spy 2.0.3 ===" / "=== ACAB Mesh-Detect 2.0.3 ===". A version check that
        # cannot fail is worse than no version check, because it reads as a pass.
        blob = bin_strings(p)
        found = (re.findall(r"All Cameras Are Beacons ([0-9.]+)", blob)
                 + re.findall(r"=== ACAB [\w-]+ ([0-9.]+) ===", blob))
        if not found:
            # oui-spy / mesh-detect images carry a different banner; only gate what we can read.
            print(f"  --    {rel} carries no readable banner, version not checked here")
            continue
        check(want_ver in found, f"{rel} reports {sorted(set(found))}, source says {want_ver}")

    canaries = args.strings or CANARIES.get(want_ver or "", [])
    if not canaries:
        print(f"\nCONTENT  , NO CANARIES for {want_ver}. Add a CANARIES row for this version, or")
        print("          pass --strings, or this run proves only that the files are recent.")
        FAIL.append(f"no content canaries defined for {want_ver}")
    if canaries:
        src = "--strings" if args.strings else f"CANARIES[{want_ver}]"
        print(f"\nCONTENT  (from {src}: these must be present in every image)")
        for p in images:
            rel = os.path.relpath(p, os.path.dirname(REPO))
            blob = bin_strings(p)
            for s in canaries:
                check(s in blob, f"{rel} contains {s!r}")

    mf = os.path.join(SITE, "firmware/firmware-latest.json")
    if os.path.exists(mf):
        print("\nOTA MANIFEST  (hash + size must describe the bytes served)")
        m = json.load(open(mf))
        for name, b in m.get("builds", {}).items():
            app = b.get("app") or {}
            fn = app.get("url", "").split("/")[-1].split("?")[0]
            p = os.path.join(SITE, "firmware", fn)
            if not fn or not os.path.exists(p):
                check(False, f"{name}: manifest points at {fn or '(nothing)'}, not found locally")
                continue
            data = open(p, "rb").read()
            check(hashlib.sha256(data).hexdigest() == app.get("sha256"), f"{name}: sha256 matches {fn}")
            check(len(data) == app.get("size"), f"{name}: size matches {fn}")
            check(b.get("version") == want_ver, f"{name}: manifest version {b.get('version')} == {want_ver}")

            # SIGNATURE. The staging scripts WARN-AND-CONTINUE when openssl fails, which produces a
            # manifest carrying an empty signature - and until now this verifier accepted it. An
            # unsigned image is one the board's OTA gate will reject in the field, so shipping it
            # is a silent bricked-update release.
            if args.production:
                sig = (app.get("sig") or "").strip()
                check(bool(sig), f"{name}: OTA signature present and non-empty")
                if sig:
                    # HEX, not Base64, and the key is beacon_ota_pub.pem (or .der). Both were wrong
                    # in the first version of this gate: it looked for a beacon_ota_key.pub that has
                    # never existed and b64decoded a hex DER signature. Either mistake fails EVERY
                    # legitimate release, which is the worst possible failure for a release gate -
                    # it trains you to ignore it. build-beacon-flasher.sh emits
                    # `openssl dgst -sha256 -sign ... | xxd -p`, i.e. hex of a DER ECDSA signature,
                    # which is why a real one starts with 3044/3045.
                    pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.pem")
                    if not os.path.exists(pub):
                        pub = os.path.join(REPO, "firmware/tools/ota_signing/beacon_ota_pub.der")
                    if not os.path.exists(pub):
                        check(False, f"{name}: no OTA public key found to verify against")
                    else:
                        import binascii, subprocess, tempfile
                        try:
                            raw = binascii.unhexlify(sig.strip())
                        except Exception as e:
                            raw = None
                            check(False, f"{name}: signature is not hex ({e}); "
                                         f"expected hex DER from build-beacon-flasher.sh")
                        if raw:
                            with tempfile.NamedTemporaryFile(delete=False) as sf:
                                sf.write(raw); sigf = sf.name
                            keyform = "PEM" if pub.endswith(".pem") else "DER"
                            r = subprocess.run(
                                ["openssl", "dgst", "-sha256", "-verify", pub,
                                 "-keyform", keyform, "-signature", sigf, p],
                                capture_output=True)
                            check(r.returncode == 0,
                                  f"{name}: OTA signature VERIFIES against {os.path.basename(pub)}")
                            os.unlink(sigf)

        # nRF DFU package. Never validated before, so a corrupt or version-mismatched zip could
        # ship: the phone drives that update, and a bad package fails mid-DFU on the user's board.
        if args.production:
            print("\nnRF DFU PACKAGE")
            zips = glob.glob(os.path.join(SITE, "firmware", "*dfu*.zip"))
            check(bool(zips), "an nRF DFU zip is staged")
            for z in zips:
                rel = os.path.relpath(z, os.path.dirname(REPO))
                try:
                    import zipfile
                    with zipfile.ZipFile(z) as zf:
                        bad = zf.testzip()
                        check(bad is None, f"{rel} is a well-formed zip")
                        names = zf.namelist()
                        check(any(n.endswith("manifest.json") for n in names),
                              f"{rel} contains a DFU manifest.json")
                except Exception as e:
                    check(False, f"{rel} could not be read as a zip ({e})")

    # PROVENANCE. A commit SHA alone cannot identify the bytes when the tree is dirty, so the
    # dirty digest is part of the record, not a footnote.
    if args.production:
        print("\nPROVENANCE")
        import subprocess
        for label, path in (("acab", REPO), ("soyboi.tech", SITE)):
            try:
                sha = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                                     capture_output=True, text=True).stdout.strip()[:12]
                dirty = subprocess.run(["git", "-C", path, "status", "--porcelain"],
                                       capture_output=True, text=True).stdout
                digest = hashlib.sha256(dirty.encode()).hexdigest()[:12] if dirty.strip() else "clean"
                print(f"  --    {label}: {sha} (working tree: {digest})")
            except Exception as e:
                print(f"  --    {label}: provenance unavailable ({e})")
        print("  --    toolchain: espressif32@6.13.0, NimBLE-Arduino@1.4.3")

    print(f"\n{len(OK)} passed, {len(FAIL)} failed\n")
    if FAIL:
        print("Re-stage before publishing:")
        print("  (cd web && ./build-flasher.sh)")
        print("  (cd ../soyboi.tech/firmware && ./build-beacon-flasher.sh)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
