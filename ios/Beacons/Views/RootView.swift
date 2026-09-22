import SwiftUI
import Combine
import UIKit

func shouldPresentSampleTour(isDemoMode: Bool, tourRequested: Bool) -> Bool {
    isDemoMode && tourRequested
}

enum OnboardingPresentation: Equatable {
    case none
    case waitForSetupHelp
    case firstRunTour
    case finishSetup
}

/// One owner chooses every first-run sheet. Finish setup wins over an unseen tour because Root
/// persists that state first; this also covers a process death between arming Finish setup and
/// marking the tour seen. An already-presented sheet blocks every other surface.
func onboardingPresentation(isSessionReady: Bool, isDemoMode: Bool,
                            hasSeenTour: Bool, finishSetupPending: Bool,
                            setupHelpPresented: Bool, tourPresented: Bool,
                            finishSetupPresented: Bool) -> OnboardingPresentation {
    guard isSessionReady, !isDemoMode else { return .none }
    guard !tourPresented, !finishSetupPresented else { return .none }
    if finishSetupPending {
        return setupHelpPresented ? .waitForSetupHelp : .finishSetup
    }
    guard !hasSeenTour else { return .none }
    return setupHelpPresented ? .waitForSetupHelp : .firstRunTour
}

func firstRunOnboardingShouldRemainActive(hasSeenTour: Bool,
                                          finishSetupPending: Bool) -> Bool {
    !hasSeenTour || finishSetupPending
}

func shouldRequestOnboardingLocation(continueChosen: Bool, isSessionReady: Bool,
                                     finishSetupWasPresented: Bool, isDemoMode: Bool,
                                     isAppActive: Bool) -> Bool {
    continueChosen && finishSetupWasPresented && isSessionReady && !isDemoMode && isAppActive
}

func realTourCompletionCanPersist(isSampleData: Bool, isSessionReady: Bool) -> Bool {
    !isSampleData && isSessionReady
}

/// Persist in the safe order: Finish setup pending first, tour seen second. Every process-death
/// point is then recoverable. Sample tours, Help replay, and a tour whose secure session vanished
/// leave both stores untouched.
@discardableResult
func persistRealTourCompletion(isSampleData: Bool, isSessionReady: Bool,
                               defaults: UserDefaults = .standard) -> Bool {
    guard realTourCompletionCanPersist(isSampleData: isSampleData,
                                       isSessionReady: isSessionReady) else { return false }
    FinishSetupOnboarding.arm(in: defaults)
    FirstRunTour.markSeen(in: defaults)
    return true
}

/// Converge the inverse interrupted-write window too. If the app died after Finish setup was armed
/// but before the tour marker landed, closing the recovered checklist repairs seen first, then
/// clears pending. A death between these writes safely presents the checklist once more.
func persistFinishSetupCompletion(defaults: UserDefaults = .standard) {
    FirstRunTour.markSeen(in: defaults)
    FinishSetupOnboarding.complete(in: defaults)
}

/// Connect screen until a board is connected, then the main tabs.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager
    /// One-time orientation, armed the first time a real board connects. Kept here (not in
    /// MainTabView) so it presents over the tabs the instant they appear, which is exactly the
    /// "I'm connected, now what?" moment new users were getting stuck at.
    @State private var showFirstRunTour = false
    @State private var tourIsSampleData = false
    @State private var showSetupHelp = false
    @State private var showFinishSetup = false
    @State private var finishSetupWasPresented = false
    @State private var requestLocationAfterSetup = false
    // Once the tab shell has existed, keep that exact instance mounted. A transient BLE dropout
    // should cover it with recovery UI, not destroy its NavigationStacks and an in-progress
    // ContributeView capture. This intentionally lasts for the process; the hidden shell is cheap
    // and retaining user-entered field work is more important than rebuilding it after reconnect.
    @State private var hasMountedMain = false
    /// Bold Text. Mirrored into TypePrefs (the observable the static font helpers read) so a
    /// change made in Settings reaches every custom-font Text without a relaunch.
    @Environment(\.legibilityWeight) private var legibilityWeight
    /// Higher contrast, mirrored into TypePrefs beside `bold`: the palette swap is a colour
    /// change, and this is what also carries it into type weight. Reading the environment (not
    /// ContrastPreference) covers both inputs at once, because the in-app switch reaches views
    /// as the same window trait the iOS setting sets.
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
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
        .sheet(isPresented: $showFirstRunTour, onDismiss: finishTourDismissed) {
            FirstRunTourView(
                isSampleData: tourIsSampleData,
                onFinish: {
                    persistRealTourCompletion(isSampleData: tourIsSampleData,
                                              isSessionReady: ble.sessionReady)
                })
        }
        .sheet(isPresented: $showSetupHelp, onDismiss: setupHelpDismissed) {
            NavigationStack {
                HelpView(
                    scrollToId: "q-setup",
                    canImproveDetection: improveDetectionAvailable(
                        isSessionReady: ble.sessionReady,
                        isDemoMode: ble.demoMode))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("close") { showSetupHelp = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFinishSetup, onDismiss: finishSetupDismissed) {
            FinishSetupView(
                onContinueLocation: {
                    requestLocationAfterSetup = true
                    showFinishSetup = false
                },
                onNotNow: {
                    showFinishSetup = false
                })
                .environmentObject(ble)
        }
        .alert("Couldn't save managed devices", isPresented: Binding(
            get: { ble.managedListPersistenceError != nil },
            set: { if !$0 { ble.dismissManagedListPersistenceError() } }
        )) {
            Button("Retry now") { ble.retryManagedListPersistence() }
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
            // stays gated through the tour and finish-setup rationale.
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

    /// Stage one of `shell`: the layout plus the two type-preference mirrors.
    private var shellMirrors: some View {
        shellLayout
            .animation(.easeInOut, value: ble.offlineSyncBanner)
            .onChange(of: colorSchemeContrast, initial: true) { (_: ColorSchemeContrast, c: ColorSchemeContrast) in
                TypePrefs.shared.highContrast = (c == .increased)
            }
            .onChange(of: legibilityWeight, initial: true) { (_: LegibilityWeight?, w: LegibilityWeight?) in
                TypePrefs.shared.bold = (w == .bold)
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
                            guard !showFirstRunTour, !showFinishSetup else { return }
                            showSetupHelp = true
                        })
                            .background(ACABTheme.bg.ignoresSafeArea())
                            .zIndex(1)
                    }
                }
            }
        }
    }

    private func routeOnboardingIfNeeded(isSessionReady: Bool) {
        switch onboardingPresentation(
            isSessionReady: isSessionReady,
            isDemoMode: ble.demoMode,
            hasSeenTour: FirstRunTour.hasSeen,
            finishSetupPending: FinishSetupOnboarding.isPending,
            setupHelpPresented: showSetupHelp,
            tourPresented: showFirstRunTour,
            finishSetupPresented: showFinishSetup) {
        case .none:
            break
        case .waitForSetupHelp:
            break
        case .firstRunTour:
            tourIsSampleData = false
            showFirstRunTour = true
        case .finishSetup:
            finishSetupWasPresented = true
            showFinishSetup = true
        }
    }

    private func setupHelpDismissed() {
        DispatchQueue.main.async {
            presentSampleTourIfNeeded()
            routeOnboardingIfNeeded(isSessionReady: ble.sessionReady)
        }
    }

    private func finishTourDismissed() {
        // Finish setup was armed before the real tour marked itself seen. Wait one run-loop turn
        // for the tour sheet to leave, then let the single router present the durable next step.
        DispatchQueue.main.async {
            routeOnboardingIfNeeded(isSessionReady: ble.sessionReady)
        }
    }

    private func finishSetupDismissed() {
        let completedPresentedSheet = finishSetupWasPresented
        finishSetupWasPresented = false
        if completedPresentedSheet {
            persistFinishSetupCompletion()
        }
        ble.setFirstRunOnboardingActive(firstRunOnboardingShouldRemainActive(
            hasSeenTour: FirstRunTour.hasSeen,
            finishSetupPending: FinishSetupOnboarding.isPending))
        let continueChosen = requestLocationAfterSetup
        requestLocationAfterSetup = false
        guard shouldRequestOnboardingLocation(
            continueChosen: continueChosen,
            isSessionReady: ble.sessionReady,
            finishSetupWasPresented: completedPresentedSheet,
            isDemoMode: ble.demoMode,
            isAppActive: UIApplication.shared.applicationState == .active) else { return }
        // Let the checklist finish dismissing before iOS presents its permission sheet. The user
        // sees the rationale first and never gets a system prompt over either onboarding surface.
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
            VStack(spacing: 8) {
                if reconnecting {
                    LinkRecoveryBannerView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if sampleData {
                    SampleDataBannerView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let summary = ble.offlineSyncBanner {
                    OfflineSyncBannerView(summary: summary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func presentSampleTourIfNeeded() {
        guard shouldPresentSampleTour(isDemoMode: ble.demoMode,
                                      tourRequested: ble.demoTourRequested),
              !showSetupHelp, !showFirstRunTour, !showFinishSetup else { return }
        tourIsSampleData = true
        showFirstRunTour = true
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

/// Sample mode is intentionally realistic, which also makes it easy to forget that no live board
/// is attached. Keep a compact escape on every tab instead of burying it at the bottom of Beacon.
private struct SampleDataBannerView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample data")
                    .font(ACABTheme.mono(11.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                Text("No live beacon is connected.")
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
            }
            Spacer(minLength: 4)
            Button("EXIT") { ble.exitDemo() }
                .font(ACABTheme.mono(10, weight: .bold)).tracking(0.7)
                .foregroundStyle(ACABTheme.accentText)
                .frame(minWidth: 54, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Exit sample data")
                .accessibilityHint("Returns to beacon setup")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Keep the app usable during a transient board dropout, especially Stop/Review in an active
/// contribution. The tab shell remains mounted underneath; this compact banner names the state
/// and retains the same escape ConnectView offered without replacing the user's navigation tree.
private struct LinkRecoveryBannerView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(ACABTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconnecting to your beacon")
                    .font(ACABTheme.mono(11.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                Text("Your open screen and capture are preserved.")
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
            }
            Spacer(minLength: 4)
            Button("STOP RECONNECTING") { ble.disconnect() }
                .font(ACABTheme.mono(9.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(ACABTheme.dim)
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }
}

/// Four-tab shell (Status, Map, Log, Device) with a frosted tab bar.
struct MainTabView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var tab: Int
    @State private var openDetectorsToken = 0
    /// The four .tag values below. An app built with the iOS 27 SDK traps when a TabView selection
    /// names a tab that is not visible, so every seed that comes from outside the body (the DEBUG
    /// -tab launch argument and the acab.pendingTab hand-off) is checked against this first.
    private static let tabTags = 0...3

    init() {
        var initial = 0
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let n = Int(args[i + 1]),
           Self.tabTags.contains(n) { initial = n }
        #endif
        _tab = State(initialValue: initial)

        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        // Dynamic UIColors, not UIColor(Color) snapshots: UIKit re-resolves these when the
        // accessibilityContrast trait changes (system Increase Contrast, or the in-app switch
        // via ContrastPreference), so the tab bar follows the palette like every SwiftUI view.
        a.backgroundColor = ACABTheme.uiTabBarBackground

        let item = UITabBarItemAppearance()
        item.normal.iconColor = ACABTheme.uiFaint
        item.normal.titleTextAttributes = [.foregroundColor: ACABTheme.uiFaint]
        item.selected.iconColor = ACABTheme.uiAccent
        item.selected.titleTextAttributes = [.foregroundColor: ACABTheme.uiAccent]
        a.stackedLayoutAppearance = item
        a.inlineLayoutAppearance = item
        a.compactInlineLayoutAppearance = item

        // has to go on UITabBar.appearance() before the view first renders
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

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
            DeviceView(openDetectorsToken: openDetectorsToken)
                .tabItem { Label("Beacon", systemImage: "cpu.fill") }.tag(3)   // label only; DeviceView identifier stays
        }
        .tint(ACABTheme.accent)
        // A New dot means "arrived since you last looked at the log": advance the seen-watermark
        // when the user LEAVES the Log tab. Opening a dossier keeps the selection on tag 2, so
        // this only fires on a real tab switch, never when drilling into a row. Mirrors Android's
        // Tab.LOG onDispose in MainScreen.
        .onChange(of: tab) { old, new in
            if old == 2 && new != 2 { ble.markAllSeen() }
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
        // A dossier's "OPEN IN MAP" tap: switch to the Map tab. MapTabView picks up
        // the stashed coordinate itself (see MapFocus in MapTabView.swift).
        .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
            tab = 1
        }
        // A Status category tile tap: switch to the Log tab. DetectionsView consumes the
        // stashed category itself (see LogFocus in DetectionsView.swift).
        .onReceive(NotificationCenter.default.publisher(for: LogFocus.notification)) { _ in
            tab = 2
        }
    }
}

/// Transient, dismissible banner announcing how many detections the board buffered while
/// the phone was away. "view" deep-links to the Log tab's NEW lens via the same mechanism
/// the Live Activity uses; the x just clears it. One-shot, never persisted across launches.
struct OfflineSyncBannerView: View {
    let summary: OfflineSyncSummary
    @EnvironmentObject var ble: BLEManager

    private var message: String {
        // The unreplayed clause discloses this attempt's shortfall, not permanent loss. Current
        // firmware leaves an over-MTU row uncommitted in the ring so a later larger-MTU/corrected
        // attempt can retry it. Keep the present-attempt copy byte-identical to Android's banner.
        let noun = summary.count == 1 ? "detection" : "detections"
        if summary.count == 0 && summary.unreplayed > 0 {
            let bnoun = summary.unreplayed == 1 ? "detection" : "detections"
            return "\(summary.unreplayed) buffered \(bnoun) couldn't be replayed from the beacon"
        }
        if summary.unreplayed > 0 {
            return "\(summary.count) \(noun) recorded while you were away"
                + " (\(summary.unreplayed) more couldn't be replayed)"
        }
        return "\(summary.count) \(noun) recorded while you were away"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ACABTheme.accent)
            Text(message)
                .font(ACABTheme.mono(11.5))
                .foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(action: viewNew) {
                Text("view")
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.onAccent)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(ACABTheme.accent, in: Capsule())
                    // 44pt hit target around the 30pt capsule; the drawn pill is unchanged.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { ble.clearOfflineSyncBanner() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ACABTheme.dim)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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
