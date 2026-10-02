import SwiftUI
import Combine   // Timer.publish(...).autoconnect(): Xcode 27 warns when the file relies on SwiftUI's re-export
import MapKit
import UIKit
import UniformTypeIdentifiers   // UTType for the localOnly/expiring pasteboard item

/// Whether a full Map tab exists to receive the dossier's Open in Map handoff. ConnectView's
/// board-less saved-log sheet sets this false: MainTabView isn't mounted while disconnected,
/// so the tap would dead-end (nobody receives MapFocus.notification) and park a stale
/// coordinate in MapFocus.pending that hijacks a later connect's first map open.
private struct MapHandoffAvailableKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var mapHandoffAvailable: Bool {
        get { self[MapHandoffAvailableKey.self] }
        set { self[MapHandoffAvailableKey.self] = newValue }
    }
}

/// What the SEEN WITH YOU panel is currently saying, cached between evaluations.
///
/// Four states, not two, because "we have no opinion" has several different honest explanations and
/// picking the wrong one is a lie: location off means we were never watching, no recorded position
/// means we were watching and never filed one worth using (or the session that held them ended),
/// and not-measured means the scorer REFUSED the row on its time record. All three are distinct
/// from a real score of none, which is the only one of them that is a finding.
/// Internal, not private, so FollowEvidenceTests can name it through `dossierFollowCopy`.
enum FollowPanelState: Equatable {
    case scored(FollowEvidence.Score)
    /// A refusal, kept as its own case rather than folded back into `.scored` so the panel cannot
    /// quietly reacquire the none sentence for a row nothing was computed for.
    case notMeasured
    case noLocation
    case noFix
}

/// The dossier's short age text: "now", "12s ago", "4m ago", "1h ago", "3d ago", or a dash when
/// there is no time. `now` has no default on purpose: the dossier hands in its 1 s tick, so every
/// clock reading on that screen measures against the same instant and its body keeps a real
/// dependency on the tick (see DetectionDetailView `now`). Taking it as a parameter is also what
/// lets DetectionDetailTimeTests prove the text follows the `now` it is given, not the wall clock.
/// TWIN: android DetailScreen.kt `relativeAgo(ms, nowMs)`, same buckets and edges, pinned there by
/// DetailTimeLabelsTest; check-signature-drift.py's "dossier time labels" rule pins the same
/// buckets in both bodies.
func dossierRelativeAgo(_ date: Date?, now: Date) -> String {
    guard let date else { return "-" }
    // Non-trapping: a poisoned Date from an old checkpoint must degrade, not crash the view.
    let secs = max(0, Int(exactly: now.timeIntervalSince(date).rounded(.down)) ?? Int.max)
    switch secs {
    case ..<5:        return "now"
    case ..<60:       return "\(secs)s ago"
    case ..<3600:     return "\(secs / 60)m ago"
    case ..<86_400:   return "\(secs / 3600)h ago"
    default:          return "\(secs / 86_400)d ago"
    }
}

/// Compact duration since the first sighting, for CONFIRM IT's "over 18m so far": "45s", "18m",
/// "2h", "3d". Floored at 1 s, so a fresh row reads "over 1s", never "over 0s". `now` is required
/// for the same reasons as `dossierRelativeAgo`, and DetectionDetailTimeTests pins it the same way.
/// TWIN: android DetailScreen.kt `seenSpan(ms, nowMs)`, same buckets and floor, pinned there by
/// DetailTimeLabelsTest; check-signature-drift.py's "dossier time labels" rule pins the same
/// buckets in both bodies. The twin returns null for a missing stamp; here the view's
/// `sightingSpan` makes that call.
func dossierSightingSpan(since first: Date, now: Date) -> String {
    // Non-trapping: a poisoned first-seen Date from an old checkpoint must not crash the detail
    // view every time it opens (the decode clamp stops new ones at ingest).
    let secs = max(1, Int(exactly: now.timeIntervalSince(first).rounded(.down)) ?? Int.max)
    switch secs {
    case ..<60:      return "\(secs)s"
    case ..<3600:    return "\(secs / 60)m"
    case ..<86_400:  return "\(secs / 3600)h"
    default:         return "\(secs / 86_400)d"
    }
}

/// The SIGHTINGS row value: the count, then how good the first-seen time is. `now` is the
/// dossier's 1 s tick, for the same reasons as `dossierRelativeAgo`.
/// One line, so this cell says only how good the time is; the Technical details rows carry
/// the actual range and the explanation. The tilde is the same "derived" shorthand the log
/// row's RECON tag stands for.
func dossierSightingsText(count: Int, firstSeen: Date?, basis: TimeBasis, now: Date) -> String {
    guard let firstSeen else { return "\(count)" }
    switch basis {
    case .exact:         return "\(count) \u{00B7} first \(dossierRelativeAgo(firstSeen, now: now))"
    case .reconstructed: return "\(count) \u{00B7} first ~\(dossierRelativeAgo(firstSeen, now: now))"
    case .bracketed:     return "\(count) \u{00B7} time bounded"
    case .unknown:       return "\(count) \u{00B7} time unknown"
    }
}

/// A dossier row value as drawn: through keepingMiddleDotsAttached (SettingsView.swift), the
/// no-break space BEFORE each middle dot that the Map legend headline and the Log rows use, so a
/// wrap keeps the dot on its word's line and never starts a line with an orphan "· 80%".
/// Applied where dossierRowValue draws, not in the builders, so the strings the tests pin
/// (dossierConfidenceLine, the SIGHTINGS value) stay as written; the spoken text is unchanged.
/// TWIN: android Components.kt dossierValueForDisplay (drawn by GroupedValueRow), through keepingMiddleDotsAttached
/// (LogScreen.kt).
func dossierValueForDisplay(_ value: String) -> String {
    keepingMiddleDotsAttached(value)
}

/// The MATCH QUALITY "confidence" row value: the verdict words, then the percent. This is the
/// band owner: the row's weak-match glyph switches at the same 50 edge, and
/// DetectionRow.confidenceWord follows these edges. Low certainty is loud amber (the glyph),
/// never crimson: crimson is for categories only, never for confidence.
///
/// A Desert-mode row (nearbyDevice) is confidence 0 because nothing matched, not because a match
/// is weak, so it reads "Not a match" with no percent (the Log hides that 0 for the same reason).
/// TWIN: android DetailScreen.kt `dossierConfidenceLine`.
func dossierConfidenceLine(type: DeviceType, confidence: Int) -> String {
    if type == .nearbyDevice { return "Not a match" }
    let verdict: String
    switch confidence {
    case ..<50: verdict = "Weak match, verify"
    case ..<80: verdict = "Partial match"
    default:    verdict = "Strong match"
    }
    return "\(verdict) \u{00B7} \(confidence)%"
}

/// What the SEEN WITH YOU section shows for a state: a band label (plain text, and the only
/// state that also earns the section header) and the sentence under it. Only a firing band has
/// a label; none, the refusal and the two no-crumb states each keep their own sentence.
func dossierFollowCopy(_ state: FollowPanelState) -> (label: String?, sentence: String) {
    switch state {
    case .scored(let s): return (FollowEvidence.label(s.band), FollowEvidence.body(s))
    case .notMeasured:   return (nil, FollowEvidence.notMeasuredLine)
    case .noLocation:    return (nil, FollowEvidence.noLocationLine)
    case .noFix:         return (nil, FollowEvidence.noFixLine)
    }
}

/// Whether the SIGNAL header reads STALE (true) or LIVE (false). Sample data is always active
/// (C10): the Log's Active segment lists sample rows, Status counts them nearby and Map keeps them
/// in "active", so the dossier reads LIVE for them too rather than STALE on the one page that
/// describes the row. The demo arm lives here, not in BLEManager.isStale, so the store's own
/// staleness answer stays a plain clock reading for every other caller. `storeIsStale` is an
/// autoclosure, so a sample row never asks the store. DetectionDetailTimeTests pins the demo arm.
/// TWIN: android DetailScreen.kt `val stale = !demo && ble.isStale(d.id, nowMs = nowMs)`.
func dossierSignalIsStale(isDemoMode: Bool, storeIsStale: @autoclosure () -> Bool) -> Bool {
    !isDemoMode && storeIsStale()
}

/// The Technical details "Last seen" value. Sample data reads "now" (dossierRelativeAgo's word for
/// the freshest bucket), the same demo arm dossierSignalIsStale gives the SIGNAL header: the seed
/// stamps its rows once, so the measured age grew to "9m ago" under a header that said LIVE, and
/// the tour could not teach what LIVE means (C12-03). `measured` is an autoclosure, so a sample
/// row never computes an age. Every other row keeps the measured reading. Pinned beside the
/// dossierSignalIsStale demo-arm test in DetectionDetailTimeTests. TWIN: android DetailScreen.kt's
/// Technical details "Last seen" row, which reads "now" in sample data the same way.
func dossierLastSeenValue(isDemoMode: Bool, measured: @autoclosure () -> String) -> String {
    isDemoMode ? "now" : measured()
}

/// The SIGNAL header word: SAMPLE for sample rows (an uppercase sibling of LIVE / STALE, so the
/// header never calls a sample row live), else STALE or LIVE. `stale` is dossierSignalIsStale's
/// answer, which still feeds the sparkline tint. Spoken as "SIGNAL · <word>".
/// TWIN: android DetailScreen.kt `dossierSignalWord`.
func dossierSignalWord(isDemoMode: Bool, stale: Bool) -> String {
    if isDemoMode { return "SAMPLE" }
    return stale ? "STALE" : "LIVE"
}

/// The "why flagged" line under the hero. When the method and the source carry the same label
/// (a drone: Remote ID over Remote ID) the source is dropped instead of repeated. A Desert-mode
/// row (nearbyDevice) was flagged by nothing: its method is SSID on WiFi and none on BLE, so it
/// names only the radio and desert mode. TWIN: android DetailScreen.kt `dossierFlaggedLine`.
func dossierFlaggedLine(type: DeviceType, methodLabel: String, sourceLabel: String) -> String {
    if type == .nearbyDevice { return "Heard over \(sourceLabel) in desert mode." }
    return methodLabel.caseInsensitiveCompare(sourceLabel) == .orderedSame
        ? "Flagged by \(methodLabel)."
        : "Flagged by \(methodLabel) over \(sourceLabel)."
}

/// The hero subtitle: the node handle, then the maker (or the per-type vendor) unless it is the
/// headline already drawn above it (a tag titled "Apple Find My", glasses titled "Meta"). Equal
/// ignoring case only; no fuzzy match, so "Flock Safety" under "FlockSafety" stays.
/// `headline` is the drawn title, Detection.titleName. TWIN: android DetailScreen.kt
/// `dossierHeroSubtitle`.
func dossierHeroSubtitle(node: String, makerOrVendor: String, headline: String) -> String {
    makerOrVendor.caseInsensitiveCompare(headline) == .orderedSame
        ? "NODE \(node)"
        : "NODE \(node) · \(makerOrVendor)"
}

/// The MATCH QUALITY "matched on" value. The two OUI telegrams are the FAQ's quoted words; every
/// other method reads its own label verbatim, with its own casing ("device name", "manufacturer
/// ID", "SSID", "Remote ID"), never lowercased and never a telegram that says match twice.
///
/// Some OUI hits land on the maker's OWN registered block (Axon, Utility, Motorola Solutions, and
/// every camera brand in netcam_signatures.h), not a chipset shared with unrelated gear, so
/// "chipset only" would understate what we know. What's uncertain is which of the vendor's
/// products this is, which is why it keeps the amber weak-match treatment. Keyed on `maker`
/// rather than bodyCamSignature so network cameras stop sitting on the wrong side of this exact
/// distinction.
///
/// A Desert-mode row (nearbyDevice) matched nothing, yet desert_detect.cpp stamps its WiFi rows
/// with method SSID and its BLE rows with none, so the method label would read "SSID" or
/// "unknown" on a row no signature claimed. It reads "no signature" instead, keyed on the type.
/// TWIN: android DetailScreen.kt `methodChipLabel`.
func methodChipLabel(type: DeviceType, method: DetectionMethod, maker: String?) -> String {
    if type == .nearbyDevice { return "no signature" }
    switch method {
    case .oui where maker != nil: return "OUI \u{00B7} VENDOR ONLY"
    case .oui:                    return "OUI \u{00B7} CHIPSET ONLY"
    default:                      return method.label
    }
}

/// The MATCH QUALITY explainer for a body cam with no recognized signature. Gated on the row
/// REALLY being a replay (Detection.isHistory, the wire "hist" flag, persisted so it survives a
/// reload), never on the detail being absent (J3). TWIN: android DetailScreen.kt
/// `dossierBodyCamFallbackLine`.
func dossierBodyCamFallbackLine(isReplay: Bool) -> String {
    isReplay
        ? "Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired."
        : "Matched a body-worn camera signature. The board didn't report which one."
}

/// The MATCH QUALITY explainer for a Desert-mode row (nearbyDevice, wire t=7). desert_detect.cpp
/// emits one for every device it hears, at confidence 0, with method SSID (WiFi) or none (BLE),
/// so the per-method lines would claim a signature matched. `detail` is that file's address
/// label (bleAddrLabel, desertClassifyWiFi), which the footer draws verbatim under this line; an
/// unknown label or none (a buffered record keeps no detail) gets the first sentence alone.
/// TWIN: android DetailScreen.kt `dossierNearbyDeviceLine`.
func dossierNearbyDeviceLine(detail: String?) -> String {
    let base = "Desert mode lists every nearby device it hears, and no signature matched this one."
    switch detail {
    case "randomized MAC":
        return "\(base) \"randomized MAC\" means the address isn't from a maker's registered block. Phones, watches, and earbuds use addresses like this and change them often, so the same device can come back under a new one."
    case "hardware OUI":
        return "\(base) \"hardware OUI\" means the address starts with a block registered to a maker, so it usually stays the same between sightings."
    case "OUI unknown":
        return "\(base) \"OUI unknown\" means the board couldn't tell whether the address comes from a maker's registered block or is randomized."
    default:
        return base
    }
}

/// The app's note under a tracker's verbatim firmware detail when that detail ends "(offline)":
/// the firmware means a tag separated from its owner, and the same word elsewhere in the app
/// names the offline buffer. Nil for every other row, and for a tracker without the suffix.
/// TWIN: android DetailScreen.kt `trackerOfflineNote`.
func trackerOfflineNote(type: DeviceType, detail: String?) -> String? {
    guard type == .tracker, let detail, detail.hasSuffix("(offline)") else { return nil }
    return "offline here means separated from its owner, not replayed from the offline buffer."
}

/// The caption under a drone's location thumbnail while it draws the operator marker.
/// TWIN: android DetailScreen.kt `DRONE_OPERATOR_CAPTION`.
let droneOperatorCaption = "operator position, from the drone's Remote ID"

/// The pushed dossier's system bar: the category as an inline title (DeviceType.inlineCategory, the
/// locked "body cam" spelling; never DeviceType.label, which reads "Body Camera"). The iPad Log's embedded
/// pane is NOT pushed: it sits inside the Log root's own NavigationStack, so a title set here would
/// replace that root's "Log". The embedded pane therefore sets none.
private struct DossierChrome: ViewModifier {
    let embedded: Bool
    let title: String
    @ViewBuilder
    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Full detection detail: pushed from Status and the Log, embedded in the iPad Log's second pane,
/// and inside the Map's sheet or inspector. An inset-grouped List in the C12 panel order, under
/// the system navigation bar.
struct DetectionDetailView: View {
    let detection: Detection
    /// True when hosted persistently in a two-pane (T3 iPad Log). Then we must NOT hide the
    /// tab bar (that would trap the user in the Log tab), it sets no navigation title (it would
    /// replace the Log root's), and there is no back to show.
    var embedded: Bool = false
    /// The dossier's reading width on regular width: the iPad Log's two-pane caps the embedded
    /// dossier at this (DetectionsView.detailPane), and a pushed one caps itself the same way
    /// below, so one dossier has one width on a device (HIG Layout: restrict the width of text).
    /// Android's pane is 640dp, its own derivation.
    static let readingWidth: CGFloat = 560
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.mapHandoffAvailable) private var mapHandoffAvailable
    @ScaledMetric(relativeTo: .caption) private var signalGraphHeight: CGFloat = 46
    /// One column for the MATCH QUALITY cue glyphs, so the two row titles align whichever
    /// symbol each row shows.
    @ScaledMetric(relativeTo: .body) private var matchGlyphColumn: CGFloat = 24
    @State private var copied = false

    // "Confirm it" checklist, per-visit UI state only, nothing persists.
    @State private var lookedAround = false
    @State private var secondPass = false
    @State private var confirmRandomWatch = false   // R7: confirm dialog before starring a randomized MAC
    @State private var showRssiInfo = false          // tap the info dot next to SIGNAL to explain the RSSI graph
    @State private var showMuteOptions = false
    @State private var muteError: String?
    @State private var identityExpanded = false
    @State private var helpExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Follow evidence (trackers only). Cached in @State and refreshed on a slow tick rather than
    // derived inside `body`, because this dossier re-renders at the coalesced publish cadence (a
    // few Hz, much more under a Desert-mode flood) and the span pass is O(n^2) over up to 120
    // crumbs. Recomputing it per render would hang a 7140-haversine sweep off every incoming
    // detection for as long as the screen is open, which is exactly the thing the spec forbids.
    @State private var followState: FollowPanelState = .scored(.unscored)
    /// 5 s cadence, held in @State so the SAME publisher survives a re-render. As a plain `let` it
    /// would be rebuilt on every body evaluation, and onReceive would cancel and resubscribe each
    /// time, so under a fast feed the timer would never live long enough to fire once.
    @State private var followTick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// The clock every time-derived reading on this screen is measured against: the LIVE/STALE
    /// header and the sparkline dim, First seen and Last seen, the SIGHTINGS age, and CONFIRM IT's
    /// "over 2m". Staleness moves with the clock, not with @Published state, so once this device
    /// stops being heard and nothing else publishes, nothing invalidates the view: the header held
    /// LIVE and Last seen held its last age indefinitely, at exactly the moment someone
    /// checks whether a device really went quiet. followTick cannot stand in for it, because its
    /// refreshes assign Equatable state that is unchanged in the usual case, and SwiftUI skips those.
    /// 1 s, and held in @State for the same reason as DashboardView's `staleTick`. TWIN: Android
    /// DetailScreen `nowMs` drives the same readings at the same cadence. Every clock reading below
    /// measures against `now` instead of calling Date(). The panels, the Technical details rows
    /// included, read it inside DeferredView bodies, which re-run on every pass of this body, so
    /// they move with each tick.
    @State private var now = Date()
    @State private var staleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Mapped-camera corroboration for the LOCATION panel, cached for the same reason followState
    /// is. `ALPRStore.nearest(to:)` walks the node array end to end, and its inputs (this
    /// sighting's coordinate, the loaded dataset, the unverified-nodes setting) all move far more
    /// slowly than the render cadence, so reading it inside `body` hung a full-dataset pass off
    /// every incoming detection for as long as an ALPR dossier stayed open. Refreshed on the same
    /// 5 s tick, which also picks up a dataset that finishes loading while the screen is up.
    @State private var alprMatch: ALPRMatch?

    /// What the panel needs from the nearest mapped node. Equatable so a refresh that finds the
    /// same answer (the usual case) doesn't invalidate the view.
    private struct ALPRMatch: Equatable {
        let meters: Double
        let maker: String
        let tier: UInt8
        let confirmed: Bool
    }

    /// Camera for the LOCATION thumbnail, fitted in `mapThumbnail` whenever its pin or trail moves.
    /// A binding rather than `initialPosition`, which a map reads once: with it, the only way to
    /// bring the camera to a moved pin was to build a whole new map. `.automatic` is only the value
    /// before the first fit, which runs as the thumbnail appears.
    @State private var thumbnailCamera: MapCameraPosition = .automatic

    /// Always re-read the live row: the captured `detection` is a value type with let fields,
    /// so it can never update, and this screen sits next to id-keyed lookups that do (the
    /// LIVE/STALE header, the sparkline). A frozen copy means the dBm readout never moves
    /// beside a moving sparkline, and "seen 3x" in CONFIRM IT can never increment while you
    /// walk back for a second pass, which is the whole point of that checklist. Falls back to
    /// the captured copy once the row is evicted, so the dossier doesn't blank out.
    private var d: Detection { ble.detection(for: detection.id) ?? detection }
    private var trend: [Int] { ble.rssiTrend(for: d.id) }
    /// Exactly the same subject-vs-observer resolution as the full Map tab. Non-drone dossiers
    /// show the strongest located sighting; Remote ID dossiers keep the aircraft coordinate.
    private var mapCoordinate: CLLocationCoordinate2D? {
        resolvedDetectionMapCoordinate(type: d.type, wireCoordinate: d.coordinate,
                                       strongestObserverCoordinate: ble.capturedLocation(for: d.id),
                                       allowNonDroneWireFallback: d.isHistory || ble.demoMode
                                           || liveWireObserverFixIsCurrent(gpsAgeSec: d.gpsAgeSec))
    }
    private var muteRule: IgnoredDevice? {
        ble.ignored.first { $0.mac == d.mac.lowercased() }
    }
    private var canAcquireFreshLocation: Bool {
        ble.connectionState == .connected || ble.demoMode
    }

    var body: some View {
        // The panels are built in DeferredView (Components.swift), not inline: this getter's
        // modifier chain copied the whole panel tuple at each stage, and in a Debug build that
        // frame alone took a quarter of an iPhone's 1 MiB main-thread stack.
        List { DeferredView {
            // THE CANONICAL DOSSIER ORDER (C12, 2026-09-23). android DetailScreen.kt's dossier
            // column runs the same panels in the same SEQUENCE, so an instruction that names a
            // panel ("expand Technical details", "tap Copy MAC Address") is true on both phones.
            // The decisions come first (Watch and Mute two-up, any mute rule's state under them),
            // then what the match rests on (match quality, CONFIRM IT for a weak or OUI-only
            // match), then the live evidence (signal, sightings, the map, Seen with you), and the
            // reference material last (Related help, then Technical details), with Copy MAC
            // Address the final control and never inside the disclosure.
            // check-signature-drift.py's "dossier shape" rule pins this sequence on both sides;
            // move a panel on both or on neither.
            titleBlock
            primaryActions
            matchQualityPanel
            if d.type.isExperimental { experimentalNote }
            if showConfirmIt { confirmItPanel }
            signalPanel
            statGrid
            // The SAME resolution the Map tab pins with: Remote ID aircraft coordinates
            // win for drones; fixed installs use the phone position paired with their
            // strongest located RSSI sample. Broadcast-GPS rows keep their richer readout
            // in the expandable technical details below.
            if let coord = mapCoordinate { locationPanel(coord) }
            // Tracker rows only, and only here. Nothing about this judgement is allowed to
            // reach a notification, a haptic, the buzzer, the log row, the dashboard
            // counters, the Live Activity, the map, or the CSV export. The export in
            // particular: it is a record of raw sightings that gets handed over as
            // evidence, and a derived opinion in a column reads as fact.
            followPanel
            relatedHelpPanel
            identityDisclosure
            copyButton
        } }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(ACABTheme.bg)
        // A pushed dossier on regular width (iPad from Status, or a compact-window Log's push)
        // keeps the two-pane's reading width, centred on the bg colour: uncapped it ran the full
        // 1032pt, "matched on" 900pt from its value. The embedded pane caps itself, and the
        // Map's inspector is narrower than the cap, so neither is touched.
        .frame(maxWidth: hSize == .regular && !embedded ? Self.readingWidth : .infinity)
        .frame(maxWidth: .infinity)
        .background(ACABTheme.bg)
        .modifier(DossierChrome(embedded: embedded, title: d.type.inlineCategory))
        .toolbar(embedded ? .visible : .hidden, for: .tabBar)
        // Evaluate on appear, then at most once per 5 s while the screen is up, and never from
        // the ingest or publish paths. Crumbs need 60 s and 25 m to move at all, so a 5 s refresh
        // is already far faster than the underlying data can change. The mapped-camera
        // corroboration rides the same three hooks, but do NOT read ITS input as equally still.
        // The panel resolves the aircraft coordinate for Remote ID and the captured strongest-
        // RSSI observer coordinate for other rows. Both can move, with none of the 60 s / 25 m
        // floors the tracker crumb gate has. So the
        // distance in the corroboration line can trail the coordinate printed at the top of the
        // same panel by up to one tick. Bounded and accepted: nearest(to:) walks the whole node
        // array, so hanging it off every coordinate change would put that walk back on the render
        // path this cache exists to clear.
        .onAppear { refreshFollow(); refreshALPRMatch() }
        // The Map's regular-width inspector (MapTabView DossierPresentation) keeps ONE detail view
        // mounted and swaps the row into it; the Log's two-pane gives each row a fresh view with
        // .id(d.id). Without this the inspector would keep showing the previous row's follow
        // score, its ticked CONFIRM IT toggles and a Copied label for a MAC never copied. Every
        // per-visit flag resets here. TWIN: android DetailScreen.kt keys the same per-row state
        // on d.id with remember(d.id) (identityExpanded, looked, secondPass, and RelatedHelpPanel's
        // expanded).
        .onChange(of: d.id) {
            identityExpanded = false; helpExpanded = false
            lookedAround = false; secondPass = false; copied = false; showRssiInfo = false
            refreshFollow(); refreshALPRMatch()
        }
        .onReceive(followTick) { _ in refreshFollow(); refreshALPRMatch() }
        .onReceive(staleTick) { now = $0 }
        // The dialogs hang off the List, not off the rows that open them: a presentation
        // attached to a List row does not present while that row is scrolled away, and Watch
        // can be tapped from the CONFIRM IT star row with the action row off screen, while the
        // mute dialog is reached from both Mute… and Change.
        // A randomized address rotates, so confirm before starring it. ONE dialog with a
        // type-selected body, never two in a row: a tracker is almost always randomized too, so
        // firing a generic prompt and then a tracker prompt would double up on the same tap.
        .confirmationDialog("Watch a rotating address?", isPresented: $confirmRandomWatch,
                            titleVisibility: .visible) {
            Button("Watch Anyway") { ble.watchDevice(d) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(watchWarningBody)
        }
        .confirmationDialog("Mute this device", isPresented: $showMuteOptions,
                            titleVisibility: .visible) {
            muteOptionButtons
        } message: {
            Text(muteExplanation)
        }
        .alert("Couldn't mute device", isPresented: Binding(
            get: { muteError != nil }, set: { if !$0 { muteError = nil } }
        )) {
            Button("OK", role: .cancel) { muteError = nil }
        } message: {
            Text(muteError ?? "No mute was added.")
        }
        // A star refused at the firmware's 256-entry cap sets this on the manager; surface it here
        // instead of the Watch tap silently doing nothing.
        .alert("Watchlist full", isPresented: $ble.watchlistFull) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can watch up to 256 devices at once. Stop watching one before adding another.")
        }
    }

    // MARK: Shared rows

    /// GroupedRow's shape (Components.swift) for the dossier rows GroupedRow cannot draw: a leading
    /// cue glyph (match quality), a monospaced or selectable value, or a note under the value
    /// (Technical details). Inline when it fits the offered width, title over value when it does
    /// not (ViewThatFits), and always stacked at accessibility sizes. No Text here clamps its line
    /// count or hugs its width. The glyph is decorative for VoiceOver: the row's words carry the
    /// same meaning.
    private func dossierRow(_ title: String, _ value: String, design: Font.Design = .default,
                            selectable: Bool = false, note: String? = nil,
                            glyph: String? = nil, glyphColor: Color = ACABTheme.dim) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let glyph {
                Image(systemName: glyph)
                    .font(ACABTheme.font(.body))
                    .foregroundStyle(glyphColor)
                    .frame(width: matchGlyphColumn)
                    .accessibilityHidden(true)
            }
            if dynamicTypeSize.isAccessibilitySize {
                dossierRowStacked(title, value, design: design, selectable: selectable, note: note)
            } else {
                ViewThatFits(in: .horizontal) {
                    dossierRowInline(title, value, design: design, selectable: selectable, note: note)
                    dossierRowStacked(title, value, design: design, selectable: selectable, note: note)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dossierRowInline(_ title: String, _ value: String, design: Font.Design,
                                  selectable: Bool, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            dossierRowTitle(title)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                dossierRowValue(value, design: design, selectable: selectable, alignment: .trailing)
                if let note { dossierRowNote(note, alignment: .trailing) }
            }
        }
    }

    private func dossierRowStacked(_ title: String, _ value: String, design: Font.Design,
                                   selectable: Bool, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            dossierRowTitle(title)
            dossierRowValue(value, design: design, selectable: selectable, alignment: .leading)
            if let note { dossierRowNote(note, alignment: .leading) }
        }
    }

    private func dossierRowTitle(_ title: String) -> some View {
        Text(title)
            .font(ACABTheme.font(.body)).foregroundStyle(ACABTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func dossierRowValue(_ value: String, design: Font.Design, selectable: Bool,
                                 alignment: TextAlignment) -> some View {
        // Every dossier value is data (a method, a confidence, a MAC): the instrument face.
        // `design` stays in the signature; .monospaced already resolves to the same face.
        // Verbatim through dossierValueForDisplay: a middle dot stays on its word's line.
        let text = Text(verbatim: dossierValueForDisplay(value))
            .font(ACABTheme.telemetry(.subheadline, weight: .regular))
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
        // Two branches, not a ternary: the two text-selectability types differ.
        if selectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }

    private func dossierRowNote(_ note: String, alignment: TextAlignment) -> some View {
        Text(note)
            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One half of the two-up action row: a tint label on a bg2 key, or onAccent on a tint fill
    /// while the action is on. No border and no shadow.
    private func actionLabel(_ title: String, systemImage: String, on: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(ACABTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(on ? ACABTheme.onAccent : ACABTheme.tint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(on ? ACABTheme.tint : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
    }

    // MARK: Title

    /// Watch and Mute, two-up (stacked at accessibility sizes). An existing mute rule adds its
    /// state and Change in the section below.
    ///
    /// The pair is the FOOTER of an empty section, never a row. The inset-grouped List masks a
    /// row to the section's own corner radius, so a full-width row gave each key the section's
    /// large radius on its outer corners and ACABTheme.radius on its inner ones. A footer is not
    /// masked, so both keys keep their own radius on all four corners.
    @ViewBuilder
    private var primaryActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        Section {
            EmptyView()
        } footer: {
            layout {
                watchButton
                ignoreButton
            }
            .textCase(nil)
            .listRowInsets(EdgeInsets())
        }
        if let rule = muteRule { mutedStateSection(rule) }
    }

    private var titleBlock: some View {
        let headline = d.titleName
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return Section {
            layout {
                CatGlyph(type: d.type, size: 60, style: .tile(fill: ACABTheme.bg2))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    // The headline is the same user/device name the Log row and the Status hero
                    // lead with (custom label, else advertised name, else UAS serial, else maker,
                    // else the class's title fallback: Detection.titleName); the node handle
                    // moves into the subtitle. TWIN: android DetailScreen.kt title block,
                    // `d.titleName` over `dossierHeroSubtitle(...)`, one dossier header on both
                    // phones.
                    Text(headline)
                        .font(ACABTheme.font(.title2, weight: .bold)).foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // Subtitle is the node handle and the vendor, not the type label (F15), the
                    // navigation title names the category. NEITHER branch may consult
                    // the OUI lookup: for a Flock Falcon it resolves to the Liteon WiFi module and
                    // would head the ALPR dossier with "Liteon" instead of "Flock Safety".
                    // The OUI reading still shows in the identity panel below, labelled as such.
                    //
                    // `maker` leads because it is the name the device's own payload carried;
                    // `vendor` is the per-type fallback. For a body cam both read the same
                    // signature, so a recognized Motorola or Utility hit names its own maker.
                    // With no signature it recognizes (a replayed row carries no detail),
                    // `vendor` names all three makers together, Axon first, so a body-cam row
                    // names Axon alone only when an Axon signature fired. maker is nil for
                    // Flock, so the ALPR case above is unaffected. The maker is dropped when it
                    // IS the headline (dossierHeroSubtitle), so "Meta" never reads twice.
                    Text(dossierHeroSubtitle(node: d.nodeName, makerOrVendor: d.maker ?? d.vendor,
                                             headline: headline))
                        .font(ACABTheme.telemetry(.subheadline, weight: .regular)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                // A VoiceOver heading, as android's hero `displayName` is a TalkBack heading().
                .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var experimentalNote: some View {
        Section {
            Label {
                Text("Experimental detector. \(d.type.experimentalNoun) signatures are not field-verified yet, so treat this as a maybe.")
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ACABTheme.warn)
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    // MARK: Match quality (1d / F12)

    /// RELATED HELP: the FAQ answers that speak to THIS category, deep-linked.
    ///
    /// It is the only route from a dossier into HelpView (the bar carries no help item), so it
    /// renders whenever the category has mapped questions. Since the C12 order (2026-09-23) it
    /// opens the reference material above Technical details; the first screen carries the doubt
    /// itself (the MATCH QUALITY footer, and CONFIRM IT for a weak or OUI-only match). Collapsed
    /// so a second block of prose does not stack under that warning.
    ///
    /// Renders nothing for categories with no mapped questions (nearby device and unknown, whose
    /// faqKey is ""). Every real category has entries, and the drift check enforces that.
    @ViewBuilder
    private var relatedHelpPanel: some View {
        let qs = FAQContent.shared.related(for: d.type)
        if !qs.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $helpExpanded) {
                    ForEach(qs, id: \.id) { q in
                        NavigationLink {
                            HelpView(
                                scrollToId: q.id,
                                canImproveDetection: improveDetectionAvailable(
                                    isSessionReady: ble.sessionReady,
                                    isDemoMode: ble.demoMode))
                        } label: {
                            Text(q.q)
                                .font(ACABTheme.font(.body)).foregroundStyle(ACABTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } label: {
                    // Same anatomy as identityDisclosure below, and the summary is BYTE-IDENTICAL to
                    // android DetailScreen.kt's RelatedHelpPanel `summary`. Collapsed content leaves
                    // the accessibility tree entirely, so without this line VoiceOver reached a
                    // control that named nothing about what it holds while Technical details, sitting
                    // right under it, said what was inside.
                    disclosureLabel("Related help", systemImage: "questionmark.circle",
                                    summary: "\(qs.count) answer\(qs.count == 1 ? "" : "s") for \(d.type.inlineLabel)")
                }
            }
            .listRowBackground(ACABTheme.bg2)
        }
    }

    /// The confidence row's amber weak-match cue. A Desert-mode row is confidence 0 because nothing
    /// matched, so it reads "Not a match" (dossierConfidenceLine) beside the plain gauge, with no
    /// weak match to verify. TWIN: android DetailScreen.kt MatchQualityPanel's `weak`.
    private var confidenceIsWeak: Bool { d.confidence < 50 && d.type != .nearbyDevice }

    private var matchQualityPanel: some View {
        Section {
            // The weak-match cue rides the leading glyphs, never the values: ONE rule on both
            // phones (android's GroupedValueRow has no value colour). The confidence glyph also
            // changes shape below 50, so the cue does not ride colour alone. At 50 and over it
            // is a gauge, not info.circle: on this screen info.circle marks the tappable "What
            // the RSSI graph means" control and the Technical details disclosure, so an (i) here
            // read as a help button that did nothing (C12-09). TWIN: android DetailScreen.kt MatchQualityPanel's confidence icon
            // (Icons.Outlined.Speed, the same gauge idea; Warning below 50).
            dossierRow("matched on", methodChipLabel(type: d.type, method: d.method, maker: d.maker),
                       glyph: "touchid", glyphColor: d.method == .oui ? ACABTheme.warn : ACABTheme.dim)
            dossierRow("confidence", dossierConfidenceLine(type: d.type, confidence: d.confidence),
                       glyph: confidenceIsWeak ? "exclamationmark.triangle.fill" : "gauge.medium",
                       glyphColor: confidenceIsWeak ? ACABTheme.warn : ACABTheme.dim)
        } header: {
            Kicker("MATCH QUALITY")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                matchExplainer
                    .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                // Keep the broadcast's qualifications visible when technical identity is collapsed:
                // strings such as "or Quest" / "gear, no Remote ID" must never turn into certainty.
                // TWIN: android DetailScreen.kt's MatchQualityPanel closes with the same string in
                // this same slot, verbatim and with no kicker of its own.
                if let detail = d.detail, !detail.isEmpty {
                    Text(detail)
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Directly under the verbatim detail: the firmware's "(offline)" on a tracker
                // means separated from its owner, not the offline buffer (trackerOfflineNote).
                // TWIN: android DetailScreen.kt MatchQualityPanel, the same note in this slot.
                if let note = trackerOfflineNote(type: d.type, detail: d.detail) {
                    Text(note)
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    /// The MATCH QUALITY footer: what actually matched, in words.
    /// Returns Text so the OUI vendor name can render semibold inside the dim line.
    private var matchExplainer: Text {
        // Body cam covers five signatures of very different weight under one label, so the
        // generic per-method line is too vague here (and its "shared chipset" wording is
        // wrong for a vendor's own OUI block). Name the signature that fired instead.
        if let sig = d.bodyCamSignature { return signatureExplainer(sig) }
        // Replayed from the offline buffer: StoredDet (firmware det_log.h) has no detail
        // field, so bodyCamSignature is nil for a buffered body-cam hit even though the
        // method and confidence survived. Do NOT fall through to the .oui branch below,
        // which would confidently assert "shared chipset" wording that is simply wrong for
        // a vendor's own OUI block, and flatly false if the original hit was the conf-90
        // BWCDEVICE payload tag. Say what we actually still know instead.
        //
        // Gated on the row REALLY being a replay (isHistory, the wire "hist" flag), not on the
        // detail being absent (J3): a live hit with no recognized signature string (a board
        // that predates the split) is not from the buffer, and telling the owner it was
        // contradicted the LIVE header, the Active segment and the Status count on the same
        // row. That case gets its own sentence, which claims nothing about the buffer.
        // TWIN: android DetailScreen.kt's match explainer, the same two sentences under the
        // same two conditions.
        if d.type == .axonBodyCam {
            return Text(dossierBodyCamFallbackLine(isReplay: d.isHistory))
        }
        // Desert mode's ambient rows match no signature but still carry a method (SSID on WiFi),
        // so the per-method lines below would claim a match. TWIN: android DetailScreen.kt
        // plainMatchLine, the same branch in the same place.
        if d.type == .nearbyDevice { return Text(dossierNearbyDeviceLine(detail: d.detail)) }
        switch d.method {
        case .oui:
            // An OUI block is one of two very different things and the copy has to say which.
            // When `maker` resolved, the block is the MAKER'S OWN registration (Hikvision's
            // 44:19:B6, Axon's 00:25:DF), so the old "only the radio chipset matched" line was
            // flatly false, and would have contradicted a row now titled "Hikvision" on the
            // same screen. What stays open is which of that maker's products this is.
            if let m = d.maker {
                return Text("Matched \(Text(m).font(ACABTheme.font(.footnote, weight: .semibold)))'s own registered MAC block. That names the maker, not which of their products this is.")
            }
            // No maker: the block really does name a chipset vendor, which Flock shares with
            // plenty of consumer gear, so spell out how thin the evidence is.
            let isFlock = d.type == .flockCamera || d.type == .flockRaven
            let part = isFlock ? "a part Flock shares with routers and home cameras"
                               : "a part shared with routers and home cameras"
            if let vendor = d.ouiVendor {
                return Text("Only the radio chipset matched: \(Text(vendor).font(ACABTheme.font(.footnote, weight: .semibold))), \(part). The name and service IDs didn't match.")
            }
            return Text("Only the radio chipset matched, \(part). The name and service IDs didn't match.")
        case .name:        return Text("The name this device broadcasts matched a known signature.")
        case .serviceUUID: return Text("The device advertises a service UUID tied to this hardware.")
        case .mfgID:       return Text("The manufacturer ID in the advertisement matched a known signature.")
        case .ssid:        return Text("The WiFi network name matched a known signature.")
        case .probe:       return Text("The device probed for a network tied to this hardware.")
        case .remoteID:    return Text("The aircraft identified itself over Remote ID.")
        case .serviceData: return Text("A service-data tag tied to this hardware matched.")
        case .mfgSubtype:  return Text("A decoded manufacturer-data subtype matched a known signature.")
        case .watchlist:   return Text("This exact device was on your watchlist, so every sighting matched.")
        case .none:        return Text("No match method was reported for this hit.")
        }
    }

    /// Which body-cam signature fired, and how much weight it carries. The five sources
    /// under this one category range from Axon's own broadcast identifier to a vendor-block
    /// proxy, and without this they all read as "Body camera". Says nothing about the
    /// numbers: the confidence row above already carries the strength.
    private func signatureExplainer(_ sig: BodyCamSignature) -> Text {
        let name = Text(sig.rawValue).font(ACABTheme.font(.footnote, weight: .semibold))
        switch sig {
        case .axonPayload:
            return Text("Matched \(name), the tag Axon body cams broadcast about themselves. It rides in the advertisement rather than in the address, so it holds even when the device randomizes its MAC. This is the strongest body cam signature the board carries.")
        case .axonOUI:
            return Text("Matched \(name) only. The address block is Axon Enterprise's, but the broadcast body cam tag never appeared, so this is Axon-made gear of some kind. They ship other products on the same block.")
        case .utility:
            if d.method == .name {
                return Text("Matched \(name) by broadcast name. The device announced itself as part of Utility's body cam system, which is a deliberate self-identification and a solid match, though a name is easy for anything to copy.")
            }
            return Text("Matched \(name) by address block only. The block is Utility Inc's, but the broadcast name didn't match and Utility ships other gear on it, so treat this as a maybe.")
        case .motorola:
            return Text("Matched \(name), a vendor proxy rather than a body cam signature. The block is Motorola Solutions' own, so the maker is right, but they also sell two-way radios, docks, and site infrastructure on it. Read this as their equipment nearby, not a confirmed camera.")
        case .watchguard:
            return Text("Matched \(name), a vendor proxy rather than a body cam signature. The block is WatchGuard Video's own, so the maker is right, but they also put in-car video systems and docks on it. WatchGuard belongs to Motorola Solutions, so the Motorola Solutions switch controls this match. Read this as their equipment nearby, not a confirmed body cam.")
        }
    }

    // MARK: Confirm it (1d)

    /// Weak and OUI-only hits get an active checklist instead of a passive
    /// false-positive note. The two toggles are per-visit UI state and nothing persists; the
    /// star row wires to the real watch action through toggleWatch().
    private var showConfirmIt: Bool { d.method == .oui || d.confidence < 50 }

    private var confirmItPanel: some View {
        Section {
            // System toggles speak their own on/off value. The UNREAD prompt is the bright one
            // and a completed row dims, so finished items recede and the pending work stands out.
            // TWIN: android DetailScreen.kt `CheckRow`, which dims a checked row the same way.
            Toggle(isOn: $lookedAround) {
                Text(d.type.confirmPrompt)
                    .font(ACABTheme.font(.body))
                    .foregroundStyle(lookedAround ? ACABTheme.dim : ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $secondPass) {
                Text(secondPassText)
                    .font(ACABTheme.font(.body))
                    .foregroundStyle(secondPass ? ACABTheme.dim : ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            starRow
        } header: {
            Kicker("CONFIRM IT", color: ACABTheme.warn)
        }
        .tint(ACABTheme.tint)
        .listRowBackground(ACABTheme.bg2)
    }

    private var secondPassText: String {
        if let span = sightingSpan {
            return "Still here on a second pass? It's been seen \(d.count)\u{00D7} over \(span) so far."
        }
        return "Still here on a second pass? It's been seen \(d.count)\u{00D7} so far."
    }

    /// Compact duration since the first sighting: "45s", "18m", "2h", "3d".
    /// nil when the row has no instant to measure from: a bracketed or undateable buffered
    /// record has no point in time, so the "over X" clause is dropped rather than measured off
    /// its ordering key.
    private var sightingSpan: String? {
        let first = ble.firstSeenDate(for: d.id)
        guard let first, !ble.timeBasis(for: d.id, stamp: first).hidesInstant else { return nil }
        return dossierSightingSpan(since: first, now: now)
    }

    private var starRow: some View {
        let on = ble.isWatched(d.mac)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            Label {
                Text("Watch it to get pinged every time this exact device shows up.")
                    .font(ACABTheme.font(.body)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: on ? "star.fill" : "star")
                    .foregroundStyle(ACABTheme.watchTone)
            }
            Spacer(minLength: 8)
            Button {
                toggleWatch()   // shared guard: this used to star directly, skipping the confirm
            } label: {
                // Same pair as the primary watchButton below and Android's WatchChip: the action
                // verb, spoken as drawn (no label override), so the sighted label and the spoken
                // one agree. Selected while watched, as Android's WatchChip (a FilterChip) is.
                Text(on ? "Stop Watching" : "Watch")
                    .font(ACABTheme.font(.subheadline, weight: .semibold))
                    .foregroundStyle(ACABTheme.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    // MARK: Signal

    private var signalPanel: some View {
        // Sample rows read LIVE (C10); dossierSignalIsStale owns that rule and says why.
        // TWIN: android DetailScreen.kt `val stale = !demo && ble.isStale(d.id, nowMs = nowMs)`.
        let stale = dossierSignalIsStale(isDemoMode: ble.demoMode,
                                         storeIsStale: ble.isStale(for: d.id, asOf: now))
        // SAMPLE / STALE / LIVE (dossierSignalWord); `stale` alone still picks the sparkline tint.
        let word = dossierSignalWord(isDemoMode: ble.demoMode, stale: stale)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return Section {
            layout {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SignalBars(bars: d.signalBars, tint: d.type.tint).accessibilityHidden(true)
                    Text("\(d.rssi)")
                        .font(ACABTheme.telemetry(.title2, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                    Text("dBm").font(ACABTheme.telemetry(.subheadline, weight: .regular)).foregroundStyle(ACABTheme.dim)
                }
                // One element with the unit spoken, the Log row's wording (DetectionRow) and
                // android DetailScreen.kt's instrument contentDescription.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Signal strength \(d.rssi) decibels relative to one milliwatt")
                Spacer(minLength: 8)
                Text(d.source.label)
                    .font(ACABTheme.telemetry(.subheadline, weight: .regular)).foregroundStyle(ACABTheme.dim)
                Button {
                    withAnimation(reduceMotion ? nil : Animation.easeInOut(duration: 0.15)) { showRssiInfo.toggle() }
                } label: {
                    Image(systemName: "info.circle")
                        .font(ACABTheme.font(.body))
                        .foregroundStyle(ACABTheme.tint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("What the RSSI graph means")
            }
            HStack(alignment: .top, spacing: 8) {
                // The fixed scale's edge words (signalGraphFraction: -30 dBm at the top, -100 at
                // the bottom). Hidden from VoiceOver: the graph's value below says the same.
                // Capped at xxxLarge so the two words never outgrow the plot, itself capped at
                // 100pt. TWIN: android DetailScreen.kt's signal graph label column.
                VStack(alignment: .leading, spacing: 0) {
                    Text("STRONG")
                    Spacer(minLength: 0)
                    Text("WEAK")
                }
                .font(ACABTheme.telemetry(.caption2)).foregroundStyle(ACABTheme.dim)
                .tracking(ACABTheme.telemetryTracking)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
                // A stale row draws its history in dim rather than the category hue.
                Sparkline(values: trend, tint: stale ? ACABTheme.dim : d.type.tint)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Signal history")
                    .accessibilityValue("Strong at the top, weak at the bottom")
            }
            .frame(height: min(signalGraphHeight, 100))
        } header: {
            HStack {
                Kicker("SIGNAL")
                Spacer()
                Text(word)
                    .font(ACABTheme.telemetry(.footnote, weight: .semibold))
                    .tracking(ACABTheme.telemetryTracking)
                    .foregroundStyle(stale ? ACABTheme.dim : ACABTheme.text)
            }
            .textCase(nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SIGNAL · \(word)")
            .accessibilityAddTraits(.isHeader)
        } footer: {
            if showRssiInfo {
                Kicker("RSSI is signal strength, moment to moment. closer to 0 is stronger, so the line climbs as you get nearer the source and drops as you move away, use it to home in on a hit.")
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    // MARK: Stat grid

    /// The SIGHTINGS row. The name is kept: the drift rule and android's StatGrid twin pin it.
    /// The live dBm and band sit in the SIGNAL section above.
    private var statGrid: some View {
        let first = ble.firstSeenDate(for: d.id)
        let sightings = dossierSightingsText(count: d.count, firstSeen: first,
                                             basis: ble.timeBasis(for: d.id, stamp: first), now: now)
        return Section {
            GroupedRow(title: "SIGHTINGS", value: sightings)
        }
        .listRowBackground(ACABTheme.bg2)
    }

    // MARK: Identity

    /// The Technical details rows. Siblings, with no wrapping stack, so each one is its own List
    /// row inside the disclosure; the disclosure label names the group.
    @ViewBuilder
    private var identityPanel: some View {
        // TWO ROWS, NOT ONE. The old single "Vendor" row rendered a union of a real IEEE
        // registrant and a per-type constant, so it printed "Vendor: IP camera" and
        // "Vendor: Nearby device": the category restated under a label that claims an
        // identification the detector never made. Renaming it "Category" would have been
        // worse, not better, since the same row also holds "Liteon" on a genuine Falcon.
        //
        // So: Maker = who built it (payload-derived, absorbing the old Brand row), OUI
        // vendor = who owns the MAC block, annotated when that is only the radio module.
        // When neither resolves NOTHING RENDERS, which is the actual fix.
        let mk = d.maker ?? d.type.brand
        if let m = mk { idRow("Maker", m) }
        if let o = d.ouiVendor, o != mk {
            idRow("OUI vendor", isChipsetRegistrant(o) ? "\(o) \u{00B7} chipset" : o)
        }
        if let cid = d.companyIdText { idRow("Company ID", cid) }
        idRow("Identifier", d.mac, monospaced: true)
        timeRow("First seen", ble.firstSeenDate(for: d.id))
        timeRow("Last seen", ble.lastSeenDate(for: d.id), sampleReadsNow: true)
        if let n = d.name, !n.isEmpty { idRow("Name", n) }
        if let id = d.uasID, !id.isEmpty { idRow("UAS ID", id) }
        // No separate "Manufacturer" row: maker's step 2 IS ridManufacturer, so it now
        // renders as Maker above. Keeping both printed the same company twice, three rows
        // apart, under two different labels.
        //
        // The Detail row stays VERBATIM and is load-bearing, not decoration. Every hedge the
        // firmware authors wrote lives only here now that maker parses the same string:
        // " on wifi" (this is a device on the network, not necessarily a camera pointed at
        // you), "(offline)" (a separated tag, NOT buffer replay), "or Quest"
        // (glasses_signatures.h says that caveat must be present), and "gear, no Remote ID"
        // (may be a controller, not an aircraft). Do not reformat or condense it.
        if let det = d.detail, !det.isEmpty { idRow("Detail", det) }
        // Numeric lat/lon alongside the mini-map above: the coordinates are the actionable
        // datum in an evidence export, and the operator (pilot) fix is the whole point of a
        // drone detection, so show both as text, not only as a pin.
        if let c = d.coordinate { idRow("Position", String(format: "%.5f, %.5f", c.latitude, c.longitude), monospaced: true) }
        if let alt = d.altitude { idRow("Altitude", "\(alt) m") }
        if let s = d.speedH { idRow("Speed", "\(s) m/s") }
        if let vs = d.speedV, vs != 0 { idRow("Vert. speed", "\(vs) m/s") }
        if let h = d.heading { idRow("Heading", "\(h)°") }
        if let hg = d.heightAGL { idRow("Height AGL", "\(hg) m") }
        if let p = d.pilotCoordinate { idRow("Operator pos", String(format: "%.5f, %.5f", p.latitude, p.longitude), monospaced: true) }
        if let pa = d.pilotAlt { idRow("Operator alt", "\(pa) m") }
        if let st = d.ridStatusLabel { idRow("Status", st) }
        whyFlagged
    }

    /// Title and subtitle are BYTE-IDENTICAL to android DetailScreen.kt's identity
    /// DisclosureSection, and docs/app-guide.md names this control for readers of both apps.
    private var identityDisclosure: some View {
        Section {
            DisclosureGroup(isExpanded: $identityExpanded) {
                // Deferred (DeferredView in Components.swift): DisclosureGroup builds its content
                // even while collapsed, and inline this getter sat at the deepest point of the
                // dossier's Debug stack. Deferred, it is built only when the group expands.
                DeferredView { identityPanel }
            } label: {
                disclosureLabel("Technical details", systemImage: "info.circle",
                                summary: "Identifiers, capture times and broadcast fields")
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    /// The label of the two reference disclosures (Related help, Technical details). The title and
    /// its summary are ONE Label title, so the summary starts under the title text, not under the
    /// icon.
    private func disclosureLabel(_ title: String, systemImage: String, summary: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ACABTheme.font(.body, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Text(summary)
                    .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(ACABTheme.font(.body, weight: .semibold)).foregroundStyle(ACABTheme.text)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    /// One Technical details row. `monospaced` for the MAC and the coordinates, whose columns
    /// are read character by character; everything else stays in the default design.
    private func idRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        dossierRow(label, value, design: monospaced ? .monospaced : .default, selectable: true)
    }

    /// Short "ago" string for a sighting, measured to `now`, the 1 Hz tick, so an age keeps
    /// advancing while no frame arrives. The buckets live in `dossierRelativeAgo`.
    private func relativeAgo(_ date: Date?) -> String { dossierRelativeAgo(date, now: now) }

    /// A sighting time and, whenever it was not read off the phone's own clock, how it was
    /// arrived at. The qualifier sits in the row rather than in a footnote because a derived
    /// time printed on its own is read as a measured one, which is the whole failure this
    /// screen has to avoid: these records get handed over as evidence.
    /// Asked per STAMP, not per row: a device replayed from the buffer and THEN heard live has a
    /// derived First seen and a genuine Last seen, and each has to say so for itself.
    /// `sampleReadsNow` is for Last seen only: in sample data it reads "now" with no basis note
    /// (dossierLastSeenValue), so it agrees with the LIVE header. First seen keeps its real age.
    private func timeRow(_ label: String, _ date: Date?, sampleReadsNow: Bool = false) -> some View {
        let basis = ble.timeBasis(for: d.id, stamp: date)
        let sampleNow = sampleReadsNow && ble.demoMode
        return dossierRow(label,
                          sampleReadsNow
                            ? dossierLastSeenValue(isDemoMode: ble.demoMode, measured: timeValue(basis, date))
                            : timeValue(basis, date),
                          selectable: true,
                          note: sampleNow ? nil : TimeBasisCopy.note(for: basis))
    }

    /// A live stamp keeps the relative "4m ago" the rest of the screen speaks in. Anything
    /// derived switches to an absolute reading or a range, because "4m ago" quietly asserts a
    /// precision no reconstruction has.
    private func timeValue(_ basis: TimeBasis, _ date: Date?) -> String {
        if case .exact = basis { return relativeAgo(date) }
        return TimeBasisCopy.value(for: basis, stamp: date)
    }

    private var whyFlagged: some View {
        Label {
            Text(dossierFlaggedLine(type: d.type, methodLabel: d.method.label, sourceLabel: d.source.label))
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "scope").foregroundStyle(d.type.tint)
        }
    }

    // MARK: Location

    private func locationPanel(_ coord: CLLocationCoordinate2D) -> some View {
        let hasTrackerTrail = d.type == .tracker && ble.crumbTrail(for: d.id).count >= 2
        let coordText = Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
            .font(ACABTheme.telemetry(.footnote, weight: .regular))
            .foregroundStyle(ACABTheme.dim)
        return Section {
            // gpsAgeSec describes the wire coordinate on THIS row. Once a different strongest
            // sample owns the observer pin, applying this row's age to it would be false.
            if let wire = d.coordinate,
               wire.latitude == coord.latitude, wire.longitude == coord.longitude,
               let age = d.locationAgeDetail {
                // The board stamped this fix from a stale phone position (offline /
                // Desert mode), so flag how old it is.
                Label {
                    Text(age)
                        .font(ACABTheme.font(.subheadline, weight: .medium)).foregroundStyle(ACABTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(ACABTheme.warn)
                }
            }
            // CORROBORATION, positive-only. If this is an ALPR-type hit AND a community-mapped
            // camera sits within ~150m, say so - a live detection landing on an independently
            // mapped node is strong confirmation, and names the mapped maker when known.
            // We NEVER show a "no mapped camera" line: OSM lags new installs and mobile cruiser
            // ALPR is meant to move, so absence is not evidence of a false positive (the confidence
            // row is the false-positive tell). Only shows when the ALPR layer is loaded.
            // Read from the cache, never from the store: see alprMatch.
            // The words take accentText, never flockTone: the ALPR hue is a fill, not a text
            // colour on bg2. The seal glyph keeps the hue.
            if (d.type == .flockCamera || d.type == .flockRaven),
               let hit = alprMatch, hit.meters <= 150 {
                Label {
                    // This line is the app VOUCHING for a detection using the mapped maker as
                    // corroboration, so it must not spend the maker's credibility on a maker
                    // nobody verified. An unverified node still corroborates the LOCATION (someone
                    // mapped a camera here) but not the NAME, so it drops the maker from the
                    // sentence rather than repeating a guess back at the user as evidence.
                    Text(hit.confirmed
                         ? (hit.maker.isEmpty
                            ? "matches a mapped camera · \(Int(hit.meters.rounded())) m"
                            : "matches a mapped \(hit.maker) camera · \(Int(hit.meters.rounded())) m")
                         : "near a community-mapped camera · \(Int(hit.meters.rounded())) m")
                        .font(ACABTheme.font(.subheadline, weight: .medium))
                        .foregroundStyle(hit.confirmed ? ACABTheme.accentText : ACABTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(hit.confirmed ? ACABTheme.flockTone : ACABTheme.warn)
                }
                // Must mirror the VISIBLE claim exactly. This branched on maker alone, so
                // VoiceOver spoke "matches a mapped Motorola camera" for a node the sighted user
                // is deliberately told is only "near a community-mapped camera" - the screen
                // reader was making the stronger claim the visible copy refuses to make.
                .accessibilityLabel(!hit.confirmed
                     ? (hit.tier == 2
                        ? "near a legacy-tag community camera candidate, about \(Int(hit.meters.rounded())) meters away"
                        : "near a canonical community-mapped camera, about \(Int(hit.meters.rounded())) meters away, manufacturer attribution not structured")
                     : (hit.maker.isEmpty
                        ? "matches a mapped camera about \(Int(hit.meters.rounded())) meters away"
                        : "matches a mapped \(hit.maker) camera about \(Int(hit.meters.rounded())) meters away"))
            }
            VStack(alignment: .leading, spacing: 8) {
                // The whole thumbnail is one tap target: close the dossier and hand the full
                // Map tab a one-shot close-in focus on this coordinate (see MapFocus). The
                // pill is just discoverability; the thumbnail itself stays static. In the
                // board-less saved-log sheet no Map tab is mounted to receive the handoff, so
                // the affordance is suppressed there: a plain thumbnail, no button, no pill.
                if mapHandoffAvailable {
                    Button { openInMap(coord) } label: {
                        mapThumbnail(coord)
                            .overlay(alignment: .topTrailing) { openInMapPill }
                            .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hasTrackerTrail
                                        ? "Open in Map. Phone breadcrumb trail, this session."
                                        : "Open in Map")
                } else {
                    mapThumbnail(coord)
                        .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                }
                if hasTrackerTrail {
                    Label("Phone breadcrumb trail · this session",
                          systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(ACABTheme.font(.footnote))
                        .foregroundStyle(ACABTheme.dim)
                        .accessibilityLabel("Phone breadcrumb trail, this session only")
                }
                // The thumbnail draws the operator marker exactly when pilotCoordinate is
                // non-nil (mapThumbnail), so the caption shares that gate. TWIN: android
                // DetailScreen.kt LocationPanel's DRONE_OPERATOR_CAPTION row.
                if d.type == .drone, d.pilotCoordinate != nil {
                    Label(droneOperatorCaption, systemImage: "person.fill")
                        .font(ACABTheme.font(.footnote))
                        .foregroundStyle(ACABTheme.dim)
                }
            }
        } header: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { Kicker("LOCATION"); Spacer(minLength: 8); coordText }
                VStack(alignment: .leading, spacing: 2) { Kicker("LOCATION"); coordText }
            }
            .textCase(nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .listRowBackground(ACABTheme.bg2)
    }

    /// The static mini-map itself, shared by both presentations of the panel above.
    private func mapThumbnail(_ coord: CLLocationCoordinate2D) -> some View {
        let crumbs = d.type == .tracker ? ble.crumbTrail(for: d.id) : []
        return Map(position: $thumbnailCamera) {
            // The same accumulated, session-only phone trail the full Map draws for a tracker.
            // It is intentionally independent of the Map tab's display toggle: this dossier is
            // the evidence view the user explicitly opened for this one row.
            if crumbs.count >= 2 {
                MapPolyline(coordinates: crumbs)
                    .stroke(ACABTheme.trackerTone.opacity(0.85),
                            style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
            Annotation(d.type.shortTag, coordinate: coord) { miniPin }
            if let pilot = d.pilotCoordinate {
                Marker("Operator", systemImage: "person.fill", coordinate: pilot).tint(ACABTheme.dim)
            }
        }
        // The map's identity carries NO pin. The pin moves whenever a strictly stronger packet
        // arrives with a new phone fix, and a Remote ID aircraft's pin moves with every position
        // it broadcasts, so on an approach it moves again and again while this dossier is open.
        // Keyed on the pin, each of those moves built a fresh MKMapView and fetched its tiles
        // again. A crumb landing or the trail dropping still rebuilds: that cost is bounded
        // (tracker rows only, and crumbs land at least 60 s apart), and it draws the trail on a
        // fresh map, so this evidence view never depends on an overlay being swapped in place.
        // Selecting a different row in the iPad two-pane rebuilds too.
        .id(ThumbnailMapKey(detectionID: d.id, trail: CrumbTrailStamp(crumbs)))
        // A pin move keeps the map: the annotation above moves in place, as the operator marker
        // always has, and this re-fits the camera to the new pin, the same thing android
        // DetailScreen.kt LocationPanel's `update` block does to its retained MapView (re-center,
        // or re-fit a trail). It sits outside the `.id` on purpose, so a rebuild never resets what
        // it compares against and a crumb change re-fits the rebuilt map as well. The region is
        // computed only here, when the key changes, never in the body pass, so the trail sort
        // stays off the render path.
        //
        // What this key does not see: the operator coordinate, which was never part of the fit
        // (its marker still moves), and a trail edit that keeps both its count and its last crumb
        // (see CrumbTrailStamp). Neither can strand the pin: the pin is in the key, so the camera
        // always frames the final pin, and the annotation is re-declared on every pass, so the
        // final pin always renders.
        .onChange(of: ThumbnailFit(pin: coord, trail: crumbs), initial: true) { _, fit in
            thumbnailCamera = .region(detectionDetailMapRegion(pin: fit.pin, trail: fit.trail))
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .preferredColorScheme(.dark)
        .frame(height: 168)
        .allowsHitTesting(false)   // just a thumbnail; never pans, any wrapping button takes the tap
    }

    /// Identity of the thumbnail's Map. No pin, on purpose: see mapThumbnail.
    private struct ThumbnailMapKey: Hashable {
        let detectionID: String
        let trail: CrumbTrailStamp
    }

    /// What the thumbnail camera is fitted to. Equality reads the pin and the trail's stamp, not
    /// every crumb, so the comparison made on each body pass stays O(1). `trail` rides along so
    /// the fit uses the trail from the pass that changed rather than one captured earlier.
    private struct ThumbnailFit: Equatable {
        let pin: CLLocationCoordinate2D
        let trail: [CLLocationCoordinate2D]

        static func == (a: ThumbnailFit, b: ThumbnailFit) -> Bool {
            a.pin.latitude == b.pin.latitude && a.pin.longitude == b.pin.longitude
                && CrumbTrailStamp(a.trail) == CrumbTrailStamp(b.trail)
        }
    }

    /// Stands in for a whole crumb trail in both keys above. BLEManager's crumb writer appends a
    /// crumb at least 25 m from the previous one, trims the oldest past 120, or drops the whole
    /// trail, so an append always moves the count or the last crumb and a drop always moves the
    /// count. The one edit this cannot see is a trail dropped and rebuilt to the same count, ending
    /// on a bit-identical coordinate; for the two or more crumbs the thumbnail draws, that needs
    /// at least a minute of crumbs and the phone reporting the exact same fix again.
    private struct CrumbTrailStamp: Hashable {
        let count: Int
        let lastLat: Double?
        let lastLon: Double?

        init(_ trail: [CLLocationCoordinate2D]) {
            count = trail.count
            lastLat = trail.last?.latitude
            lastLon = trail.last?.longitude
        }
    }

    /// Corner chip on the map thumbnail so the tap is discoverable. An opaque bg2 capsule, so the
    /// tint text sits on a measured text surface whatever the tile shows; no material, no
    /// border (L1).
    private var openInMapPill: some View {
        Text("Open in Map")
            .font(ACABTheme.font(.caption, weight: .semibold))
            .foregroundStyle(ACABTheme.tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(ACABTheme.bg2, in: Capsule())
            .padding(8)
    }

    /// Close this dossier and hand the full Map tab a one-shot focus on the captured
    /// coordinate. Same notification channel the Live Activity deep link rides for tab
    /// switching; the coordinate sits in a static slot so a cold Map tab picks it up on
    /// first appear and a warm one flies immediately.
    private func openInMap(_ coord: CLLocationCoordinate2D) {
        MapFocus.pending = coord
        NotificationCenter.default.post(name: MapFocus.notification, object: nil)
        // Sheets and pushes close here. The embedded two-pane has no dismissal and
        // needs none: switching to the Map tab is itself the close.
        dismiss()
    }

    // MARK: Seen with you
    //
    // The one place in the app that answers "has this thing been with me", and it answers with
    // evidence rather than a verdict. It is silent by design: no notification, no haptic, no
    // buzzer, no list badge, no map change. The panel's own sentences name the innocent
    // explanations in the same breath as the numbers, because no threshold can separate a stalker
    // from a fellow commuter carrying a Tile, and a product that over-claims here spends the trust
    // every other alert depends on.

    /// Re-score from the manager's current state. Takes a VALUE COPY of the crumb list first, so
    /// the O(n^2) diameter sweep never runs while anything else could be mutating the store.
    private func refreshFollow() {
        // Only trackers accumulate crumbs, so only trackers can be scored. Everything else gets no
        // panel at all rather than an empty one, which would imply it had been checked. The state
        // still goes to .notMeasured rather than a none score, matching what the scorer itself
        // returns for a non-tracker: if the panel's own type gate above is ever widened, it must
        // widen onto "we did not look" and not onto "we looked and found nothing".
        guard d.type == .tracker else { followState = .notMeasured; return }
        let crumbs = ble.crumbTrail(for: d.id)
        // No crumbs at all needs an explanation, not a blank. Demo mode is the exception: it seeds
        // the store directly and never runs the live path, so a demo tracker legitimately has zero
        // crumbs and must sit at band none. Printing "there was no usable position" over sample
        // data would teach the user to read a tour as a measurement.
        if crumbs.isEmpty, !ble.demoMode {
            followState = ble.locationAuthorized ? .noFix : .noLocation
            return
        }
        // firstCrumbAt, NOT firstSeenDate: the row survives a restart and the crumbs do not, so
        // the first-HEARD stamp would open a window the trail never covered.
        let s = FollowEvidence.score(crumbs: crumbs,
                                     firstCrumbAt: ble.firstCrumbAt(for: d.id),
                                     lastCrumbAt: ble.lastCrumbAt(for: d.id),
                                     basis: ble.timeBasis(for: d.id),
                                     type: d.type)
        // Split the refusal out here, once, so every reader below is either a real finding or an
        // explicit "we did not look". Collapsing them is what let the panel report a comparison it
        // had declined to run.
        followState = (s.band == .notMeasured) ? .notMeasured : .scored(s)
    }

    /// Re-read the nearest mapped ALPR node for this sighting. Only the two types whose panel can
    /// show the corroboration line pay the scan at all; everything else clears the cache, so a
    /// swapped-in row on the iPad two-pane can never inherit the previous row's answer. Assigned
    /// only when the answer actually changed, so a tick that finds the same node (the usual case)
    /// costs nothing downstream.
    private func refreshALPRMatch() {
        guard d.type == .flockCamera || d.type == .flockRaven,
              let coord = mapCoordinate else {
            if alprMatch != nil { alprMatch = nil }
            return
        }
        let next = ALPRStore.shared.nearest(to: coord).map {
            ALPRMatch(meters: $0.meters, maker: $0.maker, tier: $0.tier, confirmed: $0.confirmed)
        }
        if next != alprMatch { alprMatch = next }
    }

    @ViewBuilder private var followPanel: some View {
        if d.type == .tracker {
            let copy = dossierFollowCopy(followState)
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = copy.label {
                        // Plain body text, never routed through Kicker: the label is copy, not a
                        // header, and any casing step is one more thing that can silently drift
                        // away from Android.
                        Text(label)
                            .font(ACABTheme.font(.body, weight: .semibold))
                            .foregroundStyle(ACABTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(copy.sentence)
                        .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                // The kicker appears ONLY when a band fires. Over the none state it would be a
                // header asserting something the body immediately walks back.
                if copy.label != nil { Kicker(FollowEvidence.kicker) }
            } footer: {
                // EVERY state, not just the ones where a band fired. The states that say nothing
                // are precisely where the user has to be told the memory is session-scoped: after
                // a restart the crumbs are gone and the row is not, and without this line the
                // panel's silence reads as a result. Crumbs are session-only and never persisted,
                // and they exist for trackers alone. Both facts ride on every state of this panel,
                // so it can never imply a longer memory or a wider scope than the app actually has.
                Kicker(FollowEvidence.scopeLine)
            }
            .listRowBackground(ACABTheme.bg2)
        }
    }

    private var miniPin: some View {
        ZStack {
            Circle().fill(d.type.tint).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(ACABTheme.text, lineWidth: 2))
            Image(systemName: d.type.symbol)
                .font(ACABTheme.fixed(10, weight: .bold))   // pin geometry: fixed size on purpose
                .foregroundStyle(ACABTheme.onAccent)
        }
    }

    // MARK: Action

    /// Always visible, below the Technical details disclosure and never inside it: an address is
    /// what someone hands to a reporter or a records request, so it cannot sit behind a collapsed
    /// section. TWIN: android DetailScreen.kt calls CopyMacButton in this same position. Copied
    /// reverts to Copy MAC Address after 1.5 s, the same delay as CopyMacButton's LaunchedEffect,
    /// so the label never outlives the 60 s pasteboard item it describes.
    private var copyButton: some View {
        Section {
            Button {
                // localOnly keeps the MAC off Universal Clipboard (no sync to other devices) and the
                // 60s expiry auto-clears it, so a copied surveillance-gear MAC doesn't linger on the
                // pasteboard or leak to a paired Mac/iPad.
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: d.mac]],
                                              options: [.localOnly: true,
                                                        .expirationDate: Date().addingTimeInterval(60)])
                withAnimation(reduceMotion ? nil : Animation.default) { copied = true }
            } label: {
                Label(copied ? "Copied" : "Copy MAC Address",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(ACABTheme.font(.body, weight: .semibold))
                    .foregroundStyle(ACABTheme.tint)
                    .frame(maxWidth: .infinity)
            }
            // Restarted on every change of `copied`: a row swap (which resets it) or the revert
            // itself cancels the pending wait, and a cancelled wait writes nothing.
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Animation.default) { copied = false }
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    /// The ONE place star/unstar is decided, so every entry point gets the same guard. There are
    /// two call sites (starRow in CONFIRM IT and watchButton in the action row) and starRow used
    /// to call ble.watchDevice(d) directly, skipping the confirm entirely. That bypass fired on
    /// exactly the rows most likely to rotate: Desert nearby-device rows are confidence 0, so they
    /// always show the ConfirmIt panel that hosts starRow. Android already funnelled both sites
    /// through one closure; this brings iOS to parity.
    private func toggleWatch() {
        if ble.isWatched(d.mac) { ble.unwatch(d.mac); return }
        if d.addressIsRandomized { confirmRandomWatch = true; return }   // ask first, mirror Android
        ble.watchDevice(d)
    }

    /// Body copy for the star confirm, selected by type so the user gets the ONE fact that applies
    /// to what they tapped. Order matters: tracker first, then Desert nearby-device, then the
    /// generic randomized case, so exactly one message is chosen.
    private var watchWarningBody: String {
        switch d.type {
        case .tracker:
            // A SEPARATED tag holds its address ~24h (IETF DULT requires it, so that unwanted-
            // tracking detectors can accumulate evidence), rolling around 4am. So the star DOES
            // work, just not past the rollover. Do not repeat the "every few minutes" line here,
            // that is the near-owner interval and it is wrong for the tags that matter.
            return "This tag's address holds for about a day, then changes around 4am. The watchlist entry stops matching when it does. The tracker detector finds it either way."
        case .nearbyDevice:
            return "Most phones change their address every few minutes, so the watchlist entry will likely stop matching within the hour."
        default:
            // No "trackers" here: .tracker is handled above, and a separated tag rotates about
            // once a day, not every few minutes. Repeating the near-owner interval in the fallback
            // would put the debunked claim straight back in front of the user.
            return "This address looks randomized, so the watchlist entry may stop matching this device."
        }
    }

    /// Star / un-star this exact MAC. Watching and ignoring are exclusive, so starring a
    /// currently-ignored device silently un-mutes it (handled in BLEManager.watchDevice). The
    /// rotating-address confirm hangs off the List (see body), so it presents from either entry
    /// point.
    private var watchButton: some View {
        let on = ble.isWatched(d.mac)
        return Button {
            toggleWatch()
        } label: {
            // "Watch" / "Stop Watching": the action verb, not a state word. VoiceOver reads it
            // as drawn (no label override), so the sighted label and the spoken one say the same
            // thing. TWIN: android DetailScreen.kt `WatchButton`, same pair, byte for byte, which
            // TalkBack reads as drawn too. iOS adds the selected trait while watched, as Mute does.
            actionLabel(on ? "Stop Watching" : "Watch", systemImage: on ? "star.fill" : "star", on: on)
        }
        // .plain, never the automatic style: actionLabel draws the key, and the automatic style
        // would restyle it (and in a List row it fires both keys on one tap).
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Mute… opens the scope dialog; with a rule in place the same key reads Unmute and clears
    /// it in one tap. The rule's state and Change sit in `mutedStateSection` under the row.
    private var ignoreButton: some View {
        let muted = muteRule != nil
        return Button {
            if muted { ble.unignore(d.mac) } else { showMuteOptions = true }
        } label: {
            actionLabel(muted ? "Unmute" : "Mute…", systemImage: muted ? "bell.slash.fill" : "bell.slash",
                        on: muted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(muted ? .isSelected : [])
    }

    private func mutedStateSection(_ rule: IgnoredDevice) -> some View {
        // Evaluated fresh at render time, never via the 60 s-cached isIgnored set, so
        // the headline and the detail line always describe the same instant - matching
        // Android's DetailScreen, which feeds MutedStateRows from ble.muteRuleStatus.
        let status = ble.muteRuleStatus(for: rule)
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(muteHeadline(for: rule, status: status))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "bell.slash.fill")
                }
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(status == .active ? ACABTheme.tint : ACABTheme.warn)
                if let detail = muteStatusDetail(for: status) {
                    Text(detail)
                        .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Button { showMuteOptions = true } label: {
                Text("Change")
                    .font(ACABTheme.font(.body)).foregroundStyle(ACABTheme.tint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
        }
        .listRowBackground(ACABTheme.bg2)
    }

    /// The mute dialog's scope buttons, hoisted onto the List with the dialog itself (see body).
    @ViewBuilder
    private var muteOptionButtons: some View {
        Button("Permanently") { applyMute(.permanent) }
        Button("For 1 Hour") { applyMute(.oneHour) }
        Button("For 24 Hours") { applyMute(.oneDay) }
        if ble.currentLocationCoord != nil {
            Button("At This Place (50 m)") { applyMute(.here) }
        } else if !canAcquireFreshLocation {
            Button("Connect Your Beacon for a Current Location") {}
                .disabled(true)
        } else if ble.locationRestricted {
            Button("Location Restricted by Device Policy") {}
                .disabled(true)
        } else if ble.locationDenied {
            Button("Open Settings for a Place Mute", action: openAppSettings)
        } else if !ble.locationAuthorized && !ble.locationDenied {
            Button("Enable Location for a Place Mute") {
                ble.requestLocationForPlaceMute()
            }
        } else {
            Button("Get a More Accurate Location") {
                ble.requestLocationForPlaceMute()
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    /// Android-parity headline (MutedStateRows in DetailScreen.kt): only an ACTIVE rule may say
    /// MUTED; every other status presents the rule as set-but-not-suppressing.
    private func muteHeadline(for rule: IgnoredDevice, status: MuteRuleStatus) -> String {
        switch status {
        case .active: return "MUTED · \(rule.scopeLabel.uppercased())"
        case .currentLocationRequired: return "MUTE SET · ACCURATE LOCATION NEEDED"
        case .outsideRadius: return "MUTE SET · OUTSIDE SAVED AREA"
        case .expired: return "MUTE ENDED"
        case .invalidPlace: return "MUTE SET · PLACE UNAVAILABLE"
        }
    }

    private func muteStatusDetail(for status: MuteRuleStatus) -> String? {
        switch status {
        case .active:
            return nil
        case .currentLocationRequired:
            return "This place mute is saved but inactive because a fresh location accurate to 50 meters is unavailable."
        case .outsideRadius:
            return "This place mute is configured but inactive outside its saved radius."
        case .expired:
            return "This timed mute is no longer active."
        case .invalidPlace:
            return "This saved place rule is incomplete and is not muting the device."
        }
    }

    private var muteExplanation: String {
        let base = "Existing log history is kept. Permanent mutes silence the app and beacon. Timed and place mutes are enforced by this phone, so the beacon can still sound."
        guard d.addressIsRandomized else { return base }
        return base + " This device uses a rotating address, so the mute may stop matching after the address changes."
    }

    private func applyMute(_ scope: MuteScope) {
        if ble.ignoreDevice(d, scope: scope) {
            muteError = nil
            showMuteOptions = false
        } else if scope == .here && ble.currentLocationCoord == nil {
            muteError = "A fresh location fix accurate to 50 meters is required for a place mute. Keep the beacon connected and try again."
        } else {
            muteError = "The muted-device list is full. Unmute another device and try again."
        }
    }
}
