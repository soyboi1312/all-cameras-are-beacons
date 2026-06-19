import SwiftUI

/// Status / home: the at-a-glance "how much is watching me right now" screen.
/// Built around the radar scope, fed by live BLE detections.
struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager

    private var detections: [Detection] { ble.detections }
    private var count: Int { detections.count }

    private func count(_ type: DeviceType) -> Int {
        detections.filter { $0.type == type }.count
    }

    private var dots: [RadarDot] {
        // cap at 14 so a busy scope stays readable
        detections.prefix(14).map { d in
            let norm = min(1, max(0, (Double(-d.rssi) - 30) / 70))
            return RadarDot(id: d.id, angle: angle(for: d.mac),
                            radius: 0.12 + norm * 0.8, tone: d.type.tint)
        }
    }

    private var nearest: Detection? {
        detections.max(by: { $0.rssi < $1.rssi })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            BrandMark(size: 21)
                            Spacer()
                            LinkChip(connected: ble.connectionState == .connected, demo: ble.demoMode)
                        }
                        HStack(spacing: 8) {
                            ScanDot()
                            Kicker("SCANNING · BLE · WI-FI", color: ACABTheme.dim)
                        }

                        RadarScope(count: count, dots: dots)
                            .frame(height: 250)
                            .padding(.top, 4)

                        HStack { Spacer(); PunkLine(); Spacer() }
                            .padding(.vertical, 2)

                        categoryTiles

                        if let nearest { nearestCard(nearest) }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                }
            }
            .navigationBarHidden(true)
        }
    }

    /// Two columns of per-category counts.
    private var categoryTiles: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            tile(.flockCamera, "ALPR",     count(.flockCamera) + count(.flockRaven))
            tile(.drone,       "DRONE",    count(.drone))
            tile(.axonBodyCam, "BODY CAM", count(.axonBodyCam))
            tile(.tracker,     "TRACKER",  count(.tracker))
        }
    }

    private func tile(_ type: DeviceType, _ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CatGlyph(type: type, size: 30)
            Text("\(n)")
                .font(ACABTheme.display(26, weight: .semibold))
                .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text)
                .monospacedDigit()
            Kicker(label, color: n == 0 ? ACABTheme.faint : type.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 13)
    }

    /// Tappable card for the closest device (highest RSSI).
    private func nearestCard(_ d: Detection) -> some View {
        NavigationLink {
            DetectionDetailView(detection: d)
        } label: {
            HStack(spacing: 12) {
                CatGlyph(type: d.type, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(categoryTitle(d.type.category))
                            .font(ACABTheme.display(15, weight: .semibold))
                            .foregroundStyle(ACABTheme.text)
                        Text("NODE \(nodeName(d.mac))")
                            .font(ACABTheme.mono(11, weight: .medium))
                            .foregroundStyle(ACABTheme.dim)
                    }
                    Text("\(d.source.label) · seen \(d.count)×")
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(d.rssi)")
                        .font(ACABTheme.mono(15, weight: .semibold))
                        .foregroundStyle(ACABTheme.accent)
                    SignalBars(bars: d.signalBars, tint: d.type.tint)
                }
            }
            .panel(strong: true)
        }
        .buttonStyle(.plain)
    }

    // Fake-but-stable bearing hashed from the MAC — we only have RSSI, not a real one.
    private func angle(for mac: String) -> Double {
        var h: UInt64 = 5381
        for b in mac.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360)
    }
    private func nodeName(_ mac: String) -> String {
        String(mac.replacingOccurrences(of: ":", with: "").suffix(4)).uppercased()
    }

    // Title-case a category (Drone, Body Cam) but leave acronyms like ALPR alone,
    // since .capitalized would turn it into "Alpr".
    private func categoryTitle(_ cat: String) -> String {
        let isAcronym = !cat.contains(" ") && cat.allSatisfy { $0.isUppercase }
        return isAcronym ? cat : cat.capitalized
    }
}
