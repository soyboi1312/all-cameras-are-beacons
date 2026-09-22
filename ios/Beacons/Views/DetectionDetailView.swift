import SwiftUI
import Combine   // Timer.publish(...).autoconnect(): Xcode 27 warns when the file relies on SwiftUI's re-export
import MapKit
import UIKit
import UniformTypeIdentifiers   // UTType for the localOnly/expiring pasteboard item

/// Whether a full Map tab exists to receive the dossier's OPEN IN MAP handoff. ConnectView's
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
private enum FollowPanelState: Equatable {
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

/// Full detection detail, pushed from the dashboard and logbook, shown as a sheet
/// from the map. Custom top bar, a live RSSI signal panel, stat grid, identity, and
/// location.
struct DetectionDetailView: View {
    let detection: Detection
    /// True when hosted persistently in a two-pane (T3 iPad Log). Then we must NOT hide the
    /// tab bar (that would trap the user in the Log tab) and the back chevron is meaningless.
    var embedded: Bool = false
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mapHandoffAvailable) private var mapHandoffAvailable
    @ScaledMetric(relativeTo: .caption) private var signalGraphHeight: CGFloat = 46
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
    /// kicker and the sparkline dim, First seen and Last seen, the SIGHTINGS age, and CONFIRM IT's
    /// "over 2m". Staleness moves with the clock, not with @Published state, so once this device
    /// stops being heard and nothing else publishes, nothing invalidates the view: the kicker held
    /// SIGNAL · LIVE and Last seen held its last age indefinitely, at exactly the moment someone
    /// checks whether a device really went quiet. followTick cannot stand in for it, because its
    /// refreshes assign Equatable state that is unchanged in the usual case, and SwiftUI skips those.
    /// 1 s, and held in @State for the same reason as DashboardView's `staleTick`. TWIN: Android
    /// DetailScreen `nowMs` drives the same readings at the same cadence. Every clock reading below
    /// measures against `now` instead of calling Date(), so the body keeps a real dependency on it.
    /// The Technical details rows are built during this body pass, so they move only when it re-runs.
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
    /// LIVE/STALE kicker, the sparkline). A frozen copy means the dBm readout never moves
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
        ZStack(alignment: .top) {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // THE CANONICAL DOSSIER ORDER. android DetailScreen.kt's dossier Column runs
                    // the same panels in the same SEQUENCE, so an instruction that names a panel
                    // ("expand Technical details", "tap COPY MAC ADDRESS") is true on both phones.
                    // Sequence, NOT cell for cell: the two primary actions are one child here in
                    // either layout (watch beside mute, stacked only for an existing mute rule or
                    // accessibility text), and two full-width children on android, so every panel
                    // below sits one child later there. Moving one of those actions is a two-file
                    // edit for that reason. Until this was settled, android carried a CAPTURE NOTE
                    // panel of its own, ran CONFIRM IT above the map, and kept COPY MAC ADDRESS
                    // inside the collapsed disclosure. Keep the two in step when either one moves.
                    titleBlock
                    primaryActions
                    matchQualityPanel
                    if d.type.isExperimental { experimentalNote }
                    relatedHelpPanel
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
                    signalPanel
                    statGrid
                    if showConfirmIt { confirmItPanel }
                    identityDisclosure
                    copyButton
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 58)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            topBar
        }
        .navigationBarHidden(true)
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
        // The iPad two-pane keeps ONE detail view mounted and swaps the row into it, so without
        // this the panel would keep showing the previously selected tag's score.
        .onChange(of: d.id) {
            identityExpanded = false; helpExpanded = false
            refreshFollow(); refreshALPRMatch()
        }
        .onReceive(followTick) { _ in refreshFollow(); refreshALPRMatch() }
        .onReceive(staleTick) { now = $0 }
        // A star refused at the firmware's 256-entry cap sets this on the manager; surface it here
        // instead of the WATCH tap silently doing nothing.
        .alert("Watchlist full", isPresented: $ble.watchlistFull) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can watch up to 256 devices at once. Un-watch one before adding another.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if embedded {
                Color.clear.frame(width: 44, height: 44)   // no back button in the two-pane
            } else {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                        .frame(width: 36, height: 36)
                        .background(ACABTheme.bg2, in: Circle())
                        .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Spacer()
            Kicker("DETECTION")
            Spacer()
            Color.clear.frame(width: 44, height: 44)   // invisible right item to keep the title centered
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 8).padding(.bottom, 10)
        .background(
            LinearGradient(colors: [ACABTheme.bg, ACABTheme.bg.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: Title

    /// The two common decisions are available before the technical dossier. An existing mute
    /// has an explanatory state panel, so it keeps a full row; large text also stacks the actions.
    private var primaryActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize || muteRule != nil
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            watchButton
            ignoreButton
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            CatGlyph(type: d.type, size: 54, filled: true)
            VStack(alignment: .leading, spacing: 7) {
                badgePill
                // The headline is the same user/device name the Log row and the Status hero
                // lead with (custom label, else advertised name, else UAS serial, else maker,
                // else the class); the node handle moves into the subtitle. TWIN: android
                // DetailScreen.kt title block - `Text(d.displayName, 26.sp)` over
                // `"NODE ${nodeName(d.mac)} · ${d.maker ?: d.vendor}"`, one dossier header on
                // both phones.
                Text(d.displayName)
                    .font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                // Subtitle is the node handle and the vendor, not the type label (F15), the
                // badge pill above already names the category. NEITHER branch may consult
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
                // Flock, so the ALPR case above is unaffected.
                Text("NODE \(d.nodeName) · \(d.maker ?? d.vendor)")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            Spacer(minLength: 0)
        }
    }

    private var badgePill: some View {
        HStack(spacing: 5) {
            Text(d.type.inlineCategory)
            Text("\u{00B7}").opacity(0.5)
            Text(d.classLabel)
        }
        .font(ACABTheme.mono(9.5, weight: .bold)).tracking(1)
        .foregroundStyle(d.type.textTint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(d.type.tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(d.type.tint.opacity(0.35), lineWidth: 1))
    }

    private var experimentalNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ACABTheme.warn).font(.system(size: 12))
            Text("Experimental detector. \(d.type.experimentalNoun) signatures are not field-verified yet, so treat this as a maybe.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.warn)
        }
        .panel(strong: false, padding: 13)
    }

    // MARK: Match quality (1d / F12)

    /// Low certainty is loud amber, high certainty is calm white. Crimson is for
    /// categories only, never for confidence.
    private var isWeakMatch: Bool { d.confidence < 50 }

    /// RELATED HELP: the FAQ answers that speak to THIS category, deep-linked.
    ///
    /// Collapsed, but placed where the doubt lands: directly under match quality and the
    /// category's own experimental note. Someone looking at a 45% body cam hit, or an ALPR pin
    /// with nothing detected, is already asking a question, and the answer was previously only on
    /// the website. A reporter using the device hit exactly that and concluded the hardware was
    /// broken. It is collapsed so a second block of prose does not stack under that warning and
    /// read as a second hedge, but the header stays on the FIRST screen. Do not demote it again:
    /// this panel is the only route from a dossier into HelpView, the top bar carries no help
    /// control, and a collapsed row further down the scroll is reachable only by someone who
    /// already knows to look. That is not the reader it exists for.
    ///
    /// Renders nothing for categories with no mapped questions (nearby device and unknown, whose
    /// faqKey is ""). Every real category has entries, and the drift check enforces that.
    @ViewBuilder
    private var relatedHelpPanel: some View {
        let qs = FAQContent.shared.related(for: d.type)
        if !qs.isEmpty {
            DisclosureGroup(isExpanded: $helpExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(qs.enumerated()), id: \.element.id) { idx, q in
                        NavigationLink {
                            HelpView(
                                scrollToId: q.id,
                                canImproveDetection: improveDetectionAvailable(
                                    isSessionReady: ble.sessionReady,
                                    isDemoMode: ble.demoMode))
                        } label: {
                            HStack(spacing: 10) {
                                Text(q.q)
                                    .font(ACABTheme.display(13.5, weight: .medium))
                                    .foregroundStyle(ACABTheme.text)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ACABTheme.faint)
                            }
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if idx < qs.count - 1 {
                            Rectangle().fill(ACABTheme.line).frame(height: 1)
                        }
                    }
                }
            } label: {
                // Same anatomy as identityDisclosure below, and the summary is BYTE-IDENTICAL to
                // android DetailScreen.kt's RelatedHelpPanel `summary`. Collapsed content leaves
                // the accessibility tree entirely, so without this line VoiceOver reached a
                // control that named nothing about what it holds while Technical details, sitting
                // right under it, said what was inside.
                VStack(alignment: .leading, spacing: 3) {
                    Label("Related help", systemImage: "questionmark.circle")
                        .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    Text("\(qs.count) answer\(qs.count == 1 ? "" : "s") for \(d.type.inlineLabel)")
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 44)
            }
            .tint(ACABTheme.dim)
            .panel()
        }
    }

    private var matchQualityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Kicker("MATCH QUALITY")
                Spacer(minLength: 8)
                methodChip
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verdictText)
                    .font(ACABTheme.display(22, weight: .bold))
                    .foregroundStyle(verdictColor)
                Text("\(d.confidence)%")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            matchMeter
            matchExplainer
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            // Keep the broadcast's qualifications visible when technical identity is collapsed:
            // strings such as "or Quest" / "gear, no Remote ID" must never turn into certainty.
            // TWIN: android DetailScreen.kt's MatchQualityPanel closes with the same string in
            // this same slot, verbatim and with no kicker of its own.
            if let detail = d.detail, !detail.isEmpty {
                Text(detail)
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(isWeakMatch ? ACABTheme.warn.opacity(0.4) : ACABTheme.line, lineWidth: 1))
    }

    private var verdictText: String {
        switch d.confidence {
        case ..<50: return "Weak match, verify"
        case ..<80: return "Partial match"
        default:    return "Strong match"
        }
    }

    private var verdictColor: Color {
        switch d.confidence {
        case ..<50: return ACABTheme.warn
        case ..<80: return ACABTheme.dim
        default:    return ACABTheme.text
        }
    }

    /// How the signature hit: OUI-only gets the loud amber "chipset only" treatment,
    /// everything else a neutral chip.
    private var methodChip: some View {
        let oui = d.method == .oui
        return Text(methodChipLabel)
            .font(ACABTheme.mono(9, weight: .bold)).tracking(1)
            .foregroundStyle(oui ? ACABTheme.warn : ACABTheme.dim)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(oui ? ACABTheme.warn.opacity(0.14) : ACABTheme.bg3,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(oui ? ACABTheme.warn.opacity(0.4) : ACABTheme.line, lineWidth: 1))
    }

    private var methodChipLabel: String {
        switch d.method {
        // Some OUI hits land on the maker's OWN registered block (Axon, Utility, Motorola
        // Solutions, and every camera brand in netcam_signatures.h), not a chipset shared
        // with unrelated gear, so "chipset only" would understate what we know. What's
        // uncertain is which of the vendor's products this is, which is why it keeps the
        // amber weak-match treatment. Keyed on `maker` rather than bodyCamSignature so
        // network cameras stop sitting on the wrong side of this exact distinction.
        case .oui where d.maker != nil: return "OUI \u{00B7} VENDOR ONLY"
        case .oui:  return "OUI \u{00B7} CHIPSET ONLY"
        case .name: return "NAME MATCH"
        default:    return d.method.label.lowercased()   // "service UUID", "SSID", ...
        }
    }

    /// 5-segment certainty meter: filled = round(confidence / 20).
    private var matchMeter: some View {
        let filled = Int((Double(d.confidence) / 20).rounded())
        let tone = isWeakMatch ? ACABTheme.warn : ACABTheme.text
        return HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i < filled ? tone : ACABTheme.bg3)
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Plain-language line under the meter: what actually matched, in words.
    /// Returns Text so the OUI vendor name can render semibold inside the dim line.
    private var matchExplainer: Text {
        // Body cam covers four signatures of very different weight under one label, so the
        // generic per-method line is too vague here (and its "shared chipset" wording is
        // wrong for a vendor's own OUI block). Name the signature that fired instead.
        if let sig = d.bodyCamSignature { return signatureExplainer(sig) }
        // Replayed from the offline buffer: StoredDet (firmware det_log.h) has no detail
        // field, so bodyCamSignature is nil for a buffered body-cam hit even though the
        // method and confidence survived. Do NOT fall through to the .oui branch below,
        // which would confidently assert "shared chipset" wording that is simply wrong for
        // a vendor's own OUI block, and flatly false if the original hit was the conf-90
        // BWCDEVICE payload tag. Say what we actually still know instead.
        if d.type == .axonBodyCam {
            return Text("Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired.")
        }
        switch d.method {
        case .oui:
            // An OUI block is one of two very different things and the copy has to say which.
            // When `maker` resolved, the block is the MAKER'S OWN registration (Hikvision's
            // 44:19:B6, Axon's 00:25:DF), so the old "only the radio chipset matched" line was
            // flatly false, and would have contradicted a row now titled "Hikvision" on the
            // same screen. What stays open is which of that maker's products this is.
            if let m = d.maker {
                return Text("Matched \(Text(m).font(ACABTheme.mono(11, weight: .semibold)))'s own registered MAC block. That names the maker, not which of their products this is.")
            }
            // No maker: the block really does name a chipset vendor, which Flock shares with
            // plenty of consumer gear, so spell out how thin the evidence is.
            let isFlock = d.type == .flockCamera || d.type == .flockRaven
            let part = isFlock ? "a part Flock shares with routers and home cameras"
                               : "a part shared with routers and home cameras"
            if let vendor = d.ouiVendor {
                return Text("Only the radio chipset matched: \(Text(vendor).font(ACABTheme.mono(11, weight: .semibold))), \(part). The name and service IDs didn't match.")
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
        case .watchlist:   return Text("You starred this exact device, so every sighting matches.")
        case .none:        return Text("No match method was reported for this hit.")
        }
    }

    /// Which body-cam signature fired, and how much weight it carries. The four sources
    /// under this one category range from Axon's own broadcast identifier to a vendor-block
    /// proxy, and without this they all read as "Body camera". Says nothing about the
    /// numbers: the verdict, meter, and percentage above already carry the strength.
    private func signatureExplainer(_ sig: BodyCamSignature) -> Text {
        let name = Text(sig.rawValue).font(ACABTheme.mono(11, weight: .semibold))
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
        }
    }

    // MARK: Confirm it (1d)

    /// Weak and OUI-only hits get an active checklist instead of a passive
    /// false-positive note. Checkboxes are local UI state; the star row wires to the
    /// real watch action.
    private var showConfirmIt: Bool { d.method == .oui || d.confidence < 50 }

    private var confirmItPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker("CONFIRM IT", color: ACABTheme.warn).padding(.bottom, 6)
            checkRow(isOn: $lookedAround,
                     text: d.type.confirmPrompt)
            Rectangle().fill(ACABTheme.line).frame(height: 1)
            checkRow(isOn: $secondPass, text: secondPassText)
            Rectangle().fill(ACABTheme.line).frame(height: 1)
            starRow
        }
        .panel()
    }

    private func checkRow(isOn: Binding<Bool>, text: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? ACABTheme.warn : ACABTheme.faint)
                Text(text)
                    .font(ACABTheme.mono(11))
                    .foregroundStyle(isOn.wrappedValue ? ACABTheme.dim : ACABTheme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The tick lives only in the SF Symbol swap, so without this VoiceOver reads the same
        // sentence plus "button" whether the row is ticked or not - no state, and no feedback
        // that the tap landed - on the one panel that exists to be worked through step by step.
        // Same trait every other selectable control here carries; Android's twin is a
        // Role.Checkbox toggleable.
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
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
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ACABTheme.watchTone)
            Text("Star it to get pinged every time this exact device shows up.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                toggleWatch()   // shared guard: this used to star directly, skipping the confirm
            } label: {
                // Same pair as the primary watchButton below and Android's WatchButton: the
                // action verb, so the sighted label and the spoken one agree.
                Text(on ? "STOP WATCHING" : "WATCH")
                    .font(ACABTheme.mono(9.5, weight: .bold)).tracking(1)
                    .foregroundStyle(on ? ACABTheme.onAccent : ACABTheme.watchTone)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(on ? ACABTheme.watchTone : ACABTheme.watchTone.opacity(0.14),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Color.clear : ACABTheme.watchTone.opacity(0.4),
                                                    lineWidth: 1))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }

    // MARK: Signal

    private var signalPanel: some View {
        let stale = ble.isStale(for: d.id, asOf: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if stale {
                    Kicker("SIGNAL \u{00B7} STALE", color: ACABTheme.dim)
                } else {
                    Kicker("SIGNAL \u{00B7} LIVE")
                }
                Button { withAnimation(.easeInOut(duration: 0.15)) { showRssiInfo.toggle() } } label: {
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(ACABTheme.dim)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What the RSSI graph means")
                Spacer()
                SignalBars(bars: d.signalBars, tint: d.type.tint)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(d.rssi)").font(ACABTheme.display(30, weight: .semibold))
                            .foregroundStyle(ACABTheme.text).monospacedDigit()
                        Text("dBm").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                    Kicker("RSSI")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(d.source.label).font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(d.type.textTint)
                    Kicker("BAND")
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Kicker("STRONG", color: d.type.textTint)
                    Spacer(minLength: 4)
                    Kicker("WEAK", color: ACABTheme.dim)
                }
                .frame(height: min(signalGraphHeight, 100))
                Sparkline(values: trend, tint: d.type.tint)
                    .frame(height: min(signalGraphHeight, 100))
            }
            .opacity(stale ? 0.35 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Signal history")
            .accessibilityValue("Strong at the top, weak at the bottom")
            if showRssiInfo {
                Text("RSSI is signal strength, moment to moment. closer to 0 is stronger, so the line climbs as you get nearer the source and drops as you move away, use it to home in on a hit.")
                    .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    // MARK: Stat grid

    /// Two cells: signal and sightings. Matched-on and confidence live in the
    /// match-quality panel above (1d).
    private var statGrid: some View {
        let firstDate = ble.firstSeenDate(for: d.id)
        let sightings: String
        // One line, so this cell says only how good the time is; the identity panel below carries
        // the actual range and the explanation. The tilde is the same "derived" shorthand the log
        // row's RECON tag stands for.
        if let firstDate {
            switch ble.timeBasis(for: d.id, stamp: firstDate) {
            case .exact:         sightings = "\(d.count) \u{00B7} first \(relativeAgo(firstDate))"
            case .reconstructed: sightings = "\(d.count) \u{00B7} first ~\(relativeAgo(firstDate))"
            case .bracketed:     sightings = "\(d.count) \u{00B7} time bounded"
            case .unknown:       sightings = "\(d.count) \u{00B7} time unknown"
            }
        } else {
            sightings = "\(d.count)"
        }
        let cells: [(String, String)] = [
            ("SIGNAL",    "\(d.rssi) dBm \u{00B7} \(d.source.label)"),
            ("SIGHTINGS", sightings),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 5) {
                    Kicker(c.0)
                    Text(c.1).font(ACABTheme.mono(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .overlay(alignment: .trailing) {
                    if i == 0 { Rectangle().fill(ACABTheme.line).frame(width: 1) }
                }
            }
        }
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    // MARK: Identity

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker("IDENTITY").padding(.bottom, 4)
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
            idRow("Identifier", d.mac)
            timeRow("First seen", ble.firstSeenDate(for: d.id))
            timeRow("Last seen", ble.lastSeenDate(for: d.id))
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
            if let c = d.coordinate { idRow("Position", String(format: "%.5f, %.5f", c.latitude, c.longitude)) }
            if let alt = d.altitude { idRow("Altitude", "\(alt) m") }
            if let s = d.speedH { idRow("Speed", "\(s) m/s") }
            if let vs = d.speedV, vs != 0 { idRow("Vert. speed", "\(vs) m/s") }
            if let h = d.heading { idRow("Heading", "\(h)°") }
            if let hg = d.heightAGL { idRow("Height AGL", "\(hg) m") }
            if let p = d.pilotCoordinate { idRow("Operator pos", String(format: "%.5f, %.5f", p.latitude, p.longitude)) }
            if let pa = d.pilotAlt { idRow("Operator alt", "\(pa) m") }
            if let st = d.ridStatusLabel { idRow("Status", st) }
            whyFlagged
        }
    }

    /// Title and subtitle are BYTE-IDENTICAL to android DetailScreen.kt's identity
    /// DisclosureSection, and docs/app-guide.md names this control for readers of both apps.
    private var identityDisclosure: some View {
        DisclosureGroup(isExpanded: $identityExpanded) {
            identityPanel
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("Technical details", systemImage: "info.circle")
                    .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Text("Identifiers, capture times and broadcast fields")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 44)
        }
        .tint(ACABTheme.dim)
        .panel()
    }

    private func idRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            Spacer(minLength: 16)
            Text(value).font(ACABTheme.mono(12, weight: .medium)).foregroundStyle(ACABTheme.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(ACABTheme.line).frame(height: 1) }
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
    private func timeRow(_ label: String, _ date: Date?) -> some View {
        let basis = ble.timeBasis(for: d.id, stamp: date)
        return HStack(alignment: .top) {
            Text(label).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(timeValue(basis, date))
                    .font(ACABTheme.mono(12, weight: .medium)).foregroundStyle(ACABTheme.text)
                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                if let note = TimeBasisCopy.note(for: basis) {
                    Text(note)
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(ACABTheme.line).frame(height: 1) }
    }

    /// A live stamp keeps the relative "4m ago" the rest of the screen speaks in. Anything
    /// derived switches to an absolute reading or a range, because "4m ago" quietly asserts a
    /// precision no reconstruction has.
    private func timeValue(_ basis: TimeBasis, _ date: Date?) -> String {
        if case .exact = basis { return relativeAgo(date) }
        return TimeBasisCopy.value(for: basis, stamp: date)
    }

    private var whyFlagged: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(d.type.tint)
            Text("Flagged by \(d.method.label) over \(d.source.label).")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    // MARK: Location

    private func locationPanel(_ coord: CLLocationCoordinate2D) -> some View {
        let hasTrackerTrail = d.type == .tracker && ble.crumbTrail(for: d.id).count >= 2
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Kicker("LOCATION")
                Spacer()
                Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
            }
            // gpsAgeSec describes the wire coordinate on THIS row. Once a different strongest
            // sample owns the observer pin, applying this row's age to it would be false.
            if let wire = d.coordinate,
               wire.latitude == coord.latitude, wire.longitude == coord.longitude,
               let age = d.locationAgeDetail {
                // The board stamped this fix from a stale phone position (offline /
                // Desert mode), so flag how old it is.
                HStack(spacing: 7) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11)).foregroundStyle(ACABTheme.warn)
                    Text(age)
                        .font(ACABTheme.mono(11, weight: .medium)).foregroundStyle(ACABTheme.warn)
                    Spacer(minLength: 0)
                }
            }
            // CORROBORATION, positive-only. If this is an ALPR-type hit AND a community-mapped
            // camera sits within ~150m, say so - a live detection landing on an independently
            // mapped node is strong confirmation, and names the mapped maker when known.
            // We NEVER show a "no mapped camera" line: OSM lags new installs and mobile cruiser
            // ALPR is meant to move, so absence is not evidence of a false positive (the confidence
            // % chip is the false-positive tell). Only shows when the ALPR layer is loaded.
            // Read from the cache, never from the store: see alprMatch.
            if (d.type == .flockCamera || d.type == .flockRaven),
               let hit = alprMatch, hit.meters <= 150 {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11)).foregroundStyle(hit.confirmed ? ACABTheme.flockTone : ACABTheme.warn)
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
                        .font(ACABTheme.mono(11, weight: .medium))
                        .foregroundStyle(hit.confirmed ? ACABTheme.flockTone : ACABTheme.warn)
                    Spacer(minLength: 0)
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
                        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                            .strokeBorder(ACABTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasTrackerTrail
                                    ? "Open in map. Phone breadcrumb trail, this session."
                                    : "Open in map")
            } else {
                mapThumbnail(coord)
                    .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                        .strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            if hasTrackerTrail {
                Label("Phone breadcrumb trail · this session",
                      systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(ACABTheme.mono(9.5))
                    .foregroundStyle(ACABTheme.faint)
                    .accessibilityLabel("Phone breadcrumb trail, this session only")
            }
        }
        .panel()
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

    /// Corner chip on the map thumbnail so the tap is discoverable. Styled like the map
    /// tab's own overlay chips (material capsule, hairline border).
    private var openInMapPill: some View {
        Text("OPEN IN MAP")
            .font(ACABTheme.mono(9.5, weight: .bold)).tracking(1)
            .foregroundStyle(ACABTheme.dim)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            .padding(7)
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
            VStack(alignment: .leading, spacing: 9) {
                switch followState {
                case .scored(let s):
                    // The kicker appears ONLY when a band fires. Over the none state it would be a
                    // header asserting something the body immediately walks back.
                    if let label = FollowEvidence.label(s.band) {
                        Kicker(FollowEvidence.kicker)
                        // Plain body text, never routed through Kicker: an all-caps transform is
                        // one more thing that can silently drift away from Android.
                        Text(label)
                            .font(ACABTheme.display(15, weight: .medium))
                            .foregroundStyle(ACABTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(FollowEvidence.body(s))
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                case .notMeasured:
                    Text(FollowEvidence.notMeasuredLine)
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                case .noLocation:
                    Text(FollowEvidence.noLocationLine)
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                case .noFix:
                    Text(FollowEvidence.noFixLine)
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // EVERY state, not just the ones where a band fired. The states that say nothing
                // are precisely where the user has to be told the memory is session-scoped: after
                // a restart the crumbs are gone and the row is not, and without this line the
                // panel's silence reads as a result.
                scopeLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    /// Crumbs are session-only and never persisted, and they exist for trackers alone. Both facts
    /// ride on every state of this panel, so it can never imply a longer memory or a wider scope
    /// than the app actually has.
    private var scopeLine: some View {
        Text(FollowEvidence.scopeLine)
            .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var miniPin: some View {
        ZStack {
            Circle().fill(d.type.tint).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2))
            Image(systemName: d.type.symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
        }
    }

    // MARK: Action

    /// Always visible, below the Technical details disclosure and never inside it: an address is
    /// what someone hands to a reporter or a records request, so it cannot sit behind a collapsed
    /// section. TWIN: android DetailScreen.kt calls CopyMacButton in this same position.
    private var copyButton: some View {
        Button {
            // localOnly keeps the MAC off Universal Clipboard (no sync to other devices) and the
            // 60s expiry auto-clears it, so a copied surveillance-gear MAC doesn't linger on the
            // pasteboard or leak to a paired Mac/iPad.
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: d.mac]],
                                          options: [.localOnly: true,
                                                    .expirationDate: Date().addingTimeInterval(60)])
            withAnimation { copied = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .bold))
                Text(copied ? "COPIED" : "COPY MAC ADDRESS").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(ACABTheme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Star / un-star this exact MAC. Watching and ignoring are exclusive, so starring
    /// The ONE place star/unstar is decided, so every entry point gets the same guard. There are
    /// two call sites (starRow in the header and watchButton below) and starRow used to call
    /// ble.watchDevice(d) directly, skipping the confirm entirely. That bypass fired on exactly the
    /// rows most likely to rotate: Desert nearby-device rows are confidence 0, so they always show
    /// the ConfirmIt panel that hosts starRow. Android already funnelled both sites through one
    /// closure; this brings iOS to parity.
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
            return "This tag's address holds for about a day, then changes around 4am. The star stops matching when it does. The tracker detector finds it either way."
        case .nearbyDevice:
            return "Most phones change their address every few minutes, so this star will likely stop matching within the hour."
        default:
            // No "trackers" here: .tracker is handled above, and a separated tag rotates about
            // once a day, not every few minutes. Repeating the near-owner interval in the fallback
            // would put the debunked claim straight back in front of the user.
            return "This address looks randomized, so the star may stop matching this device."
        }
    }

    /// a currently-ignored device silently un-mutes it (handled in the manager).
    private var watchButton: some View {
        let on = ble.isWatched(d.mac)
        return Button {
            toggleWatch()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: on ? "star.fill" : "star").font(.system(size: 13, weight: .bold))
                // "WATCH" / "STOP WATCHING": the action verb, not a state word, so the sighted
                // label and the VoiceOver label below say the same thing. TWIN: android
                // DetailScreen.kt `WatchButton`, same pair, byte for byte.
                Text(on ? "STOP WATCHING" : "WATCH")
                    .font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(on ? ACABTheme.onAccent : ACABTheme.watchTone)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(on ? ACABTheme.watchTone : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(on ? Color.clear : ACABTheme.watchTone.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Stop watching this device" : "Watch this device")
        .accessibilityAddTraits(on ? .isSelected : [])
        // A randomized address rotates, so confirm before starring it. ONE dialog with a
        // type-selected body, never two in a row: a tracker is almost always randomized too, so
        // firing a generic prompt and then a tracker prompt would double up on the same tap.
        .confirmationDialog("Watch a rotating address?", isPresented: $confirmRandomWatch, titleVisibility: .visible) {
            Button("Watch anyway") { ble.watchDevice(d) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(watchWarningBody)
        }
    }

    private var ignoreButton: some View {
        Group {
            if let rule = muteRule {
                // Evaluated fresh at render time, never via the 60 s-cached isIgnored set, so
                // the headline and the detail line always describe the same instant - matching
                // Android's DetailScreen, which feeds MuteButton from ble.muteRuleStatus.
                let status = ble.muteRuleStatus(for: rule)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "bell.slash.fill").font(.system(size: 13, weight: .bold))
                        Text(muteHeadline(for: rule, status: status))
                            .font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(status == .active ? ACABTheme.accent : ACABTheme.warn)
                    if let detail = muteStatusDetail(for: status) {
                        Text(detail)
                            .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("CHANGE") { showMuteOptions = true }
                            .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                            .foregroundStyle(ACABTheme.dim)
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                                .strokeBorder(ACABTheme.line, lineWidth: 1))
                        Button("UNMUTE") { ble.unignore(d.mac) }
                            .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                            .foregroundStyle(ACABTheme.onAccent)
                            .frame(maxWidth: .infinity).frame(minHeight: 44)
                            .background(ACABTheme.accent,
                                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(ACABTheme.bg2,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                    .strokeBorder(ACABTheme.line, lineWidth: 1))
            } else {
                Button { showMuteOptions = true } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                        Text("MUTE…").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
                    }
                    .foregroundStyle(ACABTheme.dim)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                        .strokeBorder(ACABTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog("Mute this device", isPresented: $showMuteOptions,
                            titleVisibility: .visible) {
            Button("Permanently") { applyMute(.permanent) }
            Button("For 1 hour") { applyMute(.oneHour) }
            Button("For 24 hours") { applyMute(.oneDay) }
            if ble.currentLocationCoord != nil {
                Button("At this place (50 m)") { applyMute(.here) }
            } else if !canAcquireFreshLocation {
                Button("Connect your beacon for a current location") {}
                    .disabled(true)
            } else if ble.locationRestricted {
                Button("Location restricted by device policy") {}
                    .disabled(true)
            } else if ble.locationDenied {
                Button("Open Settings for a place mute", action: openAppSettings)
            } else if !ble.locationAuthorized && !ble.locationDenied {
                Button("Enable location for a place mute") {
                    ble.requestLocationForPlaceMute()
                }
            } else {
                Button("Get a more accurate location") {
                    ble.requestLocationForPlaceMute()
                }
            }
            Button("Cancel", role: .cancel) {}
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
    }

    /// Android-parity headline (MuteButton in DetailScreen.kt): only an ACTIVE rule may say
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
