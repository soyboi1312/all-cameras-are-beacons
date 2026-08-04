/*
 * ACAB OUI-Spy - BLE GATT service (the contract the iOS app codes against).
 *
 *   Service        acab0100-6f75-6973-7079-000000000000   ("...ouispy")
 *   ├─ Detections  acab0101-...   NOTIFY        one compact-JSON record per hit
 *   ├─ Config      acab0102-...   WRITE         JSON commands from the app
 *   ├─ Status      acab0103-...   READ | NOTIFY periodic device status JSON
 *   └─ OTA         acab0104-...   WRITE_NR | NOTIFY   firmware bytes up / progress down
 *
 * OTA (firmware update, all writes require the bonded/encrypted link):
 *   control rides the Config characteristic as an {"ota":{...}} object -
 *     {"ota":{"begin":true,"size":1069573,"crc":"a1b2c3d4","ver":"2.0.1"}}  open a session
 *     ...then stream the raw image bytes to the OTA characteristic (write-no-response)...
 *     {"ota":{"end":true}}     finalize + reboot into the new image
 *     {"ota":{"abort":true}}   cancel
 *     {"ota":{"confirm":true}} after reboot: mark the new image healthy (disarms rollback)
 *   the board notifies progress/results on the OTA characteristic:
 *     {"ota":"ready","size":N} {"ota":"prog","rx":B,"pct":P} {"ota":"done"}
 *     {"ota":"ok"} {"ota":"err","e":"crc"}
 *   crc is a standard zlib CRC-32 (hex) over the whole image; ver must be newer than the
 *   running firmware (send "force":true to override). On the dual board the new S3 image
 *   carries the matching nRF app, which the S3 reflashes over SWD after the reboot.
 *
 * Detection record (one BLE notify, fits the negotiated ATT MTU; we negotiate 512):
 *   {"t":1,"s":0,"meth":1,"c":85,"mac":"aa:bb:..","rssi":-67,"name":"Flock",
 *    "det":"mfg 0x09C8","lat":0,"lon":0,"plat":0,"plon":0,"alt":0,"n":3,"new":true}
 *   t   = device type   (1 Flock cam, 2 Flock Raven, 3 Axon body cam, 4 Drone, 5 tracker,
 *                        7 nearby/Desert, 8 watchlist, 9 glasses, 10 network camera)
 *   s   = source        (0 BLE, 1 WiFi, 2 RemoteID)
 *   meth= match method, c = confidence 0-100, n = sighting count
 *
 * Config commands (send any subset). The surface has grown well past this sample:
 * per-detector toggles (flock/drone/droneoui/axon/motorola/tracker/glasses/netcam),
 * desert mode, led, the encrypted offline buffer (key/epoch/sync/clearlog/buffer), the
 * watchlist (watch), and OTA ({"ota":{...}}). Examples:
 *   {"axon":true}      enable the body-cam category (Axon + Utility BodyWorn)
 *   {"motorola":false} quiet ONLY the broad Motorola-Solutions OUI proxy - a SUB-toggle
 *                      of the body-cam category, so the conf-90 Axon BWCDEVICE tag keeps
 *                      running. Absent key on old firmware = the two were one switch.
 *   {"buzzer":false}   mute the buzzer
 *   {"lat":32.79,"lon":-116.94}  push the phone's GPS (Mesh-Detect tags its uplink)
 *
 * Status record (fw string is "<label> <version>", e.g. beacon board reports "beacon board"):
 *   {"fw":"ACAB-ouispy 2.0.0","up":12345,"total":42,"ble":true,"wifi":true,
 *    "axon":false,"buzzer":true,"gps":false, ...}
 *   wseen/bseen (radio diagnostics) appear on every build; bat only on battery-sense
 *   boards; co/chg/nbb only on the dual-radio beacon board.
 *
 * The full, current key list for all three characteristics lives in docs/ble-protocol.md;
 * treat that doc as the source of truth and this header as a quick orientation.
 */
#ifndef ACAB_BLE_SERVICE_H
#define ACAB_BLE_SERVICE_H

#include "detection.h"
#include "acab_version.h"  // the one place ACAB_FW_VERSION lives

// ---- RF privacy defaults -------------------------------------------------------------------
// The detector used to be the most conspicuous beacon in the room: a fixed service UUID, a literal
// name, a custom company ID, an exact firmware version, and a stable MAC, broadcast continuously.
// The detection path was always passive; the leak was in the phone link nobody audited.
//
// ACAB_BLE_PRIVACY      1 = advertise a rotating Resolvable Private Address.
//                       OFF, AND IT STAYS OFF: IT BREAKS iOS. Bench-proven 2026-08-02, controlled
//                       A/B on one board. Read the rest of this block before touching the flag.
// ACAB_ADVERTISE_VERSION 1 = put the exact firmware version in the scan response. OFF by default:
//                       it told every passive listener which signature set a unit carries, i.e.
//                       what it can and cannot see, to save its owner one tap. The version still
//                       reaches the app over the Status characteristic, post-connect and post-bond.
//                       This one is off for a PRIVACY reason. Nothing about it is broken and it has
//                       nothing to do with the iOS failure described below.
//
// The rotation itself works. Two independent proofs stand:
//   1. ON AIR. The companion nRF52840, a separate receiver on the same PCB, captured AdvA = the
//      rotating RPA at rssi -17 while the S3 reported that exact value. The public address never
//      appeared. A board cannot observe its own AdvA and iOS/macOS substitute a per-host UUID, so
//      the co-processor was the only way to see the truth.
//   2. ANDROID IS FINE. Paired, rebooted the board (new RPA), and it reconnected unprompted in 4 s
//      with enc_change status=0, encrypted=1 bonded=1.
//
// BUT iOS CANNOT CONNECT. Same board, same firmware, only this flag changed:
//   ACAB_BLE_PRIVACY=1 -> the board appears in the picker, tapping it opens a link (the board even
//                         sounds its connect chirp), and then NOTHING. onConnect never fires, so
//                         the GATT server never sees the peer. Never recovers.
//   ACAB_BLE_PRIVACY=0 -> connected in 7 s, encrypted=1 bonded=1 at t=18 s.
// So the link reaches the controller and dies before the host hands it up. Not yet root-caused.
//
// A detector that cannot pair with an iPhone is not shippable, and that outweighs the leak this
// setting closes. Everything the feature needs is still here and still correct: the address type
// (BLE_OWN_ADDR_RANDOM, not RPA_PUBLIC_DEFAULT, see the .cpp), the explicit ENC|ID key
// distribution, the build guard, the advertising re-arm after rotation preempts GAP, and the
// serial diagnostics that made all of the above visible.
//
// Anyone resuming this: reproduce the A/B above FIRST, then instrument the iOS side. The board
// tells you almost nothing because the failure is above the controller and below the host
// callback. A sniffer on the CONNECT_IND / connection-request exchange is the next real step.
#ifndef ACAB_BLE_PRIVACY
#define ACAB_BLE_PRIVACY 0
#endif
#ifndef ACAB_ADVERTISE_VERSION
#define ACAB_ADVERTISE_VERSION 0
#endif

#define ACAB_BLE_SVC_UUID    "acab0100-6f75-6973-7079-000000000000"
#define ACAB_BLE_DET_UUID    "acab0101-6f75-6973-7079-000000000000"
#define ACAB_BLE_CFG_UUID    "acab0102-6f75-6973-7079-000000000000"
#define ACAB_BLE_STAT_UUID   "acab0103-6f75-6973-7079-000000000000"
#define ACAB_BLE_OTA_UUID    "acab0104-6f75-6973-7079-000000000000"

// The companion nRF's app version for the status doc (dual-radio boards). Weakly defined as -1
// here; the beacon-board app provides the real one (the last "V<n>" it heard from the nRF).
int acabNrfVersion();
// Carrier revision, auto-detected at boot (true = rev-B: momentary power button + real VBUS sense).
// Defined in the beacon-board build; weakly defaulted false elsewhere so the shared core links.
bool acabBoardIsRevB() __attribute__((weak));

// True while the companion nRF is mid BLE DFU (dual-radio boards; weakly false elsewhere). Drives
// the status "nrfup" flag so the app mutes the co-proc fault banner during a legitimate update.
bool acabNrfDfuActive();

// One-shot: returns true (and clears the latch) if an {"nrfdfu":true} config write asked to kick
// the companion nRF into BLE OTA DFU since the last call. The beacon-board loop() polls this and
// forwards the trigger over UART. Always safe to call; single-board builds never see the request.
bool acabBleTakeNrfDfuRequest();

// Init NimBLE, build the service, and start advertising as `deviceName`. `fwLabel`
// is this build's name in the status "fw" string (e.g. "mesh-detect-ACAB").
void acabBleBegin(const char* deviceName, const char* fwLabel = "ACAB-ouispy");

// Push one detection to subscribed clients (call from the scanner sink).
void acabBleNotifyDetection(const AcabDetection& d, bool isNew);

// Refresh + notify the Status characteristic. Call periodically from loop().
void acabBleUpdateStatus();

// Report battery percentage (0-100) in the status JSON. Boards with no sense divider
// never call this, so "bat" stays out of the JSON (pass -1 for unknown).
void acabBleSetBatteryPct(int pct);

// Report whether the battery is charging (VBAT held above the discharge ceiling on USB). The
// status "chg" flag only appears on the dual-radio build; an absent key = draining/unknown, so
// the app shows a normal battery. No-op storage on other builds.
void acabBleSetCharging(bool charging);

// True once the app is connected.
bool acabBleClientConnected();

// Drive the offline-buffer replay drain (a bounded burst of records per call, paced by the
// notify mbuf pool) and pump the acab_core deferred work that must stay off the NimBLE host
// task (chunked buffer wipe, nRF ignore-list mirror). Call from loop() every pass.
void acabBleDrainTick();

// OTA stall watchdog: abort + un-quiesce an OTA session that has gone idle > 30s (e.g. a
// link drop the disconnect callback did not catch). Cheap; call periodically from loop().
void acabBleOtaWatchdog();

// Latest phone GPS the app pushed via the Config characteristic, if fresher than
// maxAgeMs (use 0xFFFFFFFF for "any age"). Returns false (outputs untouched) when
// there's no fix. When ageMs is non-null, it gets the fix's age in millis.
bool acabBleGetPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs = nullptr);

#endif // ACAB_BLE_SERVICE_H
