/*
 * ACAB OUI-Spy - BLE GATT service (the contract the iOS app codes against).
 *
 *   Service        acab0100-6f75-6973-7079-000000000000   ("...ouispy")
 *   ├─ Detections  acab0101-...   NOTIFY        one compact-JSON record per hit
 *   ├─ Config      acab0102-...   WRITE         JSON commands from the app
 *   └─ Status      acab0103-...   READ | NOTIFY periodic device status JSON
 *
 * Detection record (one BLE notify, fits a 247-byte MTU):
 *   {"t":1,"s":0,"meth":1,"c":85,"mac":"aa:bb:..","rssi":-67,"name":"Flock",
 *    "det":"mfg 0x09C8","lat":0,"lon":0,"plat":0,"plon":0,"alt":0,"n":3,"new":true}
 *   t   = device type   (1 Flock cam, 2 Flock Raven, 3 Axon, 4 Drone)
 *   s   = source        (0 BLE, 1 WiFi, 2 RemoteID)
 *   meth= match method, c = confidence 0-100, n = sighting count
 *
 * Config commands (send any subset):
 *   {"axon":true}      enable the Axon detector
 *   {"buzzer":false}   mute the buzzer
 *
 * Status record:
 *   {"fw":"ACAB-ouispy 0.9","up":12345,"total":42,"ble":true,"wifi":true,
 *    "axon":false,"buzzer":true,"gps":false}
 */
#ifndef ACAB_BLE_SERVICE_H
#define ACAB_BLE_SERVICE_H

#include "detection.h"
#include "acab_version.h"  // the one place ACAB_FW_VERSION lives

#define ACAB_BLE_SVC_UUID    "acab0100-6f75-6973-7079-000000000000"
#define ACAB_BLE_DET_UUID    "acab0101-6f75-6973-7079-000000000000"
#define ACAB_BLE_CFG_UUID    "acab0102-6f75-6973-7079-000000000000"
#define ACAB_BLE_STAT_UUID   "acab0103-6f75-6973-7079-000000000000"

// Init NimBLE, build the service, and start advertising as `deviceName`.
void acabBleBegin(const char* deviceName);

// Push one detection to subscribed clients (call from the scanner sink).
void acabBleNotifyDetection(const AcabDetection& d, bool isNew);

// Refresh + notify the Status characteristic. Call periodically from loop().
void acabBleUpdateStatus();

// True once the app is connected.
bool acabBleClientConnected();

#endif // ACAB_BLE_SERVICE_H
