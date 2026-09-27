import SwiftUI
import Combine
import UIKit

func shouldPresentSampleTour(isDemoMode: Bool, tourRequested: Bool) -> Bool {
    isDemoMode && tourRequested
}

enum OnboardingPresentation: Equatable {
    case none
    case waitForSetupHelp
    case checklist
}

/// One owner chooses the post-connect checklist. Nothing before encrypted readiness, nothing in
/// sample data, nothing while the checklist is already up, and it waits behind setup help. The
/// sample tour is not an input: it is presented only in sample data, which returns .none first.
func onboardingPresentation(isSessionReady: Bool, isDemoMode: Bool,
                            hasSeenTour: Bool, finishSetupPending: Bool,
                            setupHelpPresented: Bool, checklistPresented: Bool) -> OnboardingPresentation {
    guard isSessionReady, !isDemoMode, !checklistPresented else { return .none }
    guard firstRunOnboardingShouldRemainActive(hasSeenTour: hasSeenTour,
                                               finishSetupPending: finishSetupPending) else { return .none }
    return setupHelpPresented ? .waitForSetupHelp : .checklist
}

/// True until the checklist completes. Seen is the checklist's marker; pending is the
/// pre-checklist build's Finish setup key, so a user it left mid-onboarding still gets the
/// checklist once. Gates automatic Live Mode and the Location request (setFirstRunOnboardingActive).
func firstRunOnboardingShouldRemainActive(hasSeenTour: Bool,
                                          finishSetupPending: Bool) -> Bool {
    !hasSeenTour || finishSetupPending
}

/// `finishSetupWasPresented` means "the checklist was presented"; the name is kept so the
/// signature and its test stay as they are.
func shouldRequestOnboardingLocation(continueChosen: Bool, isSessionReady: Bool,
                                     finishSetupWasPresented: Bool, isDemoMode: Bool,
                                     isAppActive: Bool) -> Bool {
    continueChosen && finishSetupWasPresented && isSessionReady && !isDemoMode && isAppActive
}

func checklistCompletionCanPersist(isReplay: Bool, isDemoMode: Bool, isSessionReady: Bool) -> Bool {
    !isReplay && !isDemoMode && isSessionReady
}

/// Completion writes seen, then clears pending. Both orders end in the same state; the order only
/// matters for a process death between the two writes. This build never arms pending, so for a
/// fresh install that death leaves seen = true and no pending key, and the checklist does not
/// return. A pre-checklist upgrader whose pending key was set sees it once more, which keeps the
/// Live Mode and Location gate held rather than releasing it without the rationale. Replay, sample
/// data and a session that lost readiness write nothing. RootView is the only production caller
/// and passes isReplay: false; the input keeps the replay rule in the tested policy.
@discardableResult
func persistChecklistCompletion(isReplay: Bool, isDemoMode: Bool, isSessionReady: Bool,
                                defaults: UserDefaults = .standard) -> Bool {
    guard checklistCompletionCanPersist(isReplay: isReplay, isDemoMode: isDemoMode,
                                        isSessionReady: isSessionReady) else { return false }
    FirstRunTour.markSeen(in: defaults)
    FinishSetupOnboarding.complete(in: defaults)
    return true
}

/// How a pinned banner (reconnect, sample data, offline sync) enters and leaves. The slide moves
/// on the y-axis on every reconnect, so Reduce Motion replaces it with a fade, as the HIG asks
/// ("Replacing transitions in x-, y-, and z-axes with fades to avoid motion").
enum PinnedBannerMotion: Equatable {
    case slideFromTop
    case fade

    var transition: AnyTransition {
        switch self {
        case .slideFromTop: return .move(edge: .top).combined(with: .opacity)
        case .fade:         return .opacity
        }
    }
}

func pinnedBannerMotion(reduceMotion: Bool) -> PinnedBannerMotion {
    reduceMotion ? .fade : .slideFromTop
}

/// Connect screen until a board is connected, then the main tabs.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager
    /// The post-connect checklist, presented over the tabs the instant a real session is ready (the
    /// "I'm connected, now what?" moment). Kept here, not in MainTabView, so it covers the tabs.
    @State private var showChecklist = false
    /// The non-persisting sample-data tour (sample data only).
    @State private var showSampleTour = false
    @State private var showSetupHelp = false
    @State private var checklistWasPresented = false
    @State private var requestLocationAfterSetup = false
    /// A checklist chevron's Beacon row, posted only after the sheet is gone and completed.
    @State private var pendingBeaconFocus: BeaconFocus?
    // Once the tab shell has existed, keep that exact instance mounted. A transient BLE dropout
    // should cover it with recovery UI, not destroy its NavigationStacks and an in-progress
    // ContributeView capture. This intentionally lasts for the process; the hidden shell is cheap
    // and retaining user-entered field work is more important than rebuilding it after reconnect.
    @State private var hasMountedMain = false
    /// Higher contrast, mirrored into TypePrefs (the observable the font helpers read): the
    /// palette swap is a colour change, and this is what also carries it into type weight.
    /// Reading the environment (not ContrastPreference) covers both inputs at once, because the
    /// in-app switch reaches views as the same window trait the iOS setting sets.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// Reduce Motion swaps the pinned banners' slide-in for a fade (pinnedBannerMotion).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hasUsableSession: Bool {
        (ble.sessionReady && ble.connectionState == .connected)
            || (ble.demoMode && ble.connectionState == .connected)
    }
    private var mainIsUsable: Bool {
        // An OTA reboot drops sessionReady, but the update progress UI lives in the shell;
        // falling to ConnectView's scan panel mid-update would invite a racing second connect.
        hasUsableSession || (hasMountedMain && (ble.isReconnecting || ble.isRebootingForUpdate))
    }
    /// THE LAST HOME THE RESTORE OFFER WAS MISSING. Every other surface that carries it lives on
    /// the Beacon screen, and `mainIsUsable` false means the tab shell was never mounted or is
    /// mounted with its opacity at zero, its hit testing off and its accessibility hidden, so
    /// DeviceView is not reachable: the board ended Desert, the user came back with the board off
    /// or gone, and alerts stayed silent with nothing on screen and no way out of it. RootView is
    /// the only view composed in BOTH states, which is why the decision is taken here and handed
    /// down rather than made inside ConnectView (where the shell is false by construction).
    ///
    /// ONE screen reads it here, where Android has two: `mainIsUsable` stays true through an OTA
    /// reboot (it takes `isRebootingForUpdate`), so the shell keeps carrying the offer for that
    /// whole window, while AcabApp parks its shell behind a locked wait screen and draws the panel
    /// on that screen as well. Android twin: the same call in AcabApp.kt, above its early returns.
    private var connectScreenCarriesRestore: Bool {
        desertRestoreNeedsPreConnectSurface(
            restoreOffered: alertRestoreIsOffered(isDemoMode: ble.demoMode,
                                                  pending: ble.pendingAlertModeRestore),
            mainShellVisible: mainIsUsable)
    }

    // ONE chain was too much for Xcode 26.6: the whole body (the shell below plus every sheet,
    // alert and lifecycle hook) was a single expression, and adding the higher-contrast mirror
    // tipped it into "unable to type-check this expression in reasonable time" on the CI
    // runner while Xcode 27 still managed (~400 ms locally). Keep the halves separate, and put a
    // new modifier on whichever half it belongs to instead of regrowing one chain.
    var body: some View {
        shell
        .sheet(isPresented: $showSampleTour) { FirstRunTourView() }
        .sheet(isPresented: $showSetupHelp, onDismiss: setupHelpDismissed) {
            NavigationStack {
                HelpView(
                    scrollToId: "q-setup",
                    canImproveDetection: improveDetectionAvailable(
                        isSessionReady: ble.sessionReady,
                        isDemoMode: ble.demoMode))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showSetupHelp = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showChecklist, onDismiss: checklistDismissed) { checklistSheet }
        .alert("Couldn't save managed devices", isPresented: Binding(
            get: { ble.managedListPersistenceError != nil },
            set: { if !$0 { ble.dismissManagedListPersistenceError() } }
        )) {
            Button("Retry Now") { ble.retryManagedListPersistence() }
            Button("OK", role: .cancel) { ble.dismissManagedListPersistenceError() }
        } message: {
            Text(ble.managedListPersistenceError ?? "The managed-device change has not been saved yet.")
        }
        // The pending flags below live in UserDefaults, which survives process death: a tap
        // that landed on ConnectView in a session that never connected would otherwise replay
        // DAYS later, jumping an unrelated launch to the Log tab with the NEW filter armed
        // (Android guards the same replay via removeExtra + the LAUNCHED_FROM_HISTORY check).
        // Clear both on launch, before onOpenURL can re-set them, so a tap only ever seeds
        // the session it arrived in. RootView appears exactly once per process.
        .onAppear {
            // Default true keeps cold-launch reconciliation safe until Root has decided whether
            // first-run onboarding is due. Returning users release immediately; a first-time user
            // stays gated until the checklist closes.
            ble.setFirstRunOnboardingActive(firstRunOnboardingShouldRemainActive(
                hasSeenTour: FirstRunTour.hasSeen,
                finishSetupPending: FinishSetupOnboarding.isPending))
            if hasUsableSession { hasMountedMain = true }
            routeOnboardingIfNeeded(isSessionReady: ble.sessionReady)
            presentSampleTourIfNeeded()
            UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
            UserDefaults.standard.removeObject(forKey: "acab.pendingTab")
        }
        // Live Mode Live Activity taps (Lock Screen + Dynamic Island) arrive as
        // beacons://log/new. This handler lives on RootView (always mounted), NOT
        // MainTabView, so a tap on cold launch or while ConnectView is showing isn't
        // dropped: the pending flags seed the tabs when they mount, and the
        // notification switches an already-mounted MainTabView immediately.
        .onOpenURL { url in
            guard url.scheme == "beacons", url.host == "log" else { return }
            if url.lastPathComponent == "new" {
                UserDefaults.standard.set(true, forKey: "acab.pendingNewFilter")
                UserDefaults.standard.set(2, forKey: "acab.pendingTab")
                NotificationCenter.default.post(name: Notification.Name("acabOpenLogNew"), object: nil)
            }
        }
    }

    /// The tab shell or connect screen, the banners above them, and the state mirrors and
    /// onboarding triggers that ride on them. `body` adds the sheets, the alert and the launch hooks.
    ///
    /// STAGED, AND THE CLOSURES ARE TYPED, ON PURPOSE. Xcode 26.6 (the gating CI lane) still gave
    /// up on this half as one chain after `body` was split: five overloaded `onChange` calls and two
    /// `animation(_:value:)` calls with untyped closures in a single expression, where Xcode 27 took
    /// ~80 ms. Each stage below is its own expression with at most three of them, and every
    /// `onChange` closure names its parameter types, so the old solver has no overloads to search.
    /// Modifier order is exactly what the single chain had.
    private var shell: some View {
        shellMirrors
            .preferredColorScheme(.dark)
            .animation(.easeInOut, value: ble.connectionState)
            // Mount sample data at its synthetic connected boundary. A real session is mounted by the
            // explicit encrypted-readiness publication below, not early transport state.
            .onChange(of: ble.connectionState) { (_: BLEConnectionState, new: BLEConnectionState) in
                if new == .connected, ble.demoMode {
                    hasMountedMain = true
                }
            }
            .onChange(of: ble.sessionReady) { (_: Bool, ready: Bool) in
                if ready {
                    hasMountedMain = true
                }
                // A link drop takes the checklist down with it: the sheet belongs to a ready
                // session, and left up it would float over the reconnect or connect screen.
                // checklistDismissed then persists nothing (the session is no longer ready) and
                // posts no Beacon row focus, so the router reopens the sheet on the next ready
                // session. TWIN: android AcabApp composes ChecklistSheet only under
                // ConnState.READY, and its ChecklistSheet KDoc says a close cut short by the sheet
                // leaving composition completes nothing.
                if !ready && showChecklist { showChecklist = false }
                routeOnboardingIfNeeded(isSessionReady: ready)
            }
            // Sample data gets the same orientation every time it is entered, but completing or
            // skipping that tour must never consume the one-time real-board onboarding marker.
            .onChange(of: ble.demoMode) { (_: Bool, isSample: Bool) in
                if isSample {
                    presentSampleTourIfNeeded()
                } else {
                    routeOnboardingIfNeeded(isSessionReady: ble.sessionReady)
                }
            }
    }

    /// Stage one of `shell`: the layout plus the higher-contrast type-preference mirror.
    private var shellMirrors: some View {
        shellLayout
            .animation(.easeInOut, value: ble.offlineSyncBanner)
            .onChange(of: colorSchemeContrast, initial: true) { (_: ColorSchemeContrast, c: ColorSchemeContrast) in
                TypePrefs.shared.highContrast = (c == .increased)
            }
    }

    /// The banners over either the tab shell or the connect screen, with no modifiers.
    private var shellLayout: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBanners
                ZStack {
                    if hasMountedMain || hasUsableSession {
                        connectedContent
                            .opacity(mainIsUsable ? 1 : 0)
                            .allowsHitTesting(mainIsUsable)
                            .accessibilityHidden(!mainIsUsable)
                    }
                    if !mainIsUsable {
                        ConnectView(showAlertRestore: connectScreenCarriesRestore,
                                    onOpenSetupHelp: {
                            guard !showSampleTour, !showChecklist else { return }
                            showSetupHelp = true
                        })
                            .background(ACABTheme.bg.ignoresSafeArea())
                            .zIndex(1)
                    }
                }
            }
        }
    }

    /// The checklist sheet's content, its own property so `body` keeps a short chain (Xcode 26.6
    /// type-check budget). The closure parameter is typed on purpose, as in `shell`.
    private var checklistSheet: some View {
        ChecklistView(
            replay: false,
            onContinueLocation: {
                requestLocationAfterSetup = true
                showChecklist = false
            },
            onNotNow: {
                showChecklist = false
            },
            onOpenBeaconRow: { (focus: BeaconFocus) in
                pendingBeaconFocus = focus
                showChecklist = false
            })
            .environmentObject(ble)
    }

    private func routeOnboardingIfNeeded(isSessionReady: Bool) {
        switch onboardingPresentation(
            isSessionReady: isSessionReady,
            isDemoMode: ble.demoMode,
            hasSeenTour: FirstRunTour.hasSeen,
            finishSetupPending: FinishSetupOnboarding.isPending,
            setupHelpPresented: showSetupHelp,
            checklistPresented: showChecklist) {
        case .none, .waitForSetupHelp:
            break
        case .checklist:
            checklistWasPresented = true
            showChecklist = true
        }
    }

    private func setupHelpDismissed() {
        DispatchQueue.main.async {
            presentSampleTourIfNeeded()
            routeOnboardingIfNeeded(isSessionReady: ble.sessionReady)
        }
    }

    private func checklistDismissed() {
        let completedPresentedSheet = checklistWasPresented
        checklistWasPresented = false
        var completionPersisted = false
        if completedPresentedSheet {
            completionPersisted = persistChecklistCompletion(isReplay: false, isDemoMode: ble.demoMode,
                                                             isSessionReady: ble.sessionReady)
        }
        ble.setFirstRunOnboardingActive(firstRunOnboardingShouldRemainActive(
            hasSeenTour: FirstRunTour.hasSeen,
            finishSetupPending: FinishSetupOnboarding.isPending))
        // A chevron closed the sheet: switch to its Beacon row only now, after completion and
        // release, and only when that completion persisted. A close that completed nothing (the
        // link dropped under the sheet) leaves the tab shell hidden behind the connect screen, so
        // a focus posted to it would land on a page nobody can see.
        if let focus = pendingBeaconFocus {
            pendingBeaconFocus = nil
            if completionPersisted {
                BeaconFocus.pending = focus
                NotificationCenter.default.post(name: BeaconFocus.notification, object: nil)
            }
        }
        let continueChosen = requestLocationAfterSetup
        requestLocationAfterSetup = false
        guard shouldRequestOnboardingLocation(
            continueChosen: continueChosen,
            isSessionReady: ble.sessionReady,
            finishSetupWasPresented: completedPresentedSheet,
            isDemoMode: ble.demoMode,
            isAppActive: UIApplication.shared.applicationState == .active) else { return }
        // Let the checklist finish dismissing before iOS presents its permission sheet. The user
        // sees the rationale first and never gets a system prompt over the checklist.
        DispatchQueue.main.async {
            guard shouldRequestOnboardingLocation(
                continueChosen: true,
                isSessionReady: ble.sessionReady,
                finishSetupWasPresented: completedPresentedSheet,
                isDemoMode: ble.demoMode,
                isAppActive: UIApplication.shared.applicationState == .active) else { return }
            ble.requestLocationAccessIfNeeded()
        }
    }

    /// Reconnect / sample / replay banners. Lives on RootView (always mounted) so a banner is
    /// seen no matter which tab is up when the board finishes replaying its buffer. They STACK
    /// rather than replace each other: a reconnect must not swallow "N detections replayed while
    /// you were away".
    ///
    /// Real layout space above the shell, NOT the `.safeAreaInset(edge: .top)` this used to be.
    /// The tab shell is a UIKit-backed TabView, and it re-derives its pages' safe area from the
    /// window, so an ancestor's additional inset never reached a tab: the banner drew straight
    /// over every screen's title, and over the back chevron of a pushed dossier (whose own top
    /// bar sits at the same height), which left sample data with no visible way back out of a
    /// detection. TWIN: android MainScreen.kt, whose banner stack is now the first child of a
    /// Column above the shell AND above the full-screen dossier, for the same reason and after
    /// the same bug (a reconnect banner swallowing the dossier's back control). There the top
    /// banner carries the status-bar inset and the content below consumes it; here the VStack
    /// is simply outside the shell's safe area, so no inset bookkeeping is needed.
    @ViewBuilder private var topBanners: some View {
        let reconnecting = hasMountedMain && ble.isReconnecting
        let sampleData = hasMountedMain && ble.demoMode
        if reconnecting || sampleData || ble.offlineSyncBanner != nil {
            let transition = pinnedBannerMotion(reduceMotion: reduceMotion).transition
            VStack(spacing: 8) {
                if reconnecting {
                    LinkRecoveryBannerView()
                        .transition(transition)
                }
                if sampleData {
                    SampleDataBannerView()
                        .transition(transition)
                }
                if let summary = ble.offlineSyncBanner {
                    OfflineSyncBannerView(summary: summary)
                        .transition(transition)
                }
            }
            .padding(.horizontal, ACABTheme.pad)
            .padding(.bottom, 8)
        }
    }

    private func presentSampleTourIfNeeded() {
        guard shouldPresentSampleTour(isDemoMode: ble.demoMode,
                                      tourRequested: ble.demoTourRequested),
              !showSetupHelp, !showSampleTour, !showChecklist else { return }
        showSampleTour = true
    }

    @ViewBuilder private var connectedContent: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-detail"),
           let d = ble.detections.max(by: { $0.rssi < $1.rssi }) {
            NavigationStack { DetectionDetailView(detection: d) }
        } else {
            MainTabView()
        }
        #else
        MainTabView()
        #endif
    }
}

/// The sample banner's words, one message and one button, identical on both apps. TWIN: Android
/// MainScreen.kt `SAMPLE_BANNER_MESSAGE` / `SAMPLE_BANNER_EXIT_LABEL`. Sample tour card 3 names
/// the same control ("an Exit Sample Data banner stays at the top of the app"). The button is
/// Title Case like every other button, and the message is Title Case too (owner, 2026-09-25): it
/// is the banner's name for the mode, read as a label beside its button, not body copy.
let sampleBannerMessage = "Sample Data, Not Nearby Devices"
let sampleBannerExitLabel = "Exit Sample Data"

/// Sample mode is intentionally realistic, which also makes it easy to forget that no live board
/// is attached. Keep a compact escape on every tab instead of burying it at the bottom of Beacon.
private struct SampleDataBannerView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes a side glyph and the button column squeezed the text to
                // one short word per line. Stack instead, as LinkRecoveryBannerView does: the
                // message at full width, wrapping instead of truncating, then the button on its
                // own trailing row.
                VStack(alignment: .leading, spacing: 4) {
                    message.fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        exitButton
                    }
                }
            } else {
                // One row when the message and the button fit side by side; otherwise the button
                // drops to its own trailing row under the message.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        glyph
                        message
                        Spacer(minLength: 4)
                        exitButton
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            glyph
                            message.fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Spacer(minLength: 0)
                            exitButton
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .accessibilityElement(children: .contain)
        // Pinned above every tab and never scrolls away (a fixed VStack cell, not an inset), so
        // its type stops at accessibility2: persistent chrome must leave the tab its screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var glyph: some View {
        Image(systemName: "sparkles")
            .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.tint)
            .accessibilityHidden(true)
    }

    private var message: some View {
        Text(sampleBannerMessage)
            .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.text)
    }

    private var exitButton: some View {
        Button(sampleBannerExitLabel) { ble.exitDemo() }
            .font(ACABTheme.font(.subheadline, weight: .semibold))
            .foregroundStyle(ACABTheme.tint)
            .frame(minWidth: 54, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Exit Sample Data")
            .accessibilityHint("Returns to beacon setup")
    }
}

/// Keep the app usable during a transient board dropout, especially Stop/Review in an active
/// contribution. The tab shell remains mounted underneath; this compact banner names the state
/// and retains the same escape ConnectView offered without replacing the user's navigation tree.
private struct LinkRecoveryBannerView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Same reason as SampleDataBannerView: at accessibility sizes the long button
                // column squeezed the text to a word per line. Stack the text at full width, then
                // the button on its own trailing row.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ProgressView().controlSize(.small).tint(ACABTheme.tint)
                        title.fixedSize(horizontal: false, vertical: true)
                    }
                    subtitle.fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        stopButton
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(ACABTheme.tint)
                    VStack(alignment: .leading, spacing: 2) { title; subtitle }
                    Spacer(minLength: 4)
                    stopButton
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .accessibilityElement(children: .contain)
        // Pinned above every tab like the sample banner, so the same accessibility2 type cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// Names the board that dropped (BLEManager.targetKind: the reconnect target, whose kind was
    /// carried from the live session before its status frame was cleared). Lowercase-first, one
    /// template, ConnectCopy.reconnectBannerTitle. TWIN: Android MainScreen.kt
    /// RECONNECT_BANNER_TITLE_TEMPLATE, byte-identical.
    private var title: some View {
        Text(renderBoardCopy(ConnectCopy.reconnectBannerTitle, ble.targetKind))
            .font(ACABTheme.font(.subheadline, weight: .semibold)).foregroundStyle(ACABTheme.text)
    }

    private var subtitle: some View {
        Text(ConnectCopy.reconnectBannerSubtitle)
            .font(ACABTheme.font(.footnote)).foregroundStyle(ACABTheme.dim)
    }

    private var stopButton: some View {
        Button("Stop Reconnecting") { ble.disconnect() }
            .font(ACABTheme.font(.footnote, weight: .semibold))
            .foregroundStyle(ACABTheme.dim)
            .frame(minHeight: 44)
    }
}

/// Does leaving the Log tab advance the seen watermark? Outside sample data, yes: a New dot means
/// "arrived since you last looked". In sample data, no: the seed's baseline (the rows it flags new)
/// stays until the user taps Mark Seen. TWIN: Android MainScreen's Tab.LOG `openedInDemo` gate.
func logTabLeaveMarksSeen(isDemoMode: Bool) -> Bool { !isDemoMode }

/// Four-tab shell (Status, Map, Log, Beacon) on the system tab bar; selected colour from .tint.
struct MainTabView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var tab: Int
    @State private var openDetectorsToken = 0
    // The setup checklist's two Beacon chevrons (Phone notifications, Live Mode); see openBeaconFocus.
    @State private var openNotifyToken = 0
    @State private var openLiveModeToken = 0
    /// The four .tag values below. An app built with the iOS 27 SDK traps when a TabView selection
    /// names a tab that is not visible, so every seed that comes from outside the body (the DEBUG
    /// -tab launch argument and the acab.pendingTab hand-off) is checked against this first.
    private static let tabTags = 0...3

    init() { _tab = State(initialValue: Self.launchTab ?? 0) }

    /// DEBUG `-tab N` launch argument, parsed once per process: this init runs on every RootView
    /// body pass (~3 Hz while detections flow) because connectedContent constructs MainTabView() inline.
    private static let launchTab: Int? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let n = Int(args[i + 1]),
           tabTags.contains(n) { return n }
        #endif
        return nil
    }()

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(onOpenDetectors: {
                openDetectorsToken += 1
                tab = 3
            })
                .tabItem { Label("Status", systemImage: "scope") }.tag(0)
            MapTabView()
                .tabItem { Label("Map", systemImage: "map.fill") }.tag(1)
            DetectionsView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle.fill") }.tag(2)
            DeviceView(openDetectorsToken: openDetectorsToken, openNotifyToken: openNotifyToken,
                       openLiveModeToken: openLiveModeToken)
                .tabItem { Label("Beacon", systemImage: "cpu.fill") }.tag(3)   // label only; DeviceView identifier stays
        }
        .tint(ACABTheme.tint)
        // A New dot means "arrived since you last looked at the log": advance the seen-watermark
        // when the user LEAVES the Log tab. Opening a dossier keeps the selection on tag 2, so
        // this only fires on a real tab switch, never when drilling into a row. Mirrors Android's
        // Tab.LOG onDispose in MainScreen. Never in sample data (logTabLeaveMarksSeen): the sample
        // log keeps the seed's own baseline until the user taps Mark Seen.
        .onChange(of: tab) { (old: Int, new: Int) in
            if old == 2 && new != 2 && logTabLeaveMarksSeen(isDemoMode: ble.demoMode) {
                ble.markAllSeen()
            }
        }
        // Cold path: a Live Activity tap landed before we mounted (cold launch, or
        // ConnectView was up). RootView parked the target tab in this flag; consume it.
        .onAppear {
            if let pending = UserDefaults.standard.object(forKey: "acab.pendingTab") as? Int {
                UserDefaults.standard.removeObject(forKey: "acab.pendingTab")
                if Self.tabTags.contains(pending) { tab = pending }
            }
        }
        // Warm path: already mounted when the tap arrived; RootView's onOpenURL posts
        // this so we switch right away. DetectionsView arms the NEW filter itself.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("acabOpenLogNew"))) { _ in
            UserDefaults.standard.removeObject(forKey: "acab.pendingTab")
            tab = 2
        }
        // A dossier's "Open in Map" tap: switch to the Map tab. MapTabView picks up
        // the stashed coordinate itself (see MapFocus in MapTabView.swift).
        .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
            tab = 1
        }
        // A Status category tile tap: switch to the Log tab. DetectionsView consumes the
        // stashed category itself (see LogFocus in DetectionsView.swift).
        .onReceive(NotificationCenter.default.publisher(for: LogFocus.notification)) { _ in
            tab = 2
        }
        // A checklist chevron (Phone notifications / Live Mode): switch to the Beacon tab, which
        // selects THIS <IDIOM> and pushes the row itself (see BeaconFocus in SettingsView.swift).
        // checklistDismissed posts this only after the sheet is gone.
        .onReceive(NotificationCenter.default.publisher(for: BeaconFocus.notification)) { (_: Notification) in
            openBeaconFocus()
        }
    }

    /// Consume the one pending BeaconFocus request exactly once: bump the matching token (DeviceView
    /// handles it like openDetectorsToken) and select the Beacon tab.
    private func openBeaconFocus() {
        guard let focus = BeaconFocus.pending else { return }
        BeaconFocus.pending = nil
        switch focus {
        case .notifications: openNotifyToken += 1
        case .liveMode:      openLiveModeToken += 1
        }
        tab = 3
    }
}

/// The offline-sync banner's line: `count` records were replayed, `unreplayed` the board promised
/// but did not send; `kind` is the board that buffered them (nil reads as beacon). The unreplayed
/// clause discloses this attempt's shortfall, not permanent loss. Current firmware leaves an
/// over-MTU row uncommitted in the ring so a later larger-MTU/corrected attempt can retry it.
/// Only the all-unreplayed arm names the board. TWIN: Android MainScreen.kt offlineSyncMessage,
/// byte-identical.
func offlineSyncMessage(count: Int, unreplayed: Int, kind: BoardKind?) -> String {
    let noun = count == 1 ? "detection" : "detections"
    if count == 0 && unreplayed > 0 {
        let bnoun = unreplayed == 1 ? "detection" : "detections"
        return renderBoardCopy("\(unreplayed) buffered \(bnoun) couldn't be replayed from the {noun}",
                               kind)
    }
    if unreplayed > 0 {
        return "\(count) \(noun) recorded while you were away"
            + " (\(unreplayed) more couldn't be replayed)"
    }
    return "\(count) \(noun) recorded while you were away"
}

/// Transient, dismissible banner announcing how many detections the board buffered while
/// the phone was away. "View" deep-links to the Log tab's NEW lens via the same mechanism
/// the Live Activity uses; the x just clears it. One-shot, never persisted across launches.
struct OfflineSyncBannerView: View {
    let summary: OfflineSyncSummary
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Names the board that buffered the rows (BLEManager.connectedKind).
    private var message: String {
        offlineSyncMessage(count: summary.count, unreplayed: summary.unreplayed,
                           kind: ble.connectedKind)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Same reason as SampleDataBannerView: at accessibility sizes the glyph, the pill
                // and the dismiss button squeezed the message to a narrow column. Stack the
                // message at full width, then the two buttons on their own trailing row.
                VStack(alignment: .leading, spacing: 4) {
                    messageText
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        viewButton
                        dismissButton
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(ACABTheme.font(.subheadline, weight: .semibold))
                        .foregroundStyle(ACABTheme.tint)
                    messageText
                    Spacer(minLength: 6)
                    viewButton
                    dismissButton
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        // Pinned above every tab like the other two banners, so the same accessibility2 type cap.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var messageText: some View {
        Text(message)
            .font(ACABTheme.font(.subheadline))
            .foregroundStyle(ACABTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var viewButton: some View {
        Button(action: viewNew) {
            // A custom pill, not .borderedProminent: that draws white on the tint, which is
            // far under AA; onAccent on tint is pinned by ContrastPaletteTests.
            Text("View")
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(ACABTheme.onAccent)
                // A floor, not a fixed height: at large type the label is taller than 30pt, and a
                // fixed capsule left the onAccent ink outside the tint fill.
                .padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: 30)
                .background(ACABTheme.tint, in: Capsule())
                // 44pt hit target around the 30pt capsule; the drawn pill is unchanged.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dismissButton: some View {
        Button { ble.clearOfflineSyncBanner() } label: {
            Image(systemName: "xmark")
                .font(ACABTheme.font(.footnote, weight: .bold))
                .foregroundStyle(ACABTheme.dim)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    /// Reuse the Live-Activity deep-link path: park the NEW filter + Log tab, then post the
    /// switch notification. RootView/MainTabView + DetectionsView already consume these.
    private func viewNew() {
        UserDefaults.standard.set(true, forKey: "acab.pendingNewFilter")
        UserDefaults.standard.set(2, forKey: "acab.pendingTab")
        NotificationCenter.default.post(name: Notification.Name("acabOpenLogNew"), object: nil)
        ble.clearOfflineSyncBanner()
    }
}
