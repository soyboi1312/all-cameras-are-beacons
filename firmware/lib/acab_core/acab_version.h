/*
 * ACAB - All Cameras Are Beacons
 * Single source of truth for the firmware version.
 *
 * This default value is what oui-spy and mesh-detect report; bump it here for those
 * builds. The beacon board carries its OWN -DACAB_FW_VERSION in platformio.ini (that is
 * the line to bump for a beacon-board release), so it does not read this default.
 *   oui-spy     banner, advertised version, status JSON ("fw")
 *   mesh-detect serial banner
 *   beacon-board overrides via -DACAB_FW_VERSION (platformio.ini)
 *
 * It's a string literal so it can be glued onto adjacent literals (e.g.
 * "ACAB-ouispy " ACAB_FW_VERSION). Not called version.h, to avoid clashing with
 * the C++ standard <version> header.
 */
#ifndef ACAB_VERSION_H
#define ACAB_VERSION_H

// Default single source of truth. A build env may override it (the beacon-board carries
// its own version via -DACAB_FW_VERSION so OTA's version-guard can compare builds); oui-spy
// and mesh-detect leave it at the default. Keep it "a.b[.c]" so OTA can parse and compare.
// 2.0.0: the Colonel Panic builds pick up the full v2 detection set the beacon board ships
// with (offline buffer, watchlist/custom category, ignore list, refreshed OUIs, glasses).
#ifndef ACAB_FW_VERSION
#define ACAB_FW_VERSION "2.0.0"
#endif

#endif // ACAB_VERSION_H
