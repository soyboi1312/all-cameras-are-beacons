import Foundation
import CoreBluetooth
import CoreLocation
import Combine
import UIKit
import Intents
import ActivityKit
import Security

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
    /// Shared instance: the app, its App Intents (the Control Center toggle), and the Live
    /// Activity End button all drive ONE link. ACABApp injects this as the environment object.
    static let shared = BLEManager()

    @Published private(set) var connectionState: BLEConnectionState = .unknown
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connectedName: String?
    @Published private(set) var ignored: [IgnoredDevice] = []
    /// "Mark all seen" baseline. A detection counts as New if we first heard it after
    /// this point. Nil until the user sets a watermark (then everything older is "seen").
    @Published private(set) var seenWatermark: Date?
    @Published private(set) var demoMode = false   // canned sample data, no real board
    @Published private(set) var alertMode: AlertMode = .buzzer
    @Published private(set) var driveModeOn = false   // Live Activity (Drive mode) running
    /// Hide detection counts on the Lock Screen banner (user setting, default on). The
    /// counts still show in the Dynamic Island and in the app.
    @Published var redactLockScreen = true {
        didSet {
            UserDefaults.standard.set(redactLockScreen, forKey: redactKey)
            if driveModeOn { liveActivity.update(liveState(lastKind: ""), escalate: true) }
        }
    }

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
    private let watermarkKey = "acab.seenWatermark"   // "mark all seen" baseline
    private let alertModeKey = "acab.alertMode"
    private let lastSeqKey = "acab.lastSeq"   // persisted across disconnects; survives relaunch
    private let redactKey = "acab.redactLockScreen"

    // Offline detection buffer. The board buffers detections (encrypted at rest with
    // our key) while we're away, then replays them on {sync}. We file replayed records
    // into the same store + dedup as live ones, but with their original timestamp and
    // no alert.
    @Published private(set) var bufferingOn = false   // mirrors the board's "bufon"
    private var histReceived = 0                       // records filed this drain
    private var lastGoodSeq: UInt32 = 0                // highest contiguous seq filed this drain
    private var histPseudoTick = 0                     // monotonically-decreasing pseudo-time source for approx records
    private let notifHaptic = UINotificationFeedbackGenerator()
    private let impactHaptic = UIImpactFeedbackGenerator(style: .medium)

    private let locationManager = CLLocationManager()
    private var lastCoord: CLLocationCoordinate2D?

    private let liveActivity = LiveActivityController()   // Dynamic Island / Lock Screen counter
    // Per-category live counts, maintained in publishDetections() so the Live Activity
    // snapshot is O(1) instead of re-scanning the store on every detection notify.
    private var liveCounts = (alpr: 0, drones: 0, body: 0, trackers: 0)

    // Live-feed performance. A Desert-mode firehose can fire detection notifies far
    // faster than SwiftUI can diff a list, so we (1) cap the published array at the
    // most-recent `liveFeedCap` rows and (2) coalesce republishes to a few Hz.
    private let liveFeedCap = 400                  // most-recent rows kept in the live feed
    private var publishTimer: Timer?               // pending coalesced republish
    private var lastPublish = Date.distantPast     // when we last pushed to @Published
    private let publishInterval: TimeInterval = 0.3   // ~3 Hz ceiling on UI updates

    override init() {
        super.init()
        loadIgnored()
        if let t = UserDefaults.standard.object(forKey: watermarkKey) as? Double {
            seenWatermark = Date(timeIntervalSince1970: t)
        }
        loadPersistedDetections()   // bring back any history filed in a past session
        if let v = UserDefaults.standard.object(forKey: redactKey) as? Bool { redactLockScreen = v }
        // Keep the Drive-mode toggle honest: the controller flips it back off if the Live
        // Activity ends or the user swipes it away, and re-adopts one still running from a
        // previous launch (so a relaunch mid-drive resumes instead of orphaning it).
        liveActivity.onInactive = { [weak self] in self?.driveModeOn = false }
        // Best-effort: end the Drive-mode Live Activity when the app is force-quit, so the
        // Dynamic Island / Lock Screen counter doesn't linger. willTerminate only fires
        // while the app is actually running in the background - during Drive mode that comes
        // from the location updates (when location is granted), NOT bluetooth-central alone,
        // which iOS suspends between events. A suspended app (e.g. location denied) can be
        // killed without willTerminate; the activity's staleDate + the next-launch
        // adoptExisting() reconcile are the backstops there. endBlocking waits for ActivityKit
        // to take the dismissal before we return, since the process is about to die.
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.liveActivity.endBlocking()
        }
        if liveActivity.adoptExisting() { driveModeOn = true }
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
        publishTimer?.invalidate(); publishTimer = nil   // drop any queued coalesced republish
        store.removeAll(); lastSeen.removeAll(); rssiHistory.removeAll()
        trackHistory.removeAll()
        firstSeenAt.removeAll(); capturedLoc.removeAll(); detections = []
        liveCounts = (0, 0, 0, 0)
        deletePersistedDetections()   // also wipe the on-disk history
        if driveModeOn { liveActivity.update(liveState(lastKind: "")) }
    }

    // MARK: - Drive mode (Live Activity: Dynamic Island + Lock Screen counter)

    /// Live Activities can be disabled per-app in Settings; the toggle surfaces a hint.
    var liveActivitiesEnabled: Bool { liveActivity.isAvailable }

    /// Start the Drive-mode Live Activity. iOS requires the app to be foregrounded to
    /// begin one; the toggle lives in DeviceView, which is on-screen when tapped.
    func startDriveMode() {
        guard liveActivity.isAvailable else { return }
        liveActivity.dropIfInactive()
        if liveActivity.adoptExisting() {   // reuse one already running (e.g. the Control Center toggle)
            driveModeOn = true
            liveActivity.update(liveState(lastKind: ""))
            return
        }
        // Reflect whether the system actually started the activity (request can fail
        // silently); the controller also resets driveModeOn if it's later dismissed.
        driveModeOn = liveActivity.start(deviceName: connectedName ?? "Beacons",
                                         state: liveState(lastKind: ""))
    }

    func endDriveMode() {
        driveModeOn = false
        liveActivity.end()
    }

    /// Re-sync Drive mode with reality when the app returns to the foreground: adopt an
    /// activity started by the Control Center toggle, and turn the flag off if the Live
    /// Activity was ended (the in-activity End button, the toggle, or a swipe-away).
    func reconcileDriveMode() {
        liveActivity.dropIfInactive()
        if liveActivity.adoptExisting() {
            driveModeOn = true
            liveActivity.update(liveState(lastKind: ""))
        } else {
            driveModeOn = false
        }
    }

    /// Snapshot the live store into the Live Activity's per-category counts. Mirrors the
    /// dashboard tiles exactly (ALPR = flockCamera + flockRaven; no police bucket).
    private func liveState(lastKind: String) -> DetectionActivityAttributes.DetectionState {
        // O(1): counts are maintained by publishDetections() (which already iterates the
        // store for the sort), not re-scanned here on every detection notify.
        return .init(alpr: liveCounts.alpr, drones: liveCounts.drones,
                     bodyCams: liveCounts.body, trackers: liveCounts.trackers,
                     lastKind: lastKind, lastSeen: Date(),
                     connected: connectionState == .connected || demoMode,
                     redact: redactLockScreen)
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

    /// Silence several devices at once (the Logbook's select mode). One ignore-list
    /// push and one republish instead of one per row. The firmware accepts up to 256
    /// entries, so we cap the list there.
    func ignoreDevices(_ list: [Detection]) {
        var added = false
        for d in list {
            let mac = d.mac.lowercased()
            guard !isIgnored(mac), ignored.count < 256 else { continue }
            ignored.append(IgnoredDevice(mac: mac, label: d.displayName))
            added = true
        }
        guard added else { return }
        persistIgnored(); sendIgnoreList()
        let muted = Set(ignored.map { $0.mac })
        for e in store.values where muted.contains(e.mac.lowercased()) {
            store[e.id] = nil; lastSeen[e.id] = nil
        }
        publishDetections()
    }

    /// Un-silence a device.
    func unignore(_ mac: String) {
        ignored.removeAll { $0.mac == mac.lowercased() }
        persistIgnored(); sendIgnoreList()
    }

    // MARK: - Seen watermark ("mark all seen")

    /// Drop a "seen" baseline at now: everything currently in the log becomes "seen",
    /// and the New-only filter then shows only what arrives after this.
    func markAllSeen() {
        let now = Date()
        seenWatermark = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: watermarkKey)
    }

    /// Clear the baseline so every detection counts as New again.
    func clearSeenWatermark() {
        seenWatermark = nil
        UserDefaults.standard.removeObject(forKey: watermarkKey)
    }

    /// Has this detection been seen yet? New means first heard after the watermark
    /// (or always New when no watermark is set).
    func isUnseen(_ d: Detection) -> Bool {
        guard let mark = seenWatermark else { return true }
        guard let first = firstSeenAt[d.id] else { return true }
        return first > mark
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

    /// Push the store into the published feed immediately. Recomputes the per-category
    /// counts (O(store), needed for the Live Activity), sorts most-recent-first, and
    /// caps the array so a huge Desert-mode store doesn't hand SwiftUI thousands of rows.
    private func publishDetections() {
        publishTimer?.invalidate()
        publishTimer = nil
        lastPublish = Date()

        var a = 0, dr = 0, b = 0, tr = 0
        for d in store.values {
            switch d.type {
            case .flockCamera, .flockRaven: a += 1
            case .drone:                    dr += 1
            case .axonBodyCam:              b += 1
            case .tracker:                  tr += 1
            case .nearbyDevice:             break   // Desert-mode devices don't fill the drive-mode buckets
            }
        }
        liveCounts = (a, dr, b, tr)
        let sorted = store.values.sorted {
            (lastSeen[$0.id] ?? .distantPast) > (lastSeen[$1.id] ?? .distantPast)
        }
        detections = sorted.count > liveFeedCap ? Array(sorted.prefix(liveFeedCap)) : sorted
    }

    /// Coalesced republish for the hot path. Publishes at most once per
    /// `publishInterval`; rapid-fire notifies in between collapse into one trailing
    /// update, so a Desert-mode firehose updates the feed a few times a second instead
    /// of thrashing SwiftUI on every record.
    private func schedulePublish() {
        guard publishTimer == nil else { return }   // a trailing publish is already queued
        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= publishInterval {
            publishDetections()
        } else {
            publishTimer = Timer.scheduledTimer(withTimeInterval: publishInterval - elapsed,
                                                repeats: false) { [weak self] _ in
                self?.publishTimer = nil
                self?.publishDetections()
            }
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

    /// Toggle Desert mode: the board reports EVERY device in range (not just signatures).
    /// Enabling it drops alerts to Silent; with everything reporting in, the buzzer and
    /// haptics would otherwise never stop. The user can switch sound back on afterward.
    func setDesertMode(_ on: Bool) {
        writeConfig(["desert": on])
        if on && alertMode != .silent { setAlertMode(.silent) }
    }

    /// Toggle the board's offline detection buffer (off by default in firmware). When
    /// on, the board stores detections while we're disconnected and replays them on
    /// the next {sync}.
    func setBufferingEnabled(_ on: Bool) {
        bufferingOn = on
        writeConfig(["buffer": on])
    }

    /// Erase the board's stored buffer.
    func clearBufferLog() { writeConfig(["clearlog": true]) }

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

    /// Push the phone's GPS to the board so a Mesh-Detect uplink can carry where we
    /// are. Throttled - the board only needs a periodic fix, not every CL update.
    private var lastGpsSent = Date.distantPast
    private func sendPhoneLocation() {
        guard let c = lastCoord, configChar != nil,
              Date().timeIntervalSince(lastGpsSent) > 15 else { return }
        lastGpsSent = Date()
        writeConfig(["lat": c.latitude, "lon": c.longitude])
    }

    // MARK: - Offline buffer: key, handshake, lastSeq, persistence

    /// Highest buffer seq we've successfully filed. Persisted so a reconnect only asks
    /// the board for records newer than this. Survives disconnects and relaunches —
    /// disconnect cleanup must NOT clear it.
    private var lastSeq: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: lastSeqKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSeqKey) }
    }

    /// The Detections-replay handshake, run once the Detections characteristic starts
    /// notifying: hand the board our key, the current epoch, then ask it to replay
    /// everything newer than lastSeq. Order matters and must follow the subscribe.
    private func sendBufferHandshake() {
        let key = bufferKeyHex()
        // Reset per-drain counters; resume contiguity from where we left off.
        histReceived = 0
        histPseudoTick = 0
        lastGoodSeq = lastSeq
        writeConfig(["key": key])
        writeConfig(["epoch": Int(Date().timeIntervalSince1970)])
        writeConfig(["sync": Int(lastSeq)])
    }

    // MARK: key (Keychain)

    private let keyTag = "tech.beacons.app.bufferKey"

    /// Our persistent 32-byte buffer key as 64 lowercase hex chars. Generated once and
    /// stored in the Keychain, reused on every launch.
    private func bufferKeyHex() -> String {
        let raw = loadOrCreateBufferKey()
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrCreateBufferKey() -> Data {
        if let existing = keychainReadKey() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        keychainWriteKey(data)
        return data
    }

    private func keychainReadKey() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private func keychainWriteKey(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // AfterFirstUnlockThisDeviceOnly: readable for the while-locked BLE handshake, but
        // ThisDeviceOnly makes the key non-exportable (kept out of iTunes/Finder backups).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: local persistence (Application Support)

    /// Where we checkpoint filed detections so replayed history survives a relaunch.
    private var persistURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("acab-detections.json")
    }

    /// One persisted detection row: the raw record plus the timing we reconstructed.
    private struct StoredRow: Codable {
        let detection: Detection
        let firstSeen: Date?
        let lastSeen: Date?
        let lat: Double?
        let lon: Double?
    }

    private func persistDetections() {
        guard let url = persistURL else { return }
        let rows = store.values.map { d -> StoredRow in
            let c = capturedLoc[d.id]
            return StoredRow(detection: d, firstSeen: firstSeenAt[d.id], lastSeen: lastSeen[d.id],
                             lat: c?.latitude, lon: c?.longitude)
        }
        // .completeFileProtection: the detections file (MACs + phone GPS + timestamps) is
        // unreadable while the device is locked, so a seized locked phone can't yield it.
        if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    private func loadPersistedDetections() {
        guard let url = persistURL, let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([StoredRow].self, from: data) else { return }
        for r in rows {
            let d = r.detection
            store[d.id] = d
            if let f = r.firstSeen { firstSeenAt[d.id] = f }
            if let l = r.lastSeen { lastSeen[d.id] = l }
            if let lat = r.lat, let lon = r.lon {
                capturedLoc[d.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        publishDetections()
    }

    private func deletePersistedDetections() {
        if let url = persistURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Decoding

    // Hot path: every detection notify from the board lands here. This carries both
    // live detections and, during a buffer drain, replayed history records plus a
    // closing sentinel.
    private func ingestDetection(_ data: Data) {
        // The drain ends with a sentinel {"hist":"end","n":N} that isn't a Detection
        // (no "t"). Catch it first so we can verify the count and re-sync on a gap.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["hist"] as? String) == "end" {
            handleHistEnd(expected: (obj["n"] as? Int) ?? histReceived)
            return
        }

        guard let d = try? JSONDecoder().decode(Detection.self, from: data) else { return }
        if isIgnored(d.mac) { return }       // whitelisted — drop it (the board does too)

        let firstTime = store[d.id] == nil
        if d.isHistory {
            // Replayed buffered record: file it with its original time, no alert.
            ingestHistory(d, firstTime: firstTime)
        } else {
            if firstTime {                   // first sighting: stamp time and place
                firstSeenAt[d.id] = Date()
                capturedLoc[d.id] = lastCoord
            }
            store[d.id] = d
            lastSeen[d.id] = Date()
        }

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
        schedulePublish()   // coalesced: a Desert-mode firehose updates the feed a few Hz, not per-record
        if d.isHistory { persistDetections() }   // history changed the store; checkpoint it
        // Live first sightings buzz; replayed history never does.
        if !d.isHistory, alertMode == .vibrate, firstTime, !focusActive { alertHaptic(for: d.type) }
        // Drive mode: push the live count to the Dynamic Island / Lock Screen. A brand-new
        // device escalates (immediate); the rest coalesce in the controller. History never updates.
        if !d.isHistory, driveModeOn {
            liveActivity.update(liveState(lastKind: d.type.category), escalate: firstTime)
        }
    }

    /// File one replayed buffered record. Uses the record's own timestamp ("at") when
    /// the board knew it; otherwise a synthetic monotonically-DECREASING pseudo-time
    /// derived from seq, so the newest-first sort in publishDetections() leaves history
    /// behind live hits instead of pulling it to "now".
    private func ingestHistory(_ d: Detection, firstTime: Bool) {
        let stamp: Date
        if let at = d.capturedAt {
            stamp = at                       // absolute time the board captured it
        } else {
            // approx (or no "at"): fabricate a strictly-decreasing time well in the past.
            histPseudoTick += 1
            stamp = Date(timeIntervalSince1970: 1).addingTimeInterval(-Double(histPseudoTick))
        }
        // Don't let a replayed record clobber a fresher live entry or an earlier-filed
        // history record for the same id.
        if firstTime {
            firstSeenAt[d.id] = stamp
            capturedLoc[d.id] = d.coordinate
            store[d.id] = d
            lastSeen[d.id] = stamp
        } else if let existing = lastSeen[d.id], stamp < existing {
            // keep the newer of the two as the sort key, but make sure the record exists
            if store[d.id] == nil { store[d.id] = d }
        } else {
            store[d.id] = d
            lastSeen[d.id] = stamp
            if firstSeenAt[d.id] == nil { firstSeenAt[d.id] = stamp }
        }

        histReceived += 1
        // Advance the contiguous high-water mark only on an in-order seq.
        if let s = d.seq, s == lastGoodSeq + 1 { lastGoodSeq = s }
    }

    /// End-of-drain sentinel. Verify we got every record the board promised; if a seq
    /// gap dropped some, re-issue {sync} from the last contiguous seq to refill. On a
    /// clean drain, persist lastSeq so we don't re-request what we already have.
    private func handleHistEnd(expected: Int) {
        let ok = histReceived == expected
        if ok {
            if lastGoodSeq > lastSeq { lastSeq = lastGoodSeq }
            persistDetections()
        } else {
            // Gap: ask the board to replay again from the last good contiguous seq.
            writeConfig(["sync": Int(lastGoodSeq)])
        }
        histReceived = 0
        histPseudoTick = 0
    }

    private func ingestStatus(_ data: Data) {
        if let s = try? JSONDecoder().decode(DeviceStatus.self, from: data) {
            status = s
            bufferingOn = s.bufferingOn   // keep the toggle in step with the board
        }
    }

    /// Fill the app with sample detections so you can explore the whole UI without a
    /// board. Used by the connect screen's "Continue without pairing" and the `-demo`
    /// launch argument in debug builds.
    func seedDemoData() {
        demoMode = true
        connectionState = .connected
        connectedName = "ESP32 board"
        status = decodeJSON(DeviceStatus.self, [
            "fw": "esp32-scanner 1.7", "up": 4920, "total": 7, "ble": true, "wifi": true,
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
        publishDetections()   // sort the feed + populate the live category counts
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
        if driveModeOn { liveActivity.setConnected(false) }   // -> "Reconnecting…", don't end the session
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
        if driveModeOn { liveActivity.setConnected(true) }   // back from a dropout
        sendIgnoreList()   // re-send the whitelist so the board has it this session
        setBuzzerEnabled(alertMode == .buzzer)   // a fresh board boots up buzzing; match the phone's mode
        lastGpsSent = .distantPast; sendPhoneLocation()   // push our location to the freshly-connected board
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Once the Detections characteristic is actually subscribed, run the buffer
        // handshake (key, epoch, sync) so the board can replay anything it buffered
        // while we were away. Order matters: this must come AFTER the subscribe.
        guard characteristic.uuid == ACABProfile.detections, characteristic.isNotifying else { return }
        sendBufferHandshake()
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
        sendPhoneLocation()
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
