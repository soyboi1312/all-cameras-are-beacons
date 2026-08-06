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
    /// Confidence per node, parallel to `nodes`: true when the mapper picked the manufacturer from
    /// an editor preset (it carries a wikidata id), false when it was typed freehand or left blank.
    /// The false set is small (7-14%) and is where misidentified pins concentrate, so the map draws
    /// it in a different colour and says so. Same lifecycle as nodeMakers: not @Published, only
    /// ever assigned alongside `nodes`.
    private var nodeConfirmed: [Bool] = []
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
        /// The manifest 404s. NOT a network fault, and worth its own case because it means
        /// something specific and temporary: this build polls its own manifest URL (see
        /// manifestURL), so between an app release and the dataset being published there is a
        /// window where the file legitimately does not exist yet. Telling the user to "check your
        /// connection" in that window sends them to debug a working network.
        case notPublished
    }

    /// The V3 manifest, deliberately a SEPARATE URL from the one shipped builds poll.
    /// alpr-latest.json still serves ALP2 and always will, because an already-installed app
    /// exact-length-checks the binary and REJECTS an ALP3 file outright rather than ignoring the
    /// extra tail , and its reject path returns before it stamps the version key, so it would
    /// re-download and re-fail forever with a map frozen at the last good dataset. Pointing new
    /// builds at their own manifest means the rollout cannot break the installed base, whatever
    /// order the app stores approve things in. Keep BOTH in lockstep with the generator's
    /// dual-publish block (soyboi.tech/tools/build_alpr_dataset.py).
    private let manifestURL = URL(string: "https://soyboi.tech/data/alpr-v3-latest.json")!
    /// Show the community-mapped nodes nobody could name a manufacturer for. DEFAULT OFF.
    ///
    /// These are the pins that get the APP blamed. A node with no manufacturer recorded is
    /// disproportionately a solar panel on a pole that someone marked in passing, and when a user
    /// drives to one and finds nothing there, they conclude the detector is broken , not that an
    /// OSM contributor guessed. That happened to a reporter evaluating the product.
    /// 8.1% of nodes across five metros, and 22% in Chicago, so this is not a rounding error.
    ///
    /// They are still DOWNLOADED and still counted in the manifest. Hiding them is a display
    /// decision; deleting them would make the data-quality problem invisible rather than absent.
    @Published private(set) var showUnverified: Bool
    private let showUnverifiedKey = "acab.alpr.showUnverified"
    /// How many of `nodes` are tier-0. Stored, not computed: the settings caption reads it on every
    /// redraw and the array is six figures long. Only ever assigned alongside `nodeConfirmed`.
    @Published private(set) var unverifiedCount = 0

    private let enabledKey = "acab.alpr.enabled"
    private let versionKey = "acab.alpr.version"      // last-downloaded dataset `updated`
    private let lastCheckedKey = "acab.alpr.lastChecked"   // epoch seconds of the last completed manifest check
    private var inFlight = false

    /// Bumped on every enable/disable. fetch() snapshots it and abandons itself if it changed,
    /// so a download started before an opt-out can't publish or cache after one.
    private var enableGen = 0

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alpr.bin")
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        showUnverified = UserDefaults.standard.bool(forKey: showUnverifiedKey)   // default false
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
        // Retire any fetch already in the air. Clearing the arrays below does NOT stop a download
        // that is mid-flight, and its publish step would repopulate them seconds after the user
        // switched the layer off - the toggle would visibly undo itself. See fetch()'s gen checks.
        enableGen &+= 1
        if on {
            loadFromDisk()
            refresh()
        } else {
            nodes = []
            nodeMakers = []
            nodeConfirmed = []
            unverifiedCount = 0
        }
    }

    /// Toggle the unverified tier on the map. No refetch , the nodes are already loaded, this only
    /// changes what `nodes(in:)` hands back, so the map redraws immediately.
    func setShowUnverified(_ on: Bool) {
        guard on != showUnverified else { return }
        showUnverified = on
        UserDefaults.standard.set(on, forKey: showUnverifiedKey)
    }

    // MARK: viewport query

    /// The camera points inside `region`, capped so a zoomed-out view never tries to draw the
    /// whole set. Returns [] past the cap (caller shows a "zoom in" hint instead).
    func nodes(in region: MKCoordinateRegion, cap: Int = 500) -> [(coord: CLLocationCoordinate2D, maker: String, confirmed: Bool)] {
        guard !nodes.isEmpty else { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        var out: [(coord: CLLocationCoordinate2D, maker: String, confirmed: Bool)] = []
        out.reserveCapacity(min(cap, 64))
        for i in nodes.indices {
            let c = nodes[i]
            if c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon {
                let ok = i < nodeConfirmed.count ? nodeConfirmed[i] : true
                if !ok && !showUnverified { continue }   // hidden by default, see showUnverified
                out.append((c, i < nodeMakers.count ? nodeMakers[i] : "", ok))
                if out.count > cap { return [] }     // too many in view: signal "zoom in"
            }
        }
        return out
    }

    /// Nearest mapped camera to `coord`, for the detection detail's "matches a mapped camera" line.
    /// A ~2km bounding-box prefilter keeps this cheap over the full ~127k set (a real match is <200m,
    /// so nothing useful is ever outside the box); returns nil when the box is empty. Equirectangular
    /// distance is accurate to well under 1% at these ranges. On-device only - no query leaves the phone.
    func nearest(to coord: CLLocationCoordinate2D) -> (meters: Double, maker: String, confirmed: Bool)? {
        guard !nodes.isEmpty else { return nil }
        let box = 0.02                                   // ~2.2 km half-window
        let cosLat = cos(coord.latitude * .pi / 180)
        var bestM = Double.greatestFiniteMagnitude
        var bestMaker = ""
        var bestConfirmed = true
        for i in nodes.indices {
            let c = nodes[i]
            if abs(c.latitude - coord.latitude) > box || abs(c.longitude - coord.longitude) > box { continue }
            // Never corroborate a detection against a node the user cannot see on the map. Vouching
            // for a hit using evidence we have decided is untrustworthy is worse than staying quiet.
            if !showUnverified, i < nodeConfirmed.count, !nodeConfirmed[i] { continue }
            let dLat = (c.latitude - coord.latitude) * 111_320
            let dLon = (c.longitude - coord.longitude) * 111_320 * cosLat
            let m = (dLat * dLat + dLon * dLon).squareRoot()
            if m < bestM {
                bestM = m
                bestMaker = i < nodeMakers.count ? nodeMakers[i] : ""
                bestConfirmed = i < nodeConfirmed.count ? nodeConfirmed[i] : true
            }
        }
        return bestM.isFinite ? (bestM, bestMaker, bestConfirmed) : nil
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
        // Every await below is a window in which the user can switch the layer off. Snapshot the
        // enable generation now and re-check it after each one: a stale fetch must not spend the
        // bandwidth, publish the points, or leave a cache file behind after an opt-out.
        let gen = enableGen
        // 1) manifest
        var req = URLRequest(url: manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (mData, mResp) = try? await URLSession.shared.data(for: req),
              let http = mResp as? HTTPURLResponse else { return }
        if http.statusCode == 404 { outcome = .notPublished; return }
        guard (200..<300).contains(http.statusCode),
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
        // Layer switched off while the manifest was in the air: stop before the expensive part.
        guard gen == enableGen, enabled else { return }
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
        // 4) parse + publish + cache. Last chance to catch an opt-out: publishing here is what
        // would repopulate a map the user just cleared, and the cache write would put the dataset
        // on disk after they declined it.
        guard gen == enableGen, enabled else { return }
        guard let parsed = Self.parse(bin) else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        nodeConfirmed = parsed.confirmed
        unverifiedCount = parsed.confirmed.reduce(0) { $0 + ($1 ? 0 : 1) }
        updated = manifest.updated
        outcome = .updated(count: parsed.coords.count)
        UserDefaults.standard.set(manifest.updated, forKey: versionKey)
        try? bin.write(to: cacheURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let bin = try? Data(contentsOf: cacheURL), let parsed = Self.parse(bin) else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        nodeConfirmed = parsed.confirmed
        unverifiedCount = parsed.confirmed.reduce(0) { $0 + ($1 ? 0 : 1) }
        // The cache IS the version `versionKey` recorded, so a cold start can caption its
        // dataset date before (or without) the next successful manifest round-trip.
        if updated == nil { updated = UserDefaults.standard.string(forKey: versionKey) }
    }

    /// Parse the "ALP3" binary into coordinates + parallel maker and confidence arrays. Also
    /// accepts a legacy "ALP2" (coords + makers) and "ALP1" (coords only), so a cache written by an
    /// older build still loads. Bounds-checked throughout; returns nil on any malformation (a bad
    /// length, a table that runs past the buffer). A maker index past the table is NOT a rejection:
    /// it resolves to "" for that one node, same as Android, because a single unreadable label is a
    /// display fault and blanking a whole city's map over it is not. Out-of-range coords are
    /// dropped WITH their maker and tier, so all three arrays stay in lockstep.
    ///
    /// A pre-ALP3 file defaults every node to CONFIRMED, never unverified. The tier is an
    /// accusation ("nobody picked this manufacturer from a preset, so it may be misidentified"),
    /// and a cache predating the field carries no evidence either way. Defaulting the other way
    /// would paint a whole stale map amber purely because the file is old.
    ///
    /// Internal rather than private so BeaconsTests can drive it directly (@testable raises
    /// internal to public, it does not reach private). This is the one function in the app with a
    /// history of shipping a schema mismatch to BOTH platforms at once, so it is worth the keyword.
    static func parse(_ data: Data) -> (coords: [CLLocationCoordinate2D], makers: [String], confirmed: [Bool])? {
        let isV3 = data.count >= 4 && data.prefix(4).elementsEqual("ALP3".utf8)
        let isV2 = data.count >= 4 && data.prefix(4).elementsEqual("ALP2".utf8)
        let isV1 = data.count >= 4 && data.prefix(4).elementsEqual("ALP1".utf8)
        let hasMakers = isV2 || isV3
        guard data.count >= 12, isV1 || hasMakers else { return nil }
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
        if hasMakers {
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
        // coords, then (v2/v3) the parallel maker-index array, then (v3 only) the parallel tier array
        let coordsBytes = count * 8
        let idxBytes = hasMakers ? count : 0
        let tierBytes = isV3 ? count : 0
        guard data.count == off + coordsBytes + idxBytes + tierBytes else { return nil }
        let idxBase = off + coordsBytes
        let tierBase = idxBase + idxBytes

        var coords: [CLLocationCoordinate2D] = []; coords.reserveCapacity(count)
        var makers: [String] = []; makers.reserveCapacity(count)
        var confirmed: [Bool] = []; confirmed.reserveCapacity(count)
        for k in 0..<count {
            let o = off + k * 8
            let c = CLLocationCoordinate2D(latitude: Double(i32(o)) / 1e7, longitude: Double(i32(o + 4)) / 1e7)
            guard CLLocationCoordinate2DIsValid(c) else { continue }  // drop corrupt coords, and their maker + tier
            coords.append(c)
            if hasMakers {
                let mi = u8(idxBase + k)
                makers.append(mi < table.count ? table[mi] : "")
            } else {
                makers.append("")
            }
            confirmed.append(isV3 ? u8(tierBase + k) == 1 : true)     // pre-v3: no evidence, so no accusation
        }
        return (coords, makers, confirmed)
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
