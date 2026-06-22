import Foundation
import CoreLocation

/// One detection event, decoded from a Detections-characteristic notify.
/// JSON shape and keys live in docs/ble-protocol.md.
struct Detection: Identifiable, Equatable {
    let type: DeviceType
    let source: DetectionSource
    let method: DetectionMethod
    let confidence: Int          // 0...100
    let mac: String
    let rssi: Int

    let name: String?            // advertised name
    let uasID: String?           // RID serial / operator id  (json "id")
    let detail: String?          // raven fw, ssid, op-id, etc. (json "det")

    let lat: Double?
    let lon: Double?
    let pilotLat: Double?        // json "plat"
    let pilotLon: Double?        // json "plon"
    let altitude: Int?           // metres MSL (drones)

    // Drone Remote ID flight telemetry (drones only; nil when not broadcast).
    let speedH: Int?             // horizontal speed m/s   (json "spd")
    let speedV: Int?             // vertical speed m/s     (json "vspd")
    let heading: Int?            // track direction deg    (json "hdg")
    let heightAGL: Int?          // height above takeoff m (json "hgt")
    let pilotAlt: Int?           // operator altitude m    (json "palt")
    let ridStatus: Int?          // ODID op status         (json "sta")

    let count: Int               // sightings this session (json "n")
    let isNew: Bool              // first sighting in the dedup window (json "new")

    // Offline-buffer replay fields (only set on a history drain; nil/false live).
    let isHistory: Bool          // a replayed buffered record (json "hist")
    let seq: UInt32?             // the board's buffer sequence number (json "seq")
    let capturedAt: Date?        // when the board actually saw it, unix secs (json "at")
    let approx: Bool             // timestamp unknown; only ordering is meaningful (json "approx")

    /// Stable identity. Drones group by UAS-ID so they survive MAC rotation, matching
    /// the firmware's dedup key. Everything else is one entry per (type, MAC).
    var id: String {
        if type == .drone, let uasID, !uasID.isEmpty { return "\(type.rawValue):\(uasID)" }
        return "\(type.rawValue):\(mac)"
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon, !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var pilotCoordinate: CLLocationCoordinate2D? {
        guard let pilotLat, let pilotLon, !(pilotLat == 0 && pilotLon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: pilotLat, longitude: pilotLon)
    }

    /// Best label we have: advertised name, else UAS serial, else device class.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let uasID, !uasID.isEmpty { return uasID }
        return type.label
    }

    /// Readable label for the drone's ODID operational status.
    var ridStatusLabel: String? {
        switch ridStatus {
        case 1: return "On ground"
        case 2: return "Airborne"
        case 3: return "Emergency"
        case 4: return "System fault"
        default: return nil
        }
    }

    /// Drone maker decoded from a CTA-2063-A Remote ID serial. The serial is a 4-char
    /// maker code, then a length digit, then the device serial. We name the codes we
    /// know and show the raw code otherwise.
    var ridManufacturer: String? {
        guard type == .drone, let s = uasID, s.count >= 5 else { return nil }
        let chars = Array(s)
        let code = String(chars[0..<4])
        let codeOK = code.allSatisfy { $0.isNumber || (("A"..."Z").contains($0) && $0 != "I" && $0 != "O") }
        guard codeOK, "123456789ABCDEF".contains(chars[4]) else { return nil }
        let names = ["1581": "DJI", "1748": "Autel", "1588": "Parrot", "1668": "Skydio", "1871": "Aurora"]
        return names[code] ?? "Mfr \(code)"
    }

    /// Rough signal bucket for the bars indicator (0...4).
    var signalBars: Int {
        switch rssi {
        case ..<(-90): return 1
        case ..<(-80): return 2
        case ..<(-67): return 3
        default:       return 4
        }
    }
}

extension Detection: Codable {
    // The firmware's short keys; they map to the longer property names above.
    enum CodingKeys: String, CodingKey {
        case t, s, meth, c, mac, rssi, name, id, det, lat, lon, plat, plon, alt
        case spd, vspd, hdg, hgt, palt, sta, n, new
        case hist, seq, at, approx   // offline-buffer replay
    }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        // Drop any detection whose type this build doesn't show (e.g. police gear,
        // t=6, which the firmware still emits). Throwing makes the enclosing
        // JSONDecoder().decode(...) fail at the try? call sites, so the row is
        // skipped instead of getting mislabeled by a .flockCamera fallback.
        guard let dt = DeviceType(rawValue: (try? k.decode(Int.self, forKey: .t)) ?? 0) else {
            throw DecodingError.dataCorruptedError(
                forKey: .t, in: k, debugDescription: "unsupported device type for this build")
        }
        type       = dt
        source     = DetectionSource(rawValue: (try? k.decode(Int.self, forKey: .s)) ?? 0) ?? .ble
        method     = DetectionMethod(rawValue: (try? k.decode(Int.self, forKey: .meth)) ?? 0) ?? .none
        confidence = (try? k.decode(Int.self, forKey: .c)) ?? 0
        mac        = (try? k.decode(String.self, forKey: .mac)) ?? "??:??:??:??:??:??"
        rssi       = (try? k.decode(Int.self, forKey: .rssi)) ?? 0
        name       = try? k.decodeIfPresent(String.self, forKey: .name)
        uasID      = try? k.decodeIfPresent(String.self, forKey: .id)
        detail     = try? k.decodeIfPresent(String.self, forKey: .det)
        lat        = try? k.decodeIfPresent(Double.self, forKey: .lat)
        lon        = try? k.decodeIfPresent(Double.self, forKey: .lon)
        pilotLat   = try? k.decodeIfPresent(Double.self, forKey: .plat)
        pilotLon   = try? k.decodeIfPresent(Double.self, forKey: .plon)
        altitude   = try? k.decodeIfPresent(Int.self, forKey: .alt)
        speedH     = try? k.decodeIfPresent(Int.self, forKey: .spd)
        speedV     = try? k.decodeIfPresent(Int.self, forKey: .vspd)
        heading    = try? k.decodeIfPresent(Int.self, forKey: .hdg)
        heightAGL  = try? k.decodeIfPresent(Int.self, forKey: .hgt)
        pilotAlt   = try? k.decodeIfPresent(Int.self, forKey: .palt)
        ridStatus  = try? k.decodeIfPresent(Int.self, forKey: .sta)
        count      = (try? k.decode(Int.self, forKey: .n)) ?? 1
        isNew      = (try? k.decode(Bool.self, forKey: .new)) ?? false
        isHistory  = (try? k.decode(Bool.self, forKey: .hist)) ?? false
        seq        = try? k.decodeIfPresent(UInt32.self, forKey: .seq)
        capturedAt = (try? k.decodeIfPresent(TimeInterval.self, forKey: .at) ?? nil).map(Date.init(timeIntervalSince1970:))
        approx     = (try? k.decode(Bool.self, forKey: .approx)) ?? false
    }

    // Encoded only for our own on-disk history checkpoint, using the same short keys
    // so init(from:) reads it straight back. Not part of the BLE wire protocol.
    func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        try k.encode(type.rawValue, forKey: .t)
        try k.encode(source.rawValue, forKey: .s)
        try k.encode(method.rawValue, forKey: .meth)
        try k.encode(confidence, forKey: .c)
        try k.encode(mac, forKey: .mac)
        try k.encode(rssi, forKey: .rssi)
        try k.encodeIfPresent(name, forKey: .name)
        try k.encodeIfPresent(uasID, forKey: .id)
        try k.encodeIfPresent(detail, forKey: .det)
        try k.encodeIfPresent(lat, forKey: .lat)
        try k.encodeIfPresent(lon, forKey: .lon)
        try k.encodeIfPresent(pilotLat, forKey: .plat)
        try k.encodeIfPresent(pilotLon, forKey: .plon)
        try k.encodeIfPresent(altitude, forKey: .alt)
        try k.encodeIfPresent(speedH, forKey: .spd)
        try k.encodeIfPresent(speedV, forKey: .vspd)
        try k.encodeIfPresent(heading, forKey: .hdg)
        try k.encodeIfPresent(heightAGL, forKey: .hgt)
        try k.encodeIfPresent(pilotAlt, forKey: .palt)
        try k.encodeIfPresent(ridStatus, forKey: .sta)
        try k.encode(count, forKey: .n)
        try k.encode(isNew, forKey: .new)
        try k.encode(isHistory, forKey: .hist)
        try k.encodeIfPresent(seq, forKey: .seq)
        try k.encodeIfPresent(capturedAt.map { $0.timeIntervalSince1970 }, forKey: .at)
        try k.encode(approx, forKey: .approx)
    }
}
