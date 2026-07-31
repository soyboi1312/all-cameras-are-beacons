import Foundation
import MapKit
import Combine
import CryptoKit

/// The "known ALPR cameras" map overlay , community-mapped license-plate-reader
/// locations from OpenStreetMap (the registry the DeFlock project maintains), shown as a
/// quiet reference layer under the live detections.
///
/// PRIVACY: the phone downloads ONE static file from soyboi.tech and renders it locally.
/// It never queries Overpass, never sends its map viewport anywhere, and the fetch only
/// happens after the user opts in by turning the layer on. Same "nothing about where you
/// are leaves the device" promise as the rest of the app.
///
/// Wire format (`alpr.bin`, little-endian): "ALP2" | epochDay:u32 | count:u32 | nMakers:u8 |
/// nMakers*(len:u8, utf8) | count*(latE7:i32, lonE7:i32) | count*(makerIdx:u8). Maker table index 0
/// is always "" (unknown); the coord block matches ALP1 so an old cached ALP1 file still parses
/// (all makers unknown). The table is self-describing, so we never hardcode the maker list.
/// Manifest (`alpr-latest.json`): { updated, count, data:{ url, sha256, size } }. We re-download
/// only when `updated` changes; the parsed points are cached to disk for instant, offline redraw.
@MainActor
final class ALPRStore: ObservableObject {
    static let shared = ALPRStore()

    /// Loaded camera coordinates (empty until the layer is enabled + a dataset is present).
    @Published private(set) var nodes: [CLLocationCoordinate2D] = []
    /// Canonical maker name per node ("" = unknown), parallel to `nodes`. Kept as a plain array,
    /// not @Published: it only ever changes in the same assignment as `nodes`, and nothing observes
    /// it directly - the map/detail read it through nodes(in:) and nearest(to:).
    private var nodeMakers: [String] = []
    /// Dataset date string ("YYYY-MM-DD") for the attribution line, or nil.
    @Published private(set) var updated: String?
    /// True while ANY fetch is in flight, including the sub-second manifest freshness check.
    /// Drives the toggle's spinner, and suppresses the "couldn't load camera data" hint so a
    /// first load never flashes a false error before the points arrive.
    @Published private(set) var loading = false
    /// True only while the dataset BINARY is downloading/parsing. Narrower than `loading` on
    /// purpose: enabling an already-cached layer still runs a manifest check, and hanging the
    /// legend's auto-expand off `loading` popped it open and shut across that round-trip with
    /// nothing to show. Auto-expand is worth it for a real download, never for a freshness ping.
    @Published private(set) var downloading = false
    /// User opt-in. Persisted; flipping it on triggers the first download.
    @Published private(set) var enabled: Bool
    /// When the last manifest freshness check COMPLETED (success or already-up-to-date; a dead
    /// network stamps nothing). Persisted so the map settings caption survives relaunch.
    @Published private(set) var lastChecked: Date?
    /// How the most recent fetch ended, for the settings row's inline outcome. nil until a
    /// fetch has run this session.
    @Published private(set) var lastOutcome: RefreshOutcome?

    enum RefreshOutcome: Equatable {
        case updated(count: Int)    // new dataset downloaded + parsed
        case upToDate               // manifest checked, cached version already current
        case failed                 // network/decode/integrity failure; cache left in place
    }

    private let manifestURL = URL(string: "https://soyboi.tech/data/alpr-latest.json")!
    private let enabledKey = "acab.alpr.enabled"
    private let versionKey = "acab.alpr.version"      // last-downloaded dataset `updated`
    private let lastCheckedKey = "acab.alpr.lastChecked"   // epoch seconds of the last completed manifest check
    private var inFlight = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alpr.bin")
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        let t = UserDefaults.standard.double(forKey: lastCheckedKey)
        lastChecked = t > 0 ? Date(timeIntervalSince1970: t) : nil
        if enabled {
            loadFromDisk()          // instant redraw from the last-good cache
            refresh()               // then freshen in the background
        }
    }

    // MARK: opt-in

    /// Turn the layer on (loads cache + refreshes, downloading on first enable) or off
    /// (clears the in-memory points; the cache is kept so re-enabling is instant).
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            loadFromDisk()
            refresh()
        } else {
            nodes = []
            nodeMakers = []
        }
    }

    // MARK: viewport query

    /// The camera points inside `region`, capped so a zoomed-out view never tries to draw the
    /// whole set. Returns [] past the cap (caller shows a "zoom in" hint instead).
    func nodes(in region: MKCoordinateRegion, cap: Int = 500) -> [(coord: CLLocationCoordinate2D, maker: String)] {
        guard !nodes.isEmpty else { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        var out: [(coord: CLLocationCoordinate2D, maker: String)] = []
        out.reserveCapacity(min(cap, 64))
        for i in nodes.indices {
            let c = nodes[i]
            if c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon {
                out.append((c, i < nodeMakers.count ? nodeMakers[i] : ""))
                if out.count > cap { return [] }     // too many in view: signal "zoom in"
            }
        }
        return out
    }

    /// Nearest mapped camera to `coord`, for the detection detail's "matches a mapped camera" line.
    /// A ~2km bounding-box prefilter keeps this cheap over the full ~127k set (a real match is <200m,
    /// so nothing useful is ever outside the box); returns nil when the box is empty. Equirectangular
    /// distance is accurate to well under 1% at these ranges. On-device only - no query leaves the phone.
    func nearest(to coord: CLLocationCoordinate2D) -> (meters: Double, maker: String)? {
        guard !nodes.isEmpty else { return nil }
        let box = 0.02                                   // ~2.2 km half-window
        let cosLat = cos(coord.latitude * .pi / 180)
        var bestM = Double.greatestFiniteMagnitude
        var bestMaker = ""
        for i in nodes.indices {
            let c = nodes[i]
            if abs(c.latitude - coord.latitude) > box || abs(c.longitude - coord.longitude) > box { continue }
            let dLat = (c.latitude - coord.latitude) * 111_320
            let dLon = (c.longitude - coord.longitude) * 111_320 * cosLat
            let m = (dLat * dLat + dLon * dLon).squareRoot()
            if m < bestM { bestM = m; bestMaker = i < nodeMakers.count ? nodeMakers[i] : "" }
        }
        return bestM.isFinite ? (bestM, bestMaker) : nil
    }

    // MARK: fetch + cache

    /// Freshen the dataset if the layer is on. Non-blocking, failure-tolerant: a bad network or
    /// hash mismatch leaves the cached points in place and never throws into the UI.
    func refresh() {
        guard enabled, !inFlight else { return }
        inFlight = true
        Task { await fetch(); inFlight = false }
    }

    /// Awaitable variant for the map settings panel's "check for updates" row: same
    /// single-flight fetch, but the caller can await completion and read `lastOutcome`
    /// to render the result inline. No-ops (like `refresh`) if a fetch is already running.
    func refreshNow() async {
        guard enabled, !inFlight else { return }
        inFlight = true
        await fetch()
        inFlight = false
    }

    private func fetch() async {
        loading = true
        var outcome: RefreshOutcome = .failed
        defer { loading = false; lastOutcome = outcome }
        // 1) manifest
        var req = URLRequest(url: manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (mData, mResp) = try? await URLSession.shared.data(for: req),
              let http = mResp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let manifest = try? JSONDecoder().decode(ALPRManifest.self, from: mData),
              manifest.schema == 1, let d = manifest.data,
              let url = URL(string: d.url), url.scheme == "https" else { return }
        // Manifest check completed (whatever the version says): stamp it for the
        // settings caption's "checked X ago". Failures above deliberately stamp nothing.
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked!.timeIntervalSince1970, forKey: lastCheckedKey)
        // Already have this version cached + loaded? Nothing to do.
        if manifest.updated == UserDefaults.standard.string(forKey: versionKey), !nodes.isEmpty {
            updated = manifest.updated
            outcome = .upToDate
            return
        }
        // 2) binary. Past this point we are committed to a real download, so the legend may
        // auto-open to surface the data credit. Everything above was a freshness check.
        downloading = true
        defer { downloading = false }
        var breq = URLRequest(url: url)
        breq.timeoutInterval = 30
        guard let (bin, bResp) = try? await URLSession.shared.data(for: breq),
              let bhttp = bResp as? HTTPURLResponse, (200..<300).contains(bhttp.statusCode) else { return }
        // 3) integrity: size + sha256 must match the manifest, or we discard it
        guard bin.count == d.size,
              SHA256.hash(data: bin).map({ String(format: "%02x", $0) }).joined() == d.sha256.lowercased() else { return }
        // 4) parse + publish + cache
        guard let parsed = Self.parse(bin) else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        updated = manifest.updated
        outcome = .updated(count: parsed.coords.count)
        UserDefaults.standard.set(manifest.updated, forKey: versionKey)
        try? bin.write(to: cacheURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let bin = try? Data(contentsOf: cacheURL), let parsed = Self.parse(bin) else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        // The cache IS the version `versionKey` recorded, so a cold start can caption its
        // dataset date before (or without) the next successful manifest round-trip.
        if updated == nil { updated = UserDefaults.standard.string(forKey: versionKey) }
    }

    /// Parse the "ALP2" binary into coordinates + a parallel maker array. Also accepts a legacy
    /// "ALP1" file (coords only, all makers ""), so a cache written by an older build still loads.
    /// Bounds-checked throughout; returns nil on any malformation (a bad length, a table that runs
    /// past the buffer, an index past the table). Out-of-range coords are dropped WITH their maker
    /// so the two arrays stay in lockstep.
    private static func parse(_ data: Data) -> (coords: [CLLocationCoordinate2D], makers: [String])? {
        let isV2 = data.count >= 4 && data.prefix(4).elementsEqual("ALP2".utf8)
        let isV1 = data.count >= 4 && data.prefix(4).elementsEqual("ALP1".utf8)
        guard data.count >= 12, isV2 || isV1 else { return nil }
        let base = data.startIndex
        func u8(_ off: Int) -> Int { Int(data[base + off]) }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[base + off]) | (UInt32(data[base + off + 1]) << 8)
                | (UInt32(data[base + off + 2]) << 16) | (UInt32(data[base + off + 3]) << 24)
        }
        func i32(_ off: Int) -> Int32 { Int32(bitPattern: u32(off)) }
        let count = Int(u32(8))
        guard count >= 0, count < 5_000_000 else { return nil }

        var table: [String] = [""]
        var off = 12
        if isV2 {
            guard data.count >= 13 else { return nil }
            let nMakers = u8(12); off = 13
            table = []
            for _ in 0..<nMakers {
                guard off < data.count else { return nil }
                let len = u8(off); off += 1
                guard off + len <= data.count else { return nil }
                table.append(String(decoding: data[(base + off)..<(base + off + len)], as: UTF8.self))
                off += len
            }
            guard !table.isEmpty else { return nil }               // index 0 must exist
        }
        // coords, then (v2 only) the parallel maker-index array
        let coordsBytes = count * 8
        let idxBytes = isV2 ? count : 0
        guard data.count == off + coordsBytes + idxBytes else { return nil }
        let idxBase = off + coordsBytes

        var coords: [CLLocationCoordinate2D] = []; coords.reserveCapacity(count)
        var makers: [String] = []; makers.reserveCapacity(count)
        for k in 0..<count {
            let o = off + k * 8
            let c = CLLocationCoordinate2D(latitude: Double(i32(o)) / 1e7, longitude: Double(i32(o + 4)) / 1e7)
            guard CLLocationCoordinate2DIsValid(c) else { continue }  // drop corrupt coords, and their maker
            coords.append(c)
            if isV2 {
                let mi = u8(idxBase + k)
                makers.append(mi < table.count ? table[mi] : "")
            } else {
                makers.append("")
            }
        }
        return (coords, makers)
    }
}

/// Manifest shape published at soyboi.tech/data/alpr-latest.json.
private struct ALPRManifest: Codable {
    var schema: Int
    var updated: String
    var count: Int?
    var data: DataRef?
    struct DataRef: Codable { var url: String; var sha256: String; var size: Int }
}
