import CoreBluetooth

/// The ACAB GATT contract. Keep in sync with firmware/lib/acab_core/acab_ble_service.h.
enum ACABProfile {
    static let service    = CBUUID(string: "acab0100-6f75-6973-7079-000000000000")
    static let detections = CBUUID(string: "acab0101-6f75-6973-7079-000000000000")  // notify
    static let config     = CBUUID(string: "acab0102-6f75-6973-7079-000000000000")  // write
    static let status     = CBUUID(string: "acab0103-6f75-6973-7079-000000000000")  // read + notify
    // OTA firmware update: image bytes go up (write-no-response, encrypted), progress
    // notifies come down. Only boards built with in-app OTA expose it; released 1.7
    // boards do NOT, so its presence is a runtime capability check (see BLEManager.otaCapable).
    static let ota        = CBUUID(string: "acab0104-6f75-6973-7079-000000000000")  // write-no-response + notify

    /// What the firmware advertises as.
    static let advertisedName = "ACAB"
}
