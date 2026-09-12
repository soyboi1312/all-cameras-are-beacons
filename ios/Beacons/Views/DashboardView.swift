import SwiftUI

/// Status / home: the at-a-glance "how much is watching me right now" screen.
/// Built around the radar scope, fed by live BLE detections.
struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    var onOpenDetectors: () -> Void = {}
    // Accessibility text sizes reflow the six-across tile strip into a grid and pad the scroll
    // bottom; read once here so every consumer keys off the same threshold.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // SF Symbols have different intrinsic bounds (the wide tracker radio waves are taller than
    // the glasses, for example), so the icon sits in a fixed frame. Under it every tile has the
    // same three scaled lines: the count (always a digit; OFF never takes its place), the label,
    // and the OFF line, which holds an empty string while the detector is on. The caption metric
    // sizes both of the last two, so neither the glyph choice nor switching a detector off
    // changes the card's outer height. The value/caption metrics follow the same Dynamic Type
    // curves as the matching ACABTheme fonts below.
    @ScaledMetric(relativeTo: .title) private var categoryValueLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var categoryCaptionLineHeight: CGFloat = 10

    // Staleness moves with the clock, not with @Published state, so nothing would invalidate
    // this screen as rows go quiet: without the tick the count freezes at its last-publish
    // value and a device we stopped hearing 20 minutes ago keeps reading LIVE. Pass `tick`
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
    // fake continuous range. Full bars = inner ring, 3 = mid, weaker = outer.
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
    private var scanning: Bool { radioPresentation.isScanning }
    private var scanKickerColor: Color {
        radioPresentation.tone == .warning ? ACABTheme.warn : ACABTheme.dim
    }

    var body: some View {
        let snapshot = dashboardSnapshot(ble.detections, now: tick, isDemoMode: ble.demoMode,
            lastHeard: ble.lastSeenDate(for:), isWatched: { ble.isWatched($0) })
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            BrandMark(size: 21)
                            Spacer()
                            NavigationLink {
                                HelpView(canImproveDetection: improveDetectionAvailable(
                                    isSessionReady: ble.sessionReady,
                                    isDemoMode: ble.demoMode))
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(ACABTheme.dim)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("help and support")
                            LinkChip(version: ble.status?.version,
                                     connected: ble.connectionState == .connected && ble.sessionReady && !ble.isReconnecting,
                                     demo: ble.demoMode, stateLabel: radioPresentation.chipLabel)
                        }
                        HStack(spacing: 8) {
                            if scanning {
                                ScanDot(color: bleFault ? ACABTheme.warn : ACABTheme.accent)
                            } else {
                                // A pulsing dot beside "NOT SCANNING" would still read as alive.
                                Circle().fill(ACABTheme.faint).frame(width: 7, height: 7)
                            }
                            Kicker(radioPresentation.scanLabel, color: scanKickerColor)
                                // The kicker is a clipped all-caps telegram ("SCANNING ·
                                // WI-FI ONLY · BLE RADIO FAULT"). The presenter already carries
                                // the plain sentence that abbreviation stands for, so speak it
                                // after the label. Part of the LABEL, not a hint: hints are a
                                // VoiceOver setting a user can switch off, and this is the only
                                // place the sentence is read.
                                .accessibilityLabel("\(radioPresentation.scanLabel). \(radioPresentation.detail)")
                            // Far-right recency note: the radar + counts only include devices heard
                            // within the activeNearbyInterval window (dashboardSnapshot's
                            // lastSeenIsStale), so name it, but only when something is up.
                            if !ble.demoMode, snapshot.total > 0 {
                                Spacer()
                                Kicker(DashboardSnapshot.seenWindowKicker, color: ACABTheme.faint)
                            }
                        }

                        if bleFault { coprocFaultPill } else if bleUpdating { coprocUpdatingPill }
                        if ble.syncingOfflineLog { syncingPill }

                        // A square that fills the column up to 420, which is what Android's
                        // RadarScope has always been: `widthIn(max = 420.dp)` outside,
                        // `fillMaxWidth().aspectRatio(1f).padding(top = 4.dp)` inside
                        // (StatusScreen.kt). This used to be a hard `.frame(height: 250)`, and
                        // because RadarScope sizes on `min(width, height)` that height ALWAYS won:
                        // the scope was 250pt on every phone AND every iPad, the shared 420 cap
                        // below was unreachable, and the same screen read 250pt on iPhone against
                        // 371dp on a 411dp Android. aspectRatio must stay INSIDE the 420 frame so
                        // it squares the capped width rather than the full column.
                        //
                        // Unbounded height is what makes `.fit` resolve on width here: this sits
                        // in a ScrollView. Do not add a fixed height back.
                        RadarScope(count: snapshot.total, dots: dots(from: snapshot),
                                   cap: DashboardSnapshot.dotLimit, sweeping: scanning)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(ringLabels)
                            .frame(maxWidth: 420)
                            .frame(maxWidth: .infinity)   // center the capped radar in the (leading) column, matters on iPad
                            .padding(.top, 4)

                        // SECTION ORDER BELOW THE SCOPE IS SHARED with android StatusScreen.kt
                        // (the Column in StatusScreen, RadarScope down to PunkLine): the strongest
                        // card, the category tiles, the legend that explains the dial (count cards,
                        // the two conditional lines, the captions, the no-direction pill), then the
                        // brand line. The square scope already spends most of a 390pt phone's first
                        // screen, so the verdict and the two taps it leads to (dossier, Log) come
                        // before the legend, which can scroll. Reorder one side only and the other
                        // side's comment becomes a lie.
                        if let strongest = snapshot.strongest { nearestCard(strongest) }
                        categoryTiles(snapshot)
                        radarLegend(snapshot)
                        // Brand ornament, last on both phones (PunkLine is the last child of the
                        // Android Column too), so it spends nothing of the budget above the fold.
                        HStack { Spacer(); PunkLine(); Spacer() }
                            .padding(.top, 2)
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
            }
            .navigationBarHidden(true)
        }
        .onReceive(staleTick) { tick = $0 }
    }

    /// Everything that explains the dial, one block in one order on both phones (android
    /// StatusScreen.kt `RadarLegend`): the count cards that split TOTAL NEARBY, the two
    /// conditional lines, the two caption lines, then the no-direction pill. Three siblings of
    /// the column, so they keep its section spacing.
    @ViewBuilder
    private func radarLegend(_ snapshot: DashboardSnapshot) -> some View {
        nearbyBreakdown(snapshot)

        VStack(spacing: 3) {
            // Both lines come from the presentation, where Android's
            // StatusNearbySummary.radarCaption / STATUS_RADAR_CAPTION_DETAIL are
            // the byte-identical twins and both suites pin the literals.
            Text(snapshot.radarCaption)
                .font(ACABTheme.mono(11, weight: .semibold))
            Text(DashboardSnapshot.radarCaptionDetail)
                .font(ACABTheme.mono(10))
        }
        .foregroundStyle(ACABTheme.dim)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)

        // Promoted from a 9pt afterthought to a standing element of the radar presentation: a
        // dial reads as bearing to everyone who has ever seen one, and here the angle is a MAC
        // hash. The one line that corrects that mental model has to be legible and always
        // rendered (the lines above it come and go), not a caption you squint at. Scales with
        // Dynamic Type (it is content, not chrome).
        Text("SIGNAL STRENGTH ONLY \u{00B7} NO DIRECTION")
            .font(ACABTheme.mono(10.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }

    /// The two count cards and the two lines under them. Every drawn word is the presentation's
    /// (DashboardSnapshot.matchedCardTitle and friends, unclassifiedLine, watchedLine), where the
    /// Android twins are named. The one string worded here is the watched tap's VoiceOver hint,
    /// which is iOS's own: Android's tap speaks its "show in log" click label instead. TWIN:
    /// android StatusScreen.kt `RadarCountCards` + the two lines in `RadarLegend`, same order,
    /// same tones: crimson (accentText) for the match card, dim for ambient and for the
    /// unclassified line, the watched tint for the watched tap.
    private func nearbyBreakdown(_ snapshot: DashboardSnapshot) -> some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    nearbyCount(snapshot.matched, title: DashboardSnapshot.matchedCardTitle,
                                detail: DashboardSnapshot.matchedCardDetail, color: ACABTheme.accentText)
                    nearbyCount(snapshot.ambient, title: DashboardSnapshot.ambientCardTitle,
                                detail: DashboardSnapshot.ambientCardDetail, color: ACABTheme.dim)
                }
                VStack(spacing: 8) {
                    nearbyCount(snapshot.matched, title: DashboardSnapshot.matchedCardTitle,
                                detail: DashboardSnapshot.matchedCardDetail, color: ACABTheme.accentText)
                    nearbyCount(snapshot.ambient, title: DashboardSnapshot.ambientCardTitle,
                                detail: DashboardSnapshot.ambientCardDetail, color: ACABTheme.dim)
                }
            }
            if let line = snapshot.unclassifiedLine {
                // Dim on purpose: a wire type this build does not know is a fact to report, not
                // an alert (the nearest card treats unclassified the same way).
                Text(line)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = snapshot.watchedLine {
                Button {
                    LogFocus.pendingCategory = "WATCHED"
                    NotificationCenter.default.post(name: LogFocus.notification, object: nil)
                } label: {
                    Label(line, systemImage: "star.fill")
                        .font(ACABTheme.mono(11, weight: .medium))
                        .foregroundStyle(DeviceType.watched.textTint)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint("opens the Log filtered to watched devices")
            }
        }
    }

    /// VoiceOver reads the three children in order (count, title, detail); the Android card
    /// speaks the same three through its merged contentDescription.
    private func nearbyCount(_ count: Int, title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(count)").font(ACABTheme.display(24, weight: .bold)).monospacedDigit()
            Text(title).font(ACABTheme.mono(10, weight: .semibold))
            Text(detail).font(ACABTheme.mono(9)).foregroundStyle(ACABTheme.dim)
        }
        .foregroundStyle(color)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
        .accessibilityElement(children: .combine)
    }

    /// The nRF fault is a whole half of the detection surface going dark, so it can't live
    /// only on the Beacon tab. Short form here, Beacon carries the full what-to-try.
    private var coprocFaultPill: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(ACABTheme.warn)
            Text("nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.warn.opacity(0.4), lineWidth: 1))
    }

    /// Same slot as coprocFaultPill, for the one case where the dark nRF is intentional: it's
    /// taking new firmware. Says the same thing about coverage without the alarm colours.
    private var coprocUpdatingPill: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .tint(ACABTheme.dim)
            Text("updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Subtle, non-blocking indicator shown while the board is replaying its offline
    /// "black box" buffer on reconnect. Indeterminate (the total isn't known until the
    /// end), with a live-climbing count when we have one.
    private var syncingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .tint(ACABTheme.dim)
            Text(syncingLabel)
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Determinate "X of N" once the board's {"hist":"begin"} lead-in gives the total; falls back
    /// to a live "so far" count, then a bare spinner label before any record lands.
    private var syncingLabel: String {
        let n = ble.offlineSyncCount, total = ble.offlineSyncTotal
        if total > 0 { return "syncing offline log, \(n) of \(total)" }
        if n > 0     { return "syncing offline log, \(n) so far" }
        return "syncing offline log\u{2026}"
    }

    /// STRONG / GOOD / WEAK stacked up the vertical axis, naming the rings the blips snap to.
    /// Lives in an overlay so RadarScope itself stays generic.
    ///
    /// THESE ARE STRENGTH WORDS, NOT DISTANCE WORDS. They were NEAR / MID / FAR until
    /// 2026-09-08, which labelled a signal-strength quantity with distance, and the screen then
    /// had to walk it back twice on itself: the pill says SIGNAL STRENGTH ONLY - NO DIRECTION and
    /// radarCaptionDetail says the same again. RSSI is not distance, because transmit power is a
    /// per-DEVICE choice (faq-content.json q-signal spells this out): a pole-mounted ALPR camera
    /// reads strong from across a street while a tracking tag a few meters away reads weak. The
    /// vocabulary is `beaconSignalDescription`'s, so the ring a blip sits on and the word
    /// VoiceOver speaks for its bars cannot disagree. Do not put NEAR / MID / FAR back.
    private var ringLabels: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = s / 2
            Group {
                ringLabel("STRONG", opacity: 0.45).position(x: cx, y: cy - s / 6)
                ringLabel("GOOD",   opacity: 0.38).position(x: cx, y: cy - s / 3)
                ringLabel("WEAK",   opacity: 0.30).position(x: cx, y: cy - s / 2 + 7)
            }
        }
        .allowsHitTesting(false)
        // Decorative instrument chrome: VoiceOver otherwise reads the three ring words as stray
        // elements. The scope's own summary label already carries the meaning.
        .accessibilityHidden(true)
    }

    private func ringLabel(_ text: String, opacity: Double) -> some View {
        // Fixed size on purpose - decorative instrument chrome positioned absolutely on the
        // scope's fixed geometry. On the Dynamic Type caption curve these roughly quadruple at
        // accessibility sizes and overlapped each other and the count. The scope's real content
        // (the count) still scales, and RadarScope speaks a full summary for VoiceOver.
        Text(text)
            .font(Font.custom("JetBrainsMono-Medium", fixedSize: 7.5))
            .tracking(1)
            .foregroundStyle(ACABTheme.text.opacity(opacity))
    }

    /// One strip of compact per-category counts, matching the Log tiles and Map chips
    /// (ALPR, DRONE, BODY, TRACKER, GLASSES, plus Network camera). Six compact tiles share the
    /// row width evenly, so Status surfaces the netcam count the same way Log and Map already do.
    /// At accessibility text sizes six-across leaves each tile ~55pt while its label quadruples,
    /// so the strip reflows into a 3x2 grid; the default layout is untouched.
    @ViewBuilder
    private func categoryTiles(_ snapshot: DashboardSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) { tileSet(snapshot) }
        } else {
            HStack(spacing: 6) { tileSet(snapshot) }
        }
    }

    /// The six tiles themselves, shared by both containers above. Which tiles, in what order,
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
            VStack(spacing: 5) {
                Image(systemName: type.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : type.tint)
                    .frame(width: 22, height: 18)
                // Turning a detector off does not erase what was just heard. Keep the number
                // until it ages out, and show the setting separately from the evidence count.
                Text("\(n)")
                    .font(ACABTheme.display(18, weight: .bold))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(height: categoryValueLineHeight)
                Text(t.label)
                    .font(ACABTheme.mono(8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : type.textTint)
                    .lineLimit(1)
                    .frame(height: categoryCaptionLineHeight)
                // ONE OFF TREATMENT ON BOTH PHONES: the count stays, and OFF is a dim fourth
                // line under the label (android StatusScreen.kt CountTile draws the same line).
                // Dim, not amber: the user switched this detector off, nothing is faulty. The
                // empty string keeps the slot, so an OFF tile is no taller than its neighbours.
                Text(off ? "OFF" : "")
                    .font(ACABTheme.mono(8, weight: .semibold))
                    .foregroundStyle(ACABTheme.dim)
                    .lineLimit(1)
                    .frame(height: categoryCaptionLineHeight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dashboardTileAccessibilityLabel(spoken: t.spoken, count: n, off: off))
        .accessibilityHint(opensSettings ? "opens detector settings on Beacon" : "opens the Log filtered to this category")
    }

    /// The strongest recent match, falling back to explicitly labelled ambient traffic.
    private func nearestCard(_ sighting: DashboardSighting) -> some View {
        let d = sighting.detection
        let kind = sighting.matched ? "MATCH" : (sighting.unclassified ? "UNCLASSIFIED" : "AMBIENT")
        let recency = ble.demoMode ? "SAMPLE" : "RECENT"
        return VStack(alignment: .leading, spacing: 8) {
            // TWIN: android StatusScreen.kt NearestCard `Kicker(title, color = ...)`. Crimson
            // (accentText, the text cut - the fill tone is under AA as a word) ONLY for a match:
            // ambient and unclassified traffic is not an alert and reads dim on both phones.
            Kicker("STRONGEST \(kind) · \(recency)",
                   color: sighting.matched ? ACABTheme.accentText : ACABTheme.dim)
            NavigationLink {
                DetectionDetailView(detection: d)
            } label: {
                HStack(spacing: 12) {
                    CatGlyph(type: d.type, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.displayName)
                            .font(ACABTheme.display(15, weight: .semibold))
                            .foregroundStyle(ACABTheme.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        // THE FOUR LINES ARE SHARED, line for line, with android StatusScreen.kt
                        // NearestCard: the name, `inlineCategory · NODE xxxx`, the last-heard age
                        // on its own dim line, then `source · seen N×` faint. The age stands alone
                        // so neither line has to wrap beside the glyph and the dBm column.
                        //
                        // The inline category, the brand rule everywhere else on Status
                        // ("body cam", "ALPR"), not the title-case type label. Lowercase except
                        // where an initialism or proper noun keeps its casing, which is why this
                        // reads DeviceType.inlineCategory instead of lowercasing `category` here:
                        // that spelled the ALPR initialism "alpr".
                        Text("\(d.type.inlineCategory) · NODE \(d.nodeName)")
                            .font(ACABTheme.mono(10, weight: .medium))
                            .foregroundStyle(ACABTheme.dim)
                        Text(dashboardLastHeardLabel(sighting.lastHeard, now: tick, isDemoMode: ble.demoMode))
                            .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                        Text("\(d.source.label) · seen \(d.count)×")
                            .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(d.rssi)")
                            .font(ACABTheme.mono(15, weight: .semibold))
                            .foregroundStyle(ACABTheme.accentText)
                        Text("dBm").font(ACABTheme.mono(9)).foregroundStyle(ACABTheme.dim)
                        SignalBars(bars: d.signalBars, tint: d.type.tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ACABTheme.faint)
                }
                .panel(strong: true)
            }
            .buttonStyle(.plain)
        }
    }

    // Fake-but-stable bearing hashed from the MAC, we only have RSSI, not a real one.
    private func angle(for mac: String) -> Double {
        var h: UInt64 = 5381
        for b in mac.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360)
    }

}
