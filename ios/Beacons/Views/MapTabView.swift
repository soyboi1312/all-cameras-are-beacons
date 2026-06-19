import SwiftUI
import MapKit

/// Located detections on a dark map, filterable by category. Fixed installs
/// (Flock/body-cam/tracker) sit at our position when we heard them; drones plot
/// their own broadcast position plus the operator's.
struct MapTabView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?           // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selected: Detection?
    @State private var emptyDismissed = false

    /// Where the pin goes: a drone's own broadcast coordinate if it has one, else
    /// the phone's position when we first heard it (Flock / body-cam / tracker —
    /// the board has no GPS).
    private func mapCoord(for d: Detection) -> CLLocationCoordinate2D? {
        d.coordinate ?? ble.capturedLocation(for: d.id)
    }

    private var located: [Detection] {
        ble.detections.filter { mapCoord(for: $0) != nil && (filter == nil || $0.type.category == filter) }
    }
    private var totalLocated: Int { ble.detections.filter { mapCoord(for: $0) != nil }.count }
    private func count(_ cat: String) -> Int {
        ble.detections.filter { mapCoord(for: $0) != nil && $0.type.category == cat }.count
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                map
                VStack(spacing: 12) {
                    header
                    filterBar
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 8)
                .background(
                    LinearGradient(colors: [ACABTheme.bg, ACABTheme.bg.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                )
                if totalLocated == 0 && !emptyDismissed {
                    emptyBanner.transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                legend.padding(ACABTheme.pad).padding(.bottom, 6)
            }
            .navigationBarHidden(true)
            .sheet(item: $selected) { DetectionDetailView(detection: $0).environmentObject(ble) }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()                       // the phone's live position
            ForEach(located) { d in
                if d.type == .drone { droneOverlay(d) }
                if let coord = mapCoord(for: d) {
                    Annotation(d.type.shortTag, coordinate: coord) {
                        Button { selected = d } label: { MapPin(type: d.type) }
                            .buttonStyle(.plain)
                    }
                }
                if let pilot = d.pilotCoordinate {
                    Annotation("OP", coordinate: pilot) { OperatorPin() }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }   // tap the button to recenter on me
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    /// Drone-only overlays: the flight-path line, a launch marker at the first fix,
    /// and a dashed tether to the operator.
    @MapContentBuilder
    private func droneOverlay(_ d: Detection) -> some MapContent {
        let track = ble.track(for: d.id)
        if track.count >= 2 {
            MapPolyline(coordinates: track)
                .stroke(ACABTheme.droneTone.opacity(0.85), lineWidth: 2.5)
        }
        if let launch = track.first {
            Annotation("LAUNCH", coordinate: launch) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ACABTheme.droneTone)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
        }
        if let drone = d.coordinate, let pilot = d.pilotCoordinate {
            MapPolyline(coordinates: [drone, pilot])
                .stroke(ACABTheme.droneTone.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        if d.coordinate == nil, let me = ble.selfCoord {   // no GPS fix: draw an RSSI ring around us instead
            MapCircle(center: me, radius: rssiRadiusMeters(d.rssi))
                .foregroundStyle(ACABTheme.droneTone.opacity(0.08))
                .stroke(ACABTheme.droneTone.opacity(0.5), lineWidth: 1.5)
        }
    }

    /// Rough RSSI → distance in metres for the no-GPS ring. Log-distance path-loss
    /// model, deliberately fuzzy — just a "somewhere around here" hint.
    private func rssiRadiusMeters(_ rssi: Int) -> Double {
        let d = pow(10.0, (-50.0 - Double(rssi)) / 25.0)   // assumes TxPower -50 dBm, path-loss n ~ 2.5
        return min(max(d, 5), 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Map").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker("\(totalLocated) SIGHTING\(totalLocated == 1 ? "" : "S")")
            }
            Spacer()
            LinkChip(connected: ble.connectionState == .connected, demo: ble.demoMode)
        }
    }

    /// Scrolling category chips; tap one to narrow the pins.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "ALL", totalLocated)
                chip("ALPR", "ALPR", count("ALPR"))
                chip("DRONE", "DRONE", count("DRONE"))
                chip("BODY CAM", "BODY CAM", count("BODY CAM"))
                chip("TRACKER", "TRACKER", count("TRACKER"))
            }
            .padding(.bottom, 2)
        }
    }

    private func chip(_ cat: String?, _ label: String, _ n: Int) -> some View {
        let active = filter == cat
        let tint = catTint(cat)
        return Button { filter = cat } label: {
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

    private func catTint(_ cat: String?) -> Color {
        switch cat {
        case "ALPR":     return ACABTheme.flockTone
        case "DRONE":    return ACABTheme.droneTone
        case "BODY CAM": return ACABTheme.axonTone
        case "TRACKER":  return ACABTheme.trackerTone
        default:         return ACABTheme.accent
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            legendRow(ACABTheme.flockTone, "ALPR")
            legendRow(ACABTheme.droneTone, "Drone")
            legendRow(ACABTheme.axonTone,  "Body cam")
            legendRow(ACABTheme.trackerTone, "Tracker")
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private func legendRow(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.6), radius: 3)
            Text(t).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
    }

    private var emptyBanner: some View {
        VStack(spacing: 9) {
            Image(systemName: "mappin.slash").font(.system(size: 28)).foregroundStyle(ACABTheme.faint)
            Text("No located detections yet")
                .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
            Text("ALPR, body-cam and tracker hits use your phone's position; drones report their own.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                .multilineTextAlignment(.center).frame(maxWidth: 250)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
        .allowsHitTesting(false)        // let touches fall through so you can still pan the map behind it
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { emptyDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(ACABTheme.dim)
                    .frame(width: 26, height: 26)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Animated category pin: filled dot with a glyph and a slow ping ring.
private struct MapPin: View {
    let type: DeviceType
    @State private var ping = false
    var body: some View {
        ZStack {
            Circle().stroke(type.tint, lineWidth: 2).frame(width: 28, height: 28)
                .scaleEffect(ping ? 1.9 : 0.9).opacity(ping ? 0 : 0.7)
            Circle().fill(type.tint).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2.5))
                .shadow(color: type.tint.opacity(0.7), radius: 6)
            Image(systemName: type.symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { ping = true }
        }
    }
}

/// Muted person icon for a drone's operator, kept distinct from the device pin.
private struct OperatorPin: View {
    var body: some View {
        Image(systemName: "person.fill").font(.system(size: 11, weight: .bold))
            .foregroundStyle(ACABTheme.text)
            .padding(6)
            .background(ACABTheme.bg3, in: Circle())
            .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
    }
}
