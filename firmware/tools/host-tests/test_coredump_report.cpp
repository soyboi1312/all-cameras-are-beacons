// Host regression tests for the real retained-coredump probe/erase state machine.
#include "coredump_report.h"
#include <Arduino.h>
#include <esp_core_dump.h>
#include <cstdio>

static int failures = 0;
static uint32_t pendingGeneration = 0;
static uint32_t completedGeneration = 0;
static bool ringWipePending = false;

// Link seams consumed by coredump_report.cpp. The det_log token's own persistence behavior is
// covered by test_det_log.cpp; this suite proves the physical consumer never acknowledges an
// unreadable or failed erase.
uint32_t detLogSensitiveErasePending() { return pendingGeneration; }
void detLogSensitiveEraseComplete(uint32_t generation) {
    completedGeneration = generation;
    if (pendingGeneration == generation) pendingGeneration = 0;
}
bool detLogWipePending() { return ringWipePending; }

static void check(const char* label, bool ok) {
    std::printf("  %-72s %s\n", label, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
}

// A fresh case is a factory-blank 64 KB partition (every byte 0xFF) and no pending token.
static void resetCase() {
    acabHostCoreDumpReset();
    acabHostSetMillis(1000);
    pendingGeneration = 0;
    completedGeneration = 0;
    ringWipePending = false;
}

static bool probedEmpty() {
    acabCoredumpProbe();
    return !acabCoredumpInfo().present && !acabCoredumpInfo().corrupt;
}
static bool probedEraseRequired() {
    acabCoredumpProbe();
    return !acabCoredumpInfo().present && acabCoredumpInfo().corrupt;
}

// Fail the one read that covers kFaultOffset, so the size word reads fine and the blank scan
// meets a flash fault part way through.
static const size_t kFaultOffset = 40000;
static void failReadAtFaultOffset(AcabHostFlashOp op, size_t offset, size_t size) {
    if (op == ACAB_HOST_FLASH_READ && offset <= kFaultOffset && kFaultOffset < offset + size)
        acabHostFailReads = 1;
}

int main() {
    std::printf("coredump_report host tests\n");

    // ---- provably blank reads as empty --------------------------------------------------------
    // The pinned IDF answers ESP_ERR_INVALID_SIZE for both blank states below (see the stub), so
    // the probe has to prove blankness from the bytes. Before it did, every boot read "erase
    // required", and every boot with a pending erase token erased the 64 KB partition again.
    // Each boot's first phone link mints a token that is held until the next boot, so a board in
    // daily use erased once per boot.
    resetCase();
    check("the stub reports a blank partition as INVALID_SIZE, like IDF v4.4.7",
          esp_core_dump_image_check() == ESP_ERR_INVALID_SIZE);
    check("a factory-blank partition (all 0xFF) is empty", probedEmpty());
    check("empty erase is a no-op success", acabCoredumpErase() && acabHostEraseCalls == 0);

    resetCase();
    check("stub erase succeeds", esp_core_dump_image_erase() == ESP_OK);
    check("the marker esp_core_dump_image_erase() leaves is not all 0xFF",
          !acabHostPartitionAllErased() &&
          esp_core_dump_image_check() == ESP_ERR_INVALID_SIZE);
    check("the partition esp_core_dump_image_erase() leaves is empty", probedEmpty());

    resetCase();
    acabHostPartitionAvailable = false;
    check("no coredump partition means nothing can be retained", probedEmpty());

    // A token restored at boot over a blank partition is acknowledged with no flash erase. This
    // is the per-boot erase the blank-partition bug caused.
    resetCase();
    acabCoredumpProbe();
    pendingGeneration = 201;
    acabCoredumpWipeTick();
    check("pending token over a blank partition completes with no erase",
          pendingGeneration == 0 && completedGeneration == 201 && acabHostEraseCalls == 0);

    // ---- everything else that is not a valid image stays erase-required -----------------------
    // The size word alone is not proof: a later, smaller dump erases only the sectors it needs,
    // so an interrupted write can leave a blank head in front of an older dump's stack bytes.
    resetCase();
    acabHostPartitionCorrupt(kFaultOffset, 0x5A);
    check("blank size word with a stray byte deeper in the partition is erase-required",
          probedEraseRequired());

    resetCase();
    acabHostPartitionCorrupt(ACAB_HOST_CORE_PART_SIZE - 1, 0x00);
    check("a non-0xFF last byte of the partition is erase-required", probedEraseRequired());

    resetCase();
    acabHostPartitionCorrupt(16, 0x00);
    check("a zero byte just past the erase marker is erase-required", probedEraseRequired());

    // 4096 + 4 sits at chunk position 4 for every power-of-two read size from 16 B to 4 KB, so
    // this catches a pad window keyed to the offset inside the read buffer instead of the
    // partition.
    resetCase();
    esp_core_dump_image_erase();
    acabHostPartitionCorrupt(4096 + 4, 0x00);
    check("a zero byte at offset 4 of a later sector is erase-required", probedEraseRequired());

    resetCase();
    esp_core_dump_image_erase();
    acabHostPartitionCorrupt(5, 0x12);
    check("an erase-marker pad byte that is neither 0x00 nor 0xFF is erase-required",
          probedEraseRequired());

    resetCase();
    acabHostPartitionCorrupt(3, 0x00);
    check("a size word that is not the blank marker is erase-required", probedEraseRequired());

    resetCase();
    acabHostCoreSetSizeWord(0);
    check("a zero size word is not mistaken for an empty partition", probedEraseRequired());

    resetCase();
    acabHostFlashHook = failReadAtFaultOffset;
    check("a flash read fault during the blank scan is erase-required", probedEraseRequired());

    resetCase();
    acabHostFailReads = 1000000;
    check("an unreadable partition is erase-required", probedEraseRequired());

    resetCase();
    acabHostCoreSetSizeWord(4096);
    acabHostCoreCheckResult = ESP_ERR_INVALID_CRC;
    check("a sized image with a bad checksum is erase-required and keeps its size",
          probedEraseRequired() && acabCoredumpInfo().sizeBytes == 4096);

    resetCase();
    acabHostCoreSetSizeWord(4096);
    acabHostCoreGetResult = ESP_FAIL;
    check("metadata access failure remains erase-required", probedEraseRequired());
    acabHostFailErases = 1;
    check("failed erase leaves unreadable state intact",
          !acabCoredumpErase() && acabCoredumpInfo().corrupt && acabHostEraseCalls == 1);
    check("successful erase clears the unreadable cache",
          acabCoredumpErase() && !acabCoredumpInfo().present && !acabCoredumpInfo().corrupt &&
          acabHostEraseCalls == 2);
    // The next boot. Before the fix this probe read "erase required" again, forever.
    acabHostCoreGetResult = ESP_OK;
    check("the next boot's probe reads the erased partition as empty", probedEmpty());
    pendingGeneration = 202;
    acabCoredumpWipeTick();
    check("a token restored on that boot completes with no second erase",
          pendingGeneration == 0 && completedGeneration == 202 && acabHostEraseCalls == 2);

    resetCase();
    acabHostCoreSetSizeWord(4096);
    acabHostCoreSummaryResult = ESP_OK;
    acabHostCoreSummary.exc_pc = 0x12345678;
    acabHostCoreSummary.core_dump_version = 7;
    acabCoredumpProbe();
    check("valid nonempty image remains reportable",
          acabCoredumpInfo().present && !acabCoredumpInfo().corrupt &&
          acabCoredumpInfo().sizeBytes == 4096 && acabCoredumpInfo().pc == 0x12345678);

    // Explicit wipe completion is the security boundary: a failed erase must leave the durable
    // token untouched. A newer generation may retry immediately without rebooting.
    pendingGeneration = 101;
    acabHostFailErases = 1;
    acabCoredumpWipeTick();
    check("failed explicit erase retains its generation",
          pendingGeneration == 101 && completedGeneration == 0);
    pendingGeneration = 102;
    acabCoredumpWipeTick();
    check("successful erase acknowledges only the generation it handled",
          pendingGeneration == 0 && completedGeneration == 102 &&
          !acabCoredumpInfo().present && !acabCoredumpInfo().corrupt);

    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
