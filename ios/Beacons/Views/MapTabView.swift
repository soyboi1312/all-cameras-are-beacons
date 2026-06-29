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
    @State private var cluster: Cluster?         // tapped multi-member bubble (drives the picker sheet)
    @State private var span: MKCoordinateSpan = .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
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

    /// Only generic Desert-mode "nearby device" hits and item trackers accumulate into
    /// count bubbles — the noisy, low-stakes mass. Surveillance infrastructure (Flock
    /// ALPR, Raven, drone, body cam) ALWAYS renders as an individual marker, so a camera
    /// is never lost inside a clump. (A tracker later flagged as "following" will promote
    /// back to an individual marker.)
    private func clusterable(_ d: Detection) -> Bool { d.type == .nearbyDevice || d.type == .tracker }

    /// Drones: individual pins (they own flight-path overlays + an operator tether).
    private var droneDetections: [Detection] { located.filter { $0.type == .drone } }

    /// Surveillance infrastructure that always pins individually (located, non-drone,
    /// non-clusterable): Flock ALPR, Raven, body cam.
    private var infraDetections: [Detection] { located.filter { $0.type != .drone && !clusterable($0) } }

    /// Grid-clustered bubbles for ONLY the clusterable hits (nearby devices + trackers).
    /// Cell size scales with the current zoom (span / 14), so zooming in splits dense
    /// Desert-mode clumps apart and zooming out merges them.
    private var clusters: [Cluster] {
        let points = located.filter { clusterable($0) }
        guard !points.isEmpty else { return [] }
        let cell = max(span.latitudeDelta, span.longitudeDelta) / 14
        guard cell > 0 else {
            return points.compactMap { d in mapCoord(for: d).map { Cluster(coord: $0, members: [d]) } }
        }
        var buckets: [String: [Detection]] = [:]
        for d in points {
            guard let c = mapCoord(for: d) else { continue }
            let gx = (c.latitude / cell).rounded(.down)
            let gy = (c.longitude / cell).rounded(.down)
            buckets["\(gx):\(gy)", default: []].append(d)
        }
        return buckets.map { key, members in
            // Average the members so the bubble sits in the middle of the clump.
            let lat = members.compactMap { mapCoord(for: $0)?.latitude }.reduce(0, +) / Double(members.count)
            let lon = members.compactMap { mapCoord(for: $0)?.longitude }.reduce(0, +) / Double(members.count)
            return Cluster(id: key, coord: CLLocationCoordinate2D(latitude: lat, longitude: lon), members: members)
        }
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
            .sheet(item: $cluster) { c in
                ClusterListSheet(cluster: c) { d in
                    cluster = nil
                    // Defer so the picker sheet finishes dismissing before the detail one
                    // presents (two sheets can't transition at the same instant).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { selected = d }
                }
                .environmentObject(ble)
                .presentationDetents([.medium, .large])
            }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()                       // the phone's live position
            // Drones: their own pins, flight paths, and operator tethers.
            ForEach(droneDetections) { d in
                droneOverlay(d)
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
            // Surveillance infrastructure: always an individual marker, never bubbled.
            ForEach(infraDetections) { d in
                if let coord = mapCoord(for: d) {
                    Annotation(d.type.shortTag, coordinate: coord) {
                        Button { selected = d } label: { MapPin(type: d.type) }
                            .buttonStyle(.plain)
                    }
                }
            }
            // Nearby devices + trackers: grid-clustered bubbles. A lone member renders as
            // a normal pin; a clump renders one count bubble so a dense log stays legible.
            ForEach(clusters) { c in
                Annotation(c.shortTag, coordinate: c.coord) {
                    if let only = c.single {
                        Button { selected = only } label: { MapPin(type: only.type) }
                            .buttonStyle(.plain)
                    } else {
                        Button { cluster = c } label: { ClusterBubble(cluster: c) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }   // tap the button to recenter on me
        .preferredColorScheme(.dark)
        .onMapCameraChange(frequency: .onEnd) { ctx in span = ctx.region.span }
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

// MARK: - Clustering

/// A group of located detections that fall in the same grid cell at the current zoom.
/// A single-member cluster is drawn as a normal pin; multi-member as a count bubble.
struct Cluster: Identifiable {
    var id: String
    let coord: CLLocationCoordinate2D
    let members: [Detection]

    init(id: String = UUID().uuidString, coord: CLLocationCoordinate2D, members: [Detection]) {
        self.id = id; self.coord = coord; self.members = members
    }

    /// The lone member when this isn't really a cluster (count == 1).
    var single: Detection? { members.count == 1 ? members.first : nil }

    /// The category tint for the whole bubble: a uniform clump keeps its category tint,
    /// a mixed clump goes neutral.
    var tint: Color {
        let cats = Set(members.map { $0.type.category })
        return cats.count == 1 ? (members.first?.type.tint ?? ACABTheme.accent) : ACABTheme.text
    }

    var shortTag: String { members.count == 1 ? (members.first?.type.shortTag ?? "") : "\(members.count)" }
}

/// A count bubble for a multi-member cluster — sized up a touch for bigger clumps.
private struct ClusterBubble: View {
    let cluster: Cluster
    private var n: Int { cluster.members.count }
    private var diameter: CGFloat {
        switch n {
        case ..<10:  return 34
        case ..<50:  return 40
        case ..<200: return 46
        default:     return 52
        }
    }
    var body: some View {
        ZStack {
            Circle().fill(cluster.tint.opacity(0.22)).frame(width: diameter + 10, height: diameter + 10)
            Circle().fill(ACABTheme.bg2).frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(cluster.tint, lineWidth: 2))
                .shadow(color: cluster.tint.opacity(0.5), radius: 5)
            Text("\(n)")
                .font(ACABTheme.display(n < 100 ? 15 : 13, weight: .bold))
                .foregroundStyle(ACABTheme.text).monospacedDigit()
        }
    }
}

/// Bottom sheet listing the detections inside a tapped cluster; pick one to open it.
private struct ClusterListSheet: View {
    let cluster: Cluster
    let onPick: (Detection) -> Void
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private var members: [Detection] {
        cluster.members.sorted {
            (ble.lastSeenDate(for: $0.id) ?? .distantPast) > (ble.lastSeenDate(for: $1.id) ?? .distantPast)
        }
    }

    var body: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(cluster.members.count) here")
                                .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                            Kicker("CLUSTERED AT THIS SPOT")
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ACABTheme.dim)
                                .frame(width: 32, height: 32)
                                .background(ACABTheme.bg2, in: Circle())
                                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(members.enumerated()), id: \.element.id) { i, d in
                            Button { onPick(d) } label: { DetectionRow(detection: d) }
                                .buttonStyle(.plain)
                            if i < members.count - 1 { Divider().overlay(ACABTheme.line) }
                        }
                    }
                    .panel()
                }
                .padding(ACABTheme.pad)
            }
        }
        .preferredColorScheme(.dark)
    }
}
