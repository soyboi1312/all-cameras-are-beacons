import SwiftUI

/// Pre-connection screen: surface Bluetooth state, scan, and pick a board.
struct ConnectView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        VStack(spacing: 0) {
            ACABWordmark()
                .padding(.top, 64)
                .padding(.bottom, 28)

            ScrollView {
                content.padding(.horizontal, 20)
            }

            demoButton
            scopeFootnote
        }
    }

    // pick the right idle/error/scan UI for the current BLE state
    @ViewBuilder private var content: some View {
        switch ble.connectionState {
        case .poweredOff:
            message("Bluetooth is off", "Turn on Bluetooth to find your board.", "bolt.slash.fill")
        case .unauthorized:
            message("Bluetooth not allowed", "Enable Bluetooth for Beacons in Settings.", "lock.fill")
        case .unknown:
            message("Starting Bluetooth\u{2026}", "", "antenna.radiowaves.left.and.right")
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(ACABTheme.red)
                Text("Connecting\u{2026}").font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.dim)
            }
            .padding(.top, 48)
        default:
            scanList
        }
    }

    private var scanList: some View {
        VStack(spacing: 14) {
            Button {
                ble.connectionState == .scanning ? ble.stopScan() : ble.startScan()
            } label: {
                Label(ble.connectionState == .scanning ? "Scanning\u{2026}" : "Scan for boards",
                      systemImage: ble.connectionState == .scanning
                        ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                    .font(ACABTheme.mono(15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(ACABTheme.red)
                    .foregroundStyle(ACABTheme.black)
            }

            if ble.discovered.isEmpty, ble.connectionState == .scanning {
                Text("Looking for your board\u{2026}")
                    .font(ACABTheme.mono(12))
                    .foregroundStyle(ACABTheme.dim)
                    .padding(.top, 6)
            }

            // one tappable row per board we've found
            ForEach(ble.discovered) { dev in
                Button { ble.connect(dev) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu").foregroundStyle(ACABTheme.red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(dev.name).font(ACABTheme.mono(14, weight: .semibold))
                                if let fw = dev.firmware {
                                    Text("v\(fw)").font(ACABTheme.mono(9, weight: .bold))
                                        .foregroundStyle(ACABTheme.red)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(ACABTheme.red.opacity(0.15), in: Capsule())
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
            }
        }
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
        .padding(.top, 44)
    }

    /// Explore the full app with sample data, no board needed (also handy for App Review).
    private var demoButton: some View {
        Button { ble.seedDemoData() } label: {
            VStack(spacing: 3) {
                Text("Continue without pairing")
                    .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                Text("explore the app with sample data")
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.top, 4)
    }

    private var scopeFootnote: some View {
        Text("Passive detection only. Beacons never jams, spoofs, or interferes.")
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
