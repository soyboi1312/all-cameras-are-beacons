import Foundation

/// The IEEE-registered vendor for each Flock OUI the detector watches. Flock runs on
/// off-the-shelf modules, so most of these are chipset makers (Liteon, Espressif, USI,
/// Silicon Labs) or consumer brands — only b41e52 is actually Flock's. We show this on
/// the detail screen so an OUI match reads honestly.
enum OUIVendors {
    static let table: [String: String] = [
        "00180a": "Cisco Meraki",
        "00236c": "Apple",
        "00f48d": "Liteon",
        "040d84": "Silicon Labs",
        "083a88": "USI",
        "145afc": "Liteon",
        "14b5cd": "Liteon",
        "1c34f1": "Silicon Labs",
        "1cb72c": "ASUSTek",
        "240ac4": "Espressif",
        "246f28": "Espressif",
        "24b2b9": "Liteon",
        "2cf432": "Espressif",
        "30aea4": "Espressif",
        "385b44": "Silicon Labs",
        "3c6105": "Espressif",
        "3c71bf": "Espressif",
        "3c9180": "Liteon",
        "4827ea": "Samsung",
        "5800e3": "Liteon",
        "588e81": "Silicon Labs",
        "5c93a2": "Liteon",
        "646e69": "Liteon",
        "700894": "Liteon",
        "70c94e": "Liteon",
        "744ca1": "Liteon",
        "803049": "Liteon",
        "840d8e": "Espressif",
        "84f3eb": "Espressif",
        "8caab5": "Espressif",
        "9035ea": "Silicon Labs",
        "940853": "Liteon",
        "942a6f": "Ubiquiti",
        "943469": "Silicon Labs",
        "98f4ab": "Espressif",
        "9c2f9d": "Liteon",
        "9c9c1f": "Espressif",
        "a0c9a0": "Murata",
        "a4cf12": "Espressif",
        "ac67b2": "Espressif",
        "b41e52": "Flock Safety",
        "b4e3f9": "Silicon Labs",
        "b81ea4": "Liteon",
        "bcddc2": "Espressif",
        "c03532": "Liteon",
        "c82b96": "Espressif",
        "cc50e3": "Espressif",
        "d03957": "Liteon",
        "d411d6": "ShotSpotter",
        "d8a01d": "Espressif",
        "d8f3bc": "Liteon",
        "dc5475": "Espressif",
        "e00af6": "Liteon",
        "e04f43": "USI",
        "e4aaea": "Liteon",
        "e8d0fc": "Liteon",
        "ec1bbd": "Silicon Labs",
        "ec6260": "Espressif",
        "f082c0": "Silicon Labs",
        "f46add": "Liteon",
        "f4cfa2": "Espressif",
        "f4e2c6": "Ubiquiti",
        "f8a2d6": "Liteon",
        "fcf5c4": "Espressif",
    ]
}

extension Detection {
    /// Registered vendor for the MAC's OUI prefix, if we know it.
    var ouiVendor: String? {
        let hex = mac.lowercased().filter { $0 != ":" && $0 != "-" }
        guard hex.count >= 6 else { return nil }
        return OUIVendors.table[String(hex.prefix(6))]
    }
}
