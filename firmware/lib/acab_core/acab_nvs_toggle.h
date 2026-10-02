#pragma once
// One NVS-persisted on/off flag, shared by every detector's xSetEnabled / xIsEnabled /
// xRestoreEnabled. An aggregate on purpose (no constructor): a file-static instance is
// constant-initialized, and `.on` on the per-packet path is the same single load a bool was.
#include <Preferences.h>

struct AcabNvsToggle {
    const char* ns;    // Preferences namespace
    const char* key;   // key in that namespace
    bool        on;    // initializer is the module default until restore() runs

    // Writes NVS only on a real change (no flash wear on a redundant set); true when it flipped.
    bool set(bool enabled) {
        if (enabled == on) return false;
        on = enabled;
        Preferences p; p.begin(ns, false); p.putBool(key, enabled); p.end();
        return true;
    }
    // Reload the persisted value on boot; if none saved yet, use dflt.
    void restore(bool dflt) {
        Preferences p; p.begin(ns, true);
        on = p.getBool(key, dflt);
        p.end();
    }
};
