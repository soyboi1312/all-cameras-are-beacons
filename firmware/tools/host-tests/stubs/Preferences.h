#pragma once
// Minimal Arduino Preferences stub so the detector compiles on the host.
struct Preferences {
    void begin(const char*, bool = false) {}
    void end() {}
    bool getBool(const char*, bool d) { return d; }
    void putBool(const char*, bool) {}
};
