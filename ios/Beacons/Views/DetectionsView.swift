import SwiftUI
import UIKit
import Combine

/// The ordered category set shown as the Log's tools-menu categories and filter chip, and the
/// Map's filter chips, defined once and shared so the surfaces stay in lockstep as categories
/// grow. Each entry carries a representative DeviceType (supplies the tint + glyph), the
/// `DeviceType.category` key it filters on, its labels and its VoiceOver name. "Nearby Device"
/// (Desert-mode ambient noise) is deliberately absent - it is not a filter category.
struct DetectionCategory: Identifiable {
    let type: DeviceType    // representative type: supplies tint + SF Symbol
    let key: String         // the DeviceType.category key this entry filters on
    let chipLabel: String   // label for the Map filter chip, the Log filter chip and the lens footer
    let menuLabel: String   // Title Case label for the Log tools menu's category item and Export label
    let spoken: String      // VoiceOver name: the Map and Log chips, the tools menu, Connect's hears tiles
    var id: String { key }
}

/// One-shot handoff from a Status category tile to the Log tab with that category filter
/// armed. Same static-slot + notification pattern as MapFocus (and deliberately NOT the
/// UserDefaults channel the Live Activity uses): a tile tap must never outlive the session,
/// or a stale persisted category would hijack an unrelated later launch's Log open.
/// MainTabView switches tabs on the notification; DetectionsView consumes the slot exactly
/// once (onAppear when the tab was cold, onReceive when it is already alive).
/// `pendingAll` is the Beacon tab's Saved log row (BEA-iOS): open the Log on All with no category.
enum LogFocus {
    static var pendingCategory: String?
    static var pendingAll = false
    static let notification = Notification.Name("acabFocusLogCategory")
}

/// Whether a row belongs to one of the Log / Map category lenses. WATCHED is deliberately an
/// overlapping category: a starred tracker is still a tracker (and keeps that type's styling),
/// but it is also reachable through WATCHED. A wire row whose type is `.watched` remains capture-
/// time evidence in that category after it is unstarred; only `isCurrentlyWatched` represents the
/// current watchlist and may affect active mute policy elsewhere.
func detectionMatchesCategory(type: DeviceType, category: String?,
                              isCurrentlyWatched: Bool) -> Bool {
    guard let category else { return true }
    if category == DeviceType.watched.category {
        return type == .watched || isCurrentlyWatched
    }
    return type.category == category
}

/// Does an ordinary appearance of the Log run the first-open seen baseline
/// (BLEManager.seedSeenWatermarkOnce)? Pure, so the rule can be pinned by tests rather than only
/// by a SwiftUI lifecycle callback. A wrong answer here is not cosmetic: the baseline marks
/// everything already stored as seen, so running it inside a seeded NEW visit empties the very
/// lens a notification tap exists to show, and the user reviewing that tap reads "Nothing new".
///
/// `deepLinkNew` is the parked acab.pendingNewFilter flag. The other three describe the seeded
/// NEW visit (see DetectionsView.newVisit): `hasVisit` carries existence separately because nil
/// is a real starting watermark and must not read as "no visit", and `current` is the watermark
/// now. The skip lasts for the whole visit, not for one appearance, because a skipped
/// seedSeenWatermarkOnce is postponed and not cancelled: outside sample data its persisted
/// once-only flag stays unset, so the next appearance inside the visit (a dossier pop, a
/// size-class change) would run it and mark the seeded rows seen.
func logFirstOpenBaselineRuns(deepLinkNew: Bool, hasVisit: Bool,
                              visitWatermark: Date?, current: Date?) -> Bool {
    if deepLinkNew { return false }      // this appearance seeds the lens and starts the visit
    guard hasVisit else { return true }  // no visit in progress, so an ordinary first open
    return visitWatermark != current     // the watermark moved under the visit, which ended it
}

/// ALPR, DRONE, BODY CAM, TRACKER, GLASSES, CAMERA (Network camera), and WATCHED. Reuses each
/// type's existing tint + glyph (netcamTone + web.camera.fill for the CAMERA / networkCamera
/// entry). The Log's tools menu offers the six detector categories always and WATCHED only while
/// at least one row belongs (tuneCategories); the Map's chips show a category while it has rows (a
/// selected detector chip stays at zero). `chipLabel` stays in caps (chips and the lens footer);
/// `menuLabel` is the same words in Title Case for the tools menu, where menu items use Apple
/// title-style capitalization. TWIN: Android `LOG_CATEGORIES` (`LogCategory.menuLabel`) in
/// LogScreen.kt.
let detectionCategories: [DetectionCategory] = [
    .init(type: .flockCamera,      key: "ALPR",     chipLabel: "ALPR",        menuLabel: "ALPR",        spoken: "automatic license plate readers"),
    .init(type: .drone,            key: "DRONE",    chipLabel: "DRONE",       menuLabel: "Drone",       spoken: "drones"),
    .init(type: .axonBodyCam,      key: "BODY CAM", chipLabel: "BODY CAM",    menuLabel: "Body Cam",    spoken: "body cameras"),
    .init(type: .tracker,          key: "TRACKER",  chipLabel: "TRACKER",     menuLabel: "Tracker",     spoken: "item trackers"),
    .init(type: .recordingGlasses, key: "GLASSES",  chipLabel: "GLASSES",     menuLabel: "Glasses",     spoken: "recording glasses"),
    .init(type: .networkCamera,    key: "CAMERA",   chipLabel: "NETWORK CAM", menuLabel: "Network Cam", spoken: "network cameras"),
    .init(type: .watched,          key: "WATCHED",  chipLabel: "WATCHED",     menuLabel: "Watched",     spoken: "watched devices"),
]

/// A category filter key's drawn label: "CAMERA" reads "NETWORK CAM", as its chip does. The key
/// is the filter's internal name and belongs only in the export filename slug; everything the
/// user reads (the chip, the lens footer, the Export item) says the label, so one filter has one
/// name on screen (LOG-4). An unknown key passes through. TWIN: Android `logCategoryLabel` in
/// LogScreen.kt.
func logCategoryLabel(_ key: String?) -> String? {
    key.map { k in detectionCategories.first { $0.key == k }?.chipLabel ?? k }
}

/// The tools menu's export submenu label: "Export", or "Export <menuLabel>" while a category
/// filter is on ("Export Network Cam" for the CAMERA key), so a partial export can't be mistaken
/// for the whole log. It reads `menuLabel`, the same words as the chip in menu-item case; an
/// unknown key passes through. TWIN: Android `logExportMenuHeader` in LogScreen.kt,
/// byte-identical.
func logExportMenuLabel(_ key: String?) -> String {
    key.map { k in "Export \(detectionCategories.first { $0.key == k }?.menuLabel ?? k)" } ?? "Export"
}

/// The Log's lens footer, drawn ("1 of 6 retained · NETWORK CAM"). `category` is the drawn label
/// (logCategoryLabel), never the key. TWIN: Android `logLensSummaryText` in LogScreen.kt,
/// byte-identical.
func logLensSummaryText(shown: Int, total: Int, paused: Bool, category: String?) -> String {
    "\(shown) of \(total)\(paused ? " paused" : " retained")\(category.map { " · \($0)" } ?? "")"
}

/// The spoken form of logLensSummaryText. TWIN: Android `logLensSummaryDescription` in
/// LogScreen.kt, byte-identical.
func logLensSummaryDescription(shown: Int, total: Int, paused: Bool, category: String?) -> String {
    "\(shown) matching detections of \(total)\(paused ? " in the paused log" : " retained")"
        + (category.map { " · \($0)" } ?? "")
}

// MARK: - Log scope, cut, counts and time sections (pure; contracts 3.1 to 3.4)

/// The Log's segment axis, in segment order. File scope so the pure cut / count / label
/// functions below, the export and the tests can name it. TWIN: Android `LogScope` in
/// LogScreen.kt (contracts 3.1).
enum StatusScope: Equatable { case active, new, all }

/// Does `d` belong to `scope`? Active = not replayed and in the Active set; New = unseen since
/// the watermark; All = every row. TWIN: Android `logScopeKeeps` in LogScreen.kt (contracts 3.2).
func logScopeKeeps(_ d: Detection, scope: StatusScope, isUnseen: (Detection) -> Bool,
                   activeIDs: Set<String>) -> Bool {
    switch scope {
    case .all:    return true
    case .new:    return isUnseen(d)
    case .active: return !d.isHistory && activeIDs.contains(d.id)
    }
}

/// The segment's cut over the one lens result (the lens runs without the scope axis).
/// TWIN: Android `logScopeCut` in LogScreen.kt (contracts 3.2).
func logScopeCut(_ lensAll: [Detection], scope: StatusScope, isUnseen: (Detection) -> Bool,
                 activeIDs: Set<String>) -> [Detection] {
    guard scope != .all else { return lensAll }          // the lens result itself, no copy
    return lensAll.filter { logScopeKeeps($0, scope: scope, isUnseen: isUnseen, activeIDs: activeIDs) }
}

/// The Active and New segment counts, from the same lens result the segment cuts (so a category
/// or a search narrows the counts too). TWIN: Android `logScopeCounts` in LogScreen.kt
/// (contracts 3.2).
func logScopeCounts(_ lensAll: [Detection], isUnseen: (Detection) -> Bool,
                    activeIDs: Set<String>) -> (active: Int, new: Int) {
    var active = 0, new = 0
    for d in lensAll {
        if logScopeKeeps(d, scope: .active, isUnseen: isUnseen, activeIDs: activeIDs) { active += 1 }
        if isUnseen(d) { new += 1 }
    }
    return (active, new)
}

/// The segment's drawn and spoken label; All carries no count. The drift row "log scope segment
/// labels" reads this whole declaration, so keep its shape. TWIN: Android `logScopeSegmentLabel`
/// in LogScreen.kt (contracts 3.2).
func logScopeSegmentLabel(_ scope: StatusScope, count: Int) -> String {
    switch scope {
    case .active: return "active · \(count)"
    case .new:    return "new · \(count)"
    case .all:    return "all"
    }
}

/// One time section of the Log under the Newest sort (contracts 3.4). A nil title is the untitled
/// section of the Active segment (decision L6): the list draws no header for it.
/// TWIN: Android `LogSection` in LogScreen.kt (contracts 3.4).
struct LogSection { let title: String?; let rows: [Detection] }

/// Splits the shown rows, in feed order, into up to three sections: the Active set (not replayed,
/// in `activeIDs`); rows whose LAST-SEEN stamp falls on `now`'s local calendar day with a
/// trustworthy LAST-SEEN basis (.exact / .reconstructed); everything else. Empty sections are
/// dropped. One pass, plain Date compares per row; the calendar is consulted once.
/// Under the Active segment (decision L6) every shown row was heard in the last 45 s, so the
/// header would only repeat the segment: the rows come back as ONE untitled section, with no
/// per-row work at all. All and New keep the three sections.
/// TWIN: Android `logSections` in LogScreen.kt (contracts 3.4; its `!d.offline` arm is the
/// Android spelling of "this row's last-seen stamp is a live clock reading").
func logSections(_ shown: [Detection], scope: StatusScope, activeIDs: Set<String>,
                 stamp: (String) -> Date?, basis: (String) -> TimeBasis, now: Date,
                 calendar: Calendar) -> [LogSection] {
    if scope == .active { return shown.isEmpty ? [] : [LogSection(title: nil, rows: shown)] }
    let day = calendar.dateInterval(of: .day, for: now)
    var active: [Detection] = [], today: [Detection] = [], older: [Detection] = []
    for d in shown {
        if !d.isHistory && activeIDs.contains(d.id) { active.append(d); continue }
        // The date test runs first on purpose: `basis` costs a dictionary lookup per row, and
        // only rows stamped today need it.
        if let day, let s = stamp(d.id), s >= day.start, s < day.end {
            switch basis(d.id) {
            case .exact, .reconstructed: today.append(d); continue
            case .bracketed, .unknown: break
            }
        }
        older.append(d)
    }
    return [LogSection(title: BLEManager.activeSectionHeader, rows: active),
            LogSection(title: DetectionsView.earlierTodaySectionHeader, rows: today),
            LogSection(title: DetectionsView.olderSectionHeader, rows: older)]
        .filter { !$0.rows.isEmpty }
}

/// Which button the no-match panel offers (logNoMatchAction).
enum LogNoMatchAction: Equatable { case clearFilters, showAll }

/// "Clear Filters" only while a filter is actually on (a search, a category or Offline only); a
/// segment is not a filter (C10), so an empty Active or New segment with no filter on offers
/// "Show All" (moves to the All segment) instead, and the All segment with no filter on (which
/// cannot be empty while the feed has rows) offers nothing. `searching` is true while the search
/// field holds a query. TWIN: Android `logNoMatchAction` in LogScreen.kt, same rule (review
/// finding CON-13).
func logNoMatchAction(scope: StatusScope, category: String?, searching: Bool,
                      offlineOnly: Bool) -> LogNoMatchAction? {
    if searching || category != nil || offlineOnly { return .clearFilters }
    return scope != .all ? .showAll : nil
}

/// What one LogFocus handoff seeds. pendingAll (the Beacon tab's Saved log row) wins over a
/// category, and the consumer clears both slots, so a stale category can never hijack a later visit.
struct LogFocusSeed: Equatable { let scope: StatusScope; let category: String? }
func logFocusSeed(pendingAll: Bool, pendingCategory: String?) -> LogFocusSeed? {
    if pendingAll { return LogFocusSeed(scope: .all, category: nil) }
    if let pendingCategory { return LogFocusSeed(scope: .all, category: pendingCategory) }
    return nil
}

/// The Log tab: the retained detection store as an inset-grouped List under the large "Log"
/// title, with the system search field, an active / new / all segment, a chip row for the tools
/// menu's category and offline filters, time sections under the Newest sort, and a select mode
/// for bulk-muting rows.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var scope: StatusScope = .all   // active / new / all (C10)
    // The tools menu's Offline only filter: independent of the segment, shown as a chip while on.
    @State private var offlineOnly = false
    @State private var searchText = ""
    @State private var sortOrder: DetectionLogSort = .newest
    // The seeded NEW visit, or nil. A NEW deep link starts one (the acabOpenLogNew arm, or
    // onAppear's flag branch on a cold tab) and records the seen watermark as it stood then.
    // While that record still equals ble.seenWatermark, masterList's onAppear skips the
    // first-open baseline, so a dossier pop or a size-class change inside the visit cannot mark
    // the seeded rows seen. The arm says what ends a visit and what a visit fails to end on.
    @State private var newVisit: SeededNewVisit?
    // Bumped by every seed so a seeded list starts at the top (seedLens writes it, masterList
    // applies it). A counter, not a flag: two seeds in a row must each scroll, and the value
    // doubles as the seed's identity for the applied record below.
    @State private var seedScrollToken = 0
    // The last seed this list actually scrolled for, and whether the list was on screen at the
    // time. A seed can land on a loaded list while another tab is showing (see the acabOpenLogNew
    // arm), and a scroll aimed at a list that has no layout can be dropped, so an off-screen
    // application is deliberately not recorded and the next appearance applies it again.
    @State private var appliedScrollToken = 0
    @State private var listOnScreen = false
    @State private var selecting = false   // bulk-select mode
    @State private var selection: Set<String> = []   // selected Detection.id
    @State private var exportFile: ExportFile?
    @State private var exportProblem: ExportProblem?
    @State private var confirmClear = false           // gate the destructive log wipe
    // Pause the live feed so a fast-scrolling list can actually be read. Paused freezes the
    // DISPLAYED rows to a snapshot; the store keeps accumulating in BLEManager (nothing is
    // dropped), and resume snaps back to live. The frozen export also owns NEW and time metadata,
    // so the visible row and any file made from it cannot drift apart.
    @State private var paused = false
    @State private var frozenExport: BLEManager.DetectionExportSnapshot?
    // The pause instant. A paused feed's Active cut, its "active · N" count and its time sections
    // are evaluated against it and stay frozen (C10); set and cleared with `paused`.
    @State private var pausedAt: Date?
    // The two things body reads out of that snapshot, taken ONCE at the freeze. Both are computed
    // properties on DetectionExportSnapshot (a full map, and a full Set build), and the store
    // keeps filling while paused - that is the point of pause - so body re-read them on every
    // ~3 Hz publish, over the whole capped store, in the one state the user entered to make the
    // screen hold still. The live path pays neither.
    @State private var frozenRows: [Detection] = []
    @State private var frozenIDs: Set<String> = []
    // T3: on regular width the log is a two-pane master/detail; this drives the right pane.
    // Never set at compact width, so the phone-portrait path is untouched.
    @State private var selectedDetail: Detection?
    @Environment(\.horizontalSizeClass) private var hSize
    // Accessibility text sizes pad the scroll bottom, stack the select bar and the filter chips,
    // and replace the segmented scope control with three checkmark rows (scopePicker).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // The Active boundary and the local day move with the clock, so the list needs a tick. It is
    // NOT a `now` state: see refreshActiveBoundary for why a quiet second writes nothing.
    @State private var activeTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var activeRevision = 0
    @State private var logDay = Calendar.current.startOfDay(for: Date())

    /// The time-section headers after the Active one (BLEManager.activeSectionHeader). Copy
    /// headers, so they render lowercase as written (Kicker carries .textCase(nil)).
    /// TWIN: Android LOG_EARLIER_TODAY_HEADER / LOG_OLDER_HEADER in LogScreen.kt (contracts 3.4).
    static let earlierTodaySectionHeader = "earlier today"
    static let olderSectionHeader = "older"

    private struct ExportProblem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// One seeded NEW visit (see `newVisit`). A struct, not a bare `Date?`, because nil is a real
    /// starting watermark (no mark was ever set) and must not read as "no visit".
    private struct SeededNewVisit: Equatable { let watermark: Date? }

    /// The inputs the Log lens reads, so an equal key means the previous result is still the
    /// right one. Every member is either @State on this screen or @Published on the manager,
    /// which is what makes the memo safe: body re-runs when any of them moves. ADD A MEMBER
    /// HERE whenever the lens learns to read something new - a missing axis shows the user a
    /// filtered list that no longer matches the store, and a Log that under-reports is hidden
    /// evidence, not a cosmetic bug.
    ///
    /// Declared cheapest-first on purpose: the synthesized `==` compares in declaration order
    /// and short-circuits, so a keystroke, a filter tap or a select-mode tap usually decides on
    /// the scalars and never walks the row array.
    private struct LogLensKey: Equatable {
        let paused: Bool          // also covers frozenExport, which only changes with it
        /// The lens itself runs with `unseenOnly: false`, but the New cut and the New count
        /// downstream read `isUnseen` and key on this memo's generation (lensGeneration), so the
        /// axes `isUnseen` reads stay here. `isUnseen` compares the manager's per-row first-seen
        /// stamps against the watermark, and those stamps do NOT travel with `rows`: Detection
        /// carries no first/last-seen field, and BLEManager.rekey (run from
        /// resolveBracketedHistory at a drain's end sentinel) rewrites the stamps of rows that
        /// were already filed without touching any Detection. The republish that follows can
        /// therefore come back element-wise equal while a row's verdict has flipped from New to
        /// seen. A drain whose begin sentinel promised rows raises syncingOfflineLog, and
        /// handleHistEnd drops it in the same turn it re-keys, so this Bool is the axis that moves
        /// with the rekey. Gap: a drain whose begin sentinel promised no rows never raises it, so
        /// a rekey at that drain's end is not covered. A manager-owned stamp-revision counter
        /// would close that gap and should replace this member when one exists.
        let syncing: Bool
        let offlineOnly: Bool
        let filter: String?
        let sort: DetectionLogSort
        let search: String
        /// `isUnseen` (read by the New cut and count downstream, not by the lens) reads the seen
        /// watermark. markAllSeen advances the pseudo-band baseline in the same call that sets
        /// this Date, so the Date moves whenever either does.
        let watermark: Date?
        /// `isWatched` reads the watchlist, and the search reads the custom names DeviceNames
        /// rebuilds from the watched AND ignored lists, so both belong in the key.
        let watched: [WatchedDevice]
        let ignored: [IgnoredDevice]
        let rows: [Detection]
    }

    /// Memo for the Log lens, and for the query it runs. A reference type held in @State so
    /// filling it during a body eval is a cache write, not a state change SwiftUI would
    /// re-render for.
    ///
    /// Why it exists: with a non-empty search, the lens derives nine fields per row and folds
    /// them, over the whole retained store (liveFeedCap 5,000). `body` re-runs on every one of
    /// the manager's publishes (~3 Hz while detections stream), on every keystroke, and on
    /// every @State write on this screen, and the lens was recomputed from scratch each time.
    /// Two arrays that share storage compare equal without touching an element, so an
    /// unchanged store is decided cheaply; correctness does not rely on that - a changed store
    /// falls back to an ordinary element-wise compare and rebuilds. This is the same
    /// discipline MapTabView applies to its own lens.
    ///
    /// A publish that DID change the store (a re-sighted row's RSSI) still rebuilds the result,
    /// but through `searchIndex`, which keeps every row's folded haystack across publishes and
    /// refolds only a row whose identity text moved (DetectionLogSearchIndex says which fields).
    /// The rebuild is then a substring test per row, not a nine-field derivation plus a fold.
    ///
    /// It also holds the per-feed-emission stamp capture (contracts 3.3) and the four small
    /// memos downstream of the lens (the Active ids, the segment cut, the segment counts and the
    /// time sections), each keyed on generation counters plus the scalars it reads, so an
    /// unchanged publish hands every ForEach the same array storage.
    private final class LogLensMemo {
        private var cachedKey: LogLensKey?
        private var cachedRows: [Detection] = []
        private var cachedText: String?
        private var cachedQuery = DetectionLogQuery("")
        let searchIndex = DetectionLogSearchIndex()
        /// Moves on every rebuild in rows(for:build:). The cut, the counts and the sections key on it.
        private(set) var lensGeneration = 0

        /// One DetectionLogQuery per query change, shared by the list, the empty state and the
        /// export filename qualifier instead of being rebuilt at each call site.
        func query(for searchText: String) -> DetectionLogQuery {
            if cachedText != searchText {
                cachedText = searchText
                cachedQuery = DetectionLogQuery(searchText)
            }
            return cachedQuery
        }

        func rows(for key: LogLensKey, build: () -> [Detection]) -> [Detection] {
            if cachedKey == key { return cachedRows }
            let built = build()
            cachedKey = key
            cachedRows = built
            lensGeneration &+= 1
            return built
        }

        // Once per feed emission (contracts 3.3). `demo` is in the key because the fill reads
        // ble.demoMode (ADD A MEMBER HERE rule of LogLensKey). `syncing` for the reason
        // LogLensKey.syncing gives: a drain-end rekey rewrites stamps under equal rows.
        struct FeedKey: Equatable { let paused: Bool; let syncing: Bool; let demo: Bool; let rows: [Detection] }
        private var feedKey: FeedKey?
        private(set) var feedGeneration = 0
        private(set) var stamps: [String: Date] = [:]   // EVERY row of the feed, live and replayed
        private(set) var feedLive: [Detection] = []     // !isHistory, feed order
        private(set) var liveEnvelope: [Date] = []
        /// feedLive.prefix(k) is the Active set. Written by the fill and by the 1 s tick (a cache write).
        var k = 0

        func captureFeed(_ key: FeedKey, lastSeen: (Detection) -> Date?, evaluatedAt: () -> Date) {
            guard feedKey != key else { return }
            feedKey = key
            var s: [String: Date] = [:]
            s.reserveCapacity(key.rows.count)
            for d in key.rows { if let t = lastSeen(d) { s[d.id] = t } }
            stamps = s
            feedLive = key.rows.filter { !$0.isHistory }
            liveEnvelope = newestFirstEnvelope(feedLive.map { s[$0.id] })
            k = key.demo ? feedLive.count : activeBoundary(liveEnvelope, now: evaluatedAt())
            feedGeneration &+= 1
        }

        private struct IDsKey: Equatable { let feed: Int; let k: Int }
        private var idsKey: IDsKey?
        private var cachedIDs: Set<String> = []
        func activeIDs() -> Set<String> {
            let key = IDsKey(feed: feedGeneration, k: k)
            if idsKey != key {
                idsKey = key
                cachedIDs = Set(feedLive.prefix(k).map(\.id))
            }
            return cachedIDs
        }

        private struct CutKey: Equatable { let lens: Int; let feed: Int; let k: Int; let scope: StatusScope }
        private var cutKey: CutKey?
        private var cachedCut: [Detection] = []
        func cut(_ lensAll: [Detection], scope: StatusScope, isUnseen: (Detection) -> Bool,
                 activeIDs: Set<String>) -> [Detection] {
            let key = CutKey(lens: lensGeneration, feed: feedGeneration, k: k, scope: scope)
            if cutKey != key {
                cutKey = key
                cachedCut = logScopeCut(lensAll, scope: scope, isUnseen: isUnseen, activeIDs: activeIDs)
            }
            return cachedCut
        }

        private struct CountsKey: Equatable { let lens: Int; let feed: Int; let k: Int }
        private var countsKey: CountsKey?
        private var cachedCounts: (active: Int, new: Int) = (0, 0)
        func counts(_ lensAll: [Detection], isUnseen: (Detection) -> Bool,
                    activeIDs: Set<String>) -> (active: Int, new: Int) {
            let key = CountsKey(lens: lensGeneration, feed: feedGeneration, k: k)
            if countsKey != key {
                countsKey = key
                cachedCounts = logScopeCounts(lensAll, isUnseen: isUnseen, activeIDs: activeIDs)
            }
            return cachedCounts
        }

        // The contracts 3.4 key (shownIDs, k, sectionDay, syncing): `shown` is a pure function of
        // (lens result, scope, Active ids), and the Active ids of (feed, k).
        private struct SectionsKey: Equatable {
            let lens: Int; let feed: Int; let k: Int; let scope: StatusScope; let day: Date; let syncing: Bool
        }
        private var sectionsKey: SectionsKey?
        private var cachedSections: [LogSection] = []
        func sections(_ shown: [Detection], scope: StatusScope, activeIDs: Set<String>, day: Date,
                      syncing: Bool, stamp: (String) -> Date?, basis: (String) -> TimeBasis,
                      now: () -> Date) -> [LogSection] {
            let key = SectionsKey(lens: lensGeneration, feed: feedGeneration, k: k, scope: scope,
                                  day: day, syncing: syncing)
            if sectionsKey != key {
                sectionsKey = key
                cachedSections = logSections(shown, scope: scope, activeIDs: activeIDs, stamp: stamp,
                                             basis: basis, now: now(), calendar: .current)
            }
            return cachedSections
        }
    }

    @State private var lensMemo = LogLensMemo()

    /// Built once per query change (see LogLensMemo.query), not once per read.
    private var searchQuery: DetectionLogQuery { lensMemo.query(for: searchText) }

    /// The one lens result, WITHOUT the scope axis (contracts 3.2): the segment cut and both
    /// segment counts come from it.
    private var lensAll: [Detection] {
        // Paused: read from the frozen snapshot so the list holds still. Live otherwise.
        let base = paused ? frozenRows : ble.logDetections
        let key = LogLensKey(paused: paused, syncing: ble.syncingOfflineLog, offlineOnly: offlineOnly,
                             filter: filter, sort: sortOrder, search: searchText,
                             watermark: ble.seenWatermark, watched: ble.watched,
                             ignored: ble.ignored, rows: base)
        let query = searchQuery   // resolved before the memo call, not inside its build closure
        let index = lensMemo.searchIndex
        return lensMemo.rows(for: key) {
            applyDetectionLogLens(base, category: filter, unseenOnly: false,
                offlineOnly: offlineOnly, query: query, sort: sortOrder,
                isUnseen: { isUnseenRow($0) },
                isWatched: { ble.isWatched($0) }, index: index)
        }
    }

    /// The instant sections, the Active boundary and an "-active" export are evaluated against:
    /// the pause instant while paused (C10, frozen), the clock otherwise. Read ONLY inside memo
    /// fills (passed as a closure) and in export(), never directly in body.
    private func evaluationInstant() -> Date { paused ? (pausedAt ?? Date()) : Date() }
    private func isUnseenRow(_ d: Detection) -> Bool {
        paused ? frozenExport?.unseenIDs.contains(d.id) == true : ble.isUnseen(d)
    }

    private func pauseFeed() {
        let snap = ble.detectionExportSnapshot()
        frozenExport = snap
        frozenRows = snap.detections
        frozenIDs = snap.ids
        pausedAt = Date()
        paused = true
    }
    private func resumeFeed() {
        paused = false
        pausedAt = nil
        frozenExport = nil
        frozenRows = []
        frozenIDs = []
        // The first live pass after a long pause must not section against a stale day.
        let today = Calendar.current.startOfDay(for: Date())
        if logDay != today { logDay = today }
    }
    /// Everything one body eval needs from the store and the lens.
    private struct LogSnapshot {
        /// The segment's cut over the lens result; the drift-pinned lens summary reads `snap.shown.count`.
        let shown: [Detection]
        let scopeCounts: (active: Int, new: Int)
        let sections: [LogSection]             // Newest only; [] under Strongest
        /// Rows in the WATCHED category (the wire type or the current watchlist): the tools menu
        /// offers WATCHED only while this is above zero.
        let watchedCount: Int
        /// While paused, how many detections have landed in the live store since the freeze -
        /// the "N new" hint. The store never stops filling; only the display is frozen. Counted
        /// in the one store pass below rather than by its own property.
        let pausedNewCount: Int
    }

    private func makeSnapshot() -> LogSnapshot {
        var watchedN = 0, pausedNewN = 0
        for d in ble.logDetections {                       // the ONE store walk per body pass
            // Same total the old per-category count gave WATCHED: a row the board typed watched,
            // or a row whose MAC is on the current watchlist, counted once.
            if d.type == .watched || ble.isWatched(d) { watchedN += 1 }
            if paused && !frozenIDs.contains(d.id) { pausedNewN += 1 }
        }
        let memo = lensMemo
        let lens = lensAll
        let base = paused ? frozenRows : ble.logDetections
        memo.captureFeed(.init(paused: paused, syncing: ble.syncingOfflineLog, demo: ble.demoMode, rows: base),
                         lastSeen: { paused ? frozenExport?.lastSeen(for: $0.id) : ble.lastSeenDate(for: $0.id) },
                         evaluatedAt: { evaluationInstant() })
        let activeIDs = memo.activeIDs()
        let shown = memo.cut(lens, scope: scope, isUnseen: { isUnseenRow($0) }, activeIDs: activeIDs)
        let counts = memo.counts(lens, isUnseen: { isUnseenRow($0) }, activeIDs: activeIDs)
        // Section 2's basis is the LAST-SEEN basis on both paths (contracts 3.4): the stamp form of
        // timeBasis live, the frozen lastSeenBasis while paused. timeBasis(for:) without a stamp is
        // the FIRST-seen basis and is wrong here.
        let sections: [LogSection] = sortOrder == .newest
            ? memo.sections(shown, scope: scope, activeIDs: activeIDs,
                            day: paused ? (pausedAt.map { Calendar.current.startOfDay(for: $0) } ?? logDay) : logDay,
                            syncing: ble.syncingOfflineLog,
                            stamp: { memo.stamps[$0] },
                            basis: { id in paused ? (frozenExport?.lastSeenBasis(for: id) ?? .unknown)
                                                  : ble.timeBasis(for: id, stamp: memo.stamps[id]) },
                            now: { evaluationInstant() })
            : []
        return LogSnapshot(shown: shown, scopeCounts: counts, sections: sections,
                           watchedCount: watchedN, pausedNewCount: pausedNewN)
    }

    /// The 1 s tick's whole job: move the Active boundary and the local day, writing state only when
    /// one of them moved. A quiet second costs one binary search and one start-of-day.
    private func refreshActiveBoundary(now: Date) {
        guard listOnScreen, !paused else { return }
        let memo = lensMemo
        let newK = ble.demoMode ? memo.feedLive.count : activeBoundary(memo.liveEnvelope, now: now)
        if newK != memo.k { memo.k = newK; activeRevision &+= 1 }
        let day = Calendar.current.startOfDay(for: now)
        if day != logDay { logDay = day }
    }

    var body: some View {
        // Read so SwiftUI re-runs body when refreshActiveBoundary moves the Active boundary: a
        // @State that body never reads does not invalidate it, so this read is what makes the
        // tick's write count.
        let _ = activeRevision
        let snap = makeSnapshot()   // ONE store pass per body eval; everything below reads this
        NavigationStack {
            layout(snap)
                // R8: if the selected detection disappears (clear log / capped-store eviction) while its
                // dossier is open in the two-pane, drop the selection so the pane returns to the
                // placeholder instead of showing a detection that no longer exists.
                .onChange(of: ble.logDetections) {
                    if let d = selectedDetail, !ble.logDetections.contains(where: { $0.id == d.id }) {
                        selectedDetail = nil
                    }
                    // Log cleared out from under a paused view: drop the frozen snapshot so we
                    // don't keep showing rows that no longer exist and can't be resumed away from.
                    if paused && ble.logDetections.isEmpty { resumeFeed() }
                }
                // WATCHED exists only while it has a member: the tools menu offers it only then.
                // If the last member is removed, return to ALL before the tools menu stops
                // offering it, so no hidden filter is stranded on screen.
                .onChange(of: snap.watchedCount, initial: true) { _, count in
                    if filter == DeviceType.watched.category, count == 0 { filter = nil }
                }
        }
    }

    /// Regular width: two-pane master/detail (list left, dossier right). Compact:
    /// the single-column Log.
    @ViewBuilder
    private func layout(_ snap: LogSnapshot) -> some View {
        if hSize == .regular {
            HStack(spacing: 0) {
                masterList(snap).frame(width: 380)
                Divider().overlay(ACABTheme.line)
                ZStack {
                    ACABTheme.bg.ignoresSafeArea()
                    detailPane
                }
                .frame(maxWidth: .infinity)
            }
            // A guard: DetectionDetailView applies `.toolbar(embedded ? .visible : .hidden,
            // for: .tabBar)`, and detailPane passes `embedded: true`, so the dossier keeps the
            // tab bar itself; this keeps it visible should that default ever change under a
            // persistent two-pane (the Map's inspector arm, DossierPresentation, is the
            // non-embedded case and forces the tab bar for a different reason).
            .toolbar(.visible, for: .tabBar)
        } else {
            masterList(snap)
        }
    }

    /// A picked row's full dossier, capped and centered in the right pane; a placeholder
    /// until something is selected.
    @ViewBuilder
    private var detailPane: some View {
        if let d = selectedDetail {
            DetectionDetailView(detection: d, embedded: true)
                .environmentObject(ble)
                .id(d.id)                       // fresh dossier (and its @State) per selection
                .frame(maxWidth: DetectionDetailView.readingWidth)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "scope").font(ACABTheme.font(.largeTitle)).foregroundStyle(ACABTheme.faint)
                Text("Select a detection")
                    .font(ACABTheme.font(.headline)).foregroundStyle(ACABTheme.dim)
                Text("Pick a row to open its full dossier here.")
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    /// Scroll anchor for the top of the master list, parked on the scope picker row (the first
    /// row whenever the store is non-empty); when buffer-health banners lead the list, the seed
    /// scrolls to the first banner's own ForEach id instead.
    private static let topAnchorID = "logTop"

    /// Put the master list back at the top for a seed, at most once per seed.
    /// Called from the token's onChange (the usual path, this list is on screen) and from the
    /// list's onAppear, because the acabOpenLogNew arm also seeds a loaded list that another tab
    /// is covering: the seed and MainTabView's tab switch happen in one update, so that attempt
    /// can reach a list with no layout yet. Only an on-screen application is recorded, which is
    /// what keeps a dropped one from being counted as done, and the appearance that follows the
    /// tab switch then applies the same seed. It hops to the next run loop because the lens
    /// writes and the tab switch are in this update, so the target reaches its final position
    /// first.
    private func applySeedScroll(_ proxy: ScrollViewProxy, onScreen: Bool) {
        guard appliedScrollToken != seedScrollToken else { return }
        let token = seedScrollToken
        DispatchQueue.main.async {
            if let first = ble.status?.bufferHealthNotices.first { proxy.scrollTo(first, anchor: .top) }
            else { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
            if onScreen { appliedScrollToken = token }
        }
    }

    /// The Log screen: the whole view when compact, the left column when regular.
    /// Keeps its own nav / sheet / dialog modifiers so both layouts get them. The vertical order
    /// is fixed (contracts 3.6): buffer-health banners, the controls (scope picker, then the
    /// filter chips), then the content (empty state, no-match state, or the rows).
    ///
    /// Shared rules, TWIN: Android LogScreen's LazyColumn items. The controls are drawn only
    /// while the log has rows: an empty log shows its empty state alone (Android gates its
    /// "log-scope" and "log-filters" items on a non-empty feed the same way). The lens summary
    /// (logLensSummary) is the footer under the rows AND under the no-match panel, never under
    /// the empty state (Android's "log-footer" item follows both the rows and "log-nomatch").
    private func masterList(_ snap: LogSnapshot) -> some View {
        ScrollViewReader { proxy in
            List {
                // Persistent board-side loss/censoring flags belong beside the evidence,
                // not behind a settings disclosure. The Offline Buffer card repeats them.
                if let notices = ble.status?.bufferHealthNotices, !notices.isEmpty {
                    Section {
                        ForEach(notices, id: \.self) {
                            BufferHealthBanner(notice: $0)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                if !ble.logDetections.isEmpty {
                    Section {
                        scopePicker(snap)
                        if paused || filter != nil || offlineOnly { filterChips(snap) }
                    }
                }
                if ble.logDetections.isEmpty {
                    Section { emptyState }
                } else if snap.shown.isEmpty {
                    Section { noMatchState } footer: { logLensSummary(snap) }
                } else if sortOrder == .newest {
                    // An untitled section (the Active segment, decision L6) draws no header.
                    ForEach(snap.sections, id: \.title) { section in
                        Section {
                            ForEach(section.rows) { d in row(d).listRowBackground(ACABTheme.bg2) }
                        } header: {
                            if let title = section.title {
                                Kicker(title).accessibilityAddTraits(.isHeader)
                            }
                        } footer: {
                            if section.title == snap.sections.last?.title { logLensSummary(snap) }
                        }
                    }
                } else {
                    Section {
                        ForEach(snap.shown) { d in row(d).listRowBackground(ACABTheme.bg2) }
                    } footer: {
                        logLensSummary(snap)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ACABTheme.bg)
            // Inside .searchable on purpose: dismissSearch is only readable by a view that the
            // searchable modifier wraps.
            .background(SeedSearchDismisser(token: seedScrollToken))
            // Compact width at accessibility sizes: the header falls back to the large title and
            // the automatic placement becomes the collapsed drawer, which a pull-down reveals and
            // nothing else shows (the AX5 shot had no field at all), so the field is pinned
            // visible there (HIG Searching: give an important search a primary position). The
            // default placement everywhere else, the iPad two-pane included.
            .searchable(text: $searchText,
                        placement: dynamicTypeSize.isAccessibilitySize && hSize != .regular
                            ? .navigationBarDrawer(displayMode: .always) : .automatic,
                        prompt: "Search name, MAC or vendor")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // Extra bottom margin only at accessibility sizes, so grown content never ends
            // under the tab bar; zero at default sizes (layout untouched).
            .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            // Only a seed scrolls (seedLens bumps the token). A lens change the user makes by
            // hand keeps the offset, which is what Android does too: only MainScreen's seeds
            // bump logScreenKey, nothing else re-keys LogScreen. Unanimated, because a seed is
            // a jump to a different lens and not a scroll the user made.
            // Applied from both ends so the seeded lens always ends up at the top: the token's
            // change, and this list's appearance when the seed arrived while it was off
            // screen (applySeedScroll records which seeds it has already served).
            // NOT device-verified this round: where SwiftUI settles when the lens and the
            // scroll move in one update still needs a run on hardware.
            .onChange(of: seedScrollToken) { applySeedScroll(proxy, onScreen: listOnScreen) }
            .onAppear {
                // Guarded because a redundant write here would re-run this whole list body.
                if !listOnScreen { listOnScreen = true }
                refreshActiveBoundary(now: Date())
                applySeedScroll(proxy, onScreen: true)
            }
            .onDisappear { listOnScreen = false }
            .onReceive(activeTick) { refreshActiveBoundary(now: $0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectBar(snap) }
        }
        // One header row: "Log" leading, the tools menu (or Done in select mode) trailing
        // (TabHeader, M2). The .searchable above is untouched.
        .tabHeader("Log") {
            if selecting {
                Button("Done") { exitSelect() }
            } else {
                logToolsMenu(snap).disabled(ble.logDetections.isEmpty)
            }
        }
        .navigationDestination(for: Detection.self) { d in
            DetectionDetailView(detection: d)
        }
        .onAppear {
            // Every NEW deep link parks this flag before it posts acabOpenLogNew (the arm
            // below lists the posters). It survives to here when no loaded list heard that
            // post, as on a cold tab; consume it once and start the seeded NEW visit.
            let deepLinkNew = UserDefaults.standard.bool(forKey: "acab.pendingNewFilter")
            let runBaseline = logFirstOpenBaselineRuns(
                deepLinkNew: deepLinkNew, hasVisit: newVisit != nil,
                visitWatermark: newVisit?.watermark, current: ble.seenWatermark)
            if deepLinkNew {
                seedLens(scope: .new, category: nil)
                UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
                newVisit = SeededNewVisit(watermark: ble.seenWatermark)
            } else if runBaseline {
                // First ordinary open, baseline the New dots to what is already here so a
                // fresh install / first backlog is not a wall of dots. Once-only outside
                // sample data; in sample data BLEManager.seedSeenWatermarkOnce does nothing,
                // because the sample seed owns that log's baseline (the rows it flags new).
                // Skipped for the whole seeded NEW visit, or the baseline would erase the very
                // rows the link promised.
                if newVisit != nil { newVisit = nil }
                ble.seedSeenWatermarkOnce()
            }
            consumeLogFocus()   // Status-tile / Saved log handoff, cold-tab path
        }
        // Every NEW deep link parks acab.pendingNewFilter, then posts this: RootView.onOpenURL
        // (a Live Activity beacons://log/new tap), DetectionNotifier's
        // userNotificationCenter(_:didReceive:withCompletionHandler:) (a notification tap) and
        // OfflineSyncBannerView.viewNew (the offline-sync banner's view action). A tap while
        // this list is on screen never re-fires onAppear, so the lens is seeded here at post
        // time. This arm also runs while the Log tab is loaded but another tab is selected:
        // MainTabView then switches to it and onAppear follows with the flag already gone.
        // The arm seeds whether or not the list is visible, because a visibility gate that
        // misread a visible list as hidden would drop the tap until some later appearance.
        // Either way the arm starts the seeded NEW visit (newVisit).
        //
        // The baseline skip lasts for the visit, not for one appearance. A skipped
        // BLEManager.seedSeenWatermarkOnce is postponed, not cancelled (its once-only key stays
        // unset), so a skip that ended at the next appearance would run the baseline at the
        // first dossier pop, mark the seeded rows seen and empty the NEW lens under review.
        // A visit ends when the watermark moves under it. MainTabView.onChange(of: tab) calls
        // markAllSeen when the user leaves the Log tab outside sample data
        // (logTabLeaveMarksSeen), and the next appearance then runs the baseline. The Mark Seen
        // menu item moves the watermark too, so it re-records the visit instead of ending it;
        // otherwise the next pop would mark seen every row that arrived after the tap. Android
        // ends its skip at the same point: LogScreen runs
        // seedSeenWatermarkOnce from LaunchedEffect(Unit) only when initialFilter is not
        // NewOnly, once per key(logScreenKey) composition. MainScreen draws the compact dossier
        // as an overlay, so closing it never re-runs that gate, and Mark Seen does not rekey
        // it. The composition ends when the user leaves the Log tab, and a manual tab tap
        // resets logFilterSeed.
        //
        // What a visit fails to end on: a watermark that returns to the recorded value.
        // markAllSeen always stamps a new Date, so while this view exists only
        // BLEManager.exitDemo can do that, by restoring the watermark seedDemoData saved, and
        // only when the watermark had not moved between the record and the start of sample
        // data. The skip then holds until the user next leaves the Log tab. A skip never marks
        // a row seen, so this leaves New dots in place and hides nothing.
        //
        // Regular width is closed: seedLens clears selectedDetail, so the right pane drops
        // back to its placeholder instead of holding a dossier the seeded lens does not list.
        // That is what Android does on the same seeds, where MainScreen calls setSelected(null)
        // in the LaunchedEffect(openLogNew) and in openLogCategory.
        //
        // Not closed, and compact width only: a NEW link that lands while a dossier is PUSHED
        // on this stack seeds the lens under the dossier, which stays on top, so the tap shows
        // no change until the user goes back. That pop is inside the visit and shows the
        // seeded lens. Closing it needs a NavigationStack path the seed resets, a navigation
        // change this fix does not make.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("acabOpenLogNew"))) { _ in
            seedLens(scope: .new, category: nil)
            UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
            newVisit = SeededNewVisit(watermark: ble.seenWatermark)
        }
        // Status-tile / Saved log handoff, warm-tab path (see LogFocus).
        .onReceive(NotificationCenter.default.publisher(for: LogFocus.notification)) { _ in
            consumeLogFocus()
        }
        .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        .alert(item: $exportProblem) { problem in
            Alert(title: Text(problem.title), message: Text(problem.message),
                  dismissButton: .default(Text("OK")))
        }
        .confirmationDialog("Clear \(ble.demoMode ? "sample" : "log") \(ble.logDetections.count) detection\(ble.logDetections.count == 1 ? "" : "s")?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Export CSV First") {
                export(.csv, snapshot: ble.detectionExportSnapshot(), qualifier: nil)
            }
            Button(ble.demoMode ? "Clear Sample" : "Clear Log", role: .destructive) {
                if !ble.clearDetections() {
                    exportProblem = ExportProblem(
                        title: "Couldn't clear log",
                        message: "The saved log could not be secured for deletion. Nothing was cleared. Try again while the phone is unlocked.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ble.demoMode
                 ? "This clears only the sample rows. Your saved detection log stays unchanged."
                 : "This deletes the log on this phone, including the app's copies of earlier exports, and can't be undone. If this is evidence, export it first and save or send it somewhere else. Only a copy outside the app survives.")
        }
    }

    /// The Active / New / All segment. Counts come from the shown lens (contracts 3.2). At
    /// accessibility sizes three full-width checkmark rows replace the segmented control, so no
    /// segment label truncates. They are plain buttons, not an inline Picker: the inline Picker's
    /// selected-row checkmark drew in system blue even with `.tint` on the Picker and on the root,
    /// and crimson is the one accent. The list's top scroll anchor (`topAnchorID`) rides on the
    /// segmented control, or on the first row of the accessibility form.
    @ViewBuilder
    private func scopePicker(_ snap: LogSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ForEach([StatusScope.active, .new, .all], id: \.self) { s in
                scopeRow(s, snap: snap)
                    .id(s == .active ? Self.topAnchorID : "logScope-\(s)")
                    .listRowBackground(ACABTheme.bg2)
            }
        } else {
            scopePickerControl(snap)
                .pickerStyle(.segmented)
                .id(Self.topAnchorID)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    /// One accessibility-size scope row: the segment label, a crimson checkmark on the selected
    /// row, and the selected trait so VoiceOver says which scope is on.
    private func scopeRow(_ s: StatusScope, snap: LogSnapshot) -> some View {
        let label = logScopeSegmentLabel(s, count: s == .new ? snap.scopeCounts.new
                                                              : snap.scopeCounts.active)
        return Button { scope = s } label: {
            HStack {
                Text(label).foregroundStyle(ACABTheme.text)
                Spacer(minLength: 8)
                if scope == s {
                    Image(systemName: "checkmark")
                        .font(ACABTheme.font(.body, weight: .semibold))
                        .foregroundStyle(ACABTheme.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(scope == s ? .isSelected : [])
    }

    private func scopePickerControl(_ snap: LogSnapshot) -> some View {
        Picker(selection: $scope) {
            ForEach([StatusScope.active, .new, .all], id: \.self) { s in
                let label = logScopeSegmentLabel(s, count: s == .new ? snap.scopeCounts.new
                                                                      : snap.scopeCounts.active)
                Text(label).accessibilityLabel(label).tag(s)
            }
        } label: {
            EmptyView()
        }
    }

    /// The one row of filters that are ON, under the segment: the paused pill, the category chip,
    /// the OFFLINE chip. Each chip clears its own filter in one tap. It sits on the page `bg`.
    private func filterChips(_ snap: LogSnapshot) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { filterChipItems(snap) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { filterChipItems(snap) }
                    VStack(alignment: .leading, spacing: 8) { filterChipItems(snap) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func filterChipItems(_ snap: LogSnapshot) -> some View {
        if paused {
            // The store keeps filling behind the frozen list; the pill says how much and resumes.
            let text = snap.pausedNewCount > 0 ? "PAUSED \u{00B7} \(snap.pausedNewCount) NEW" : "PAUSED"
            filterChip(text, systemImage: "play.fill", spoken: "Resume live feed", hint: nil) {
                resumeFeed()
            }
            .accessibilityValue(text)
        }
        if let f = filter, let label = logCategoryLabel(f) {
            // An unknown key passes through logCategoryLabel, so it speaks its own name.
            let spoken = detectionCategories.first { $0.key == f }?.spoken ?? label.lowercased()
            filterChip(label, systemImage: "xmark", spoken: spoken,
                       hint: "Clears this filter") { filter = nil }
        }
        if offlineOnly {
            filterChip("OFFLINE", systemImage: "xmark", spoken: "Offline only",
                       hint: "Clears this filter") { offlineOnly = false }
        }
    }

    /// One tinted chip. `.buttonStyle(.plain)` is required: more than one Button in one List row
    /// fires together unless each has a plain or borderless style.
    private func filterChip(_ text: String, systemImage: String, spoken: String, hint: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text).font(ACABTheme.font(.subheadline, weight: .semibold, tabular: true))
                Image(systemName: systemImage).font(ACABTheme.font(.caption, weight: .bold))
            }
            .foregroundStyle(ACABTheme.tint)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(ACABTheme.tint.opacity(ACABPalette.pillFillAlpha), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint(hint ?? "")
    }

    /// Every Log tool in ONE toolbar menu (contracts 3.6, same items and order as Android's):
    /// sort, category, offline only, pause / resume, select, mark seen, export, clear.
    /// TWIN: Android `LogToolsMenu` and `logToolGates` in LogScreen.kt.
    ///
    /// Mark Seen is offered in sample data on both apps: markAllSeen moves the in-memory
    /// watermark and seenWatermarkWritesAllowed keeps it off disk (Android: the
    /// persistedLogMutationAllowed gate in markAllSeen), so the sample New segment empties and
    /// the real watermark returns on exit.
    /// PLATFORM DIFFERENCE, sample data only: iOS offers "Clear Sample" in place of "Clear Log";
    /// Android's logToolGates hides Clear in sample data. With a real board both menus list the
    /// same items in the same order.
    private func logToolsMenu(_ snap: LogSnapshot) -> some View {
        Menu {
            Picker("Sort Detections", selection: $sortOrder) {
                ForEach(DetectionLogSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Menu("Category") {
                Button { filter = nil } label: { checkLabel("All Categories", on: filter == nil) }
                ForEach(tuneCategories(watchedCount: snap.watchedCount)) { c in
                    Button { filter = c.key } label: { checkLabel(c.menuLabel, on: filter == c.key) }
                        .accessibilityLabel(c.spoken)
                }
            }
            Toggle("Offline Only", isOn: $offlineOnly)
            Divider()
            Button { paused ? resumeFeed() : pauseFeed() } label: {
                Label(paused ? "Resume Live Feed" : "Pause Live Feed",
                      systemImage: paused ? "play.fill" : "pause.fill")
            }
            // Bulk-mute acts on retained Log rows, so select mode starts from the live feed.
            Button { resumeFeed(); selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
            Button { markSeen() } label: { Label("Mark Seen", systemImage: "checkmark") }
            // Both formats carry the CURRENT category filter, and the item names it by the
            // category's menu label ("Export Drone", "Export Network Cam") so a partial export
            // can't be mistaken for the whole log. The key ("CAMERA") stays in the filename slug
            // only.
            Menu {
                Button { export(.csv) } label: { Label("CSV, Shown Rows", systemImage: "tablecells") }
                Button { export(.gpx) } label: { Label("GPX, for Maps", systemImage: "mappin.and.ellipse") }
            } label: {
                Label(logExportMenuLabel(filter), systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) { confirmClear = true } label: {
                Label(ble.demoMode ? "Clear Sample" : "Clear Log", systemImage: "trash")
            }
        } label: {
            Label("Log tools", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private func checkLabel(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    /// The tools menu's categories: the six detector categories always, and WATCHED only while it
    /// has a member (the rule the watched-count reset in body enforces; Android's reset in
    /// LogScreen.kt reads tallies.watchedCount the same way).
    private func tuneCategories(watchedCount: Int) -> [DetectionCategory] {
        detectionCategories.filter { $0.key != DeviceType.watched.category || watchedCount > 0 }
    }

    /// Mark Seen: move the watermark, then show everything. Re-record a live seeded NEW visit
    /// rather than end it (see the acabOpenLogNew arm): ending it would let the next dossier pop
    /// run a pending first-open baseline and mark seen every row that arrived after this tap.
    private func markSeen() {
        ble.markAllSeen()
        if newVisit != nil { newVisit = SeededNewVisit(watermark: ble.seenWatermark) }
        scope = .all
    }

    private func logLensSummary(_ snap: LogSnapshot) -> some View {
        let total = paused ? frozenRows.count : ble.logDetections.count
        // The chip's label, not the filter key (LOG-4): "NETWORK CAM", never "CAMERA".
        let category = logCategoryLabel(filter)
        return Text(logLensSummaryText(shown: snap.shown.count, total: total, paused: paused,
                                       category: category))
            .font(ACABTheme.font(.footnote, tabular: true)).foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(logLensSummaryDescription(shown: snap.shown.count, total: total,
                                                          paused: paused, category: category))
    }

    @ViewBuilder
    private func row(_ d: Detection) -> some View {
        // Resolved once per row: the log is where a buffered record is most likely to be read as
        // a plain timestamp, so the caveat has to travel with it (DetectionRow's provenance
        // overline). This is the FIRST-seen basis; the time sections use the last-seen one.
        let basis = paused ? (frozenExport?.basis(for: d.id) ?? .unknown) : ble.timeBasis(for: d.id)
        if selecting {
            let selected = selection.contains(d.id)
            Button { toggle(d) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(ACABTheme.font(.title3))
                        .foregroundStyle(selected ? ACABTheme.tint : ACABTheme.faint)
                    DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else if hSize == .regular {
            // Two-pane: rows select the right dossier instead of pushing. The selected row keeps
            // the bg2 text surface and gets a leading tint bar (a non-text mark) plus the
            // isSelected trait, its spoken form.
            Button { selectedDetail = d } label: {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                if selectedDetail?.id == d.id {
                    Rectangle().fill(ACABTheme.tint).frame(width: 3)
                }
            }
            .accessibilityAddTraits(selectedDetail?.id == d.id ? .isSelected : [])
        } else {
            // Value-based nav: the destination is built ONCE on tap (via navigationDestination),
            // not eagerly per row. A closure-NavigationLink here would materialize a full
            // DetectionDetailView for every row in the List, so fast-scrolling thousands of
            // rows spiked memory/CPU and crashed the app.
            NavigationLink(value: d) {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
            }
        }
    }

    /// Export the exact rows the user is reviewing. A paused view keeps its row fields, NEW
    /// membership, timestamps, and observer positions frozen together; a live view takes one
    /// authoritative manager snapshot at the tap instead of exporting the delayed UI projection.
    /// An Active export holds the rows the Active segment shows at the tap, evaluated at the
    /// pause instant while paused (contracts 3.6).
    private func export(_ format: BLEManager.ExportFormat,
                        snapshot supplied: BLEManager.DetectionExportSnapshot? = nil,
                        qualifier suppliedQualifier: String? = nil) {
        let base = supplied ?? (paused ? frozenExport : nil) ?? ble.detectionExportSnapshot()
        let activeIDs = supplied == nil && scope == .active
            ? base.activeIDs(now: evaluationInstant(), isDemoMode: ble.demoMode) : nil
        let scoped = supplied == nil
            ? base.reviewed(category: filter, unseenOnly: scope == .new, offlineOnly: offlineOnly,
                            activeIDs: activeIDs, query: searchQuery, sort: sortOrder,
                            isWatched: { ble.isWatched($0) })
            : base
        let qualifier = supplied == nil ? (suppliedQualifier ?? exportQualifier) : suppliedQualifier
        ble.writeDetections(format, snapshot: scoped, filenameQualifier: qualifier) { result in
            switch result {
            case .success(let url):
                exportFile = ExportFile(url: url)
            case .emptyGPX:
                exportProblem = ExportProblem(
                    title: "Nothing to map",
                    message: "None of the reviewed detections has a location. Export CSV instead; it keeps every reviewed row with blank location columns.")
            case .failure(let detail):
                exportProblem = ExportProblem(
                    title: "Export failed",
                    message: "The file could not be prepared. \(detail)")
            }
        }
    }

    /// The filename slug's vocabulary is ONE rule on both platforms, in this order: the category
    /// key, ACTIVE or NEW, OFFLINE, SEARCH, STRONGEST, PAUSED, joined by "-". writeDetections
    /// lowercases the whole slug and turns spaces into "-", so "BODY CAM" lands as the same
    /// "body-cam" Android's `it.lowercase().replace(' ', '-')` makes. A file made from a
    /// strongest-first or paused review says so in its name the way a category or a search does:
    /// what left the phone was a re-ordered or frozen view, not the log in arrival order.
    /// TWIN: Android `slugParts` in LogScreen.exportLog, same words, same order.
    private var exportQualifier: String? {
        var parts: [String] = []
        if let filter { parts.append(filter) }
        switch scope {
        case .all: break
        case .active: parts.append("ACTIVE")
        case .new: parts.append("NEW")
        }
        if offlineOnly { parts.append("OFFLINE") }
        // Never leak a pasted device name/address into the temporary export filename.
        if !searchQuery.isEmpty { parts.append("SEARCH") }
        if sortOrder == .strongest { parts.append("STRONGEST") }
        if paused { parts.append("PAUSED") }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    /// Bottom action bar shown in select mode: the selection count, then bulk-mute the selected
    /// rows. Takes the body's snapshot rather than reading the lens itself: this bar used to read
    /// it twice more (once for the button's action, once eagerly for the trait), so select mode -
    /// where every checkbox tap re-runs body - paid for three lens passes per eval instead of one.
    private func selectBar(_ snap: LogSnapshot) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            Kicker("\(selection.count) SELECTED")
            layout {
                Button { selection = Set(snap.shown.map { $0.id }) } label: {
                    Text("Select Shown").font(ACABTheme.font(.subheadline, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(ACABTheme.bg2, in: Capsule())
                }
                .buttonStyle(.plain)
                // allSatisfy, not isSuperset(of: map(\.id)): the superset form built a throwaway
                // array of every shown row's id on every body eval, and this modifier's argument
                // is evaluated eagerly whether or not VoiceOver is running.
                .accessibilityAddTraits(!snap.shown.isEmpty
                                        && snap.shown.allSatisfy { selection.contains($0.id) }
                                        ? .isSelected : [])
                // onAccent on a tint capsule, not .borderedProminent (white on tint fails contrast).
                Button(action: ignoreSelected) {
                    HStack(spacing: 7) {
                        Image(systemName: "bell.slash")
                            .font(ACABTheme.font(.subheadline, weight: .semibold, tabular: true))
                        Text("Mute \(selection.count)")
                            .font(ACABTheme.font(.subheadline, weight: .semibold, tabular: true))
                    }
                    .foregroundStyle(selection.isEmpty ? ACABTheme.faint : ACABTheme.onAccent)
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .background(selection.isEmpty ? ACABTheme.bg2 : ACABTheme.tint, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 10).padding(.bottom, 8)
        .background(ACABTheme.bg.ignoresSafeArea(edges: .bottom))
    }

    /// Consume the one-shot LogFocus handoff: a Status-tile category over the ALL scope, or the
    /// Beacon tab's Saved log row (pendingAll: ALL with no category, which wins). Both slots are
    /// cleared, which makes it exactly-once, so a later plain visit to the tab is unfiltered.
    private func consumeLogFocus() {
        guard let seed = logFocusSeed(pendingAll: LogFocus.pendingAll,
                                      pendingCategory: LogFocus.pendingCategory) else { return }
        LogFocus.pendingAll = false
        LogFocus.pendingCategory = nil
        seedLens(scope: seed.scope, category: seed.category)
    }

    /// A deep-link seed (Live Activity / notification NEW tap, offline-sync banner, Status
    /// category tile, the Beacon tab's Saved log row) positions only the axis it names and resets
    /// every other lens axis to its default. The seed promised specific rows: a search, a
    /// category or the offline filter the user set earlier would hide them, in a populated list
    /// that silently lacks them or behind the no-match panel when nothing else matches; a
    /// strongest-first sort would bury the newest of them; and a frozen snapshot would leave them
    /// off the paused list. Android does the same: MainScreen bumps logScreenKey on every seed, so
    /// LogScreen rebuilds its lens from the seed with every other axis at its default, and resumes
    /// the paused feed in the same handler.
    ///
    /// A seed also leaves bulk-select mode and closes the right-pane dossier, so a seeded visit
    /// always starts as a plain list. Android drops both structurally: LogScreen keeps select mode
    /// and its id set in plain `remember` state inside MainScreen's key(logScreenKey) wrapper, and
    /// every seed bumps that key.
    ///
    /// A seed returns the list to the top too (seedScrollToken, applied in masterList), and
    /// dismisses an active search field (SeedSearchDismisser watches the same token). Android
    /// reaches the same place without writing anything: LogScreen's LazyColumn is declared with
    /// no state argument, so the default rememberLazyListState it builds lives inside
    /// key(logScreenKey) and every seed rebuilds it at offset 0. That half is an absence rather
    /// than a rule anyone wrote, and it is the fragile one: hoisting a rememberLazyListState out
    /// of LogScreen to carry the offset across tab switches would end the reset silently, so a
    /// drift pin for that side has to be the absence of rememberLazyListState in LogScreen.kt.
    /// SwiftUI keeps the content offset across a state change instead, so without the token the
    /// same notification tap starts at the top on Android and mid-list on iPhone, with the
    /// newest-first rows it promised above the viewport.
    private func seedLens(scope newScope: StatusScope, category: String?) {
        filter = category
        scope = newScope
        sortOrder = .newest
        searchText = ""
        offlineOnly = false
        if paused { resumeFeed() }   // the live rows the seed exists to show, not a stale snapshot
        seedScrollToken += 1         // back to the top of the seeded lens, see masterList
        // A selection carried in from an earlier visit would aim MUTE N at rows the user never
        // chose, in a list whose contents just changed under the checkboxes. This closes the seed
        // route to that hazard and only that route: the lens controls stay live during select mode
        // on both apps, so a selection still outlives a lens change the user makes by hand. Here
        // only the tools menu is hidden while `selecting` (DONE takes its toolbar slot), while
        // the scope picker (scopePicker), the filter chips that clear a filter (filterChips) and
        // the search field stay live, and ignoreSelected resolves picks over ble.logDetections
        // rather than the shown rows. Android is the same shape, so closing that is one rule
        // across both apps and is not decided here: SelectBar onIgnore filters `detections` the
        // same way.
        // This ends the mode only; the select bar and its labels are untouched.
        selecting = false
        selection.removeAll()
        // Regular width: the open dossier is usually a row the seeded lens does not list, so the
        // pane would contradict the list beside it. Inert at compact width, where rows push
        // instead of filling a pane (see row(_:)), and the pane always falls back to its
        // "Select a detection" placeholder rather than going blank.
        selectedDetail = nil
    }

    private func toggle(_ d: Detection) {
        if selection.contains(d.id) { selection.remove(d.id) } else { selection.insert(d.id) }
    }

    private func ignoreSelected() {
        let picks = ble.logDetections.filter { selection.contains($0.id) }
        let refused = ble.ignoreDevices(picks)
        let requested = Set(picks.map { $0.mac.lowercased() }).count
        let muted = max(0, requested - refused)
        exportProblem = ExportProblem(
            title: refused == 0 ? "Devices muted" : "Some devices weren't muted",
            message: refused == 0
                ? "\(muted) device\(muted == 1 ? "" : "s") muted. Existing history was kept."
                : "\(muted) muted; \(refused) couldn't be added because the muted-device list is full."
        )
        exitSelect()
    }

    private func exitSelect() {
        selecting = false
        selection.removeAll()
    }

    /// Headline tracks radio state so an empty log never lies about scanning.
    private var emptyHeadline: String {
        if ble.demoMode { return "Sample data mode." }
        // No status frame at all = no board linked; "Scanning…" would be a lie.
        if ble.status == nil { return "No board linked." }
        // Plain words, two sentences: TWIN android LogScreen.kt's empty headline, byte-identical.
        if radiosOff { return "Radios are off. Turn them on in Beacon." }
        return "Scanning\u{2026}"
    }
    private var radiosOff: Bool { if let s = ble.status { return !s.ble && !s.wifi }; return false }
    /// Only while genuinely scanning does the "log here" hint make sense (not in demo, not with
    /// no board linked, not when the radios are off. Then the headline already explains why
    /// nothing shows).
    private var isScanning: Bool { !ble.demoMode && ble.status != nil && !radiosOff }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope").font(ACABTheme.font(.largeTitle)).foregroundStyle(ACABTheme.faint)
            Text(emptyHeadline)
                .font(ACABTheme.font(.headline)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
            if isScanning {
                Text("Detections log here as beacons spots surveillance gear nearby.")
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
            } else if !ble.demoMode && ble.status == nil {
                Text("connect your beacon, it does the listening")
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    /// Shown when the lens and the segment hide everything (e.g. New with nothing new yet). The
    /// paused pill in the chip row directly above keeps resume reachable.
    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: noMatchSymbol)
                .font(ACABTheme.font(.largeTitle)).foregroundStyle(ACABTheme.faint)
            Text(noMatchTitle)
                .font(ACABTheme.font(.headline)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
            Text(noMatchBody)
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
            // The button is logNoMatchAction's: "Clear Filters" resets search, category, scope
            // and Offline only in one tap; "Show All" only moves to the All segment.
            if let action = logNoMatchAction(scope: scope, category: filter,
                                             searching: !searchQuery.isEmpty, offlineOnly: offlineOnly) {
                Group {
                    switch action {
                    case .clearFilters:
                        Button("Clear Filters") { searchText = ""; filter = nil; scope = .all; offlineOnly = false }
                    case .showAll:
                        Button("Show All") { scope = .all }
                    }
                }
                .font(ACABTheme.font(.body, weight: .semibold))
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .listRowBackground(Color.clear)
    }

    private var noMatchSymbol: String {
        switch scope {
        case .active: return offlineOnly ? "tray" : "antenna.radiowaves.left.and.right"
        case .new:    return "checkmark.seal"
        case .all:    return offlineOnly ? "tray" : "line.3.horizontal.decrease.circle"
        }
    }
    /// Offline only is checked BEFORE the Active copy: an offline replay is never Active
    /// (logScopeKeeps), so Active with Offline only is always empty, and "Nothing was heard in
    /// the last 45 seconds" would blame the radio for what the filter did. TWIN: Android
    /// `NoMatchState` in LogScreen.kt, same precedence and the same words.
    private var noMatchTitle: String {
        if !searchQuery.isEmpty { return "No matching detections" }
        switch scope {
        case .active: return offlineOnly ? "Nothing offline" : "Nothing active"
        case .new:    return "Nothing new"
        case .all:
            if offlineOnly { return "Nothing offline" }
            // ALPR gets its specific title (Android parity): the body below already explains why a
            // quiet ALPR lens is the expected result, and the generic "No matches" undersold that.
            return filter == "ALPR" ? "No ALPR radio signal" : "No matches"
        }
    }
    private var noMatchBody: String {
        if !searchQuery.isEmpty {
            return "Try a shorter name, vendor or MAC address, or clear the current filters."
        }
        switch scope {
        case .active where offlineOnly:
            return "No offline-recorded detections yet. The board buffers these while your phone is away."
        case .active: return "Nothing was heard in the last \(Int(activeNearbyInterval)) seconds. Earlier detections stay under all."
        case .new:    return "Everything here is marked seen. New hits show up as they arrive."
        case .all:
            if offlineOnly { return "No offline-recorded detections yet. The board buffers these while your phone is away." }
            // ALPR gets a specific line because a quiet result there means something different:
            // most current installs are RF-silent (see the site + faq), so absence is expected,
            // not a failure, and the map is the primary ALPR surface.
            if filter == "ALPR" {
                return "No compatible ALPR radio signal was observed. Some cameras do not broadcast "
                     + "a detectable signal, many backhaul over cellular and stay silent. Check the "
                     + "map for known installations, or export a diagnostic capture to contribute if "
                     + "you can visually confirm one nearby."
            }
            return "No detections in this category yet."
        }
    }
}

/// Dismisses the system search field when a seed lands (seedLens bumps the token), replacing the
/// old focus write. `dismissSearch` and `isSearching` are only readable inside the view that
/// `.searchable` modifies, which is why this sits in the List's background, inside that modifier.
private struct SeedSearchDismisser: View {
    let token: Int
    @Environment(\.isSearching) private var isSearching
    @Environment(\.dismissSearch) private var dismissSearch
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: token) { if isSearching { dismissSearch() } }
    }
}

/// A temp file to share. Identifiable so it can drive `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Share-sheet wrapper around UIActivityViewController.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
