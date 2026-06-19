import CoreBluetooth

/// The ACAB GATT contract. Keep in sync with firmware/src/oui-spy/acab_ble_service.h.
enum ACABProfile {
    static let service    = CBUUID(string: "acab0100-6f75-6973-7079-000000000000")
    static let detections = CBUUID(string: "acab0101-6f75-6973-7079-000000000000")  // notify
    static let config     = CBUUID(string: "acab0102-6f75-6973-7079-000000000000")  // write
    static let status     = CBUUID(string: "acab0103-6f75-6973-7079-000000000000")  // read + notify

    /// What the firmware advertises as.
    static let advertisedName = "ACAB"
}
