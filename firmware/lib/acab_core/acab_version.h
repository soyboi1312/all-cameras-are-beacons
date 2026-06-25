/*
 * ACAB - All Cameras Are Bastards
 * Single source of truth for the firmware version.
 *
 * Bump ACAB_FW_VERSION here and nowhere else. Both builds use it:
 *   oui-spy     banner, advertised version, status JSON ("fw")
 *   mesh-detect serial banner
 *
 * It's a string literal so it can be glued onto adjacent literals (e.g.
 * "ACAB-ouispy " ACAB_FW_VERSION). Not called version.h, to avoid clashing with
 * the C++ standard <version> header.
 */
#ifndef ACAB_VERSION_H
#define ACAB_VERSION_H

#define ACAB_FW_VERSION "1.7"

#endif // ACAB_VERSION_H
