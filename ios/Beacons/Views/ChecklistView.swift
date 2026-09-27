import SwiftUI
import UIKit

enum FinishSetupLocationChoice: Equatable {
    case continueOrNotNow
    case openSettingsOrDone
    case done
}

func finishSetupLocationChoice(isAuthorized: Bool, isDenied: Bool) -> FinishSetupLocationChoice {
    if isAuthorized { return .done }
    return isDenied ? .openSettingsOrDone : .continueOrNotNow
}

/// The pending key the pre-checklist build armed between its real tour and Finish setup. This
/// build never arms it in production: it READS it (the checklist gate in RootView) and CLEARS it
/// (persistChecklistCompletion). A missing key means nothing is pending, which keeps upgraders
/// who finished the old flow from seeing the checklist. `arm(in:)` has no production caller; it
/// stays as the old build's write so OnboardingPolicyTests can reproduce that state.
enum FinishSetupOnboarding {
    private static let pendingKey = "acab.firstRunFinishSetup.pending"

    static var isPending: Bool { isPending(in: .standard) }
    static func isPending(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pendingKey)
    }
    static func arm(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }
    static func complete(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }
}

/// The four readiness sentences, shared by the checklist and Beacon > System readiness. Holds no
/// state: each consumer keeps its own systemPermissionRevision token, because
/// notifier.mutedBySystem has no publisher.
///
/// TWINS: android FirstRunTour.kt `checklistLocationDetail`, `checklistNotificationDetail`,
/// `checklistLiveModeDetail` and `checklistBufferDetail` draw the same sentences in the Android
/// checklist sheet (Android's System readiness card keeps its own uppercase words). Recorded
/// platform differences: Android's Location arm reads "allowed; Map is ready" (Android Live Mode
/// does not use Location) and it has no restricted / denied arms (no such Android fact); Android's
/// Live Mode has no Live Activities or waits-for-Location arm and reads "on by default, but its
/// notification is blocked by Android" when blocked; Android's buffer row adds "not known until
/// your beacon reports it" before the first status frame, where iOS reads a sticky Bool with no
/// unknown state; the blocked notifications sentence names the platform ("iOS" / "Android").
struct ChecklistRows {
    let ble: BLEManager

    /// The board these sentences (and the checklist's title, subtitle and preview note) name: the
    /// connected board's kind (BLEManager.connectedKind: its fw label, else its live advert hint,
    /// else its stored kind, else the kind its connect carried), and in a replay with no board the remembered board's. Sample data is
    /// always a beacon, so it reads nil. TWIN: Android checklistBoardKind in FirstRunTour.kt.
    var kind: BoardKind? {
        if ble.demoMode { return nil }
        return ble.connectedKind ?? ble.rememberedKind
    }

    var locationDetail: String {
        if ble.locationAuthorized { return "allowed; Map and background Live Mode are ready" }
        if ble.locationRestricted { return "restricted by device policy; detection still works" }
        if ble.locationDenied { return "off in iOS settings; detection still works" }
        return "optional; not decided yet"
    }

    var notificationDetail: String {
        let count = ble.enabledPhoneNotificationTypes.count
        if count == 0 { return "off until you choose categories under Beacon" }
        // enabledPhoneNotificationTypes is built from UserDefaults alone and carries no
        // authorization state, so the bare count reads as ready over a feature iOS will not
        // deliver. Every other row on this sheet folds the system's answer in (Live Mode reads
        // liveActivitiesEnabled, Location reads locationDenied / locationRestricted), Settings'
        // notify card already warns on exactly this state, and Android's twin row says BLOCKED.
        if !ble.demoMode, ble.notifier.mutedBySystem {
            return "\(count) chosen, but iOS is blocking them; turn notifications on for beacons in Settings"
        }
        return "\(count) categor\(count == 1 ? "y" : "ies") enabled on this phone"
    }

    var liveModeDetail: String {
        if ble.driveModeOn { return "active on supported system surfaces" }
        if !ble.driveModeWanted { return "off by choice; change it later under Beacon" }
        if !ble.liveActivitiesEnabled { return "on by default, but Live Activities are blocked by iOS" }
        if liveModeShouldWaitForLocation(hasReadySession: ble.sessionReady,
                                         isDemoMode: ble.demoMode,
                                         locationAuthorized: ble.locationAuthorized) {
            return "on by default; waits for Location before showing a system surface"
        }
        return renderBoardCopy("ready to start with this {noun}", kind)
    }

    var bufferDetail: String {
        if ble.bufferingOn { return renderBoardCopy("on; the {noun} retains hits while this phone is away", kind) }
        return "off; turn it on under Beacon if you want away-time hits retained"
    }
}

/// The six category detectors the status frame reports; nil before the first frame. Not droui,
/// which refines the drone detector rather than adding one. Twin: Android enabledDetectorCount
/// over flock, drone, bodyCam, tracker, glasses, ncam.
func enabledDetectorCount(_ s: DeviceStatus?) -> Int? {
    guard let s else { return nil }
    var n = 0
    for on in [s.flock, s.drone, s.axon, s.tracker, s.glasses, s.ncam] where on { n += 1 }
    return n
}

/// True when the sheet is the read-only replay AND has no live board to describe: `frame` is the
/// board's status frame, already nil in sample data (ChecklistView.alreadyTrueSection) and with no
/// link. Then the sheet is a preview (J7): it draws FirstRunTour.checklistPreviewNote under the
/// subtitle and rows 1 and 2 as neutral rows, never as unticked checks, so a user with no beacon
/// does not read a failed setup. The post-connect sheet itself is never a preview.
/// TWIN: Android `checklistIsPreview` in FirstRunTour.kt, the same two inputs.
func checklistIsPreview(replay: Bool, frame: DeviceStatus?) -> Bool {
    replay && frame == nil
}

/// The detectors row's title: the plain phrase before the first status frame, then the count.
/// Sentence case like every checklist row title (P3-11); a count leads the other two arms.
func checklistDetectorsTitle(count: Int?) -> String {
    guard let count else { return "Detectors on" }
    return count == 1 ? "1 detector on" : "\(count) detectors on"
}

/// The soft scroll-edge effect at the top of a scroll view on iOS 26, nothing on iOS 18 (which
/// has no floating glass bar to own an edge). Applied by ChecklistView's List.
private struct SoftTopScrollEdge: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

/// The one post-connect checklist (replaces the real first-run tour and Finish setup). Dismissal
/// in any form is completion, and RootView persists it in onDismiss; the view itself writes
/// nothing. `replay` is the read-only Help copy: state lines only, no buttons, no chevrons.
struct ChecklistView: View {
    let replay: Bool
    let onContinueLocation: () -> Void
    let onNotNow: () -> Void
    let onOpenBeaconRow: (BeaconFocus) -> Void
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    /// Invalidation token for the notification row. `notifier.mutedBySystem` is a plain cached var
    /// with no publisher, so a user who leaves for iOS Settings and comes back would otherwise read
    /// the answer this view was built with. Same mechanism SettingsView uses for its notify card.
    @State private var systemPermissionRevision = 0
    @ScaledMetric(relativeTo: .title3) private var glyphColumn: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Where a row's text starts: beside the glyph column, or at the row edge at accessibility
    /// sizes, where GroupedRow stacks the glyph above the text.
    private var textInset: CGFloat { dynamicTypeSize.isAccessibilitySize ? 0 : glyphColumn + 12 }
    /// The glyph's place in its column: centred beside the text, leading when stacked above it.
    private var glyphAlignment: Alignment { dynamicTypeSize.isAccessibilitySize ? .leading : .center }

    init(replay: Bool,
         onContinueLocation: @escaping () -> Void = {},
         onNotNow: @escaping () -> Void = {},
         onOpenBeaconRow: @escaping (BeaconFocus) -> Void = { _ in }) {
        self.replay = replay
        self.onContinueLocation = onContinueLocation
        self.onNotNow = onNotNow
        self.onOpenBeaconRow = onOpenBeaconRow
    }

    var body: some View {
        // SwiftUI never invalidates for a @State the body does not read.
        let _ = systemPermissionRevision
        let rows = ChecklistRows(ble: ble)
        NavigationStack {
            List {
                alreadyTrueSection
                optionalSection(rows)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ACABTheme.bg)
            // The bar holds only the Done pill and no title, so on iOS 26 it is an empty glass
            // strip with no scroll-edge region: once the List scrolled, the rows slid under the
            // pill and it cut the row text ("paired over encrypted Bluetooth"). The soft edge
            // gives the bar its own region (HIG Toolbars) and keeps the drawn header as it is.
            .modifier(SoftTopScrollEdge())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close(onNotNow) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ACABTheme.bg)
        // The manager already re-reads the system answer on willEnterForeground; issue it here too
        // (cheap and idempotent) so an activation without one - dismissing Control Center - counts,
        // and bump the token in the completion, after the notifier's cache is written.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ble.notifier.refreshAuthorization {
                systemPermissionRevision &+= 1
            }
        }
    }

    // Index order is the drift-pinned order of checklistRowTitles: paired, Location, phone
    // notifications, Live Mode, offline buffer.

    /// The sheet's title and subtitle, drawn as the first section's header. Never a List row: a
    /// zero-inset row in an inset-grouped section is clipped by the section's rounded corners even
    /// with a clear background, which cut the leading glyph of the first and last lines. A header
    /// is outside that clip and takes the section's own leading inset. `.textCase(nil)` keeps the
    /// lowercase-first copy as written.
    private func checklistHeader(preview: Bool, kind: BoardKind?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(renderBoardCopy(FirstRunTour.checklistTitle, kind))
                .font(ACABTheme.font(.title, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            // In a preview (checklistIsPreview) the first thing under the title says so, before
            // the subtitle's "detection is already active" can be read as a claim about now.
            if preview {
                Text(renderBoardCopy(FirstRunTour.checklistPreviewNote, kind))
                    .font(ACABTheme.font(.body, weight: .semibold))
                    .foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(renderBoardCopy(FirstRunTour.checklistSubtitle, kind))
                .font(ACABTheme.font(.body))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
        .padding(.bottom, 12)
    }

    /// What is already true: the encrypted pairing and the detectors. Both rows read ONE input,
    /// `frame`: the board's status frame, treated as absent in sample data. Sample data's canned
    /// board is no board, and with no link there is no frame (BLEManager clears `status` on a
    /// drop), so rows 1 and 2 draw a check, the paired row's firmware subtitle and the detector
    /// count only for a real, connected board that has sent its first frame. The replay before a
    /// connect and sample data therefore show no check, no subtitle and detectorsNote.
    /// TWIN: android FirstRunTour.kt ChecklistSheet (`val frame = if (demo) null else status`,
    /// `paired = frame != null`), the same rule.
    ///
    /// In the replay with no frame (checklistIsPreview) the two rows are neutral: a plain glyph
    /// and no "done" / "not yet" value, since there is no board whose state they could report.
    private var alreadyTrueSection: some View {
        let frame = ble.demoMode ? nil : ble.status
        let preview = checklistIsPreview(replay: replay, frame: frame)
        let paired = frame != nil
        let count = enabledDetectorCount(frame)
        let detectorsOn = (count ?? 0) > 0
        return Section {
            GroupedRow(title: FirstRunTour.checklistRowTitles[0],
                       subtitle: frame.map { "\($0.firmwareLabel) \u{00B7} firmware \($0.version)" }) {
                if preview { rowGlyph("lock.fill") } else { checkGlyph(paired) }
            }
            .accessibilityValue(preview ? "" : (paired ? "done" : "not yet"))
            .listRowBackground(ACABTheme.bg2)
            .listRowSeparatorTint(ACABTheme.line)
            GroupedRow(title: checklistDetectorsTitle(count: count),
                       subtitle: frame == nil
                        ? FirstRunTour.detectorsNote
                        : "trackers and network cameras are opt-in, switch them on in Beacon settings.") {
                if preview { rowGlyph("switch.2") } else { checkGlyph(detectorsOn) }
            }
            .accessibilityValue(preview ? "" : (detectorsOn ? "done" : "not yet"))
            .listRowBackground(ACABTheme.bg2)
            .listRowSeparatorTint(ACABTheme.line)
        } header: {
            checklistHeader(preview: preview, kind: ChecklistRows(ble: ble).kind)
        }
    }

    private func optionalSection(_ rows: ChecklistRows) -> some View {
        Section {
            locationRow(rows)
                .listRowBackground(ACABTheme.bg2)
                .listRowSeparatorTint(ACABTheme.line)
            navigationRow("app.badge", FirstRunTour.checklistRowTitles[2], rows.notificationDetail,
                          focus: .notifications, hint: "opens Notifications under Beacon")
                .listRowBackground(ACABTheme.bg2)
                .listRowSeparatorTint(ACABTheme.line)
            navigationRow("dot.radiowaves.left.and.right", FirstRunTour.checklistRowTitles[3],
                          rows.liveModeDetail, focus: .liveMode, hint: "opens Live Mode under Beacon")
                .listRowBackground(ACABTheme.bg2)
                .listRowSeparatorTint(ACABTheme.line)
            GroupedRow(title: FirstRunTour.checklistRowTitles[4], subtitle: rows.bufferDetail) {
                rowGlyph("externaldrive.fill")
            }
            .listRowBackground(ACABTheme.bg2)
            .listRowSeparatorTint(ACABTheme.line)
        } footer: {
            Kicker(FirstRunTour.quietSentence)
        }
    }

    // MARK: rows

    private func locationRow(_ rows: ChecklistRows) -> some View {
        let choice = finishSetupLocationChoice(isAuthorized: ble.locationAuthorized,
                                               isDenied: ble.locationDenied)
        return VStack(alignment: .leading, spacing: 8) {
            GroupedRow(title: FirstRunTour.checklistRowTitles[1], subtitle: rows.locationDetail) {
                rowGlyph("location.fill")
            }
            if let sentence = locationArmSentence(choice, kind: rows.kind) {
                Text(sentence)
                    .font(ACABTheme.font(.subheadline))
                    .foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, textInset)
            }
            if !replay {
                locationButtons(choice)
                    .padding(.leading, textInset)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// `kind` names the board in the rationale's "lets the {noun} label buffered hits" clause.
    /// The `.done` arm has no paragraph: the row's subtitle ("allowed; Map and background Live
    /// Mode are ready") already says it, and a second sentence under it said the same thing
    /// twice (HIG Writing: fewer words). Android's granted arm shows only the subtitle too. The
    /// other two arms hold the honesty lines and are unchanged.
    private func locationArmSentence(_ choice: FinishSetupLocationChoice, kind: BoardKind?) -> String? {
        switch choice {
        case .continueOrNotNow:
            return renderBoardCopy(FirstRunTour.locationRationale, kind)
        case .openSettingsOrDone:
            return "Location is off. detection still works, while background Live Mode and most pins showing where your phone heard a detection stay unavailable."
        case .done:
            return nil
        }
    }

    /// Both buttons carry `.plain`: two buttons in one List row must not share the row's tap.
    @ViewBuilder private func locationButtons(_ choice: FinishSetupLocationChoice) -> some View {
        switch choice {
        case .continueOrNotNow:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    primaryButton("Continue") { close(onContinueLocation) }
                    secondaryButton("Not Now") { close(onNotNow) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    primaryButton("Continue") { close(onContinueLocation) }
                    secondaryButton("Not Now") { close(onNotNow) }
                }
            }
        case .openSettingsOrDone:
            primaryButton("Open Settings") {
                openAppSettings()
                close(onNotNow)
            }
        case .done:
            EmptyView()
        }
    }

    /// A chevron row that closes the sheet and names the Beacon row to open. In the replay it is a
    /// plain state row: no chevron, no action.
    @ViewBuilder
    private func navigationRow(_ symbol: String, _ title: String, _ detail: String,
                               focus: BeaconFocus, hint: String) -> some View {
        if replay {
            GroupedRow(title: title, subtitle: detail) { rowGlyph(symbol) }
        } else {
            Button {
                close { onOpenBeaconRow(focus) }
            } label: {
                GroupedRow(title: title, subtitle: detail, chevron: true) { rowGlyph(symbol) }
            }
            .accessibilityHint(hint)
        }
    }

    private func rowGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(ACABTheme.font(.title3))
            .foregroundStyle(ACABTheme.tint)
            .frame(width: glyphColumn, alignment: glyphAlignment)
            .accessibilityHidden(true)
    }

    /// Filled check in tint when the fact holds, an empty circle in faint when it does not. The
    /// glyph is hidden from VoiceOver in both states: the row speaks its state through its own
    /// accessibilityValue ("done" / "not yet"), so the symbol's label is not read twice.
    private func checkGlyph(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(ACABTheme.font(.title3))
            .foregroundStyle(done ? ACABTheme.tint : ACABTheme.faint)
            .frame(width: glyphColumn, alignment: glyphAlignment)
            .accessibilityHidden(true)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(ACABTheme.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(ACABTheme.tint,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(ACABTheme.tint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Runs the host's callback, then dismisses. In the RootView host the callbacks already clear
    /// the presenting flag, so the dismiss is a no-op there; for the replay (no-op callbacks) the
    /// dismiss is what closes the sheet.
    private func close(_ then: () -> Void) {
        then()
        dismiss()
    }
}

/// Beacon > THIS <IDIOM> > System readiness: the checklist's four optional rows as status, with
/// the one Settings route.
struct ReadinessView: View {
    @EnvironmentObject private var ble: BLEManager
    /// Same token as ChecklistView's, for the same reason: notifier.mutedBySystem has no publisher.
    @State private var systemPermissionRevision = 0
    @ScaledMetric(relativeTo: .title3) private var glyphColumn: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // SwiftUI never invalidates for a @State the body does not read.
        let _ = systemPermissionRevision
        let rows = ChecklistRows(ble: ble)
        let needsSettings = finishSetupLocationChoice(isAuthorized: ble.locationAuthorized,
                                                      isDenied: ble.locationDenied) == .openSettingsOrDone
            || (!ble.demoMode && ble.notifier.mutedBySystem)
        List {
            Section {
                row("location.fill", FirstRunTour.checklistRowTitles[1], rows.locationDetail)
                row("app.badge", FirstRunTour.checklistRowTitles[2], rows.notificationDetail)
                row("dot.radiowaves.left.and.right", FirstRunTour.checklistRowTitles[3], rows.liveModeDetail)
                row("externaldrive.fill", FirstRunTour.checklistRowTitles[4], rows.bufferDetail)
            }
            if needsSettings {
                Section {
                    Button { openAppSettings() } label: {
                        Text("Open Settings")
                            .font(ACABTheme.font(.body))
                            .foregroundStyle(ACABTheme.tint)
                    }
                    .listRowBackground(ACABTheme.bg2)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ACABTheme.bg)
        .navigationTitle("System readiness")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ble.notifier.refreshAuthorization {
                systemPermissionRevision &+= 1
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        GroupedRow(title: title, subtitle: detail) {
            Image(systemName: symbol)
                .font(ACABTheme.font(.title3))
                .foregroundStyle(ACABTheme.tint)
                .frame(width: glyphColumn,
                       alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .center)
                .accessibilityHidden(true)
        }
        .listRowBackground(ACABTheme.bg2)
        .listRowSeparatorTint(ACABTheme.line)
    }
}
