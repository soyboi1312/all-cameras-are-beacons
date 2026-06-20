import Foundation

/// Device status from the Status characteristic (read + notify).
/// JSON keys live in docs/ble-protocol.md.
struct DeviceStatus: Equatable {
    let firmware: String     // "fw"
    let uptime: Int          // seconds ("up")
    let total: Int           // detections this session
    let ble: Bool
    let wifi: Bool
    let axon: Bool           // body-cam (Axon) detector enabled
    let tracker: Bool        // BLE item-tracker detector enabled
    let buzzer: Bool         // master audio on/off
    let volume: Int          // buzzer loudness, 0...100
    let gps: Bool

    var uptimeText: String {
        let h = uptime / 3600, m = (uptime % 3600) / 60, s = uptime % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

extension DeviceStatus: Decodable {
    enum CodingKeys: String, CodingKey {
        case fw, up, total, ble, wifi, axon, tracker, buzzer, gps
        case vol  // firmware sends "vol"; we call it `volume`
    }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        firmware = (try? k.decode(String.self, forKey: .fw)) ?? "ESP32"
        uptime   = (try? k.decode(Int.self, forKey: .up)) ?? 0
        total    = (try? k.decode(Int.self, forKey: .total)) ?? 0
        ble      = (try? k.decode(Bool.self, forKey: .ble)) ?? false
        wifi     = (try? k.decode(Bool.self, forKey: .wifi)) ?? false
        axon     = (try? k.decode(Bool.self, forKey: .axon)) ?? false
        tracker  = (try? k.decode(Bool.self, forKey: .tracker)) ?? false
        buzzer   = (try? k.decode(Bool.self, forKey: .buzzer)) ?? false
        volume   = (try? k.decode(Int.self, forKey: .vol)) ?? 80
        gps      = (try? k.decode(Bool.self, forKey: .gps)) ?? false
    }
}

extension DeviceStatus {
    /// Latest firmware this app ships against. Bump on a firmware release so the
    /// Device screen flags the update.
    static let latestVersion = "1.1"

    /// Just the version number out of `fw` ("ACAB-ouispy 0.1.0" -> "0.1.0").
    var version: String { firmware.split(separator: " ").last.map(String.init) ?? firmware }

    /// True for a Mesh-Detect board (no buzzer; its fw label starts "mesh-detect").
    var isMeshDetect: Bool { firmware.hasPrefix("mesh-detect") }

    /// Installed firmware older than `latestVersion`?
    var updateAvailable: Bool {
        version.compare(Self.latestVersion, options: .numeric) == .orderedAscending
    }
}
