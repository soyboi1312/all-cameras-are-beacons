import SwiftUI
import Combine

/// Connect screen until a board is connected, then the main tabs.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager
    /// One-time orientation, armed the first time a real board connects. Kept here (not in
    /// MainTabView) so it presents over the tabs the instant they appear, which is exactly the
    /// "I'm connected, now what?" moment new users were getting stuck at.
    @State private var showFirstRunTour = false

    var body: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            if ble.connectionState == .connected {
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
            } else {
                ConnectView()
            }
        }
        // Reconnect "black box" count banner. Lives on RootView (always mounted) so it's
        // seen no matter which tab is up when the board finishes replaying its buffer.
        .overlay(alignment: .top) {
            if let summary = ble.offlineSyncBanner {
                OfflineSyncBannerView(summary: summary)
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: ble.offlineSyncBanner)
        .preferredColorScheme(.dark)
        .animation(.easeInOut, value: ble.connectionState)
        // Arm on the first REAL connection only: demo mode has its own guided framing, and firing
        // the tour over sample data would spend the one-time moment on a fake board.
        .onChange(of: ble.connectionState) { _, new in
            if new == .connected, !ble.demoMode, !FirstRunTour.hasSeen { showFirstRunTour = true }
        }
        .sheet(isPresented: $showFirstRunTour) { FirstRunTourView() }
        // The pending flags below live in UserDefaults, which survives process death: a tap
        // that landed on ConnectView in a session that never connected would otherwise replay
        // DAYS later, jumping an unrelated launch to the Log tab with the NEW filter armed
        // (Android guards the same replay via removeExtra + the LAUNCHED_FROM_HISTORY check).
        // Clear both on launch, before onOpenURL can re-set them, so a tap only ever seeds
        // the session it arrived in. RootView appears exactly once per process.
        .onAppear {
            UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
            UserDefaults.standard.removeObject(forKey: "acab.pendingTab")
        }
        // Drive Mode Live Activity taps (Lock Screen + Dynamic Island) arrive as
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
}

/// Four-tab shell (Status, Map, Log, Device) with a frosted tab bar.
struct MainTabView: View {
    @State private var tab: Int

    init() {
        var initial = 0
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let n = Int(args[i + 1]) { initial = n }
        #endif
        _tab = State(initialValue: initial)

        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        a.backgroundColor = UIColor(red: 18/255, green: 12/255, blue: 14/255, alpha: 0.74)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = UIColor(ACABTheme.faint)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(ACABTheme.faint)]
        item.selected.iconColor = UIColor(ACABTheme.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(ACABTheme.accent)]
        a.stackedLayoutAppearance = item
        a.inlineLayoutAppearance = item
        a.compactInlineLayoutAppearance = item

        // has to go on UITabBar.appearance() before the view first renders
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Status", systemImage: "scope") }.tag(0)
            MapTabView()
                .tabItem { Label("Map", systemImage: "map.fill") }.tag(1)
            DetectionsView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle.fill") }.tag(2)
            DeviceView()
                .tabItem { Label("Device", systemImage: "cpu.fill") }.tag(3)
        }
        .tint(ACABTheme.accent)
        // Cold path: a Live Activity tap landed before we mounted (cold launch, or
        // ConnectView was up). RootView parked the target tab in this flag; consume it.
        .onAppear {
            if let pending = UserDefaults.standard.object(forKey: "acab.pendingTab") as? Int {
                UserDefaults.standard.removeObject(forKey: "acab.pendingTab")
                tab = pending
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
    }
}

/// Transient, dismissible banner announcing how many detections the board buffered while
/// the phone was away. "view" deep-links to the Log tab's NEW lens via the same mechanism
/// the Live Activity uses; the x just clears it. One-shot, never persisted across launches.
struct OfflineSyncBannerView: View {
    let summary: OfflineSyncSummary
    @EnvironmentObject var ble: BLEManager

    private var message: String {
        let noun = summary.count == 1 ? "detection" : "detections"
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
            }
            .buttonStyle(.plain)
            Button { ble.clearOfflineSyncBanner() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ACABTheme.dim)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
