import SwiftUI
import Combine   // the file-scope Timer.publish(...).autoconnect() relies on SwiftUI's re-export; Xcode 27 warns on the @State form of it elsewhere
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
///
/// The case order is the segment order. The raw values "recent" and "all" are persisted under
/// `map.historyScope` and must never change; "active" was added in front of them.
enum MapHistoryScope: String, CaseIterable, Identifiable {
    case active
    case recent
    case all

    /// SHARED WITH ANDROID - this one IS the same number: MAP_RECENT_WINDOW_MS in
    /// AcabBleManager.kt. Both suites pin the literal (900 here, 15 * 60_000L there) rather than
    /// the constant, because the empty-state copy, the spoken map summary ("fifteen minutes") and
    /// docs/map-performance.md promise 15 minutes in hardcoded copy that a constant edit would
    /// not touch. Active reuses `activeNearbyInterval` (BLEManager.swift), the one window Status,
    /// Live Mode and the dossier share, so it has no constant of its own here.
    static let recentSeconds: TimeInterval = 15 * 60
    var id: String { rawValue }
    /// Spoken name of each scope segment (its VoiceOver label). The drawn label is
    /// mapScopeSegmentLabel(_:count:).
    var label: String {
        switch self {
        case .active: return "Active"
        case .recent: return "Recent"
        case .all:    return "All history"
        }
    }
}

/// Recent and Active are intentionally strict about evidence quality: an exact or reconstructed
/// instant can be compared with the 15-minute (Recent) or `activeNearbyInterval` (Active) window;
/// an unknown time or a bracket is available under All only. A stamp ahead of the clock is out of
/// both windows. Kept pure for cross-platform boundary tests and deterministic dense-map
/// regression tests.
func mapHistoryScopeIncludes(lastSeen: Date?, basis: TimeBasis,
                             scope: MapHistoryScope, now: Date) -> Bool {
    let window: TimeInterval
    switch scope {
    case .all:    return true
    case .recent: window = MapHistoryScope.recentSeconds
    case .active: window = activeNearbyInterval
    }
    switch basis {
    case .exact, .reconstructed: break
    case .bracketed, .unknown: return false
    }
    guard let lastSeen else { return false }
    let age = now.timeIntervalSince(lastSeen)
    return age.isFinite && age >= 0 && age <= window
}

/// The Map's scope membership as the view applies it: `mapHistoryScopeIncludes`, plus the
/// sample-data bypass on every windowed scope (Active and Recent). In sample data every row counts
/// and draws as active, the same bypass Status (`dashboardSnapshot`) and the Log
/// (`DetectionLogLens.activeIDs`) apply to the 45 s window: the seed stamps its rows once, so
/// without it the Map alone would fall to "active · 0" 45 s into the tour while the other two tabs
/// still show every row (C10 / C11). Recent takes the same bypass because Active is a subset of
/// Recent: with it on Active alone, the tour read "active · 5 / recent · 0" 15 minutes in and the
/// default Recent scope drew an empty map (MAP-01). So in sample data active <= recent <= all
/// holds at any age. All is unchanged (it keeps every row anyway). TWIN: Android
/// mapHistoryIncludes / mapScopeCounts in MapProjection.kt apply the same bypass to the Map
/// Active and Recent memberships and tallies.
func mapScopeIncludes(lastSeen: Date?, basis: TimeBasis, scope: MapHistoryScope,
                      now: Date, isDemoMode: Bool) -> Bool {
    if isDemoMode, scope != .all { return true }
    return mapHistoryScopeIncludes(lastSeen: lastSeen, basis: basis, scope: scope, now: now)
}

/// The drawn label of each scope segment. TWIN: Android mapScopeSegmentLabel in MapProjection.kt;
/// the drift row "map scope segment labels" (contract 11.2) compares the two declarations, so
/// keep this exact shape: one switch, a literal middle dot, no comment inside the body.
func mapScopeSegmentLabel(_ scope: MapHistoryScope, count: Int) -> String {
    switch scope {
    case .active: return "active · \(count)"
    case .recent: return "recent · \(count)"
    case .all:    return "all · \(count)"
    }
}

/// The legend card's headline. Counts are plain Ints, never `.formatted()`: session counters
/// stay ungrouped. TWIN: Android mapHonestyHeadline in MapProjection.kt; the drift row "map
/// honesty headline" (contract 11.2) reads this single-expression body, so no `return`.
///
/// PLATFORM DIFFERENCE in the numbers passed in (MapSnapshot.withoutLocation): a Remote ID drone
/// with ONLY an operator coordinate (no drone position and no observer fix) has no `mapCoord` on
/// iOS, so it counts as "without a location", joins no segment count and draws nothing. Android's
/// mapRepresentationCoord (MapScreen.kt) falls back to the operator position for a drone, so there
/// it counts as "on the map" and in the segments and draws its operator marker. Every other row
/// splits the same way on both phones.
func mapHonestyHeadline(onMap: Int, withoutLocation: Int) -> String {
    "\(onMap) on the map · \(withoutLocation) without a location"
}

/// The Active membership of a non-increasing stamp list at `now`, as the index range of the
/// stamps with 0 <= now - stamp <= activeNearbyInterval: exactly `mapHistoryScopeIncludes(.active)`
/// over trustworthy stamps. `lo` counts the stamps later than `now` (a prefix, because the list
/// is non-increasing); `hi` is `activeBoundary`, the first stale index. Two binary searches, no
/// allocation. A window, not a one-sided boundary: a future stamp ENTERS the membership when the
/// clock passes it, which moves `lo` while the boundary stays put (contract 5.3).
func activeWindow(_ stamps: [Date], now: Date) -> Range<Int> {
    var low = 0, high = stamps.count
    while low < high {
        let mid = (low + high) / 2
        if stamps[mid] > now { low = mid + 1 } else { high = mid }
    }
    let hi = activeBoundary(stamps, now: now)
    return low..<max(low, hi)
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

/// Where the map's camera must centre so a tapped pin stays in view above the compact dossier
/// sheet (P2-4, R19; HIG Maps: keep the location visible while a place card is up). The sheet
/// opens at the medium detent, about half the window, so only the strip between the map's top
/// edge (`mapTop`, window coordinates) and `sheetTop` stays uncovered. The pin's screen row is
/// read off the current `region` (latitude is linear over a city-block span); if it already
/// sits inside the strip, inset by `margin` for the pin's own artwork, nil: the camera does not
/// move for a pin that was visible. Otherwise the centre that puts the pin on the strip's
/// midline, at the same span and the same longitude: a vertical pan, never a zoom. nil as well
/// when the geometry has not been measured (a zero-height map) or the strip is too thin for a
/// pin and its margin, so a tiny window never gets a wild pan. iOS only: Android's compact
/// dossier is a full-screen overlay (P2-4 leaves it so).
func mapCenterKeepingPinVisible(pin: CLLocationCoordinate2D, region: MKCoordinateRegion,
                                mapTop: CGFloat, mapHeight: CGFloat, sheetTop: CGFloat,
                                margin: CGFloat = 32) -> CLLocationCoordinate2D? {
    guard mapHeight > 0, region.span.latitudeDelta > 0 else { return nil }
    let stripTop = mapTop + margin, stripBottom = sheetTop - margin
    guard stripBottom > stripTop else { return nil }
    let degreesPerPoint = region.span.latitudeDelta / Double(mapHeight)
    let centerY = mapTop + mapHeight / 2
    let pinY = centerY - CGFloat((pin.latitude - region.center.latitude) / degreesPerPoint)
    if pinY >= stripTop && pinY <= stripBottom { return nil }
    let targetY = (stripTop + stripBottom) / 2
    let centerLatitude = pin.latitude - Double(centerY - targetY) * degreesPerPoint
    return CLLocationCoordinate2D(latitude: centerLatitude, longitude: region.center.longitude)
}

// MARK: Floating Map controls
// The Map's three floating buttons (the legend's info button at the lower left, Map options and
// Center on my location at the lower right) and the legend card they open. TWIN: android
// MapScreen.kt MAP_CONTROL_TARGET, MAP_CONTROL_MARGIN, MAP_CONTROL_SPACING and
// MAP_CONTROLS_RESERVE. The sizes are per platform, each from its own guideline: 44pt is the HIG's
// minimum target here; Android's 40dp small FAB pads its own target to 48dp.

/// Visual diameter AND hit target of each floating Map button: the HIG's 44pt minimum.
let mapControlSize: CGFloat = 44
/// Gap between the map region's bottom edge and the floating buttons. The horizontal gutter is
/// `ACABTheme.pad`.
let mapControlMargin: CGFloat = 8
/// Between the two stacked buttons at the lower right.
let mapControlSpacing: CGFloat = 8
/// The map's CONSTANT bottom safe-area inset: the buttons row plus the HIG's 10pt above it, so
/// MapKit's logo and Legal line (drawn at the map's bottom-left, where the info button sits) rest
/// above the lowest custom UI and never move with it (HIG Maps). A constant, never state, never
/// measured, never animated: an animated SHRINKING bottom inset laid the MKMapView out in the
/// old, smaller safe region for the animation, and MKMapView keeps its centre across that bounds
/// change, so each legend collapse threw the whole map up and back with a small zoom creep; and a
/// programmatic camera (the one-shot fit, or following the user after Locate) refit to every new
/// inset. Nothing on the Map changes this value, so there is nothing for MapKit to re-frame.
let mapFloatingControlsInset: CGFloat = mapControlMargin + mapControlSize + 10
/// MapKit's logo + Legal line, which sits just above `mapFloatingControlsInset`. The legend card
/// and the bottom notices rest above it, so the attribution stays visible and still with either
/// showing.
let mapAttributionClearance: CGFloat = 28
/// The empty banner's bottom padding: the lower-right stack at its tallest (two buttons) plus 8,
/// so the banner centres above it and its actions never land under a button. TWIN: android
/// MapScreen.kt's empty card padding (MAP_FLOATING_STACK_HEIGHT + 8.dp while the two buttons
/// stack, never less than the controls row and the OSM credit above it).
let mapFloatingStackReserve: CGFloat = mapControlMargin + 2 * mapControlSize + mapControlSpacing + 8

/// The info button's spoken value: "collapsed" or "expanded", plus ", loading camera data" while
/// the known-ALPR dataset downloads (the button's spinner badge, which VoiceOver cannot see).
/// A download never opens the card. TWIN: android MapScreen.kt `mapLegendStateDescription`, the
/// same outputs byte for byte.
func mapLegendAccessibilityValue(open: Bool, downloading: Bool) -> String {
    let state = open ? "expanded" : "collapsed"
    return downloading ? "\(state), \(MapTabView.legendLoadingValue)" : state
}

/// The legend card's height cap, as a share of the map region (`regionHeight`, from the bottom of
/// the navigation bar to the top of the tab bar, the floating scope header included), so the map
/// keeps the rest at every text size. `topInset` is the scope header's height (it floats over the
/// region's top edge since P3-1) and `bottomInset` is the card's own bottom padding (it rests above
/// the info button and MapKit's logo + Legal line). Unbounded until the first measurement lands
/// (`regionHeight` 0).
///
/// 55% at default sizes: under the sample-data banner, the scope picker and the filter chips, 45%
/// was too short for the six category keys plus Known ALPR and the credit, so the keys scrolled
/// with the last one below the fold. The card hugs its content (HeightCap), so the larger cap
/// costs map only when the keys need it. 45% at accessibility sizes, where the keys scroll anyway
/// and the map keeps its floor. Either cap is clamped to the room between `topInset` and
/// `bottomInset` (less an 8pt gap), so the card does not climb under the scope header when it can
/// help it. The share is taken of the WHOLE region, header included: taking it of the region
/// less the header (the first P3-1 build) cost the card 55% of the header's height and made the
/// keys scroll at content size large on an iPhone 17 Pro, where the docked header had shown them
/// whole.
///
/// At accessibility sizes the honesty headline is never cut: the cap never goes below the
/// measured header row (`summaryHeight`) plus room for one 44pt key row inside legendScroll's 12pt
/// top and bottom padding, plus the card's own 16pt bottom padding. Where the space above the
/// card's bottom padding is shorter than that floor (the sample banner and the chips at AX5 on an
/// iPhone 17 Pro), the space bounds the card and `legendCard` scrolls the header with the keys:
/// the floor lifts the cap above the share, never above the room, so the card's top edge stops
/// 8pt under the floating pills instead of running up over the chips (the R21 review measured
/// the unbounded floor putting the card's fill 3.3pt over the ALL and ALPR chips there). TWIN:
/// android MapScreen.kt `mapLegendCardMaxPx`, whose floor still wins over its room clamp (not
/// changed with R21).
func mapLegendCardCap(regionHeight: CGFloat, summaryHeight: CGFloat, accessibilitySize: Bool,
                      topInset: CGFloat = 0, bottomInset: CGFloat) -> CGFloat {
    guard regionHeight > 0 else { return .infinity }
    let room = max(0, regionHeight - topInset - bottomInset - 8)
    let share = regionHeight * (accessibilitySize ? 0.45 : 0.55)
    let headlineFloor = summaryHeight + 12 + 44 + 12 + 16
    return accessibilitySize ? min(max(share, headlineFloor), room) : min(share, room)
}

/// The floating buttons' glass is tinted toward the page (`ACABTheme.bg` at this alpha), so the
/// crimson glyph reads on it over any tile. Untinted, the glass took the map's colour: on the
/// 2026-09-26 shots the glyph measured 1.66 to 2.22:1 on the three buttons, under both the 3:1
/// non-text floor and the 4.5:1 text floor (HIG Materials: "use vibrant colors on top of
/// materials"). Modelled as bg composited at this alpha over the backdrop the untinted glass
/// showed: 0.55 over the lightest button backdrop in the shots (86, 109, 138) lands near
/// (39, 49, 62), where `tint` clears 4.5:1; MapGlassTintTests pins the 3:1 floor over the
/// darkest and the lightest tile of the forced-dark map. The legend card takes the same tint
/// and keeps the palette's inks on it (`legendCard`): on the P1-2 verify shots (2026-09-26) the
/// system's vibrant secondary label read 2.7 to 3.2:1 over the downtown tiles, untinted AND
/// tinted (vibrant secondary is dim by design on a dark backdrop), under the 4.5:1 floor and
/// below the palette `dim` it replaced; `dim` on the tinted glass models at 5.5:1 over the
/// lightest tile (MapGlassTintTests). Android's small FABs are tonal and measure 7.26:1 on their
/// own; they take no tint.
let mapGlassTintAlpha: Double = 0.55

/// The surface of the Map's floating buttons, legend card, scope segments pill and unselected
/// category chips: Liquid Glass on iOS 26 (Apple Maps floats glass controls on a full-bleed map),
/// the regular material on iOS 18, and the opaque map-information surface under Reduce
/// Transparency or higher contrast. No stroke, no glow. Both the glass and the material branch
/// are tinted toward the page by `mapGlassTintAlpha`; `interactive` is the buttons' and the
/// chips' glass (it responds to touch), the text-heavy card and the segments pill take the
/// regular variant (Materials HIG). The branch is at the view level. Every piece is its own
/// pill: nothing on the Map draws a full-width surface any more (R21).
private struct MapControlSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || TypePrefs.shared.highContrast {
            content.background(ACABTheme.mapInfoBackground, in: shape)
        } else if #available(iOS 26, *) {
            let tinted = Glass.regular.tint(ACABTheme.bg.opacity(mapGlassTintAlpha))
            content.glassEffect(interactive ? tinted.interactive() : tinted, in: shape)
        } else {
            // The tint sits between the material and the content: the outer background is drawn
            // further back, so the material stays the blur and the tint darkens it.
            content.background(ACABTheme.bg.opacity(mapGlassTintAlpha), in: shape)
                .background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    func mapControlSurface<S: Shape>(_ shape: S, interactive: Bool = true) -> some View {
        modifier(MapControlSurface(shape: shape, interactive: interactive))
    }
}

/// A category chip's capsule (R21): the selected chip is its category hue, opaque, and takes no
/// glass (the fill is the selection cue, and glass lensing at the rim of an opaque fill would
/// only blur its edge); every other chip is the interactive map-control surface, so the tiles
/// show through it like the floating buttons. A branch, not one chain with a clear fill, so the
/// selected chip carries no glass effect at all.
private struct MapChipSurface: ViewModifier {
    let active: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.background(tint, in: Capsule())
        } else {
            content.mapControlSurface(Capsule(), interactive: true)
        }
    }
}

/// Proposes at most `cap` points of height to its one child and reports the child's own height,
/// never more. `.frame(maxHeight:)` reports min(cap, proposal) instead, so the legend card under
/// it would always draw at the cap and cover the map for nothing.
private struct HeightCap: Layout {
    var cap: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let h = min(proposal.height ?? cap, cap)
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: h))
        return CGSize(width: size.width, height: min(size.height, h))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The caption under the Map options "lower-confidence pins" toggle. Says what the tier MEANS
/// rather than naming it, because "unverified" invites the reading that we checked and it failed.
/// Nobody checked. `count` is the lower-confidence pin count, drawn with grouped digits; one pin
/// reads "pin is", every other count "pins are". TWIN: android MapScreen.kt's lower-confidence
/// toggle line, the same words.
func alprLowerConfidenceLine(count: Int, showing: Bool) -> String {
    let n = count.formatted()
    let one = count == 1
    return showing
        ? "showing \(n) \(one ? "pin" : "pins") without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras."
        : "\(n) lower-confidence \(one ? "pin is" : "pins are") hidden. some are not cameras."
}

/// Does any drawn drone overlay carry an operator marker? The Map draws OperatorPin for each
/// overlay whose detection has a pilotCoordinate, so the legend's "Drone operator" key shares that
/// gate. Called once per snapshot pass over the overlay feed. TWIN: android MapScreen.kt
/// `mapOperatorPinFlag` (counted in its marker rebuild pass).
func mapHasOperatorPins<S: Sequence>(_ drones: S) -> Bool where S.Element == Detection {
    drones.contains { $0.pilotCoordinate != nil }
}

/// Instruments-only timing for the two map stages. INTERVALS ship; their count ARGUMENTS are
/// DEBUG-only, because os_signpost arguments land in the OS unified log, which this app cannot
/// clear (see the note at the MapProjection `.end` call). Nothing here ever carries a coordinate,
/// a MAC or a name.
private let mapPerformanceLog = OSLog(subsystem: "com.soyboi.Beacons", category: "MapPerformance")
/// Visible-map maintenance only: expires the Recent lens and advances age styling while a
/// disconnected/quiet scanner emits no detections (the Active lens has its own 1 s tick,
/// `mapActiveTimer`). It is intentionally slow; live arrivals use the adaptive leading/trailing
/// refresh path instead.
private let mapMaintenanceTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
/// The Active segment's clock; see the handler (`MapTabView.mapFed`). Two binary searches per
/// second while the map is visible (two more under the Active scope, over `otherActiveStamps`),
/// a state write only when the Active count moves, a rebuild only under the Active scope when its
/// membership moves.
private let mapActiveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

/// Located detections on a dark map, filterable by category. Fixed installs
/// (Flock/body-cam/tracker) sit at our position when we heard them; drones plot
/// their own broadcast position plus the operator's.
struct MapTabView: View {
    /// The Map options "phone breadcrumb trails" toggle's subline. BYTE-IDENTICAL to android
    /// MapScreen.kt `MAP_BREADCRUMB_TOGGLE_SUBLINE`.
    static let breadcrumbToggleSubline = "draws your phone's path while the beacon kept hearing a tracker. kept in memory for this session only."
    /// The info button's spoken suffix while the known-ALPR dataset downloads (see
    /// `mapLegendAccessibilityValue`). BYTE-IDENTICAL to android MapScreen.kt
    /// `MAP_LEGEND_LOADING_STATE`.
    static let legendLoadingValue = "loading camera data"

    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var alpr: ALPRStore        // known-ALPR reference layer (on by default, OSM/DeFlock)
    @State private var filter: String?           // category key: ALPR / DRONE / BODY CAM / TRACKER
    // NEVER fall back to .automatic: it re-frames the camera to fit the CONTENT, and the ALPR dots are
    // themselves computed FROM the camera region (onMapCameraChange -> refreshALPRVisible -> alprVisible
    // -> Annotations -> content changed -> .automatic re-frames -> camera changed -> ...). That closes an
    // unbounded render loop that pegs the main thread (a cpu_resource spin, not a crash). A fixed fallback
    // region breaks the content->camera edge; `recenterButton` (the floating stack) drives the camera explicitly.
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
    @State private var legendExpanded = false     // the legend card starts closed (not persisted)
    @State private var showMapOptions = false     // one readable sheet for display and reference layers
    /// Height of the region between the navigation bar and the tab bar, the floating scope header
    /// included, written only by the `onGeometryChange` in `mapLayout`. Read by `legendCardCap`
    /// (with `scopeHeaderHeight` as the top inset); 0 until the first measurement.
    @State private var mapRegionHeight: CGFloat = 0
    /// Height of the floating scope header (`scopeHeader`), written only by the `onGeometryChange`
    /// on the header in `mapLayout`. It changes with the text size and never animates, and NOTHING
    /// feeds it back into MapKit: the map's top safe-area inset is the header's own layout height,
    /// laid by SwiftUI (`safeAreaInset`), not this state. Read by `legendCardCap`, so the card does
    /// not climb under the header, and by the empty banner, so it centres in the visible map; 0
    /// until measured.
    @State private var scopeHeaderHeight: CGFloat = 0
    /// The Map view's frame in window coordinates, written only by the `onGeometryChange` in
    /// `map(_:)`. Read by `keepPinVisibleUnderSheet` (P2-4): its top edge and height place the
    /// tapped pin above the medium dossier sheet (the camera region maps onto this layout frame;
    /// the tiles the map paints under the floating tab bar and under the scope header lie outside
    /// it). Zero until the first measurement.
    @State private var mapGlobalFrame: CGRect = .zero
    /// Height of the legend card's header row (the honesty line and the close control), written
    /// only by the `onGeometryChange` in `legendCard`. Read by `legendCardCap`, so the card never
    /// caps that headline away at accessibility sizes; 0 until measured.
    @State private var legendSummaryHeight: CGFloat = 0
    /// VoiceOver focus: the card's header row after an open, the info button after a close by
    /// the button, the close control, a map tap or the escape gesture.
    @AccessibilityFocusState private var legendFocused: Bool
    @AccessibilityFocusState private var legendButtonFocused: Bool
    // One-shot camera fit to the located detections' bounding region (see fitToDetections).
    // Also set when a dossier handoff places the camera, so the fit never yanks it away.
    @State private var didFitToDetections = false
    /// The main Map's "phone breadcrumb trails" option starts OFF (decision B1): a user's own or a
    /// family member's tag (a Tile, a partner's AirTag) otherwise draws a trail that reads as being
    /// followed, and the trails clutter the main Map. Only the fallback for a user who never flipped
    /// the toggle: a stored choice wins. Collection is unchanged, and the tracker's dossier still
    /// shows its trail. TWIN: Android MAP_SHOW_BREADCRUMBS_DEFAULT in MapScreen.kt.
    static let showBreadcrumbsDefault = false
    @AppStorage("map.showBreadcrumbs") private var showBreadcrumbs = MapTabView.showBreadcrumbsDefault   // tracker trails on the main map (persisted)
    @AppStorage("map.showLabels") private var showLabels = false             // pin captions, off for a cleaner map (persisted)
    @AppStorage("map.historyScope") private var historyScopeRaw = MapHistoryScope.recent.rawValue
    @State private var alprChecking = false       // manual "Check for Updates" in flight (double-tap guard)
    @State private var alprJustChecked = false    // brief window after a manual check: row shows the outcome
    @Environment(\.horizontalSizeClass) private var hSize   // T5: dossier as inspector on regular width
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize   // accessibility sizes: one-column legend, the card's headline floor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion   // the legend card opens (fade only) and the camera fits, flies and recenters without animation

    /// The expensive map projection is state, not a body-local computed value. BLEManager remains
    /// an ObservableObject used by the surrounding chrome, but unrelated publishes cannot force a
    /// store walk or MapKit content rebuild. Detection-driven refreshes are coalesced below.
    @State private var snapshot: MapSnapshot = .empty
    @State private var mapRenderRevision: UInt64 = 0
    @State private var isMapVisible = false
    @State private var suppressNextScopeRefit = false
    /// The Active count the 1 s tick measured since the last install, or nil when it has not
    /// moved from `snapshot.activeCount`. Reset by every `installFreshSnapshot`.
    @State private var activeTickCount: Int?

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
    /// At least one drawn ring is peeking (a live pin stands on a mapped camera). State, written
    /// only by `installALPRVisible`, so the legend's live-hit row never scans `alprVisible`.
    @State private var alprPeeking = false

    /// The ONE writer of `alprVisible`: installs a changed set, keeps `alprPeeking` in step (the
    /// contains-scan runs only on a change), and bumps the render revision. An unchanged set
    /// costs one array compare and zero @State writes.
    private func installALPRVisible(_ next: [ALPRPoint]) {
        guard next != alprVisible else { return }
        alprVisible = next
        let peeking = next.contains(where: \.peek)
        if peeking != alprPeeking { alprPeeking = peeking }
        bumpMapRenderRevision()
    }

    /// Recompute the viewport-culled ALPR points. Called on the events that change its inputs,
    /// never in body. Clears out when the layer is off or the map is zoomed too far out.
    private func refreshALPRVisible(region requestedRegion: MKCoordinateRegion? = nil) {
        // HYSTERESIS, not a single cliff. A lone 0.35 threshold can flip-flop across the boundary
        // (dots appear -> content grows -> zoom crosses back -> dots vanish -> ...), re-invalidating
        // body forever. Separate on/off thresholds make that physically impossible.
        let activeRegion = requestedRegion ?? region
        let limit = alprVisible.isEmpty ? 0.30 : 0.40
        guard alpr.enabled, activeRegion.span.latitudeDelta < limit else {
            if !alprVisible.isEmpty { installALPRVisible([]) }
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
        installALPRVisible(next)
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
        installALPRVisible(next)
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
        /// ClusterListSheet draws one DetectionRow per member, and no row prints an age of any
        /// kind: the LOC chip, the GPS-fix age a row used to carry, now shows in the dossier only
        /// (contract 3.6), so the row order is the whole recency cue the sheet has.
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
        /// The legend card's qualifier line names this separately from `viewportCulled` so
        /// aggregation and a cap are never reported as one number, and neither is ever mistaken
        /// for evidence deletion.
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
        /// At least one drawn drone overlay carries an operator marker (mapHasOperatorPins over
        /// `drones`, the same feed that draws them), so the legend names the person marker. Set
        /// in the snapshot pass, never computed in a body.
        let hasOperatorPins: Bool
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
        /// The located rows in scope AND category: the honesty headline's "N on the map".
        let filteredLocated: Int
        /// The located, category-passing rows each scope segment would show. `activeCount` is
        /// `activeWindowAtBuild.count`, or `allCount` in sample data (`activeIsSampleData`); the
        /// 1 s tick (`mapActiveTimer`) moves the drawn Active count between rebuilds.
        let activeCount: Int
        let recentCount: Int
        let allCount: Int
        /// Unlocated rows that pass the category chip AND the selected scope (the row's own
        /// stamp and last-seen basis at this snapshot's `now`): the headline's "M without a
        /// location". The same rule as Android's mapScopeCounts, so both phones name one number,
        /// except for an operator-only Remote ID drone (see mapHonestyHeadline).
        let withoutLocation: Int
        /// Trustworthy (`.exact` / `.reconstructed`) stamps of the located, category-passing rows
        /// that were not stale at build time, sorted descending once per snapshot. A stamp stale
        /// at build time cannot re-enter the window before the next rebuild: the clock only moves
        /// forward, a re-hearing publishes (and so rebuilds), and the 30 s maintenance tick
        /// rebuilds after a wall-clock step back.
        let activeStamps: [Date]
        /// `activeWindow(activeStamps, now:)` at build time; the tick compares against it.
        let activeWindowAtBuild: Range<Int>
        /// Under the Active scope only (empty otherwise): the same trustworthy, not-yet-stale
        /// stamps, for the rows OUTSIDE `activeStamps` whose Active membership still moves a
        /// drawn number: unlocated rows that pass the category chip (`withoutLocation`, the
        /// headline's "M without a location") and located rows the category chip hides (the other
        /// category chips, the ALL chip and `totalLocated`, which also gates the empty-map card).
        /// Sorted descending once per snapshot, like `activeStamps`. The 1 s tick rebuilds when
        /// their window moves too, so every Active-dependent number follows the clock within a
        /// second, as Android's does (MapScreen's scopeCounts, catCounts and showEmptyCard all
        /// read the 1 s Active clock).
        let otherActiveStamps: [Date]
        /// `activeWindow(otherActiveStamps, now:)` at build time; the tick compares against it.
        let otherActiveWindowAtBuild: Range<Int>
        /// Built in sample data, where every row is active (`mapScopeIncludes`): `activeStamps` is
        /// empty and the 1 s tick leaves the Active count alone, because no stamp can age out.
        let activeIsSampleData: Bool

        static let empty = MapSnapshot(
            totalLocated: 0, retainedLocated: 0,
            representedRows: 0, markerCount: 0, mergedRows: 0, viewportCulled: 0, droppedRows: 0,
            counts: [:], drones: [], infra: [], clusters: [], trackerTrails: [],
            pinsAnimated: false, simplifiedArtwork: false, pins: PinSet(items: []),
            hasStalePins: false, hasOperatorPins: false, spokenFilter: nil, spokenScope: .recent,
            spokenLocationDenied: false,
            filteredLocated: 0, activeCount: 0, recentCount: 0, allCount: 0, withoutLocation: 0,
            activeStamps: [], activeWindowAtBuild: 0..<0,
            otherActiveStamps: [], otherActiveWindowAtBuild: 0..<0, activeIsSampleData: false)

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
        /// signal-only publish, so keeping them exact costs the gate nothing. The legend card's
        /// honesty lines read them outside the gate, from the freshly installed snapshot. The same
        /// reasoning puts the three `spoken*` lens fields here: that label names the filter, the
        /// scope and the permission story too, and a filter change that lands on an identical pin
        /// set moves none of the counts. The segment counts, the headline counts and the Active
        /// stamps are NOT in the key: nothing inside the gate reads them.
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
        // Read once, like the clock: the Active membership, its count and the tick's gate all
        // follow this one reading (mapScopeIncludes' sample-data bypass).
        let sampleData = ble.demoMode
        var retainedLocated = 0
        var total = 0
        var filteredLocated = 0, withoutLocation = 0, recentCount = 0, allCount = 0
        var activeStamps: [Date] = []
        var otherActiveStamps: [Date] = []
        // Only the Active scope draws its tallies from the Active membership, so only it pays
        // for the second stamp list (MapSnapshot.otherActiveStamps).
        let collectOtherActive = historyScope == .active && !sampleData
        /// A row's stamp when it can still leave the Active window before the next rebuild: the
        /// same trustworthy, not-stale-now rule `activeStamps` uses below.
        func activeStamp(_ seen: Date?, _ basis: TimeBasis) -> Date? {
            guard let seen, !lastSeenIsStale(seen, now: now) else { return nil }
            switch basis {
            case .exact, .reconstructed: return seen
            case .bracketed, .unknown: return nil
            }
        }
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
            // Stamp, basis and watched state are resolved for EVERY row now, located or not:
            // the unlocated ones feed `withoutLocation` and the out-of-scope located ones feed
            // the segment counts. Dictionary and set lookups, O(1) each, still ONE pass.
            let seen = ble.lastSeenDate(for: d.id)
            let basis = ble.timeBasis(for: d.id, stamp: seen)
            let currentlyWatched = ble.isWatched(d)
            let inCategory = detectionMatchesCategory(type: d.type, category: filter,
                                                      isCurrentlyWatched: currentlyWatched)
            let inScope = mapScopeIncludes(lastSeen: seen, basis: basis, scope: historyScope,
                                           now: now, isDemoMode: sampleData)
            guard let c = mapCoord(for: d) else {
                if inCategory && inScope { withoutLocation += 1 }
                if collectOtherActive, inCategory, let stamp = activeStamp(seen, basis) {
                    otherActiveStamps.append(stamp)
                }
                continue
            }
            retainedLocated += 1
            if collectOtherActive, !inCategory, let stamp = activeStamp(seen, basis) {
                otherActiveStamps.append(stamp)
            }
            if inCategory {
                allCount += 1
                // Through mapScopeIncludes, so the Recent tally takes the same sample-data bypass
                // as the Recent membership (MAP-01).
                if mapScopeIncludes(lastSeen: seen, basis: basis, scope: .recent, now: now,
                                    isDemoMode: sampleData) {
                    recentCount += 1
                }
                // Only the stamps not stale NOW: see MapSnapshot.activeStamps for why a stamp
                // stale at build time cannot re-enter the window before the next rebuild. None in
                // sample data, where the Active count is allCount and the tick stands down.
                if !sampleData, let stamp = activeStamp(seen, basis) { activeStamps.append(stamp) }
            }
            guard inScope else { continue }
            total += 1
            counts[d.type.category, default: 0] += 1
            if d.type != .watched, currentlyWatched {
                counts[DeviceType.watched.category, default: 0] += 1
            }
            guard inCategory else { continue }
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
        // Bounded to the not-yet-stale trustworthy candidates, not the whole store.
        activeStamps.sort(by: >)
        let activeWindowAtBuild = activeWindow(activeStamps, now: now)
        otherActiveStamps.sort(by: >)
        let otherActiveWindowAtBuild = activeWindow(otherActiveStamps, now: now)
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
            hasOperatorPins: mapHasOperatorPins(drones.lazy.map(\.detection)),
            spokenFilter: filter, spokenScope: historyScope,
            spokenLocationDenied: ble.locationDenied && !ble.demoMode,
            filteredLocated: filteredLocated,
            activeCount: sampleData ? allCount : activeWindowAtBuild.count,
            recentCount: recentCount, allCount: allCount, withoutLocation: withoutLocation,
            activeStamps: activeStamps, activeWindowAtBuild: activeWindowAtBuild,
            otherActiveStamps: otherActiveStamps, otherActiveWindowAtBuild: otherActiveWindowAtBuild,
            activeIsSampleData: sampleData)
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
        if activeTickCount != nil { activeTickCount = nil }
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

    // MARK: Body, in stages
    // ONE modifier chain holding ten overloaded onChange calls is more than the CI compiler
    // (Xcode 26.6) type-checks in time; RootView needed the same split. So the body is built in
    // stages, each a computed view, and every onChange closure is fully typed with its head on
    // one line.

    /// Stage 1, the layout: the full-bleed map region with the scope header (the segments pill
    /// and the chip row, each pill its own surface with the map between them, R21) floating over
    /// its top edge and three overlays floating on the map (the ALPR notices at the bottom; the
    /// legend's info button and its card at the lower left; Map options and Center on my location
    /// at the lower right), and the navigation bar with the title alone. The map fills the region
    /// and runs under the header and the tab bar (P3-1 of the 2026-09-26 UI review; HIG Layout:
    /// extend full-screen content under the bars). Its safe area is the header's own layout
    /// height at the top (a `safeAreaInset` on the map itself, so MapKit's camera region and its
    /// logo + Legal line keep clear of the pills) and the tab bar plus the CONSTANT
    /// `mapFloatingControlsInset` at the bottom, so the attribution sits above the buttons row
    /// (the HIG's "lowest resting position" of custom UI over a map). Neither inset animates and
    /// nothing the user does moves the map: the header's height changes only with the text size.
    /// This layout's own frame runs from the bottom of the bar row to the top of the bottom bar at
    /// BOTH widths, with the bars as its safe area (measured 2026-09-27, R23: iPhone 17 Pro Max
    /// 26.5 sim, top inset 64 and bottom 83; iPad Pro 13-inch (M5) 26.5 sim, top inset 64 and
    /// bottom 20 once `DossierPresentation` lets the regular-width inspector container reach under
    /// the row). MapKit paints under the bars from there; nothing here ignores a safe area.
    private var mapLayout: some View {
        let snap = snapshot
        return ZStack {
            MapRenderGate(revision: mapRenderRevision) { map(snap) }
                .equatable()
                // The constant inset (see mapFloatingControlsInset for why it is never state).
                // Applied here, inside the ZStack, so the overlays are not lifted by it.
                .safeAreaPadding(.bottom, mapFloatingControlsInset)
                // A tap on the map closes the legend card. Outside MapRenderGate, so the gate's
                // Equatable key never changes; simultaneous, so pins, clusters, pans, pinch and
                // double-tap zoom still reach the map. Pans and zooms leave the card open.
                .simultaneousGesture(TapGesture().onEnded {
                    if legendExpanded { setLegendExpanded(false) }
                })
                // The floating scope header, as the map's OWN top safe-area inset (the same
                // mechanism as the bottom padding above): the header draws no surface, so the
                // map paints under and between its pills, and lays its camera and attribution
                // inside the rest. On the map, not the ZStack, so the overlays keep the whole
                // region. The pills swallow their own touches (the Picker, and each chip Button
                // through its 44pt contentShape), so a tap on a segment or a chip never reaches
                // the map's tap gesture above; the clear parts of the inset (the VStack's
                // spacing and paddings, no background and no contentShape) are not hit-testable
                // and fall through to the map, so a drag started between the pills pans the map
                // and a tap there closes the legend like any map tap (measured on the iPhone
                // 17 Pro Max 26.5 sim, R21 review: a swipe begun under the chips moved the map
                // about 200pt). Wanted: the owner asked for the map between the pills. Deferred
                // like the overlays (Debug stack).
                .safeAreaInset(edge: .top, spacing: 0) {
                    DeferredView { scopeHeader(snap) }
                        // Fires only on a change: the header's height moves with the text size
                        // and with nothing else (the chips scroll sideways; a count changes no
                        // height), so this is not a per-tick write.
                        .onGeometryChange(for: CGFloat.self,
                                          of: { (proxy: GeometryProxy) in proxy.size.height },
                                          action: { (height: CGFloat) in scopeHeaderHeight = height })
                }
            if snap.totalLocated == 0 && !emptyDismissed {
                // Deferred for the Debug main-thread stack (see DeferredView in Components.swift).
                // Padded by the header's height and the lower-right stack's reserve, so it centres
                // in the visible map, above the buttons.
                DeferredView { emptyBanner }
                    .padding(.top, scopeHeaderHeight)
                    .padding(.bottom, mapFloatingStackReserve)
                    .transition(.opacity)
            }
        }
        // The overlays and the scope header are the heaviest inline subtrees; each is deferred so
        // this modifier chain carries a closure, not the subtree value (Debug stack on a 1 MiB
        // phone main thread; see DeferredView in Components.swift).
        .overlay(alignment: .bottom) { DeferredView { mapBottomNotices } }
        .overlay(alignment: .bottomLeading) { DeferredView { mapLegendOverlay(snap) } }
        .overlay(alignment: .bottomTrailing) { DeferredView { mapFloatingStack } }
        // Measured on the view that carries the overlays: the whole region between the navigation
        // bar and the tab bar (the floating header included), whose size does not depend on the
        // card, so the card cap that reads it cannot feed back into its own input. Fires only on
        // a change.
        .onGeometryChange(for: CGFloat.self, of: { (proxy: GeometryProxy) in proxy.size.height },
                          action: { (height: CGFloat) in mapRegionHeight = height })
        .background(ACABTheme.bg.ignoresSafeArea())
        // The header row holds the title alone: layers and locate float on the map (the floating
        // stack), so TabHeader draws no trailing items. The inline bar gives the map back the
        // large title's height. At accessibility sizes the system bar stays inline: a large title
        // alone costs the map about 100pt there.
        .tabHeader("Map", accessibilityTitleMode: .inline) { EmptyView() }
    }

    /// Stage 2, the presentations: the dossier (sheet or inspector), the cluster member sheet and
    /// the Map options sheet. Presenting any of them closes the legend card (no focus move: the
    /// presentation takes VoiceOver focus).
    private var mapPresented: some View {
        mapLayout
            // T5: regular width shows the tapped dossier in a trailing inspector (pin stays
            // visible); compact keeps today's full sheet. Exactly one is active per size class.
            .modifier(DossierPresentation(selected: $selected, regular: hSize == .regular))
            // P2-4: the compact sheet opens at the medium detent; pan the tapped pin into the
            // strip it leaves uncovered (a pin near the map's bottom edge would otherwise sit
            // under the sheet). The inspector on regular width never covers the map.
            .onChange(of: selected?.id) { (_: String?, _: String?) in
                guard hSize != .regular, let d = selected, let coord = mapCoord(for: d) else { return }
                keepPinVisibleUnderSheet(coord)
            }
            .sheet(item: $cluster) { (c: Cluster) in
                ClusterListSheet(cluster: c) { (d: Detection) in
                    cluster = nil
                    // Defer so the picker sheet finishes dismissing before the detail one
                    // presents (two sheets can't transition at the same instant).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { selected = d }
                }
                .environmentObject(ble)
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showMapOptions) { mapOptionsSheet }
            .onChange(of: selected != nil || cluster != nil || showMapOptions) { (_: Bool, presenting: Bool) in
                if presenting && legendExpanded { legendExpanded = false }
            }
    }

    /// Stage 3, the feeds: lifecycle, the store publishers, the two clocks, the dossier handoff
    /// and the WATCHED lens reset.
    private var mapFed: some View {
        mapPresented
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
            // The Active segment's clock, under EVERY scope while the map is visible, so
            // "active · N" follows the clock under Recent and All too. Two binary searches over
            // the snapshot's sorted stamps; a state write only when the count moves. The rebuild
            // is gated: only the Active scope draws that membership. Under Active it also moves
            // the headline's "without a location", the category chips, the ALL chip and the
            // empty-map card, whose rows outside the pin set are `otherActiveStamps` (two more
            // binary searches, under Active only). The gate matters because
            // scheduleDetectionSnapshotRefresh cannot coalesce a 1 s tick (its ladder tops out
            // at 1.0 s and it installs at once when the wait is spent), so an unconditional call
            // would rebuild and re-cluster every second. A queued trailing refresh makes later
            // ticks return early inside it. A sample-data snapshot has no stamps to measure: every
            // sample row stays active (mapScopeIncludes), so the tick stands down.
            .onReceive(mapActiveTimer) { (now: Date) in
                guard isMapVisible, !snapshot.activeIsSampleData else { return }
                let w = activeWindow(snapshot.activeStamps, now: now)
                if w.count != (activeTickCount ?? snapshot.activeCount) { activeTickCount = w.count }
                guard historyScope == .active else { return }
                if w != snapshot.activeWindowAtBuild
                    || activeWindow(snapshot.otherActiveStamps, now: now) != snapshot.otherActiveWindowAtBuild {
                    scheduleDetectionSnapshotRefresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
                selected = nil
                consumePendingFocus()
            }
            // WATCHED exists only while at least one located row belongs to it. If an unstar or
            // eviction removes the final member, drop the lens before its chip disappears.
            .onChange(of: snapshot.counts[DeviceType.watched.category] ?? 0, initial: true) { (_: Int, count: Int) in
                if filter == DeviceType.watched.category, count == 0 { filter = nil }
            }
    }

    /// Stage 4, the lens hooks: category, scope and breadcrumbs each rebuild the projection.
    private var mapLensHooks: some View {
        mapFed
            .onChange(of: filter) { (_: String?, _: String?) in installFreshSnapshot() }
            .onChange(of: historyScopeRaw) { (_: String, _: String) in
                if suppressNextScopeRefit {
                    suppressNextScopeRefit = false
                    return
                }
                didFitToDetections = false
                installFreshSnapshot()
                fitToDetections()
            }
            .onChange(of: showBreadcrumbs) { (_: Bool, _: Bool) in installFreshSnapshot() }
    }

    /// Stage 5, the layer hooks: captions and the known-ALPR reference layer.
    private var mapLayerHooks: some View {
        mapLensHooks
            .onChange(of: showLabels) { (_: Bool, _: Bool) in bumpMapRenderRevision() }
            .onChange(of: alpr.enabled) { (_: Bool, _: Bool) in refreshALPRVisible() }
            .onChange(of: alpr.showUnverified) { (_: Bool, _: Bool) in refreshALPRVisible() }
    }

    /// Stage 6, the content hooks: the ALPR dataset landing, the late first fix, and demo seeds
    /// re-placed around the user.
    private var mapContentHooks: some View {
        mapLayerHooks
            .onChange(of: alpr.nodes.count) { (_: Int, _: Int) in refreshALPRVisible() }
            // Late first fix: the tab may open with an EXISTING row that is not located yet, so
            // row count never changes when its first paired coordinate arrives. Key this retry to
            // located membership instead. fitToDetections remains one-shot, so later strongest-
            // RSSI pin migrations never fight a user pan.
            .onChange(of: snapshot.totalLocated) { (_: Int, _: Int) in fitToDetections() }
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
            .onChange(of: demoSeedKey) { (_: [Detection], _: [Detection]) in
                guard ble.demoMode else { return }
                didFitToDetections = false
                installFreshSnapshot()
                fitToDetections()
                // The re-placed seeds are new PIN COORDINATES, so the map's pin-set handler
                // re-matches the rings on the body pass this very change triggers. Nothing to do
                // here: stamping now would only match the pins from before they moved.
            }
    }

    var body: some View {
        NavigationStack { mapContentHooks }
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
            guard mapScopeIncludes(lastSeen: seen,
                                   basis: ble.timeBasis(for: d.id, stamp: seen),
                                   scope: historyScope, now: now,
                                   isDemoMode: ble.demoMode) else { return nil }
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
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.5)) {
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
        // segmented control and the chip row show both changes, so this is never a silent filter
        // mutation.
        if historyScope != .all {
            suppressNextScopeRefit = true
            historyScopeRaw = MapHistoryScope.all.rawValue
        }
        filter = nil
        let target = MKCoordinateRegion(center: coord, span: Self.focusSpan)
        region = target
        span = target.span
        installFreshSnapshot(region: target)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
            camera = .region(target)
        }
        bumpMapRenderRevision()
    }

    /// The medium detent's top edge as a share of the window height: measured at 0.48 on an
    /// iPhone 17 Pro (the sheet's grabber row sits just under the midline).
    private static let mediumSheetTopShare: CGFloat = 0.48
    /// The window's height, the space `mapGlobalFrame` is measured in. The compact arm only
    /// runs on a phone-width window, where the sheet's detents are shares of this height.
    private static var windowHeight: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.keyWindow?.bounds.height ?? 0
    }

    /// Pans the camera so `coord` stays visible above the medium dossier sheet
    /// (`mapCenterKeepingPinVisible`); a no-op when it already is, or before the map's frame is
    /// measured. Same span, same longitude; animated like the other camera moves, not under
    /// Reduce Motion. The move lands through `onMapCameraChange`, which refreshes the snapshot.
    private func keepPinVisibleUnderSheet(_ coord: CLLocationCoordinate2D) {
        guard let center = mapCenterKeepingPinVisible(
            pin: coord, region: region, mapTop: mapGlobalFrame.minY, mapHeight: mapGlobalFrame.height,
            sheetTop: Self.windowHeight * Self.mediumSheetTopShare) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
            camera = .region(MKCoordinateRegion(center: center, span: region.span))
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
            // Hidden when the "phone breadcrumb trails" map setting is off, which is its default
            // (showBreadcrumbsDefault).
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
                            ClusterBubble(count: c.memberCount, uniformType: c.uniformType)
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
        // Locate is `recenterButton` in the floating stack at the lower right. The compass is
        // MapKit's own control: the map extends under the floating scope pills (P3-1, R21) and its
        // top safe-area inset is their height (`mapLayout`), so the compass lays out inside that
        // inset, below the pills, like the logo and Legal line at the bottom.
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
        .onGeometryChange(for: CGRect.self, of: { (proxy: GeometryProxy) in proxy.frame(in: .global) },
                          action: { (frame: CGRect) in mapGlobalFrame = frame })
        // The rings do not move when the pins do, but the PEEK does: a filter change hides or
        // reveals pins, a new sighting adds one, and a drone steps along its track, all without
        // touching the viewport. Keyed to the pin SET this pass actually drew - not to a count,
        // and never to `ble.detections` itself, which republishes at ~3 Hz - so a row that was
        // already in the store and only just got a coordinate still lands, while a publish that
        // moved no pin costs one array compare and nothing else. Stashing the pins here (an event
        // handler, not body) is what lets the match skip a store pass; the stamp behind it is
        // throttled, so an arrival stream cannot become a match-pass stream. `initial: true` seeds
        // the pins on the first pass, when there is no previous set to differ from.
        .onChange(of: snap.pins, initial: true) { (_: PinSet, pins: PinSet) in
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
    }

    /// One spoken sentence carrying the map's actual state: the pin content for VoiceOver
    /// users, or which empty story (permission, the Active or Recent window, nothing located)
    /// applies.
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
            // Two explicit arms, not an interpolated window word, so each runtime string can be
            // read here. "forty-five" and "fifteen" are hardcoded: MapPinRulesTests pins
            // activeNearbyInterval == 45 and recentSeconds == 900, so a retune fails there first.
            if snap.spokenScope == .active, snap.retainedLocated > 0 {
                return "Map. No located detections in the last forty-five seconds. \(snap.retainedLocated) older located detections remain retained in the Log."
            }
            if snap.spokenScope == .recent, snap.retainedLocated > 0 {
                return "Map. No located detections in the previous fifteen minutes. \(snap.retainedLocated) older located detections remain retained in the Log."
            }
            return "Map. No located detections yet."
        }
        let shown = snap.representedRows
        let filtered = snap.spokenFilter.map { " filtered to \($0.lowercased())" } ?? " across all types"
        let scope: String
        switch snap.spokenScope {
        case .active: scope = "from the last forty-five seconds"
        case .recent: scope = "from the previous fifteen minutes"
        case .all:    scope = "from all history"
        }
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

    // MARK: Scope header

    /// The scope segments pill and, under it, the category chip row, floating over the top of the
    /// full-bleed map as the map's top safe-area inset (`mapLayout`). The header itself draws NO
    /// surface (R21, owner 2026-09-27: the full-width strip that held both rows "felt abrupt"):
    /// the map paints between and around the pills, and each pill carries its own surface, the
    /// one the floating buttons and the legend card share (`mapControlSurface`: tinted Liquid
    /// Glass on iOS 26, the tinted regular material on iOS 18, the opaque map-information surface
    /// under Reduce Transparency or higher contrast). The segments pill takes the regular variant
    /// (a control row, not one button) and sits in the gutter; the chips take the interactive one
    /// and scroll edge to edge under the gutter. 8pt above the segments and 8pt under the chips:
    /// with the strip gone, the pills read as floating at the same offsets the strip had, and the
    /// safe-area inset still reserves exactly this stack's height for MapKit's camera and Legal
    /// line. TWIN: android MapScreen.kt's MapScopeSegments and MapCategoryChips, each its own
    /// surface under the MapFloatingBar title pill.
    ///
    /// No link chip here, deliberately, and the same on Android: the connection pill lives on
    /// Status and Beacon, where a user asks "is my board there"; on the Map it only competed with
    /// the scope control and the counts.
    private func scopeHeader(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeSegments(snap)
                .padding(.horizontal, ACABTheme.pad)
            filterBar(snap)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The system segmented Picker ("Map history") as ONE floating pill: the map-control surface
    /// (regular, not interactive) in a Capsule, the shape the iOS 26 segmented control draws
    /// itself (measured on the 2026-09-26 and 2026-09-27 shots: a 30pt track with fully round
    /// ends), so the glass sits exactly under the picker's own translucent track and no second
    /// frame shows. R21 compared this with a custom glass segmented control (three buttons in a
    /// Capsule surface) on the iPhone 17 Pro Max shots: both read as one continuous pill, so the
    /// standard control won (HIG). Leading-aligned and capped to `mapScopeSegmentsMaxWidth` at
    /// regular width. The iOS 18 material branch under this pill was not rendered in R21 (no
    /// iOS 18 simulator on the build machine).
    private func scopeSegments(_ snap: MapSnapshot) -> some View {
        Picker("Map history", selection: historyScopeBinding) {
            ForEach(MapHistoryScope.allCases) { scope in
                let n = scopeCount(scope, snap)
                Text(mapScopeSegmentLabel(scope, count: n))
                    .accessibilityLabel("\(scope.label), \(n)")
                    .tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Active shows the last forty-five seconds; Recent shows the previous fifteen minutes; All history shows every retained located detection")
        // Regular width caps the segments (P3-3): uncapped on the iPad each segment ran
        // about 330pt for a 60pt label while the chip row under it hugged its content. The
        // legend card caps itself the same way (`legendCard`'s 420pt frame). TWIN: android
        // MapScreen.kt MAP_SCOPE_SEGMENTS_MAX_WIDTH, the same 520 on a tablet.
        .frame(maxWidth: hSize == .regular ? Self.mapScopeSegmentsMaxWidth : .infinity,
               alignment: .leading)
        .mapControlSurface(Capsule(), interactive: false)
    }

    /// The scope segments' width cap on regular width (P3-3). TWIN: android MapScreen.kt
    /// `MAP_SCOPE_SEGMENTS_MAX_WIDTH`, the same number.
    static let mapScopeSegmentsMaxWidth: CGFloat = 520

    /// The count each scope segment shows: the located rows that pass the category chip in that
    /// scope. Snapshot fields and the tick's state only; the body never walks the store. Active
    /// reads the 1 s tick's count when it has one, so it follows the clock under every scope.
    private func scopeCount(_ scope: MapHistoryScope, _ snap: MapSnapshot) -> Int {
        switch scope {
        case .active: return activeTickCount ?? snap.activeCount
        case .recent: return snap.recentCount
        case .all:    return snap.allCount
        }
    }

    /// Honest projection accounting: rows represented by the current viewport, the evidence the
    /// Log still retains, and how many MapKit annotations carry the visible rows. THREE causes get
    /// THREE separate numbers, because only one of them is a budget: rows merged into a marker
    /// ("simplified"), rows off screen ("outside this view", undone by panning), and rows a cap
    /// withheld ("outside display budget"). Naming them apart is what keeps aggregation from
    /// reading as evidence deletion - and it stops a zoomed-in viewport over a large store from
    /// reporting thousands of ordinary off-screen rows as withheld by a budget.
    /// Counts are plain Ints, ungrouped like the honesty headline directly above this line
    /// (contract 5.4).
    private func projectionSummary(_ snap: MapSnapshot) -> String {
        var parts = ["\(snap.representedRows) displayed",
                     "\(snap.retainedLocated) retained"]
        if snap.markerCount != snap.representedRows || snap.simplifiedArtwork {
            parts.append("\(snap.markerCount) markers")
        }
        if snap.viewportCulled > 0 {
            parts.append("\(snap.viewportCulled) outside this view")
        }
        if snap.droppedRows > 0 { parts.append("\(snap.droppedRows) outside display budget") }
        if snap.mergedRows > 0 || snap.simplifiedArtwork { parts.append("simplified") }
        // A no-break space BEFORE the dot: a wrap then always leaves the dot at the end of a line,
        // never an orphan "· " at the start of the next one.
        return parts.joined(separator: "\u{00A0}\u{00B7} ")
    }

    /// `projectionSummary` as drawn: every space INSIDE a fragment becomes a no-break space, so
    /// the mono line wraps only after a dot and a count never parts from its word (the verify
    /// shot of the mono qualifier broke "4 markers" across two lines). The fragment words the
    /// drift row pins are unchanged; the spoken text is unchanged.
    private func keepingFragmentsWhole(_ summary: String) -> String {
        let dot = "\u{00A0}\u{00B7} "
        return summary.components(separatedBy: dot)
            .map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }
            .joined(separator: dot)
    }

    /// Scrolling category chips, each its own floating capsule over the tiles (R21); tap one to
    /// narrow the pins. Reference layers and map display policy live together in the readable
    /// Options sheet, rather than masquerading as a type. The gutter sits inside the scroll view,
    /// so the chips scroll edge to edge. On iOS 26 the row's glass chips share one
    /// GlassEffectContainer at the row's 8pt spacing, as the lower-right stack's buttons do
    /// (`mapFloatingStack`); the selected chip is an opaque hue fill and takes no glass.
    ///
    /// The chips' type is capped at accessibility2, the cap RootView gives the pinned banners:
    /// uncapped, at AX5 three chips of about 70pt filled the width and the row cost the map
    /// about 110pt while the segmented Picker above it did not grow (HIG Typography: not every
    /// word on the screen has to grow). The 44pt target and the spoken "ALPR, 1 located" label
    /// are unchanged.
    private func filterBar(_ snap: MapSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Group {
                if #available(iOS 26, *) {
                    GlassEffectContainer(spacing: Self.mapChipSpacing) { filterChips(snap) }
                } else {
                    filterChips(snap)
                }
            }
            .padding(.horizontal, ACABTheme.pad)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// The gap between two chips, and the distance at which their glass would start to blend
    /// (the GlassEffectContainer's spacing), so two chips never read as one.
    private static let mapChipSpacing: CGFloat = 8

    /// The chip row's content: ALL first, then the categories `shownCategories` keeps.
    private func filterChips(_ snap: MapSnapshot) -> some View {
        HStack(spacing: Self.mapChipSpacing) {
            chip(nil, "ALL", snap.totalLocated)
            ForEach(shownCategories(snap)) { c in
                chip(c.key, c.chipLabel, snap.counts[c.key] ?? 0)
            }
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

    // MARK: Floating controls

    /// The lower-right stack: Map options above Center on my location, floating on the map
    /// (Apple Maps puts its map modes button at the lower right). Vertical when the region is
    /// tall enough, a row when it is not (a phone in landscape at accessibility sizes), so the
    /// stack never climbs over the scope header. On iOS 26 the two glass buttons share one
    /// GlassEffectContainer. Hidden while the legend card is open (hidden, not removed, so nothing
    /// re-lays out): glass never sits on glass, and the card is the one thing in focus.
    /// TWIN: android MapScreen.kt's floating stack (`mapFloatingStackVertical`).
    private var mapFloatingStack: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: mapControlSpacing) { mapFloatingStackButtons }
            } else {
                mapFloatingStackButtons
            }
        }
        .padding(.trailing, ACABTheme.pad).padding(.bottom, mapControlMargin)
        .opacity(legendExpanded ? 0 : 1)
        .allowsHitTesting(!legendExpanded)
        .accessibilityHidden(legendExpanded)
    }

    private var mapFloatingStackButtons: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: mapControlSpacing) { settingsButton; recenterButton }
            HStack(spacing: mapControlSpacing) { settingsButton; recenterButton }
        }
    }

    /// One floating button's face: a fixed-size glyph in the root tint on the map-control surface,
    /// `mapControlSize` across (visual AND hit target). The glyph does not grow with Dynamic Type,
    /// so each button carries the large content viewer (the bar-button pattern).
    private func mapControlFace(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ACABTheme.tint)
            .frame(width: mapControlSize, height: mapControlSize)
            .mapControlSurface(Circle())
            .contentShape(Circle())
    }

    /// Recenter on the phone's position: the floating stack's Locate button, used instead of
    /// Apple's MapUserLocationButton so it shares the stack's look. Drives the camera EXPLICITLY,
    /// which is also why the fallback above can stay a fixed region instead of .automatic (see
    /// the loop note on `camera`).
    private var recenterButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                camera = .userLocation(fallback: .region(MapTabView.fallbackRegion))
            }
            bumpMapRenderRevision()
        } label: {
            mapControlFace("location")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Center on my location")
        .accessibilityShowsLargeContentViewer()
    }

    /// The floating stack's layers button: opens one readable options sheet for display density
    /// and the reference layers. Its value says whether the known-ALPR layer is on, the same
    /// words as Android's stateDescription on its layers button.
    private var settingsButton: some View {
        Button {
            showMapOptions = true
        } label: {
            mapControlFace("square.2.layers.3d")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map options")
        .accessibilityValue(alpr.enabled ? "known ALPR layer on" : "known ALPR layer off")
        .accessibilityHint("Opens display and reference layer options")
        .accessibilityShowsLargeContentViewer()
    }

    // MARK: Map options sheet

    /// A system inset-grouped List with its surfaces PINNED, not left to the system. A sheet runs
    /// at the elevated interface level, where a dark inset-grouped List paints its page #1C1C1E
    /// and its cells #2C2C2E (bg3): `dim` measures under 7:1 there, and bg3 is not a text surface
    /// (Theme.swift, rule 1). A partial-detent sheet also defaults to glass on iOS 26. So the
    /// sheet is bg, the List page is bg and every row is bg2, in both detents.
    private var mapOptionsSheet: some View {
        NavigationStack {
            List {
                mapOptionsSection("DISPLAY") {
                    // The policy sentence alone. The projection qualifier ("N displayed · N
                    // retained · ...") is the legend card's line (`legendQualifier`) and is not
                    // repeated here: R17's rule against repeating a count the screen already
                    // shows, and Android's options sheet has no such row.
                    Text("dense and far-away sightings combine into fewer markers. pin sheets still reveal the detections represented by a marker; retained Log evidence is never removed.")
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        // "phone", not "tracker": the drawn line is the PHONE's path while a
                        // tracker stayed with us, not the tag's own route (q-breadcrumbs says
                        // so). BYTE-IDENTICAL to Android's GroupedSwitchRow headline in
                        // MapScreen.kt (the Map options sheet) - same words AND same case, so
                        // the two map options sheets cannot drift on this row.
                        Toggle("phone breadcrumb trails", isOn: $showBreadcrumbs)
                            .font(ACABTheme.font(.body))
                        // The toggle's own subline, what it draws and how long it is kept.
                        // FollowEvidence.scopeLine stays with the dossier's Seen with you panel.
                        Text(MapTabView.breadcrumbToggleSubline)
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("icon labels", isOn: $showLabels)
                        .font(ACABTheme.font(.body))
                }

                // BYTE-IDENTICAL to Android MapScreen.kt's `Kicker("REFERENCE OVERLAYS ·
                // NOT FILTERS")`, header and the ALPR note below alike: the toggles here
                // draw reference data over the map and never hide a detection, and the
                // two sheets must say so in the same words. The source credit
                // ("cameras: OpenStreetMap ODbL · DeFlock") is the map legend's job on
                // both phones; the note carries the privacy disclosure.
                mapOptionsSection("REFERENCE OVERLAYS · NOT FILTERS") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("known ALPR cameras",
                               isOn: Binding(get: { alpr.enabled },
                                             set: { alpr.setEnabled($0); if $0 { alpr.refresh() } }))
                            .font(ACABTheme.font(.body))
                        Text("draws community-mapped camera locations, on by default. the dataset is one offline download; no location, viewport, or detection data is attached, and the site host sees an ordinary web request. pins are mapped locations, not live detections.")
                            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        if alpr.enabled {
                            Text(alprStatusLine)
                                .font(ACABTheme.font(.footnote, tabular: true)).foregroundStyle(ACABTheme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if alpr.enabled {
                        if alpr.unverifiedCount > 0 {
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("lower-confidence pins",
                                       isOn: Binding(get: { alpr.showUnverified },
                                                     set: { alpr.setShowUnverified($0) }))
                                    .font(ACABTheme.font(.body))
                                Text(alprUnverifiedLine)
                                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        alprCheckRow
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ACABTheme.bg)
            .navigationTitle("Map options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showMapOptions = false }
                }
            }
        }
        .tint(ACABTheme.tint)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ACABTheme.bg)
    }

    /// One grouped section of the options sheet: an uppercase identifier header (C2) through
    /// Kicker, and every row on bg2 (see `mapOptionsSheet` for why the rows are pinned).
    private func mapOptionsSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        let rows = content()
        return Section {
            Group { rows }
                .listRowBackground(ACABTheme.bg2)
        } header: {
            Kicker(title)
        }
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

    /// Caption under the unconfirmed-pins toggle (alprLowerConfidenceLine).
    private var alprUnverifiedLine: String {
        alprLowerConfidenceLine(count: alpr.unverifiedCount, showing: alpr.showUnverified)
    }

    /// Manual dataset refresh, mirroring the firmware "Check for Updates" row in Settings at
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
                        .font(ACABTheme.font(.footnote, weight: .semibold))
                }
                Text(alprCheckLabel).font(ACABTheme.font(.subheadline, weight: .semibold))
            }
            .foregroundStyle(alprCheckSucceeded ? ACABTheme.tint : ACABTheme.dim)
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
        if alprChecking || alpr.loading { return "Checking" }   // store-driven too, so an automatic on-enable refresh reads the same as a tap (parity with Android)
        if alprJustChecked {
            switch alpr.lastOutcome {
            case .updated(let n): return "Updated \u{00B7} \(n.formatted()) Camera\(n == 1 ? "" : "s")"
            case .upToDate:       return "Up to Date"
            default:              return "Couldn't Check"
            }
        }
        return "Check for Updates"
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

    // MARK: Category chips

    /// One category chip, a floating capsule over the map (R21). Unselected: `dim` ink on the
    /// interactive map-control surface (tinted glass on iOS 26, tinted material on iOS 18, the
    /// opaque map-information surface under Reduce Transparency or higher contrast;
    /// MapGlassTintTests pins `dim` at the 4.5:1 text floor on the tinted glass over the lightest
    /// tile). Selected: the category hue, opaque, with `onAccent` ink, exactly as before; the
    /// filled chip is the selection cue and glass never sits under it (`MapChipSurface`).
    private func chip(_ cat: String?, _ label: String, _ n: Int) -> some View {
        let active = filter == cat
        let tint = catTint(cat)
        return Button { filter = cat } label: {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.font(.subheadline, weight: .semibold))
                Text("\(n)").font(ACABTheme.font(.subheadline, tabular: true))
            }
            // Active: dark ink at full strength on the category hue (MapGlassTintTests pins
            // onAccent at the 4.5:1 text floor on every chip hue). Inactive: secondary text on
            // the tinted glass.
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .modifier(MapChipSurface(active: active, tint: tint))
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
        default:         return ACABTheme.tint
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

    // MARK: Bottom notices

    /// The bottom overlay's one content: the ALPR credit callout ABOVE the ALPR hint, one stack,
    /// so the two can never collide at any text size. It rests above the info button AND MapKit's
    /// logo + Legal line (`mapFloatingControlsInset + mapAttributionClearance`: the callout spans
    /// the map's width on a phone, and the attribution sits at the map's bottom-left), and clear
    /// of the lower-right stack on its trailing side. Bounded to the map region: at accessibility
    /// sizes the callout can outgrow the space between the scope header and that resting line, so
    /// ViewThatFits keeps the unscrolled stack whenever it fits and otherwise scrolls it inside
    /// the region instead of letting it climb under the scope header. Hidden while the legend
    /// card is open (hidden, not removed, so nothing re-lays out).
    private var mapBottomNotices: some View {
        ViewThatFits(in: .vertical) {
            mapBottomNoticeStack
            ScrollView { mapBottomNoticeStack }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .scrollIndicatorsFlash(onAppear: true)
        }
        .padding(.leading, ACABTheme.pad)
        .padding(.trailing, ACABTheme.pad + mapControlSize + mapControlSpacing)
        // The floating header's height on top of the 8, so the bounded form ends under the
        // header (the overlay spans the whole region, header band included).
        .padding(.top, 8 + scopeHeaderHeight)
        .padding(.bottom, mapFloatingControlsInset + mapAttributionClearance)
        .opacity(legendExpanded ? 0 : 1)
        .allowsHitTesting(!legendExpanded)
        .accessibilityHidden(legendExpanded)
    }

    private var mapBottomNoticeStack: some View {
        VStack(spacing: 8) {
            if showALPRInfo { alprCallout.transition(.opacity) }
            if let hint = alprHint { alprHintView(hint).transition(.opacity) }
        }
    }

    private func alprHintView(_ hint: String) -> some View {
        Text(hint)
            .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.mapInfoText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(ACABTheme.mapInfoBackground,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
    }

    /// Tapped a known-ALPR dot: one shared credit callout (tap it to dismiss), drawn by
    /// `mapBottomNotices` above the alprHint slot so the two never collide in the narrow zoom
    /// band where both apply.
    private var alprCallout: some View {
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
                        .font(ACABTheme.font(.subheadline, weight: .semibold))
                        .foregroundStyle(ACABTheme.mapInfoText)
                    Text(alprCalloutDetail(tier: tappedALPRTier,
                                           maker: tappedALPRMaker,
                                           peek: tappedALPRPeek))
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.mapInfoText)
                }
                .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "xmark")
                    .font(ACABTheme.font(.footnote, weight: .semibold))
                    .foregroundStyle(ACABTheme.mapInfoText).padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: 420, alignment: .leading)
            .background(ACABTheme.mapInfoBackground,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dismisses mapped-camera information")
    }

    // MARK: Legend card

    /// The lower-left overlay: the legend card when open, then the info button. Not one VStack:
    /// the card is placed by its own bottom padding, so opening it never moves the button.
    private func mapLegendOverlay(_ snap: MapSnapshot) -> some View {
        ZStack(alignment: .bottomLeading) {
            if legendExpanded {
                DeferredView { legendCard(snap) }
                    .transition(legendCardTransition)
            }
            DeferredView { legendButton }
        }
    }

    /// The card grows out of the info button's corner; under Reduce Motion it only fades.
    private var legendCardTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity
            : AnyTransition.scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity)
    }

    /// The card's height cap: `mapLegendCardCap` over the measured region and header row, with
    /// the floating scope header as the top inset (so the card's room ends under the header) and
    /// the card's own bottom padding as the bottom inset.
    private var legendCardCap: CGFloat {
        mapLegendCardCap(regionHeight: mapRegionHeight,
                         summaryHeight: legendSummaryHeight,
                         accessibilitySize: dynamicTypeSize.isAccessibilitySize,
                         topInset: scopeHeaderHeight,
                         bottomInset: mapFloatingControlsInset + mapAttributionClearance)
    }

    /// Corner radius of the legend card's surface: a floating card over the map, rounder than a
    /// grouped cell (`ACABTheme.radius`).
    private static let mapLegendCardRadius: CGFloat = 20

    /// Opens or closes the card from the info button, the close control, a map tap or the escape
    /// gesture, then moves VoiceOver focus: to the card's header row after an open, back to the
    /// info button after a close (one run-loop turn later, so the card exists or is gone first).
    /// A presentation closes the card by writing `legendExpanded` directly (see `mapPresented`),
    /// with no focus move.
    private func setLegendExpanded(_ open: Bool) {
        if reduceMotion { legendExpanded = open }
        else { withAnimation(.easeOut(duration: 0.2)) { legendExpanded = open } }
        DispatchQueue.main.async {
            if open { legendFocused = true } else { legendButtonFocused = true }
        }
    }

    /// The legend's info button: round, at the lower left, the info glyph only (the round button
    /// supplies the circle; `info.circle` would draw a ring inside the ring). No count: the scope
    /// header already shows it. Tap to open or close the card.
    ///
    /// While the known-ALPR dataset DOWNLOADS, a small spinner badge sits on its top-trailing edge
    /// and the spoken value says so; the card never opens by itself. Keyed to `downloading`, NOT
    /// `loading`: `loading` also covers the manifest freshness check that runs on every enable,
    /// and binding the old legend panel to it flashed the panel open and shut for a network
    /// round-trip that usually early-returns with the cache already drawn.
    ///
    /// "Map legend" + expanded/collapsed are Android stateDescription parity, and the screenshot
    /// driver targets "Map legend". TWIN: android MapScreen.kt's info button
    /// (`mapLegendStateDescription`).
    private var legendButton: some View {
        Button { setLegendExpanded(!legendExpanded) } label: {
            mapControlFace("info")
                .overlay(alignment: .topTrailing) {
                    if alpr.downloading { legendDownloadBadge }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map legend")
        .accessibilityValue(mapLegendAccessibilityValue(open: legendExpanded, downloading: alpr.downloading))
        .accessibilityHint(legendExpanded ? "Hides the map legend" : "Shows the map legend")
        .accessibilityShowsLargeContentViewer()
        .accessibilityFocused($legendButtonFocused)
        .padding(.leading, ACABTheme.pad).padding(.bottom, mapControlMargin)
    }

    /// The download badge: a mini spinner on a 16pt disc of the opaque map-information surface.
    /// Hidden from VoiceOver: the button's value says "loading camera data" instead.
    private var legendDownloadBadge: some View {
        ProgressView().controlSize(.mini)
            .frame(width: 16, height: 16)
            .background(ACABTheme.mapInfoBackground, in: Circle())
            .accessibilityHidden(true)
    }

    /// The legend card, floating at the lower left above the info button AND MapKit's logo +
    /// Legal line (`mapFloatingControlsInset + mapAttributionClearance`), so the attribution stays
    /// visible and still with the card open (HIG Maps; Android keeps its OSM credit visible the
    /// same way). Up to 420pt wide: a phone gets the full width between the gutters, an iPad a
    /// card, not a banner. Its surface is the tinted regular glass (`mapControlSurface`, not
    /// interactive: the card is text); the Map is forced dark and the tint keeps the glass dark
    /// over the palest tile, so the palette's inks read on it (headline `mapInfoText`, qualifier
    /// `dim`, keys and credit `mapInfoText`, the close glyph `faint`): untinted, the 2026-09-26
    /// shots measured the `dim` qualifier at 3.13:1; the system's vibrant labels the review
    /// proposed instead measured 2.7 to 3.2:1 on the verify shots, tinted or not, so the tint
    /// carries the card and the inks stay the measured palette ones (ContrastPaletteTests,
    /// MapGlassTintTests).
    ///
    /// The honesty line comes FIRST, in the header row with the close control, and that row is
    /// never capped away (`legendCardCap`); at default sizes it never scrolls. The card hugs its
    /// content under the cap (HeightCap); a part that does not fit scrolls, and ViewThatFits picks
    /// the unscrolled form first. Default sizes: the header holds the headline and the qualifier line
    /// (`legendHonesty`); the keys follow, with the data credit pinned BELOW them, so the
    /// attribution never hides below the fold of a capped card. The keys' ViewThatFits carries
    /// layoutPriority(1): without it the VStack split the capped height with the credit line and
    /// handed the keys a share too small for the unscrolled form, so the keys scrolled (Known
    /// ALPR below the fold) well under the cap. Accessibility sizes: the header holds the
    /// headline alone, and the qualifier line, the keys and the credit scroll together below it:
    /// there the credit alone runs to three lines, and pinned it squeezed every key out. When
    /// not even one key row fits under the header there, the header scrolls with them (the
    /// three forms in the body), so the open card still starts with the honesty line.
    ///
    /// Closed by the info button, the close control, a map tap, the escape gesture and any
    /// presentation; pans and zooms leave it open (Apple Maps). Not modal: the map stays
    /// interactive under it. TWIN: android MapScreen.kt `MapLegendCardContent`.
    private func legendCard(_ snap: MapSnapshot) -> some View {
        HeightCap(cap: legendCardCap) {
            VStack(alignment: .leading, spacing: 0) {
                if dynamicTypeSize.isAccessibilitySize {
                    // Three forms, the first that fits: everything unscrolled; the header fixed
                    // over scrolling keys, when at least one key row fits under it
                    // (`legendOneKeyRow` is that form's ideal height for the scroll); else the
                    // header scrolls WITH the keys. The card rests above the info button and the
                    // logo + Legal line, so a short region (the sample banner and the chips at
                    // AX5 on an iPhone 17 Pro) left a fixed four-line headline about 16pt of
                    // keys, a sliver no one could read. The honesty line is still the first
                    // thing the open card shows. Each block is deferred: built inline, the key
                    // blocks in this closure made its Debug frame about 220 KB on a 1 MiB phone
                    // main thread (see DeferredView in Components.swift).
                    ViewThatFits(in: .vertical) {
                        DeferredView {
                            VStack(alignment: .leading, spacing: 0) {
                                legendMeasuredHeader(snap)
                                DeferredView { legendBody(snap) }
                            }
                        }
                        DeferredView {
                            VStack(alignment: .leading, spacing: 0) {
                                legendMeasuredHeader(snap)
                                legendScroll { DeferredView { legendBody(snap) } }
                                    .frame(minHeight: Self.legendOneKeyRow, idealHeight: Self.legendOneKeyRow,
                                           maxHeight: .infinity)
                            }
                        }
                        DeferredView {
                            legendHeaderScroll {
                                legendMeasuredHeader(snap)
                                DeferredView { legendBody(snap) }
                            }
                        }
                    }
                } else {
                    legendMeasuredHeader(snap)
                    Divider().overlay(ACABTheme.line)
                    // Deferred for the Debug main-thread stack (see the accessibility branch
                    // above and DeferredView in Components.swift).
                    ViewThatFits(in: .vertical) {
                        DeferredView { legendKeys(snap) }
                        legendScroll { DeferredView { legendKeys(snap) } }
                    }
                    .layoutPriority(1)
                    if alpr.enabled { legendCredit }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .mapControlSurface(RoundedRectangle(cornerRadius: Self.mapLegendCardRadius, style: .continuous),
                           interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { setLegendExpanded(false) }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.bottom, mapFloatingControlsInset + mapAttributionClearance)
    }

    /// The header row as the card places it: 8pt above what follows, and measured, because its
    /// height feeds `legendCardCap`. Fires only on a change; the cap never resizes this row.
    private func legendMeasuredHeader(_ snap: MapSnapshot) -> some View {
        legendCardHeader(snap)
            .padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self, of: { (proxy: GeometryProxy) in proxy.size.height },
                              action: { (height: CGFloat) in legendSummaryHeight = height })
    }

    /// One 44pt key row inside legendScroll's 12pt top and bottom padding: the least the keys
    /// may get under a fixed header at accessibility sizes (see `legendCard`). The same sum as
    /// the accessibility floor in `mapLegendCardCap`.
    private static let legendOneKeyRow: CGFloat = 12 + 44 + 12

    /// The card's header row: the honesty line (headline + qualifier at default sizes, the
    /// headline alone at accessibility sizes), then the close control. VoiceOver lands here when
    /// the card opens.
    private func legendCardHeader(_ snap: MapSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize { legendHeadline(snap) } else { legendHonesty(snap) }
            }
            .accessibilityFocused($legendFocused)
            legendCloseButton
        }
    }

    /// The card's close control: "close map legend", the same words as Android's close button
    /// (lowercase-first, the spoken name of an icon-only button).
    /// A 44pt target pulled 10pt into the card's corner, so the glyph lines up with the headline.
    private var legendCloseButton: some View {
        Button { setLegendExpanded(false) } label: {
            Image(systemName: "xmark")
                .font(ACABTheme.font(.footnote, weight: .semibold))
                .foregroundStyle(ACABTheme.faint)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("close map legend")
        .padding(.top, -10).padding(.trailing, -10)
    }

    /// The accessibility-size scroll content of the card, under the header row: the qualifier
    /// line, then the keys and the data credit, which scrolls with them at these sizes (see
    /// `legendCard`).
    private func legendBody(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            legendQualifier(snap)
            Divider().overlay(ACABTheme.line)
            legendKeys(snap)
            if alpr.enabled { legendCredit }
        }
    }

    /// The honesty summary at default sizes, one spoken element: "N on the map · M without a
    /// location", then the existing projection qualifiers. Both lines read the installed
    /// snapshot only. Accessibility sizes draw the two lines apart (see `legendCard`).
    private func legendHonesty(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            legendHeadline(snap)
            legendQualifier(snap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "N on the map · M without a location": the first line of the open legend card, never
    /// capped away. It scrolls only at accessibility sizes, with the keys, when not one key row
    /// fits under it (see `legendCard`).
    private func legendHeadline(_ snap: MapSnapshot) -> some View {
        // Drawn with a no-break space before the dot, so a wrap never starts the second line
        // with an orphan "· "; the helper's literal stays as the test pins it.
        Text(keepingMiddleDotsAttached(
            mapHonestyHeadline(onMap: snap.filteredLocated, withoutLocation: snap.withoutLocation)))
            // Always pass the weight: the helper's default is .regular, which would
            // un-bold .headline.
            .font(ACABTheme.font(.headline, weight: .semibold, tabular: true))
            .foregroundStyle(ACABTheme.mapInfoText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The projection qualifiers under the headline ("5 displayed · 5 retained · 4 markers ·
    /// simplified"): a mono telemetry line in the instrument layer (R16), lowercase, the
    /// regular cut like the Status radar caption. The words are `projectionSummary`'s and are
    /// BYTE-IDENTICAL on both apps (owner decision 2026-09-26, R19: iOS's fuller words, drawn
    /// mono and lowercase on both). TWIN: android MapScreen.kt's legend counts line.
    private func legendQualifier(_ snap: MapSnapshot) -> some View {
        Text(keepingFragmentsWhole(projectionSummary(snap)))
            .font(ACABTheme.telemetry(.footnote, weight: .regular))
            .foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The keys, then the conditional rows, in the repo's order (the data credit follows them,
    /// pinned outside the scroll by `legendCard` at default sizes; see `legendCredit`). Every gate
    /// keeps the rule "a legend that names a treatment nothing on screen is using reads as a
    /// rendering bug".
    ///
    /// Default sizes: a two-column grid, column-major (ALPR, Drone, Body cam, Known ALPR down the
    /// left; Tracker, Glasses, Network camera, ALPR (lower confidence) down the right). The sort
    /// priorities make VoiceOver read the eight keys in the repo order (ALPR, Drone, Body cam,
    /// Tracker, Glasses, Network camera, Known ALPR, ALPR (lower confidence)) instead of column
    /// by column. Accessibility sizes: ONE column in that repo order, so the drawn and the spoken
    /// orders agree with no priorities.
    private func legendKeys(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                legendRow(ACABTheme.flockTone, "ALPR")
                legendRow(ACABTheme.droneTone, "Drone")
                legendRow(ACABTheme.axonTone, "Body cam")
                legendRow(ACABTheme.trackerTone, "Tracker")
                legendRow(ACABTheme.glassesTone, "Glasses")
                legendRow(ACABTheme.netcamTone, "Network camera")
                if alpr.enabled { knownALPRKey }
                if alpr.enabled && alpr.showUnverified { lowerConfidenceKey }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        legendRow(ACABTheme.flockTone, "ALPR").accessibilitySortPriority(8)
                        legendRow(ACABTheme.droneTone, "Drone").accessibilitySortPriority(7)
                        legendRow(ACABTheme.axonTone, "Body cam").accessibilitySortPriority(6)
                        if alpr.enabled { knownALPRKey.accessibilitySortPriority(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        legendRow(ACABTheme.trackerTone, "Tracker").accessibilitySortPriority(5)
                        legendRow(ACABTheme.glassesTone, "Glasses").accessibilitySortPriority(4)
                        legendRow(ACABTheme.netcamTone, "Network camera").accessibilitySortPriority(3)
                        if alpr.enabled && alpr.showUnverified { lowerConfidenceKey.accessibilitySortPriority(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
            }
            // The dim treatment, named. A pin persisted from yesterday used to look exactly like a
            // live hit, so the cue only works if the card says what it means. The swatch is the
            // ALPR tone at the very alpha a stale pin draws at, so it reads as a colour already in
            // the card at lower strength rather than as another category. Gated on a stale pin
            // actually being drawn (MapSnapshot.hasStalePins). The two conditional keys name
            // the treatment, then its meaning, lowercase-first like every row (R19): the same
            // words and case as Android's LegendRow twins in MapScreen.kt.
            if snap.hasStalePins {
                Divider().overlay(ACABTheme.line)
                legendEntry("dimmed: last heard over an hour ago") {
                    Circle().fill(ACABTheme.flockTone.opacity(MapPinRules.staleTintAlpha))
                        .frame(width: 10, height: 10)
                }
            }
            // The ring-peek cue, named. Gated on a ring actually peeking right now: `alprPeeking`
            // is state kept by installALPRVisible, so the legend never scans the ring set.
            if alpr.enabled && alprPeeking {
                Divider().overlay(ACABTheme.line)
                // The widest swatch in the card, and the reason the slot exists: the whole cue
                // is "this ring is bigger", so the swatch has to be bigger too.
                legendEntry("wide ring: live hit at a mapped camera") {
                    ZStack {
                        Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 1.6)
                            .frame(width: 13, height: 13)
                        Circle().fill(ACABTheme.text).frame(width: 7.5, height: 7.5)
                    }
                }
            }
            // The drone operator's person marker, named. Gated on an operator marker actually
            // being drawn (MapSnapshot.hasOperatorPins). The swatch is OperatorPin at legend
            // size: the same glyph and ink on the same bg3 disc, filling the swatch slot.
            // TWIN: android MapScreen.kt's expanded legend "Drone operator" row
            // (mapOperatorPinFlag).
            if snap.hasOperatorPins {
                Divider().overlay(ACABTheme.line)
                legendEntry("Drone operator") {
                    Image(systemName: "person.fill").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(ACABTheme.text)
                        .frame(width: Self.legendSwatchSlot, height: Self.legendSwatchSlot)
                        .background(ACABTheme.bg3, in: Circle())
                }
            }
        }
        .padding(.top, 8)
    }

    /// The reference layer's data credit, gated on the layer being on. At default sizes drawn by
    /// `legendCard` outside the scrolling keys, so a capped card still shows it without a
    /// scroll; at accessibility sizes it ends the scrolling `legendBody`.
    private var legendCredit: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(ACABTheme.line)
            Text("cameras: OpenStreetMap ODbL · DeFlock")
                .font(ACABTheme.font(.footnote))
                .foregroundStyle(ACABTheme.mapInfoText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    /// The legend's overflow form: a scroll view with a visible cue. The indicator flashes when
    /// the form appears, and 16pt fades at both edges show that rows continue past the divider
    /// above and the credit below: a row cut at either edge fades out instead of ending in a hard
    /// line. The content carries 12pt of padding at each end, so at rest (top or bottom) a fade
    /// reaches only 4pt into the first or last row, inside the blank above or below its label
    /// (a legend row is at least 34pt tall).
    private func legendScroll<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView { content().padding(.vertical, 12) }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
            }
    }

    /// The accessibility-size form where the header row scrolls with the keys (see `legendCard`).
    /// Only the bottom edge fades: at rest the header sits at the top, where legendScroll's top
    /// fade would dim the headline's first line and the close control.
    private func legendHeaderScroll<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
            }
        }
    }

    /// Known-ALPR ring key: the hollow solid ring a confirmed mapped camera draws. Gated on the
    /// layer being on.
    private var knownALPRKey: some View {
        legendEntry("Known ALPR") {
            Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 2)
                .frame(width: 9, height: 9)
        }
    }

    /// Unverified tier. Hollow + DASHED, matching ALPRDot: the swatch has to be the shape you
    /// actually see on the map, and it cannot be a filled amber dot because ACABTheme.warn IS
    /// droneTone (both 0xF2B53C) - a filled one is pixel-identical to the Drone key.
    ///
    /// Gated on showUnverified for the same reason it is gated on alpr.enabled: a legend that
    /// names a colour nothing on screen is using reads as a rendering bug.
    private var lowerConfidenceKey: some View {
        legendEntry("ALPR (lower confidence)") {
            Circle().strokeBorder(ACABTheme.warn.opacity(0.95),
                                  style: StrokeStyle(lineWidth: 2, dash: [2, 1.8]))
                .frame(width: 9, height: 9)
        }
    }

    /// One category key: a 10pt dot in the category hue.
    private func legendRow(_ c: Color, _ t: String) -> some View {
        legendEntry(t) { Circle().fill(c).frame(width: 10, height: 10) }
    }

    /// The one legend row layout: the swatch (hidden from VoiceOver) in the fixed slot, then the
    /// label, spoken as ONE element so a sort priority sits on the element VoiceOver visits.
    private func legendEntry<S: View>(_ t: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 10) {
            legendSwatch(swatch).accessibilityHidden(true)
            Text(t).font(ACABTheme.font(.subheadline))
                .foregroundStyle(ACABTheme.mapInfoText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 34, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Width of the legend's swatch column. Every swatch sits centred in this SAME fixed slot, so a
    /// row whose swatch is bigger - the ring-peek one, which has to be bigger, that IS the cue -
    /// cannot push its label out of line with the rest of the column. Sized to the widest swatch.
    /// Android's LegendRow does the same with a 12dp box.
    private static let legendSwatchSlot: CGFloat = 13

    private func legendSwatch<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(width: Self.legendSwatchSlot, height: Self.legendSwatchSlot)
    }

    // MARK: Empty state

    /// True when the "empty" story is a permission problem, not a data one. Demo mode exempts
    /// itself: its seeds carry coordinates regardless of the phone's location permission.
    private var emptyBecausePermission: Bool { ble.locationDenied && !ble.demoMode }
    private var emptyBecauseHistoryScope: Bool {
        !emptyBecausePermission && historyScope != .all && snapshot.retainedLocated > 0
    }

    /// Three empty stories over the same slot. Permission off gets the actionable one (OPEN
    /// SETTINGS). A scope story (Active or Recent) says the window is empty while older located
    /// detections are retained, with SHOW ALL HISTORY. Otherwise it is the honest "nothing
    /// located yet". Detections existing is the fourth state: the banner never mounts (see
    /// mapLayout) and the camera fits to them.
    ///
    /// The card is bounded to the map region above the lower-right stack (mapLayout pads it by
    /// `mapFloatingStackReserve`; an open legend card draws over it, as over the map): at
    /// accessibility sizes the permission sentence alone can outgrow the region between the scope
    /// header and that reserve, which would push OPEN SETTINGS / SHOW ALL HISTORY under the
    /// floating buttons. ViewThatFits keeps the unscrolled card whenever it fits and falls back
    /// to a scroll view over the region.
    private var emptyBanner: some View {
        ViewThatFits(in: .vertical) {
            emptyBannerCard(scrolling: false)
            ScrollView {
                emptyBannerCard(scrolling: true).padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .scrollIndicatorsFlash(onAppear: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The banner card. `scrolling` is the overflow form inside `emptyBanner`'s scroll view,
    /// which keeps hit-testing on so the informational variant can be scrolled to read.
    private func emptyBannerCard(scrolling: Bool) -> some View {
        VStack(spacing: 9) {
            Image(systemName: emptyBecausePermission ? "location.slash"
                  : emptyBecauseHistoryScope ? "clock.arrow.circlepath" : "mappin.slash")
                .font(ACABTheme.font(.title)).foregroundStyle(ACABTheme.faint)
            if emptyBecausePermission {
                Text("Location is off, so the app can't record where your phone heard detections. Drones that broadcast Remote ID coordinates can still appear on the map.")
                    .font(ACABTheme.font(.subheadline, weight: .medium)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                // "Open Settings" and "Show All History" are verbatim, in button title case: the
                // same literals as the empty card in Android's MapScreen.kt.
                Button(action: openAppSettings) { emptyBannerAction("Open Settings") }
                    .buttonStyle(.plain)
            } else if emptyBecauseHistoryScope {
                Text(emptyScopeTitle)
                    .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.mapInfoText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(emptyScopeBody)
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    historyScopeRaw = MapHistoryScope.all.rawValue
                } label: {
                    emptyBannerAction("Show All History")
                }
                .buttonStyle(.plain)
            } else {
                Text("No located detections yet")
                    .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.mapInfoText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Detections appear here once they're heard with location available.")
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
                    .fixedSize(horizontal: false, vertical: true)
                Text("ALPR, body cam, glasses, network camera and tracker hits use your phone's position; drones report their own.")
                    .font(ACABTheme.font(.caption)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(ACABTheme.mapInfoBackground,
                    in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        // Hit-testing stays ON when a button is present (it has to be tappable); the
        // informational variant lets touches fall through so the map still pans behind it.
        .allowsHitTesting(scrolling || emptyBecausePermission || emptyBecauseHistoryScope)
        .overlay(alignment: .topTrailing) {
            // Dismiss (x) on EVERY variant. It lives in this overlay, layered OVER the card AFTER
            // the .allowsHitTesting above, so it stays tappable even on the informational
            // variant whose card passes gestures through to the map: only the small x region
            // intercepts touches, the rest still pans the map behind.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { emptyDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(ACABTheme.font(.caption, weight: .bold)).foregroundStyle(ACABTheme.dim)
                    .frame(width: 26, height: 26)
                    .background(ACABTheme.bg3, in: Circle())
                    // 44pt hit target around the 26pt chip.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    /// The scope story's title and sentence, per window. TWIN: the scope branch of Android's
    /// empty card in MapScreen.kt (the Active pair is contract 5.4's, the same words on both).
    /// The Active number comes from activeNearbyInterval, never a literal.
    private var emptyScopeTitle: String {
        historyScope == .active ? "No active located detections" : "No recent located detections"
    }
    private var emptyScopeBody: String {
        historyScope == .active
            ? "The Active map covers the last \(Int(activeNearbyInterval)) seconds. Older located detections are still retained in the Log."
            : "The Recent map covers the previous 15 minutes. Older located detections are still retained in the Log."
    }

    /// The banner's two actions: tint words on their own tint pill (ACABPalette.pillFillAlpha),
    /// on the bg2 card (a tinted pill never sits on bg3).
    private func emptyBannerAction(_ title: String) -> some View {
        Text(title).font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// T5: on regular width the tapped dossier rides in a trailing `.inspector` (the map + pin
/// stay on screen); on compact it is a `.sheet` that opens at the medium detent, so the pin
/// stays on screen there too. Only one is ever active.
/// SwiftUI ships only `inspector(isPresented:)`, so presentation is derived from the item.
/// Both arms carry a NavigationStack and a Done item (C12); the dossier supplies its own inline
/// title. The sheet pins its background to bg (a sheet runs at the elevated interface level).
///
/// The inspector arm ignores the container's top safe area (R23, owner 2026-09-27: "fix the ipad
/// black bar too"). `.inspector` hosts the content in a UIKit split-view container
/// (BridgedInspectorRepresentable), and SwiftUI places that container INSIDE the page's safe
/// area, below the navigation bar, not under it the way a plain page is laid out: measured on
/// the iPad Pro 13-inch (M5) iOS 26.5 simulator, dark, the sample banner up, `-demo -tab 1`, the
/// page's hosting view spans y 100 to 1376 with the 64pt bar background at y 100 (the 54pt bar
/// under a 10pt margin, the floating tab bar in its centre at regular width), while the
/// inspector container and the map inside it started at y 164 with a top safe-area inset of 0.
/// Nothing in the map could reach the row: the row showed the page hosting view's own opaque
/// background through the bar's glass, as a solid band (a loud colour behind `mapLayout`, the
/// shell background, `toolbarBackgroundVisibility(.hidden)` for either bar and hiding either bar
/// all left it black). Ignoring the top safe area on the container extends it to y 100; UIKit
/// then hands the column's hosting view the bar as ITS safe area (64pt), so the map's layout
/// frame still starts under the bar with the same height (`mapRegionHeight` unchanged), MapKit
/// paints its tiles under the bar as it does under the iPhone's inline bar, the bar's own
/// material blurs them, and the scope header inset, the compass, the overlays and the empty
/// banner keep laying out under the row. The compact arm has no container: the sheet's page is
/// laid out under its bar already (top inset 64 measured on the iPhone 17 Pro Max), so it is not
/// touched.
///
/// The same arm keeps the tab bar with `toolbarVisibility(.visible, for: .tabBar)`. With the
/// container under the row, presenting the inspector made UIKit hide the floating tab bar and
/// draw the dossier's inline title in the row's centre instead (measured on the same simulator,
/// a pin selected: the tab bar's cells were still in the hierarchy 1 s after the selection and
/// gone from the row 6 s later, the outer navigation bar then holding an "ALPR" label at its
/// centre; the inspector's Done item sits in that outer bar with either placement). The dossier
/// hides the tab bar itself: `DetectionDetailView` applies
/// `.toolbar(embedded ? .visible : .hidden, for: .tabBar)`, and `dossier(_:)` leaves `embedded`
/// at its default `false`. The dossier's own NavigationStack is what carries that preference to
/// the outer TabView once the container overlaps the bar row: with the inspector content
/// stripped of its NavigationStack, or with that bar hidden, the tab bar stayed. The Log's
/// two-pane (`DetectionsView.detailPane`) is the other way round: it passes `embedded: true`, so
/// its dossier keeps the tab bar itself, and the `.toolbar(.visible, for: .tabBar)` DetectionsView
/// puts over it is a guard, not a counterpart of this one. The shared dependency is that
/// `embedded ? .visible : .hidden` line: a change there must revisit this arm. Forcing the tab bar visible on
/// this arm keeps the shipped look (the tab bar in the row's centre, no dossier title there, Done
/// at the trailing end) with the tiles under the row; the modifier is the default state
/// everywhere else, so it changes nothing when no dossier is open.
private struct DossierPresentation: ViewModifier {
    @Binding var selected: Detection?
    let regular: Bool
    @EnvironmentObject private var ble: BLEManager

    private func dossier(_ d: Detection) -> some View {
        NavigationStack {
            DetectionDetailView(detection: d)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { selected = nil }
                    }
                }
        }
        .environmentObject(ble)
        .presentationBackground(ACABTheme.bg)
    }

    func body(content: Content) -> some View {
        if regular {
            content.inspector(isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            )) {
                if let d = selected {
                    dossier(d)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
            }
            // R23: the container under the bar row, not below it, and the floating tab bar kept
            // while the dossier is open (see the type's doc comment for both).
            .ignoresSafeArea(.container, edges: .top)
            .toolbarVisibility(.visible, for: .tabBar)
        } else {
            // Half height first, so the tapped pin stays visible under the dossier (HIG Maps:
            // keep the location on the map visible while a place card is up; MapTabView's
            // keepPinVisibleUnderSheet pans a low pin into the uncovered strip); the map stays
            // interactive under the medium detent, and the large detent reaches the mini map
            // and Copy MAC Address. The cluster sheet from this view uses the same two detents.
            content.sheet(item: $selected) { (d: Detection) in
                dossier(d)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
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

/// Artwork numbers of the detection pin, read by MapPin and by the ring-peek derivation
/// (ALPRRingPeek.diameter, AlprRingPeekTests). iOS's own numbers: Android derives its own pin
/// footprint from its own artwork, and neither side copies the other's.
enum MapPinArtwork {
    static let discDiameter: CGFloat = 30   // category fill; the white ring is drawn INSIDE this frame
    static let ringWidth: CGFloat = 3
    static let glyphSize: CGFloat = 14
    static let shadowRadius: CGFloat = 4    // neutral drop shadow (a legibility edge, not a glow)
    static let shadowOffsetY: CGFloat = 2
    static let pingScale: CGFloat = 1.9     // the FRESH ping ring's largest scale
}

/// Animated category pin: a flat category disc with a white ring, a dark glyph, a neutral drop
/// shadow, and a slow ping ring. `animated: false`
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
    /// Dense/far projections keep the category glyph and hit target but drop the per-marker drop
    /// shadow; hundreds of offscreen-rendered shadows are a disproportionate compositing cost.
    var simplified = false
    @State private var ping = false
    // Reduce Motion drops the looping ping ring entirely, same as the dense-map cap does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pin's tone at the current age. Dimming is done with COLOUR ALPHA rather than a
    /// .saturation / .grayscale modifier: those install a layer colour filter on every pin that
    /// carries one, and this map draws pins up to its own cap. Over the map's near-black ground
    /// a lowered alpha reads as the same hue, washed out, which is the cue.
    private var tone: Color { dimmed ? type.tint.opacity(MapPinRules.staleTintAlpha) : type.tint }
    /// The white ring (C11) dims with the tier, so a stale pin reads as a lower intensity
    /// everywhere, ring included.
    private var ringTone: Color { dimmed ? ACABTheme.text.opacity(MapPinRules.staleTintAlpha) : ACABTheme.text }

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle().stroke(tone, lineWidth: 2)
                    .frame(width: MapPinArtwork.discDiameter, height: MapPinArtwork.discDiameter)
                    .scaleEffect(ping ? MapPinArtwork.pingScale : 0.9).opacity(ping ? 0 : 0.7)
            }
            Circle().fill(tone)
                .frame(width: MapPinArtwork.discDiameter, height: MapPinArtwork.discDiameter)
                .overlay(Circle().strokeBorder(ringTone, lineWidth: MapPinArtwork.ringWidth))
                // A neutral legibility edge against the map tile, not a glow; `simplified`
                // drops it on dense or far projections.
                .shadow(color: .black.opacity(simplified ? 0 : 0.5), radius: MapPinArtwork.shadowRadius,
                        x: 0, y: MapPinArtwork.shadowOffsetY)
            // Artwork inside a fixed disc, so a fixed size. Bold, which the higher-contrast
            // weight step leaves unchanged.
            Image(systemName: type.symbol).font(.system(size: MapPinArtwork.glyphSize, weight: .bold))
                .foregroundStyle(ACABTheme.onAccent)
            if let badge, badge > 1 { countBadge(badge) }
        }
        .onAppear(perform: updateAnimation)
        .onChange(of: reduceMotion) { (_: Bool, _: Bool) in updateAnimation() }
        .onChange(of: animated) { (_: Bool, _: Bool) in updateAnimation() }
    }

    /// Small corner badge for a same-spot group: "this one pin is several sightings".
    ///
    /// Deliberately NOT ClusterBubble's shape. A count bubble is a neutral count disc sitting
    /// ON the coordinate INSTEAD of a pin, and it means "several things somewhere in this area";
    /// this is a small capsule clipped to the shoulder of an ordinary pin, and it means "several
    /// things at exactly this point". Keeping the pin artwork whole is what keeps the two apart.
    private func countBadge(_ n: Int) -> some View {
        // Three digits would be wider than the pin it hangs off. The exact size stops mattering
        // long before that; the sheet behind the tap still lists every member.
        Text(n < 100 ? "\(n)" : "99+")
            // Fixed size on purpose (a documented exception to Dynamic Type): the count lives inside
            // fixed pin artwork. ACABTheme.fixed keeps the higher-contrast weight step.
            .font(ACABTheme.fixed(12, weight: .semibold, tabular: true))
            // The count stays at full strength on a dimmed pin: the age is the pin's business,
            // the number still has to be readable.
            .foregroundStyle(ACABTheme.onAccent)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(ACABTheme.text, in: Capsule())
            .offset(x: 15, y: -13)
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
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Drone operator")
        .accessibilityHint("Explains this Remote ID operator position")
        .popover(isPresented: $showInfo) {
            Text("operator. this drone broadcasts its pilot's location in its remote ID, so this pin is roughly where it's being flown from.")
                .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.text)
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
/// A filled detection pin (MapPinArtwork: a 30pt disc and white ring under a drop shadow)
/// completely covers a 14pt known-ALPR ring, so at map level a hit standing on a mapped camera
/// looked exactly like a hit somewhere nobody has ever mapped. That is the single most useful
/// sentence this map can say, and it was invisible. A ring with a rendered pin on it draws at
/// `diameter` instead of 14pt, so its rim stands clear of the pin's artwork with a readable gap
/// between the two. The ring still draws UNDER the pins and keeps its confirmed/unverified
/// stroke, so a peeking ring is still a hollow static ring and can never be read as a detection
/// of its own.
///
/// Keep in lockstep with Android (MapMarkers.kt rememberAlprMarker + the MapScreen.kt match pass)
/// on the RULE, not on every number: same match radius, same "rendered PINS only, never count
/// bubbles" rule, same "the rim visibly clears the pin's own artwork" requirement. The enlarged
/// DIAMETER is deliberately platform-specific - the two pin artworks are different sizes. Android
/// derives its own number from its own pin (MapMarkers.kt `rememberAlprMarker`); neither side
/// copies the other's.
enum ALPRRingPeek {
    /// A pin this close to a mapped camera is treated as standing ON it. Wide enough to absorb GPS
    /// scatter on both our own fix and the mapper's point, tight enough that the next camera down
    /// the block never claims the hit. SHARED WITH ANDROID - this one IS the same number.
    static let radiusMeters: Double = 25

    /// Outer diameter of a matched ring, derived from THIS platform's pin artwork (MapPinArtwork).
    ///
    /// The pin's outermost static ink is its disc (radius discDiameter / 2 = 15; the white ring
    /// is drawn inside that frame) plus the reach of its neutral drop shadow (blur radius 4 plus
    /// the 2pt y offset): 21pt. The rim has to clear ALL of it. The reason is legibility: a rim
    /// that touches the shadow's edge reads as part of the pin, not as a ring around it.
    ///
    /// ALPRDot strokes with `strokeBorder`, which draws INSIDE the frame, so the rim's inner edge
    /// sits at diameter / 2 - rimLineWidth. Requiring that edge to clear the pin's 21pt reach by a
    /// 1.5pt readable gap gives diameter > 49.4, so 50: the inner edge sits at 25 - 2.2 = 22.8pt,
    /// a 1.8pt band of clean map (3.6-5.4 device pixels at 2x/3x). The old 48 fails this rule
    /// (inner edge 21.8pt).
    ///
    /// Upper bound: the pin's ping ring (the 30pt circle scaled to pingScale 1.9 = 57pt, animated,
    /// dropped above 40 pins and under Reduce Motion) sweeps PAST this rim and fades to zero
    /// opacity as it goes, so the static rim stays readable between pulses. The ping is
    /// deliberately NOT resized: it belongs to the detection, not to the reference layer.
    static let diameter: CGFloat = 50

    /// ALPRDot's rim stroke width. It draws inside the frame, so it sets the rim's inner edge.
    static let rimLineWidth: CGFloat = 2.2

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
    /// clears the pin's disc, white ring and drop shadow, which would otherwise swallow the ring
    /// completely. Same tone, same stroke, same hollow
    /// shape; the diameter moves AND the resting wash is dropped - the fill below says why.
    /// See ALPRRingPeek.diameter for the derivation. The peek ring is hollow on both platforms and
    /// the resting ring keeps its wash on both (TWIN: android MapMarkers.kt rememberAlprMarker).
    var peek: Bool = false
    private var tone: Color { confirmed ? ACABTheme.flockTone : ACABTheme.warn }
    private var size: CGFloat { peek ? ALPRRingPeek.diameter : 14 }
    var body: some View {
        Circle()
            // The resting 14pt dot needs its wash to read at all. The peek ring must NOT have one:
            // the pin already fills the middle, and a wash would tint the very band of clean map
            // that ALPRRingPeek.diameter exists to open up between the pin's drop shadow and this rim.
            .fill(peek ? Color.clear : tone.opacity(confirmed ? 0.20 : 0.10))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(tone.opacity(0.95),
                                           style: StrokeStyle(lineWidth: ALPRRingPeek.rimLineWidth,
                                                              dash: confirmed ? [] : [2.6, 2.2])))
            .accessibilityLabel(confirmed ? "Known ALPR camera, manufacturer attributed"
                                          : "Community ALPR candidate, attribution not structured")
        // Bolder 2026-07-29 (user: rings washed out on the map). Still a HOLLOW STATIC ring: the
        // 'never reads as a live detection' rule holds because detections are filled + animated,
        // not because this was faint. Keep the SHAPE rule in lockstep with Android
        // rememberAlprMarker and with the legend's ring swatches (hollow, static, solid when
        // attributed, dashed at lower confidence, and a peek ring that widens past the pin, which
        // is the only thing that tells a live hit at a mapped camera apart from a live hit nobody
        // has mapped). The peek NUMBER is each platform's own (ALPRRingPeek.diameter); neither
        // side copies the other's.
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

/// A count bubble for a multi-member cluster, sized up a touch for bigger clumps: a neutral
/// disc with a ring, no halo, no glow. A uniform cluster rings in its category hue; a mixed one
/// in white.
private struct ClusterBubble: View {
    let count: Int
    let uniformType: DeviceType?
    private var ringTone: Color { uniformType?.tint ?? ACABTheme.text }
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
            Circle().fill(ACABTheme.bg2).frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(ringTone, lineWidth: 3))
            Text("\(count)")
                // Fixed size on purpose (a documented exception to Dynamic Type): the count lives inside a
                // fixed 34-52pt disc. ACABTheme.fixed keeps the higher-contrast weight step.
                .font(ACABTheme.fixed(count < 100 ? 15 : 13, weight: .bold, tabular: true))
                .foregroundStyle(ACABTheme.text)
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
    ///
    /// A system inset-grouped List with its surfaces pinned for the same reason as the Map options
    /// sheet: this sheet also runs at the elevated interface level, at a `.medium` detent. Page bg,
    /// rows bg2.
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cluster.members, id: \.id) { d in
                        Button { onPick(d) } label: {
                            DetectionRow(detection: d, timeBasis: ble.timeBasis(for: d.id))
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(ACABTheme.bg2)
                } header: {
                    // Literal kept (Android's member sheet spells the same header); a C2
                    // identifier header.
                    Kicker("CLUSTERED AT THIS SPOT")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ACABTheme.bg)
            .navigationTitle("\(cluster.members.count) here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationBackground(ACABTheme.bg)
    }
}
