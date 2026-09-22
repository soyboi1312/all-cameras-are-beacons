import SwiftUI
import UIKit
import Combine

/// The ordered category set shown as filter tiles (Log) and chips (Map), defined once and
/// shared by both surfaces so they stay in lockstep as categories grow. Each entry carries a
/// representative DeviceType (supplies the tint + glyph), the `DeviceType.category` key it
/// filters on, and its labels. "Nearby Device" (Desert-mode ambient noise) is deliberately
/// absent - it is not a filter category.
struct DetectionCategory: Identifiable {
    let type: DeviceType    // representative type: supplies tint + SF Symbol
    let key: String         // the DeviceType.category key this chip/tile filters on
    let tileLabel: String   // compact label for the Log summary tiles
    let chipLabel: String   // label for the Map filter chip
    var id: String { key }
}

/// One-shot handoff from a Status category tile to the Log tab with that category filter
/// armed. Same static-slot + notification pattern as MapFocus (and deliberately NOT the
/// UserDefaults channel the Live Activity uses): a tile tap must never outlive the session,
/// or a stale persisted category would hijack an unrelated later launch's Log open.
/// MainTabView switches tabs on the notification; DetectionsView consumes the slot exactly
/// once (onAppear when the tab was cold, onReceive when it is already alive).
enum LogFocus {
    static var pendingCategory: String?
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

/// Does an ordinary appearance of the logbook run the first-open seen baseline
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
/// entry). WATCHED is dynamic like the rest: it is offered only while at least one row belongs.
let detectionCategories: [DetectionCategory] = [
    .init(type: .flockCamera,      key: "ALPR",     tileLabel: "ALPR",  chipLabel: "ALPR"),
    .init(type: .drone,            key: "DRONE",    tileLabel: "DRONE", chipLabel: "DRONE"),
    .init(type: .axonBodyCam,      key: "BODY CAM", tileLabel: "BODY",  chipLabel: "BODY CAM"),
    .init(type: .tracker,          key: "TRACKER",  tileLabel: "TRKR",  chipLabel: "TRACKER"),
    .init(type: .recordingGlasses, key: "GLASSES",  tileLabel: "GLAS",  chipLabel: "GLASSES"),
    .init(type: .networkCamera,    key: "CAMERA",   tileLabel: "NETCAM", chipLabel: "NETWORK CAM"),
    .init(type: .watched,          key: "WATCHED",  tileLabel: "WATCH", chipLabel: "WATCHED"),
]

/// Logbook: detection history, with category tiles that double as filters over the
/// list below. New/All filtering, a "mark all seen" baseline, and a select mode for
/// bulk-muting rows.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var scope: StatusScope = .all   // all / new (after the seen watermark) / offline-recorded
    @State private var searchText = ""
    @State private var sortOrder: DetectionLogSort = .newest
    @FocusState private var searchFocused: Bool
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
    // Accessibility text sizes pad the scroll bottom and stack the select bar. The tile strip
    // measures itself instead (CategoryStripLayout), so it does not read this.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Three-way status scope over the feed: everything, only-new (after the seen
    /// watermark), or only records the board buffered offline and replayed.
    private enum StatusScope: Equatable { case all, new, offline }

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
    /// and short-circuits, so a keystroke, a tile tap or a select-mode tap usually decides on
    /// the scalars and never walks the row array.
    private struct LogLensKey: Equatable {
        let paused: Bool          // also covers frozenExport, which only changes with it
        /// `isUnseen` compares the manager's per-row first-seen stamps against the watermark,
        /// and those stamps do NOT travel with `rows`: Detection carries no first/last-seen
        /// field, and BLEManager.rekey (run from resolveBracketedHistory at a drain's end
        /// sentinel) rewrites the stamps of rows that were already filed without touching any
        /// Detection. The republish that follows can therefore come back element-wise equal
        /// while a row's verdict has flipped from New to seen. A drain whose begin sentinel
        /// promised rows raises syncingOfflineLog, and handleHistEnd drops it in the same turn
        /// it re-keys, so this Bool is the axis that moves with the rekey. Gap: a drain whose
        /// begin sentinel promised no rows never raises it, so a rekey at that drain's end is
        /// not covered. A manager-owned stamp-revision counter would close that gap and should
        /// replace this member when one exists.
        let syncing: Bool
        let filter: String?
        let scope: StatusScope
        let sort: DetectionLogSort
        let search: String
        /// `isUnseen` reads the seen watermark. markAllSeen advances the pseudo-band baseline
        /// in the same call that sets this Date, so the Date moves whenever either does.
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
    /// Why it exists: with a non-empty search, the lens derives ten fields per row and folds
    /// them, over the whole retained store (liveFeedCap 5,000). `body` re-runs on every one of
    /// the manager's publishes (~3 Hz while detections stream), on every keystroke, and on
    /// every @State write on this screen, and `shown` was recomputed from scratch each time.
    /// Two arrays that share storage compare equal without touching an element, so an
    /// unchanged store is decided cheaply; correctness does not rely on that - a changed store
    /// falls back to an ordinary element-wise compare and rebuilds. This is the same
    /// discipline MapTabView applies to its own lens.
    ///
    /// A publish that DID change the store (a re-sighted row's RSSI) still rebuilds the result,
    /// but through `searchIndex`, which keeps every row's folded haystack across publishes and
    /// refolds only a row whose identity text moved (DetectionLogSearchIndex says which fields).
    /// The rebuild is then a substring test per row, not a nine-field derivation plus a fold.
    private final class LogLensMemo {
        private var cachedKey: LogLensKey?
        private var cachedRows: [Detection] = []
        private var cachedText: String?
        private var cachedQuery = DetectionLogQuery("")
        let searchIndex = DetectionLogSearchIndex()

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
            return built
        }
    }

    @State private var lensMemo = LogLensMemo()

    /// Built once per query change (see LogLensMemo.query), not once per read.
    private var searchQuery: DetectionLogQuery { lensMemo.query(for: searchText) }

    private var shown: [Detection] {
        // Paused: read from the frozen snapshot so the list holds still. Live otherwise.
        let base = paused ? frozenRows : ble.logDetections
        let key = LogLensKey(paused: paused, syncing: ble.syncingOfflineLog, filter: filter,
                             scope: scope, sort: sortOrder, search: searchText,
                             watermark: ble.seenWatermark, watched: ble.watched,
                             ignored: ble.ignored, rows: base)
        let query = searchQuery   // resolved before the memo call, not inside its build closure
        let index = lensMemo.searchIndex
        return lensMemo.rows(for: key) {
            applyDetectionLogLens(base, category: filter, unseenOnly: scope == .new,
                offlineOnly: scope == .offline, query: query, sort: sortOrder,
                isUnseen: { paused ? frozenExport?.unseenIDs.contains($0.id) == true : ble.isUnseen($0) },
                isWatched: { ble.isWatched($0) }, index: index)
        }
    }

    private func pauseFeed() {
        let snap = ble.detectionExportSnapshot()
        frozenExport = snap
        frozenRows = snap.detections
        frozenIDs = snap.ids
        paused = true
    }
    private func resumeFeed() {
        paused = false
        frozenExport = nil
        frozenRows = []
        frozenIDs = []
    }
    /// Everything one body eval needs from the store, computed in a single pass. shown /
    /// count(cat) / newCount / offlineCount used to be independent computed properties, each
    /// a full O(store) filter, and body read them ~12x per eval at the ~3 Hz publish cadence.
    private struct LogSnapshot {
        let shown: [Detection]
        let counts: [String: Int]   // per category key, unfiltered (feeds the tiles)
        let newCount: Int
        let offlineCount: Int
        /// While paused, how many detections have landed in the live store since the freeze -
        /// the "N new" hint. The store never stops filling; only the display is frozen. Counted
        /// in the pass below rather than by its own property: the header read it twice per eval
        /// (once for the test, once for the number), so it was two extra store walks on the one
        /// screen state that exists to be calm.
        let pausedNewCount: Int
    }

    private func makeSnapshot() -> LogSnapshot {
        var counts: [String: Int] = [:]
        var newN = 0, offN = 0, pausedNewN = 0
        for d in ble.logDetections {
            counts[d.type.category, default: 0] += 1
            // WATCHED overlaps the underlying category. Do not double-count a row the board
            // already typed watched when that same MAC is still on the current watchlist.
            if d.type != .watched, ble.isWatched(d) {
                counts[DeviceType.watched.category, default: 0] += 1
            }
            if ble.isUnseen(d) { newN += 1 }
            if d.offline { offN += 1 }
            if paused && !frozenIDs.contains(d.id) { pausedNewN += 1 }
        }
        return LogSnapshot(shown: shown, counts: counts, newCount: newN, offlineCount: offN,
                           pausedNewCount: pausedNewN)
    }

    var body: some View {
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
                // Every category normally keeps its active zero-count tile so a transient store
                // change cannot strand a hidden filter. WATCHED is intentionally different: the
                // product only offers that lens while a watched/capture-typed row exists. If the
                // last member is removed, return to ALL before the tile disappears.
                .onChange(of: snap.counts[DeviceType.watched.category] ?? 0,
                          initial: true) { _, count in
                    if filter == DeviceType.watched.category, count == 0 { filter = nil }
                }
        }
    }

    /// Regular width: two-pane master/detail (list left, dossier right). Compact:
    /// today's single-column logbook, verbatim.
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
            // The embedded dossier carries .toolbar(.hidden, for: .tabBar); in this
            // persistent two-pane it would swallow the tab bar, so keep it visible.
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
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "scope").font(.system(size: 34)).foregroundStyle(ACABTheme.line)
                Text("Select a detection")
                    .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                Text("Pick a row to open its full dossier here.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    /// Scroll anchor for the top of the master list. Parked on `header`, which sits in the plain
    /// VStack outside logCard's LazyVStack and is therefore always built, so a seed can scroll to
    /// it from anywhere in a long log without depending on a lazy row being realized.
    private static let topAnchorID = "logTop"

    /// Put the master list back at the top for a seed, at most once per seed.
    /// Called from the token's onChange (the usual path, this list is on screen) and from the
    /// list's onAppear, because the acabOpenLogNew arm also seeds a loaded list that another tab
    /// is covering: the seed and MainTabView's tab switch happen in one update, so that attempt
    /// can reach a list with no layout yet. Only an on-screen application is recorded, which is
    /// what keeps a dropped one from being counted as done, and the appearance that follows the
    /// tab switch then applies the same seed. The hop to the next run loop is the one
    /// SettingsView's openDetectorsToken already documents: the lens writes and the tab switch
    /// are in this update, so the target reaches its final position first.
    private func applySeedScroll(_ proxy: ScrollViewProxy, onScreen: Bool) {
        guard appliedScrollToken != seedScrollToken else { return }
        let token = seedScrollToken
        DispatchQueue.main.async {
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
            if onScreen { appliedScrollToken = token }
        }
    }

    /// Today's logbook screen: the whole view when compact, the left column when regular.
    /// Keeps its own nav / sheet / dialog modifiers so both layouts get them.
    private func masterList(_ snap: LogSnapshot) -> some View {
            ZStack(alignment: .bottom) {
                ACABTheme.bg.ignoresSafeArea()
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(snap).id(Self.topAnchorID)
                        // Persistent board-side loss/censoring flags belong beside the evidence,
                        // not behind a settings disclosure. The Offline Buffer card repeats them.
                        ForEach(ble.status?.bufferHealthNotices ?? [], id: \.self) {
                            BufferHealthBanner(notice: $0)
                        }
                        if !selecting && !ble.logDetections.isEmpty { actionChips }
                        if !ble.logDetections.isEmpty { searchAndSort(snap) }
                        summaryTiles(snap)
                        if !ble.logDetections.isEmpty { statusFilter(snap) }
                        if ble.logDetections.isEmpty { emptyState }
                        else if snap.shown.isEmpty { noMatchState }
                        else { logCard(snap) }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                    // T2: cap the readable column so tablets/landscape don't stretch a
                    // single column full-width. A no-op at phone portrait (~390pt < 640);
                    // the ScrollView itself stays full-width, only this content centers.
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
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
                    applySeedScroll(proxy, onScreen: true)
                }
                .onDisappear { listOnScreen = false }
                }   // ScrollViewReader, wrapped without re-indenting its body so the diff stays
                    // on the wrap itself
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting { selectBar(snap) }
            }
            .navigationBarHidden(true)
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
                    // sample data (BLEManager.seedSeenWatermarkOnce re-baselines the sample log on
                    // every call). Skipped for the whole seeded NEW visit, or the baseline would
                    // erase the very rows the link promised.
                    if newVisit != nil { newVisit = nil }
                    ble.seedSeenWatermarkOnce()
                }
                consumeLogFocus()   // Status-tile category handoff, cold-tab path
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
            // markAllSeen when the user leaves the Log tab, and the next appearance then runs the
            // baseline. The MARK SEEN chip moves the watermark too, so it re-records the visit
            // instead of ending it; otherwise the next pop would mark seen every row that arrived
            // after the tap. Android ends its skip at the same point: LogScreen runs
            // seedSeenWatermarkOnce from LaunchedEffect(Unit) only when initialFilter is not
            // NewOnly, once per key(logScreenKey) composition. MainScreen draws the compact dossier
            // as an overlay, so closing it never re-runs that gate, and MARK SEEN does not rekey
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
            // Status-tile category handoff, warm-tab path (see LogFocus).
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
                Button("Export CSV first") {
                    export(.csv, snapshot: ble.detectionExportSnapshot(), qualifier: nil)
                }
                Button(ble.demoMode ? "Clear sample" : "Clear log", role: .destructive) {
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

    private func header(_ snap: LogSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Logbook").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(selecting ? "\(selection.count) SELECTED"
                                 : "\(ble.logDetections.count) DETECTED · \(snap.newCount) NEW")
            }
            Spacer()
            if selecting {
                Button { exitSelect() } label: {
                    Text("DONE").font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(ACABTheme.bg2, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Labeled action chips under the title row (replaces the old anonymous
    /// icon buttons). Clear lives in the filter row (statusFilter), always reachable.
    private var actionChips: some View {
        // Horizontally scrollable so no chip is ever clipped out of reach: the row holds up to
        // three chips (SELECT, EXPORT, MARK SEEN), and a filtered EXPORT label ("EXPORT BODY CAM")
        // is far wider than the plain one. It held four until CSV and GPX folded into the one
        // EXPORT menu. Android's twin (LogScreen action row) scrolls for the same reason.
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            actionChip("checkmark.circle", "SELECT") { resumeFeed(); selecting = true }   // bulk-mute acts on retained Log rows
            // CSV and GPX used to be two chips. That was two of the four slots in a row that must
            // scroll on a phone, spent on two variants of one action, so they fold into a single
            // EXPORT chip with a menu. Both formats still carry the CURRENT category filter, and
            // the chip names it ("EXPORT DRONE") so a partial export can't be mistaken for the
            // whole log. Mirrors Android LogScreen's export menu.
            Menu {
                Button {
                    export(.csv)
                } label: { Label("CSV, shown rows", systemImage: "tablecells") }
                Button {
                    export(.gpx)
                } label: { Label("GPX, for maps", systemImage: "mappin.and.ellipse") }
            } label: {
                chipLabel("square.and.arrow.up", filter.map { "EXPORT \($0)" } ?? "EXPORT")
            }
            .buttonStyle(.plain)
            // Re-record a live seeded NEW visit rather than end it (see the acabOpenLogNew arm):
            // ending it would let the next dossier pop run a pending first-open baseline and mark
            // seen every row that arrived after this tap.
            actionChip("checkmark", "MARK SEEN") {
                ble.markAllSeen()
                if newVisit != nil { newVisit = SeededNewVisit(watermark: ble.seenWatermark) }
                scope = .all
            }
        }
        }
    }

    /// Search and sort name the current lens explicitly. Counts describe detections, never the
    /// number of visible lazy rows, and a query is also honored by CSV/GPX exports.
    ///
    /// DELIBERATE PLATFORM DIFFERENCE, kept since 2.0.8: here search sits above the category
    /// tiles and the sort shares the lens-summary row; on Android (LogScreen.kt, the search/sort
    /// item) both sit below the ALL/NEW/OFFLINE chips and share ONE row whenever the whole
    /// placeholder still fits beside the wider sort chip. That side-by-side form is not copied
    /// here on purpose: judged with the wider label ("Strongest signal") so the layout cannot
    /// jump when the sort changes, placeholder plus sort does not fit an iPhone in portrait at
    /// the default text size or larger (both faces follow Dynamic Type, so the smallest sizes
    /// could fit on the largest phones; not worth a layout that changes with text size).
    private func searchAndSort(_ snap: LogSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ACABTheme.dim)
                TextField("Search name, MAC or vendor", text: $searchText)
                    .font(ACABTheme.display(15)).foregroundStyle(ACABTheme.text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .accessibilityLabel("Search detections by name, MAC address or vendor")
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(ACABTheme.dim)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12).padding(.trailing, searchText.isEmpty ? 12 : 0)
            .frame(minHeight: 48)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                .strokeBorder(ACABTheme.line, lineWidth: 1))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { logLensSummary(snap); Spacer(minLength: 0); sortMenu }
                VStack(alignment: .leading, spacing: 4) { logLensSummary(snap); sortMenu }
            }
        }
    }

    private func logLensSummary(_ snap: LogSnapshot) -> some View {
        let total = paused ? frozenRows.count : ble.logDetections.count
        let category = filter.map { " · \($0)" } ?? ""
        return Text("\(snap.shown.count) of \(total)\(paused ? " paused" : " retained")\(category)")
            .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("\(snap.shown.count) matching detections of \(total)\(paused ? " in the paused log" : " retained")\(category)")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort detections", selection: $sortOrder) {
                ForEach(DetectionLogSort.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
        } label: {
            Label(sortOrder.label, systemImage: "arrow.up.arrow.down")
                .font(ACABTheme.mono(11, weight: .semibold))
                .foregroundStyle(ACABTheme.text).padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(ACABTheme.bg2, in: Capsule())
        }
        .accessibilityLabel("Sort detections")
        .accessibilityValue(sortOrder.label)
    }

    // The chip's visual, factored out so the plain-action chips and the EXPORT menu share one
    // capsule. A Menu needs a label view, not a Button, so actionChip below wraps this in a Button
    // and the export menu uses it directly.
    private func chipLabel(_ system: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 11, weight: .semibold))
            Text(label).font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(ACABTheme.dim)
        .padding(.horizontal, 11).frame(height: 36)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
        // 44pt minimum hit target: the capsule stays 36pt visually, the extra height is
        // invisible tappable area (contentShape), so the look is unchanged.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func actionChip(_ system: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(system, label) }
        .buttonStyle(.plain)
    }

    /// A strip of compact category tiles, one per category that has a detection this session;
    /// tapping one toggles it as a filter for the list. Dynamic so the row scales as categories
    /// grow and a zero-count (useless) filter never takes up space. The same rule as the Status
    /// strip (CategoryStripLayout): rows of three as soon as the widest label no longer fits.
    /// Seven categories prefer four across, so they fill two readable rows instead of leaving a
    /// mostly empty third row that pushes the Log below the fold.
    private func summaryTiles(_ snap: LogSnapshot) -> some View {
        let shown = shownCategories(snap)
        return CategoryStripLayout(preferred: shown.count > 6 ? 4 : shown.count, spacing: 8) {
            ForEach(shown) { c in
                tile(c.type, c.key, c.tileLabel, count: snap.counts[c.key] ?? 0)
            }
        }
    }

    /// Which category tiles to actually render: a category with at least one detection this
    /// session, OR the currently-active filter even at count 0. The active-filter exception is
    /// required for the six detector categories: a transient eviction must not hide the way back
    /// out. WATCHED is the deliberate exception to that exception; its contract is to exist only
    /// while it has a member, and the count-change hook above returns that lens to ALL first.
    private func shownCategories(_ snap: LogSnapshot) -> [DetectionCategory] {
        detectionCategories.filter {
            let count = snap.counts[$0.key] ?? 0
            return count > 0 || ($0.key != DeviceType.watched.category && filter == $0.key)
        }
    }

    private func tile(_ type: DeviceType, _ cat: String, _ label: String, count n: Int) -> some View {
        let active = filter == cat
        return Button { filter = active ? nil : cat } label: {
            VStack(spacing: 5) {
                Image(systemName: type.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.tint)
                    // The Status tile's icon box. Glyphs differ in height (the glasses are
                    // short, the webcam tall), and without a fixed box the tiles in a row
                    // come out uneven and the labels miss a common line.
                    .frame(width: 22, height: 18)
                Text("\(n)")
                    .font(ACABTheme.display(18, weight: .bold))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text)
                    .monospacedDigit()
                Text(label)
                    .font(ACABTheme.mono(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.textTint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? type.tint.opacity(0.12) : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(active ? type.tint.opacity(0.4) : ACABTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spokenCategory(label)), \(n) detection\(n == 1 ? "" : "s")")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(active ? "Clears this filter" : "Filters the log to this category")
    }

    private func spokenCategory(_ label: String) -> String {
        // Tiles pass tileLabel ("BODY", "NETCAM", "TRKR"...), chips pass chipLabel ("BODY CAM",
        // "NETWORK CAM"...). Match BOTH spellings of each category, or the expansion silently
        // stops firing for one caller - which is exactly how "BODY" spent weeks announced as
        // "body" instead of "body cameras".
        switch label {
        case "ALPR": return "automatic license plate readers"
        case "BODY", "BODY CAM": return "body cameras"
        case "DRONE": return "drones"
        case "CAMERA", "NETCAM", "NETWORK CAM": return "network cameras"
        case "TRKR", "TRACKER": return "item trackers"
        case "GLAS", "GLASSES": return "recording glasses"
        case "WATCH", "WATCHED": return "watched devices"
        default: return label.lowercased()
        }
    }

    /// All / New / Offline segmented chips ("mark all seen" lives in the header chips now).
    private func statusFilter(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    segChip("ALL", ble.logDetections.count, active: scope == .all) { scope = .all }
                    segChip("NEW", snap.newCount, active: scope == .new, tint: ACABTheme.accent) { scope = .new }
                    segChip("OFFLINE", snap.offlineCount, active: scope == .offline) { scope = .offline }
                }
            }
            Spacer(minLength: 0)
            // Quick clear at the top: reaching the bottom "clear log..." row is a long scroll
            // once the log is big. Goes through the same confirmation, quiet so it's not a mis-tap
            // magnet. Hidden in select mode (that's for bulk-muting, not clearing).
            if !selecting {
                // Icon-only (trash reads on its own): a worded chip crowds this row on
                // narrower screens - Android's equivalent wrapped "CLEAR" mid-word.
                Button { confirmClear = true } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        // Small destructive control: pad the hit area out to 44pt without
                        // growing the drawn capsule.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ble.demoMode ? "Clear sample" : "Clear log")
            }
        }
    }

    private func segChip(_ label: String, _ n: Int, active: Bool,
                         tint: Color = ACABTheme.dim,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
                Text("\(n)").font(ACABTheme.mono(10))
                    .foregroundStyle(active ? ACABTheme.onAccent.opacity(0.7) : ACABTheme.faint)
            }
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? tint : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : ACABTheme.line, lineWidth: 1))
            // 44pt hit target; the drawn capsule keeps its size.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The detection list (honoring the active filters), divider between rows.
    /// LazyVStack so a Desert-mode log of thousands only builds the rows on screen
    /// (was a plain VStack that materialized every row at once).
    private func logCard(_ snap: LogSnapshot) -> some View {
        let rows = snap.shown   // filtered once per body eval, in the snapshot
        return LazyVStack(alignment: .leading, spacing: 0) {
            logCardHeader(snap).padding(.bottom, 8)
            ForEach(rows) { d in
                row(d)
                if d.id != rows.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    /// Log heading plus the pause/resume control. Pausing shows a "PAUSED · N NEW" pill so it's
    /// obvious the feed is still filling behind the frozen list. Hidden in select mode (that's
    /// bulk-muting, which acts on the retained Log rows).
    private func logCardHeader(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            Kicker(logHeading)
            if paused {
                Text(snap.pausedNewCount > 0 ? "PAUSED \u{00B7} \(snap.pausedNewCount) NEW" : "PAUSED")
                    .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(ACABTheme.accent.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
            if !selecting { pauseButton }
        }
    }

    /// Freeze / unfreeze the displayed feed. Accent-filled while paused so it reads as active.
    /// Icon-only: the header's "PAUSED · N NEW" pill already words the state, and the worded
    /// chip crowded this row (Android's equivalent wrapped its labels on narrower screens).
    private var pauseButton: some View {
        Button { paused ? resumeFeed() : pauseFeed() } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(paused ? ACABTheme.onAccent : ACABTheme.dim)
                .padding(.horizontal, 11).frame(height: 30)
                .background(paused ? ACABTheme.accent : ACABTheme.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(paused ? .clear : ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 30pt capsule.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? "Resume live feed" : "Pause live feed")
    }

    private var logHeading: String {
        let scopeTag: String
        switch scope {
        case .all:     scopeTag = "ALL"
        case .new:     scopeTag = "NEW"
        case .offline: scopeTag = "OFFLINE"
        }
        return filter == nil ? "\(scopeTag) DETECTIONS" : "\(filter!) \u{00B7} \(scopeTag)"
    }

    @ViewBuilder
    private func row(_ d: Detection) -> some View {
        // Resolved once per row: the log is where a buffered record is most likely to be read as
        // a plain timestamp, so the caveat has to travel with it.
        let basis = paused ? (frozenExport?.basis(for: d.id) ?? .unknown) : ble.timeBasis(for: d.id)
        if selecting {
            let selected = selection.contains(d.id)
            Button { toggle(d) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? ACABTheme.accent : ACABTheme.faint)
                    DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else if hSize == .regular {
            // Two-pane: rows select the right dossier instead of pushing; the active
            // row carries a subtle highlight.
            Button { selectedDetail = d } label: {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedDetail?.id == d.id ? ACABTheme.lineStrong : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedDetail?.id == d.id ? .isSelected : [])
        } else {
            // Value-based nav: the destination is built ONCE on tap (via navigationDestination),
            // not eagerly per row. A closure-NavigationLink here would materialize a full
            // DetectionDetailView for every row in the LazyVStack, so fast-scrolling thousands of
            // rows spiked memory/CPU and crashed the app.
            NavigationLink(value: d) {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
            }
            .buttonStyle(.plain)
        }
    }

    /// Export the exact rows the user is reviewing. A paused view keeps its row fields, NEW
    /// membership, timestamps, and observer positions frozen together; a live view takes one
    /// authoritative manager snapshot at the tap instead of exporting the delayed UI projection.
    private func export(_ format: BLEManager.ExportFormat,
                        snapshot supplied: BLEManager.DetectionExportSnapshot? = nil,
                        qualifier suppliedQualifier: String? = nil) {
        let base = supplied ?? (paused ? frozenExport : nil) ?? ble.detectionExportSnapshot()
        let scoped = supplied == nil
            ? base.reviewed(category: filter, unseenOnly: scope == .new, offlineOnly: scope == .offline,
                            query: searchQuery, sort: sortOrder,
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
    /// key, NEW or OFFLINE, SEARCH, STRONGEST, PAUSED, joined by "-". writeDetections lowercases
    /// the whole slug and turns spaces into "-", so "BODY CAM" lands as the same "body-cam"
    /// Android's `it.lowercase().replace(' ', '-')` makes. A file made from a strongest-first or
    /// paused review says so in its name the way a category or a search does: what left the
    /// phone was a re-ordered or frozen view, not the log in arrival order.
    /// TWIN: Android `slugParts` in LogScreen.exportLog, same words, same order.
    private var exportQualifier: String? {
        var parts: [String] = []
        if let filter { parts.append(filter) }
        switch scope {
        case .all: break
        case .new: parts.append("NEW")
        case .offline: parts.append("OFFLINE")
        }
        // Never leak a pasted device name/address into the temporary export filename.
        if !searchQuery.isEmpty { parts.append("SEARCH") }
        if sortOrder == .strongest { parts.append("STRONGEST") }
        if paused { parts.append("PAUSED") }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    /// Bottom action bar shown in select mode: bulk-mute the selected rows. Takes the body's
    /// snapshot rather than reading `shown` itself: this bar used to read it twice more (once
    /// for the button's action, once eagerly for the trait), so select mode - where every
    /// checkbox tap re-runs body - paid for three lens passes per eval instead of one.
    private func selectBar(_ snap: LogSnapshot) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Button { selection = Set(snap.shown.map { $0.id }) } label: {
                Text("SELECT SHOWN").font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.dim)
                    .padding(.horizontal, 14).frame(minHeight: 44)
                    .background(ACABTheme.bg2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            // allSatisfy, not isSuperset(of: map(\.id)): the superset form built a throwaway
            // array of every shown row's id on every body eval, and this modifier's argument
            // is evaluated eagerly whether or not VoiceOver is running.
            .accessibilityAddTraits(!snap.shown.isEmpty
                                    && snap.shown.allSatisfy { selection.contains($0.id) }
                                    ? .isSelected : [])
            Button(action: ignoreSelected) {
                HStack(spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                    Text("MUTE \(selection.count)").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(selection.isEmpty ? ACABTheme.faint : ACABTheme.onAccent)
                .frame(maxWidth: .infinity).frame(minHeight: 44)
                .background(selection.isEmpty ? ACABTheme.bg2 : ACABTheme.accent, in: Capsule())
                .overlay(Capsule().strokeBorder(selection.isEmpty ? ACABTheme.line : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 10).padding(.bottom, 8)
        .background(
            LinearGradient(colors: [ACABTheme.bg.opacity(0), ACABTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Consume the one-shot Status-tile handoff: arm the category filter over the ALL scope.
    /// The nil-out makes it exactly-once, so a later plain visit to the tab is unfiltered.
    private func consumeLogFocus() {
        guard let cat = LogFocus.pendingCategory else { return }
        LogFocus.pendingCategory = nil
        seedLens(scope: .all, category: cat)
    }

    /// A deep-link seed (Live Activity / notification NEW tap, offline-sync banner, Status
    /// category tile) positions only the axis it names and resets every other lens axis to its
    /// default. The seed promised specific rows: a search or a category the user set earlier
    /// would hide them, in a populated list that silently lacks them or behind the no-match
    /// panel when nothing else matches; a strongest-first sort would bury the newest of them;
    /// and a frozen snapshot would leave them off the paused list. Android does the same:
    /// MainScreen bumps logScreenKey on every seed, so LogScreen rebuilds its lens from the seed
    /// with every other axis at its default, and resumes the paused feed in the same handler.
    ///
    /// A seed also leaves bulk-select mode and closes the right-pane dossier, so a seeded visit
    /// always starts as a plain list. Android drops both structurally: LogScreen keeps select mode
    /// and its id set in plain `remember` state inside MainScreen's key(logScreenKey) wrapper, and
    /// every seed bumps that key.
    ///
    /// A seed returns the list to the top too (seedScrollToken, applied in masterList). Android
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
        searchFocused = false
        if paused { resumeFeed() }   // the live rows the seed exists to show, not a stale snapshot
        seedScrollToken += 1         // back to the top of the seeded lens, see masterList
        // A selection carried in from an earlier visit would aim MUTE N at rows the user never
        // chose, in a list whose contents just changed under the checkboxes. This closes the seed
        // route to that hazard and only that route: the lens controls stay live during select mode
        // on both apps, so a selection still outlives a lens change the user makes by hand. Here
        // only actionChips, pauseButton and the clear chip are gated on `selecting`, while the
        // tiles (tile), the scope chips (statusFilter) and the search field (searchAndSort) are
        // not, and ignoreSelected resolves picks over ble.logDetections rather than the shown rows.
        // Android is the same shape, so closing that is one rule across both apps and is not
        // decided here: only its action-chip row, PauseChip and clear chip sit behind !selectMode,
        // and SelectBar onIgnore filters `detections` the same way.
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
        if radiosOff { return "Radios are off, flip them on in Beacon." }
        return "Scanning\u{2026}"
    }
    private var radiosOff: Bool { if let s = ble.status { return !s.ble && !s.wifi }; return false }
    /// Only while genuinely scanning does the "log here" hint make sense (not in demo, not with
    /// no board linked, not when the radios are off. Then the headline already explains why
    /// nothing shows).
    private var isScanning: Bool { !ble.demoMode && ble.status != nil && !radiosOff }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope").font(.system(size: 38)).foregroundStyle(ACABTheme.line)
            Text(emptyHeadline)
                .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
            if isScanning {
                Text("Detections log here as beacons spots surveillance gear nearby.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            } else if !ble.demoMode && ble.status == nil {
                Text("connect your beacon, it does the listening")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    /// Shown when filters hide everything (e.g. New-only with nothing new yet).
    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: noMatchSymbol)
                .font(.system(size: 32)).foregroundStyle(ACABTheme.line)
            Text(noMatchTitle)
                .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.dim)
            Text(noMatchBody)
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                .multilineTextAlignment(.center)
            Button("Clear filters") {
                searchText = ""; filter = nil; scope = .all
            }
            .font(ACABTheme.display(14, weight: .semibold)).foregroundStyle(ACABTheme.text)
            .frame(minHeight: 44)
            // Keep resume reachable even if the active filter hides every frozen row while paused.
            if paused { pauseButton.padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .panel()
    }

    private var noMatchSymbol: String {
        switch scope {
        case .new:     return "checkmark.seal"
        case .offline: return "tray"
        case .all:     return "line.3.horizontal.decrease.circle"
        }
    }
    private var noMatchTitle: String {
        if !searchQuery.isEmpty { return "No matching detections" }
        switch scope {
        case .new:     return "Nothing new"
        case .offline: return "Nothing offline"
        // ALPR gets its specific title (Android parity): the body below already explains why a
        // quiet ALPR lens is the expected result, and the generic "No matches" undersold that.
        case .all:     return filter == "ALPR" ? "No ALPR radio signal" : "No matches"
        }
    }
    private var noMatchBody: String {
        if !searchQuery.isEmpty {
            return "Try a shorter name, vendor or MAC address, or clear the current filters."
        }
        switch scope {
        case .new:     return "Everything here is marked seen. New hits show up as they arrive."
        case .offline: return "No offline-recorded detections yet. The board buffers these while your phone is away."
        case .all:
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
