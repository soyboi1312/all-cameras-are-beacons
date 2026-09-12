import Foundation

/// A bounded presentation of the active, mute-filtered feed. The 14-dot drawing limit never
/// limits counters, changes the Log, or lets Desert's ambient traffic hide a known match.
struct DashboardSighting {
    let detection: Detection
    let lastHeard: Date?
    let watched: Bool

    var matched: Bool {
        watched || (detection.type != .nearbyDevice && detection.type != .unknown)
    }

    var unclassified: Bool { !watched && detection.type == .unknown }
    var radarPriority: Int { watched ? 0 : (matched ? 1 : (unclassified ? 2 : 3)) }
}

struct DashboardSnapshot {
    /// SHARED WITH ANDROID - this one IS the same number: STATUS_RADAR_DOT_CAP in StatusScreen.kt.
    /// Both suites pin the literal 14 rather than the constant, so a one-sided edit fails there.
    static let dotLimit = 14
    var total = 0
    var matched = 0
    var ambient = 0
    var unclassified = 0
    var watched = 0
    var categoryCounts: [DeviceType: Int] = [:]
    var dots: [DashboardSighting] = []
    var strongestMatch: DashboardSighting?
    var strongestAmbient: DashboardSighting?
    var strongestUnclassified: DashboardSighting?

    var strongest: DashboardSighting? { strongestMatch ?? strongestUnclassified ?? strongestAmbient }
    /// First caption line under the radar. TWIN: android StatusScreen.kt
    /// `StatusNearbySummary.radarCaption`, byte-identical; both suites pin the literal.
    var radarCaption: String { "\(dots.count) of \(total) dots · \(Self.dotLimit) max" }
    /// Second caption line. The second clause is the sentence that tells the user the 14-dot cap
    /// does not cap the counters (`total` and the breakdown count every recent device). TWIN:
    /// android StatusScreen.kt `STATUS_RADAR_CAPTION_DETAIL`, byte-identical.
    static let radarCaptionDetail = "matches and stars first · counts include every recent device"

    /// The two count cards that split TOTAL NEARBY, a title and a detail line each. TWIN: android
    /// StatusScreen.kt `STATUS_MATCHED_CARD_TITLE` / `STATUS_MATCHED_CARD_DETAIL` /
    /// `STATUS_AMBIENT_CARD_TITLE` / `STATUS_AMBIENT_CARD_DETAIL`, byte-identical; both suites pin
    /// the four literals. "MATCHED + WATCHED" because a star counts as a match here
    /// (`DashboardSighting.matched`), and the detail names the two things that means.
    static let matchedCardTitle = "MATCHED + WATCHED"
    static let matchedCardDetail = "signatures or exact stars"
    static let ambientCardTitle = "AMBIENT"
    static let ambientCardDetail = "Desert-mode broadcasts"

    /// The far-right recency kicker beside the scan label, naming the window every count on this
    /// screen is filtered to. Built from `activeNearbyInterval` (BLEManager.swift), the default
    /// window of the lastSeenIsStale call `dashboardSnapshot` drops quiet rows with, so the words
    /// cannot drift from the filter. A static let: built once, not on every ~3 Hz body pass.
    /// TWIN: android StatusScreen.kt `STATUS_SEEN_WINDOW_KICKER`, built from
    /// ACTIVE_NEARBY_WINDOW_MS; both suites pin "SEEN < 45s", so retuning one window fails there.
    static let seenWindowKicker = "SEEN < \(Int(activeNearbyInterval))s"

    /// Under the cards, only when there is something to say. TWIN: android StatusScreen.kt
    /// `StatusNearbySummary.unclassifiedLine` / `watchedLine`, byte-identical; both suites pin
    /// them. Unclassified is a dim fact (a wire type this build does not know), not an alert;
    /// watched is the tap that opens the Log's WATCHED lens.
    var unclassifiedLine: String? {
        unclassified > 0 ? "\(unclassified) unclassified · category not recognized by this app" : nil
    }
    var watchedLine: String? {
        watched > 0 ? "\(watched) watched · included in matches" : nil
    }

    /// The six category tiles, in strip order. TWIN: android StatusScreen.kt `STATUS_STRIP_TILES`,
    /// same six tiles in the same order, `label` and `spoken` byte-identical; both suites pin them.
    static let stripTiles: [DashboardStripTile] = [
        DashboardStripTile(type: .flockCamera, label: "ALPR",
                           spoken: "ALPR cameras and Raven audio sensors",
                           counted: [.flockCamera, .flockRaven], toggle: \.flock),
        DashboardStripTile(type: .drone, label: "DRONE", spoken: "drones",
                           counted: [.drone], toggle: \.drone),
        DashboardStripTile(type: .axonBodyCam, label: "BODY", spoken: "body cameras",
                           counted: [.axonBodyCam], toggle: \.axon),
        DashboardStripTile(type: .tracker, label: "TRKR", spoken: "trackers",
                           counted: [.tracker], toggle: \.tracker),
        DashboardStripTile(type: .recordingGlasses, label: "GLAS", spoken: "glasses",
                           counted: [.recordingGlasses], toggle: \.glasses),
        DashboardStripTile(type: .networkCamera, label: "NETCAM", spoken: "network cameras",
                           counted: [.networkCamera], toggle: \.ncam),
    ]

    /// Recent rows behind one tile: every type in `counted`, so the ALPR tile folds Raven in.
    func stripCount(_ tile: DashboardStripTile) -> Int {
        var n = 0
        for type in tile.counted { n += categoryCounts[type] ?? 0 }
        return n
    }
}

/// One tile of the Status category strip. `label` is the drawn width-budget abbreviation ("TRKR",
/// "GLAS"), which a screen reader would speak as gibberish, so `spoken` is what VoiceOver says
/// in its place: plural, because a count follows. TWIN: android StatusScreen.kt `StatusStripTile`.
struct DashboardStripTile: Equatable {
    let type: DeviceType
    let label: String
    let spoken: String
    /// Every type whose recent rows this tile counts. The ALPR tile counts .flockRaven too, which
    /// is why its spoken name covers both, and why both ride the flock `toggle`, the one detector
    /// that produces them.
    let counted: [DeviceType]
    /// The board toggle behind the tile, read off the current status frame.
    let toggle: KeyPath<DeviceStatus, Bool>
}

/// The tile's spoken sentence: name, count, and the detector setting when it is off. "recently
/// heard" is the radar's own word for the 45 s window (`RadarScope`'s summary says "recently
/// heard devices nearby"), so the tile and the dial describe the same thing. TWIN: android
/// StatusScreen.kt `statusCountTilePresentation`'s `contentDescription`, byte-identical; both
/// suites pin the sentence.
func dashboardTileAccessibilityLabel(spoken: String, count: Int, off: Bool) -> String {
    "\(spoken), \(count) recently heard" + (off ? ", detector off" : "")
}

/// Ranks the STRONGEST card and the dot cut: signal, then id. TWIN: android StatusScreen.kt
/// `statusNearbySummary`'s `stronger`/`comesBefore`, which use the same two keys - keep them
/// together, this rule has one owner.
///
/// `lastHeard` is deliberately NOT a key. Recency reads like the better tie-break, but both
/// candidates are already inside the same 45 s window, this comparator re-runs inside `body` on
/// every ~3 Hz publish, and `Date` is sub-millisecond, so a recency key would hand the hero card
/// to whichever of two equally-loud devices advertised most recently and trade the name back and
/// forth several times a second. `id` is a total order that holds still, and the card prints the
/// winner's own last-heard age underneath, so nothing is misreported by holding it.
private func strongerDashboardSighting(_ lhs: DashboardSighting,
                                       than rhs: DashboardSighting) -> Bool {
    if lhs.detection.rssi != rhs.detection.rssi { return lhs.detection.rssi > rhs.detection.rssi }
    return lhs.detection.id < rhs.detection.id
}

func dashboardSnapshot(_ detections: [Detection], now: Date, isDemoMode: Bool,
                       lastHeard: (String) -> Date?, isWatched: (Detection) -> Bool) -> DashboardSnapshot {
    var result = DashboardSnapshot()
    for detection in detections {
        let seen = lastHeard(detection.id)
        guard isDemoMode || (!detection.isHistory && !lastSeenIsStale(seen, now: now)) else { continue }
        let sighting = DashboardSighting(detection: detection, lastHeard: seen,
                                        watched: detection.type == .watched || isWatched(detection))
        result.total += 1
        result.categoryCounts[detection.type, default: 0] += 1
        if sighting.watched { result.watched += 1 }
        if sighting.matched {
            result.matched += 1
            if result.strongestMatch.map({ strongerDashboardSighting(sighting, than: $0) }) ?? true {
                result.strongestMatch = sighting
            }
        } else if sighting.unclassified {
            // A future/retired firmware type is not evidence of an ordinary Desert device.
            result.unclassified += 1
            if result.strongestUnclassified.map({ strongerDashboardSighting(sighting, than: $0) }) ?? true {
                result.strongestUnclassified = sighting
            }
        } else {
            result.ambient += 1
            if result.strongestAmbient.map({ strongerDashboardSighting(sighting, than: $0) }) ?? true {
                result.strongestAmbient = sighting
            }
        }

        // Keep only the best 14, rather than sorting thousands of rows on every clock tick.
        let insertion = result.dots.firstIndex {
            sighting.radarPriority < $0.radarPriority ||
                (sighting.radarPriority == $0.radarPriority && strongerDashboardSighting(sighting, than: $0))
        } ?? result.dots.count
        if insertion < DashboardSnapshot.dotLimit {
            result.dots.insert(sighting, at: insertion)
            if result.dots.count > DashboardSnapshot.dotLimit { result.dots.removeLast() }
        }
    }
    return result
}

/// TWIN: android StatusScreen.kt `statusLastHeardAge`, same strings in the same hero slot -
/// reword one and reword the other. The minute/hour/day branches are defensive totality: the
/// caller only ever hands this a row inside the 45 s freshness window.
func dashboardLastHeardLabel(_ date: Date?, now: Date, isDemoMode: Bool) -> String {
    if isDemoMode { return "sample sighting · not live" }
    guard let date else { return "last heard unknown" }
    let age = max(0, now.timeIntervalSince(date))
    guard age.isFinite else { return "last heard unknown" }
    if age < 1 { return "last heard just now" }
    if age < 60 { return "last heard \(Int(age))s ago" }
    if age < 3_600 { return "last heard \(Int(age / 60))m ago" }
    if age < 86_400 { return "last heard \(Int(age / 3_600))h ago" }
    return "last heard more than a day ago"
}

func dashboardTileOpensSettings(enabled: Bool?, count: Int) -> Bool {
    enabled == false && count == 0
}
