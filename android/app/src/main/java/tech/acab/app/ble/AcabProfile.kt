package tech.acab.app.ble

import java.util.UUID

/** The ACAB GATT contract. Keep in sync with firmware/src/oui-spy/acab_ble_service.h. */
object AcabProfile {
    val SERVICE: UUID    = UUID.fromString("acab0100-6f75-6973-7079-000000000000")
    val DETECTIONS: UUID = UUID.fromString("acab0101-6f75-6973-7079-000000000000") // notify (encrypted)
    val CONFIG: UUID     = UUID.fromString("acab0102-6f75-6973-7079-000000000000") // write  (encrypted)
    val STATUS: UUID     = UUID.fromString("acab0103-6f75-6973-7079-000000000000") // read + notify (encrypted)

    /** Standard CCCD descriptor — the one you write to turn notifications on. */
    val CCCD: UUID       = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
}
