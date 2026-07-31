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

/// ALPR, DRONE, BODY CAM, TRACKER, GLASSES, CAMERA (Network camera). Reuses each type's
/// existing tint + glyph (netcamTone + web.camera.fill for the CAMERA / networkCamera entry).
let detectionCategories: [DetectionCategory] = [
    .init(type: .flockCamera,      key: "ALPR",     tileLabel: "ALPR",  chipLabel: "ALPR"),
    .init(type: .drone,            key: "DRONE",    tileLabel: "DRONE", chipLabel: "DRONE"),
    .init(type: .axonBodyCam,      key: "BODY CAM", tileLabel: "BODY",  chipLabel: "BODY CAM"),
    .init(type: .tracker,          key: "TRACKER",  tileLabel: "TRKR",  chipLabel: "TRACKER"),
    .init(type: .recordingGlasses, key: "GLASSES",  tileLabel: "GLAS",  chipLabel: "GLASSES"),
    .init(type: .networkCamera,    key: "CAMERA",   tileLabel: "NETCAM", chipLabel: "NETWORK CAM"),
]

/// Logbook: detection history, with category tiles that double as filters over the
/// list below. New/All filtering, a "mark all seen" baseline, and a select mode for
/// bulk-ignoring rows.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var scope: StatusScope = .all   // all / new (after the seen watermark) / offline-recorded
    @State private var selecting = false   // bulk-select mode
    @State private var selection: Set<String> = []   // selected Detection.id
    @State private var exportFile: ExportFile?
    @State private var confirmClear = false           // gate the destructive log wipe
    // Pause the live feed so a fast-scrolling list can actually be read. Paused freezes the
    // DISPLAYED rows to a snapshot; the store keeps accumulating in BLEManager (nothing is
    // dropped), and resume snaps back to live. frozenIds backs the "N new" affordance without
    // re-hashing the snapshot on every body eval.
    @State private var paused = false
    @State private var frozen: [Detection] = []
    @State private var frozenIds: Set<String> = []
    // T3: on regular width the log is a two-pane master/detail; this drives the right pane.
    // Never set at compact width, so the phone-portrait path is untouched.
    @State private var selectedDetail: Detection?
    @Environment(\.horizontalSizeClass) private var hSize

    /// Three-way status scope over the feed: everything, only-new (after the seen
    /// watermark), or only records the board buffered offline and replayed.
    private enum StatusScope { case all, new, offline }

    private var shown: [Detection] {
        // Paused: read from the frozen snapshot so the list holds still. Live otherwise.
        let base = paused ? frozen : ble.detections
        return base.filter { d in
            (filter == nil || d.type.category == filter) && matchesScope(d)
        }
    }

    /// While paused, how many detections have landed in the live store since the freeze -
    /// the "N new" hint. The store never stops filling; only the display is frozen.
    private var pausedNewCount: Int {
        guard paused else { return 0 }
        return ble.detections.reduce(0) { $0 + (frozenIds.contains($1.id) ? 0 : 1) }
    }

    private func pauseFeed() {
        frozen = ble.detections
        frozenIds = Set(frozen.map { $0.id })
        paused = true
    }
    private func resumeFeed() {
        paused = false
        frozen = []
        frozenIds = []
    }
    private func matchesScope(_ d: Detection) -> Bool {
        switch scope {
        case .all:     return true
        case .new:     return ble.isUnseen(d)
        case .offline: return d.offline
        }
    }
    /// Everything one body eval needs from the store, computed in a single pass. shown /
    /// count(cat) / newCount / offlineCount used to be independent computed properties, each
    /// a full O(store) filter, and body read them ~12x per eval at the ~3 Hz publish cadence.
    private struct LogSnapshot {
        let shown: [Detection]
        let counts: [String: Int]   // per category key, unfiltered (feeds the tiles)
        let newCount: Int
        let offlineCount: Int
    }

    private func makeSnapshot() -> LogSnapshot {
        var counts: [String: Int] = [:]
        var newN = 0, offN = 0
        for d in ble.detections {
            counts[d.type.category, default: 0] += 1
            if ble.isUnseen(d) { newN += 1 }
            if d.offline { offN += 1 }
        }
        return LogSnapshot(shown: shown, counts: counts, newCount: newN, offlineCount: offN)
    }

    var body: some View {
        let snap = makeSnapshot()   // ONE store pass per body eval; everything below reads this
        NavigationStack {
            layout(snap)
                // R8: if the selected detection disappears (clear log / bulk-ignore) while its
                // dossier is open in the two-pane, drop the selection so the pane returns to the
                // placeholder instead of showing a detection that no longer exists.
                .onChange(of: ble.detections) {
                    if let d = selectedDetail, !ble.detections.contains(where: { $0.id == d.id }) {
                        selectedDetail = nil
                    }
                    // Log cleared out from under a paused view: drop the frozen snapshot so we
                    // don't keep showing rows that no longer exist and can't be resumed away from.
                    if paused && ble.detections.isEmpty { resumeFeed() }
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

    /// Today's logbook screen: the whole view when compact, the left column when regular.
    /// Keeps its own nav / sheet / dialog modifiers so both layouts get them.
    private func masterList(_ snap: LogSnapshot) -> some View {
            ZStack(alignment: .bottom) {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(snap)
                        if !selecting && !ble.detections.isEmpty { actionChips }
                        summaryTiles(snap)
                        if !ble.detections.isEmpty { statusFilter(snap) }
                        if ble.detections.isEmpty { emptyState }
                        else if snap.shown.isEmpty { noMatchState }
                        else { logCard(snap) }
                        Spacer(minLength: selecting ? 72 : 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                    // T2: cap the readable column so tablets/landscape don't stretch a
                    // single column full-width. A no-op at phone portrait (~390pt < 640);
                    // the ScrollView itself stays full-width, only this content centers.
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                if selecting { selectBar }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Detection.self) { d in
                DetectionDetailView(detection: d)
            }
            .onAppear {
                // Drive-mode surfaces (widget / notification) deep-link here with
                // the NEW filter pre-armed via this flag; consume it once.
                if UserDefaults.standard.bool(forKey: "acab.pendingNewFilter") {
                    scope = .new
                    UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
                }
            }
            // A Live Activity tap while this tab is already showing never re-fires
            // onAppear; RootView posts this notification so the filter arms right away.
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("acabOpenLogNew"))) { _ in
                scope = .new
                UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
            }
            .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
            .confirmationDialog("Clear \(ble.detections.count) detection\(ble.detections.count == 1 ? "" : "s")?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Export CSV first") {
                    ble.writeDetectionsCSV { url in
                        if let url { exportFile = ExportFile(url: url) }
                    }
                }
                Button("Clear log", role: .destructive) { ble.clearDetections() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the log on this phone and can't be undone. If this is evidence, export it first.")
            }
    }

    private func header(_ snap: LogSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Logbook").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(selecting ? "\(selection.count) SELECTED"
                                 : "\(ble.detections.count) DETECTED · \(snap.newCount) NEW")
            }
            Spacer()
            if selecting {
                Button { exitSelect() } label: {
                    Text("DONE").font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(ACABTheme.bg2, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Labeled action chips under the title row (replaces the old anonymous
    /// icon buttons). Clear lives in the filter row (statusFilter), always reachable.
    private var actionChips: some View {
        HStack(spacing: 8) {
            actionChip("checkmark.circle", "SELECT") { resumeFeed(); selecting = true }   // bulk-ignore acts on live rows
            actionChip("square.and.arrow.up", "EXPORT CSV") {
                ble.writeDetectionsCSV { url in
                    if let url { exportFile = ExportFile(url: url) }
                }
            }
            actionChip("checkmark", "MARK SEEN") { ble.markAllSeen(); scope = .all }
            Spacer(minLength: 0)
        }
    }

    private func actionChip(_ system: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 11, weight: .semibold))
                Text(label).font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(ACABTheme.dim)
            .padding(.horizontal, 11).frame(height: 36)
            .background(ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// A strip of compact category tiles, one per category that has a detection this session;
    /// tapping one toggles it as a filter for the list. Dynamic so the row scales as categories
    /// grow and a zero-count (useless) filter never takes up space.
    private func summaryTiles(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            ForEach(shownCategories(snap)) { c in
                tile(c.type, c.key, c.tileLabel, count: snap.counts[c.key] ?? 0)
            }
        }
    }

    /// Which category tiles to actually render: a category with at least one detection this
    /// session, OR the currently-active filter even at count 0. The active-filter exception is
    /// REQUIRED: if the user has filtered to a category and its live count momentarily drops to 0
    /// (eviction / staleness), the tile must NOT vanish out from under them, or the filter breaks
    /// silently with no visible way to clear it. Empty row (nothing detected yet) is fine.
    private func shownCategories(_ snap: LogSnapshot) -> [DetectionCategory] {
        detectionCategories.filter { (snap.counts[$0.key] ?? 0) > 0 || filter == $0.key }
    }

    private func tile(_ type: DeviceType, _ cat: String, _ label: String, count n: Int) -> some View {
        let active = filter == cat
        return Button { filter = active ? nil : cat } label: {
            VStack(spacing: 5) {
                Image(systemName: type.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.tint)
                Text("\(n)")
                    .font(ACABTheme.display(18, weight: .bold))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text)
                    .monospacedDigit()
                Text(label)
                    .font(ACABTheme.mono(8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? type.tint.opacity(0.12) : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(active ? type.tint.opacity(0.4) : ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// All / New / Offline segmented chips ("mark all seen" lives in the header chips now).
    private func statusFilter(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            segChip("ALL", ble.detections.count, active: scope == .all) { scope = .all }
            segChip("NEW", snap.newCount, active: scope == .new, tint: ACABTheme.accent) { scope = .new }
            segChip("OFFLINE", snap.offlineCount, active: scope == .offline) { scope = .offline }
            Spacer(minLength: 0)
            // Quick clear at the top: reaching the bottom "clear log..." row is a long scroll
            // once the log is big. Goes through the same confirmation, quiet so it's not a mis-tap
            // magnet. Hidden in select mode (that's for bulk-ignore, not clearing).
            if !selecting {
                // Icon-only (trash reads on its own): a worded chip crowds this row on
                // narrower screens - Android's equivalent wrapped "CLEAR" mid-word.
                Button { confirmClear = true } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear log")
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
        }
        .buttonStyle(.plain)
    }

    /// The detection list (honoring the active filters), divider between rows.
    /// LazyVStack so a Desert-mode log of thousands only builds the rows on screen
    /// (was a plain VStack that materialized every row at once).
    private func logCard(_ snap: LogSnapshot) -> some View {
        let rows = snap.shown   // filtered once per body eval, in the snapshot
        return LazyVStack(alignment: .leading, spacing: 0) {
            logCardHeader.padding(.bottom, 8)
            ForEach(rows) { d in
                row(d)
                if d.id != rows.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    /// Log heading plus the pause/resume control. Pausing shows a "PAUSED · N NEW" pill so it's
    /// obvious the feed is still filling behind the frozen list. Hidden in select mode (that's
    /// bulk-ignore, which acts on the live rows).
    private var logCardHeader: some View {
        HStack(spacing: 8) {
            Kicker(logHeading)
            if paused {
                Text(pausedNewCount > 0 ? "PAUSED \u{00B7} \(pausedNewCount) NEW" : "PAUSED")
                    .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.accent)
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
        let basis = ble.timeBasis(for: d.id)
        // Per-row new-dot on every lens (not just NEW), so a fresh hit reads inline on ALL.
        let isNew = ble.isUnseen(d)
        if selecting {
            Button { toggle(d) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection.contains(d.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selection.contains(d.id) ? ACABTheme.accent : ACABTheme.faint)
                    DetectionRow(detection: d, timeBasis: basis, isNew: isNew)
                }
            }
            .buttonStyle(.plain)
        } else if hSize == .regular {
            // Two-pane: rows select the right dossier instead of pushing; the active
            // row carries a subtle highlight.
            Button { selectedDetail = d } label: {
                DetectionRow(detection: d, timeBasis: basis, isNew: isNew)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedDetail?.id == d.id ? ACABTheme.lineStrong : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        } else {
            // Value-based nav: the destination is built ONCE on tap (via navigationDestination),
            // not eagerly per row. A closure-NavigationLink here would materialize a full
            // DetectionDetailView for every row in the LazyVStack, so fast-scrolling thousands of
            // rows spiked memory/CPU and crashed the app.
            NavigationLink(value: d) {
                DetectionRow(detection: d, timeBasis: basis, isNew: isNew)
            }
            .buttonStyle(.plain)
        }
    }

    /// Bottom action bar shown in select mode: bulk-ignore the selected rows.
    private var selectBar: some View {
        HStack(spacing: 10) {
            Button { selection = Set(shown.map { $0.id }) } label: {
                Text("SELECT ALL").font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.dim)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(ACABTheme.bg2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: ignoreSelected) {
                HStack(spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                    Text("IGNORE \(selection.count)").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(selection.isEmpty ? ACABTheme.faint : ACABTheme.onAccent)
                .frame(maxWidth: .infinity).frame(height: 44)
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

    private func toggle(_ d: Detection) {
        if selection.contains(d.id) { selection.remove(d.id) } else { selection.insert(d.id) }
    }

    private func ignoreSelected() {
        let picks = ble.detections.filter { selection.contains($0.id) }
        ble.ignoreDevices(picks)
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
        if radiosOff { return "Radios are off, flip them on in Device." }
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
        switch scope {
        case .new:     return "Nothing new"
        case .offline: return "Nothing offline"
        case .all:     return "No matches"
        }
    }
    private var noMatchBody: String {
        switch scope {
        case .new:     return "Everything here is marked seen. New hits show up as they arrive."
        case .offline: return "No offline-recorded detections yet. The board buffers these while your phone is away."
        case .all:     return "No detections in this category yet."
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
