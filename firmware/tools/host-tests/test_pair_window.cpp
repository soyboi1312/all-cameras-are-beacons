// Host regression test for the new-phone pairing gate (pair_window.h).
//
// The window comparison is the security property: a stranger may bond only while it reads open.
// acab_ble_service.cpp, which calls it, is never host-compiled, so these checks are the only ones
// that can fail if the window stops closing.
#include "../../lib/acab_core/pair_window.h"
#include <cstdio>

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool got, bool want) {
    gRun++; if (got != want) gFail++;
    printf("  %-58s %s\n", name, got == want ? "PASS" : "**FAIL**");
}
static void chkU(const char* name, uint32_t got, uint32_t want) {
    gRun++; if (got != want) gFail++;
    printf("  %-58s %s\n", name, got == want ? "PASS" : "**FAIL**");
    if (got != want) printf("      got %u, wanted %u\n", got, want);
}

int main() {
    printf("\n=== new-phone pairing window ===\n");
    // esp_timer microseconds; T is an arbitrary opening time. `until` is the deadline the service
    // stores (acabBleOpenPairingWindow), and W is 120 s written out, NOT read from
    // ACAB_PAIR_WINDOW_MS, so a longer window or a ms/us slip in acabPairWindowUntilUsAt fails here.
    const uint64_t W = 120000000ULL, T = 5000000ULL;
    const uint64_t until = acabPairWindowUntilUsAt(T);
    chkU("never opened (until 0) is closed",          acabPairWindowRemainingMsAt(T, 0), 0);
    chkU("full 120 s window right after opening",     acabPairWindowRemainingMsAt(T, until), 120000);
    chkU("1 ms left at 120 s - 1 ms after opening",   acabPairWindowRemainingMsAt(T + W - 1000, until), 1);
    chkU("closed exactly 120 s after opening",        acabPairWindowRemainingMsAt(T + W, until), 0);
    // The old uint32 millis() comparison read OPEN again from 2^31 ms (~24.9 days) past expiry,
    // and any ms-truncated clock reads a boot-time window open again one 2^32 ms wrap later.
    chkU("closed ~25 days past expiry",
         acabPairWindowRemainingMsAt(T + W + 2147484ULL * 1000000, until), 0);
    chkU("closed one 2^32 ms wrap (~49.7 days) after opening",
         acabPairWindowRemainingMsAt(T + 4294967296ULL * 1000, until), 0);

    // ---- admission decision (acabPairAdmit) --------------------------------------------------
    printf("\n  -- connect-gate admission --\n");
    // The ONLY rejection there is. Every other combination admits.
    chk("owned board + stranger + window closed -> REJECT",
        acabPairAdmit(true, false, false), false);
    chk("owned board + stranger + window OPEN -> admit",
        acabPairAdmit(true, false, true), true);
    // The owner, always. This is the property that means an existing user never has to re-pair.
    chk("owned board + the owner + window closed -> admit",
        acabPairAdmit(true, true, false), true);
    // Out of the box: a unit that shipped weeks ago must connect on the first try, no ritual.
    chk("UNOWNED board + new phone + window closed -> admit (out-of-box)",
        acabPairAdmit(false, false, false), true);
    chk("UNOWNED board + new phone + window open -> admit",
        acabPairAdmit(false, false, true), true);

    // A raw GAP link is not an authenticated app session. A stranger admitted while the physical
    // window is open must finish encrypted bonding before either the window or the auth deadline
    // closes. Otherwise it could keep a pre-auth link alive indefinitely and suppress offline
    // logging without ever proving possession of a bond.
    printf("\n  -- pre-auth link --\n");
    chk("stranger may authenticate while physical window remains open",
        acabPairPreAuthMayContinue(true, false, true, 1000, 30000), true);
    chk("stranger is dropped when physical window closes before auth",
        acabPairPreAuthMayContinue(true, false, false, 1000, 30000), false);
    chk("known owner may authenticate after physical window closes",
        acabPairPreAuthMayContinue(true, true, false, 1000, 30000), true);
    chk("unowned first pairing is not tied to a physical window",
        acabPairPreAuthMayContinue(false, false, false, 1000, 30000), true);
    chk("every pre-auth link is dropped at the timeout boundary",
        acabPairPreAuthMayContinue(false, false, false, 30000, 30000), false);
    chk("elapsed subtraction remains valid across millis rollover",
        acabPairPreAuthMayContinue(true, true, false,
                                   (uint32_t)(0x00000010UL - 0xfffffff0UL), 30000), true);

    printf("\n  -- legacy nRF DFU physical/session gate --\n");
    chk("secure session during physical window may arm DFU",
        acabLegacyDfuMayArm(true, true), true);
    chk("pre-auth link cannot arm DFU",
        acabLegacyDfuMayArm(false, true), false);
    chk("remote session outside physical window cannot arm DFU",
        acabLegacyDfuMayArm(true, false), false);

    // ---- physical start (boot sequencing) -----------------------------------------------------
    // Args: (powerOnReset, deepSleepWake, cellAbsent, buttonHeld, switchLow, benchBuild)
    printf("\n  -- physical start --\n");

    // Power physically applied. True on any SKU regardless of what the switch or the NVS marker
    // says, because unplug/replug of a board that was ON still reports POWERON.
    chk("POWERON -> physical", acabPhysicalStart(true, false, false, false, false, false), true);
    chk("POWERON with the switch also on -> physical",
        acabPhysicalStart(true, false, false, false, true, false), true);

    // THE REGRESSION HARDWARE CAUGHT. A reflash / OTA / panic is neither POWERON nor a deep-sleep
    // wake, and on rev-A the slide switch still reads ON. Before the reset reason came back as an
    // input, switchLow alone made this true and the window opened after every flash (pairw=108s
    // observed on the board). It must be FALSE.
    chk("warm restart (OTA/panic/WDT) with the switch still ON -> NOT physical",
        acabPhysicalStart(false, false, false, false, true, false), false);
    chk("warm restart on a USB-only board (cellAbsent still true) -> NOT physical",
        acabPhysicalStart(false, false, true, false, false, false), false);
    chk("warm restart, nothing asserted -> NOT physical",
        acabPhysicalStart(false, false, false, false, false, false), false);

    // THE P1-2 CASE. Soft-off is deep sleep, so button-off then button-on wakes as
    // ESP_RST_DEEPSLEEP. The reset-reason-only version called that a warm boot and opened no
    // window, which meant the recovery the apps instruct did not work.
    chk("deep-sleep wake + button held -> physical (the documented recovery)",
        acabPhysicalStart(false, true, false, true, false, false), true);
    chk("deep-sleep wake + switch ON -> physical",
        acabPhysicalStart(false, true, false, false, true, false), true);
    chk("deep-sleep wake + USB-only board seeing power -> physical",
        acabPhysicalStart(false, true, true, false, false, false), true);
    // A wake nobody asked for (a stray ext0 bump with nothing held) must NOT arm.
    chk("deep-sleep wake with nothing held -> NOT physical",
        acabPhysicalStart(false, true, false, false, false, false), false);

    // Bench builds skip the power gate entirely; they must stay pairable or bring-up cannot connect.
    chk("bench build -> physical even on a warm restart",
        acabPhysicalStart(false, false, false, false, false, true), true);

    // ---- never-opened window (the P1-1 regression) ---------------------------------------------
    printf("\n  -- never-opened window: enforced but closed --\n");
    // A never-opened window (until 0) reads closed and enforcement is unconditional, so a stranger
    // is refused on an owned board. Enforcement once lived behind an opt-in flag that only the
    // window opener set, and every OTA restart, panic and watchdog then admitted any phone. That a
    // warm boot really leaves until at 0 is the mains' part: test_acab_ble_service.cpp pins their
    // only opener call inside the physical-start branch.
    const bool unopened = acabPairWindowRemainingMsAt(T, 0) != 0;
    chk("never opened: owned + stranger -> REJECT",
        acabPairAdmit(true, false, unopened), false);
    chk("never opened: the owner still reconnects",
        acabPairAdmit(true, true, unopened), true);

    printf(gFail ? "\n  REGRESSION DETECTED (%d of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
