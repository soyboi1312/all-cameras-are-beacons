// Force-included into every env:beacon-c5 compile (platformio.ini), NimBLE's own sources too.
// Arduino 3's prebuilt sdkconfig.h would override the [env] CONFIG_BT_NIMBLE_* -D flags, so
// include it first (#pragma once: later includes are no-ops), then set ours;
// acab_ble_service.cpp static_asserts the result.
#pragma once

// Drop the [env] -D values so sdkconfig.h's own defines raise no redefinition warning.
#undef CONFIG_BT_NIMBLE_MAX_BONDS
#undef CONFIG_BT_NIMBLE_MAX_CCCDS
#undef CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE
#undef CONFIG_BT_NIMBLE_MAX_CONNECTIONS
#undef CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU
#undef CONFIG_BT_NIMBLE_MSYS1_BLOCK_COUNT
#include "sdkconfig.h"

// 4, not the S3's 8: the C5 RPA resolving list holds at most 5 (IDF controller/esp32c5 Kconfig),
// one is NimBLE's local entry, and a bond without a slot reconnects as a stranger.
#undef CONFIG_BT_NIMBLE_MAX_BONDS
#define CONFIG_BT_NIMBLE_MAX_BONDS 4
#undef CONFIG_BT_LE_LL_RESOLV_LIST_SIZE
#define CONFIG_BT_LE_LL_RESOLV_LIST_SIZE 5
#undef CONFIG_BT_NIMBLE_MAX_CCCDS
#define CONFIG_BT_NIMBLE_MAX_CCCDS 32                 // a CCCD overflow deletes a bond
#undef CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE
#define CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE 12288   // the OTA ECDSA verify runs on the host task
#undef CONFIG_BT_NIMBLE_MAX_CONNECTIONS
#define CONFIG_BT_NIMBLE_MAX_CONNECTIONS 1            // one client; closes the advertising race
#undef CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU
#define CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU 512        // status + rich drone JSON outgrew 247
// msys is not set: the prebuilt libbt sizes it in the controller, so a define here changes
// nothing (see DRAIN_MBUF_MIN in acab_ble_service.cpp).
