/*
 * Shim, not a copy. The tree holds ONE vendored OpenDroneID library, in
 * lib/acab_core/opendroneid/ (Apache-2.0, LICENSE in that folder). main.cpp includes this file
 * by its short name and gets that header. [env:odid-sim] in platformio.ini needs
 * `lib_ignore = acab_core` for this include; the reason is in the comment there.
 */
#include "../../lib/acab_core/opendroneid/opendroneid.h"
