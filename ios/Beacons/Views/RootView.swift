import SwiftUI

/// Connect screen until a board is connected, then the main tabs.
struct RootView: View {
    @EnvironmentObject var ble: BLEManager

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
        .preferredColorScheme(.dark)
        .animation(.easeInOut, value: ble.connectionState)
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
    }
}
