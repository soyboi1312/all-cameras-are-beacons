import Foundation

/// The IEEE-registered vendor for each OUI the detector watches. Flock uses
/// off-the-shelf modules, so most of these are chipset makers (Liteon, Espressif, USI,
/// Silicon Labs) or consumer brands. Only b41e52 is actually Flock's. We show this on
/// the detail screen so an OUI match reads honestly.
///
/// The body-cam blocks at the front of the table are the opposite case: they are the
/// makers' OWN registrations, so a hit there does name the real vendor, and leaving them
/// out made the detail screen fall back to the category's assumed maker and print the
/// wrong company on a Motorola or Utility hit.
enum OUIVendors {
    static let table: [String: String] = [
        "00047d": "Motorola Solutions",
        "0009bc": "Utility Inc",
        "0016ed": "Utility Inc",
        "00180a": "Cisco Meraki",
        "001885": "Motorola Solutions",
        "001f92": "Motorola Solutions",
        "00236c": "Apple",
        // Axon's sole IEEE block. Named here so the honest per-signature vendor below
        // never has to guess on an Axon OUI hit.
        "0025df": "Axon Enterprise",
        "00f48d": "Liteon",
        "040d84": "Silicon Labs",
        "083a88": "USI",
        // 10746f, b8e28c and 9c862b are registered to Motorola Solutions Malaysia Sdn.
        // Bhd., the group's manufacturing entity, so they read as the parent brand here.
        "10746f": "Motorola Solutions",
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
        "4ccc34": "Motorola Solutions",
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
        "9c862b": "Motorola Solutions",
        "9c9c1f": "Espressif",
        "a0c9a0": "Murata",
        "a4cf12": "Espressif",
        "ac67b2": "Espressif",
        "b41e52": "Flock Safety",
        "b4e3f9": "Silicon Labs",
        "b81ea4": "Liteon",
        "b8e28c": "Motorola Solutions",
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

/// Which body-cam signature actually fired. Body cam is the one category that carries
/// several makers' signatures at once, so the category alone cannot name a vendor or a
/// strength: an Axon payload tag and the broad Motorola proxy both arrive as t=3. The
/// firmware distinguishes them in the detail string, so that string is what we read.
/// Raw values MUST match the strings set in axon_detect.cpp and police_detect.cpp.
enum BodyCamSignature: String {
    case axonPayload = "BWC DEVICE"
    case axonOUI     = "Axon OUI"
    case utility     = "Utility BodyWorn"
    case motorola    = "Motorola Solutions OUI"

    /// Who makes the device this signature fired on. Known exactly in every case, which
    /// is the point: the category's guess would name Axon for all four.
    var vendor: String {
        switch self {
        case .axonPayload, .axonOUI: return "Axon Enterprise"
        case .utility:               return "Utility Inc"
        case .motorola:              return "Motorola Solutions"
        }
    }
}

extension Detection {
    /// The body-cam signature behind this hit, when the board reported one. nil for every
    /// other category, and for a pre-split board that sent no detail string.
    var bodyCamSignature: BodyCamSignature? {
        guard type == .axonBodyCam, let det = detail else { return nil }
        return BodyCamSignature(rawValue: det)
    }

    /// Vendor line for the detail screen, in descending order of how much we actually know:
    /// the registered owner of the MAC's OUI, then the maker behind the signature that fired
    /// (which survives BLE address randomization, where there is no OUI to look up), then a
    /// per-type guess.
    ///
    /// The last step is why this exists. `Detection.vendor` answers the body-cam category
    /// with "Axon (unverified)", so a Motorola or Utility hit, which the firmware files under
    /// the same category, printed the wrong company outright. An unknown OUI here names the
    /// category's makers rather than picking one, mirroring Android's fallback.
    var displayVendor: String {
        if let v = ouiVendor { return v }
        if let sig = bodyCamSignature { return sig.vendor }
        if type == .axonBodyCam { return "Axon / Utility / Motorola" }
        return vendor
    }
}
