#!/usr/bin/env python3
"""PlatformIO pre-build step: make NimBLE-Arduino ask before it deletes a bond.

WHAT IT PATCHES. NimBLEServer::handleGapEvent's BLE_GAP_EVENT_REPEAT_PAIRING case, in both pinned
NimBLE-Arduino versions (1.4.3 on the S3 envs, 2.x on beacon-c5), deletes the peer's existing bond
and returns BLE_GAP_REPEAT_PAIRING_RETRY ("sacrifices security for convenience"). On this product
that let a peer merely presenting a bonded phone's address (its RPA is replayable) evict the owner's
bond and Just-Works pair in its place. The application cannot veto it from the custom GAP listener:
in both pinned hosts ble_gap_repeat_pairing_event calls only ble_gap_call_conn_event_cb, never the
listener list, so the library case itself is the one hook. The patch inserts, at the top of that
case, a call to acabRepeatPairingAllowed() (extern "C", defined NON-weak in
lib/acab_core/acab_ble_service.cpp, and in src/odid-sim/main.cpp for the simulator) and returns
BLE_GAP_REPEAT_PAIRING_IGNORE when it says no, before the delete. A weak default was ruled out: it
is a fail-open the linker can pick silently.

WHY A BUILD STEP AND NOT A FORK. The library is an exact lib_deps pin that PlatformIO installs into
.pio/libdeps/<env>/ (gitignored). A clean checkout, `pio pkg update` or a deleted .pio restores the
stock file, so a patch applied by hand would vanish silently. Re-applying it on every build makes
the stock text the thing that cannot ship.

WHEN IT RUNS. PlatformIO 6.x installs lib_deps before SCons starts (run/processor.py:
EnvironmentProcessor.process calls install_project_env_dependencies, then runs the platform), and
the LDF re-installs anything still missing from inside the build script (piolib.py:
ProjectAsLibBuilder.install_dependencies, called from ConfigureProjectLibBuilder), so the file
usually exists when this pre: script loads (builder/main.py loads pre: scripts before the
platform's build script) but is not guaranteed to. The patch is therefore applied from a build
middleware (env.AddBuildMiddleware on */NimBLE-Arduino/src/NimBLEServer.cpp): PlatformIO calls it
from CollectBuildFiles when it assembles the library's object list, after either install path and
before any compile command runs. A pre-link action on the .elf then checks that the middleware saw
the file and that it carries the patch, and aborts otherwise, so a build that somehow compiled the
stock text cannot link. stamp_app_desc.py hooks the same way on the .bin.

FAIL CLOSED. Text in the case that is neither the stock 1.4.3/2.x body nor the patched one (a
library bump), or the stock case found twice, aborts the build naming this file. Idempotent: an
already patched file passes untouched.

SELF-TEST (no PlatformIO needed, fixtures are generated):
    python3 -I tools/patch_nimble_repeat_pairing.py --selftest [scratch-dir]
"""
import os
import sys
import tempfile

SCRIPT = "tools/patch_nimble_repeat_pairing.py"
MARKER = "acabRepeatPairingAllowed"
CASE_OPEN = "        case BLE_GAP_EVENT_REPEAT_PAIRING: {\n"


def _stock(desc, rc_if):
    """The stock case body, byte-exact. The two versions differ only in the desc variable and in
    the brace spacing of the rc check (read from the pinned libraries 2026-10-11)."""
    return (
        CASE_OPEN
        + "            /* We already have a bond with the peer, but it is attempting to\n"
        + "             * establish a new secure link.  This app sacrifices security for\n"
        + "             * convenience: just throw away the old bond and accept the new link.\n"
        + "             */\n"
        + "\n"
        + "            /* Delete the old bond. */\n"
        + f"            rc = ble_gap_conn_find(event->repeat_pairing.conn_handle, &{desc});\n"
        + f"            {rc_if}\n"
        + "                return BLE_GAP_REPEAT_PAIRING_IGNORE;\n"
        + "            }\n"
        + "\n"
        + f"            ble_store_util_delete_peer(&{desc}.peer_id_addr);\n"
        + "\n"
        + "            /* Return BLE_GAP_REPEAT_PAIRING_RETRY to indicate that the host should\n"
        + "             * continue with the pairing operation.\n"
        + "             */\n"
        + "            return BLE_GAP_REPEAT_PAIRING_RETRY;\n"
        + "        } // BLE_GAP_EVENT_REPEAT_PAIRING\n"
    )


STOCK = {
    "1.4.3": _stock("desc", "if (rc != 0){"),
    "2.x": _stock("peerInfo.m_desc", "if (rc != 0) {"),
}
# The definition line the extern "C" declaration goes in front of (a linkage specification must
# sit at file scope, so it cannot ride inside the case).
HANDLER_DEF = {
    "1.4.3": "int NimBLEServer::handleGapEvent(struct ble_gap_event *event, void *arg) {\n",
    "2.x": "int NimBLEServer::handleGapEvent(ble_gap_event* event, void* arg) {\n",
}
GUARD = (
    "            /* ACAB (tools/patch_nimble_repeat_pairing.py): only the application knows whether\n"
    "             * a person just power-cycled the board, so ask it before the bond is deleted. */\n"
    "            if (!acabRepeatPairingAllowed()) {\n"
    "                return BLE_GAP_REPEAT_PAIRING_IGNORE;\n"
    "            }\n"
    "\n"
)
DECL = (
    "/* ACAB (tools/patch_nimble_repeat_pairing.py): lib/acab_core/acab_ble_service.cpp defines it. */\n"
    'extern "C" bool acabRepeatPairingAllowed(void);\n'
    "\n"
)


class PatchError(RuntimeError):
    pass


def patch_text(text):
    """Return (new_text, state); state is 'patched' or 'already'. Raises PatchError on anything
    that is not exactly one stock case or exactly one patched case."""
    for ver, stock in STOCK.items():
        defn = HANDLER_DEF[ver]
        patched = stock.replace(CASE_OPEN, CASE_OPEN + GUARD, 1)
        if text.count(patched) == 1 and text.count(DECL + defn) == 1 and text.count(MARKER) == 2:
            return text, "already"
        n = text.count(stock)
        if n > 1:
            raise PatchError(f"the stock {ver} REPEAT_PAIRING case appears {n} times")
        if n == 1:
            if MARKER in text:
                raise PatchError("stock REPEAT_PAIRING case next to a stray " + MARKER)
            if text.count(defn) != 1:
                raise PatchError(f"handleGapEvent definition for {ver} not found exactly once")
            return text.replace(stock, patched, 1).replace(defn, DECL + defn, 1), "patched"
    raise PatchError(
        "neither the stock nor the patched REPEAT_PAIRING case of NimBLE-Arduino 1.4.3 / 2.x is in "
        "this file: the library changed, re-read NimBLEServer.cpp and update " + SCRIPT
    )


def patch_file(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    new, state = patch_text(text)
    if state == "patched":
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
    return state


# ---- self-test ------------------------------------------------------------------------------------
def _fixture(ver):
    return (
        '#include "NimBLEServer.h"\n\n'
        + HANDLER_DEF[ver]
        + "    switch (event->type) {\n"
        + STOCK[ver]
        + "    }\n    return 0;\n}\n"
    )


def selftest(root):
    fails = 0

    def check(name, cond):
        nonlocal fails
        fails += 0 if cond else 1
        print(f"  {name:<70} {'PASS' if cond else '**FAIL**'}")

    def raises(path):
        try:
            patch_file(path)
        except PatchError:
            return True
        return False

    def write(path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    for ver in STOCK:
        d = os.path.join(root, ver.replace(".", "_"))
        f = os.path.join(d, "NimBLEServer.cpp")
        write(f, _fixture(ver))
        check(f"{ver}: stock fixture is patched", patch_file(f) == "patched")
        out = open(f, encoding="utf-8").read()
        check(f"{ver}: guard precedes the bond delete",
              GUARD in out and out.index(GUARD) < out.index("ble_store_util_delete_peer"))
        check(f"{ver}: guard sits at the top of the case", (CASE_OPEN + GUARD) in out)
        check(f"{ver}: extern C declaration precedes handleGapEvent", (DECL + HANDLER_DEF[ver]) in out)
        check(f"{ver}: the stock RETRY return is still there, once",
              out.count("return BLE_GAP_REPEAT_PAIRING_RETRY;") == 1)
        check(f"{ver}: second run is a no-op", patch_file(f) == "already")
        check(f"{ver}: second run changed no bytes", open(f, encoding="utf-8").read() == out)
        # Unknown text: the delete line reworded, as a library bump would do.
        write(f, _fixture(ver).replace("ble_store_util_delete_peer(", "ble_store_util_delete_peer_x("))
        check(f"{ver}: unknown case text aborts", raises(f))
        # The stock case twice (a second handler) must abort, not patch the first one.
        write(f, _fixture(ver) + "\nstatic int other(ble_gap_event* event) {\n    switch (event->type) {\n"
              + STOCK[ver] + "    }\n    return 0;\n}\n")
        check(f"{ver}: duplicated stock case aborts", raises(f))
        # A half-applied or edited patch (marker present, guard text wrong) must abort too.
        write(f, out.replace("if (!acabRepeatPairingAllowed())", "if (acabRepeatPairingAllowed())"))
        check(f"{ver}: mangled guard aborts", raises(f))
    check("the two stock bodies differ (both variants are really covered)", STOCK["1.4.3"] != STOCK["2.x"])
    print("  all good (0 failures)" if not fails else f"  {fails} FAILURE(S)")
    return 1 if fails else 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        root = argv[1] if len(argv) > 1 else tempfile.mkdtemp(prefix="nimble-patch-selftest-")
        print(f"patch_nimble_repeat_pairing selftest in {root}")
        return selftest(root)
    sys.stderr.write(f"usage: python3 -I {SCRIPT} --selftest [scratch-dir]\n"
                     "(PlatformIO runs this file itself as a pre: extra_script)\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

# ---- PlatformIO (SCons) mode: only reached when PlatformIO loads this as an extra_script ---------
Import("env")  # type: ignore[name-defined]  # supplied by PlatformIO/SCons

_seen = []


def _patch_node(node_env, node):
    path = node.srcnode().get_abspath()
    try:
        state = patch_file(path)
    except (PatchError, OSError) as exc:
        sys.stderr.write(f"\n{SCRIPT}: BUILD ABORTED: {path}: {exc}\n")
        node_env.Exit(1)
    _seen.append(path)
    print(f"{SCRIPT}: REPEAT_PAIRING guard {state}: {path}")
    return node


def _verify_before_link(source, target, env):  # pylint: disable=unused-argument
    # Every env here depends on NimBLE-Arduino, so a build in which the middleware never saw
    # NimBLEServer.cpp compiled something this script did not check: refuse to link it.
    if not _seen:
        sys.stderr.write(f"\n{SCRIPT}: BUILD ABORTED: NimBLEServer.cpp never reached the build "
                         "middleware, the REPEAT_PAIRING guard was not applied\n")
        env.Exit(1)
    for path in _seen:
        try:
            with open(path, encoding="utf-8") as fh:
                _, state = patch_text(fh.read())
        except (PatchError, OSError) as exc:
            state = str(exc)
        if state != "already":
            sys.stderr.write(f"\n{SCRIPT}: BUILD ABORTED: {path} is not patched at link time ({state})\n")
            env.Exit(1)
        # Printed on success as well: a check that is silent when it passes cannot be told apart,
        # in a build log, from one that never ran.
        print(f"{SCRIPT}: REPEAT_PAIRING guard verified before link: {path}")


env.AddBuildMiddleware(_patch_node, "*/NimBLE-Arduino/src/NimBLEServer.cpp")
# AddPreAction substitutes its target when called, and a pre: script runs while PROGNAME is still
# the core default "program"; both platform scripts (espressif32 and pioarduino builder/main.py)
# rename it to "firmware" only if it still reads "program" ("Allow user to override via
# pre:script"). Take that override so this binds to the .elf the platform really links; without
# it the check below would wait on program.elf and never run.
if env.get("PROGNAME", "program") == "program":
    env.Replace(PROGNAME="firmware")
env.AddPreAction("$BUILD_DIR/${PROGNAME}.elf", _verify_before_link)
