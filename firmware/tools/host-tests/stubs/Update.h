#pragma once
// Scriptable arduino-esp32 Update object for test_ota_update.cpp.
//
// ota_update.cpp drives exactly four calls: begin(size), write(buf, n), abort() and end(true).
// This records them so a case can assert the one thing the OTA path exists to guarantee: a
// refused image is never COMMITTED (end(true) returning true is the boot-slot switch). Nothing
// here validates image bytes; the real Update's magic/SHA checks run only on the board.
#include <stdint.h>
#include <stddef.h>
#include <functional>
#include <vector>

struct AcabHostUpdate {
    // Scripted result of end(true): false models the Update library refusing the image.
    bool endOk = true;
    // Observed by a test right before end() runs, so a case can prove what NVS held at the
    // moment the slot switch happened (the trial record must already be durable then).
    std::function<void()> onEnd;

    // Recorder.
    std::vector<uint8_t> image;      // bytes written since begin()
    uint32_t aborts    = 0;
    uint32_t endCalls  = 0;
    uint32_t committed = 0;          // end(true) calls that returned true

    bool begin(size_t /*size*/) {
        image.clear();
        return true;
    }
    size_t write(uint8_t* d, size_t n) {
        image.insert(image.end(), d, d + n);
        return n;
    }
    void abort() { aborts++; }
    bool end(bool /*evenIfRemaining*/) {
        endCalls++;
        if (onEnd) onEnd();
        if (!endOk) return false;
        committed++;
        return true;
    }
    void reset() { *this = AcabHostUpdate(); }
};

inline AcabHostUpdate Update;
