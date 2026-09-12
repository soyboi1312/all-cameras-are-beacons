import SwiftUI
import MapKit
import os

/// One-shot handoff from a detection dossier's location thumbnail to the full map tab.
/// The tap stashes the coordinate here and posts the notification; MainTabView switches
/// tabs on it and MapTabView consumes the slot exactly once (onAppear when the tab was
/// cold, the notification when it is already alive). A static slot rather than the
/// UserDefaults channel the Live Activity deep link uses: this handoff never outlives
/// the session, and a stale persisted coordinate must not hijack a later launch's
/// first map open.
enum MapFocus {
    static var pending: CLLocationCoordinate2D?
    static let notification = Notification.Name("acabFocusMap")
}

/// Resolve the coordinate a detection surface should present. Remote ID owns a drone's subject
/// coordinate, so a valid aircraft fix always wins and the observer fix is only its no-position
/// fallback. Every other wire coordinate is the detector/phone fix, not the subject's position;
/// the manager's strongest-observer sample is the better estimate and therefore wins when present.
/// Kept outside the view so the full map and Log dossier cannot drift apart on this distinction.
///
/// `allowNonDroneWireFallback` gates ONLY that last fallback. TWIN: android
/// `mapCoordinateForDetection` in AcabBleManager.kt, same parameter and same default, with
/// `mapWireFallbackAllowed` standing in for the call-site expression below - one rule, one owner.
/// Every surface that presents this as "where this was heard" passes the gate, because the
/// shipped q-pin FAQ (byte-identical on both platforms) reserves the last-shared-fix fallback for
/// offline records, and a live board keeps stamping its last phone fix at ANY age. The default
/// stays `true` because the ordinary Log export must keep carrying the coordinate either way -
/// see `allowDetectionCoordinateFallback` in BLEManager.swift.
func resolvedDetectionMapCoordinate(type: DeviceType,
                                    wireCoordinate: CLLocationCoordinate2D?,
                                    strongestObserverCoordinate: CLLocationCoordinate2D?,
                                    allowNonDroneWireFallback: Bool = true)
    -> CLLocationCoordinate2D? {
    if type == .drone { return wireCoordinate ?? strongestObserverCoordinate }
    return strongestObserverCoordinate ?? (allowNonDroneWireFallback ? wireCoordinate : nil)
}

/// Region for the Log dossier's tracker thumbnail. Longitude uses the complement of the largest
/// gap on the globe, so a trail from +179° to -179° fits a narrow antimeridian window instead of
/// asking MapKit for a nearly world-wide span. Latitude and both spans are kept inside MapKit's
/// valid world bounds; a lone pin retains the existing neighborhood-scale view.
///
/// SHARED WITH ANDROID - the 1.35 pad and the 0.008 floor ARE the same numbers, applied in this
/// same order (pad first, then floor): DETAIL_MAP_FIT_SCALE and DETAIL_MAP_MIN_SPAN_DEG feeding
/// `detailBreadcrumbBounds` in DetailScreen.kt. 0.008 deg of latitude is about 890 m, and it is
/// the fixed span THIS thumbnail used before either side gained a fit: it is there so a lone pin,
/// or a trail shorter than the 25 m crumb gate, still shows the neighbourhood around the sighting.
///
/// The `usableTrail.count >= 2` gate below is shared too: a trail of one valid crumb draws no
/// polyline on either platform (this thumbnail and Android's both gate the line at two points),
/// so neither side widens the frame around it. `detailBreadcrumbBounds` applies the same gate
/// inside the function, so the two pure fit policies agree and not merely the two call sites.
///
/// Two platform-derived differences are left, both from the renderer rather than the policy:
/// osmdroid's extra 24 px fit border, which MKCoordinateRegion needs no equivalent for, and the
/// latitude ceiling - osmdroid is Web Mercator and clamps to DETAIL_MAP_MAX_LAT, while this keeps
/// the region inside MapKit's own +/-90 world bounds.
func detectionDetailMapRegion(pin: CLLocationCoordinate2D,
                              trail: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    let usableTrail = trail.filter(CLLocationCoordinate2DIsValid)
    var latitudes = [pin.latitude]
    var longitudes = [pin.longitude]
    if usableTrail.count >= 2 {
        latitudes.append(contentsOf: usableTrail.map(\.latitude))
        longitudes.append(contentsOf: usableTrail.map(\.longitude))
    }

    let minLat = latitudes.min() ?? pin.latitude
    let maxLat = latitudes.max() ?? pin.latitude
    let latitudeDelta = min(180, max((maxLat - minLat) * 1.35, 0.008))
    let latitudeHalf = latitudeDelta / 2
    let rawLatitudeCenter = (minLat + maxLat) / 2
    let latitudeCenter = min(90 - latitudeHalf,
                             max(-90 + latitudeHalf, rawLatitudeCenter))

    // Normalize into one circular [0, 360) axis, remove its largest empty arc, and fit the
    // complement. With one point the sole wrap gap is 360°, leaving a zero-width covered arc.
    let sorted = longitudes.map { lon -> Double in
        let wrapped = lon.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }.sorted()
    var largestGap = -Double.infinity
    var arcStart = sorted.first ?? 0
    if !sorted.isEmpty {
        for i in sorted.indices {
            let next = i == sorted.index(before: sorted.endIndex)
                ? sorted[0] + 360 : sorted[i + 1]
            let gap = next - sorted[i]
            if gap > largestGap {
                largestGap = gap
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
    }
    let coveredLongitude = max(0, 360 - max(0, largestGap))
    let longitudeDelta = min(360, max(coveredLongitude * 1.35, 0.008))
    var longitudeCenter = (arcStart + coveredLongitude / 2)
        .truncatingRemainder(dividingBy: 360)
    if longitudeCenter > 180 { longitudeCenter -= 360 }

    return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: latitudeCenter, longitude: longitudeCenter),
        span: MKCoordinateSpan(latitudeDelta: latitudeDelta,
                               longitudeDelta: longitudeDelta))
}

/// How much retained evidence the full map projects. The Log remains the durable evidence surface;
/// this setting only controls map density. A short default keeps a long Desert-mode drive useful
/// instead of redrawing days of ambient radios every time a fresh frame arrives.
enum MapHistoryScope: String, CaseIterable, Identifiable {
    case recent
    case all

    /// SHARED WITH ANDROID - this one IS the same number: MAP_RECENT_WINDOW_MS in
    /// AcabBleManager.kt. Both suites pin the literal (900 here, 15 * 60_000L there) rather than
    /// the constant, because the map chip and docs/map-performance.md promise "15 minutes" in
    /// hardcoded copy that a constant edit would not touch.
    static let recentSeconds: TimeInterval = 15 * 60
    var id: String { rawValue }
    var label: String { self == .recent ? "Recent" : "All history" }
    var shortLabel: String { self == .recent ? "RECENT 15 MIN" : "ALL HISTORY" }
}

/// Recent is intentionally strict about evidence quality: an exact or reconstructed instant can
/// be compared with a 15-minute window; an unknown time or a bracket is available under All only.
/// Kept pure for cross-platform boundary tests and deterministic dense-map regression tests.
func mapHistoryScopeIncludes(lastSeen: Date?, basis: TimeBasis,
                             scope: MapHistoryScope, now: Date) -> Bool {
    guard scope == .recent else { return true }
    switch basis {
    case .exact, .reconstructed: break
    case .bracketed, .unknown: return false
    }
    guard let lastSeen else { return false }
    let age = now.timeIntervalSince(lastSeen)
    return age.isFinite && age >= 0 && age <= MapHistoryScope.recentSeconds
}

/// UI refresh ceiling for a detection-driven map update. Camera, filter, scope and focus changes
/// bypass this and rebuild immediately. The return values are policy, not measured frame rates.
func mapDetectionRefreshInterval(rowCount: Int) -> TimeInterval {
    switch rowCount {
    case 4_000...: return 1.0
    case 2_000...: return 0.75
    case 500...:   return 0.5
    default:       return 0.3
    }
}

/// Hard cap on infra ANNOTATIONS, newest-first so a fresh sighting always draws. Far zooms carry
/// less positional information, so spend fewer custom annotations there; the highest-value
/// sightings still sort to the front of the cut, so this only changes the budget.
///
/// Counted AFTER same-spot grouping, which is the number that matters here: the cap exists to
/// bound how many annotations MapKit is handed, and a whole standing position now costs one.
/// Infra is the set that can still be huge once the viewport cull has run, because a city-wide
/// zoom can legitimately hold the whole persisted store. (Drone rows skip the viewport cull, and
/// a group holding one sorts to the front of this cut - see the snapshot loop for why - as does a
/// trailed tracker's trail geometry, though that tracker's own pin is culled with the rest of the
/// clusterable mass. Neither escaping set is ever more than a handful of rows.)
///
/// TWIN: android MapProjection.kt `buildMapRenderPlan`, capped by MapScreen.kt's MAP_MARKER_CAP.
/// Both sides now cap AFTER grouping, so the cap POINT and the quantity counted agree; what
/// differs is the budget, and each side derives its own from its own renderer. iOS spends an
/// adaptive 80/120/180/300 by span because every custom MKAnnotationView carries its own layer
/// tree, and it caps infra alone - the clusterable mass is bounded separately by
/// buildMapClusters. Android holds a flat 600 osmdroid overlays across ALL buckets and absorbs
/// density into its grid CELL instead (`densityScale`), so it needs no span ladder. What the two
/// sides do share is the grouping rule itself (MapPinRules), not these numbers.
func mapInfrastructurePinCap(span: MKCoordinateSpan) -> Int {
    let width = max(span.latitudeDelta, span.longitudeDelta)
    if width >= 20 { return 80 }
    if width >= 5 { return 120 }
    if width >= 1 { return 180 }
    return 300
}

func mapTrailPointBudget(span: MKCoordinateSpan) -> Int {
    let width = max(span.latitudeDelta, span.longitudeDelta)
    if width >= 20 { return 12 }
    if width >= 5 { return 16 }
    if width >= 1 { return 24 }
    if width >= 0.2 { return 48 }
    return 120
}

func mapTotalOverlayVertexBudget(span: MKCoordinateSpan) -> Int {
    max(span.latitudeDelta, span.longitudeDelta) >= 1 ? 600 : 1_200
}

/// Evenly retain endpoints and interior samples. The manager already caps raw tracks; this second,
/// zoom-aware bound limits what MapKit tessellates while keeping the full session trail in memory.
func simplifiedMapPolyline(_ points: [CLLocationCoordinate2D], maxPoints: Int)
    -> [CLLocationCoordinate2D] {
    let usable = points.filter(CLLocationCoordinate2DIsValid)
    guard maxPoints >= 2, usable.count > maxPoints else { return usable }
    let last = usable.count - 1
    var out: [CLLocationCoordinate2D] = []
    out.reserveCapacity(maxPoints)
    var previous = -1
    for i in 0..<maxPoints {
        let index = Int((Double(i) * Double(last) / Double(maxPoints - 1)).rounded())
        if index != previous { out.append(usable[index]); previous = index }
    }
    return out
}

/// Bounding-box intersection is deliberately conservative: a line that merely passes through the
/// viewport survives, while a trail wholly elsewhere costs MapKit nothing. The normal map spans do
/// not cross the antimeridian; if one does, the longitude test keeps both wrapped halves.
func mapPolylineIntersectsViewport(_ points: [CLLocationCoordinate2D],
                                   region: MKCoordinateRegion) -> Bool {
    let usable = points.filter(CLLocationCoordinate2DIsValid)
    guard let first = usable.first else { return false }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for point in usable.dropFirst() {
        minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
        minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
    }
    let halfLat = region.span.latitudeDelta * 0.6
    let halfLon = region.span.longitudeDelta * 0.6
    let viewMinLat = region.center.latitude - halfLat
    let viewMaxLat = region.center.latitude + halfLat
    guard maxLat >= viewMinLat, minLat <= viewMaxLat else { return false }
    if region.span.longitudeDelta >= 300 { return true }
    // A raw box wider than half the globe is normally a short trail crossing the date line
    // (+179° to -179°). Treat it conservatively after the latitude check; the alternative is
    // dropping a line that is visibly inside a narrow wrapped viewport.
    if maxLon - minLon > 180 { return true }
    let viewMinLon = region.center.longitude - halfLon
    let viewMaxLon = region.center.longitude + halfLon
    if viewMinLon >= -180, viewMaxLon <= 180 {
        return maxLon >= viewMinLon && minLon <= viewMaxLon
    }
    let wrappedMin = viewMinLon < -180 ? viewMinLon + 360 : viewMinLon
    let wrappedMax = viewMaxLon > 180 ? viewMaxLon - 360 : viewMaxLon
    return maxLon >= wrappedMin || minLon <= wrappedMax
}

/// Smallest angular separation on the circular longitude axis. MapKit regions near ±180° wrap;
/// raw subtraction would call -179° two whole worlds away from a viewport centered at +179°.
func mapLongitudeDistanceDegrees(_ a: Double, _ b: Double) -> Double {
    guard a.isFinite, b.isFinite else { return .infinity }
    let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(raw, 360 - raw)
}

/// Quantized grid geometry prevents a tiny pinch delta from assigning every cluster a new identity.
/// The chosen cell is never smaller than the old span/14 rule, so it cannot increase marker count.
struct MapClusterGrid: Equatable {
    let cellDegrees: Double
    let level: Int

    static func forSpan(_ span: MKCoordinateSpan) -> MapClusterGrid {
        let raw = max(span.latitudeDelta, span.longitudeDelta) / 14
        guard raw.isFinite, raw > 0 else { return MapClusterGrid(cellDegrees: 1, level: 0) }
        let level = Int(ceil(log2(raw)))
        return MapClusterGrid(cellDegrees: pow(2, Double(level)), level: level)
    }
}

struct MapClusterSeed {
    let id: String
    let type: DeviceType
    let coordinate: CLLocationCoordinate2D
    let lastSeen: Date?
    let displayName: String
    let rssi: Int
}

struct MapProjectedCluster: Identifiable, Equatable {
    let id: String
    let coord: CLLocationCoordinate2D
    let memberIDs: [String]
    let memberCount: Int
    let singleType: DeviceType?
    /// The lone member's name as the bubble speaks it; nil for a clump. Carried so the render
    /// gate can see a rename without comparing the whole spoken label (see `rendersSame(as:)`).
    let singleDisplayName: String?
    let age: MapPinRules.Age
    let uniformType: DeviceType?
    let accessibilityLabel: String

    var singleID: String? { memberCount == 1 ? memberIDs.first : nil }
    var shortTag: String { memberCount == 1 ? (singleType?.shortTag ?? "") : "\(memberCount)" }

    /// Full value equality, label included: what a test asserts when it checks that two builds of
    /// the same seeds produced the same projection.
    static func == (a: MapProjectedCluster, b: MapProjectedCluster) -> Bool {
        a.id == b.id && a.coord.latitude == b.coord.latitude
            && a.coord.longitude == b.coord.longitude && a.memberIDs == b.memberIDs
            && a.memberCount == b.memberCount && a.singleType == b.singleType
            && a.singleDisplayName == b.singleDisplayName
            && a.age == b.age && a.uniformType == b.uniformType
            && a.accessibilityLabel == b.accessibilityLabel
    }

    /// Does this bubble DRAW the same thing, SPEAK the same name, and would a tap resolve the same
    /// rows? Everything the artwork reads (coord, count, singleType, uniformType, age tier), the
    /// lone member's spoken name (singleDisplayName, so a custom label reaches VoiceOver the way
    /// `InfraPin.rendersSame(as:)` already lets leadDisplayName through) and the whole tap payload
    /// (memberIDs) is compared. `accessibilityLabel` itself is NOT: for a lone member it also
    /// carries the live dBm reading, which moves on nearly every advert while nothing on the map
    /// does, and holding the annotation subtree for that was the entire cost the render gate
    /// exists to avoid. Losing or gaining a member changes `memberIDs`, so a held pass can never
    /// hide a sighting.
    func rendersSame(as other: MapProjectedCluster) -> Bool {
        id == other.id && coord.latitude == other.coord.latitude
            && coord.longitude == other.coord.longitude && memberIDs == other.memberIDs
            && memberCount == other.memberCount && singleType == other.singleType
            && singleDisplayName == other.singleDisplayName
            && age == other.age && uniformType == other.uniformType
    }
}

struct MapClusterBuildMetrics: Equatable {
    /// COUNTED, one increment per seed the insertion loop actually looks at - not `seeds.count`
    /// handed back under another name. The one-pass claim in `buildMapClusters` is the thing the
    /// dense tests assert, so the number has to come from the loop or those assertions cannot
    /// fail: a second walk over the seeds reports twice the input size and fails them.
    let inputVisits: Int
    let bucketCount: Int
    let mergedRows: Int
}

private struct MapClusterKey: Hashable, Comparable {
    let latitude: Int
    let longitude: Int
    let level: Int

    static func < (a: MapClusterKey, b: MapClusterKey) -> Bool {
        if a.level != b.level { return a.level < b.level }
        if a.latitude != b.latitude { return a.latitude < b.latitude }
        return a.longitude < b.longitude
    }

    var id: String { "cluster:\(level):\(latitude):\(longitude)" }
}

private struct MapClusterBucket {
    var latitudeSum = 0.0
    var longitudeSum = 0.0
    var memberIDs: [String] = []
    var first: MapClusterSeed?
    var uniformType: DeviceType?
    var typeCounts: [Int: Int] = [:]

    mutating func append(_ seed: MapClusterSeed) {
        latitudeSum += seed.coordinate.latitude
        longitudeSum += seed.coordinate.longitude
        memberIDs.append(seed.id)
        if first == nil { first = seed; uniformType = seed.type }
        else if uniformType != seed.type { uniformType = nil }
        typeCounts[seed.type.rawValue, default: 0] += 1
    }
}

/// One-pass dense-map grouping. Each seed is inserted once into a numeric bucket; coordinates,
/// category uniformity and accessibility counts accumulate during that insertion. Finalization is
/// per bucket rather than another pass over all members. Member IDs stay lightweight and resolve
/// to current Detection values only if the user taps that one bucket.
func buildMapClusters(_ seeds: [MapClusterSeed], span: MKCoordinateSpan, now: Date)
    -> ([MapProjectedCluster], MapClusterBuildMetrics) {
    guard !seeds.isEmpty else {
        return ([], MapClusterBuildMetrics(inputVisits: 0, bucketCount: 0, mergedRows: 0))
    }
    let grid = MapClusterGrid.forSpan(span)
    var buckets: [MapClusterKey: MapClusterBucket] = [:]
    buckets.reserveCapacity(min(seeds.count, 324))
    var inputVisits = 0
    for seed in seeds {
        inputVisits += 1
        let lat = (seed.coordinate.latitude / grid.cellDegrees).rounded(.down)
        let lon = (seed.coordinate.longitude / grid.cellDegrees).rounded(.down)
        guard lat.isFinite, lon.isFinite,
              let latKey = Int(exactly: lat), let lonKey = Int(exactly: lon) else { continue }
        let key = MapClusterKey(latitude: latKey, longitude: lonKey, level: grid.level)
        buckets[key, default: MapClusterBucket()].append(seed)
    }
    let clusters = buckets.keys.sorted().compactMap { key -> MapProjectedCluster? in
        guard let bucket = buckets[key], let first = bucket.first else { return nil }
        let count = bucket.memberIDs.count
        let coordinate = CLLocationCoordinate2D(
            latitude: bucket.latitudeSum / Double(count),
            longitude: bucket.longitudeSum / Double(count))
        let label: String
        if count == 1 {
            label = mapPinAccessibilityLabel(type: first.type, displayName: first.displayName,
                                             rssi: first.rssi,
                                             age: MapPinRules.age(lastSeen: first.lastSeen, now: now))
        } else {
            let parts = bucket.typeCounts.keys.sorted().compactMap { raw -> String? in
                guard let type = DeviceType(rawValue: raw), let n = bucket.typeCounts[raw] else { return nil }
                let spoken = mapSpokenType(type)
                return n == 1 ? "one \(spoken)" : "\(n) detections of type \(spoken)"
            }
            label = "\(count) detections in this area: \(parts.joined(separator: ", "))"
        }
        return MapProjectedCluster(
            id: key.id, coord: coordinate, memberIDs: bucket.memberIDs, memberCount: count,
            singleType: count == 1 ? first.type : nil,
            singleDisplayName: count == 1 ? first.displayName : nil,
            age: count == 1 ? MapPinRules.age(lastSeen: first.lastSeen, now: now) : .recent,
            uniformType: bucket.uniformType, accessibilityLabel: label)
    }
    return (clusters, MapClusterBuildMetrics(
        inputVisits: inputVisits, bucketCount: clusters.count,
        mergedRows: max(0, seeds.count - clusters.count)))
}

private func mapSpokenType(_ type: DeviceType) -> String {
    switch type {
    case .flockCamera:      return "automatic license plate reader camera"
    case .flockRaven:       return "Flock Raven audio sensor"
    case .axonBodyCam:      return "body camera"
    case .drone:            return "drone with remote identification"
    case .tracker:          return "item tracker"
    case .nearbyDevice:     return "nearby device"
    case .watched:          return "watched device"
    case .recordingGlasses: return "recording glasses"
    case .networkCamera:    return "network camera"
    case .unknown:          return "unknown device"
    }
}

private func mapPinAccessibilityLabel(type: DeviceType, displayName: String, rssi: Int,
                                      age: MapPinRules.Age) -> String {
    let spoken = mapSpokenType(type)
    let name = displayName == type.label ? spoken : "\(displayName), \(spoken)"
    let stale = age == .stale ? " Not heard in the last hour." : ""
    return "\(name). Signal strength \(rssi) decibels relative to one milliwatt.\(stale)"
}

/// Prevent broad ObservableObject changes above the map from re-evaluating hundreds of MapKit
/// annotations when the cached render projection did not change.
private struct MapRenderGate<Content: View>: View, Equatable {
    let revision: UInt64
    let content: () -> Content

    init(revision: UInt64, @ViewBuilder content: @escaping () -> Content) {
        self.revision = revision
        self.content = content
    }

    static func == (a: MapRenderGate<Content>, b: MapRenderGate<Content>) -> Bool {
        a.revision == b.revision
    }

    var body: some View { content() }
}

/// Instruments-only timing for the two map stages. INTERVALS ship; their count ARGUMENTS are
/// DEBUG-only, because os_signpost arguments land in the OS unified log, which this app cannot
/// clear (see the note at the MapProjection `.end` call). Nothing here ever carries a coordinate,
/// a MAC or a name.
private let mapPerformanceLog = OSLog(subsystem: "com.soyboi.Beacons", category: "MapPerformance")
/// Visible-map maintenance only: expires the 15-minute lens and advances age styling while a
/// disconnected/quiet scanner emits no detections. It is intentionally slow; live arrivals use
/// the adaptive leading/trailing refresh path instead.
private let mapMaintenanceTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

/// Located detections on a dark map, filterable by category. Fixed installs
/// (Flock/body-cam/tracker) sit at our position when we heard them; drones plot
/// their own broadcast position plus the operator's.
struct MapTabView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var alpr: ALPRStore        // known-ALPR reference layer (on by default, OSM/DeFlock)
    @State private var filter: String?           // category key: ALPR / DRONE / BODY CAM / TRACKER
    // NEVER fall back to .automatic: it re-frames the camera to fit the CONTENT, and the ALPR dots are
    // themselves computed FROM the camera region (onMapCameraChange -> refreshALPRVisible -> alprVisible
    // -> Annotations -> content changed -> .automatic re-frames -> camera changed -> ...). That closes an
    // unbounded render loop that pegs the main thread (a cpu_resource spin, not a crash). A fixed fallback
    // region breaks the content->camera edge; the recenter button below drives the camera explicitly.
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MapTabView.fallbackRegion))
    static let fallbackRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611),   // San Diego
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
    @State private var selected: Detection?
    @State private var cluster: Cluster?         // tapped multi-member bubble (drives the picker sheet)
    @State private var showALPRInfo = false      // tapped a known-ALPR dot: show the shared credit callout (one overlay, never a per-dot popover)
    @State private var tappedALPRMaker = ""      // the maker of the last-tapped dot ("" = unknown), shown in that callout
    @State private var tappedALPRTier: UInt8 = 1  // raw ALP tier; drives the callout's wording + tone
    @State private var tappedALPRPeek = false    // was that dot's ring peeking? the callout must not deny a live hit
    @State private var span: MKCoordinateSpan = .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
    @State private var region = MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                                   span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
    @State private var emptyDismissed = false
    @State private var legendExpanded = false     // F18: legend rests as a small info chip
    @State private var showMapOptions = false     // one readable sheet for scope, display and layers
    // One-shot camera fit to the located detections' bounding region (see fitToDetections).
    // Also set when a dossier handoff places the camera, so the fit never yanks it away.
    @State private var didFitToDetections = false
    @AppStorage("map.showBreadcrumbs") private var showBreadcrumbs = true    // tracker trails on the map (persisted)
    @AppStorage("map.showLabels") private var showLabels = false             // pin captions, off for a cleaner map (persisted)
    @AppStorage("map.historyScope") private var historyScopeRaw = MapHistoryScope.recent.rawValue
    @State private var alprChecking = false       // manual "check for updates" in flight (double-tap guard)
    @State private var alprJustChecked = false    // brief window after a manual check: row shows the outcome
    @Environment(\.horizontalSizeClass) private var hSize   // T5: dossier as inspector on regular width

    /// The expensive map projection is state, not a body-local computed value. BLEManager remains
    /// an ObservableObject used by the surrounding chrome, but unrelated publishes cannot force a
    /// store walk or MapKit content rebuild. Detection-driven refreshes are coalesced below.
    @State private var snapshot: MapSnapshot = .empty
    @State private var mapRenderRevision: UInt64 = 0
    @State private var isMapVisible = false
    @State private var suppressNextScopeRefit = false

    private final class SnapshotRefreshState {
        var lastStamp: TimeInterval = -.greatestFiniteMagnitude
        var pending: DispatchWorkItem?
    }
    @State private var snapshotRefreshState = SnapshotRefreshState()

    private var historyScope: MapHistoryScope {
        MapHistoryScope(rawValue: historyScopeRaw) ?? .recent
    }

    private var historyScopeBinding: Binding<MapHistoryScope> {
        Binding(get: { historyScope }, set: { historyScopeRaw = $0.rawValue })
    }

    private func bumpMapRenderRevision() { mapRenderRevision &+= 1 }

    /// Known ALPR camera points to draw right now: only when the layer is on and the map is
    /// zoomed in enough to be useful, culled to the viewport and capped for performance.
    /// Held in @State (not recomputed in body): body can still re-evaluate off broad manager
    /// publishes, while the underlying query now searches a latitude-sorted spatial index. We
    /// refresh only where its inputs actually change (camera move, layer toggle, dataset load),
    /// so even that bounded query never becomes detection-publish work.
    @State private var alprVisible: [ALPRPoint] = []

    /// Recompute the viewport-culled ALPR points. Called on the events that change its inputs,
    /// never in body. Clears out when the layer is off or the map is zoomed too far out.
    private func refreshALPRVisible(region requestedRegion: MKCoordinateRegion? = nil) {
        // HYSTERESIS, not a single cliff. A lone 0.35 threshold can flip-flop across the boundary
        // (dots appear -> content grows -> zoom crosses back -> dots vanish -> ...), re-invalidating
        // body forever. Separate on/off thresholds make that physically impossible.
        let activeRegion = requestedRegion ?? region
        let limit = alprVisible.isEmpty ? 0.30 : 0.40
        guard alpr.enabled, activeRegion.span.latitudeDelta < limit else {
            if !alprVisible.isEmpty {
                alprVisible = []
                bumpMapRenderRevision()
            }
            return
        }
        // Interval always, counts only in DEBUG: `visible` is a viewport-derived number and the
        // unified log is not a store this app can clear. See the note on the MapProjection
        // signpost in makeSnapshot.
        let signpostID = OSSignpostID(log: mapPerformanceLog)
        #if DEBUG
        os_signpost(.begin, log: mapPerformanceLog, name: "MapALPRQuery",
                    signpostID: signpostID, "nodes=%{public}d", alpr.nodes.count)
        #else
        os_signpost(.begin, log: mapPerformanceLog, name: "MapALPRQuery", signpostID: signpostID)
        #endif
        let visibleNodes = alpr.nodes(in: activeRegion, cap: 500)
        #if DEBUG
        os_signpost(.end, log: mapPerformanceLog, name: "MapALPRQuery",
                    signpostID: signpostID, "visible=%{public}d", visibleNodes.count)
        #else
        os_signpost(.end, log: mapPerformanceLog, name: "MapALPRQuery", signpostID: signpostID)
        #endif
        var next = visibleNodes.map {
            ALPRPoint(id: $0.id, coord: $0.coord, maker: $0.maker, tier: $0.tier)
        }
        applyPeek(&next)   // stamp "a live pin is standing on this camera" HERE, in the cull pass
        // ALPRPoint is Equatable: an unchanged viewport costs zero @State writes / zero invalidations.
        if next != alprVisible {
            alprVisible = next
            bumpMapRenderRevision()
        }
    }

    /// Rendered pin coordinates carried over from the last body pass, plus the throttle state for
    /// re-stamping the ring-peek flags. A REFERENCE box held in @State, with no @State of its own:
    /// it is written from the map's pin-set change handler, which runs at pin-arrival cadence, and
    /// a @State write there would invalidate body (and so re-run makeSnapshot) for nothing.
    private final class PeekState {
        /// The pins the map actually drew last pass, from MapSnapshot.pins - so the peek match
        /// reads the SAME store pass that fed the map instead of taking a second one of its own.
        var pins: [CLLocationCoordinate2D] = []
        /// MONOTONIC uptime, not a Date: a wall-clock stamp goes backwards whenever the phone's
        /// clock is corrected or crosses a DST boundary, and the throttle would then compute an
        /// enormous wait and park the trailing run for hours - a permanently missed update.
        var lastStamp: TimeInterval = -.greatestFiniteMagnitude
        var pending: DispatchWorkItem?
    }
    @State private var peekState = PeekState()

    /// Minimum spacing between two ring-peek stamps. THROTTLED, not debounced: the first change in
    /// a quiet period stamps immediately, and a burst behind it collapses into ONE trailing run at
    /// the end of the window. A debounce would starve here - detections publish at roughly 3 Hz on
    /// a busy drive and every arrival moves the pin set, so its timer would be cancelled forever
    /// and the ring would never light up, which is the whole feature failing silently.
    private static let peekThrottle: TimeInterval = 0.5

    /// Re-stamp the ring-peek flags now, without re-culling. NO store pass: the rings are the
    /// already-culled, already-capped alprVisible, and the pins came from the body pass that drew
    /// them. Free while the layer is drawing no rings (switched off, or zoomed out past the
    /// threshold), which is also why the throttle clock only advances when there was work to do.
    private func stampPeek() {
        peekState.pending?.cancel()
        peekState.pending = nil
        guard !alprVisible.isEmpty else { return }
        peekState.lastStamp = ProcessInfo.processInfo.systemUptime
        var next = alprVisible
        applyPeek(&next)
        if next != alprVisible {
            alprVisible = next
            bumpMapRenderRevision()
        }
    }

    /// Coalesced entry point for "the drawn pins changed, re-match the rings". The leading edge
    /// runs immediately, so a filter tap or a lone new sighting lights its ring at once; anything
    /// inside the throttle window queues exactly one trailing run, so a stream of arriving
    /// detections can never become a stream of match passes - and, because that run is QUEUED
    /// rather than dropped, never a permanently missed update either.
    private func schedulePeekStamp() {
        guard !alprVisible.isEmpty else { return }   // no rings drawn: nothing to stamp
        let wait = Self.peekThrottle - (ProcessInfo.processInfo.systemUptime - peekState.lastStamp)
        guard wait > 0 else { stampPeek(); return }
        guard peekState.pending == nil else { return }   // a trailing run is already queued
        let work = DispatchWorkItem { stampPeek() }
        peekState.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Mark every ring one of the last-drawn pins is standing on. One banded proximity sweep over
    /// the culled, capped ring set, and no store pass of its own (see PeekState.pins).
    private func applyPeek(_ points: inout [ALPRPoint]) {
        guard !points.isEmpty else { return }
        let flags = ALPRRingPeek.matches(rings: points.map(\.coord), pins: peekState.pins)
        for i in points.indices { points[i].peek = flags[i] }
    }

    /// A one-line hint when the ALPR layer is on but drawing nothing, so "off" is never confused
    /// with "failed to load" or "zoomed out too far". Keyed to the ACTUAL draw state plus the
    /// hysteresis "appear" threshold (0.30) rather than a third cutoff: a lone 0.35 here both
    /// showed the hint while dots were still drawn ([0.35, 0.40)) and went silent in the dead
    /// band where nothing drew yet ([0.30, 0.35)).
    private var alprHint: String? {
        guard alpr.enabled, !alpr.loading else { return nil }
        if alpr.nodes.isEmpty {
            // A 404 is not a connectivity problem and must not be reported as one: this build
            // polls its own manifest, so there is a legitimate window before the dataset is
            // published where the file simply is not there yet.
            if alpr.lastOutcome == .notPublished {
                return "camera data not published yet \u{00B7} try again later"
            }
            return "couldn't load camera data \u{00B7} check your connection"
        }
        if alprVisible.isEmpty && span.latitudeDelta >= 0.30 { return "zoom in to see mapped cameras" }
        return nil
    }

    /// Where the pin goes: a drone's own broadcast coordinate if it has one, else the phone's
    /// position at our strongest located sighting. For every non-drone, prefer that strongest
    /// observer sample over the latest detector coordinate carried by the wire row, and accept
    /// that wire row as a LIVE pin only while the board's own fix is still current - a frozen
    /// coordinate is not a missing coordinate, it pins the rest of the drive on the driveway.
    /// Android's `mapCoord`/`mapEvidenceSnapshot` pass the same gate (`mapWireFallbackAllowed`).
    private func mapCoord(for d: Detection) -> CLLocationCoordinate2D? {
        resolvedDetectionMapCoordinate(type: d.type, wireCoordinate: d.coordinate,
                                       strongestObserverCoordinate: ble.capturedLocation(for: d.id),
                                       allowNonDroneWireFallback: d.isHistory || ble.demoMode
                                           || liveWireObserverFixIsCurrent(gpsAgeSec: d.gpsAgeSec))
    }

    /// Nearby devices, item trackers, and the rotating-MAC accumulators (recording glasses,
    /// network cameras, which can mint hundreds of same-spot rows over days) accumulate into
    /// count bubbles. Surveillance infrastructure (Flock ALPR, Raven, drone, body cam, watched) is
    /// NEVER absorbed into a bubble: whenever it draws, at any span, it draws as its own marker,
    /// so a camera is never lost inside a clump. (What CAN withhold one is the annotation budget -
    /// see mapInfrastructurePinCap - and that omits the marker rather than hiding it in a count.
    /// A tracker later flagged as "following" will promote back to an individual marker.)
    ///
    /// TWIN: android MapScreen.kt `clusterable`, which holds the same type set. The gate AROUND
    /// it is not shared, and that is deliberate on both sides: Android's buildMapRenderPlan also
    /// folds every non-RID row into its adaptive grid below MAP_FAR_ZOOM, so a far-zoom Flock pin
    /// there becomes a member of a count bubble. iOS instead keeps the individual artwork and
    /// narrows mapInfrastructurePinCap, so a far-zoom pin iOS cannot afford is cut rather than
    /// clumped. Either way the rows stay reachable - Android through the bubble's member sheet,
    /// iOS through the Log.
    private func clusterable(_ d: Detection) -> Bool {
        d.type == .nearbyDevice || d.type == .tracker
            || d.type == .recordingGlasses || d.type == .networkCamera
    }

    /// Above this many visible pins the per-pin repeatForever ping animation is dropped:
    /// hundreds of independent Core Animation loops with shadows peg older devices on
    /// their own, cull or no cull.
    private static let animatedPinCap = 40
    private static let overlayRowCap = 64

    /// One store row inside a same-spot bucket, with its `lastSeen` stamp resolved once during
    /// the store walk. A named type rather than a tuple so `InfraPin` can hold the bucket exactly
    /// as it was filled, with no repacking.
    ///
    /// Membership identity for the render gate is `id` plus `type` (MapPinRules.sameMembers):
    /// WHICH sighting this is and what it counts as. `seen` and `rssi` are deliberately left out
    /// of it - see `InfraPin.rendersSame(as:)`. `type` is in because it decides both the lead and
    /// the member sheet's order (MapPinRules).
    private struct SpotRow {
        let id: String
        let type: DeviceType
        let seen: Date?
        let displayName: String
        let rssi: Int
    }

    /// ONE rendered infrastructure annotation, which may stand for several sightings.
    ///
    /// Every detection heard from one standing position is stamped with the SAME phone
    /// coordinate, so infra pins land exactly on top of each other: only the topmost was
    /// tappable, nothing said how many were under it, and because the row list is newest-first
    /// the OLDEST sighting drew last and took every tap. So the snapshot groups them and picks
    /// which one draws (see MapPinRules).
    ///
    /// DRONE ROWS ARE IN HERE TOO. A drone used to draw its own pin from a separate set, laid
    /// down BEFORE these, so an infra pin sharing its coordinate covered it and the drone took
    /// no taps at all - with no badge sheet to reach it by, because it was never in a group.
    /// Its overlays (flight path, operator tether, launch glyph, operator marker) do not hang
    /// off this pin: they are emitted by their own pass over every located drone row, whether or
    /// not that row led its group, so folding the pin in loses none of them.
    ///
    /// `lead` is the pin that draws, chosen in one allocation-free scan. `group` is the bucket
    /// the store walk filled, kept UNORDERED: putting it in draw order belongs to the tap, not
    /// to the snapshot pass, so it happens in `orderedMemberIDs(lastSeen:)`, which says why.
    private struct InfraPin: Identifiable {
        /// Stable across passes: the grid cell, not the lead's id. Keying on the lead would
        /// change identity the moment a more important sighting arrives, and MapKit pops an
        /// annotation whose identity changed.
        let id: String
        let coord: CLLocationCoordinate2D
        let leadID: String
        let leadType: DeviceType
        let leadDisplayName: String
        let leadRSSI: Int
        /// The whole bucket in store order (newest-first, as the feed hands it over), held by
        /// reference: the snapshot pass never copies it and never re-orders it.
        let group: [SpotRow]
        /// The LEAD's age tier. The badge count is a group size, never an age.
        let age: MapPinRules.Age
        /// The lead's raw stamp, kept only so the over-cap sort does not re-resolve it.
        let leadSeen: Date?
        /// At least one member is a drone. Set while the bucket is filled, so the over-cap sort
        /// never has to look inside a group. Its only job is to sort these pins to the FRONT of
        /// the cut: a drone row escapes the viewport cull (its overlays can cross the viewport
        /// while it sits outside), so dropping its pin would leave a flight path drawn under
        /// nothing. That is a ranking, not an exemption - past the cap's worth of drone-bearing
        /// spots the cut reaches them too, and nothing here pretends otherwise.
        let holdsDrone: Bool

        /// How many sightings this one pin stands for: the badge number, and what decides
        /// whether a tap opens a dossier or the member sheet.
        var count: Int { group.count }

        /// The group in draw order, lead first. Resolved ON DEMAND, at a tap and nowhere else.
        /// The snapshot runs at publish and camera-move cadence and this list is read at most
        /// once per tap, for the ONE pin the finger landed on; ordering every group in the
        /// snapshot instead ran a sort, and the arrays that sort builds, per pin per pass for a
        /// list almost nothing ever read. The order is `MapPinRules.ordered`, the rule `lead` is
        /// pinned against.
        ///
        /// The stamps come from `lastSeen`, read at the tap, and NOT from each member's `seen`.
        /// The render gate holds this pin through a pure re-ordering of its members
        /// (`rendersSame(as:)`), and a recency crossing between two members is exactly that, so
        /// the `seen` stamps a held pin carries can trail the feed for as long as the gate holds.
        /// Sorting on them froze the sheet's "then most recent" half at whatever the last pass
        /// the gate let through left on this pin, and nothing in the sheet would have shown it:
        /// ClusterListSheet draws one DetectionRow per member, and no row prints a last-seen
        /// age. The only age there is the LOC chip, a GPS-fix age off the row's own `gpsAgeSec`
        /// (Detection.locationAgeText), so the row order is the whole recency cue the sheet has.
        /// Read at the tap, a member heard since the snapshot takes its place in the current
        /// order; if that makes it the lead, it tops the sheet and the next snapshot redraws the
        /// pin as it, because `leadID` is in the render key.
        func orderedMemberIDs(lastSeen: (String) -> Date?) -> [String] {
            guard count > 1 else { return [leadID] }
            return MapPinRules.ordered(group, type: { $0.type }, lastSeen: { lastSeen($0.id) })
                .map(\.id)
        }

        /// Does this pin DRAW the same thing, and would a tap on it resolve the same rows?
        /// The render gate's whole job is to answer that, so this compares the pin's artwork
        /// (coord, lead type, badge count through `group`, age tier), its VoiceOver nouns
        /// (lead display name), and its tap payload (leadID plus every member's id and type).
        /// The members are compared as a SET (MapPinRules.sameMembers, which says why): the
        /// bucket is filled in feed order, the feed is re-sorted newest-first on every publish,
        /// so two members still being heard swap places whenever their stamps cross. Compared in
        /// order, that swap alone re-ran the annotation rebuild this gate exists to prevent, and
        /// nothing drawn reads the order.
        ///
        /// NOT compared: `leadRSSI`, `leadSeen`, and each member's `seen`/`rssi`. A live row
        /// re-adverts with a fresh stamp and a wobbling dBm reading and nothing on the map moves:
        /// no pin, no badge, no dimming. Keeping them here meant the gate reported a changed map
        /// on essentially every publish for any device still being heard, which is exactly the
        /// annotation rebuild it exists to prevent. The member `seen` stamps are not read at the
        /// tap either: `orderedMemberIDs(lastSeen:)` takes live ones, so the member sheet's order
        /// cannot lag a held pass. The one thing that can lag a held pass is the dBm number inside
        /// `infraAccessibilityLabel`; a gated subtree is not rebuilt, so moving that string into
        /// the view would not refresh it either. Age tier, membership, the lead, and every
        /// coordinate DO invalidate, so a held pass can never hide a sighting.
        func rendersSame(as other: InfraPin) -> Bool {
            id == other.id && coord.latitude == other.coord.latitude
                && coord.longitude == other.coord.longitude && leadID == other.leadID
                && leadType == other.leadType && leadDisplayName == other.leadDisplayName
                && age == other.age && holdsDrone == other.holdsDrone
                && MapPinRules.sameMembers(group, other.group, id: { $0.id }, type: { $0.type })
        }
    }

    private struct DroneOverlay: Identifiable {
        let detection: Detection
        let track: [CLLocationCoordinate2D]
        /// Where the no-fix RSSI ring is centred, resolved AT SNAPSHOT TIME: the phone's own
        /// position, and only for a drone that broadcast no position of its own. nil for every
        /// drone that did broadcast one, and for a no-fix drone heard while the phone had no fix
        /// either - no centre, no ring, which is exactly what drew before.
        ///
        /// It is a stored field rather than a live `ble.selfCoord` read inside `droneOverlay`
        /// because the gate withholds the whole MapKit subtree: a centre the draw reads live is a
        /// centre the render key cannot compare, so the ring went on sitting at a phone position
        /// the user had already left. A cache that outlives what it caches is the one failure this
        /// gate must not have.
        let selfCenter: CLLocationCoordinate2D?
        var id: String { detection.id }

        /// Only the geometry `droneOverlay` and the OP annotation actually draw. RSSI counts for
        /// exactly one shape: the no-fix ring, whose radius IS the signal reading (see
        /// `rssiRadiusMeters`), so it is compared only when the drone broadcast no position of
        /// its own. That same ring's CENTRE is `selfCenter`, compared unconditionally: it is nil
        /// whenever no ring draws, so an ordinary drone pays one nil-vs-nil test for it.
        /// Comparing the whole Detection instead put every drone's `rssi` and `count` into the
        /// render key, which no overlay reads. Android sizes the same ring with the same formula
        /// from the same raw reading but keeps the reading out of its key: MapOverlaySignature
        /// (MapScreen.kt) has no RSSI field at all, and the pass after that rebuild gate resizes
        /// the drawn ring's polygon in place (DrawnRing). So on both apps the no-fix ring's radius
        /// follows the latest reading; only iOS re-renders the gated map content to move it.
        func rendersSame(as other: DroneOverlay) -> Bool {
            guard detection.id == other.detection.id,
                  MapTabView.coordinatesEqual(detection.coordinate, other.detection.coordinate),
                  MapTabView.coordinatesEqual(detection.pilotCoordinate,
                                              other.detection.pilotCoordinate),
                  MapTabView.coordinatesEqual(selfCenter, other.selfCenter),
                  MapTabView.coordinatesEqual(track, other.track) else { return false }
            return detection.coordinate != nil || detection.rssi == other.detection.rssi
        }
    }

    private struct TrackerTrail: Identifiable, Equatable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]

        static func == (a: TrackerTrail, b: TrackerTrail) -> Bool {
            a.id == b.id && MapTabView.coordinatesEqual(a.coordinates, b.coordinates)
        }
    }

    private static func coordinatesEqual(_ a: [CLLocationCoordinate2D],
                                         _ b: [CLLocationCoordinate2D]) -> Bool {
        a.count == b.count && !zip(a, b).contains {
            $0.latitude != $1.latitude || $0.longitude != $1.longitude
        }
    }

    /// CLLocationCoordinate2D has no Equatable conformance, so an optional one cannot be compared
    /// with `==` either. Two absent coordinates are the same coordinate.
    private static func coordinatesEqual(_ a: CLLocationCoordinate2D?,
                                         _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return l.latitude == r.latitude && l.longitude == r.longitude
        default: return false
        }
    }

    /// Element-wise render comparison, short-circuiting on the first difference and on a length
    /// change. Used instead of `==` on the snapshot's pin arrays: what the gate needs to know is
    /// whether the map DRAWS the same thing, which is a narrower question than value equality
    /// (see `InfraPin.rendersSame(as:)`).
    private static func rendersSame<T>(_ a: [T], _ b: [T], by same: (T, T) -> Bool) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            if !same(a[i], b[i]) { return false }
        }
        return true
    }

    /// Everything one body eval needs from the store, computed in a SINGLE pass. located /
    /// totalLocated / count(cat) / the per-layer splits used to be independent computed
    /// properties, each an O(store) filter resolving mapCoord per row, and body read them
    /// ~17x per eval at the ~3 Hz publish cadence. Infra pins also get the viewport cull +
    /// cap the cluster path and ALPR layer already had.
    /// The coordinates of the pins a snapshot actually DRAWS, wrapped so `.onChange` can watch
    /// them: CLLocationCoordinate2D is not Equatable, and the map needs to know when the pin set
    /// moved rather than re-stamping the ring peek on every ~3 Hz publish. One array compare per
    /// body pass. Every coordinate in here is an infra pin or a lone-member bubble: infra is
    /// bounded by the viewport cull and the 300-pin cap (drone-bearing groups escape the cull and
    /// sort to the FRONT of the cut, which is a ranking and not an exemption - see holdsDrone -
    /// so past a cap's worth of them the cut reaches those too), and the bubbles by the cull.
    private struct PinSet: Equatable {
        struct Item: Equatable {
            let id: String
            let latitude: Double
            let longitude: Double
        }
        let items: [Item]
        var coords: [CLLocationCoordinate2D] {
            items.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    private struct MapSnapshot {
        let totalLocated: Int
        let retainedLocated: Int
        let representedRows: Int
        let markerCount: Int
        let mergedRows: Int
        /// Rows that passed the filter but sit OUTSIDE the current viewport. Counted apart from
        /// `droppedRows` because the two have nothing in common: this one is undone by panning,
        /// and it is normally the whole gap between `retainedLocated` and what the map draws.
        let viewportCulled: Int
        /// Rows a BUDGET withheld: on screen, past the marker cap, so not drawn at this zoom.
        /// The header names this separately from `viewportCulled` so aggregation and a cap are
        /// never reported as one number, and neither is ever mistaken for evidence deletion.
        let droppedRows: Int
        let counts: [String: Int]   // located per category, unfiltered (feeds the chips)
        /// Every LOCATED drone row that passed the filter, in store order and NOT viewport-culled.
        /// This is the overlay feed only - flight path, launch glyph, operator tether, operator
        /// marker - and it is deliberately independent of which row won its same-spot group. The
        /// drone's PIN comes out of `infra` like every other grouped row.
        let drones: [DroneOverlay]
        let infra: [InfraPin]       // same-spot grouped, capped newest-first; culled except for drone rows
        let clusters: [MapProjectedCluster]
        let trackerTrails: [TrackerTrail]
        let pinsAnimated: Bool      // ping rings only under animatedPinCap
        let simplifiedArtwork: Bool
        let pins: PinSet            // the drawn pins' coordinates; feeds the ring-peek match
        /// At least one drawn pin is in the STALE tier, so the legend explains the dim treatment.
        /// Gated for the same reason the ring-peek and lower-confidence rows are: a legend that
        /// names a treatment nothing on screen is using reads as a rendering bug.
        let hasStalePins: Bool
        /// The LENS this projection was taken through, carried so `mapAccessibilityLabel` can
        /// speak it. That label lives INSIDE the gated subtree, so any state it reads that the
        /// render key does not compare goes on being spoken after it stopped being true: switch
        /// the category chip while every scoped row already belongs to that one category and the
        /// pin set is byte-for-byte identical, the gate holds, and VoiceOver keeps naming the
        /// PREVIOUS filter. Same for the scope and for the location-permission story behind the
        /// empty map. All three are scalars, so the gate pays nothing for them, and the label
        /// reads them from HERE rather than from the view, which makes it structurally unable to
        /// describe a lens the pins it is attached to were not built through.
        let spokenFilter: String?               // active category chip, nil = all types
        let spokenScope: MapHistoryScope
        let spokenLocationDenied: Bool          // `ble.locationDenied && !ble.demoMode`

        static let empty = MapSnapshot(
            totalLocated: 0, retainedLocated: 0,
            representedRows: 0, markerCount: 0, mergedRows: 0, viewportCulled: 0, droppedRows: 0,
            counts: [:], drones: [], infra: [], clusters: [], trackerTrails: [],
            pinsAnimated: false, simplifiedArtwork: false, pins: PinSet(items: []),
            hasStalePins: false, spokenFilter: nil, spokenScope: .recent,
            spokenLocationDenied: false)

        /// Would the map content closure draw - and SAY - the same thing? This is the render
        /// gate's only question, and it is deliberately narrower than value equality: the
        /// per-element rules (`InfraPin.rendersSame(as:)`, `MapProjectedCluster.rendersSame(as:)`,
        /// `DroneOverlay.rendersSame(as:)`) leave out the signal reading and the last-heard stamp,
        /// which move on nearly every advert of any device still being heard and move nothing on
        /// screen. Every coordinate, every membership list, every age tier and both artwork modes
        /// ARE compared, so a pass held here can never drop a pin, a badge count or a sheet row.
        ///
        /// The three counts are here because `mapAccessibilityLabel` is inside the gated subtree
        /// and speaks them: `representedRows` and `markerCount` follow from the pin arrays above,
        /// but the retained/scoped totals and the withheld count can move while every pin stays
        /// put (an arrival off screen, a row cut at the marker cap). None of the three moves on a
        /// signal-only publish, so keeping them exact costs the gate nothing. The header itself
        /// reads them outside the gate, from the freshly installed snapshot. The same reasoning
        /// puts the three `spoken*` lens fields here: that label names the filter, the scope and
        /// the permission story too, and a filter change that lands on an identical pin set moves
        /// none of the counts.
        ///
        /// NOT solved here, deliberately: `ble.detections` is re-sorted newest-first on every
        /// publish, so when several drawn devices are being heard at once the pin arrays can come
        /// back holding the same pins in a different ORDER, and this element-wise walk reports a
        /// changed map. Order is real render state (annotation z-order), so it cannot simply be
        /// ignored; making a re-sort free needs a stable pin order in the snapshot or an
        /// order-insensitive key, which is a larger change than the render key.
        func rendersSameMap(as other: MapSnapshot) -> Bool {
            pinsAnimated == other.pinsAnimated
                && simplifiedArtwork == other.simplifiedArtwork
                && totalLocated == other.totalLocated
                && retainedLocated == other.retainedLocated
                && droppedRows == other.droppedRows
                && spokenFilter == other.spokenFilter
                && spokenScope == other.spokenScope
                && spokenLocationDenied == other.spokenLocationDenied
                && trackerTrails == other.trackerTrails
                && MapTabView.rendersSame(infra, other.infra) { $0.rendersSame(as: $1) }
                && MapTabView.rendersSame(clusters, other.clusters) { $0.rendersSame(as: $1) }
                && MapTabView.rendersSame(drones, other.drones) { $0.rendersSame(as: $1) }
        }
    }

    private func makeSnapshot(region requestedRegion: MKCoordinateRegion? = nil) -> MapSnapshot {
        // ONE clock reading for the whole pass, so two pins built microseconds apart can never
        // land in different age tiers. The tier is re-derived on event-driven rebuilds and the
        // visible map's low-frequency maintenance tick, so Recent expires even while disconnected.
        let signpostID = OSSignpostID(log: mapPerformanceLog)
        #if DEBUG
        os_signpost(.begin, log: mapPerformanceLog, name: "MapProjection", signpostID: signpostID,
                    "rows=%{public}d", ble.detections.count)
        #else
        os_signpost(.begin, log: mapPerformanceLog, name: "MapProjection", signpostID: signpostID)
        #endif
        let activeRegion = requestedRegion ?? region
        let activeSpan = activeRegion.span
        let now = Date()
        // ONE phone-position reading for the whole pass, for the same reason as the clock above:
        // two no-fix drone rings built microseconds apart must not end up centred on different
        // positions. It is a cached-fix lookup, not a radio call (see `selfCoord` in BLEManager),
        // and it feeds `DroneOverlay.selfCenter`, which the render key compares - so the ring can
        // no longer freeze at a position the phone has left while the gate holds the subtree.
        let selfCoordThisPass = ble.selfCoord
        var retainedLocated = 0
        var total = 0
        var filteredLocated = 0
        var viewportCulled = 0
        var counts: [String: Int] = [:]
        var drones: [DroneOverlay] = []
        var trackerTrails: [TrackerTrail] = []
        var clusterSeeds: [MapClusterSeed] = []
        var renderedOverlayVertices = 0
        let overlayBudget = mapTotalOverlayVertexBudget(span: activeSpan)
        let perTrailBudget = mapTrailPointBudget(span: activeSpan)
        // Same-spot buckets, filled IN THIS PASS: grouping costs one hash per grouped row and no
        // second walk of the store. Held as an ARRAY plus an index map, not as a dictionary of
        // members: the groups have to come out in a fixed order (first appearance in the store's
        // newest-first feed), because `infra`, built from them, is compared element by element in
        // `rendersSameMap` to decide whether the drawn map moved. Dictionary iteration order is
        // not part of that contract, and a group order that reshuffled for free would report a
        // changed map, and rebuild the annotations, on a publish that changed nothing. (`pins` is
        // sorted by id before it is built, so the ring-peek match never sees this order.)
        var spotIndex: [MapPinRules.SpotKey: Int] = [:]
        var spots: [(key: MapPinRules.SpotKey, coord: CLLocationCoordinate2D,
                     rows: [SpotRow], drone: Bool)] = []
        // Rows whose coordinate cannot be bucketed at all (a corrupt cache, a garbled fix).
        // They render exactly as they do today: one pin each, ungrouped.
        var unbucketed: [(row: SpotRow, c: CLLocationCoordinate2D)] = []
        for d in ble.detections {
            guard let c = mapCoord(for: d) else { continue }
            retainedLocated += 1
            let seen = ble.lastSeenDate(for: d.id)
            let basis = ble.timeBasis(for: d.id, stamp: seen)
            guard mapHistoryScopeIncludes(lastSeen: seen, basis: basis,
                                          scope: historyScope, now: now) else { continue }
            let currentlyWatched = ble.isWatched(d)
            total += 1
            counts[d.type.category, default: 0] += 1
            if d.type != .watched, currentlyWatched {
                counts[DeviceType.watched.category, default: 0] += 1
            }
            guard detectionMatchesCategory(type: d.type, category: filter,
                                           isCurrentlyWatched: currentlyWatched) else { continue }
            filteredLocated += 1
            let isDrone = d.type == .drone
            if isDrone {
                let rawTrack = ble.track(for: d.id)
                var footprint = rawTrack
                if let own = d.coordinate { footprint.append(own) }
                if let pilot = d.pilotCoordinate { footprint.append(pilot) }
                if footprint.isEmpty { footprint.append(c) }
                if drones.count < Self.overlayRowCap,
                   mapPolylineIntersectsViewport(footprint, region: activeRegion) {
                    let remaining = max(0, overlayBudget - renderedOverlayVertices)
                    let renderedTrack = remaining >= 2
                        ? simplifiedMapPolyline(rawTrack, maxPoints: min(perTrailBudget, remaining)) : []
                    renderedOverlayVertices += renderedTrack.count
                    // The no-fix ring's centre is carried in the overlay so the render key can
                    // compare it; only a drone that broadcast no position of its own gets one.
                    drones.append(DroneOverlay(
                        detection: d, track: renderedTrack,
                        selfCenter: d.coordinate == nil ? selfCoordThisPass : nil))
                }
            }
            if clusterable(d) {
                if showBreadcrumbs, d.type == .tracker {
                    let rawTrail = ble.crumbTrail(for: d.id)
                    let remaining = max(0, overlayBudget - renderedOverlayVertices)
                    if rawTrail.count >= 2, remaining >= 2,
                       trackerTrails.count < Self.overlayRowCap,
                       mapPolylineIntersectsViewport(rawTrail, region: activeRegion) {
                        let rendered = simplifiedMapPolyline(
                            rawTrail, maxPoints: min(perTrailBudget, remaining))
                        if rendered.count >= 2 {
                            trackerTrails.append(TrackerTrail(id: d.id, coordinates: rendered))
                            renderedOverlayVertices += rendered.count
                        }
                    }
                }
                if inViewport(c, region: activeRegion) {
                    clusterSeeds.append(MapClusterSeed(
                        id: d.id, type: d.type, coordinate: c, lastSeen: seen,
                        displayName: d.displayName, rssi: d.rssi))
                } else {
                    viewportCulled += 1
                }
            } else if isDrone || inViewport(c, region: activeRegion) {
                // Drones group with the infra rows rather than drawing from a set of their own.
                // Two pins at one coordinate means one of them takes every tap and the covered
                // one takes none; grouped, the coordinate draws ONE badged pin whose sheet
                // reaches every member, drone included. The drone keeps its viewport exemption
                // here so a pin that draws today still draws: outside the viewport the infra rows
                // were culled, so its group holds drone rows only and the pin is the drone's.
                let row = SpotRow(id: d.id, type: d.type, seen: seen,
                                  displayName: d.displayName, rssi: d.rssi)
                guard let key = MapPinRules.spotKey(c) else {
                    unbucketed.append((row, c)); continue
                }
                if let i = spotIndex[key] {
                    spots[i].rows.append(row)
                    if isDrone { spots[i].drone = true }
                } else {
                    // The first row in a cell fixes where its pin draws. Deliberately NOT an
                    // average of the members: these coordinates are one standing position, and
                    // averaging them would move the pin off a real recorded fix for no gain.
                    spotIndex[key] = spots.count
                    spots.append((key, c, [row], isDrone))
                }
            } else {
                // Off screen: not withheld by any budget, and one pan away from drawing.
                viewportCulled += 1
            }
        }
        var infra: [InfraPin] = []
        infra.reserveCapacity(spots.count + unbucketed.count)
        // What this pass costs per pin, honestly: ONE call to MapPinRules.lead. That is a single
        // linear scan of the bucket with no sort and no intermediate array, and it returns the
        // lone row immediately for a bucket of one, which is nearly all of them. The bucket
        // itself is handed to the pin as-is (an array retain, not a copy), and the ordered
        // member list is built later, at the tap, for one pin. Sorting every bucket here and
        // materialising its members - which is what this did - ran a sort, its arrays, and one
        // more array per pin on every publish (~3 Hz) and every camera move, all of it BEFORE
        // the 300-pin cap below could throw any of it away.
        for spot in spots {
            guard let lead = MapPinRules.lead(spot.rows,
                                              type: { $0.type },
                                              lastSeen: { $0.seen }) else { continue }
            infra.append(InfraPin(id: spot.key.id, coord: spot.coord,
                                  leadID: lead.id, leadType: lead.type,
                                  leadDisplayName: lead.displayName, leadRSSI: lead.rssi, group: spot.rows,
                                  age: MapPinRules.age(lastSeen: lead.seen, now: now),
                                  leadSeen: lead.seen, holdsDrone: spot.drone))
        }
        for r in unbucketed {
            infra.append(InfraPin(id: r.row.id, coord: r.c,
                                  leadID: r.row.id, leadType: r.row.type,
                                  leadDisplayName: r.row.displayName, leadRSSI: r.row.rssi,
                                  group: [r.row],
                                  age: MapPinRules.age(lastSeen: r.row.seen, now: now),
                                  leadSeen: r.row.seen, holdsDrone: r.row.type == .drone))
        }
        let infraCap = mapInfrastructurePinCap(span: activeSpan)
        if infra.count > infraCap {
            // Drone-bearing groups first, then newest lead. Drones are the one set that skipped
            // the viewport cull, so cutting one here would delete a pin that draws today and
            // strand the flight path the overlay pass still emits for that row. The id tie-break
            // is what makes the surviving set the SAME set pass to pass when stamps are equal:
            // sort is not stable, and a cut list that reshuffled would move the drawn pin set
            // for free (see the `pins` note below).
            infra = bestInfrastructurePins(infra, limit: infraCap)
        }
        let (clusters, _) = buildMapClusters(clusterSeeds, span: activeSpan, now: now)
        // Drones are NOT added on top: their pins are inside `infra` now, so adding the overlay
        // feed would count those rows a second time and trip the animation cap early. (The
        // operator marker has never been counted either - it carries no ping to drop.)
        let pinCount = infra.count + clusters.count
        let representedRows = infra.reduce(0) { $0 + $1.count }
            + clusters.reduce(0) { $0 + $1.memberCount }
        let mergedRows = max(0, representedRows - pinCount)
        // Rows a DISPLAY BUDGET withheld, and nothing else. `filteredLocated - viewportCulled` is
        // what reached a bucket or a cluster seed, so the residue after `representedRows` is what
        // the marker cap cut in `bestInfrastructurePins` (plus the one row shape nothing can
        // bucket: a coordinate `MapClusterKey` cannot hold). Subtracting the off-screen rows is
        // the whole point: at a city-block zoom over a large All-history store they are thousands
        // of ordinary rows that the header used to report as withheld by a budget and that the
        // VoiceOver summary used to call "combined into markers".
        let droppedRows = max(0, filteredLocated - viewportCulled - representedRows)
        let simplifiedArtwork = max(activeSpan.latitudeDelta, activeSpan.longitudeDelta) >= 1
            || pinCount > 160
        // Where the pins that ACTUALLY draw are, collected in THIS pass so the ring-peek match
        // never has to take a second one. Count bubbles are deliberately excluded: a bubble already
        // says "several things here" and opens a list naming them, so it never leaves the user
        // guessing the way a lone pin sitting on a hidden ring does. Infra is read AFTER the cap,
        // so a pin the map dropped can never light a ring.
        var pinItems: [PinSet.Item] = []
        pinItems.reserveCapacity(pinCount)
        for p in infra {
            pinItems.append(PinSet.Item(id: "infra:\(p.id)", latitude: p.coord.latitude,
                                        longitude: p.coord.longitude))
        }
        for c in clusters where c.singleID != nil {
            pinItems.append(PinSet.Item(id: c.id, latitude: c.coord.latitude,
                                        longitude: c.coord.longitude))
        }
        pinItems.sort { $0.id < $1.id }
        // Reads the tiers already resolved above, and stops at the first STALE pin it meets:
        // `contains` short-circuits and the `||` is lazy, so this is a search and not a tally,
        // and it never walks past the answer. Only a pass with NO stale pin anywhere reads both
        // sets in full, and both are bounded - infra by the viewport cull and the cap above, the
        // lone-member bubbles by the cull. The overlay feed is deliberately NOT consulted: the
        // legend explains a dim PIN, and a drone whose pin was absorbed into another row's group
        // is not drawing one. What that group DOES draw is its lead's age, which `infra` already
        // reports. Note the lead is chosen by priority first and only tie-breaks on recency, so
        // the absorbing row can be older than the drone it covers; the legend still matches the
        // screen either way, because it describes the pin that drew.
        let stale = infra.contains { $0.age == .stale }
            || clusters.contains { $0.age == .stale }
        // SIGNPOST PAYLOADS ARE DEBUG-ONLY. os_signpost arguments are written to the OS unified
        // log, which this app cannot clear, which survives deleting the app, and which a
        // sysdiagnose collects wholesale - and %{public} opts them out of redaction. They are
        // counts, never a coordinate or an identifier, but they are still derived from the
        // viewport of a person whose phone may be seized, and a shipping user gets nothing from
        // them. Release still emits the bare INTERVAL, so profiling a Release build with
        // Instruments (docs/map-performance.md) still shows how many map projections ran and how
        // long each took; only the numbers stop being recorded on the device.
        #if DEBUG
        os_signpost(.end, log: mapPerformanceLog, name: "MapProjection", signpostID: signpostID,
                    "scoped=%{public}d represented=%{public}d markers=%{public}d merged=%{public}d culled=%{public}d dropped=%{public}d vertices=%{public}d",
                    total, representedRows, pinCount, mergedRows, viewportCulled, droppedRows,
                    renderedOverlayVertices)
        #else
        os_signpost(.end, log: mapPerformanceLog, name: "MapProjection", signpostID: signpostID)
        #endif
        return MapSnapshot(
            totalLocated: total, retainedLocated: retainedLocated,
            representedRows: representedRows,
            markerCount: pinCount, mergedRows: mergedRows,
            viewportCulled: viewportCulled, droppedRows: droppedRows,
            counts: counts, drones: drones, infra: infra, clusters: clusters,
            trackerTrails: trackerTrails,
            pinsAnimated: !simplifiedArtwork && pinCount <= Self.animatedPinCap,
            simplifiedArtwork: simplifiedArtwork, pins: PinSet(items: pinItems),
            hasStalePins: stale,
            spokenFilter: filter, spokenScope: historyScope,
            spokenLocationDenied: ble.locationDenied && !ble.demoMode)
    }

    /// Keep only the highest-priority infrastructure markers without sorting every candidate.
    /// The heap root is the worst retained pin, so each extra candidate costs O(log limit); the
    /// final stable sort touches at most the adaptive 80...300 marker budget.
    private func bestInfrastructurePins(_ candidates: [InfraPin], limit: Int) -> [InfraPin] {
        guard limit > 0, candidates.count > limit else { return candidates }
        func ranksBefore(_ a: InfraPin, _ b: InfraPin) -> Bool {
            if a.holdsDrone != b.holdsDrone { return a.holdsDrone }
            let at = a.leadSeen ?? .distantPast, bt = b.leadSeen ?? .distantPast
            return at == bt ? a.id < b.id : at > bt
        }
        func isWorse(_ a: InfraPin, than b: InfraPin) -> Bool { ranksBefore(b, a) }
        var heap: [InfraPin] = []
        heap.reserveCapacity(limit)
        for candidate in candidates {
            if heap.count < limit {
                heap.append(candidate)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard isWorse(heap[child], than: heap[parent]) else { break }
                    heap.swapAt(child, parent); child = parent
                }
                continue
            }
            guard ranksBefore(candidate, heap[0]) else { continue }
            heap[0] = candidate
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                var worse = left
                if right < heap.count, isWorse(heap[right], than: heap[left]) { worse = right }
                guard isWorse(heap[worse], than: heap[parent]) else { break }
                heap.swapAt(parent, worse); parent = worse
            }
        }
        return heap.sorted(by: ranksBefore)
    }

    private func installFreshSnapshot(region requestedRegion: MKCoordinateRegion? = nil) {
        snapshotRefreshState.pending?.cancel()
        snapshotRefreshState.pending = nil
        let next = makeSnapshot(region: requestedRegion)
        let mapChanged = !next.rendersSameMap(as: snapshot)
        snapshot = next
        snapshotRefreshState.lastStamp = ProcessInfo.processInfo.systemUptime
        if mapChanged { bumpMapRenderRevision() }
    }

    /// Leading + trailing throttle: the first quiet update appears immediately; a Desert-mode
    /// burst collapses behind it but always receives one final projection at the end of the gap.
    private func scheduleDetectionSnapshotRefresh() {
        let interval = mapDetectionRefreshInterval(rowCount: ble.detections.count)
        let elapsed = ProcessInfo.processInfo.systemUptime - snapshotRefreshState.lastStamp
        let wait = interval - elapsed
        guard wait > 0 else { installFreshSnapshot(); return }
        guard snapshotRefreshState.pending == nil else { return }
        let work = DispatchWorkItem { installFreshSnapshot() }
        snapshotRefreshState.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func cancelSnapshotRefresh() {
        snapshotRefreshState.pending?.cancel()
        snapshotRefreshState.pending = nil
    }

    /// Inside the current viewport (plus a 20% margin so bubbles don't pop at the edges while panning).
    private func inViewport(_ c: CLLocationCoordinate2D, region: MKCoordinateRegion) -> Bool {
        abs(c.latitude  - region.center.latitude)  <= region.span.latitudeDelta  * 0.6 &&
        mapLongitudeDistanceDegrees(c.longitude, region.center.longitude)
            <= min(180, region.span.longitudeDelta * 0.6)
    }

    var body: some View {
        let snap = snapshot
        NavigationStack {
            ZStack(alignment: .top) {
                MapRenderGate(revision: mapRenderRevision) { map(snap) }
                    .equatable()
                VStack(spacing: 12) {
                    header(snap)
                    filterBar(snap)
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 8)
                .background(
                    LinearGradient(colors: [ACABTheme.bg, ACABTheme.bg.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                )
                if snap.totalLocated == 0 && !emptyDismissed {
                    emptyBanner.transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                legend(snap).padding(ACABTheme.pad).padding(.bottom, 6)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    settingsButton
                    recenterButton
                }
                .padding(ACABTheme.pad).padding(.bottom, 6)
            }
            .overlay(alignment: .bottom) {
                if let hint = alprHint {
                    Text(hint)
                        .font(ACABTheme.display(13)).foregroundStyle(ACABTheme.mapInfoText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(ACABTheme.mapInfoBackground,
                                    in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
                        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .padding(.horizontal, ACABTheme.pad)
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
            }
            // Tapped a known-ALPR dot: one shared credit callout (tap it to dismiss). Sits above
            // the alprHint slot so the two never collide in the narrow zoom band where both apply.
            .overlay(alignment: .bottom) {
                if showALPRInfo {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showALPRInfo = false } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Circle().strokeBorder((tappedALPRTier == 1 ? ACABTheme.flockTone : ACABTheme.warn).opacity(0.95),
                                                  style: StrokeStyle(lineWidth: 2,
                                                                     dash: tappedALPRTier == 1 ? [] : [2, 1.8]))
                                .frame(width: 11, height: 11).padding(.top, 4)
                            // The line the journalist needed: a pin is a MAPPED LOCATION, not a
                            // live detection, and most fixed ALPRs backhaul over cellular so they
                            // are silent to this hardware whether or not one is standing there.
                            // The unverified tier says so more softly still: nobody recorded a
                            // manufacturer for it, which is the shape a misidentified pole takes.
                            // On a PEEKING ring that denial is the one thing it must not say; see
                            // alprCalloutDetail.
                            VStack(alignment: .leading, spacing: 5) {
                                // TIER FIRST, then maker. Testing maker first printed "known
                                // ALPR" for a hand-typed name, contradicting the second line
                                // directly beneath it. The maker is still shown when we have one:
                                // an unverified node's NAME is the doubtful part, not its presence.
                                Text(ALPRAttribution.headline(
                                    tier: tappedALPRTier, maker: tappedALPRMaker))
                                    .font(ACABTheme.display(14, weight: .semibold))
                                    .foregroundStyle(ACABTheme.mapInfoText)
                                Text(alprCalloutDetail(tier: tappedALPRTier,
                                                       maker: tappedALPRMaker,
                                                       peek: tappedALPRPeek))
                                    .font(ACABTheme.display(13)).foregroundStyle(ACABTheme.mapInfoText)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ACABTheme.mapInfoText).padding(.top, 4)
                                .accessibilityHidden(true)
                        }
                        .padding(14)
                        .frame(maxWidth: 420, alignment: .leading)
                        .background(ACABTheme.mapInfoBackground,
                                    in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
                        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses mapped-camera information")
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.bottom, 60)
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
            // T5: regular width shows the tapped dossier in a trailing inspector (pin stays
            // visible); compact keeps today's full sheet. Exactly one is active per size class.
            .modifier(DossierPresentation(selected: $selected, regular: hSize == .regular))
            .sheet(item: $cluster) { c in
                ClusterListSheet(cluster: c) { d in
                    cluster = nil
                    // Defer so the picker sheet finishes dismissing before the detail one
                    // presents (two sheets can't transition at the same instant).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { selected = d }
                }
                .environmentObject(ble)
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showMapOptions) { mapOptionsSheet }
            // Dossier "OPEN IN MAP" handoff. Cold tab: the stash is consumed on first
            // compose. Warm tab (including a dossier opened from this very map): drop
            // our own presented dossier so it isn't in the way, then fly. The sheet
            // dismisses itself, but the regular-width inspector has no dismiss of its
            // own, so the clear here is what closes it.
            // Focus is consumed BEFORE the detections fit so an explicit handoff always wins.
            .onAppear {
                isMapVisible = true
                // Location is optional for pairing. Ask only when the user opens the one
                // surface that needs observer coordinates; existing grants simply resume fixes.
                if !ble.demoMode { ble.requestLocationAccessIfNeeded() }
                if MapFocus.pending != nil {
                    consumePendingFocus()
                } else {
                    installFreshSnapshot()
                    fitToDetections()
                }
            }
            .onDisappear {
                isMapVisible = false
                cancelSnapshotRefresh()
            }
            // @Published emits from willSet. Defer one run-loop turn so projection reads the
            // installed array/set, not the previous value from the manager.
            .onReceive(ble.$detections.dropFirst()) { _ in
                DispatchQueue.main.async {
                    guard isMapVisible else { return }
                    scheduleDetectionSnapshotRefresh()
                }
            }
            .onReceive(ble.$watched.dropFirst()) { _ in
                DispatchQueue.main.async {
                    guard isMapVisible else { return }
                    installFreshSnapshot()
                }
            }
            .onReceive(mapMaintenanceTimer) { _ in
                guard isMapVisible else { return }
                installFreshSnapshot()
            }
            .onChange(of: filter) { _, _ in installFreshSnapshot() }
            .onChange(of: historyScopeRaw) { _, _ in
                if suppressNextScopeRefit {
                    suppressNextScopeRefit = false
                    return
                }
                didFitToDetections = false
                installFreshSnapshot()
                fitToDetections()
            }
            .onChange(of: showBreadcrumbs) { _, _ in installFreshSnapshot() }
            .onChange(of: showLabels) { _, _ in bumpMapRenderRevision() }
            .onChange(of: alpr.enabled) { _, _ in refreshALPRVisible() }
            .onChange(of: alpr.showUnverified) { _, _ in refreshALPRVisible() }
            .onChange(of: alpr.nodes.count) { _, _ in refreshALPRVisible() }
            // Late first fix: the tab may open with an EXISTING row that is not located yet, so
            // row count never changes when its first paired coordinate arrives. Key this retry to
            // located membership instead. fitToDetections remains one-shot, so later strongest-
            // RSSI pin migrations never fight a user pan.
            .onChange(of: snap.totalLocated) { _, _ in fitToDetections() }
            // Demo seeds re-place around the user when the first GPS fix arrives - same COUNT,
            // new coordinates - so the hook above never fires and a one-shot fit taken on the
            // authored-city coords would strand the camera over six invisible pins (the exact
            // "5 sightings, no pins" bug). Demo only: live detections never teleport, and the
            // demo store is six rows, so re-arming the fit there is cheap and safe.
            //
            // Keyed on demoSeedKey, NOT on `ble.detections`: the rule the pin-set handler below
            // spells out. The store republishes a freshly built array at ~3 Hz, so Array `==` has
            // no buffer-identity shortcut and SwiftUI ran an element-by-element compare on every
            // body pass of a REAL session - walking the entire store on any pass where it found
            // no difference at all - purely to reach a handler that returns at the guard.
            // Outside demo the key is a constant empty array, which compares on count alone.
            .onChange(of: demoSeedKey) { _, _ in
                guard ble.demoMode else { return }
                didFitToDetections = false
                installFreshSnapshot()
                fitToDetections()
                // The re-placed seeds are new PIN COORDINATES, so the map's pin-set handler
                // re-matches the rings on the body pass this very change triggers. Nothing to do
                // here: stamping now would only match the pins from before they moved.
            }
            // WATCHED exists only while at least one located row belongs to it. If an unstar or
            // eviction removes the final member, drop the lens before its chip disappears.
            .onChange(of: snap.counts[DeviceType.watched.category] ?? 0,
                      initial: true) { _, count in
                if filter == DeviceType.watched.category, count == 0 { filter = nil }
            }
            .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
                selected = nil
                consumePendingFocus()
            }
        }
    }

    /// What the demo re-fit watches: the six seeded rows while the tour is running, and a
    /// constant empty array otherwise. The re-fit only ever cares about seeds being re-placed,
    /// so a live session should not be comparing the live store to notice that nothing happened.
    private var demoSeedKey: [Detection] { ble.demoMode ? ble.detections : [] }

    /// Frame the camera to the located detections' bounding region, exactly once per tab life.
    /// This runs BEFORE the hard-coded city fallback can matter, which is the fix for the demo
    /// bug where the header said "5 sightings" over an empty viewport: the seeds sat in one city
    /// while .userLocation's fallback framed another, and nothing ever reconciled them. The 40%
    /// margin plus a 0.01-degree floor keeps a tight clump (the demo seeds span ~0.005 degrees)
    /// comfortably inside the frame, single points get a neighborhood-scale view. A history that
    /// spans more than 1 degree on either axis (a road trip, weeks of driving) gets the OPPOSITE
    /// treatment: a full-bbox fit would open on a useless continent-scale wash of pins, so frame
    /// the MOST RECENT located detection at street scale instead - the newest sighting is what
    /// the user opened the tab to see.
    private func fitToDetections() {
        guard !didFitToDetections, MapFocus.pending == nil else { return }
        let now = Date()
        let coords = ble.detections.compactMap { d -> CLLocationCoordinate2D? in
            let seen = ble.lastSeenDate(for: d.id)
            guard mapHistoryScopeIncludes(lastSeen: seen,
                                          basis: ble.timeBasis(for: d.id, stamp: seen),
                                          scope: historyScope, now: now) else { return nil }
            return mapCoord(for: d)
        }
        guard let first = coords.first else { return }
        didFitToDetections = true
        var minLat = first.latitude,  maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        // Continent-wide history: `first` IS the most recent located detection (detections is
        // sorted newest-first and compactMap preserves order), so center on it at 0.02 degrees
        // (~2 km, a recognizable neighborhood) rather than fitting the whole bbox.
        if maxLat - minLat > 1.0 || maxLon - minLon > 1.0 {
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .region(MKCoordinateRegion(
                    center: first,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
            }
            bumpMapRenderRevision()
            return
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.01))
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
        bumpMapRenderRevision()
    }

    /// City-block zoom for the dossier handoff, roughly 600 m across.
    private static let focusSpan = MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)

    /// Consume the one-shot dossier handoff, if any: fly the camera to the stashed
    /// coordinate at city-block zoom. Called from onAppear (cold tab) and the MapFocus
    /// notification (warm tab); the nil-out makes it exactly-once. Also retires the
    /// detections fit: an explicit handoff placed the camera deliberately.
    private func consumePendingFocus() {
        guard let coord = MapFocus.pending else { return }
        MapFocus.pending = nil
        didFitToDetections = true
        // An explicit dossier handoff must reveal that retained row even if it is older than the
        // default 15-minute lens or belongs to a category different from the active chip. The
        // visible header reports both changes, so this is never a silent filter mutation.
        if historyScope != .all {
            suppressNextScopeRefit = true
            historyScopeRaw = MapHistoryScope.all.rawValue
        }
        filter = nil
        let target = MKCoordinateRegion(center: coord, span: Self.focusSpan)
        region = target
        span = target.span
        installFreshSnapshot(region: target)
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(target)
        }
        bumpMapRenderRevision()
    }

    private func map(_ snap: MapSnapshot) -> some View {
        Map(position: $camera) {
            UserAnnotation()                       // the phone's live position
            // Known ALPR cameras (default-on reference layer), drawn UNDER the live pins so a
            // live hit always sits on top. Quiet hollow rings, not the animated detection pins.
            // Tap one for the shared DeFlock credit callout: a Button (cheap) flips ONE @State
            // that a single bottom overlay reads - never a per-dot popover (see ALPRDot).
            ForEach(alprVisible) { p in
                Annotation("", coordinate: p.coord) {
                    Button {
                        tappedALPRMaker = p.maker
                        tappedALPRTier = p.tier
                        // The ring the finger landed on is the only thing that knows whether a
                        // live pin is standing on it; the shared callout below has no other way
                        // to find out, so the flag is recorded here with the maker and tier.
                        tappedALPRPeek = p.peek
                        withAnimation(.easeOut(duration: 0.15)) { showALPRInfo = true }
                    } label: { ALPRDot(confirmed: p.confirmed, peek: p.peek) }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(alprAccessibilityLabel(p))
                        .accessibilityHint("Shows information about this mapped camera")
                }
            }
            // Tracker breadcrumb trails: the phone's path while a separated tracker stayed with
            // us. Drawn UNDER the live pins (like the ALPR layer) so the tracker's own pin sits on
            // top, and DASHED teal so it reads distinct from the SOLID amber drone flight paths.
            // Hidden when the "phone breadcrumb trails" map setting is off.
            if showBreadcrumbs {
                ForEach(snap.trackerTrails) { d in
                    trackerTrail(d)
                }
            }
            // Drone flight paths, launch glyphs, operator tethers and operator markers. This
            // pass runs for EVERY located drone row and knows nothing about grouping, so a drone
            // whose pin was absorbed into a group led by another sighting keeps all of it. The
            // drone's own pin is drawn once, by the infra pass below, as that group's member.
            // Z-ORDER, deliberate: the OP marker used to draw just after its drone's pin and so
            // sat above it. The pin moved into the infra pass, so the pin now sits above OP where
            // the two coincide - a grounded drone, or any zoom-out that collapses the tether.
            // That is the better way round: the pin is the tappable thing that opens the dossier,
            // and OP is a non-interactive marker the tether already identifies.
            ForEach(snap.drones) { overlay in
                droneOverlay(overlay)
                if let pilot = overlay.detection.pilotCoordinate {
                    Annotation(showLabels ? "OP" : "", coordinate: pilot) { OperatorPin() }
                }
            }
            // Surveillance infrastructure, drones included: always an individual marker, never
            // bubbled into the count-bubble layer. Sightings stamped at the SAME standing
            // position collapse into one pin carrying a small count badge; the tap opens the same
            // member sheet a count bubble opens, so nothing is left buried under the pin on top.
            ForEach(snap.infra) { p in
                Annotation(showLabels ? p.leadType.shortTag : "", coordinate: p.coord) {
                    Button {
                        // The member list is put in draw order HERE, on the tap, for this one
                        // pin and on the stamps as they stand now: never in the snapshot pass for
                        // every pin on the map, and never on the stamps this held pin carries.
                        if p.count == 1 { selected = ble.detection(for: p.leadID) }
                        else {
                            let members = p
                                .orderedMemberIDs(lastSeen: { ble.lastSeenDate(for: $0) })
                                .compactMap { ble.detection(for: $0) }
                            if !members.isEmpty {
                                cluster = Cluster(id: p.id, coord: p.coord, members: members)
                            }
                        }
                    } label: {
                        MapPin(type: p.leadType,
                               animated: snap.pinsAnimated && p.age == .fresh,
                               badge: p.count,
                               dimmed: p.age == .stale,
                               simplified: snap.simplifiedArtwork)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(infraAccessibilityLabel(p))
                    .accessibilityHint(p.count == 1
                                       ? "Opens detection details"
                                       : "Opens the detections at this spot")
                }
            }
            // Clusterable hits: grid-clustered bubbles. A lone member renders as a normal
            // pin; a clump renders one count bubble so a dense log stays legible.
            ForEach(snap.clusters) { c in
                Annotation(showLabels ? c.shortTag : "", coordinate: c.coord) {
                    if let onlyID = c.singleID, let onlyType = c.singleType {
                        Button { selected = ble.detection(for: onlyID) } label: {
                            MapPin(type: onlyType,
                                   animated: snap.pinsAnimated && c.age == .fresh,
                                   dimmed: c.age == .stale,
                                   simplified: snap.simplifiedArtwork)
                        }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(c.accessibilityLabel)
                            .accessibilityHint("Opens detection details")
                    } else {
                        Button {
                            let members = c.memberIDs.compactMap { ble.detection(for: $0) }
                            if !members.isEmpty {
                                cluster = Cluster(id: c.id, coord: c.coord, members: members)
                            }
                        } label: {
                            ClusterBubble(count: c.memberCount, uniformType: c.uniformType,
                                          simplified: snap.simplifiedArtwork)
                        }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(c.accessibilityLabel)
                            .accessibilityHint("Opens the detections in this area")
                    }
                }
            }
        }
        // Captions follow the "icon labels" setting: each Annotation title is empty "" (no
        // caption, cleaner map) unless showLabels is on, when it carries the pin's short tag.
        // (Map has no .annotationTitles modifier; the empty title is the supported way to
        // suppress the caption, same as the ALPR dots, which always stay uncaptioned.)
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // MapUserLocationButton is deliberately NOT here: .mapControls renders at the map's top-trailing,
        // which on this full-bleed map sits UNDER our own header badge - invisible and untappable. The
        // custom recenterButton (bottom-trailing, styled like the rest of the app) replaces it.
        .mapControls { MapCompass() }
        .preferredColorScheme(.dark)
        .onMapCameraChange(frequency: .onEnd) { ctx in
            // MKCoordinateRegion/MKCoordinateSpan have NO Equatable conformance, so SwiftUI cannot dedupe
            // these @State writes for us: without this guard every callback invalidates body
            // unconditionally, even when the region is bit-identical. Required independently of the
            // .automatic fix above. (Android already does this - MapScreen.kt writes only on a flip.)
            let r = ctx.region, eps = 1e-6
            guard abs(r.center.latitude  - region.center.latitude)  > eps
               || abs(r.center.longitude - region.center.longitude) > eps
               || abs(r.span.latitudeDelta  - region.span.latitudeDelta)  > eps
               || abs(r.span.longitudeDelta - region.span.longitudeDelta) > eps else { return }
            span = r.span; region = r
            installFreshSnapshot(region: r)
            refreshALPRVisible(region: r)   // viewport changed: re-cull the drawn ALPR points
        }
        // The rings do not move when the pins do, but the PEEK does: a filter change hides or
        // reveals pins, a new sighting adds one, and a drone steps along its track, all without
        // touching the viewport. Keyed to the pin SET this pass actually drew - not to a count,
        // and never to `ble.detections` itself, which republishes at ~3 Hz - so a row that was
        // already in the store and only just got a coordinate still lands, while a publish that
        // moved no pin costs one array compare and nothing else. Stashing the pins here (an event
        // handler, not body) is what lets the match skip a store pass; the stamp behind it is
        // throttled, so an arrival stream cannot become a match-pass stream. `initial: true` seeds
        // the pins on the first pass, when there is no previous set to differ from.
        .onChange(of: snap.pins, initial: true) { _, pins in
            peekState.pins = pins.coords
            schedulePeekStamp()
        }
        .onAppear {
            refreshALPRVisible()
            // The first cull can land before the seeding above (SwiftUI does not order two
            // handlers on one view), in which case it stamped against no pins at all. Re-stamping
            // is free when it was not needed: ALPRPoint is Equatable, so an unchanged result is
            // zero @State writes.
            schedulePeekStamp()
        }
        // VoiceOver summary of what the pins carry: a silent map reads as an empty one.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mapAccessibilityLabel(snap))
        .ignoresSafeArea()
    }

    /// One spoken sentence carrying the map's actual state: the pin content for VoiceOver
    /// users, or which of the two empty stories (permission vs nothing located) applies.
    ///
    /// EVERY input comes off the snapshot, never off the view. This runs inside the render gate,
    /// so a fact read live here is a fact the gate can hold past its expiry - and the lens facts
    /// are exactly the ones that move without moving a pin. `MapSnapshot.spokenFilter` and its
    /// two neighbours are in the render key for that reason; reading them from the same place
    /// keeps the sentence and the key from ever drifting apart.
    private func mapAccessibilityLabel(_ snap: MapSnapshot) -> String {
        if snap.totalLocated == 0 {
            if snap.spokenLocationDenied {
                return "Map. The app cannot record where your phone heard detections while Location is off. Drones that broadcast Remote ID coordinates can still appear."
            }
            if snap.spokenScope == .recent, snap.retainedLocated > 0 {
                return "Map. No located detections in the previous fifteen minutes. \(snap.retainedLocated) older located detections remain retained in the Log."
            }
            return "Map. No located detections yet."
        }
        let shown = snap.representedRows
        let filtered = snap.spokenFilter.map { " filtered to \($0.lowercased())" } ?? " across all types"
        let scope = snap.spokenScope == .recent
            ? "from the previous fifteen minutes" : "from all history"
        // Two different facts, and only the first is aggregation: markers standing for more rows
        // than there are markers, and rows a cap withheld at this zoom. Saying "combined" for the
        // second told a VoiceOver user that rows had been folded into the pins on screen when they
        // had not been drawn at all - and before droppedRows counted the cap alone, it fired for
        // every off-screen row, i.e. on nearly every zoomed-in pass.
        let combined = snap.markerCount < shown
            ? " Combined into \(snap.markerCount) markers for this view."
            : ""
        let withheld = snap.droppedRows > 0
            ? " \(snap.droppedRows) more are not drawn at this zoom and stay in the Log."
            : ""
        return "Map showing \(shown) located detection\(shown == 1 ? "" : "s") \(scope)\(filtered). \(snap.retainedLocated) located detections retained.\(combined)\(withheld)"
    }

    /// A grouped infra pin speaks the sighting it DRAWS plus how many it stands for, because the
    /// count badge is the only thing on screen saying the other members exist.
    private func infraAccessibilityLabel(_ p: InfraPin) -> String {
        let base = mapPinAccessibilityLabel(type: p.leadType, displayName: p.leadDisplayName,
                                            rssi: p.leadRSSI, age: p.age)
        guard p.count > 1 else { return base }
        return "\(base) This pin represents \(p.count) detections at the same spot."
    }

    private func alprAccessibilityLabel(_ point: ALPRPoint) -> String {
        let base = ALPRAttribution.accessibilityLabel(tier: point.tier, maker: point.maker)
        // The enlarged ring is a purely visual cue, so VoiceOver is told the same fact in words.
        guard point.peek else { return base }
        return "\(base). A live detection is sitting on this mapped camera."
    }

    /// The clause a resting tier-1 ring ends on. Byte-identical to the tail of
    /// ALPRAttribution.detail(tier: 1, maker:) - the only tier whose wording denies a detection.
    private static let alprNotLiveClause = ", not a live detection"
    /// The ring-peek fact, in the callout's own words. Byte-identical to Android's
    /// ALPR_PEEK_SNIPPET (MapAlpr.kt), so the two platforms say the same sentence about the same
    /// ring. Says what was HEARD here, never that the mapped camera is the thing we heard.
    private static let alprPeekSentence = "wide ring: a live detection was heard at this mapped location"

    /// The tap callout's second line. `ALPRAttribution.detail` describes the RECORD, and its
    /// tier-1 wording ends "a mapped location, not a live detection" - true of a resting ring, a
    /// flat denial on one a live pin is standing on, which is the single case the ring-peek cue
    /// exists to show. The legend row and the VoiceOver label already tell the truth about that
    /// ring, so a sighted user was the only one being told otherwise. On a peeking ring the
    /// denial drops and the peek sentence carries the claim instead, matching Android's
    /// alprMarkerText(peek:). Nothing else moves: the tier body stays byte-identical, because the
    /// peek says something about the DETECTION, not about this row's attribution.
    private func alprCalloutDetail(tier: UInt8, maker: String, peek: Bool) -> String {
        let base = ALPRAttribution.detail(tier: tier, maker: maker)
        guard peek else { return base }
        let body = base.hasSuffix(Self.alprNotLiveClause)
            ? String(base.dropLast(Self.alprNotLiveClause.count)) : base
        return "\(body) \u{00B7} \(Self.alprPeekSentence)"
    }

    /// Drone-only overlays: the flight-path line, a launch marker at the first fix,
    /// and a dashed tether to the operator.
    @MapContentBuilder
    private func droneOverlay(_ overlay: DroneOverlay) -> some MapContent {
        let d = overlay.detection
        let track = overlay.track
        if track.count >= 2 {
            MapPolyline(coordinates: track)
                .stroke(ACABTheme.droneTone.opacity(0.85), lineWidth: 2.5)
        }
        if let launch = track.first {
            Annotation(showLabels ? "LAUNCH" : "", coordinate: launch) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ACABTheme.droneTone)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
        }
        if let drone = d.coordinate, let pilot = d.pilotCoordinate {
            MapPolyline(coordinates: [drone, pilot])
                .stroke(ACABTheme.droneTone.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        // No GPS fix: draw an RSSI ring around us instead. The centre comes off the overlay, NOT
        // off `ble.selfCoord`: this subtree is inside the render gate, so a live read here would
        // freeze at whatever position the phone held on the pass that last rebuilt the map. The
        // snapshot sets it only when the drone broadcast no position of its own, so `selfCenter`
        // being non-nil is the same condition `d.coordinate == nil` used to test.
        if let me = overlay.selfCenter {
            MapCircle(center: me, radius: rssiRadiusMeters(d.rssi))
                .foregroundStyle(ACABTheme.droneTone.opacity(0.08))
                .stroke(ACABTheme.droneTone.opacity(0.5), lineWidth: 1.5)
        }
    }

    /// A tracker's breadcrumb trail: the phone's path while a separated tag stayed with us.
    /// Dashed teal, distinct from the solid amber drone flight paths that use the same MapPolyline.
    @MapContentBuilder
    private func trackerTrail(_ trail: TrackerTrail) -> some MapContent {
        let crumbs = trail.coordinates
        if crumbs.count >= 2 {
            MapPolyline(coordinates: crumbs)
                .stroke(ACABTheme.trackerTone.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
        }
    }

    /// Rough RSSI → distance in metres for the no-GPS ring. Log-distance path-loss
    /// model, deliberately fuzzy, just a "somewhere around here" hint.
    private func rssiRadiusMeters(_ rssi: Int) -> Double {
        let d = pow(10.0, (-50.0 - Double(rssi)) / 25.0)   // assumes TxPower -50 dBm, path-loss n ~ 2.5
        return min(max(d, 5), 600)
    }

    /// NO LINK CHIP HERE, deliberately, and the same on Android (MapScreen.kt's header Column).
    /// The connection pill lives on Status and Beacon, which are where a user goes to ask "is my
    /// board there". On the Map it only competed with the counts for a narrow header: on a 411dp
    /// Android phone the row measured the text column first and "CONNECTED" wrapped mid-word over
    /// three lines. iOS never wrapped, because Kicker pins one line at default type, but the pill
    /// is redundant here on both platforms. Dropping it also gives the counts the full width.
    private func header(_ snap: MapSnapshot) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            Text("Map").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
            Kicker("\(historyScope.shortLabel) · \(activeFilterLabel)")
            Text(projectionSummary(snap))
                .font(ACABTheme.mono(10, weight: .medium))
                .foregroundStyle(ACABTheme.faint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeFilterLabel: String {
        guard let filter else { return "ALL TYPES" }
        return detectionCategories.first(where: { $0.key == filter })?.chipLabel ?? filter
    }

    /// Honest projection accounting: rows represented by the current viewport, the evidence the
    /// Log still retains, and how many MapKit annotations carry the visible rows. THREE causes get
    /// THREE separate numbers, because only one of them is a budget: rows merged into a marker
    /// ("simplified"), rows off screen ("outside this view", undone by panning), and rows a cap
    /// withheld ("outside display budget"). Naming them apart is what keeps aggregation from
    /// reading as evidence deletion - and it stops a zoomed-in viewport over a large store from
    /// reporting thousands of ordinary off-screen rows as withheld by a budget.
    private func projectionSummary(_ snap: MapSnapshot) -> String {
        var parts = ["\(snap.representedRows.formatted()) displayed",
                     "\(snap.retainedLocated.formatted()) retained"]
        if snap.markerCount != snap.representedRows || snap.simplifiedArtwork {
            parts.append("\(snap.markerCount.formatted()) markers")
        }
        if snap.viewportCulled > 0 {
            parts.append("\(snap.viewportCulled.formatted()) outside this view")
        }
        if snap.droppedRows > 0 { parts.append("\(snap.droppedRows.formatted()) outside display budget") }
        if snap.mergedRows > 0 || snap.simplifiedArtwork { parts.append("simplified") }
        return parts.joined(separator: " · ")
    }

    /// Scrolling category chips; tap one to narrow the pins. Reference layers and map display
    /// policy live together in the readable Options sheet, rather than masquerading as a type.
    private func filterBar(_ snap: MapSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "ALL", snap.totalLocated)
                ForEach(shownCategories(snap)) { c in
                    chip(c.key, c.chipLabel, snap.counts[c.key] ?? 0)
                }
            }
            .padding(.bottom, 2)
        }
    }

    /// Which category chips to actually render: a category with at least one LOCATED detection
    /// this session, OR the currently-active filter even at count 0. The active-filter exception
    /// keeps ordinary detector lenses visible through a transient eviction. WATCHED is different
    /// by contract: it exists only while a located member does, and the count-change hook above
    /// returns its empty lens to ALL before this removes the chip.
    private func shownCategories(_ snap: MapSnapshot) -> [DetectionCategory] {
        detectionCategories.filter {
            let count = snap.counts[$0.key] ?? 0
            return count > 0 || ($0.key != DeviceType.watched.category && filter == $0.key)
        }
    }

    /// Recenter on the phone's position. Replaces Apple's MapUserLocationButton, which lands under our
    /// header badge on this full-bleed map. Drives the camera EXPLICITLY, which is also why the fallback
    /// above can stay a fixed region instead of .automatic (see the loop note on `camera`).
    private var recenterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                camera = .userLocation(fallback: .region(MapTabView.fallbackRegion))
            }
            bumpMapRenderRevision()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 38pt chip.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Center on my location")
    }

    /// Cog companion to the recenter/legend controls: opens one readable options sheet for
    /// history scope, display density and reference layers.
    private var settingsButton: some View {
        Button {
            showMapOptions = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ACABTheme.dim)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 34pt chip.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map options")
        .accessibilityHint("Opens history, display, and reference layer options")
    }

    private var mapOptionsSheet: some View {
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        mapOptionsSection("HISTORY") {
                            Picker("Map history", selection: historyScopeBinding) {
                                ForEach(MapHistoryScope.allCases) { scope in
                                    Text(scope.label).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityHint("Recent shows the previous fifteen minutes; All history shows every retained located detection")
                            Text("Recent shows detections with a trustworthy time from the previous 15 minutes. All history changes only this map; the Log keeps every retained detection either way.")
                                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        mapOptionsSection("DISPLAY") {
                            Text(projectionSummary(snapshot))
                                .font(ACABTheme.mono(12, weight: .bold))
                                .foregroundStyle(ACABTheme.text)
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                            Text("dense and far-away sightings combine into fewer markers. pin sheets still reveal the detections represented by a marker; retained Log evidence is never removed.")
                                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                            // "phone", not "tracker": the drawn line is the PHONE's path while a
                            // tracker stayed with us, not the tag's own route (q-breadcrumbs says
                            // so). BYTE-IDENTICAL to Android's MapSettingRow label in MapScreen.kt
                            // - same words AND same case, so the two map options sheets cannot
                            // drift on this row.
                            Toggle("phone breadcrumb trails", isOn: $showBreadcrumbs)
                                .font(ACABTheme.display(15, weight: .medium))
                            Text(FollowEvidence.scopeLine)
                                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("icon labels", isOn: $showLabels)
                                .font(ACABTheme.display(15, weight: .medium))
                        }

                        // BYTE-IDENTICAL to Android MapScreen.kt's `Kicker("REFERENCE OVERLAYS ·
                        // NOT FILTERS")`, header and the ALPR note below alike: the toggles here
                        // draw reference data over the map and never hide a detection, and the
                        // two sheets must say so in the same words. The source credit
                        // ("cameras: OpenStreetMap ODbL · DeFlock") is the map legend's job on
                        // both phones; the note carries the privacy disclosure.
                        mapOptionsSection("REFERENCE OVERLAYS · NOT FILTERS") {
                            Toggle("known ALPR cameras",
                                   isOn: Binding(get: { alpr.enabled },
                                                 set: { alpr.setEnabled($0); if $0 { alpr.refresh() } }))
                                .font(ACABTheme.display(15, weight: .medium))
                            Text("draws community-mapped camera locations, on by default. the dataset is one offline download; no location, viewport, or detection data is attached, and the site host sees an ordinary web request. pins are mapped locations, not live detections.")
                                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                            if alpr.enabled {
                                Text(alprStatusLine)
                                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                                    .fixedSize(horizontal: false, vertical: true)
                                if alpr.unverifiedCount > 0 {
                                    Toggle("lower-confidence pins",
                                           isOn: Binding(get: { alpr.showUnverified },
                                                         set: { alpr.setShowUnverified($0) }))
                                        .font(ACABTheme.display(14, weight: .medium))
                                    Text(alprUnverifiedLine)
                                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                alprCheckRow
                            }
                        }
                    }
                    .padding(ACABTheme.pad)
                }
            }
            .navigationTitle("Map options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMapOptions = false }
                        .font(ACABTheme.mono(13, weight: .bold))
                        .foregroundStyle(ACABTheme.accentText)
                }
            }
        }
        .tint(ACABTheme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ACABTheme.bg)
    }

    private func mapOptionsSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Status caption under the known-ALPR toggle: how many cameras we hold, the dataset's
    /// publish date, and when the manifest was last checked. Same middle-dot separators as
    /// the rest of the map overlays.
    private var alprStatusLine: String {
        let checked = alpr.lastChecked.map { "checked \(checkedAgo($0))" } ?? "never checked"
        guard !alpr.nodes.isEmpty else { return "no dataset yet \u{00B7} \(checked)" }
        // Count what the map DRAWS. Captioning the full dataset while hiding a chunk of it makes
        // the toggle below look broken (number never moves) and overstates the coverage.
        let shown = alpr.showUnverified ? alpr.nodes.count : alpr.nodes.count - alpr.unverifiedCount
        var parts = ["\(shown.formatted()) camera\(shown == 1 ? "" : "s")"]
        if let u = alpr.updated { parts.append("dataset \(datasetDate(u))") }
        parts.append(checked)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Caption under the unconfirmed-pins toggle. Says what the tier MEANS rather than naming it,
    /// because "unverified" invites the reading that we checked and it failed. Nobody checked.
    private var alprUnverifiedLine: String {
        let n = alpr.unverifiedCount.formatted()
        return alpr.showUnverified
            ? "showing \(n) pin\(alpr.unverifiedCount == 1 ? "" : "s") without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras."
            : "\(n) lower-confidence pin\(alpr.unverifiedCount == 1 ? "" : "s") are hidden. some are not cameras."
    }

    /// Manual dataset refresh, mirroring the firmware "check for updates" row in Settings at
    /// panel scale: spinner while the manifest check + conditional download run, then a brief
    /// inline outcome before the label resets. Disabled while any fetch is in flight.
    private var alprCheckRow: some View {
        Button {
            guard !alprChecking else { return }
            Task {
                alprChecking = true
                alprJustChecked = false
                await alpr.refreshNow()
                alprChecking = false
                alprJustChecked = true
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                alprJustChecked = false
            }
        } label: {
            HStack(spacing: 6) {
                if alprChecking || alpr.loading {
                    ProgressView().controlSize(.mini).tint(ACABTheme.dim)
                } else {
                    Image(systemName: alprCheckSucceeded ? "checkmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(alprCheckLabel).font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(alprCheckSucceeded ? ACABTheme.accent : ACABTheme.dim)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .disabled(alprChecking || alpr.loading)
        .accessibilityLabel("Check automatic license plate reader map data for updates")
    }

    /// True in the brief post-check window when the check actually completed (fresh data or
    /// confirmed current), coloring the row; a failed check keeps the resting look.
    private var alprCheckSucceeded: Bool {
        guard alprJustChecked, let o = alpr.lastOutcome else { return false }
        return o != .failed
    }

    private var alprCheckLabel: String {
        if alprChecking || alpr.loading { return "checking" }   // store-driven too, so an automatic on-enable refresh reads the same as a tap (parity with Android)
        if alprJustChecked {
            switch alpr.lastOutcome {
            case .updated(let n): return "updated \u{00B7} \(n.formatted()) camera\(n == 1 ? "" : "s")"
            case .upToDate:       return "up to date"
            default:              return "couldn't check"
            }
        }
        return "check for updates"
    }

    /// Short "checked X ago" tail, same buckets the detail screen's relativeAgo speaks in.
    private func checkedAgo(_ date: Date) -> String {
        // Non-trapping, same as relativeAgo: a bad persisted Date degrades, never crashes.
        let secs = max(0, Int(exactly: Date().timeIntervalSince(date).rounded(.down)) ?? Int.max)
        switch secs {
        case ..<60:       return "just now"
        case ..<3600:     return "\(secs / 60)m ago"
        case ..<86_400:   return "\(secs / 3600)h ago"
        default:          return "\(secs / 86_400)d ago"
        }
    }

    /// "2026-07-27" (the manifest's `updated`) -> "Jul 27", with the year kept only when it
    /// isn't this year. Fixed POSIX formats, per the TimeBasisCopy rule.
    private func datasetDate(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        return out.string(from: d)
    }

    private func chip(_ cat: String?, _ label: String, _ n: Int) -> some View {
        let active = filter == cat
        let tint = catTint(cat)
        return Button { filter = cat } label: {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
                Text("\(n)").font(ACABTheme.mono(10))
                    .foregroundStyle(active ? ACABTheme.onAccent.opacity(0.7) : ACABTheme.faint)
            }
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? tint : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : ACABTheme.line, lineWidth: 1))
            // 44pt hit target; drawn capsule unchanged.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spokenCategory(label)), \(n) located")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func catTint(_ cat: String?) -> Color {
        switch cat {
        case "ALPR":     return ACABTheme.flockTone
        case "DRONE":    return ACABTheme.droneTone
        case "BODY CAM": return ACABTheme.axonTone
        case "TRACKER":  return ACABTheme.trackerTone
        case "GLASSES":  return ACABTheme.glassesTone
        case "CAMERA":   return ACABTheme.netcamTone
        case "WATCHED":  return DeviceType.watched.tint
        default:         return ACABTheme.accent
        }
    }

    private func spokenCategory(_ label: String) -> String {
        switch label {
        case "ALPR": return "automatic license plate readers"
        case "DRONE": return "drones"
        case "BODY CAM": return "body cameras"
        case "CAMERA", "NETCAM", "NETWORK CAM": return "network cameras"
        case "TRKR", "TRACKER": return "item trackers"
        case "GLAS", "GLASSES": return "recording glasses"
        case "WATCH", "WATCHED": return "watched devices"
        case "ALL": return "all categories"
        default: return label.lowercased()
        }
    }

    /// F18: whether the legend is open. Manual expansion aside, it auto-expands while the
    /// ALPR layer is downloading so the data credit is visible during the first load.
    /// Keyed to `downloading`, NOT `loading`: `loading` also covers the manifest freshness
    /// check that runs on every enable, so binding to it flashed the panel open and shut
    /// for a network round-trip that usually early-returns with the cache already drawn.
    private var legendOpen: Bool { legendExpanded || alpr.downloading }

    /// Collapsed by default: a small circular info chip. Tap to expand the full legend;
    /// tap the panel to tuck it away again.
    private func legend(_ snap: MapSnapshot) -> some View {
        Group {
            if legendOpen {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { legendExpanded = false }
                } label: { legendPanel(snap) }
                .buttonStyle(.plain)
                // NO .accessibilityLabel here, deliberately. A Button merges its label subtree
                // into ONE element, and an explicit label REPLACES the string SwiftUI synthesises
                // from that subtree's Texts - so "Collapse map legend" was the whole panel to
                // VoiceOver: no category rows, no dim-pin rule, no ring-peek row, and none of the
                // "cameras: OpenStreetMap ODbL · DeFlock" credit this panel auto-expands during
                // the first download to show. Value + hint say what the control does WITHOUT
                // standing in for the content, and the value keeps both legend states naming
                // which side they are on: the collapsed chip below carries
                // .accessibilityValue("collapsed"), and Android sets stateDescription
                // "expanded"/"collapsed" across that same pair (MapScreen.kt).
                .accessibilityValue("expanded")
                .accessibilityHint("Collapses the map legend")
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { legendExpanded = true }
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ACABTheme.mapInfoText)
                        .frame(width: 34, height: 34)
                        .background(ACABTheme.mapInfoBackground, in: Circle())
                        .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                        // 44pt hit target around the 34pt chip.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Map legend")
                .accessibilityValue("collapsed")
            }
        }
        .animation(.easeOut(duration: 0.2), value: legendOpen)
    }

    private func legendPanel(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            legendRow(ACABTheme.flockTone, "ALPR")
            legendRow(ACABTheme.droneTone, "Drone")
            legendRow(ACABTheme.axonTone,  "Body cam")
            legendRow(ACABTheme.trackerTone, "Tracker")
            legendRow(ACABTheme.glassesTone, "Glasses")
            HStack(spacing: 7) {
                legendSwatch {
                    Image(systemName: "web.camera.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(ACABTheme.netcamTone)
                        .frame(width: 8, height: 8)
                }
                Text("Network camera").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
            }
            // The dim treatment, named. A pin persisted from yesterday used to look exactly like a
            // live hit, so the cue only works if the panel says what it means. The swatch is the
            // ALPR tone at the very alpha a stale pin draws at, so it reads as a colour already in
            // the panel at lower strength rather than as another category; the hairline above it
            // is what separates the treatment from the category rows, the same way the
            // lower-confidence row below is separated. Gated on a stale pin actually being drawn,
            // for the same reason that row is gated on its tier being shown.
            if snap.hasStalePins {
                HStack(spacing: 7) {
                    legendSwatch {
                        Circle().fill(ACABTheme.flockTone.opacity(MapPinRules.staleTintAlpha))
                            .frame(width: 8, height: 8)
                    }
                    Text("Dimmed: last heard over an hour ago")
                        .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
                }
                .padding(.top, 6)
                .overlay(alignment: .top) {
                    Rectangle().fill(ACABTheme.line).frame(height: 1)
                }
            }
            if alpr.enabled {
                // NOT a bare Divider: dividers are width-greedy and would balloon the
                // panel to the full overlay width. The hairline rides the row instead.
                HStack(spacing: 7) {
                    legendSwatch {
                        Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 2)
                            .frame(width: 9, height: 9)
                    }
                    Text("Known ALPR").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
                }
                // The ring-peek cue, named. Gated on a ring actually peeking right now, the same
                // rule the lower-confidence row below follows: a legend that explains a treatment
                // nothing on screen is using reads as a rendering bug. The scan is only ever run
                // while the panel is expanded, over the capped culled set.
                if alprVisible.contains(where: \.peek) {
                    HStack(spacing: 7) {
                        // The widest swatch in the panel, and the reason the slot exists: the
                        // whole cue is "this ring is bigger", so the swatch has to be bigger too.
                        legendSwatch {
                            ZStack {
                                Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 1.6)
                                    .frame(width: 13, height: 13)
                                Circle().fill(ACABTheme.text).frame(width: 7.5, height: 7.5)
                            }
                        }
                        Text("Live hit on a mapped camera")
                            .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
                    }
                }
                // Unverified tier. Hollow + DASHED, matching ALPRDot: the swatch has to be the
                // shape you actually see on the map, and it cannot be a filled amber dot because
                // ACABTheme.warn IS droneTone (both 0xF2B53C) - a filled one is pixel-identical to
                // the Drone row above.
                //
                // Gated on showUnverified for the same reason it is gated on alpr.enabled: a legend
                // that names a colour nothing on screen is using reads as a rendering bug.
                if alpr.showUnverified {
                    HStack(spacing: 7) {
                        legendSwatch {
                            Circle().strokeBorder(ACABTheme.warn.opacity(0.95),
                                                  style: StrokeStyle(lineWidth: 2, dash: [2, 1.8]))
                                .frame(width: 9, height: 9)
                        }
                        Text("ALPR (lower confidence)").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) {
                        Rectangle().fill(ACABTheme.line).frame(height: 1)
                    }
                }
                Text("cameras: OpenStreetMap ODbL · DeFlock")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.mapInfoText)
            }
        }
        // Hug the content, but never past the screen. fixedSize(horizontal:) alone means "take my
        // ideal width" with no upper bound, which was safe only while the fonts ignored Dynamic
        // Type; once ACABTheme.mono started scaling, a large-text legend could run off the map.
        // The frame caps it so it still hugs when small and wraps when it cannot.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(11)
        .background(ACABTheme.mapInfoBackground,
                    in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
    }

    private func legendRow(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 7) {
            legendSwatch { Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.6), radius: 3) }
            Text(t).font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.mapInfoText)
        }
    }

    /// Width of the legend's swatch column. Every swatch sits centred in this SAME fixed slot, so a
    /// row whose swatch is bigger - the ring-peek one, which has to be bigger, that IS the cue -
    /// cannot push its label out of line with the rest of the column. Sized to the widest swatch.
    /// Android's LegendRow does the same with a 12dp box.
    private static let legendSwatchSlot: CGFloat = 13

    private func legendSwatch<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(width: Self.legendSwatchSlot, height: Self.legendSwatchSlot)
    }

    /// True when the "empty" story is a permission problem, not a data one. Demo mode exempts
    /// itself: its seeds carry coordinates regardless of the phone's location permission.
    private var emptyBecausePermission: Bool { ble.locationDenied && !ble.demoMode }
    private var emptyBecauseHistoryScope: Bool {
        !emptyBecausePermission && historyScope == .recent && snapshot.retainedLocated > 0
    }

    /// Two distinct empty stories over the same slot. Permission off gets the actionable one
    /// (Open Settings); otherwise it is the honest "nothing located yet". Detections existing
    /// is the third state: the banner never mounts (see body) and the camera fits to them.
    private var emptyBanner: some View {
        VStack(spacing: 9) {
            Image(systemName: emptyBecausePermission ? "location.slash"
                  : emptyBecauseHistoryScope ? "clock.arrow.circlepath" : "mappin.slash")
                .font(.system(size: 28)).foregroundStyle(ACABTheme.faint)
            if emptyBecausePermission {
                Text("Location is off, so the app can't record where your phone heard detections. Drones that broadcast Remote ID coordinates can still appear on the map.")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openAppSettings) {
                    Text("OPEN SETTINGS")
                        .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.accentText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)   // 44pt target
                        .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if emptyBecauseHistoryScope {
                Text("No recent located detections")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                Text("The Recent map covers the previous 15 minutes. Older located detections are still retained in the Log.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    historyScopeRaw = MapHistoryScope.all.rawValue
                } label: {
                    Text("SHOW ALL HISTORY")
                        .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.accentText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("No located detections yet")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                Text("Detections appear here once they're heard with location available.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
                Text("ALPR, body cam, glasses, network camera and tracker hits use your phone's position; drones report their own.")
                    .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
        // Hit-testing stays ON when the Open Settings button is present (it has to be tappable);
        // the informational variant lets touches fall through so the map still pans behind it.
        .allowsHitTesting(emptyBecausePermission || emptyBecauseHistoryScope)
        .overlay(alignment: .topTrailing) {
            // Dismiss (x) on BOTH variants (the informational one used to have none). It lives in
            // this overlay, layered OVER the card AFTER the .allowsHitTesting above, so it stays
            // tappable even on the informational variant whose card passes gestures through to the
            // map: only the small x region intercepts touches, the rest still pans the map behind.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { emptyDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(ACABTheme.dim)
                    .frame(width: 26, height: 26)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                    // 44pt hit target around the 26pt chip.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// T5: on regular width the tapped dossier rides in a trailing `.inspector` (the map + pin
/// stay on screen); on compact it stays the full-height `.sheet`. Only one is ever active.
/// SwiftUI ships only `inspector(isPresented:)`, so presentation is derived from the item.
private struct DossierPresentation: ViewModifier {
    @Binding var selected: Detection?
    let regular: Bool
    @EnvironmentObject private var ble: BLEManager

    func body(content: Content) -> some View {
        if regular {
            content.inspector(isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            )) {
                if let d = selected {
                    DetectionDetailView(detection: d)
                        .environmentObject(ble)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
            }
        } else {
            content.sheet(item: $selected) { DetectionDetailView(detection: $0).environmentObject(ble) }
        }
    }
}

// MARK: - Shared map-pin rules

/// The two rules that decide what a map pin stands for and how old it is allowed to look.
///
/// Pure value logic: no CoreBluetooth, no SwiftUI, no store. That is what lets the tests pin the
/// rules down directly, and it is why every caller here reads the same answer instead of each
/// annotation re-deriving one.
///
/// SHARED WITH ANDROID on the RULE and on the thresholds below: the same-spot tolerance, the
/// priority order, "break ties by most recent", the three age boundaries, and "a missing stamp is
/// RECENT, never FRESH". What is deliberately NOT shared is artwork. Each platform draws its own
/// badge and its own dimmed marker with numbers derived from its own pin, so neither side may
/// "fix" the other's to match.
enum MapPinRules {

    // MARK: Same-coordinate grouping

    /// Grid cell for "the same standing position", in degrees. About 1.1 m of latitude.
    ///
    /// Every detection logged from one spot is stamped with the SAME phone coordinate, so infra
    /// pins land exactly on top of each other: only the topmost took a tap, nothing said how many
    /// were underneath, and the row list being newest-first meant the OLDEST sighting drew last
    /// and stole every one of those taps.
    ///
    /// QUANTIZED, not a pairwise radius sweep. The case this exists for is coordinates that are
    /// EQUAL, and a grid costs one hash per pin instead of comparing every pin to every other
    /// pin. The cost is a cell edge: two sightings a metre apart that straddle one stay separate,
    /// which is the safe direction to be wrong, because separate is exactly what the map draws
    /// today.
    static let sameSpotDegrees = 1e-5

    /// Which grid cell a coordinate falls in. Hashable and allocation-free; the group's string
    /// identity is built once per GROUP, never per row.
    struct SpotKey: Hashable {
        let lat: Int
        let lon: Int
        var id: String { "\(lat):\(lon)" }
    }

    /// The cell `c` falls in, or nil for a coordinate that cannot be bucketed without trapping
    /// (a NaN or a wild value out of a corrupt cache or a garbled Remote ID fix). A nil key is
    /// rendered ungrouped, i.e. exactly as it renders today.
    static func spotKey(_ c: CLLocationCoordinate2D) -> SpotKey? {
        let lat = (c.latitude / sameSpotDegrees).rounded(.down)
        let lon = (c.longitude / sameSpotDegrees).rounded(.down)
        // isFinite first: NaN fails every comparison, so an ordering test alone would let it
        // through to a trapping Int conversion.
        guard lat.isFinite, lon.isFinite, abs(lat) <= 1e12, abs(lon) <= 1e12 else { return nil }
        return SpotKey(lat: Int(lat), lon: Int(lon))
    }

    /// Which sighting a stack of same-spot pins draws AS. Lower is more important.
    ///
    /// This order IS the feature. The map's job is to say "a body camera was here", and a body
    /// camera must never end up hidden under an older, less important sighting that happens to
    /// share its coordinate.
    static func priority(_ type: DeviceType) -> Int {
        switch type {
        case .watched:      return 0   // the user named this exact device; nothing outranks that
        case .flockCamera:  return 1
        case .flockRaven:   return 2
        case .axonBodyCam:  return 3
        case .drone:        return 4
        default:            return 5   // everything else, in one bucket
        }
    }

    /// Same-spot members ordered so the pin that draws is element 0: priority first, then MOST
    /// RECENT, then the order they arrived in. That last step is not decoration. Swift's sort is
    /// not stable, so without it two members tied on both keys could swap between passes, and an
    /// annotation whose identity or artwork flickers pops on the map.
    static func ordered<T>(_ members: [T],
                           type: (T) -> DeviceType,
                           lastSeen: (T) -> Date?) -> [T] {
        guard members.count > 1 else { return members }
        return members.enumerated()
            .map { (i: $0.offset,
                    p: priority(type($0.element)),
                    t: (lastSeen($0.element) ?? .distantPast).timeIntervalSinceReferenceDate,
                    m: $0.element) }
            .sorted {
                if $0.p != $1.p { return $0.p < $1.p }
                if $0.t != $1.t { return $0.t > $1.t }
                return $0.i < $1.i
            }
            .map(\.m)
    }

    /// The one member a same-spot group DRAWS as, i.e. exactly what `ordered(_:)` puts first,
    /// found in a single linear scan with no sort and no intermediate array.
    ///
    /// This is the map's hot path: it runs once per infra pin on every publish and every camera
    /// move, while the full ordering runs once per tap. The two must never disagree, so the
    /// tie-break here is the same one by construction - a later member replaces the incumbent
    /// ONLY when it strictly wins on priority, or, at equal priority, strictly wins on recency -
    /// which leaves the earliest arrival holding a full tie, exactly as `ordered`'s index
    /// tie-break does. A group of one comes straight back out without resolving anything.
    static func lead<T>(_ members: [T],
                        type: (T) -> DeviceType,
                        lastSeen: (T) -> Date?) -> T? {
        guard let first = members.first else { return nil }
        guard members.count > 1 else { return first }
        var best = first
        var bestPriority = priority(type(first))
        var bestSeen = (lastSeen(first) ?? .distantPast).timeIntervalSinceReferenceDate
        for m in members.dropFirst() {
            let p = priority(type(m))
            if p > bestPriority { continue }   // outranked: its stamp never has to be resolved
            let t = (lastSeen(m) ?? .distantPast).timeIntervalSinceReferenceDate
            guard p < bestPriority || t > bestSeen else { continue }
            best = m
            bestPriority = p
            bestSeen = t
        }
        return best
    }

    /// Are `a` and `b` the same same-spot members, whatever order the feed listed them in?
    ///
    /// The render gate compares an infra pin's bucket with this (`InfraPin.rendersSame(as:)`).
    /// Buckets are filled in feed order, and `publishDetections` (BLEManager) re-sorts the feed
    /// newest-first on every publish, so two members that are both still being heard swap places
    /// whenever their stamps cross. Compared element by element, that swap alone reported a
    /// changed map and rebuilt every annotation for it. Nothing drawn reads the order: the pin
    /// draws the lead (compared on the pin by id, type and name), the badge draws the count, and
    /// a tap orders the members through `ordered` on stamps it reads at that moment
    /// (`InfraPin.orderedMemberIDs(lastSeen:)`). All that takes from the bucket's order is the
    /// arrival-index tie-break, which only separates members tied on both priority and stamp, an
    /// order the feed's own sort never fixed. What this therefore no longer invalidates on is a
    /// pure re-ordering of the same ids and types inside one bucket, and nothing else.
    ///
    /// Hot path cost: the element-wise walk, allocation-free. That walk IS the whole test for any
    /// bucket whose members and order both held, a bucket of one included (nearly every pin). A
    /// same-size bucket whose walk stops early pays the id-keyed dictionary, O(n) and one
    /// allocation: one whose order moved, in place of the annotation rebuild that used to cost,
    /// and one with a member swapped out, whose pass rebuilds anyway. Ids are unique within a
    /// bucket because the feed is built from `store.values`, a dictionary keyed by id
    /// (BLEManager.publishDetections), so equal counts plus "every id of `a` is in `b` with the
    /// same type" is set equality.
    static func sameMembers<T>(_ a: [T], _ b: [T],
                               id: (T) -> String,
                               type: (T) -> DeviceType) -> Bool {
        guard a.count == b.count else { return false }
        var i = 0
        while i < a.count, id(a[i]) == id(b[i]), type(a[i]) == type(b[i]) { i += 1 }
        if i == a.count { return true }
        var members: [String: DeviceType] = [:]
        members.reserveCapacity(b.count)
        for m in b { members[id(m)] = type(m) }
        for m in a where members[id(m)] != type(m) { return false }
        return true
    }

    // MARK: Age

    /// How old the sighting behind a pin is, in the three tiers the map draws.
    ///
    /// Without this a pin persisted from yesterday looked exactly like a live hit, and the ping
    /// animation was gated only on how many pins were on screen, so old pins pulsed like alerts.
    enum Age {
        /// Under `freshSeconds`. Full colour, and the ping may run (still subject to the pin-count
        /// cap and Reduce Motion).
        case fresh
        /// `freshSeconds` to `staleSeconds`, and the tier a pin with no usable stamp lands in.
        /// Full colour, no ping.
        case recent
        /// Past `staleSeconds`. Dimmed, no ping, and otherwise untouched: same size, same glyph,
        /// same colour family, still tappable.
        case stale
    }

    static let freshSeconds: TimeInterval = 5 * 60
    static let staleSeconds: TimeInterval = 60 * 60

    /// The tier for a row's lastSeen stamp, the same stamp the log and the cluster sheet order by.
    ///
    /// A missing or zeroed stamp resolves to RECENT, never FRESH. A row we cannot date is a row we
    /// cannot call live, and the whole point of the tier is that FRESH means something.
    static func age(lastSeen: Date?, now: Date) -> Age {
        // A zeroed stamp is 1970, which would otherwise read as the oldest thing on the map. It
        // means "unknown", so it takes the unknown tier.
        guard let lastSeen, lastSeen.timeIntervalSince1970 > 0 else { return .recent }
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed.isFinite else { return .recent }
        // Clamped, not trusted: a stamp ahead of the clock is a clock correction, not the future.
        let secs = max(0, elapsed)
        if secs < freshSeconds { return .fresh }
        if secs <= staleSeconds { return .recent }
        return .stale
    }

    /// Alpha a STALE pin draws its own tone at. See MapPin.tone for why this is alpha rather than
    /// a saturation filter.
    static let staleTintAlpha: Double = 0.45
}

/// Animated category pin: filled dot with a glyph and a slow ping ring. `animated: false`
/// (set once per body pass when the visible pin count crosses animatedPinCap, or when the
/// sighting behind the pin is not FRESH) drops the repeatForever ping entirely, so hundreds of
/// independent Core Animation loops never coexist on a dense map and an old sighting never
/// pulses like a live alert.
private struct MapPin: View {
    let type: DeviceType
    var animated = true
    /// How many detections this ONE pin stands for. 1 (or nil) draws today's artwork exactly:
    /// a group of one has to be visually unchanged.
    var badge: Int? = nil
    /// STALE tier: the pin keeps its size, its glyph and its colour family, and only its
    /// intensity drops. Never a hide, never a shrink, never a shared "old" colour.
    var dimmed = false
    /// Dense/far projections retain the category glyph and hit target but omit per-marker glows.
    /// Hundreds of offscreen-rendered shadows are a disproportionate compositing cost.
    var simplified = false
    @State private var ping = false
    // Reduce Motion drops the looping ping ring entirely, same as the dense-map cap does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pin's tone at the current age. Dimming is done with COLOUR ALPHA rather than a
    /// .saturation / .grayscale modifier: those install a layer colour filter on every pin that
    /// carries one, and this map draws pins up to its own cap. Over the map's near-black ground
    /// a lowered alpha reads as the same hue, washed out, which is the cue.
    private var tone: Color { dimmed ? type.tint.opacity(MapPinRules.staleTintAlpha) : type.tint }

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle().stroke(tone, lineWidth: 2).frame(width: 28, height: 28)
                    .scaleEffect(ping ? 1.9 : 0.9).opacity(ping ? 0 : 0.7)
            }
            Circle().fill(tone).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2.5))
                // The glow goes with the colour: a stale pin that still bloomed would keep
                // drawing the eye, which is the exact thing the tier exists to stop.
                .shadow(color: type.tint.opacity(dimmed || simplified ? 0 : 0.7), radius: 6)
            Image(systemName: type.symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
            if let badge, badge > 1 { countBadge(badge) }
        }
        .onAppear(perform: updateAnimation)
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
        .onChange(of: animated) { _, _ in updateAnimation() }
    }

    /// Small corner badge for a same-spot group: "this one pin is several sightings".
    ///
    /// Deliberately NOT ClusterBubble's shape. A count bubble is a large tint-ringed disc sitting
    /// ON the coordinate INSTEAD of a pin, and it means "several things somewhere in this area";
    /// this is a small capsule clipped to the shoulder of an ordinary pin, and it means "several
    /// things at exactly this point". Keeping the pin artwork whole is what keeps the two apart.
    private func countBadge(_ n: Int) -> some View {
        // Three digits would be wider than the pin it hangs off. The exact size stops mattering
        // long before that; the sheet behind the tap still lists every member.
        Text(n < 100 ? "\(n)" : "99+")
            .font(ACABTheme.mono(9, weight: .bold)).monospacedDigit()
            // The count stays at full strength on a dimmed pin: the age is the pin's business,
            // the number still has to be readable.
            .foregroundStyle(ACABTheme.text)
            .padding(.horizontal, 3)
            .frame(minWidth: 15, minHeight: 15)
            .background(ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(tone, lineWidth: 1))
            .offset(x: 14, y: -12)
    }

    private func updateAnimation() {
        var parked = Transaction(animation: nil)
        parked.disablesAnimations = true
        withTransaction(parked) { ping = false }
        guard animated, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { ping = true }
    }
}

/// Muted person icon for a drone's operator, kept distinct from the device pin.
/// Tap it for a one-line explanation: remote ID broadcasts the pilot's location.
private struct OperatorPin: View {
    @State private var showInfo = false
    var body: some View {
        Button { showInfo = true } label: {
            Image(systemName: "person.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                .padding(6)
                .background(ACABTheme.bg3, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Drone operator")
        .accessibilityHint("Explains this Remote ID operator position")
        .popover(isPresented: $showInfo) {
            Text("operator. this drone broadcasts its pilot's location in its remote ID, so this pin is roughly where it's being flown from.")
                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(width: 230)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A known-ALPR camera point (default-on reference layer). ALP4 identity is stable OSM type + ID, so
/// two cameras mapped at the same coordinate remain distinct; legacy caches add their row index.
/// Equatable so refreshALPRVisible can early-out when the culled set is unchanged: without it every
/// camera callback rewrites @State and invalidates body even when nothing moved. `id` is stored, not
/// computed - it's read per-row by ForEach, and interpolating a String there is the same trap that
/// made Detection.id expensive.
private struct ALPRPoint: Identifiable, Equatable {
    let coord: CLLocationCoordinate2D
    let maker: String
    /// Raw attribution tier from ALP3/ALP4. Tier 1 gets the stronger solid treatment; tier 0 and
    /// tier 2 remain distinguishable in copy even though both use the lower-confidence ring.
    let tier: UInt8
    var confirmed: Bool { tier == 1 }
    /// A rendered detection pin is standing on this camera, so the ring draws enlarged and its rim
    /// peeks out around the pin. Stamped by applyPeek - on the cull pass, and on the throttled
    /// pin-set pass - NEVER in body. Part of `==` on purpose: a peek that appears or clears has to
    /// reach the map. See ALPRRingPeek.
    var peek = false
    let id: String
    init(id: String, coord: CLLocationCoordinate2D, maker: String, tier: UInt8) {
        self.id = id
        self.coord = coord
        self.maker = maker
        self.tier = tier
    }
    // Stable identity plus every display field keeps an unchanged viewport at zero @State churn.
    static func == (a: ALPRPoint, b: ALPRPoint) -> Bool {
        a.id == b.id && a.coord.latitude == b.coord.latitude
            && a.coord.longitude == b.coord.longitude && a.maker == b.maker && a.tier == b.tier
            && a.peek == b.peek
    }
}

/// Geometry for the "live hit AT a mapped camera" cue.
///
/// A filled detection pin - a 28pt disc inside its own tinted glow - completely covers a 14pt
/// known-ALPR ring, so at map level a hit standing on a mapped camera looked exactly like a hit
/// somewhere nobody has ever mapped. That is the single most useful sentence this map can say, and
/// it was invisible. A ring with a rendered pin on it draws at `diameter` instead of 14pt, so its
/// rim stands clear of the pin's artwork with a readable gap between the two.
/// The ring still draws UNDER the pins and keeps its confirmed/unverified stroke, so a peeking
/// ring is still a hollow static ring and can never be read as a detection of its own.
///
/// Keep in lockstep with Android (MapMarkers.kt rememberAlprMarker + the MapScreen.kt match pass)
/// on the RULE, not on every number: same match radius, same "rendered PINS only, never count
/// bubbles" rule, same "the rim visibly clears the pin's own artwork" requirement. The enlarged
/// DIAMETER is deliberately platform-specific - the two pin artworks are different sizes, so each
/// side derives its own number from its own pin (Android: 49dp, off a pin whose outermost ink is a
/// 41dp pulse ring). Neither side may "fix" the other's number to match.
enum ALPRRingPeek {
    /// A pin this close to a mapped camera is treated as standing ON it. Wide enough to absorb GPS
    /// scatter on both our own fix and the mapper's point, tight enough that the next camera down
    /// the block never claims the hit. SHARED WITH ANDROID - this one IS the same number.
    static let radiusMeters: Double = 25

    /// Outer diameter of a matched ring, derived from THIS platform's pin artwork.
    ///
    /// MapPin is not just its 28pt disc: it draws that disc under `.shadow(radius: 6)` in the pin's
    /// own tint, so the pin occupies a ~40pt tinted footprint (radius 14 + 6). The rim has to clear
    /// ALL of it. That is not a nicety in the headline case - an ALPR detection tints its pin
    /// ACABTheme.flockTone, the exact tone of a confirmed ring, so a rim landing inside that glow
    /// is not merely tight, it is invisible. (The 36pt first cut did exactly that: its rim sat at
    /// radius 18, a full 2pt INSIDE the glow.)
    ///
    /// ALPRDot strokes with `strokeBorder`, which draws INSIDE the frame, so a 48pt ring puts the
    /// rim's inner edge at radius 24 - 2.2 = 21.8pt: a ~1.8pt band of clean map between the edge of
    /// the glow and the start of the rim, which at 2x/3x is 3.6-5.4 device pixels of gap. Readable,
    /// and still comfortably inside a 44pt touch target's neighbourhood on the map.
    ///
    /// The pin's ping ring (the 28pt circle scaled to 1.9 = ~53pt, animated, dropped above 40 pins
    /// and under Reduce Motion) sweeps PAST this rim and fades to zero opacity as it goes, so the
    /// static rim stays readable between pulses. The ping is deliberately NOT resized: it belongs
    /// to the detection, not to the reference layer.
    static let diameter: CGFloat = 48

    /// Which of `rings` has at least one of `pins` within `radiusMeters`, as an array parallel to
    /// `rings`. Cheap by construction and never per frame. It runs on the cull path, and on a
    /// throttled pin-set change (see schedulePeekStamp) so an arriving pin lights its ring: both inputs
    /// are already viewport-culled and capped (500 rings, a few hundred pins), and the pins are
    /// bucketed into `radiusMeters`-tall latitude bands so each ring only tests the three bands
    /// that could possibly hold a match. Equirectangular distance, same model as
    /// ALPRStore.nearest(to:) - well under 1% error at this range.
    static func matches(rings: [CLLocationCoordinate2D], pins: [CLLocationCoordinate2D]) -> [Bool] {
        var out = [Bool](repeating: false, count: rings.count)
        guard !rings.isEmpty, !pins.isEmpty else { return out }
        let bandDeg = radiusMeters / 111_320.0     // metres -> degrees of latitude (uniform)
        var bands: [Int: [CLLocationCoordinate2D]] = [:]
        for p in pins where usable(p) {
            bands[Int((p.latitude / bandDeg).rounded(.down)), default: []].append(p)
        }
        guard !bands.isEmpty else { return out }
        let r2 = radiusMeters * radiusMeters
        for (i, ring) in rings.enumerated() where usable(ring) {
            // Longitude degrees shrink with latitude. Take the scale from the RING: anything close
            // enough to match is within 25 m of it, where the difference is far below the noise.
            let lonScale = 111_320.0 * cos(ring.latitude * .pi / 180)
            let band = Int((ring.latitude / bandDeg).rounded(.down))
            search: for b in (band - 1)...(band + 1) {
                guard let candidates = bands[b] else { continue }
                for p in candidates {
                    let dLat = (ring.latitude - p.latitude) * 111_320.0
                    let dLon = (ring.longitude - p.longitude) * lonScale
                    if dLat * dLat + dLon * dLon <= r2 { out[i] = true; break search }
                }
            }
        }
        return out
    }

    /// A coordinate that can be bucketed without trapping. A garbage lat/lon reaches the map only
    /// through a corrupt cache or a bad fix, and it must degrade to "no match", never to a crash
    /// converting a NaN or a wild Double to Int.
    private static func usable(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }
}

/// Quiet hollow ring for a known/mapped ALPR camera (default-on reference layer). Deliberately
/// un-animated and low-contrast so a mapped location never reads as a live detection.
/// The dot itself stays a plain shape with NO @State and NO .popover of its own: up to 500 are
/// on screen and the Map content closure rebuilds ~3 Hz off every detection publish, so a per-dot
/// popover would mean up to 500 presentation hosts torn down and rebuilt 3x a second - a main-thread
/// stall on its own, independent of any camera loop. Tapping is handled ONE level up: the call site
/// wraps this in a Button that flips a single shared @State (showALPRInfo), and one bottom overlay
/// renders the DeFlock credit callout. (The provenance is also credited permanently in the legend.)
private struct ALPRDot: View {
    /// Confirmed rings stay the established red. Unverified ones go amber and DASHED: colour alone
    /// is not a distinction for a red/green-deficient viewer, and this is a map where the whole
    /// point of the second tier is that you can tell it apart. Same shape and weight otherwise, so
    /// neither tier reads as a live detection.
    var confirmed: Bool = true
    /// A live detection pin is standing on this camera: draw the ring wide enough that its rim
    /// clears the pin's whole visual footprint - the 28pt disc AND the tinted shadow around it -
    /// which would otherwise swallow the ring completely. Same tone, same stroke, same hollow
    /// shape; the diameter moves AND the resting wash is dropped - the fill below says why.
    /// See ALPRRingPeek.diameter for the derivation. OPEN DIVERGENCE: Android's rememberAlprMarker
    /// keeps its wash at the peek size, so its standoff band is tinted where this one is bare map.
    var peek: Bool = false
    private var tone: Color { confirmed ? ACABTheme.flockTone : ACABTheme.warn }
    private var size: CGFloat { peek ? ALPRRingPeek.diameter : 14 }
    var body: some View {
        Circle()
            // The resting 14pt dot needs its wash to read at all. The peek ring must NOT have one:
            // the pin already fills the middle, and a wash would tint the very band of clean map
            // that ALPRRingPeek.diameter exists to open up between the pin's glow and this rim.
            .fill(peek ? Color.clear : tone.opacity(confirmed ? 0.20 : 0.10))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(tone.opacity(0.95),
                                           style: StrokeStyle(lineWidth: 2.2,
                                                              dash: confirmed ? [] : [2.6, 2.2])))
            .accessibilityLabel(confirmed ? "Known ALPR camera, manufacturer attributed"
                                          : "Community ALPR candidate, attribution not structured")
        // Bolder 2026-07-29 (user: rings washed out on the map). Still a HOLLOW STATIC ring -
        // the "never reads as a live detection" rule holds because detections are filled +
        // animated, not because this was faint. Keep in lockstep with Android rememberAlprMarker
        // and the legend swatch below - INCLUDING the peek size, which is the only thing that
        // tells a live hit at a mapped camera apart from a live hit nobody has mapped.
    }
}

// MARK: - Clustering

/// A group of located detections that fall in the same grid cell at the current zoom.
/// A single-member cluster is drawn as a normal pin; multi-member as a count bubble.
struct Cluster: Identifiable {
    var id: String
    let coord: CLLocationCoordinate2D
    let members: [Detection]

    init(id: String = UUID().uuidString, coord: CLLocationCoordinate2D, members: [Detection]) {
        self.id = id; self.coord = coord; self.members = members
    }
}

/// A count bubble for a multi-member cluster, sized up a touch for bigger clumps.
private struct ClusterBubble: View {
    let count: Int
    let uniformType: DeviceType?
    var simplified = false
    private var tint: Color { uniformType?.tint ?? ACABTheme.text }
    private var diameter: CGFloat {
        switch count {
        case ..<10:  return 34
        case ..<50:  return 40
        case ..<200: return 46
        default:     return 52
        }
    }
    var body: some View {
        ZStack {
            if !simplified {
                Circle().fill(tint.opacity(0.22)).frame(width: diameter + 10, height: diameter + 10)
            }
            Circle().fill(ACABTheme.bg2).frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(tint, lineWidth: 2))
                .shadow(color: tint.opacity(simplified ? 0 : 0.5), radius: 5)
            Text("\(count)")
                .font(ACABTheme.display(count < 100 ? 15 : 13, weight: .bold))
                .foregroundStyle(ACABTheme.text).monospacedDigit()
        }
    }
}

/// Bottom sheet listing the detections inside a tapped cluster; pick one to open it.
private struct ClusterListSheet: View {
    let cluster: Cluster
    let onPick: (Detection) -> Void
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    /// Rows render in the order the CALLER built, never re-sorted here. An infra pin hands over
    /// the rows behind `InfraPin.orderedMemberIDs(lastSeen:)`: priority first, then most recent
    /// on the stamps read at the tap. That is the same rule that chose the pin the finger landed
    /// on, so that row is the one on top, except that a same-priority member heard since the pin
    /// was drawn can top the sheet a moment before the next snapshot redraws the pin as that
    /// member. A count bubble hands over store order (the feed's newest-first). Re-sorting by
    /// lastSeen alone threw the priority half away, so a tap on a body-cam pin could open a sheet
    /// led by a fresher unknown row, while Android's twin sheet renders `clusterMembers`
    /// untouched: the list orderSameSpotMembers (MapProjection.kt) ordered for the tapped pin on
    /// the stamps its draw loop read at the last rebuild (MapScreen.kt). So the same tap read
    /// differently on the two phones. It was also a sort per body eval, two `lastSeenDate`
    /// lookups per comparison, inside a view that holds `ble` and therefore re-runs at the ~3 Hz
    /// publish, for a list that cannot change while the sheet is open.
    var body: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(cluster.members.count) here")
                                .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                            Kicker("CLUSTERED AT THIS SPOT")
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ACABTheme.dim)
                                .frame(width: 32, height: 32)
                                .background(ACABTheme.bg2, in: Circle())
                                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close cluster")
                    }
                    .padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(cluster.members.enumerated()), id: \.element.id) { i, d in
                            Button { onPick(d) } label: {
                                DetectionRow(detection: d, timeBasis: ble.timeBasis(for: d.id))
                            }
                                .buttonStyle(.plain)
                            if i < cluster.members.count - 1 { Divider().overlay(ACABTheme.line) }
                        }
                    }
                    .panel()
                }
                .padding(ACABTheme.pad)
            }
        }
        .preferredColorScheme(.dark)
    }
}
