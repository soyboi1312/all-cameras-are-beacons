import SwiftUI

// MARK: - Brand

/// Small in-app wordmark.
struct BrandMark: View {
    var size: CGFloat = 20
    var body: some View {
        Text("Beacons")
            .font(ACABTheme.display(size, weight: .bold))
            .foregroundStyle(ACABTheme.text)
    }
}

/// Big centered wordmark for the connect screen.
struct ACABWordmark: View {
    var subtitle: String? = "ALL CAMERAS ARE BEACONS"
    var body: some View {
        VStack(spacing: 8) {
            Text("Beacons")
                .font(ACABTheme.display(46, weight: .bold))
                .foregroundStyle(ACABTheme.text)
            if let subtitle { Kicker(subtitle, color: ACABTheme.faint) }
        }
    }
}

/// The board status pill: crimson dot + glow when connected, amber "DEMO" in sample-data mode.
struct LinkChip: View {
    var label: String = "ESP32"
    var connected: Bool
    var demo: Bool = false
    var body: some View {
        let tone = demo ? ACABTheme.warn : (connected ? ACABTheme.accent : ACABTheme.faint)
        return HStack(spacing: 6) {
            Circle().fill(tone)
                .frame(width: 7, height: 7)
                .shadow(color: demo ? ACABTheme.warn.opacity(0.6)
                                    : (connected ? ACABTheme.accentGlow : .clear), radius: 4)
            Kicker(demo ? "DEMO" : label,
                   color: demo ? ACABTheme.warn : (connected ? ACABTheme.dim : ACABTheme.faint))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(demo ? ACABTheme.warn.opacity(0.4) : ACABTheme.line, lineWidth: 1))
    }
}

/// Blinking "live" dot.
struct ScanDot: View {
    var color: Color = ACABTheme.accent
    @State private var on = true
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.25)
            .shadow(color: color.opacity(0.5), radius: 3)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = false } }
    }
}

// MARK: - Category glyph

/// A category glyph in a rounded tile, tinted by category.
struct CatGlyph: View {
    let type: DeviceType
    var size: CGFloat = 34
    var filled: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(filled ? type.tint.opacity(0.16) : ACABTheme.bg3)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(ACABTheme.line, lineWidth: 1)
            )
            .overlay(
                Image(systemName: type.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(type.tint)
            )
    }
}

// MARK: - Signal bars

/// Four rising signal-strength bars (0 = nothing, 4 = full).
struct SignalBars: View {
    let bars: Int            // 0...4
    var tint: Color = ACABTheme.accent
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? tint : ACABTheme.line)
                    .frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
    }
}

// MARK: - Radar scope (the signature element)

struct RadarDot: Identifiable {
    let id: String
    let angle: Double     // degrees
    let radius: Double    // 0...1 (0 = center)
    let tone: Color
}

struct RadarScope: View {
    let count: Int
    let dots: [RadarDot]
    @State private var sweep = 0.0

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .strokeBorder(i == 3 ? ACABTheme.lineStrong : ACABTheme.line, lineWidth: 1)
                        .frame(width: s * CGFloat(i) / 3, height: s * CGFloat(i) / 3)
                }
                Path { p in
                    p.move(to: CGPoint(x: s/2, y: 0));  p.addLine(to: CGPoint(x: s/2, y: s))
                    p.move(to: CGPoint(x: 0, y: s/2));  p.addLine(to: CGPoint(x: s, y: s/2))
                }
                .stroke(ACABTheme.line, lineWidth: 1)

                // rotating angular gradient fakes a radar sweep beam
                Circle()
                    .fill(AngularGradient(gradient: Gradient(stops: [
                        .init(color: ACABTheme.accent.opacity(0.0),  location: 0.72),
                        .init(color: ACABTheme.accent.opacity(0.40), location: 0.99),
                        .init(color: ACABTheme.accent.opacity(0.0),  location: 1.0),
                    ]), center: .center))
                    .frame(width: s, height: s)
                    .rotationEffect(.degrees(sweep))
                    .blendMode(.screen)

                ForEach(dots) { dot in
                    Circle().fill(dot.tone)
                        .frame(width: 8, height: 8)
                        .shadow(color: dot.tone.opacity(0.8), radius: 5)
                        .offset(x: CGFloat(cos(dot.angle * .pi/180) * dot.radius) * s/2,
                                y: CGFloat(sin(dot.angle * .pi/180) * dot.radius) * s/2)
                }

                VStack(spacing: 2) {
                    Text("\(count)")
                        .font(ACABTheme.display(62, weight: .bold))
                        .foregroundStyle(ACABTheme.text)
                        .monospacedDigit()
                    Kicker("DEVICES NEARBY")
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity)
            .onAppear {
                withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) { sweep = 360 }
            }
        }
    }
}

/// "they're watching - watch back."
struct PunkLine: View {
    var body: some View {
        (Text("they're watching. ").foregroundStyle(ACABTheme.dim)
         + Text("watch back.").foregroundStyle(ACABTheme.accent).italic())
            .font(ACABTheme.display(14, weight: .medium))
    }
}

/// Filled-area sparkline of a number series (e.g. an RSSI trend).
struct Sparkline: View {
    let values: [Int]
    var tint: Color = ACABTheme.accent
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if values.count >= 2 {
                ZStack {
                    areaPath(size)
                        .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    linePath(size)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(tint.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
    }

    private func point(_ i: Int, _ size: CGSize) -> CGPoint {
        let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
        let range = max(1, hi - lo)
        let x = size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
        let y = size.height - size.height * 0.86 * CGFloat((Double(values[i]) - lo) / range) - size.height * 0.07
        return CGPoint(x: x, y: y)
    }
    private func linePath(_ size: CGSize) -> Path {
        Path { p in
            p.move(to: point(0, size))
            for i in 1..<values.count { p.addLine(to: point(i, size)) }
        }
    }
    private func areaPath(_ size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for i in values.indices { p.addLine(to: point(i, size)) }
            p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath()
        }
    }
}

extension Detection {
    /// Last 4 hex of the MAC, uppercased — a short "node" handle.
    var nodeName: String {
        String(mac.replacingOccurrences(of: ":", with: "").suffix(4)).uppercased()
    }
    /// Friendly vendor guess for the detail screen.
    var vendor: String {
        switch type {
        case .flockCamera, .flockRaven: return "Flock Safety"
        case .drone:                    return "UAS · Remote ID"
        case .axonBodyCam:              return "Axon (unverified)"
        case .tracker:                  return "Item tracker"
        }
    }
    /// Short category label for the badge pill.
    var classLabel: String {
        switch type {
        case .flockCamera: return "PLATE READER"
        case .flockRaven:  return "AUDIO SENSOR"
        case .drone:       return "AERIAL · RID"
        case .axonBodyCam: return "BODY CAMERA"
        case .tracker:     return "ITEM TRACKER"
        }
    }
}

// MARK: - Small reused bits

struct Tag: View {
    let text: String
    var color: Color = ACABTheme.dim
    var body: some View {
        Text(text)
            .font(ACABTheme.mono(9, weight: .bold)).tracking(1)
            .foregroundStyle(ACABTheme.onAccent)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Inline confidence %, colored by how high it is (dim / amber / crimson).
struct ConfidenceBadge: View {
    let value: Int
    var experimental: Bool = false
    var body: some View {
        HStack(spacing: 4) {
            if experimental { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
            Text("\(value)%").font(ACABTheme.mono(11, weight: .semibold))
        }
        .foregroundStyle(experimental ? ACABTheme.warn : color)
    }
    private var color: Color {
        switch value {
        case ..<50: return ACABTheme.dim
        case ..<80: return ACABTheme.warn
        default:    return ACABTheme.accent
        }
    }
}
