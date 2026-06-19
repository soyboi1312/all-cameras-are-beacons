package tech.acab.app.model

/** The IEEE-registered vendor for each Flock OUI the detector watches. Flock uses
 *  off-the-shelf modules, so most of these are chipset makers (Liteon, Espressif, USI,
 *  Silicon Labs) or consumer brands, not Flock itself. Shown on the detail screen to
 *  keep an OUI match honest — only b41e52 is actually Flock's. */
val OUI_VENDORS: Map<String, String> = mapOf(
    "00180a" to "Cisco Meraki",
    "00236c" to "Apple",
    "00f48d" to "Liteon",
    "040d84" to "Silicon Labs",
    "083a88" to "USI",
    "145afc" to "Liteon",
    "14b5cd" to "Liteon",
    "1c34f1" to "Silicon Labs",
    "1cb72c" to "ASUSTek",
    "240ac4" to "Espressif",
    "246f28" to "Espressif",
    "24b2b9" to "Liteon",
    "2cf432" to "Espressif",
    "30aea4" to "Espressif",
    "385b44" to "Silicon Labs",
    "3c6105" to "Espressif",
    "3c71bf" to "Espressif",
    "3c9180" to "Liteon",
    "4827ea" to "Samsung",
    "5800e3" to "Liteon",
    "588e81" to "Silicon Labs",
    "5c93a2" to "Liteon",
    "646e69" to "Liteon",
    "700894" to "Liteon",
    "70c94e" to "Liteon",
    "744ca1" to "Liteon",
    "803049" to "Liteon",
    "840d8e" to "Espressif",
    "84f3eb" to "Espressif",
    "8caab5" to "Espressif",
    "9035ea" to "Silicon Labs",
    "940853" to "Liteon",
    "942a6f" to "Ubiquiti",
    "943469" to "Silicon Labs",
    "98f4ab" to "Espressif",
    "9c2f9d" to "Liteon",
    "9c9c1f" to "Espressif",
    "a0c9a0" to "Murata",
    "a4cf12" to "Espressif",
    "ac67b2" to "Espressif",
    "b41e52" to "Flock Safety",
    "b4e3f9" to "Silicon Labs",
    "b81ea4" to "Liteon",
    "bcddc2" to "Espressif",
    "c03532" to "Liteon",
    "c82b96" to "Espressif",
    "cc50e3" to "Espressif",
    "d03957" to "Liteon",
    "d411d6" to "ShotSpotter",
    "d8a01d" to "Espressif",
    "d8f3bc" to "Liteon",
    "dc5475" to "Espressif",
    "e00af6" to "Liteon",
    "e04f43" to "USI",
    "e4aaea" to "Liteon",
    "e8d0fc" to "Liteon",
    "ec1bbd" to "Silicon Labs",
    "ec6260" to "Espressif",
    "f082c0" to "Silicon Labs",
    "f46add" to "Liteon",
    "f4cfa2" to "Espressif",
    "f4e2c6" to "Ubiquiti",
    "f8a2d6" to "Liteon",
    "fcf5c4" to "Espressif",
)

/** Registered vendor for the MAC's OUI prefix, if we know it. */
val Detection.ouiVendor: String?
    get() {
        val hex = mac.lowercase().filter { it != ':' && it != '-' }
        return if (hex.length >= 6) OUI_VENDORS[hex.take(6)] else null
    }

/** Readable "matched on" label for the firmware's `meth` int. */
val Detection.methodLabel: String
    get() = when (method) {
        1 -> "OUI match"
        2 -> "device name"
        3 -> "manufacturer ID"
        4 -> "service UUID"
        5 -> "SSID"
        6 -> "wildcard probe"
        7 -> "Remote ID"
        else -> "unknown"
    }

/** Readable radio-source label for the firmware's `s` int. */
val Detection.sourceLabel: String
    get() = when (source) {
        0 -> "BLE"
        1 -> "WiFi"
        2 -> "Remote ID"
        else -> "?"
    }

/** True when only the OUI matched — the case that's prone to false positives. */
val Detection.isOuiMatch: Boolean get() = method == 1

/** Readable name for the ignore list and CSV export. */
val Detection.displayName: String
    get() = name?.takeIf { it.isNotEmpty() }
        ?: "${type.label} ${mac.filter { it != ':' && it != '-' }.takeLast(4).uppercase()}"
