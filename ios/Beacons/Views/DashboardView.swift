import SwiftUI
import Combine   // Timer.publish(...).autoconnect(): Xcode 27 warns when the file relies on SwiftUI's re-export

/// Status / home: the at-a-glance "how much is watching me right now" screen.
/// Built around the radar scope, fed by live BLE detections.
struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    var onOpenDetectors: () -> Void = {}
    // Accessibility text sizes pad the scroll bottom and stack the header and the strongest
    // cell. The tile strip measures itself instead (CategoryStripLayout), so it does not read this.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // SF Symbols have different intrinsic bounds (the wide tracker radio waves are taller than
    // the glasses, for example), so the icon sits in a fixed frame. Under it every tile has the
    // same three scaled lines: the count (always a digit; OFF never takes its place), the label,
    // and the OFF line, which holds an empty string while the detector is on. The caption metric
    // sizes both of the last two, so neither the glyph choice nor switching a detector off
    // changes the card's outer height.
    // Each metric rides the Dynamic Type curve of the text style its line draws with: the count
    // in .headline, the label and the OFF line in .caption. Each base value is a little taller
    // than SF's own line at that style's default size, so no line clips.
    @ScaledMetric(relativeTo: .headline) private var categoryValueLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var categoryCaptionLineHeight: CGFloat = 16

    // Staleness moves with the clock, not with @Published state, so nothing would invalidate
    // this screen as rows go quiet: without the tick the count freezes at its last-publish
    // value and a device we stopped hearing 20 minutes ago keeps holding the STRONGEST ... ·
    // RECENT cell and the TOTAL NEARBY count (TWIN: android StatusScreen.kt's tick comment names
    // the same cue). Pass `tick`
    // into isStale rather than just reading it, so the dependency can't get optimized or
    // tidied away. 1 s cadence, same as Android's StatusScreen, so a device crossing the
    // 45 s boundary ages off the radar at the same moment on both platforms.
    @State private var tick = Date()
    /// Held in @State so the SAME publisher survives a re-render, exactly like the dossier's
    /// followTick. MainTabView holds the manager, so its body re-runs on every publish and builds
    /// this view fresh with it: as a plain `let` the timer was rebuilt each time and onReceive
    /// cancelled and resubscribed with it, so under a streaming feed it never lived the whole
    /// second it needs to fire once. `tick` then stuck at the instant Status appeared - and it
    /// stuck hardest during a drive or Desert mode, which is exactly when a row that went quiet
    /// has to age off instead of holding the radar at "SEEN < 45s".
    @State private var staleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// A starred row keeps its real category type, so the gold comes from the sighting's watched
    /// flag and not from the type (Android StatusScreen.kt's RadarScope dot loop draws it the
    /// same way, from StatusRadarDot.watched).
    private func dots(from snapshot: DashboardSnapshot) -> [RadarDot] {
        snapshot.dots.map { sighting in
            let d = sighting.detection
            return RadarDot(id: d.id, angle: angle(for: d.mac),
                     radius: ringRadius(bars: d.signalBars),
                     tone: sighting.watched ? DeviceType.watched.tint : d.type.tint)
        }
    }

    // Honest radar: blips snap to the ring of their signal band instead of a
    // fake continuous range. Full bars = inner ring, 3 = mid, weaker = outer. RadarScope draws
    // the outer band just inside the disc edge (it caps a dot's centre at s/2 less the dot's
    // radius, RadarScope.dotSize), so the whole dot stays on the disc. TWIN: android
    // StatusScreen.kt RadarScope's `rad`, which does the same with its own dot radius.
    private func ringRadius(bars: Int) -> Double {
        switch bars {
        case 4:  return 1.0 / 3.0
        case 3:  return 2.0 / 3.0
        default: return 1.0
        }
    }

    // MARK: Live radio state

    // The board reports ble/wifi as toggle INTENT, and on dual-radio boards "co" as nRF
    // liveness. A dead nRF gives coproc == false while status.ble still says true, so the
    // whole BLE half is dark and the toggle alone can't tell us. Single-radio boards omit
    // "co" (coproc == nil), where the toggle is the whole story.
    // A BLE-DFU window is the one benign reason for a dark nRF: it sits in its bootloader for
    // minutes, so "co" reads false and the board says so with "nrfup". Split the two - the radio
    // is equally dark either way (coprocDown, which is what drives scanning state), but only one
    // of them is a fault worth alarming about.
    private var coprocDown: Bool { ble.status?.coproc == false }
    private var nrfUpdating: Bool { ble.status?.nrfUpdating == true }
    private var coprocFault: Bool { coprocDown && !nrfUpdating }
    /// The nRF is only worth shouting about when BLE is meant to be running.
    private var bleFault: Bool {
        ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting
            && !ble.combinedState.isRunning && coprocFault && ble.status?.ble == true
    }
    /// The board's update state is meaningful even if Bluetooth scanning was switched off.
    private var bleUpdating: Bool {
        ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting
            && nrfUpdating
    }
    private var radioPresentation: BeaconRadioPresentation {
        beaconRadioPresentation(connectionState: ble.connectionState, sessionReady: ble.sessionReady,
            isReconnecting: ble.isReconnecting, isDemoMode: ble.demoMode, status: ble.status,
            combinedUpdateRunning: ble.combinedState.isRunning,
            isRebootingForUpdate: ble.isRebootingForUpdate)
    }
    /// Words only: a healthy presenter reads as quiet chrome in dim, and only `.warning` (a radio
    /// fault, among others) colours the scan telegram amber.
    private func scanKickerColor(_ radio: BeaconRadioPresentation) -> Color {
        radio.tone == .warning ? ACABTheme.warn : ACABTheme.dim
    }

    var body: some View {
        let snapshot = dashboardSnapshot(ble.detections, now: tick, isDemoMode: ble.demoMode,
            lastHeard: ble.lastSeenDate(for:), isWatched: { ble.isWatched($0) })
        // ONE presenter evaluation per body pass: the header and the sweep both read this.
        let radio = radioPresentation
        // The value the LinkChip is handed, and the first-zero line's `connected`, by construction.
        let connected = ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusHeader(snapshot, radioPresentation: radio, connected: connected)

                    if bleFault { coprocFaultNotice } else if bleUpdating { coprocUpdatingNotice }
                    if ble.syncingOfflineLog { syncingNotice }

                    VStack(spacing: 6) {
                        // A square three quarters of the column wide, capped at 315
                        // (RadarSideLayout, which says why and names the Android twin), centred.
                        // This used to be a hard `.frame(height: 250)`, and because RadarScope
                        // sizes on `min(width, height)` that height ALWAYS won: the scope was
                        // 250pt on every phone AND every iPad and the shared cap was unreachable.
                        // Then it filled the whole column up to 420; the owner found that too big
                        // (2026-09-25), so the side is now 0.75 of that.
                        //
                        // The layout proposes the square's side to RadarScope and reports that
                        // side as its height, so it works in this ScrollView's unbounded height.
                        // Do not add a fixed height back.
                        RadarSideLayout {
                            RadarScope(count: snapshot.total, dots: dots(from: snapshot),
                                       cap: DashboardSnapshot.dotLimit, sweeping: radio.isScanning)
                        }
                        .padding(.top, 4)
                        noDirectionCaption
                        // The motto, right under the caption, so it is on the first screen as
                        // on the pre-redesign Status (owner, 2026-09-25). Centred like the
                        // caption. TWIN: android StatusScreen.kt PunkLine, the same slot.
                        PunkLine()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }

                    // SECTION ORDER IS SHARED with android StatusScreen.kt (the content Column
                    // in StatusScreen), per C9: radar, the no-direction caption, the motto, the
                    // category strip, the strongest cell, then the legend cell. The first three
                    // are the VStack above (RadarScope, noDirectionCaption, then PunkLine); below
                    // this line come categoryTiles, the strongest slot (nearestCard, or firstZeroCell when a
                    // connected real session has nothing in the window: the quiet sentence while
                    // the board scans, statusFirstZeroLine, or why it is not scanning while the
                    // sweep is parked, statusNotScanningLine),
                    // then radarLegend (count cards, the unclassified line and the watched tap
                    // as one cell, the two caption lines under it; Android draws those two as
                    // the cell's last rows). No "Look around" row. The scope, its caption and
                    // the motto still spend about half of a 390pt phone's first screen, so the
                    // counts, the verdict and the taps they lead to (Log, dossier) come before
                    // the legend, which can scroll. Reorder one side only and the other side's
                    // comment becomes a lie.
                    categoryTiles(snapshot)
                    if let strongest = snapshot.strongest {
                        nearestCard(strongest)
                    } else if let line = statusFirstZeroLine(connected: connected,
                                                             isDemoMode: ble.demoMode,
                                                             scanning: radio.isScanning,
                                                             total: snapshot.total)
                                ?? statusNotScanningLine(connected: connected,
                                                         isDemoMode: ble.demoMode,
                                                         scanning: radio.isScanning,
                                                         total: snapshot.total,
                                                         detail: radio.detail) {
                        firstZeroCell(line)
                    }
                    radarLegend(snapshot)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 8)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            // Extra bottom margin ONLY at accessibility sizes, where the grown content can
            // otherwise end flush against (or under) the tab bar. Zero at default sizes so
            // the standard layout is untouched.
            .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
            // A Color background fills the safe areas by default, so the page is bg edge to edge.
            .background(ACABTheme.bg)
            // One header row: "Status" leading, help trailing (TabHeader, M2).
            .tabHeader("Status") { helpButton }
        }
        .onReceive(staleTick) { tick = $0 }
    }

    // MARK: Header

    /// Help and support, the Status header row's trailing button (TabHeader; tinted by the root
    /// `.tint`, no custom font).
    private var helpButton: some View {
        NavigationLink {
            HelpView(canImproveDetection: improveDetectionAvailable(
                isSessionReady: ble.sessionReady,
                isDemoMode: ble.demoMode))
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .accessibilityLabel("help and support")
    }

    /// The first content row under the header row (TabHeader): the board pill and the scan
    /// telegram, on `bg` (the pill's measured ratios hold on bg and bg2 only, so it is never a
    /// toolbar item).
    /// Beside each other when both fit; stacked, pill first, when they do not, and always
    /// stacked at accessibility sizes. The pill alone when sample data hides the bare telegram
    /// (dashboardScanKicker). Nothing here hugs its width or is clamped to one line.
    @ViewBuilder
    private func statusHeader(_ snapshot: DashboardSnapshot, radioPresentation: BeaconRadioPresentation,
                              connected: Bool) -> some View {
        // The pill's type is capped at accessibility2, the cap RootView gives the pinned banners:
        // riding the full curve it reached about 60pt at AX5 and, under the banner and the large
        // title, pushed the radar's caption and the motto under the tab bar on first paint (HIG
        // Typography: prioritise the important content). Its text is spoken in full either way.
        let chip = LinkChip(connected: connected, demo: ble.demoMode, stateLabel: radioPresentation.chipLabel)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        // Nil for the bare sample kicker (dashboardScanKicker says why).
        let scanKicker = dashboardScanKicker(scanLabel: radioPresentation.scanLabel,
                                             isDemoMode: ble.demoMode)
        // Recency note: the radar + counts only include devices heard
        // within the activeNearbyInterval window (dashboardSnapshot's
        // lastSeenIsStale), so name it, but only when something is up.
        let showsWindow = !ble.demoMode && snapshot.total > 0
        let scan = VStack(alignment: .leading, spacing: 2) {
            if let scanKicker {
                Kicker(scanKicker, color: scanKickerColor(radioPresentation))
                    // The kicker is a clipped all-caps telegram ("SCANNING ·
                    // WI-FI ONLY · BLE RADIO FAULT"). The presenter already carries
                    // the plain sentence that abbreviation stands for, so speak it
                    // after the label. Part of the LABEL, not a hint: hints are a
                    // VoiceOver setting a user can switch off, and this is the only
                    // place the sentence is read.
                    .accessibilityLabel("\(scanKicker). \(radioPresentation.detail)")
            }
            if showsWindow {
                Kicker(DashboardSnapshot.seenWindowKicker)
            }
        }
        if scanKicker == nil && !showsWindow {
            // Sample data with the bare kicker hidden: the pill alone, no empty column beside it.
            chip
        } else if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { chip; scan }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    scan
                    Spacer(minLength: 8)
                    // The pill reads first in both forms.
                    chip.accessibilitySortPriority(1)
                }
                .accessibilityElement(children: .contain)
                VStack(alignment: .leading, spacing: 8) { chip; scan }
            }
        }
    }

    // MARK: Notices

    /// The nRF fault is a whole half of the detection surface going dark, so it can't live
    /// only on the Beacon tab. Short form here, Beacon carries the full what-to-try. A notice
    /// cell: amber words on the grouped cell, no border.
    private var coprocFaultNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(ACABTheme.warn)
            Text("nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.")
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .groupedCell(padding: 12)
    }

    /// Same slot as coprocFaultNotice, for the one case where the dark nRF is intentional: it's
    /// taking new firmware. Says the same thing about coverage without the alarm colours.
    private var coprocUpdatingNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(ACABTheme.dim)
            Text("updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.")
                .font(ACABTheme.font(.subheadline)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .groupedCell(padding: 12)
    }

    /// Subtle, non-blocking notice cell shown while the board is replaying its offline
    /// "black box" buffer on reconnect. Indeterminate (the total isn't known until the
    /// end), with a live-climbing count when we have one.
    private var syncingNotice: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(ACABTheme.dim)
            Text(syncingLabel)
                .font(ACABTheme.font(.subheadline, tabular: true))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .groupedCell(padding: 12)
    }

    /// Determinate "X of N" once the board's {"hist":"begin"} lead-in gives the total; falls back
    /// to a live "so far" count, then a bare spinner label before any record lands.
    private var syncingLabel: String {
        let n = ble.offlineSyncCount, total = ble.offlineSyncTotal
        if total > 0 { return "syncing offline log, \(n) of \(total)" }
        if n > 0     { return "syncing offline log, \(n) so far" }
        return "syncing offline log\u{2026}"
    }

    // MARK: Radar chrome

    /// A dial reads as bearing to everyone who has ever seen one, and here the angle is a MAC
    /// hash. This is the one line that corrects that mental model, so it is always rendered,
    /// sits directly under the disc, and scales with Dynamic Type (it is content, not chrome)
    /// up to accessibility2, the cap RootView gives the pinned banners and statusHeader gives the
    /// SAMPLE pill: uncapped, at AX5 on the iPhone 17 Pro the stacked form wrapped "SIGNAL
    /// STRENGTH ONLY" inside itself to three lines with the third behind the tab bar
    /// (2026-09-26 review, P2-3 residue). The spoken label carries the words at every size.
    ///
    /// The two phrases wrap as units (STA-8): on one line when the whole caption fits, otherwise
    /// the two phrases stacked and centred without the dot, so a large text size never splits
    /// "NO" from "DIRECTION" or starts a line with a stray separator. VoiceOver reads the whole
    /// C9 literal as one element in both forms. TWIN: android StatusScreen.kt's caption under
    /// RadarScope, which wraps the same two phrases as units.
    private var noDirectionCaption: some View {
        ViewThatFits(in: .horizontal) {
            // One Text for the one-line form: a separate " · " Text loses its trailing space
            // (SwiftUI trims it), which drew the dot against NO DIRECTION.
            noDirectionPhrase(Self.noDirectionCaptionText)
                .lineLimit(1)
            VStack(spacing: 2) {
                noDirectionPhrase("SIGNAL STRENGTH ONLY")
                noDirectionPhrase("NO DIRECTION")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.noDirectionCaptionText)
    }

    /// The C9 caption literal, whole. Drawn as its two phrases by noDirectionCaption and spoken
    /// as this one string.
    static let noDirectionCaptionText = "SIGNAL STRENGTH ONLY \u{00B7} NO DIRECTION"

    /// One phrase of the caption, in the Kicker's type and ink (Kicker itself is not used here
    /// because ViewThatFits needs each phrase's own one-line width to choose a form).
    private func noDirectionPhrase(_ text: String) -> some View {
        Text(text)
            .font(ACABTheme.telemetry(.footnote))
            .tracking(ACABTheme.telemetryTracking)
            .foregroundStyle(ACABTheme.dim)
    }

    // MARK: Category strip

    /// One strip of compact per-category counts, the same six categories the Map chips count,
    /// drawn as ALPR / DRONE / BODY / TRKR / GLAS / NETCAM. Six compact tiles share the row width
    /// evenly, so Status surfaces the netcam count the same way the Map chips do. The strip
    /// reflows into rows of three as soon as the widest label no longer fits a six-across tile,
    /// and into rows of two after that (CategoryStripLayout measures it).
    private func categoryTiles(_ snapshot: DashboardSnapshot) -> some View {
        CategoryStripLayout(preferred: DashboardSnapshot.stripTiles.count, spacing: 6) {
            tileSet(snapshot)
        }
    }

    /// The six tiles themselves, laid out by categoryTiles. Which tiles, in what order,
    /// drawn and spoken as what, and counting which types, is the presentation's
    /// (DashboardSnapshot.stripTiles, where the Android twin is named); this only draws them.
    @ViewBuilder
    private func tileSet(_ snapshot: DashboardSnapshot) -> some View {
        ForEach(DashboardSnapshot.stripTiles, id: \.type) { t in
            // nil before the first frame: not off, not on, just unknown.
            tile(t, enabled: ble.status.map { $0[keyPath: t.toggle] }, snapshot.stripCount(t))
        }
    }

    /// Each tile deep-links to the Log tab with its category filter armed (LogFocus is the
    /// same one-shot static-slot pattern MapFocus uses, session-only on purpose), so the
    /// at-a-glance count answers "show me those" in one tap instead of being a dead number.
    private func tile(_ t: DashboardStripTile, enabled: Bool?, _ n: Int) -> some View {
        let type = t.type
        let off = enabled == false
        let opensSettings = dashboardTileOpensSettings(enabled: enabled, count: n)
        return Button {
            if opensSettings {
                onOpenDetectors()
            } else {
                LogFocus.pendingCategory = type.category
                NotificationCenter.default.post(name: LogFocus.notification, object: nil)
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: type.symbol)
                    // Fixed on purpose: SF Symbols have different intrinsic bounds, so the glyph
                    // sits in a fixed frame; the label below carries the category in text and scales.
                    .font(ACABTheme.fixed(20, weight: .medium))
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : type.tint)
                    .frame(width: 32, height: 26)
                // Turning a detector off does not erase what was just heard. Keep the number
                // until it ages out, and show the setting separately from the evidence count.
                Text("\(n)")
                    .font(ACABTheme.telemetry(.headline, weight: .semibold))
                    .foregroundStyle(n == 0 ? ACABTheme.dim : ACABTheme.text)
                    .lineLimit(1)
                    .frame(height: categoryValueLineHeight)
                Text(t.label)
                    .font(ACABTheme.telemetry(.caption))
                    .tracking(ACABTheme.telemetryTracking)
                    .foregroundStyle(ACABTheme.dim)
                    .lineLimit(1)
                    .frame(height: categoryCaptionLineHeight)
                // ONE OFF TREATMENT ON BOTH PHONES: the count stays, and OFF is a dim fourth
                // line under the label (android StatusScreen.kt CountTile draws the same line).
                // Dim, not amber: the user switched this detector off, nothing is faulty. The
                // empty string keeps the slot, so an OFF tile is no taller than its neighbours.
                Text(off ? "OFF" : "")
                    .font(ACABTheme.telemetry(.caption, weight: .semibold))
                    .tracking(ACABTheme.telemetryTracking)
                    .foregroundStyle(ACABTheme.dim)
                    .lineLimit(1)
                    .frame(height: categoryCaptionLineHeight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dashboardTileAccessibilityLabel(spoken: t.spoken, count: n, off: off))
        .accessibilityHint(opensSettings ? "opens detector settings on Beacon" : "opens the Log filtered to this category")
    }

    // MARK: Strongest cell

    /// The strongest recent match, falling back to explicitly labelled ambient traffic.
    private func nearestCard(_ sighting: DashboardSighting) -> some View {
        let d = sighting.detection
        let kind = sighting.matched ? "MATCH" : (sighting.unclassified ? "UNCLASSIFIED" : "AMBIENT")
        return VStack(alignment: .leading, spacing: 0) {
            // TWIN: android StatusScreen.kt NearestCard's header. Crimson (accentText) ONLY for
            // a match: ambient and unclassified traffic is not an alert and reads dim on both
            // phones. No recency suffix in sample data (dashboardStrongestHeader).
            SectionHeader(dashboardStrongestHeader(kind: kind, isDemoMode: ble.demoMode),
                          color: sighting.matched ? ACABTheme.accentText : ACABTheme.dim)
            NavigationLink {
                DetectionDetailView(detection: d)
            } label: {
                // At accessibility sizes the dBm column kept its width beside the text and
                // squeezed the text to about one short word per line, so words broke mid-word
                // ("FlockS" / "afety"). There the card stacks: a glyph row with only the glyph
                // and the chevron, the name and the facts at full width, then the signal at the
                // trailing edge of its own last row. The Log's DetectionRow.accessibilityLayout
                // stacks the same way (glyph, overline, name, subtitle, confidence, signal) but
                // draws no chevron: the List draws the disclosure indicator. The name stays out
                // of the glyph row on both: beside the glyph column and the chevron,
                // "FlockSafety" would break at the largest size on a 390pt phone.
                //
                // TWIN: android StatusScreen.kt NearestCard stacks the same way from fontScale
                // 1.5 (STATUS_LARGE_TEXT_STACK_SCALE): the glyph alone, the text at full width,
                // then the signal end-aligned on its own row. It draws no chevron.
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                CatGlyph(type: d.type, style: .bare)
                                Spacer(minLength: 0)
                                // Hidden: up here it would be spoken before the name.
                                nearestChevron.accessibilityHidden(true)
                            }
                            nearestText(sighting)
                            HStack { Spacer(); nearestSignal(d) }
                        }
                    } else {
                        HStack(spacing: 12) {
                            CatGlyph(type: d.type, style: .bare)
                            nearestText(sighting)
                            Spacer(minLength: 8)
                            nearestSignal(d)
                            nearestChevron
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 60)
                .groupedCell(padding: 0)
            }
            .buttonStyle(.plain)
        }
    }

    /// The name and the lines under it, one stack for both nearestCard layouts.
    private func nearestText(_ sighting: DashboardSighting) -> some View {
        let d = sighting.detection
        return VStack(alignment: .leading, spacing: 2) {
            // titleName: the display name, or the title fallback ("body cam", "network camera")
            // when nothing names the device (Detection.titleName).
            Text(d.titleName)
                .font(ACABTheme.font(.body))
                .foregroundStyle(ACABTheme.text)
                // No cap at accessibility sizes: there the name has the full card width, and
                // two lines of it can still cut a long name short.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            // THE FOUR LINES ARE SHARED, line for line, with android StatusScreen.kt
            // NearestCard: the name, `inlineCategory · NODE xxxx`, the last-heard age
            // on its own dim line, then `source · seen N×` dim. The age stands alone
            // so neither line has to wrap beside the glyph and the dBm column.
            //
            // The inline category, the brand rule everywhere else on Status
            // ("body cam", "ALPR"), not the title-case type label. Lowercase except
            // where an initialism or proper noun keeps its casing, which is why this
            // reads DeviceType.inlineCategory instead of lowercasing `category` here:
            // that spelled the ALPR initialism "alpr".
            // Lines 2 to 4 are the sighting's telemetry block: the instrument face.
            Text("\(d.type.inlineCategory) · NODE \(d.nodeName)")
                .font(ACABTheme.telemetry(.subheadline, weight: .regular))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text(dashboardLastHeardLabel(sighting.lastHeard, now: tick, isDemoMode: ble.demoMode))
                .font(ACABTheme.telemetry(.subheadline, weight: .regular))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(d.source.label) · seen \(d.count)×")
                .font(ACABTheme.telemetry(.footnote, weight: .regular))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The signal as a number stacked over its unit, trailing-aligned, secondary ink (crimson
    /// stays on the match header). Stacked, not side by side, so the trailing column is about
    /// half as wide and the four text lines beside it keep their width: side by side, "-54 dBm"
    /// and the chevron took about 40% of the row and the sample age line broke as
    /// "sample sighting ·" / "not live" (STA-9). TWIN: android StatusScreen.kt NearestSignal,
    /// which stacks the number over the unit the same way. Spoken with the Log row's wording
    /// (DetectionRow `signalText`) instead of the symbols.
    private func nearestSignal(_ d: Detection) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(d.rssi)").font(ACABTheme.telemetry(.subheadline))
            Text("dBm").font(ACABTheme.telemetry(.caption, weight: .regular))
        }
        .foregroundStyle(ACABTheme.dim)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength \(d.rssi) decibels relative to one milliwatt")
    }

    private var nearestChevron: some View {
        Image(systemName: "chevron.right")
            .font(ACABTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(ACABTheme.faint)
    }

    /// The strongest slot on a connected, real session with nothing heard in the window: what
    /// zero means (statusFirstZeroLine) while the board scans, or why the board is not scanning
    /// (statusNotScanningLine) while the sweep is parked, instead of an empty slot. No header:
    /// there is no sighting to name.
    private func firstZeroCell(_ line: String) -> some View {
        Text(line)
            .font(ACABTheme.font(.subheadline))
            .foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .groupedCell()
    }

    // MARK: Legend cell

    /// Everything that explains the dial, as ONE grouped cell under the strongest cell: the count
    /// cards that split TOTAL NEARBY, then the two conditional lines (unclassified, and the
    /// watched tap), with the two caption lines as the cell's footer. Every drawn word is the
    /// presentation's. TWIN: android StatusScreen.kt `RadarLegend`, the same content in the same
    /// order as one grouped cell (contracts C9).
    private func radarLegend(_ snapshot: DashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                nearbyBreakdown(snapshot)
                if let line = snapshot.unclassifiedLine {
                    Divider().overlay(ACABTheme.line)
                    // Dim on purpose: a wire type this build does not know is a fact to report, not
                    // an alert (the nearest card treats unclassified the same way).
                    Text(line)
                        .font(ACABTheme.font(.subheadline, tabular: true))
                        .foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                }
                if let line = snapshot.watchedLine {
                    Divider().overlay(ACABTheme.line)
                    watchedRow(line)
                }
            }
            .padding(.horizontal, 16)
            .groupedCell(padding: 0)
            VStack(alignment: .leading, spacing: 2) {
                // Both lines come from the presentation, where Android's
                // StatusNearbySummary.radarCaption / STATUS_RADAR_CAPTION_DETAIL are
                // the byte-identical twins and both suites pin the literals. Drawn through
                // keepingMiddleDotsAttached (SettingsView.swift), so a wrap at large sizes
                // never starts a line with an orphan "· 8 max"; the literal is untouched.
                Text(keepingMiddleDotsAttached(snapshot.radarCaption))
                    .font(ACABTheme.telemetry(.footnote, weight: .regular))
                    .foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Kicker(DashboardSnapshot.radarCaptionDetail)
            }
            .padding(.horizontal, 16)
        }
    }

    /// The two count cards, side by side when both fit and stacked when they do not, split by a
    /// separator. Every drawn word is the presentation's (DashboardSnapshot.matchedCardTitle and
    /// friends), where the Android twins are named. TWIN: android StatusScreen.kt
    /// `RadarCountCards`, the matched card first. Crimson (accentText) is for the matched card
    /// only; ambient reads dim.
    private func nearbyBreakdown(_ snapshot: DashboardSnapshot) -> some View {
        let matched = nearbyCount(snapshot.matched, title: DashboardSnapshot.matchedCardTitle,
                                  detail: DashboardSnapshot.matchedCardDetail, color: ACABTheme.accentText)
        let ambient = nearbyCount(snapshot.ambient, title: DashboardSnapshot.ambientCardTitle,
                                  detail: DashboardSnapshot.ambientCardDetail, color: ACABTheme.dim)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                matched
                Divider().overlay(ACABTheme.line)
                ambient
            }
            // The vertical separator takes the cards' height, not the whole column's.
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                matched
                Divider().overlay(ACABTheme.line)
                ambient
            }
        }
    }

    /// VoiceOver reads the three children in order (count, title, detail); the Android card
    /// speaks the same three through its merged contentDescription.
    private func nearbyCount(_ count: Int, title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)").font(ACABTheme.telemetry(.title2, weight: .bold))
            Text(title).font(ACABTheme.telemetry(.footnote, weight: .semibold))
                .tracking(ACABTheme.telemetryTracking)
            Text(detail).font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
        }
        .foregroundStyle(color)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// The watched line as the tap that opens the Log's WATCHED lens. The star and the chevron
    /// are hidden from VoiceOver: a Button merges its label's children, so without that the
    /// symbols' own names would be read before the line. The row speaks its line plus the hint.
    private func watchedRow(_ line: String) -> some View {
        Button {
            LogFocus.pendingCategory = "WATCHED"
            NotificationCenter.default.post(name: LogFocus.notification, object: nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(ACABTheme.font(.subheadline, weight: .semibold))
                    .foregroundStyle(DeviceType.watched.tint)
                    .accessibilityHidden(true)
                Text(line)
                    .font(ACABTheme.font(.subheadline, tabular: true))
                    .foregroundStyle(DeviceType.watched.textTint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(ACABTheme.font(.footnote, weight: .semibold))
                    .foregroundStyle(ACABTheme.faint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("opens the Log filtered to watched devices")
    }

    // Fake-but-stable bearing hashed from the MAC, we only have RSSI, not a real one.
    private func angle(for mac: String) -> Double {
        var h: UInt64 = 5381
        for b in mac.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360)
    }

}
