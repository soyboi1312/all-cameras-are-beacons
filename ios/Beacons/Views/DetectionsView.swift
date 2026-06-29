import SwiftUI
import UIKit

/// Logbook: detection history, with category tiles that double as filters over the
/// list below. New/All filtering, a "mark all seen" baseline, and a select mode for
/// bulk-ignoring rows.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var newOnly = false     // show only detections after the seen watermark
    @State private var selecting = false   // bulk-select mode
    @State private var selection: Set<String> = []   // selected Detection.id
    @State private var exportFile: ExportFile?

    private var shown: [Detection] {
        ble.detections.filter { d in
            (filter == nil || d.type.category == filter) &&
            (!newOnly || ble.isUnseen(d))
        }
    }
    private func count(_ cat: String) -> Int {
        ble.detections.filter { $0.type.category == cat }.count
    }
    private var newCount: Int { ble.detections.filter { ble.isUnseen($0) }.count }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        summaryTiles
                        if !ble.detections.isEmpty { statusFilter }
                        if ble.detections.isEmpty { emptyState }
                        else if shown.isEmpty { noMatchState }
                        else { logCard }
                        Spacer(minLength: selecting ? 72 : 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                }
                if selecting { selectBar }
            }
            .navigationBarHidden(true)
            .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Logbook").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(selecting ? "\(selection.count) SELECTED" : "\(ble.detections.count) DETECTED")
            }
            Spacer()
            if selecting {
                Button { exitSelect() } label: {
                    Text("DONE").font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(ACABTheme.bg2, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if !ble.detections.isEmpty {
                HStack(spacing: 10) {
                    iconButton("checkmark.circle") { selecting = true }
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

    /// All / New segmented chips plus the "mark all seen" baseline control.
    private var statusFilter: some View {
        HStack(spacing: 8) {
            segChip("ALL", ble.detections.count, active: !newOnly) { newOnly = false }
            segChip("NEW", newCount, active: newOnly, tint: ACABTheme.accent) { newOnly = true }
            Spacer(minLength: 0)
            Button { ble.markAllSeen(); newOnly = false } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle").font(.system(size: 11, weight: .semibold))
                    Text("MARK SEEN").font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(ACABTheme.dim)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(ACABTheme.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func segChip(_ label: String, _ n: Int, active: Bool,
                         tint: Color = ACABTheme.dim,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
                Text("\(n)").font(ACABTheme.mono(10))
                    .foregroundStyle(active ? ACABTheme.onAccent.opacity(0.7) : ACABTheme.faint)
            }
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? tint : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// The detection list (honoring the active filters), divider between rows.
    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(logHeading).padding(.bottom, 8)
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, d in
                row(d)
                if i < shown.count - 1 { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    private var logHeading: String {
        let scope = newOnly ? "NEW" : "ALL"
        return filter == nil ? "\(scope) DETECTIONS" : "\(filter!) \u{00B7} \(scope)"
    }

    @ViewBuilder
    private func row(_ d: Detection) -> some View {
        if selecting {
            Button { toggle(d) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selection.contains(d.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selection.contains(d.id) ? ACABTheme.accent : ACABTheme.faint)
                    DetectionRow(detection: d)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                DetectionDetailView(detection: d)
            } label: {
                DetectionRow(detection: d)
            }
            .buttonStyle(.plain)
        }
    }

    /// Bottom action bar shown in select mode: bulk-ignore the selected rows.
    private var selectBar: some View {
        HStack(spacing: 10) {
            Button { selection = Set(shown.map { $0.id }) } label: {
                Text("SELECT ALL").font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.dim)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(ACABTheme.bg2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: ignoreSelected) {
                HStack(spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                    Text("IGNORE \(selection.count)").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(selection.isEmpty ? ACABTheme.faint : ACABTheme.onAccent)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(selection.isEmpty ? ACABTheme.bg2 : ACABTheme.accent, in: Capsule())
                .overlay(Capsule().strokeBorder(selection.isEmpty ? ACABTheme.line : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 10).padding(.bottom, 8)
        .background(
            LinearGradient(colors: [ACABTheme.bg.opacity(0), ACABTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func toggle(_ d: Detection) {
        if selection.contains(d.id) { selection.remove(d.id) } else { selection.insert(d.id) }
    }

    private func ignoreSelected() {
        let picks = ble.detections.filter { selection.contains($0.id) }
        ble.ignoreDevices(picks)
        exitSelect()
    }

    private func exitSelect() {
        selecting = false
        selection.removeAll()
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

    /// Shown when filters hide everything (e.g. New-only with nothing new yet).
    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: newOnly ? "checkmark.seal" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 32)).foregroundStyle(ACABTheme.line)
            Text(newOnly ? "Nothing new" : "No matches")
                .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.dim)
            Text(newOnly
                 ? "Everything here is marked seen. New hits show up as they arrive."
                 : "No detections in this category yet.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .panel()
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
