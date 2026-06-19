import Foundation
import CoreBluetooth
import CoreLocation
import Combine
import UIKit
import Intents

/// A board we spotted while scanning.
struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var firmware: String?
}

/// A device the user has chosen to silence (one whitelist entry).
struct IgnoredDevice: Codable, Identifiable, Equatable {
    let mac: String
    let label: String
    var id: String { mac }
}

/// How alerts reach you: board buzzer, phone haptics, or nothing.
enum AlertMode: String, CaseIterable {
    case buzzer   // board buzzes, phone stays quiet (the default)
    case vibrate  // board muted, phone buzzes on each first sighting
    case silent   // board muted, no phone feedback either
}

/// Connection lifecycle the UI watches. Doesn't track data-readiness separately.
enum BLEConnectionState: Equatable {
    case unknown          // haven't heard the radio's state yet
    case poweredOff
    case unauthorized
    case idle             // ready, just not scanning
    case scanning
    case connecting
    case connected
}

/// Drives the link to an OUI-Spy board: scan, connect, stream detections, push
/// config. CoreBluetooth runs on `queue: nil`, so every delegate callback lands on
/// the main thread. That's why we can set @Published state straight from them.
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var connectionState: BLEConnectionState = .unknown
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connectedName: String?
    @Published private(set) var ignored: [IgnoredDevice] = []
    @Published private(set) var demoMode = false   // canned sample data, no real board
    @Published private(set) var alertMode: AlertMode = .buzzer

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var configChar: CBCharacteristic?

    // Detections keyed by Detection.id (type:mac), plus arrival time so the feed
    // can sort most-recent-first.
    private var store: [String: Detection] = [:]
    private var lastSeen: [String: Date] = [:]
    private var rssiHistory: [String: [Int]] = [:]
    private var trackHistory: [String: [CLLocationCoordinate2D]] = [:]   // drone flight paths
    private var firstSeenAt: [String: Date] = [:]
    private var capturedLoc: [String: CLLocationCoordinate2D] = [:]
    private let ignoreKey = "acab.ignoredDevices"
    private let alertModeKey = "acab.alertMode"
    private let notifHaptic = UINotificationFeedbackGenerator()
    private let impactHaptic = UIImpactFeedbackGenerator(style: .medium)

    private let locationManager = CLLocationManager()
    private var lastCoord: CLLocationCoordinate2D?

    override init() {
        super.init()
        loadIgnored()
        alertMode = AlertMode(rawValue: UserDefaults.standard.string(forKey: alertModeKey) ?? "") ?? .buzzer
        if alertMode == .vibrate { requestFocusAuthIfNeeded() }
        central = CBCentralManager(delegate: self, queue: nil)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.requestWhenInUseAuthorization()   // just for tagging the log; fine to deny
    }

    // MARK: - Intent

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        connectionState = .scanning
        // Allow duplicates so we don't miss the scan-response manufacturer data
        // (the firmware version) — it usually shows up a callback or two after the first advert.
        central.scanForPeripherals(withServices: [ACABProfile.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        central.stopScan()
        connectionState = .connecting
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    func clearDetections() {
        store.removeAll(); lastSeen.removeAll(); rssiHistory.removeAll()
        trackHistory.removeAll()
        firstSeenAt.removeAll(); capturedLoc.removeAll(); detections = []
    }

    /// A drone's accumulated flight path (empty for everything else).
    func track(for id: String) -> [CLLocationCoordinate2D] { trackHistory[id] ?? [] }

    /// Phone's last known coordinate — used to center the no-GPS RSSI ring.
    var selfCoord: CLLocationCoordinate2D? { lastCoord }

    // MARK: - Whitelist (ignored devices)

    /// Is this MAC on the ignore list?
    func isIgnored(_ mac: String) -> Bool { ignored.contains { $0.mac == mac.lowercased() } }

    /// Silence a device: the board stops alerting on it and it drops out of the app.
    func ignoreDevice(_ d: Detection) {
        let mac = d.mac.lowercased()
        guard !isIgnored(mac) else { return }
        ignored.append(IgnoredDevice(mac: mac, label: d.displayName))
        persistIgnored(); sendIgnoreList()
        for e in store.values where e.mac.lowercased() == mac { store[e.id] = nil; lastSeen[e.id] = nil }
        publishDetections()
    }

    /// Un-silence a device.
    func unignore(_ mac: String) {
        ignored.removeAll { $0.mac == mac.lowercased() }
        persistIgnored(); sendIgnoreList()
    }

    private func loadIgnored() {
        if let data = UserDefaults.standard.data(forKey: ignoreKey),
           let list = try? JSONDecoder().decode([IgnoredDevice].self, from: data) { ignored = list }
    }
    private func persistIgnored() {
        if let data = try? JSONEncoder().encode(ignored) { UserDefaults.standard.set(data, forKey: ignoreKey) }
    }
    /// Send the ignore list to the board so it suppresses those MACs at the source.
    private func sendIgnoreList() { writeConfig(["ignore": ignored.map { $0.mac }]) }

    private func publishDetections() {
        detections = store.values.sorted {
            (lastSeen[$0.id] ?? .distantPast) > (lastSeen[$1.id] ?? .distantPast)
        }
    }

    /// Recent RSSI samples, oldest-first — feeds the detail sparkline.
    func rssiTrend(for id: String) -> [Int] { rssiHistory[id] ?? [] }

    /// When we first heard this detection, or nil if never.
    func firstSeenDate(for id: String) -> Date? { firstSeenAt[id] }

    /// When we last heard this detection, or nil if never.
    func lastSeenDate(for id: String) -> Date? { lastSeen[id] }

    /// Has this detection gone quiet? True if we've never heard it, or the last
    /// sighting is older than `seconds` ago.
    func isStale(for id: String, olderThan seconds: TimeInterval = 45) -> Bool {
        guard let last = lastSeen[id] else { return true }
        return Date().timeIntervalSince(last) > seconds
    }

    /// Where the phone was when we first heard this (the board has no GPS). Drones
    /// send their own position, but for Flock/Raven/Axon this is what pins them on
    /// the map. Nil if we had no location at first sighting.
    func capturedLocation(for id: String) -> CLLocationCoordinate2D? { capturedLoc[id] }

    // MARK: - Export

    /// CSV of the current log: when, what, and where for each detection. "Where" is
    /// your phone's position at first sighting (the board has no GPS), or blank if we
    /// had no location then.
    func detectionsCSV() -> String {
        let fmt = ISO8601DateFormatter()
        var rows = ["detected_at,type,mac,rssi,source,matched_on,confidence,sightings,approx_lat,approx_lon"]
        for d in detections {
            let when  = firstSeenAt[d.id].map { fmt.string(from: $0) } ?? ""
            let coord = capturedLoc[d.id] ?? d.coordinate
            let lat = coord.map { String(format: "%.6f", $0.latitude) } ?? ""
            let lon = coord.map { String(format: "%.6f", $0.longitude) } ?? ""
            rows.append([when, csvSafe(d.type.label), d.mac, "\(d.rssi)",
                         d.source.label, d.method.label, "\(d.confidence)",
                         "\(d.count)", lat, lon].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// Write the log CSV to a temp file for the share sheet and return its URL.
    func writeDetectionsCSV() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acab-detections.csv")
        do { try detectionsCSV().write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }

    private func csvSafe(_ s: String) -> String {
        (s.contains(",") || s.contains("\"") || s.contains("\n"))
            ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }

    /// Toggle the board's body-cam (Axon signature) detector.
    func setBodyCamEnabled(_ on: Bool) { writeConfig(["bodycam": on]) }

    /// Toggle the board's BLE item-tracker detector (off by default).
    func setTrackerEnabled(_ on: Bool) { writeConfig(["tracker": on]) }

    /// Master audio on/off.
    func setBuzzerEnabled(_ on: Bool) { writeConfig(["buzzer": on]) }

    /// Pick how alerts reach you. Only `.buzzer` keeps the board's buzzer live;
    /// the others mute it.
    func setAlertMode(_ m: AlertMode) {
        alertMode = m
        UserDefaults.standard.set(m.rawValue, forKey: alertModeKey)
        setBuzzerEnabled(m == .buzzer)
        if m == .vibrate { notifHaptic.prepare(); requestFocusAuthIfNeeded() }
    }

    /// Buzz the phone on a fresh sighting — a sharper pattern for priority threats.
    private func alertHaptic(for type: DeviceType) {
        switch type {
        case .flockCamera, .flockRaven, .drone: notifHaptic.notificationOccurred(.error)
        default:                                impactHaptic.impactOccurred()
        }
    }

    /// Ask once for Focus access, so vibrate alerts can defer to Do Not Disturb.
    private func requestFocusAuthIfNeeded() {
        if INFocusStatusCenter.default.authorizationStatus == .notDetermined {
            INFocusStatusCenter.default.requestAuthorization { _ in }
        }
    }

    /// True when a Focus (or Do Not Disturb) is on, so vibrate alerts stay quiet.
    /// If we can't read Focus (never authorized), treat it as off so alerts still fire.
    private var focusActive: Bool {
        INFocusStatusCenter.default.focusStatus.isFocused == true
    }

    /// Buzzer loudness, 0...100. `preview: true` also has the board beep once at that
    /// level, so you can hear it on slider release.
    func setVolume(_ v: Int, preview: Bool = false) {
        var cfg: [String: Any] = ["volume": max(0, min(100, v))]
        if preview { cfg["beep"] = true }
        writeConfig(cfg)
    }

    /// Turn the board's BLE detection scan on/off. This only stops scanning — our
    /// BLE link to the board stays up.
    func setBLEScan(_ on: Bool) { writeConfig(["ble": on]) }

    /// Turn the board's Wi-Fi (promiscuous) detection scan on/off.
    func setWiFiScan(_ on: Bool) { writeConfig(["wifi": on]) }

    private func writeConfig(_ dict: [String: Any]) {
        guard let peripheral, let configChar,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        peripheral.writeValue(data, for: configChar, type: .withResponse)
    }

    // MARK: - Decoding

    // Hot path: every detection notify from the board lands here.
    private func ingestDetection(_ data: Data) {
        guard let d = try? JSONDecoder().decode(Detection.self, from: data) else { return }
        if isIgnored(d.mac) { return }       // whitelisted — drop it (the board does too)
        let firstTime = store[d.id] == nil
        if firstTime {                       // first sighting: stamp time and place
            firstSeenAt[d.id] = Date()
            capturedLoc[d.id] = lastCoord
        }
        store[d.id] = d
        lastSeen[d.id] = Date()
        var h = rssiHistory[d.id] ?? []
        h.append(d.rssi); if h.count > 48 { h.removeFirst(h.count - 48) }  // keep the last 48
        rssiHistory[d.id] = h
        if d.type == .drone, let c = d.coordinate {       // grow the drone's flight path
            var t = trackHistory[d.id] ?? []
            if t.last?.latitude != c.latitude || t.last?.longitude != c.longitude {
                t.append(c); if t.count > 60 { t.removeFirst(t.count - 60) }
                trackHistory[d.id] = t
            }
        }
        publishDetections()
        if alertMode == .vibrate, firstTime, !focusActive { alertHaptic(for: d.type) }   // skip while a Focus is on
    }

    private func ingestStatus(_ data: Data) {
        if let s = try? JSONDecoder().decode(DeviceStatus.self, from: data) { status = s }
    }

    /// Fill the app with sample detections so you can explore the whole UI without a
    /// board. Used by the connect screen's "Continue without pairing" and the `-demo`
    /// launch argument in debug builds.
    func seedDemoData() {
        demoMode = true
        connectionState = .connected
        connectedName = "ESP32 board"
        status = decodeJSON(DeviceStatus.self, [
            "fw": "esp32-scanner 1.0", "up": 4920, "total": 7, "ble": true, "wifi": true,
            "axon": false, "tracker": true, "buzzer": true, "vol": 70, "gps": true,
        ])
        let samples: [[String: Any]] = [
            ["t": 1, "s": 1, "meth": 1, "c": 95, "mac": "AC:AB:00:7F:2A:10", "rssi": -54,
             "name": "FlockSafety", "lat": 37.7799, "lon": -122.4202, "n": 12, "new": true],
            ["t": 1, "s": 0, "meth": 4, "c": 88, "mac": "AC:AB:00:91:5B:22", "rssi": -67,
             "lat": 37.7782, "lon": -122.4175, "n": 4],
            ["t": 2, "s": 0, "meth": 2, "c": 72, "mac": "AC:AB:00:3C:7E:01", "rssi": -76,
             "det": "Raven audio v2", "lat": 37.7808, "lon": -122.4188, "n": 2],
            ["t": 4, "s": 2, "meth": 7, "c": 99, "mac": "DA:7E:E0:44:21:09", "rssi": -61,
             "id": "1581F4FED0A2B7", "lat": 37.7816, "lon": -122.4169,
             "plat": 37.7821, "plon": -122.4151, "alt": 84, "n": 1, "new": true],
            ["t": 3, "s": 0, "meth": 3, "c": 45, "mac": "AX:0N:00:BA:7C:33", "rssi": -88, "n": 1],
            ["t": 5, "s": 0, "meth": 3, "c": 85, "mac": "4C:00:12:19:AA:BB", "rssi": -72,
             "det": "Apple Find My (offline)", "lat": 37.7791, "lon": -122.4196, "n": 3],
        ]
        for dict in samples {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let d = try? JSONDecoder().decode(Detection.self, from: data) else { continue }
            store[d.id] = d
            lastSeen[d.id] = Date()
            firstSeenAt[d.id] = Date()
            let r = d.rssi
            rssiHistory[d.id] = [-6, -3, -7, -1, -4, 2, -2, 1, -3, 0, -1, 1, -2, 0]
                .map { max(-99, min(-30, r + $0)) }
        }
        detections = store.values.sorted {
            (lastSeen[$0.id] ?? .distantPast) > (lastSeen[$1.id] ?? .distantPast)
        }
    }

    /// Drop demo mode and go back to the connect screen.
    func exitDemo() {
        demoMode = false
        connectedName = nil
        status = nil
        clearDetections()
        connectionState = (central.state == .poweredOn) ? .idle : .unknown
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if demoMode { return }      // demo mode pins us as connected
        switch central.state {
        case .poweredOn:    connectionState = (peripheral == nil) ? .idle : connectionState
        case .poweredOff:   connectionState = .poweredOff
        case .unauthorized: connectionState = .unauthorized
        default:            connectionState = .unknown
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ACABProfile.advertisedName
        let fw = parseFirmwareVersion(advertisementData)
        #if DEBUG
        if name.uppercased().contains("ACAB") {
            let raw = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?
                .map { String(format: "%02X", $0) }.joined() ?? "none"
            print("[ACAB-scan] name=\(name) mfg=\(raw) parsedFW=\(fw ?? "nil") " +
                  "keys=[\(advertisementData.keys.joined(separator: ","))]")
        }
        #endif
        let dev = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                   name: name, rssi: RSSI.intValue, firmware: fw)
        if let i = discovered.firstIndex(where: { $0.id == dev.id }) {
            discovered[i].rssi = dev.rssi
            if let fw { discovered[i].firmware = fw }
        } else {
            discovered.append(dev)
        }
    }

    /// Pull the firmware version out of our scan-response manufacturer data (company id 0xACAB).
    private func parseFirmwareVersion(_ adv: [String: Any]) -> String? {
        guard let data = adv[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count > 2, data[0] == 0xAB, data[1] == 0xAC else { return nil }
        return String(data: data.subdata(in: 2..<data.count), encoding: .utf8)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedName = peripheral.name ?? ACABProfile.advertisedName
        peripheral.discoverServices([ACABProfile.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectionState = .idle
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        configChar = nil
        connectedName = nil
        status = nil
        connectionState = (central.state == .poweredOn) ? .idle : .unknown
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == ACABProfile.service }) else {
            disconnect(); return
        }
        peripheral.discoverCharacteristics(
            [ACABProfile.detections, ACABProfile.config, ACABProfile.status], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case ACABProfile.detections: peripheral.setNotifyValue(true, for: ch)
            case ACABProfile.status:     peripheral.setNotifyValue(true, for: ch); peripheral.readValue(for: ch)
            case ACABProfile.config:     configChar = ch
            default: break
            }
        }
        connectionState = .connected
        sendIgnoreList()   // re-send the whitelist so the board has it this session
        setBuzzerEnabled(alertMode == .buzzer)   // a fresh board boots up buzzing; match the phone's mode
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case ACABProfile.detections: ingestDetection(data)
        case ACABProfile.status:     ingestStatus(data)
        default: break
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension BLEManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastCoord = locations.last?.coordinate
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true   // keep tagging if the app is backgrounded mid-drive
            manager.startUpdatingLocation()
        default: break
        }
    }
}
