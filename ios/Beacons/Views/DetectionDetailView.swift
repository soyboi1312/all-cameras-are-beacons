import SwiftUI
import MapKit
import UIKit

/// Full detection detail — pushed from the dashboard and logbook, shown as a sheet
/// from the map. Custom top bar, a live RSSI signal panel, stat grid, identity, and
/// location.
struct DetectionDetailView: View {
    let detection: Detection
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var d: Detection { detection }
    private var trend: [Int] { ble.rssiTrend(for: d.id) }

    var body: some View {
        ZStack(alignment: .top) {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    if d.type.isExperimental { experimentalNote }
                    signalPanel
                    statGrid
                    if d.method == .oui { falsePositiveNote }
                    identityPanel
                    if let coord = d.coordinate { locationPanel(coord) }
                    copyButton
                    ignoreButton
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 58)
                .padding(.bottom, 24)
            }
            topBar
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ACABTheme.text)
                    .frame(width: 36, height: 36)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            Spacer()
            Kicker("DETECTION")
            Spacer()
            Color.clear.frame(width: 36, height: 36)   // invisible right item to keep the title centered
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 8).padding(.bottom, 10)
        .background(
            LinearGradient(colors: [ACABTheme.bg, ACABTheme.bg.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: Title

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            CatGlyph(type: d.type, size: 54, filled: true)
            VStack(alignment: .leading, spacing: 7) {
                badgePill
                Text("NODE \(d.nodeName)")
                    .font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Text(d.vendor).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            Spacer(minLength: 0)
        }
    }

    private var badgePill: some View {
        HStack(spacing: 5) {
            Text(d.type.category)
            Text("\u{00B7}").opacity(0.5)
            Text(d.classLabel)
        }
        .font(ACABTheme.mono(9.5, weight: .bold)).tracking(1)
        .foregroundStyle(d.type.tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(d.type.tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(d.type.tint.opacity(0.35), lineWidth: 1))
    }

    private var experimentalNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ACABTheme.warn).font(.system(size: 12))
            Text("Experimental detector. Body-cam signatures are not field-verified yet, so treat this as a maybe.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.warn)
        }
        .panel(strong: false, padding: 13)
    }

    /// Shown for OUI-only matches: an OUI only names the chipset vendor, which Flock
    /// shares with consumer gear, so these matches can be false positives.
    private var falsePositiveNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ACABTheme.warn).font(.system(size: 11))
                Kicker("POSSIBLE FALSE POSITIVE", color: ACABTheme.warn)
            }
            Text("OUI matches flag the chipset vendor, which Flock shares with plenty of consumer devices. Worth confirming before you trust it.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(strong: false, padding: 13)
    }

    // MARK: Signal

    private var signalPanel: some View {
        let stale = ble.isStale(for: d.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if stale {
                    Kicker("SIGNAL \u{00B7} STALE", color: ACABTheme.dim)
                } else {
                    Kicker("SIGNAL \u{00B7} LIVE")
                }
                Spacer()
                SignalBars(bars: d.signalBars, tint: d.type.tint)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(d.rssi)").font(ACABTheme.display(30, weight: .semibold))
                            .foregroundStyle(ACABTheme.text).monospacedDigit()
                        Text("dBm").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                    Kicker("RSSI")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(d.source.label).font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(d.type.tint)
                    Kicker("BAND")
                }
            }
            Sparkline(values: trend, tint: d.type.tint).frame(height: 46)
                .opacity(stale ? 0.35 : 1)
        }
        .panel()
    }

    // MARK: Stat grid

    /// 2x2 grid: matched-on, source, confidence, sightings.
    private var statGrid: some View {
        let cells: [(String, String, Color)] = [
            ("MATCHED ON",  d.method.label, ACABTheme.text),
            ("SOURCE",      d.source.label, ACABTheme.text),
            ("CONFIDENCE",  "\(d.confidence)%", confColor),
            ("SIGHTINGS",   "\(d.count)", ACABTheme.text),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 5) {
                    Kicker(c.0)
                    Text(c.1).font(ACABTheme.mono(14, weight: .medium)).foregroundStyle(c.2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .overlay(alignment: .trailing) {
                    if i % 2 == 0 { Rectangle().fill(ACABTheme.line).frame(width: 1) }
                }
                .overlay(alignment: .top) {
                    if i >= 2 { Rectangle().fill(ACABTheme.line).frame(height: 1) }
                }
            }
        }
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var confColor: Color {
        switch d.confidence {
        case ..<50: return ACABTheme.dim
        case ..<80: return ACABTheme.warn
        default:    return ACABTheme.accent
        }
    }

    // MARK: Identity

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker("IDENTITY").padding(.bottom, 4)
            if let brand = d.type.brand { idRow("Brand", brand) }
            idRow("Vendor", d.ouiVendor ?? d.vendor)
            idRow("Identifier", d.mac)
            idRow("First seen", relativeAgo(ble.firstSeenDate(for: d.id)))
            idRow("Last seen", relativeAgo(ble.lastSeenDate(for: d.id)))
            if let n = d.name, !n.isEmpty { idRow("Name", n) }
            if let id = d.uasID, !id.isEmpty { idRow("UAS ID", id) }
            if let mfr = d.ridManufacturer { idRow("Manufacturer", mfr) }
            if let det = d.detail, !det.isEmpty { idRow("Detail", det) }
            if let alt = d.altitude { idRow("Altitude", "\(alt) m") }
            if let s = d.speedH { idRow("Speed", "\(s) m/s") }
            if let vs = d.speedV, vs != 0 { idRow("Vert. speed", "\(vs) m/s") }
            if let h = d.heading { idRow("Heading", "\(h)°") }
            if let hg = d.heightAGL { idRow("Height AGL", "\(hg) m") }
            if let pa = d.pilotAlt { idRow("Operator alt", "\(pa) m") }
            if let st = d.ridStatusLabel { idRow("Status", st) }
            whyFlagged
        }
        .panel()
    }

    private func idRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            Spacer(minLength: 16)
            Text(value).font(ACABTheme.mono(12, weight: .medium)).foregroundStyle(ACABTheme.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(ACABTheme.line).frame(height: 1) }
    }

    /// Short "ago" string for a sighting: "now", "12s ago", "4m ago", "1h ago",
    /// "3d ago" — or a dash if we don't know the time.
    private func relativeAgo(_ date: Date?) -> String {
        guard let date else { return "-" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        switch secs {
        case ..<5:        return "now"
        case ..<60:       return "\(secs)s ago"
        case ..<3600:     return "\(secs / 60)m ago"
        case ..<86_400:   return "\(secs / 3600)h ago"
        default:          return "\(secs / 86_400)d ago"
        }
    }

    private var whyFlagged: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 11)).foregroundStyle(d.type.tint)
            Text("Flagged by \(d.method.label) over \(d.source.label).")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    // MARK: Location

    private func locationPanel(_ coord: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Kicker("LOCATION")
                Spacer()
                Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
            }
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coord, span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))) {
                Annotation(d.type.shortTag, coordinate: coord) { miniPin }
                if let pilot = d.pilotCoordinate {
                    Marker("Operator", systemImage: "person.fill", coordinate: pilot).tint(ACABTheme.dim)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .preferredColorScheme(.dark)
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
            .allowsHitTesting(false)   // just a thumbnail; the real map tab is for panning
        }
        .panel()
    }

    private var miniPin: some View {
        ZStack {
            Circle().fill(d.type.tint).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2))
            Image(systemName: d.type.symbol).font(.system(size: 10, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
        }
    }

    // MARK: Action

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = d.mac
            withAnimation { copied = true }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .bold))
                Text(copied ? "COPIED" : "COPY MAC ADDRESS").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(ACABTheme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var ignoreButton: some View {
        Button {
            ble.ignoreDevice(d)
            dismiss()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                Text("IGNORE THIS DEVICE").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(ACABTheme.dim)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
