// Host regression tests for the real OTA state machine (ota_update.cpp).
//
// The source is included into this translation unit, not compiled beside it, so each case can
// reset the module's file-static session state the way a reboot would. run.sh's header-only
// branch builds this file alone (there is no ota_update_detect.cpp; ota_update.h exists).
//
// What the stubs stand in for: Update records begin/write/abort/end and never validates bytes;
// mbedtls pk accepts exactly one (digest, signature) pair the test registers as the offline
// signer's output; esp_ota_ops is a two-slot layout whose descriptors the test dictates;
// Preferences is the shared in-memory NVS. None of that is cryptography. What the suite proves is
// the ORDER and the FAIL-CLOSED shape of the real code: which refusals happen before Update.end,
// what NVS holds when the slot switches, and how trial boots are counted.
#define ACAB_HOST_TEST
// Every product env carries -DACAB_OTA_VERSION_FLOOR ([env] build_flags in platformio.ini), so
// the floor branch is production code and this suite compiles it in.
#define ACAB_OTA_VERSION_FLOOR
#include "../../lib/acab_core/ota_update.cpp"
#include "host_check.h"
#include <cstdio>
#include <cstring>
#include <vector>

static const char* kProject = "beacon board";
static bool hostHealthy = false;
static bool healthCheck() { return hostHealthy; }

static void setDesc(esp_app_desc_t& d, const char* ver, const char* project) {
    memset(&d, 0, sizeof(d));
    snprintf(d.version, sizeof(d.version), "%s", ver);
    snprintf(d.project_name, sizeof(d.project_name), "%s", project);
}

static uint32_t nvsU32(const char* key) {
    Preferences p;
    if (!p.begin("ota", true)) return 0xFFFFFFFFu;
    const uint32_t v = p.getUInt(key, 0);
    p.end();
    return v;
}
static uint8_t nvsU8(const char* key) {
    Preferences p;
    if (!p.begin("ota", true)) return 0xFF;
    const uint8_t v = p.getUChar(key, 0);
    p.end();
    return v;
}

// A board running ACAB_FW_VERSION in slot 0 with a clean NVS "ota" namespace and no session.
static void freshBoard(uint32_t floor = 0) {
    otaAbort();                       // tears down any open session and drops a pending signature
    gOnTrial = false; gDeclaredVersion = 0; gForce = false;
    Preferences::wipeAll();
    Update.reset();
    acabHostOtaReset();
    acabHostWakeupCause = ESP_SLEEP_WAKEUP_UNDEFINED;
    acabHostPkGoodSig.clear();
    memset(acabHostPkGoodDigest, 0, sizeof(acabHostPkGoodDigest));
    acabHostPkVerifyCalls = 0;
    ESP.restarts = 0;
    hostHealthy = false;
    acabHostSetMillis(1000);
    setDesc(acabHostRunningDesc, ACAB_FW_VERSION, kProject);
    otaSetHealthCheck(healthCheck);
    if (floor) { Preferences p; p.begin("ota", false); p.putUInt("floor", floor); p.end(); }
}

// The sample image and "the offline signer's" signature over it.
static std::vector<uint8_t> sampleImage() {
    std::vector<uint8_t> img(300);
    for (size_t i = 0; i < img.size(); i++) img[i] = (uint8_t)(0xE9 ^ (i * 7));   // 0xE9: ESP image magic
    return img;
}
static std::vector<uint8_t> goodSig() {
    std::vector<uint8_t> sig(70);
    for (size_t i = 0; i < sig.size(); i++) sig[i] = (uint8_t)(0x30 + i);
    return sig;
}
// Register sig as valid over exactly these bytes.
static void signImage(const std::vector<uint8_t>& img, const std::vector<uint8_t>& sig) {
    acabHostPkGoodSig = sig;
    mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), img.data(), img.size(), acabHostPkGoodDigest);
}

enum SigMode { SIG_GOOD, SIG_BAD, SIG_NONE };

// One whole client flow: sig control, begin, two data chunks, end. `stamped*` is what the written
// slot's descriptor reads (on the board that is inside the image bytes; here the test states it).
// Returns the begin result when begin refuses, else the finish result.
static OtaResult pushImage(const char* declaredVer, const char* stampedVer, const char* stampedProject,
                           bool force = false, SigMode sigMode = SIG_GOOD, bool tamper = false) {
    std::vector<uint8_t> img = sampleImage();
    const std::vector<uint8_t> sig = goodSig();
    signImage(img, sig);
    if (tamper) img[img.size() / 2] ^= 0x01;   // the image the board receives is not the one signed
    setDesc(acabHostPendingDesc, stampedVer, stampedProject);
    if (sigMode == SIG_GOOD) otaSetSignature(sig.data(), sig.size());
    if (sigMode == SIG_BAD) { std::vector<uint8_t> bad = sig; bad[10] ^= 0x80; otaSetSignature(bad.data(), bad.size()); }
    const OtaResult b = otaBegin((uint32_t)img.size(), 0, declaredVer, force);
    if (b != OTA_OK) return b;
    const size_t half = img.size() / 2;
    if (otaWrite(img.data(), half) != OTA_OK) return OTA_ERR_WRITE;
    if (otaWrite(img.data() + half, img.size() - half) != OTA_OK) return OTA_ERR_WRITE;
    return otaFinish();
}

// The restart into a slot: RAM state is gone, the bootloader runs that slot's image, setup()
// calls otaBootCheck first.
static void rebootInto(const esp_partition_t* slot, const char* ver, bool ext0 = false) {
    acabHostRunningSlot = slot;
    setDesc(acabHostRunningDesc, ver, kProject);
    acabHostWakeupCause = ext0 ? ESP_SLEEP_WAKEUP_EXT0 : ESP_SLEEP_WAKEUP_UNDEFINED;
    gOnTrial = false;
    otaBootCheck();
}

static bool refusedUncommitted(OtaResult got, OtaResult want) {
    return got == want && Update.committed == 0 && Update.endCalls == 0 && !otaInProgress()
        && nvsU8("state") == 0;
}

int main() {
    printf("\n=== ota_update state machine ===\n");
    const uint32_t cur = acabOtaVersionPack(ACAB_FW_VERSION);
    // "newer" and "older" relative to the compiled-in ACAB_FW_VERSION, so a release bump does not
    // turn every newer push below into OTA_ERR_VERSION at otaBegin. 0.0.1 sits below any shipped
    // version. acabOtaVersionPack caps a field at 1023, so pat+2 stays packable for any real patch.
    unsigned maj = 0, mnr = 0, pat = 0;
    sscanf(ACAB_FW_VERSION, "%u.%u.%u", &maj, &mnr, &pat);
    char kNewer[40], kNewer2[40];
    snprintf(kNewer,  sizeof kNewer,  "%u.%u.%u", maj, mnr, pat + 1);
    snprintf(kNewer2, sizeof kNewer2, "%u.%u.%u", maj, mnr, pat + 2);
    const char* kOlder = "0.0.1";

    // ---- stub self-check: the streaming digest the module computes must equal the one-shot the
    // test registers with the pk stub, or every signature case below would fail for the wrong reason.
    {
        std::vector<uint8_t> img = sampleImage();
        uint8_t oneShot[32], streamed[32];
        mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), img.data(), img.size(), oneShot);
        mbedtls_md_context_t c; mbedtls_md_init(&c);
        mbedtls_md_setup(&c, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 0); mbedtls_md_starts(&c);
        mbedtls_md_update(&c, img.data(), 7); mbedtls_md_update(&c, img.data() + 7, img.size() - 7);
        mbedtls_md_finish(&c, streamed); mbedtls_md_free(&c);
        chk("stub: chunked md digest equals one-shot", memcmp(oneShot, streamed, 32) == 0, true);
    }

    // ---- the accepted path: what a committed image leaves behind ----------------------------------
    freshBoard(cur);
    {
        uint8_t stateAtEnd = 0xFF;
        Update.onEnd = [&]{ stateAtEnd = nvsU8("state"); };
        const OtaResult r = pushImage(kNewer, kNewer, kProject);
        chk("good image commits", r == OTA_OK && Update.committed == 1 && !otaInProgress(), true);
        chk("trial record armed for the written slot",
            nvsU8("state") == 1 && nvsU8("tries") == 0 && nvsU32("target") == acabHostOtaSlot1.address
                && nvsU32("trialver") == acabOtaVersionPack(kNewer), true);
        chk("trial record durable BEFORE the slot switch", stateAtEnd == 1, true);
        chk("whole image reached Update", Update.image == sampleImage(), true);
        Update.onEnd = nullptr;
    }

    // ---- signature: fail closed, nothing committed ----------------------------------------------
    freshBoard(cur);
    chk("missing sig refused, verifier never consulted",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject, false, SIG_NONE), OTA_ERR_SIG)
            && acabHostPkVerifyCalls == 0, true);
    freshBoard(cur);
    chk("bad sig refused", refusedUncommitted(pushImage(kNewer, kNewer, kProject, false, SIG_BAD), OTA_ERR_SIG), true);
    freshBoard(cur);
    chk("good sig over other bytes refused",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject, false, SIG_GOOD, true), OTA_ERR_SIG), true);

    // ---- identity and version binding to the authenticated descriptor --------------------------
    freshBoard(cur);
    chk("project_name mismatch refused",
        refusedUncommitted(pushImage(kNewer, kNewer, "beacon board rev-B"), OTA_ERR_IMAGE), true);
    freshBoard(cur);
    acabHostPendingDescReadable = false;
    chk("unreadable pending descriptor refused",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject), OTA_ERR_IMAGE), true);
    freshBoard(cur);
    chk("declared != authenticated version refused",
        refusedUncommitted(pushImage(kNewer, kNewer2, kProject), OTA_ERR_VERSION), true);
    freshBoard(cur);
    chk("unstamped (zero) authenticated version refused",
        refusedUncommitted(pushImage(kNewer, "", kProject), OTA_ERR_VERSION), true);

    // ---- confirmed floor: a USB downgrade leaves the floor above the running version ---------------
    freshBoard(acabOtaVersionPack(kNewer2));
    chk("below the confirmed floor refused at finish",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject), OTA_ERR_VERSION), true);
    freshBoard(acabOtaVersionPack(kNewer));
    chk("equal to the confirmed floor accepted", pushImage(kNewer, kNewer, kProject) == OTA_OK, true);
    freshBoard(cur);
    Preferences::failNextBegin(1);   // the floor read is the first NVS open in otaDoFinish
    chk("unreadable floor fails closed",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject), OTA_ERR_VERSION), true);

    // ---- force: the same version, never a lower one ----------------------------------------------
    freshBoard(cur);
    chk("same version refused without force", pushImage(ACAB_FW_VERSION, ACAB_FW_VERSION, kProject) == OTA_ERR_VERSION
            && Update.endCalls == 0, true);
    freshBoard(cur);
    chk("force admits the same version", pushImage(ACAB_FW_VERSION, ACAB_FW_VERSION, kProject, true) == OTA_OK, true);
    freshBoard(cur);
    chk("force never admits a lower version at begin",
        otaBegin(300, 0, kOlder, true) == OTA_ERR_VERSION && !otaInProgress(), true);
    freshBoard(cur);
    chk("busy: a second begin is refused while a session is open",
        otaBegin(300, 0, kNewer, false) == OTA_OK && otaBegin(300, 0, kNewer, false) == OTA_ERR_BUSY, true);

    // ---- trial record write order and Update.end failure -------------------------------------------
    freshBoard(cur);
    Preferences::failNextPutUInt("ota", "target");
    chk("a failed record write leaves state 0 (state written last)",
        refusedUncommitted(pushImage(kNewer, kNewer, kProject), OTA_ERR_STATE), true);
    freshBoard(cur);
    Update.endOk = false;
    chk("Update.end failure clears the prepared record",
        pushImage(kNewer, kNewer, kProject) == OTA_ERR_IMAGE && nvsU8("state") == 0
            && nvsU32("target") == 0 && nvsU32("trialver") == 0 && !otaInProgress(), true);

    // ---- boot accounting -------------------------------------------------------------------------
    // Arm a real trial, then boot into it.
    freshBoard(cur);
    chk("arm trial for the boot cases", pushImage(kNewer, kNewer, kProject) == OTA_OK, true);
    rebootInto(&acabHostOtaSlot1, kNewer);
    chk("first trial boot counts and stays armed",
        otaOnTrial() && nvsU8("tries") == 1 && nvsU8("state") == 1 && acabHostSetBootCalls == 0, true);
    rebootInto(&acabHostOtaSlot1, kNewer, /*ext0=*/true);
    rebootInto(&acabHostOtaSlot1, kNewer, /*ext0=*/true);
    chk("EXT0 wake boots are not tries",
        otaOnTrial() && nvsU8("tries") == 1 && acabHostSetBootCalls == 0 && acabHostRestarts == 0, true);
    rebootInto(&acabHostOtaSlot1, kNewer);
    chk("second warm boot without confirm reverts to the previous slot",
        acabHostBootPartition == &acabHostOtaSlot0 && acabHostRestarts == 1 && nvsU8("state") == 0, true);

    // A prepared record whose target is not the running slot (Update.end failed and the cleanup
    // also failed, or power was lost before the switch) must not condemn the image that runs.
    freshBoard(cur);
    // trialver == the running version: a forced same-version re-push whose Update.end failed. Only
    // the address guard in otaBootCheck tells this record from a real trial; the version test
    // alone would count this boot as try 2 and set the boot partition.
    { Preferences p; p.begin("ota", false); p.putUChar("state", 1); p.putUChar("tries", 1);
      p.putUInt("target", acabHostOtaSlot1.address); p.putUInt("trialver", cur); p.end(); }
    rebootInto(&acabHostOtaSlot0, ACAB_FW_VERSION);
    chk("stale prepared record is cleared, not reverted",
        !otaOnTrial() && nvsU8("state") == 0 && acabHostSetBootCalls == 0, true);

    // ---- confirm: the health gate and the floor --------------------------------------------------
    freshBoard();   // floor 0: the confirm below has to WRITE the floor, not read back its own seed
    pushImage(kNewer, kNewer, kProject);
    rebootInto(&acabHostOtaSlot1, kNewer);
    chk("health gate not met keeps the trial armed",
        !otaMarkHealthy() && otaOnTrial() && nvsU8("state") == 1, true);
    hostHealthy = true;
    // The running build is ACAB_FW_VERSION at compile time; the floor must rise to it on confirm.
    chk("healthy confirm clears the trial and raises the floor",
        otaMarkHealthy() && !otaOnTrial() && nvsU8("state") == 0 && nvsU32("floor") == cur, true);
    freshBoard(cur);
    pushImage(kNewer, kNewer, kProject);
    rebootInto(&acabHostOtaSlot1, kNewer);
    hostHealthy = true;
    Preferences::failNextBegin(1);
    chk("confirm with NVS down leaves the trial armed for a retry",
        !otaMarkHealthy() && otaOnTrial() && nvsU8("state") == 1, true);

    // ---- abort and the deferred finish -------------------------------------------------------------
    freshBoard(cur);
    {
        std::vector<uint8_t> img = sampleImage(); const std::vector<uint8_t> sig = goodSig();
        signImage(img, sig); setDesc(acabHostPendingDesc, kNewer, kProject);
        otaSetSignature(sig.data(), sig.size());
        otaBegin((uint32_t)img.size(), 0, kNewer, false);
        otaWrite(img.data(), 100);
        otaAbort();
        chk("abort drops the session and the pending signature",
            !otaInProgress() && Update.aborts == 1 && !gHasSig, true);
        chk("write after abort is refused", otaWrite(img.data(), 1) == OTA_ERR_STATE, true);
    }
    freshBoard(cur);
    {
        std::vector<uint8_t> img = sampleImage(); const std::vector<uint8_t> sig = goodSig();
        signImage(img, sig); setDesc(acabHostPendingDesc, kNewer, kProject);
        otaSetSignature(sig.data(), sig.size());
        otaBegin((uint32_t)img.size(), 0, kNewer, false);
        otaWrite(img.data(), 200);
        chk("end before the last chunk defers", otaFinish() == OTA_PENDING && otaInProgress(), true);
        acabHostAdvanceMillis(1000);
        chk("deferred finish is not expired inside the window", !otaPendingFinishExpired(), true);
        chk("the trailing chunk completes the deferred finish and reboots",
            otaWrite(img.data() + 200, 100) == OTA_OK && Update.committed == 1 && ESP.restarts == 1, true);
    }
    freshBoard(cur);
    {
        std::vector<uint8_t> img = sampleImage(); const std::vector<uint8_t> sig = goodSig();
        signImage(img, sig); setDesc(acabHostPendingDesc, kNewer, kProject);
        otaSetSignature(sig.data(), sig.size());
        otaBegin((uint32_t)img.size(), 0, kNewer, false);
        otaWrite(img.data(), 200);
        otaFinish();
        acabHostAdvanceMillis(1501);
        chk("a deferred finish that never gets its chunk expires uncommitted",
            otaPendingFinishExpired() && !otaInProgress() && Update.committed == 0 && Update.aborts == 1, true);
    }

    printf(failures ? "\n  REGRESSION (%d failures)\n\n" : "\n  all good (0 failures)\n\n", failures);
    return failures ? 1 : 0;
}
