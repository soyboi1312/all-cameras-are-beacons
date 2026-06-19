import SwiftUI
import UIKit

/// Logbook: detection history, with category tiles that double as filters over the
/// list below.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var exportFile: ExportFile?

    private var shown: [Detection] {
        guard let filter else { return ble.detections }
        return ble.detections.filter { $0.type.category == filter }
    }
    private func count(_ cat: String) -> Int {
        ble.detections.filter { $0.type.category == cat }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        summaryTiles
                        if ble.detections.isEmpty { emptyState }
                        else { logCard }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Logbook").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker("\(ble.detections.count) DETECTED")
            }
            Spacer()
            if !ble.detections.isEmpty {
                HStack(spacing: 10) {
                    iconButton("square.and.arrow.up") {
                        if let url = ble.writeDetectionsCSV() { exportFile = ExportFile(url: url) }
                    }
                    iconButton("trash") { ble.clearDetections() }
                }
            }
        }
    }

    private func iconButton(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 14)).foregroundStyle(ACABTheme.dim)
                .frame(width: 36, height: 36)
                .background(ACABTheme.bg2, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
        }
    }

    /// Category tiles; tapping one toggles it as a filter for the list.
    private var summaryTiles: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            tile(.flockCamera, "ALPR")
            tile(.drone,       "DRONE")
            tile(.axonBodyCam, "BODY CAM")
            tile(.tracker,     "TRACKER")
        }
    }

    private func tile(_ type: DeviceType, _ cat: String) -> some View {
        let active = filter == cat
        let n = count(cat)
        return Button { filter = active ? nil : cat } label: {
            HStack(spacing: 10) {
                CatGlyph(type: type, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(n)").font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text).monospacedDigit()
                    Kicker(cat, color: active ? type.tint : (n == 0 ? ACABTheme.faint : ACABTheme.dim))
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(active ? type.tint.opacity(0.12) : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(active ? type.tint.opacity(0.4) : ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The detection list (honoring the active filter), divider between rows.
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(filter == nil ? "ALL DETECTIONS" : "\(filter!) DETECTIONS").padding(.bottom, 8)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                NavigationLink {
                    DetectionDetailView(detection: d)
                } label: {
                    DetectionRow(detection: d)
                }
                .buttonStyle(.plain)
                if i < shown.count - 1 { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope").font(.system(size: 38)).foregroundStyle(ACABTheme.line)
            Text("Scanning\u{2026}").font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.dim)
            Text("Detections log here as Beacons spots surveillance gear nearby.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

/// A temp file to share. Identifiable so it can drive `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Share-sheet wrapper around UIActivityViewController.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
