import SwiftUI
import CoreBluetooth

/// Pre-connection / first-run screen: says what the beacon does, explains the permissions
/// before the OS asks, scans for a board, and offers a first-class "tour on sample data" path.
struct ConnectView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var showSavedLog = false   // read-only path into the persisted log, no board needed

    // The five things the beacon listens for, as shown in the "what it hears" strip.
    private let hears: [(DeviceType, String)] = [
        (.flockCamera, "ALPR"), (.drone, "DRONES"), (.axonBodyCam, "BODY CAMS"),
        (.tracker, "TRACKERS"), (.recordingGlasses, "GLASSES"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ACABWordmark()
                .padding(.top, 56)
                .padding(.bottom, 22)

            ScrollView {
                VStack(spacing: 16) {
                    beaconHearsPanel
                    content
                    // ORDER MATTERS (2026-07-29): the tour used to sit third, under the saved log
                    // and above the shop link, and new users never found it - yet it is the single
                    // best answer to "what does this thing even do", because it IS the app running
                    // on sample data. It now leads, and it is the only card with a filled accent
                    // background so it reads as the primary action for anyone who is stuck.
                    demoCard
                    if !ble.demoMode && !ble.detections.isEmpty { savedLogCard }
                    getBeaconCard
                    soyboiLink
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            scopeFootnote
        }
        .sheet(isPresented: $showSavedLog) {
            DetectionsView()
                .environmentObject(ble)
                // No MainTabView while disconnected, so a dossier's OPEN IN MAP handoff has no
                // receiver here: it would dead-end and park a stale MapFocus coordinate that
                // hijacks a later connect's first map open. The flag hides the affordance.
                .environment(\.mapHandoffAvailable, false)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: what it hears

    private var beaconHearsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("WHAT YOUR BEACON CAN HEAR")
            HStack(spacing: 0) {
                ForEach(hears, id: \.1) { type, label in
                    VStack(spacing: 7) {
                        CatGlyph(type: type, size: 32, filled: true)
                        Text(label)
                            .font(ACABTheme.mono(8.5, weight: .medium)).tracking(0.5)
                            .foregroundStyle(ACABTheme.dim)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("a passive listener. it never jams, spoofs, or transmits, it writes down what's already shouting.")
                .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("trackers and network cameras are opt-in, switch them on in Device settings.")
                .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    // MARK: state-driven scan / message UI

    @ViewBuilder private var content: some View {
        switch ble.connectionState {
        case .poweredOff:
            message("Bluetooth is off", "Turn on Bluetooth to find your board.", "bolt.slash.fill")
        case .unauthorized:
            message("Bluetooth not allowed", "Enable Bluetooth for beacons in Settings.", "lock.fill")
        case .unknown:
            message("Starting Bluetooth\u{2026}", "", "antenna.radiowaves.left.and.right")
        case .connecting:
            // An unexpected-drop auto-reconnect is armed indefinitely (good: it resyncs the moment
            // the board is back, even backgrounded). But RootView only shows the tabs when
            // .connected, so without an escape here a board that never returns would trap the user
            // on this screen forever with no way to scan for a different one. The fresh scan-connect
            // path needs the same way out: central.connect never times out on its own, so a stale
            // row (board powered off since discovery, or claimed by another phone) would park the
            // spinner forever. BLEManager arms a 15 s watchdog for that; the button here is the
            // manual escape, and both call disconnect(), which settles the state back to the scan
            // panel.
            if ble.isReconnecting {
                reconnectingPanel
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(ACABTheme.accent)
                    Text("Connecting\u{2026}").font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.dim)
                    Button { ble.disconnect() } label: {
                        Text("Stop and scan")
                            .font(ACABTheme.mono(12, weight: .bold))
                            .foregroundStyle(ACABTheme.dim)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(ACABTheme.bg2, in: Capsule())
                            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        default:
            scanPanel
        }
    }

    /// Shown while a pending auto-reconnect is armed (board unplugged / power-cycled). Says the
    /// reconnect is automatic AND gives a way out: "Stop and scan" calls disconnect(), which cancels
    /// the pending connect and settles the state to .idle so the scan panel returns. Without this the
    /// user is stuck on the connect screen until the board comes back, which it may never do.
    private var reconnectingPanel: some View {
        VStack(spacing: 14) {
            ProgressView().tint(ACABTheme.accent)
            Text("Reconnecting to your board\u{2026}")
                .font(ACABTheme.mono(15, weight: .bold)).foregroundStyle(ACABTheme.ink)
            Text("It reconnects on its own the moment the board is back in range, even in the background. Keep waiting, or stop to scan for a different board.")
                .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.disconnect() } label: {
                Text("Stop and scan")
                    .font(ACABTheme.mono(13, weight: .bold))
                    .foregroundStyle(ACABTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ACABTheme.accent,
                                in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 4)
        .panel()
    }

    /// True once Bluetooth is granted. Reads the static authorization (no prompt, no "access"),
    /// so the pre-permission rationale retires once the system has already asked.
    private var btGranted: Bool { CBManager.authorization == .allowedAlways }

    /// Pre-permission rationale + the primary scan CTA, then the discovered boards. The rationale
    /// panel only shows before Bluetooth is granted; once it is, the CTA stands on its own.
    private var scanPanel: some View {
        VStack(spacing: 14) {
            if btGranted {
                scanCTA
                pairWindowNote
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    Kicker("BEFORE THE SYSTEM ASKS")
                    rationaleRow("antenna.radiowaves.left.and.right", "Bluetooth",
                                 "pairs you to the beacon. The board does the listening, not your phone.")
                    rationaleRow("location.fill", "Location",
                                 "pins hits to the map. Nothing leaves this phone, no accounts, no cloud.")
                    scanCTA
                    pairWindowNote
                }
                .panel()
            }

            if ble.discovered.isEmpty, ble.connectionState == .scanning {
                Text("Looking for your board\u{2026}")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .padding(.top, 2)
            }

            // one tappable row per board we've found
            ForEach(ble.discovered) { dev in
                Button { ble.connect(dev) } label: { boardRow(dev) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func rationaleRow(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15)).foregroundStyle(ACABTheme.accent)
                .frame(width: 20)
            (Text(lead).font(ACABTheme.mono(11.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                + Text(" \(rest)").font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var scanCTA: some View {
        Button {
            ble.connectionState == .scanning ? ble.stopScan() : ble.startScan()
        } label: {
            Label(ble.connectionState == .scanning ? "Scanning\u{2026}"
                    : (btGranted ? "Scan for boards" : "Allow & scan for boards"),
                  systemImage: ble.connectionState == .scanning
                    ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(ACABTheme.mono(14, weight: .bold))
                .foregroundStyle(ACABTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ACABTheme.accent,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// First-time pairing note, shown under the scan button whenever no board is connected.
    ///
    /// A board that already belongs to a phone only accepts a NEW phone in the two minutes after it
    /// powers on. That rule is invisible from the phone's side: the board hangs up before any
    /// characteristic exists to explain itself, so a user who misses the window just sees a connect
    /// that will not take. Stating it BEFORE the failure is worth more than any error message
    /// after it, which is why this is always present rather than an alert.
    ///
    /// Deliberately says "already paired to another phone", not "your beacon": on a brand new board
    /// with no bonds the rule does not apply at all (the firmware admits any phone until the board
    /// has an owner), and telling a first-time customer to power-cycle would be a made-up ritual.
    private var pairWindowNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
            Text("Connecting a beacon that is already paired to another phone? "
                 + BLEManager.pairWindowHint)
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    private func boardRow(_ dev: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu").foregroundStyle(ACABTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dev.name).font(ACABTheme.mono(14, weight: .semibold))
                    if let fw = dev.firmware {
                        Text("v\(fw)").font(ACABTheme.mono(9, weight: .bold))
                            .foregroundStyle(ACABTheme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(ACABTheme.accent.opacity(0.15), in: Capsule())
                    }
                }
                Text(dev.id.uuidString.prefix(8)).font(ACABTheme.mono(10))
                    .foregroundStyle(ACABTheme.dim)
            }
            Spacer()
            SignalBars(bars: bars(for: dev.rssi))
            Text("\(dev.rssi)").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
        .foregroundStyle(ACABTheme.ink)
        .panel()
    }

    private func message(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(ACABTheme.dim)
            Text(title).font(ACABTheme.mono(16, weight: .bold)).foregroundStyle(ACABTheme.ink)
            if !body.isEmpty {
                Text(body).font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: saved log (no board required)

    /// The history on this phone stays reachable with no board and no Bluetooth. The Log tab
    /// is normally gated behind .connected, but a log that may be evidence must never be
    /// locked behind hardware that died or a permission that was denied. Everything inside is
    /// phone-local (view, mark seen, export CSV, clear); board-config writes no-op while
    /// disconnected. Hidden during the tour so the sample store can never be exported here.
    private var savedLogCard: some View {
        Button { showSavedLog = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("View saved log (\(ble.detections.count))")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("history on this phone \u{00B7} browse and export, no board needed")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: demo (first-class)

    /// Explore the full app with sample data, no board needed (also handy for App Review).
    private var demoCard: some View {
        Button { ble.seedDemoData() } label: {
            HStack(spacing: 12) {
                Image(systemName: "scope")   // R5: the tracker category owns dot.radiowaves...
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See how it works")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("the full app on sample data \u{00B7} no beacon needed")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(ACABTheme.accentSoft, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: get a beacon

    /// No hardware yet? Point straight at the shop. Styled to match the demo/saved-log cards so it
    /// reads as a first-class path, but it's a Link (arrow.up.right) since it leaves the app.
    private var getBeaconCard: some View {
        Link(destination: URL(string: "https://soyboi.tech")!) {
            HStack(spacing: 12) {
                Image(systemName: "cart")
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get a beacon")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("the board that does the listening \u{00B7} soyboi.tech")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Secondary text link to the same shop, for people who just want the plain URL.
    private var soyboiLink: some View {
        Link(destination: URL(string: "https://soyboi.tech")!) {
            Text("soyboi.tech")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.accent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 2)
    }

    private var scopeFootnote: some View {
        Text("Passive detection only. beacons never jams, spoofs, or interferes.")
            .font(ACABTheme.mono(9))
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(.center)
            .padding(20)
    }

    private func bars(for rssi: Int) -> Int {
        switch rssi {
        case ..<(-90): return 1
        case ..<(-80): return 2
        case ..<(-67): return 3
        default:       return 4
        }
    }
}
