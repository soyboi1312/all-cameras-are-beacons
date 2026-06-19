import SwiftUI

/// Device tab: OUI-Spy hardware status, scan radios, and alert controls.
struct DeviceView: View {
    @EnvironmentObject var ble: BLEManager

    @State private var master: Double = 72
    @State private var bodyCamOn = false
    @State private var trackerOn = false
    @State private var pendingTracker = false   // just flipped; hold the value until the board confirms
    @State private var pendingBodyCam = false
    @State private var bleOn = true
    @State private var wifiOn = true
    // Per-threat volumes are UI-only for now — the firmware has just one master level.
    @AppStorage("vol.flock") private var flock: Double = 90
    @AppStorage("vol.drone") private var drone: Double = 55
    @AppStorage("vol.axon")  private var axon:  Double = 80

    // Any mode but the buzzer dims the volume sliders.
    private var muted: Bool { ble.alertMode != .buzzer }

    var body: some View {
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        deviceHero
                        firmwareCard
                        radiosCard
                        detectorsCard
                        if !ble.ignored.isEmpty { ignoredCard }
                        buzzerCard
                        statsGrid
                        disconnectButton
                        aboutCard
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                }
            }
            .navigationBarHidden(true)
        }
        .onAppear(perform: sync)
        .onChange(of: ble.status) { _, _ in sync() }
    }

    // copy board state into local UI vars; runs on appear and on every status update
    private func sync() {
        guard let s = ble.status else { return }
        master = Double(s.volume)
        // Keep a just-toggled switch at the user's value until the board confirms it,
        // so the ~5s status frame can't snap it back to off mid-flight.
        if pendingBodyCam { if s.axon == bodyCamOn { pendingBodyCam = false } } else { bodyCamOn = s.axon }
        if pendingTracker { if s.tracker == trackerOn { pendingTracker = false } } else { trackerOn = s.tracker }
        bleOn  = s.ble
        wifiOn = s.wifi
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Device").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(ble.demoMode ? "SAMPLE DATA" : "PAIRED OVER BLE")
            }
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(ACABTheme.dim)
                .frame(width: 38, height: 38)
                .background(ACABTheme.bg2, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
        }
    }

    // MARK: device hero
    private var deviceHero: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ACABTheme.bg3).frame(width: 52, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ACABTheme.line, lineWidth: 1))
                Circle().fill(ACABTheme.accent).frame(width: 7, height: 7)
                    .shadow(color: ACABTheme.accentGlow, radius: 4).offset(x: -14, y: -9)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(ble.connectedName?.contains("ACAB") == true
                     ? "All Cameras Are Beacons" : (ble.connectedName ?? "ESP32 board"))
                    .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                Text(ble.demoMode ? "SAMPLE DATA · no live board"
                                  : "CONNECTED · \(ble.status?.firmware ?? "Beacons")")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
            }
            Spacer()
            ScanDot(color: ble.connectionState == .connected ? ACABTheme.accent : ACABTheme.faint)
        }
        .panel(strong: true)
    }

    // MARK: firmware
    private var firmwareCard: some View {
        let installed = ble.status?.version
        let outdated = ble.status?.updateAvailable ?? false
        return VStack(alignment: .leading, spacing: 12) {
            Kicker("FIRMWARE")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.map { "v\($0)" } ?? "\u{2014}")
                        .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    Kicker("INSTALLED")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("v\(DeviceStatus.latestVersion)")
                        .font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.dim)
                    Kicker("LATEST")
                }
            }
            Divider().overlay(ACABTheme.line)
            HStack(spacing: 8) {
                Image(systemName: outdated ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 13)).foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.accent)
                Text(outdated
                     ? "Update available: reflash your ESP32 board to v\(DeviceStatus.latestVersion)."
                     : "You're on the latest firmware.")
                    .font(ACABTheme.mono(11)).foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.dim)
                Spacer(minLength: 0)
            }
        }
        .panel()
    }

    // MARK: scan radios
    private var radiosCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("SCAN RADIOS")
            radioToggle("Bluetooth LE", "ALPR \u{00B7} drone \u{00B7} trackers", isOn: Binding(
                get: { bleOn }, set: { bleOn = $0; ble.setBLEScan($0) }))
            Divider().overlay(ACABTheme.line)
            radioToggle("Wi-Fi", "2.4 GHz \u{00B7} ALPR \u{00B7} drone RID", isOn: Binding(
                get: { wifiOn }, set: { wifiOn = $0; ble.setWiFiScan($0) }))
        }
        .panel()
    }

    // MARK: detectors
    private var detectorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("DETECTORS")
            radioToggle("Body cams", "Axon signature \u{00B7} experimental", isOn: Binding(
                get: { bodyCamOn }, set: { bodyCamOn = $0; pendingBodyCam = true; ble.setBodyCamEnabled($0) }), exp: true)
            Divider().overlay(ACABTheme.line)
            radioToggle("Bluetooth trackers", "AirTag \u{00B7} Tile \u{00B7} SmartTag \u{00B7} opt-in", isOn: Binding(
                get: { trackerOn }, set: { trackerOn = $0; pendingTracker = true; ble.setTrackerEnabled($0) }))
        }
        .panel()
    }

    private func radioToggle(_ name: String, _ sub: String,
                             isOn: Binding<Bool>, exp: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    if exp { Tag(text: "EXP", color: ACABTheme.warn) }
                }
                Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
        }
        .tint(ACABTheme.accent)
    }

    // MARK: alerts
    private var buzzerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("ALERTS")

            alertModePicker

            Text(alertModeCaption)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                slider("Master volume", value: $master, tone: ACABTheme.accent, bold: true) {
                    ble.setVolume(Int(master), preview: true)
                }
                Kicker("PER THREAT").frame(maxWidth: .infinity, alignment: .leading)
                threatSlider(.flockCamera, "ALPR", $flock)
                threatSlider(.drone,       "DRONE", $drone)
                threatSlider(.axonBodyCam, "BODY CAM", $axon)
            }
            .opacity(muted ? 0.4 : 1)
            .disabled(muted)
        }
        .panel()
    }

    // Themed 3-way switch: equal segments in a capsule, the active one filled with
    // the accent. A stock .segmented Picker wouldn't match the theme.
    private var alertModePicker: some View {
        HStack(spacing: 4) {
            segment("Buzzer",  .buzzer)
            segment("Vibrate", .vibrate)
            segment("Silent",  .silent)
        }
        .padding(4)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private func segment(_ label: String, _ mode: AlertMode) -> some View {
        let active = ble.alertMode == mode
        return Button { ble.setAlertMode(mode) } label: {
            Text(label)
                .font(ACABTheme.mono(11.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(active ? ACABTheme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var alertModeCaption: String {
        switch ble.alertMode {
        case .buzzer:  return "board beeps when it spots gear"
        case .vibrate: return "board silent, this phone buzzes on new hits"
        case .silent:  return "board silent, no phone feedback"
        }
    }

    private func slider(_ label: String, value: Binding<Double>, tone: Color,
                        bold: Bool = false, onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(ACABTheme.display(14, weight: bold ? .medium : .regular)).foregroundStyle(ACABTheme.text)
                Spacer()
                Text(muted ? "-" : "\(Int(value.wrappedValue))")
                    .font(ACABTheme.mono(12, weight: .semibold)).foregroundStyle(tone)
            }
            Slider(value: value, in: 0...100, step: 1) { editing in if !editing { onCommit() } }
                .tint(tone)
        }
    }

    private func threatSlider(_ type: DeviceType, _ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            CatGlyph(type: type, size: 26)
            Text(label).font(ACABTheme.mono(11, weight: .medium)).foregroundStyle(ACABTheme.text)
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: 0...100, step: 1).tint(type.tint)
            Text("\(Int(value.wrappedValue))")
                .font(ACABTheme.mono(11, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                .frame(width: 26, alignment: .trailing)
        }
    }

    // MARK: stats
    /// Quick stats: uptime, total detections, alert state, active radios.
    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            statTile("UPTIME", ble.status.map(uptimeText) ?? "-")
            statTile("DETECTIONS", "\(ble.detections.count)")
            statTile("ALERTS", ble.alertMode == .buzzer ? "\(Int(master))%"
                                                        : (ble.alertMode == .vibrate ? "Vibrate" : "Silent"))
            statTile("SCANNING", scanningSummary)
        }
    }

    private var scanningSummary: String {
        let on = [bleOn ? "BLE" : nil, wifiOn ? "WiFi" : nil].compactMap { $0 }
        return on.isEmpty ? "OFF" : on.joined(separator: "+")
    }

    private func statTile(_ kick: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(kick)
            Text(value).font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
    }

    private func uptimeText(_ s: DeviceStatus) -> String {
        let h = s.uptime / 3600, m = (s.uptime % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var disconnectButton: some View {
        Button(role: .destructive) { ble.demoMode ? ble.exitDemo() : ble.disconnect() } label: {
            Text(ble.demoMode ? "Exit sample data" : "Disconnect")
                .font(ACABTheme.display(15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(ACABTheme.accent)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius).strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
    }

    // MARK: ignored devices
    private var ignoredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("IGNORED")
            ForEach(ble.ignored) { dev in
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 12)).foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        Text(dev.mac).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer(minLength: 8)
                    Button { ble.unignore(dev.mac) } label: {
                        Text("UNMUTE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.ignored.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    // MARK: about
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("ABOUT")
            Text("All Cameras Are Beacons is a companion app for counter-surveillance scanner firmware, built for Colonel Panic's OUI-Spy hardware.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ACABTheme.line)
            linkRow("Colonel Panic", "colonelpanic.tech \u{00B7} OUI-Spy hardware",
                    URL(string: "https://colonelpanic.tech")!)
            Divider().overlay(ACABTheme.line)
            linkRow("Source on GitHub", "github.com/soyboi1312/all-cameras-are-beacons",
                    URL(string: "https://github.com/soyboi1312/all-cameras-are-beacons")!)
            Divider().overlay(ACABTheme.line)
            linkRow("Privacy", "no data leaves your device",
                    URL(string: "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html")!)
            Link(destination: URL(string: "https://github.com/soyboi1312")!) {
                Text("made by soyboi")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .panel()
    }

    private func linkRow(_ title: String, _ sub: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
