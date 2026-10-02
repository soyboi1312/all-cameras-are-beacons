import SwiftUI
import UIKit

// MARK: - Settings hand-off

/// Jump to this app's page in the Settings app. The one shared site for the hand-off, so a
/// future change (a different destination URL, an applicationState guard) lands everywhere
/// at once instead of being edited into five views. Lives here rather than in Shared/ because
/// the Shared/ files also compile into the widget extension, where UIApplication.shared
/// does not exist.
func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

/// Persistent board-side evidence warning, shared by the Log and the Offline Buffer control.
/// It is intentionally not dismissible: the firmware flag remains authoritative until the
/// physical buffer is successfully cleared and the firmware resets its latched health mask.
struct BufferHealthBanner: View {
    let notice: BufferHealthNotice

    var body: some View {
        let tone = notice.critical ? ACABTheme.tint : ACABTheme.warn
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(ACABTheme.font(.subheadline, weight: .semibold))
                .foregroundStyle(tone)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                // The presenter's telegram renders as written.
                Kicker(notice.title, color: tone)
                Text(notice.detail)
                    .font(ACABTheme.font(.footnote))
                    .foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grouped rows

/// One Settings-style row for ScrollView-built screens and for a List cell whose trailing value
/// is a runtime string. Draws NO background (the cell or the List supplies it). Title in body,
/// subtitle and trailing value in secondary subheadline, optional chevron. The trailing value
/// drops UNDER the title whenever the inline form would not fit the offered width
/// (ViewThatFits), and at accessibility text sizes the stacked form is used directly, under the
/// leading glyph. No Text
/// here ever carries lineLimit(1) or a width hug. Simple static rows in a List may use
/// LabeledContent / NavigationLink / Toggle instead; inside a NavigationLink pass
/// `chevron: false` (the List draws its own).
struct GroupedRow<Leading: View>: View {
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron: Bool = false
    /// The subtitle is a telemetry line (a state telegram, "6 ON · 1 EXP · TRACKERS ON"), set in
    /// the instrument face; false for a sentence subtitle, which stays SF.
    var telemetrySubtitle: Bool = false
    private let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = false,
         telemetrySubtitle: Bool = false,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.chevron = chevron
        self.telemetrySubtitle = telemetrySubtitle
        self.leading = leading
    }

    /// At accessibility sizes the leading glyph sits ABOVE the title block, so the text takes the
    /// full cell width: beside a 29pt tile and the chevron, the largest size left the text about
    /// 240pt and hyphenated single words ("Notifica-" / "tions"). An empty leading adds no line.
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    leading()
                    stacked
                }
            } else {
                HStack(spacing: 12) {
                    leading()
                    ViewThatFits(in: .horizontal) {
                        inline
                        stacked
                    }
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// A trailing value sits on the title's baseline. With no value the chevron centres on the
    /// title block instead, as the List's own disclosure does: on the first baseline it sat level
    /// with the title of a two-line row (the regular-width Beacon push rows, R13). Android's
    /// Beacon rows (DeviceScreen.kt BeaconLinkRow) centre their chevron the same way.
    private var inline: some View {
        HStack(alignment: value == nil ? .center : .firstTextBaseline) {
            titleBlock
            Spacer(minLength: 8)
            valueText(.trailing)
            chevronGlyph
        }
    }

    /// The value drops under the title. A chevron with no value stays beside the title block,
    /// centred on it, so the row does not grow a line that holds only the chevron and its
    /// chevron keeps the trailing column of its neighbours.
    @ViewBuilder private var stacked: some View {
        if value == nil && chevron {
            HStack {
                titleBlock
                Spacer(minLength: 8)
                chevronGlyph
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                titleBlock
                if value != nil {
                    HStack {
                        valueText(.leading)
                        Spacer(minLength: 0)
                        chevronGlyph
                    }
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // An uppercase identifier title (the detail's SIGHTINGS) is a label, not a name.
            let labelTitle = ACABTheme.isInstrumentLabel(title)
            Text(title)
                .font(labelTitle ? ACABTheme.telemetry(.body) : ACABTheme.font(.body))
                .tracking(labelTitle ? ACABTheme.telemetryTracking : 0)
                .foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(telemetrySubtitle ? ACABTheme.telemetry(.subheadline, weight: .regular)
                                            : ACABTheme.font(.subheadline))
                    .foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func valueText(_ alignment: TextAlignment) -> some View {
        if let value {
            // Trailing values are data (a telemetry line, a count): the instrument face.
            Text(value)
                .font(ACABTheme.telemetry(.subheadline, weight: .regular))
                .foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var chevronGlyph: some View {
        if chevron {
            Image(systemName: "chevron.right")
                .font(ACABTheme.font(.footnote, weight: .semibold))
                .foregroundStyle(ACABTheme.faint)
                .accessibilityHidden(true)
        }
    }
}

extension GroupedRow where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = false,
         telemetrySubtitle: Bool = false) {
        self.init(title: title, subtitle: subtitle, value: value, chevron: chevron,
                  telemetrySubtitle: telemetrySubtitle) { EmptyView() }
    }
}

/// Settings.app row tile: `size` square, radius size * 0.24, `fill` behind a semibold SF Symbol
/// at size * 0.55 in `glyph`. Defaults are NEUTRAL (bg3 tile, primary ink glyph). The hue form
/// is fill: <tone>, glyph: ACABTheme.onAccent (ContrastPaletteTests holds onAccent at 3:1 or
/// more on every hue, AA on the tint). Pick a fill per row, and never warn on a healthy row.
/// A tile is geometry, so the glyph size is fixed to the tile. The glyph lives in a box of
/// size * 0.7: a font-sized symbol wider than that box (mountain.2 ran edge to edge) scales down
/// to fit it, so a wide symbol keeps the same margin as the rest. Decorative: the row's title
/// speaks.
struct GlyphTile: View {
    let symbol: String
    var fill: Color = ACABTheme.bg3
    var glyph: Color = ACABTheme.text
    var size: CGFloat = 29

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay(
                ViewThatFits(in: .horizontal) {
                    Image(systemName: symbol)
                    Image(systemName: symbol).resizable().scaledToFit()
                }
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(glyph)
                .frame(width: size * 0.7, height: size * 0.7)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Brand

/// Big centered wordmark for the connect screen.
struct ACABWordmark: View {
    var body: some View {
        VStack(spacing: 8) {
            // The pre-redesign wordmark face, restored (R16): Space Grotesk Bold at 46pt on the
            // largeTitle Dynamic Type curve, as 2.0.8 drew it. The brand's own face, like the
            // motto (PunkLine), so it is not an ACABTheme role; Bold is the heaviest bundled cut,
            // so the higher-contrast weight step has nowhere to go and is not applied.
            // TWIN: android AcabApp.kt ConnectHero, the same face on the same "beacons".
            Text("beacons")
                .font(Font.custom("SpaceGrotesk-Bold", size: 46, relativeTo: .largeTitle))
                .foregroundStyle(ACABTheme.text)
                // One line that shrinks to fit instead of truncating: the wordmark is the brand,
                // and "Beac..." is worse than smaller type.
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        // Never wider than the screen, whatever the text size. Without this the VStack reports an
        // ideal width larger than the viewport and everything inside it is clipped symmetrically.
        .frame(maxWidth: .infinity)
    }
}

/// The motto, "they're watching. watch back.", directly under the Status radar's no-direction
/// caption (DashboardView). The redesign dropped it; the owner brought it back on 2026-09-25 (the
/// old display "had the motto on the screen"), so it is on the first screen again, under the
/// caption as in the owner's screenshot of the old Status, not at the foot of the column.
/// "they're watching." in dim, "watch back." in the crimson text ink (accentText), in Space
/// Grotesk Medium, the pre-redesign face: this one line is the brand's voice, not system copy, so
/// it keeps the old font (SpaceGrotesk-Medium.ttf, bundled for the app target only, project.yml).
/// One plain text element, spoken after the caption, with no accessibility modifiers, as the pre-redesign line had.
/// TWIN: android StatusScreen.kt PunkLine, the same words, inks and slot.
struct PunkLine: View {
    var body: some View {
        // Ornamental brand copy, so it is pinned at its design size: at accessibility text
        // sizes every point it grows is a point stolen from the content around it. Upright, as
        // the owner's reference shows. TWIN: android StatusScreen.kt PunkLine, the same words and
        // the same crimson (AcabPalette.crimsonInk = this tint at both levels).
        Text("\(Text("they're watching. ").foregroundStyle(ACABTheme.dim))\(Text("watch back.").foregroundStyle(ACABTheme.accentText))")
            .font(Font.custom("SpaceGrotesk-Medium", fixedSize: 14))
    }
}

/// The board status pill: dot and label in `tint` on an 18 % tint capsule when connected, amber
/// for SAMPLE and the three attention states, `dim` when offline.
struct LinkChip: View {
    /// The pill's word in sample data, read here and by BeaconRadioPresentation.chipLabel so the
    /// two can never disagree. TWIN: android Components.kt `linkChipAppearance` (`demo -> "SAMPLE"`).
    static let sampleLabel = "SAMPLE"

    var connected: Bool
    var demo: Bool = false
    var stateLabel: String? = nil
    var body: some View {
        // dot + CONNECTED / OFFLINE / SAMPLE, same labels and the SAME TINT RULE as the Android
        // LinkChip (Components.kt `stateNeedsAttention`): SAMPLE and the three attention states
        // (RECONNECTING / UPDATING / RADIO FAULT) draw the amber dot, label and fill, so a
        // radio fault never reads as a healthy connected pill. The firmware version lives on the
        // Beacon screen's firmware row; repeating it in the header chip was noise on a pill the
        // user reads as "is my board there or not". The labels render as written (no case
        // transform). The measured ratios hold on bg and bg2 only: never place it on bg3 or
        // on a toolbar's shared glass.
        let stateNeedsAttention = stateLabel == "RECONNECTING" || stateLabel == "UPDATING"
            || stateLabel == "RADIO FAULT"
        let amber = demo || stateNeedsAttention
        let ink: Color = amber ? ACABTheme.warn : (connected ? ACABTheme.tint : ACABTheme.dim)
        let fill: Color = ink.opacity(ACABPalette.pillFillAlpha)
        let label = demo ? Self.sampleLabel : stateLabel ?? (connected ? "CONNECTED" : "OFFLINE")
        return HStack(spacing: 6) {
            Circle().fill(ink)
                .frame(width: 8, height: 8)
            Text(label)
                .font(ACABTheme.telemetry(.subheadline, weight: .semibold))
                .tracking(ACABTheme.telemetryTracking)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(fill, in: Capsule())
    }
}

// MARK: - Category glyph

/// A category glyph, tinted by category: bare on the Dynamic Type curve or on a tile (`Style`).
struct CatGlyph: View {
    enum Style {
        /// No tile: the glyph alone in a column that scales with Dynamic Type, for rows that
        /// show the category as a leading glyph. `size` is ignored.
        case bare
        /// A rounded tile in `fill` (default bg3) with the glyph in the category tint.
        case tile(fill: Color = ACABTheme.bg3)
    }
    let type: DeviceType
    var size: CGFloat = 34
    var style: Style = .tile()
    @ScaledMetric(relativeTo: .title2) private var column: CGFloat = 32

    init(type: DeviceType, size: CGFloat = 34, style: Style = .tile()) {
        self.type = type
        self.size = size
        self.style = style
    }

    var body: some View {
        switch style {
        case .bare:
            Image(systemName: type.symbol)
                .font(ACABTheme.font(.title2, weight: .medium))
                .foregroundStyle(type.tint)
                .frame(width: column)
        case .tile(let fill):
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(fill)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: type.symbol)
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(type.tint)
                )
        }
    }
}

// MARK: - Signal bars

/// Four rising signal-strength bars (0 = nothing, 4 = full).
struct SignalBars: View {
    let bars: Int            // 0...4
    var tint: Color = ACABTheme.tint
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
    /// In priority order (DashboardSnapshot.dots: watched and matched first, then strongest
    /// signal). The first dot is placed first and painted last, so nothing covers it.
    let dots: [RadarDot]
    /// The caller's drawing limit, spoken in the accessibility summary below. Passed in rather
    /// than written into that sentence: this view takes an arbitrary `dots` array and does not
    /// own the cap, so a literal here would be a claim about somebody else's constant, and the
    /// printed caption beside the scope (which does interpolate it) would silently disagree the
    /// day the cap moved.
    let cap: Int
    /// False hides the beam and draws the count in faint ink. A scope that keeps sweeping with
    /// the radios off (or the nRF dark) reads as scanning when nothing is, and a bright 0 under a
    /// parked beam reads as a result when nothing listened. The caller passes the radio
    /// presentation's `isScanning`.
    var sweeping: Bool = true

    /// One radar sweep turn, in seconds (radarSweepDegrees). TWIN: android StatusScreen.kt
    /// `RADAR_SWEEP_PERIOD_MS` (4_500).
    static let sweepPeriod: TimeInterval = 4.5

    /// The count's size at the default text setting, before @ScaledMetric scales it along
    /// .largeTitle. countSizeCap then holds it clear of STRONG at larger text sizes (and, on a
    /// phone narrower than 390pt, a few points under this at the default size).
    static let countBaseSize: CGFloat = 56
    @ScaledMetric(relativeTo: .largeTitle) private var countSize: CGFloat = RadarScope.countBaseSize

    /// How far a ring word's text frame sits from the ring it names (ringLabels). iOS derivation:
    /// every ring is a 1pt strokeBorder, drawn INSIDE its frame, so a ring's top point is also
    /// the top of its ink; 2pt more leaves a visible strip of disc between the stroke and the
    /// word. STRONG's frame bottom therefore sits at cy - s/6 - ringLabelGap. The word sits bare
    /// on the disc (R18, no plate), so its text frame is the edge this measures to.
    static let ringLabelGap: CGFloat = 2
    /// How far WEAK's text frame top sits inside the disc edge: the outer ring's 1pt stroke, which
    /// strokeBorder draws inside the edge, then 3pt of disc before the word.
    static let weakLabelInset: CGFloat = 4
    /// The ring words and the ring each names (1 = inner, 2 = middle, 3 = the disc edge). The middle
    /// ring carries no word: the owner found WEAK and STRONG enough (2026-09-25), and the dots still
    /// snap to all three rings. TWIN: android StatusScreen.kt `RADAR_RING_WORDS`, same words, same rings.
    static let ringWords: [(word: String, ring: Int)] = [("STRONG", 1), ("WEAK", 3)]

    /// The largest count size that keeps the count clear of STRONG at Dynamic Type sizes
    /// (R7). The count block is centred on cy: the count line (SF's line was about 1.2 x the font size when this was derived; the count is JetBrains Mono since R16, whose line is a little taller, and the cap still cleared STRONG at AX5 on 2026-09-26. The old SF figure: 1.2 x the font
    /// size), a 2pt gap, then TOTAL NEARBY at a fixed 13pt (a line of about 16), so the block's
    /// top sits about 0.6 x size + 9 above cy. STRONG's frame bottom is s/6 + ringLabelGap above
    /// cy, so the size may grow until 0.6 x size + 9 reaches it. On a 268pt scope (RadarSideLayout:
    /// 0.75 of a 390pt phone's 358pt column) that is about 56pt, the default count's own size, so
    /// any larger text size is held there and a narrower phone draws the count a few points
    /// under its default.
    /// The spoken summary is unchanged. Floored at 1pt so a degenerate scope never asks for a
    /// zero or negative font size.
    static func countSizeCap(side s: CGFloat) -> CGFloat {
        max(1, (s / 6 - ringLabelGap - 9) / 0.6)
    }

    /// The dot's diameter. A dot's centre never sits further out than s/2 - dotSize/2, so a
    /// weak-band dot (radius 1, the disc edge) stays wholly on the disc. TWIN: android
    /// StatusScreen.kt RadarScope's `rad`, which pulls its weak band in by its own dot's radius
    /// (dotRingPx, 6dp, the same 12-unit diameter) for the same reason.
    static let dotSize: CGFloat = 12

    /// The named space every obstacle frame below is measured in: the scope's own s x s square,
    /// origin at its top-left, so the disc centre is (s/2, s/2).
    private static let space = "radarScope"

    /// The measured frames the dot placement keeps clear of, keyed by what they are: the count
    /// number, the TOTAL NEARBY caption and the two ring words, each the bare text's frame (no
    /// plate padding since R18). Written by onGeometryChange,
    /// which fires only when a frame changes (the count's digits, a contrast or text-size
    /// change), so a publish that moves nothing re-renders nothing here. Empty on the very first
    /// pass; the dots settle one layout later.
    @State private var obstacleFrames: [String: CGRect] = [:]

    /// One placed dot, in the scope's own square.
    private struct PlacedDot: Identifiable {
        let id: String
        let tone: Color
        let offset: CGSize
    }

    /// Where each dot is drawn: its hash angle on its signal band's ring, stepped clear of the
    /// dots already placed and of the obstacle frames (dotPositions).
    private func placedDots(_ s: CGFloat) -> [PlacedDot] {
        let c = CGPoint(x: s / 2, y: s / 2)
        let radii = dots.map { min(CGFloat($0.radius) * s / 2, s / 2 - Self.dotSize / 2) }
        let centres = Self.dotPositions(angles: dots.map(\.angle), ringRadii: radii, centre: c,
                                        dotRadius: Self.dotSize / 2,
                                        obstacles: Array(obstacleFrames.values))
        return dots.indices.map { i in
            PlacedDot(id: dots[i].id, tone: dots[i].tone,
                      offset: CGSize(width: centres[i].x - c.x, height: centres[i].y - c.y))
        }
    }

    /// Where each radar dot is drawn, in the scope's own square.
    ///
    /// Input, in priority order: each dot's hash angle in degrees (a stable MAC hash that carries
    /// no bearing) and the radius of the ring its signal band snaps to. The priority dot is
    /// placed first and keeps its hash angle whenever that spot is free; every later dot that
    /// would land within one dot diameter of a dot already placed, or would touch one of the
    /// `obstacles` (the count number, the TOTAL NEARBY caption and the two ring words, their
    /// bare text frames), steps along its own ring by one dot diameter of arc,
    /// (2 x dotRadius) / ringRadius radians,
    /// until it is clear. Deterministic: the same inputs always give the same picture, so dots do
    /// not jitter between publishes. If a ring has no clear spot left, the dot keeps its hash
    /// angle (an overlap then, never a missing dot). The caller draws the list in REVERSE, so the
    /// priority dot paints last and is never covered.
    ///
    /// Cheap on purpose: body runs it once per pass (a publish is about 3 Hz and there are at
    /// most DashboardSnapshot.dotLimit dots), never per sweep frame; the sweep is its own view.
    /// TWIN: android StatusScreen.kt `radarDotPositions`, the same rule step for step (the same
    /// step, the same clear test, the same fallback). Pinned in DashboardPresentationTests.
    static func dotPositions(angles: [Double], ringRadii: [CGFloat], centre c: CGPoint,
                             dotRadius: CGFloat, obstacles: [CGRect]) -> [CGPoint] {
        let minGap = 2 * dotRadius
        var out: [CGPoint] = []
        out.reserveCapacity(angles.count)
        func clear(_ p: CGPoint) -> Bool {
            for q in out {
                let dx = q.x - p.x, dy = q.y - p.y
                if dx * dx + dy * dy < minGap * minGap { return false }
            }
            for o in obstacles {
                // The rect's nearest point to the dot's centre: inside the dot means they touch.
                let nx = min(max(p.x, o.minX), o.maxX) - p.x
                let ny = min(max(p.y, o.minY), o.maxY) - p.y
                if nx * nx + ny * ny < dotRadius * dotRadius { return false }
            }
            return true
        }
        for i in angles.indices {
            let rad = ringRadii[i]
            let base = angles[i] * .pi / 180
            let step = rad > 0 ? Double(minGap / rad) : 0
            let tries = step > 0 ? Int(2 * Double.pi / step) : 0
            let home = CGPoint(x: c.x + CGFloat(cos(base)) * rad, y: c.y + CGFloat(sin(base)) * rad)
            var placed: CGPoint?
            for t in 0...tries {
                let a = base + Double(t) * step
                let p = CGPoint(x: c.x + CGFloat(cos(a)) * rad, y: c.y + CGFloat(sin(a)) * rad)
                if clear(p) { placed = p; break }
            }
            out.append(placed ?? home)
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let placed = placedDots(s)
            ZStack {
                // The disc the ring words and the TOTAL NEARBY caption sit straight on (R18: no
                // plates). The radar keeps its pre-redesign colours (owner, 2026-09-25): the
                // warm near-black disc, faint warm rings and a crimson edge on ring 3, all radar-only
                // tokens (ACABPalette's radar fields). TWIN: android StatusScreen.kt RadarScope's
                // disc and rings, the same token names.
                Circle().fill(ACABTheme.radarDisc)
                    .frame(width: s, height: s)
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .strokeBorder(i == 3 ? ACABTheme.radarEdge : ACABTheme.radarRing, lineWidth: 1)
                        .frame(width: s * CGFloat(i) / 3, height: s * CGFloat(i) / 3)
                }
                // The pre-redesign crosshair (owner, 2026-09-25: "add back the crosshairs too"):
                // one vertical and one horizontal 1pt line through the centre, the full diameter,
                // in the ring colour. Right after the rings, so the sweep, the ring words, the
                // dots and the count block all draw over it; the vertical line runs on behind the
                // letters of STRONG, WEAK and TOTAL NEARBY, as it did before the redesign (R18
                // removed the plates that used to mask it). Not a dot-placement obstacle: dots may
                // sit on it, as before. TWIN: android StatusScreen.kt RadarScope's two crosshair
                // drawLine calls, same colour token, same layer.
                Path { p in
                    p.move(to: CGPoint(x: s/2, y: 0));  p.addLine(to: CGPoint(x: s/2, y: s))
                    p.move(to: CGPoint(x: 0, y: s/2));  p.addLine(to: CGPoint(x: s, y: s/2))
                }
                .stroke(ACABTheme.radarRing, lineWidth: 1)
                .frame(width: s, height: s)

                // Always mounted; `running` pauses and hides it (SweepBeam says why).
                SweepBeam(size: s, running: sweeping)

                // Under the dots, as android StatusScreen.kt RadarScope draws its ring words
                // before its dots: one z-order on both phones. The placement keeps dots off the
                // words anyway.
                ringLabels(s)

                // Reverse priority order: the watched or strongest dot paints last, on top.
                ForEach(placed.reversed()) { dot in
                    Circle().fill(dot.tone)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .overlay(Circle().strokeBorder(ACABTheme.radarDisc, lineWidth: 2))
                        .offset(dot.offset)
                }

                // Centred on the disc, as android StatusScreen.kt RadarScope centres its count
                // Column (R7). The caption sits straight on the disc (R18): the crosshair, and at
                // some text sizes the inner ring's stroke, run behind its letters.
                countBlock(s)
            }
            .frame(width: s, height: s)
            .coordinateSpace(NamedCoordinateSpace.named(Self.space))
            .frame(maxWidth: .infinity)
        }
        // One spoken element for the whole instrument: the dots and rings are positional
        // decoration a screen reader cannot use, so say what the scope actually knows.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) recently heard device\(count == 1 ? "" : "s") nearby. \(dots.count) dot\(dots.count == 1 ? "" : "s") drawn, at most \(cap), with matches and watched devices first. Radar shows signal strength only, not direction.")
    }

    /// Reports `view`'s frame in the scope's square under `key`, for the dot placement.
    private func measured<V: View>(_ view: V, as key: String) -> some View {
        view.onGeometryChange(for: CGRect.self,
                              of: { (proxy: GeometryProxy) in proxy.frame(in: NamedCoordinateSpace.named(RadarScope.space)) },
                              action: { (frame: CGRect) in obstacleFrames[key] = frame })
    }

    /// STRONG and WEAK (ringWords) naming the inner ring and the disc edge the blips snap to, both
    /// on the vertical axis above centre, each straight on the disc with the crosshair, the rings
    /// and the sweep running behind its letters (R18, the pre-redesign look; the R7 plates are
    /// gone): STRONG just above the inner ring, WEAK just inside the disc edge. The middle ring
    /// has no word. The count block is centred on the disc. TWIN: android StatusScreen.kt
    /// RadarScope's ring labels, which follow the same rule and draw in the same layer (above the
    /// sweep, under the dots). The gaps are ringLabelGap and weakLabelInset above, where their iOS
    /// derivation is written, and countSizeCap caps the scaled count against STRONG.
    ///
    /// Each word is anchored by its text frame's EDGE, not its centre, so no label height is
    /// guessed: STRONG's frame bottom sits ringLabelGap above the inner ring's top point
    /// (cy - s/6), and WEAK's frame top sits weakLabelInset below the disc's top (cy - s/2).
    ///
    /// THESE ARE STRENGTH WORDS, NOT DISTANCE WORDS. They were NEAR / MID / FAR until
    /// 2026-09-08, which labelled a signal-strength quantity with distance, and the screen then
    /// had to walk it back twice on itself: the caption under the disc says SIGNAL STRENGTH ONLY
    /// - NO DIRECTION and radarCaptionDetail says the same again. RSSI is not distance, because
    /// transmit power is a per-DEVICE choice (faq-content.json q-signal spells this out): a
    /// pole-mounted ALPR camera reads strong from across a street while a tracking tag a few
    /// meters away reads weak. The vocabulary is `beaconSignalDescription`'s, so the ring a blip
    /// sits on and the word VoiceOver speaks for its bars cannot disagree. Do not put NEAR / MID /
    /// FAR back.
    ///
    /// Decorative instrument chrome: the whole scope is one spoken element (body), so VoiceOver
    /// never reads these words as stray elements.
    private func ringLabels(_ s: CGFloat) -> some View {
        let cy = s / 2
        let weakTop = cy - s / 2 + Self.weakLabelInset
        return ZStack(alignment: .top) {
            ForEach(Self.ringWords.indices, id: \.self) { i in
                let entry = Self.ringWords[i]
                if entry.ring == 3 {
                    // The edge word hangs INSIDE the disc: its frame top sits weakLabelInset down.
                    measured(ringLabel(entry.word), as: entry.word)
                        .frame(maxWidth: .infinity)
                        .padding(.top, max(0, weakTop))
                } else {
                    // A frame whose height is the word's bottom edge, bottom-aligned, puts that
                    // edge exactly ringLabelGap above the ring's top point (cy - s * ring / 6).
                    measured(ringLabel(entry.word), as: entry.word)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(0, cy - s * CGFloat(entry.ring) / 6 - Self.ringLabelGap),
                               alignment: .bottom)
                }
            }
        }
        .frame(width: s, height: s, alignment: .top)
        .allowsHitTesting(false)
    }

    private func ringLabel(_ text: String) -> some View {
        // Fixed size on purpose (ACABTheme.fixed, instrument chrome): positioned absolutely on
        // the scope's fixed geometry. On the Dynamic Type curve these grew at accessibility
        // sizes and overlapped each other and the count. The scope's real content (the count)
        // still scales, and the scope speaks a full summary for VoiceOver. The bare word, no
        // padding and no plate: the owner read the R7 disc-coloured capsules as "an outline
        // around" the words once R10 brought back the crosshair and the old disc (R18,
        // 2026-09-26), so the sweep, the rings and the crosshair pass behind the letters as they
        // did in 2.0.8. TWIN: android StatusScreen.kt RadarScope's ring-label drawText, the bare
        // layout with no drawRoundRect under it.
        Text(text)
            .font(ACABTheme.telemetryFixed(12, weight: .medium))
            .tracking(ACABTheme.telemetryTracking)
            .foregroundStyle(ACABTheme.dim)
    }

    /// The count and its caption, centred on the disc.
    private func countBlock(_ s: CGFloat) -> some View {
        VStack(spacing: 2) {
            measured(
                Text("\(count)")
                    .font(ACABTheme.telemetryFixed(min(countSize, Self.countSizeCap(side: s)), weight: .bold))
                    // Faint while the board is not scanning (sweeping false): a 0 over parked
                    // radios is not a result (STA-1).
                    .foregroundStyle(sweeping ? ACABTheme.text : ACABTheme.faint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.25),
                as: "COUNT")
                .frame(maxWidth: s * 0.82)
            // Includes matched/watched and ambient devices, separated below the scope.
            // It is still a recent, not whole-Log, count.
            // Fixed size on purpose (ACABTheme.fixed, off the Dynamic Type curve): this
            // label lives inside the scope's fixed geometry, where a scaling caption
            // collided with the count. The count itself (real content) keeps scaling
            // through countSize; the whole scope carries a spoken summary below.
            // Capped to the inner ring's diameter less a margin: on a narrow phone even
            // the full chord cannot hold the caption, so it scales down (the literal stays).
            // Straight on the disc, no padding and no plate (R18, the 2.0.8 look): the crosshair
            // and the sweep pass behind the letters, and so does the inner ring's stroke when the
            // scaled count pushes the caption down to it. The R7 plate that hid them read as an
            // outline once R10 restored the crosshair. TWIN: android StatusScreen.kt RadarScope's
            // bare TOTAL NEARBY kicker (no disc-coloured Box). The measured frame is the text's
            // own: the width cap comes after it.
            measured(
                Text("TOTAL NEARBY")
                    .font(ACABTheme.telemetryFixed(12, weight: .medium))
                    .tracking(ACABTheme.telemetryTracking)
                    .foregroundStyle(ACABTheme.dim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75),
                as: "TOTAL")
                .frame(maxWidth: max(0, s / 3 - 4))
        }
    }
}

/// Sizes the Status radar: a square whose side is `fraction` of the column's width, capped at
/// `cap`, centred in the full column width. The owner asked for the radar about 25 % smaller on
/// 2026-09-25 ("it takes up so much space"), so the side went from the whole column (capped at
/// 420) to three quarters of it (capped at 315, three quarters of 420). RadarScope sizes
/// everything inside (the rings, the ring words, countSizeCap, the dot placement) from the
/// side it is given, so only this changes. A Layout, not a GeometryReader: it reports its own
/// height (the side), so the caption and the motto sit directly under the disc.
/// TWIN: android StatusScreen.kt, the RadarScope call's width modifier (0.75 of the column,
/// capped at 315dp), the same fraction and cap.
struct RadarSideLayout: Layout {
    static let fraction: CGFloat = 0.75
    static let cap: CGFloat = 315

    /// The radar's side for a column `width` wide. Pure, so a test can pin it.
    static func side(column width: CGFloat) -> CGFloat {
        guard width.isFinite else { return cap }
        return max(0, min(width * fraction, cap))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let side = Self.side(column: proposal.width ?? .infinity)
        // The full column width, so the square centres in it (placeSubviews); a nil or infinite
        // proposal (an ideal-size query) gets the capped square alone.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? side
        return CGSize(width: width, height: side)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let side = Self.side(column: bounds.width)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                          proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

/// The radar sweep's angle in degrees at an absolute clock reading: fract(seconds / period) x 360,
/// clockwise on screen (positive rotation, y down). Read from an absolute clock, never from a
/// per-view start time, so a re-mount, a tab return or a flicker of the scanning flag continues
/// the phase instead of restarting it at 0 (M3). Handles negative readings (fract rounds down).
/// TWIN: android StatusScreen.kt `radarSweepDegrees` (RADAR_SWEEP_PERIOD_MS, the same 4.5 s).
func radarSweepDegrees(at seconds: TimeInterval, period: TimeInterval = RadarScope.sweepPeriod) -> Double {
    guard period > 0, seconds.isFinite else { return 0 }
    let turns = seconds / period
    return (turns - turns.rounded(.down)) * 360
}

/// The rotating angular gradient that fakes a radar sweep beam: a crimson wedge drawn under the
/// dots and the count, its bright edge leading (the 0.99 stop). The colour is the pre-redesign
/// sweep the owner kept on 2026-09-25: the old accent at 0.40 (radarSweep carries the alpha),
/// screen-blended onto the disc, which is what made it vivid rather than dull. ALWAYS mounted: while
/// the board is not scanning it is paused and hidden (opacity 0, no hit testing), never removed,
/// so nothing can restart it. The angle comes from the frame clock (radarSweepDegrees of the
/// TimelineView's date), not an implicit repeatForever animation, so a Status re-render (the
/// ~3 Hz publish, the 1 s tick) can neither retarget nor reset it. Only this TimelineView's
/// content redraws per frame; RadarScope's body, the dot placement and the Status snapshot do
/// not. Reduce Motion pauses the timeline and parks the beam at 0 degrees with the gradient still
/// visible, so a scanning scope still reads as distinct from a parked one.
/// TWIN: android StatusScreen.kt RadarScope's sweep (radarSweepDegrees written by a
/// withFrameNanos loop), the same period and direction. The COLOUR is not a twin: each phone
/// restores its OWN old sweep (iOS the accent at 0.40 with .screen; Android its old accentGlow,
/// 55 % at normal contrast, plain SrcOver), because that is what each one looked like before the redesign.
private struct SweepBeam: View {
    let size: CGFloat
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !running || reduceMotion)) { ctx in
            beam
                .rotationEffect(.degrees(reduceMotion
                    ? 0 : radarSweepDegrees(at: ctx.date.timeIntervalSinceReferenceDate)))
                // The angle is already the frame's answer; an ancestor's animation must never
                // interpolate it (a 359 -> 1 degree step would spin the beam backwards).
                .transaction { $0.animation = nil }
        }
        .opacity(running ? 1 : 0)
        // Outermost, as the pre-redesign beam had it: the wedge screens onto the disc and rings
        // under it, so an inner layer (the opacity above) never isolates the blend.
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var beam: some View {
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: [
                .init(color: ACABTheme.radarSweep.opacity(0.0), location: 0.72),
                .init(color: ACABTheme.radarSweep,              location: 0.99),
                .init(color: ACABTheme.radarSweep.opacity(0.0), location: 1.0),
            ]), center: .center))
            .frame(width: size, height: size)
    }
}

/// The signal graph's fixed dBm scale: -100 at the floor, -30 at the ceiling, on both apps. The
/// band edges -90 / -80 / -67 (Detection.signalBars) then sit at about 14 % / 29 % / 47 % of the
/// plot, so the weak, good and strong bands each get visible height; -30 is the ceiling the
/// sample history already clamps to and -100 sits under its -99 floor. A reading outside the
/// range pins to the nearer edge. TWIN: android DetailScreen.kt `SIGNAL_GRAPH_FLOOR_DBM` /
/// `SIGNAL_GRAPH_CEILING_DBM`.
let signalGraphFloorDbm = -100
let signalGraphCeilingDbm = -30

/// Where `rssi` sits on the signal graph: 0 at the floor, 1 at the ceiling, clamped. One fixed
/// scale for every row, so a weak device draws low instead of being stretched to fill the plot
/// by its own min...max. TWIN: android DetailScreen.kt `signalGraphFraction`.
func signalGraphFraction(rssi: Int) -> Double {
    let clamped = min(max(rssi, signalGraphFloorDbm), signalGraphCeilingDbm)
    return Double(clamped - signalGraphFloorDbm) / Double(signalGraphCeilingDbm - signalGraphFloorDbm)
}

/// Line sparkline of an RSSI series on the fixed dBm scale above (signalGraphFraction). Draws
/// nothing with fewer than two readings: on a fixed scale a placeholder midline would read as a
/// -65 dBm reading.
struct Sparkline: View {
    let values: [Int]
    var tint: Color = ACABTheme.tint
    var body: some View {
        GeometryReader { geo in
            if values.count >= 2 {
                linePath(geo.size)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
    }

    /// x spreads the readings across the width; y places each by its fixed-scale fraction inside
    /// a 7 % inset at the top and bottom, so the 2pt stroke is never cut at an edge.
    private func point(_ i: Int, _ size: CGSize) -> CGPoint {
        let x = size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
        let y = size.height - size.height * 0.86 * CGFloat(signalGraphFraction(rssi: values[i]))
            - size.height * 0.07
        return CGPoint(x: x, y: y)
    }
    private func linePath(_ size: CGSize) -> Path {
        Path { p in
            p.move(to: point(0, size))
            for i in 1..<values.count { p.addLine(to: point(i, size)) }
        }
    }
}

extension Detection {
    /// Last 4 hex of the MAC, uppercased, a short "node" handle.
    var nodeName: String {
        String(mac.replacingOccurrences(of: ":", with: "").suffix(4)).uppercased()
    }
    /// Per-type vendor guess for the dossier subtitle (`maker ?? vendor`), so a row the board
    /// could not name never repeats its type label there. Body cam reads the signature carried
    /// in the wire detail string (it survives BLE address randomization, where there is no OUI
    /// to look up); an unrecognized or missing signature names the category's makers rather
    /// than picking one, because the category alone cannot name a maker: the Axon payload tag
    /// and the broad Motorola proxy both arrive as t=3. Also one of the nine Log search fields
    /// (DetectionLogQuery.foldedHaystack), which is why this table is BYTE-IDENTICAL to Android:
    /// a vendor word on one platform only means the same query lenses different rows, and a
    /// different CSV/GPX, on the two phones. Pinned by DetectionLogLensTests and
    /// LogExportLensTest ("axon" finds an Axon signature and not a Motorola one; "unverified"
    /// finds nothing).
    /// TWIN: Android `Detection.vendor` in Models.kt, arm for arm, literal for literal.
    var vendor: String {
        switch type {
        case .flockCamera, .flockRaven: return "Flock Safety"
        case .axonBodyCam:              return bodyCamSignature?.vendor ?? "Axon / Utility / Motorola"
        case .tracker:                  return "Item tracker"
        case .drone:                    return "Drone maker"
        case .recordingGlasses:         return "Smart glasses"
        case .watched:                  return "Watched device"
        // The dossier leads with `maker` (the "<vendor> on wifi" detail) when the board named
        // the brand; this is the honest fallback when it did not.
        case .networkCamera:            return "IP camera"
        // Android's `else` arm: NEARBY_DEVICE, and UNKNOWN for a future wire type this build
        // can't name.
        case .nearbyDevice, .unknown:   return "Unknown vendor"
        }
    }
}

// MARK: - Debug main-thread stack

/// Builds its content in its OWN body update instead of inline in the caller's view value.
///
/// Why: in a Debug (-Onone) build, a computed `some View` getter keeps full stack copies of every
/// intermediate view value it builds, and a caller that chains modifiers over it copies that value
/// again at each stage. An iPhone's main thread has 1 MiB of stack (the simulator's has 8 MiB,
/// which hides the problem), so a heavy subtree built inline under a deep modifier chain crashed
/// the Debug app on the phone with EXC_BAD_ACCESS (code=2) in the Map legend's body (then
/// `MapTabView.legendPanel`, since replaced by `MapTabView.legendCard`; measured 2026-09-25: the
/// Map tab's first render needed 104% of 1 MiB; deferred, 20%). Wrapping the
/// subtree here keeps the caller's value to a closure, and SwiftUI builds the subtree after the
/// caller's getters have returned. The crash was in a Debug build; optimized Release builds were
/// not measured.
///
/// Not Equatable on purpose: a closure never compares equal, so the content re-evaluates whenever
/// the caller's body does, exactly as it did inline. Layout-transparent: a custom view's body adds
/// no container, so ViewThatFits, safeAreaInset, overlay and layoutPriority see the same child.
/// Named DeferredView, not Deferred: files that import Combine would see Combine's `Deferred`.
struct DeferredView<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View { content() }
}

// MARK: - Small reused bits

/// The one EXP tag for experimental detectors: tinted amber, matching on both platforms.
/// Amber text on an amber 14 % fill, radius 4, no border.
struct ExpTag: View {
    var body: some View {
        Text("EXP")
            .font(ACABTheme.telemetry(.caption2, weight: .semibold))
            .foregroundStyle(ACABTheme.warn)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(ACABTheme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Category tile strips

/// Lays category tiles out in equal-width columns: `preferred` across while the widest tile's
/// natural width fits an equal share of the row, otherwise rows of three, then rows of two. Two
/// is the floor. The one strip (DashboardView's category tiles) labels in the instrument face,
/// telemetry(.caption) with telemetryTracking (R16): JetBrains Mono at 11pt, every glyph 600 of
/// 1000 units (JetBrainsMono-Medium.ttf), so NETCAM is about 6 x (0.6 x 11 + 0.8) = 44.4pt at the
/// default size, under the ~53.3pt six-across share of the 350pt strip
/// CategoryStripLayoutTests uses (the SF caption it replaced measured about 50pt); the wrap rule
/// is unchanged.
/// The widest tile is set by its label (the tiles carry no horizontal padding), so this is the
/// "does every label still fit on one line" test, made on the real rendered size at the current
/// Dynamic Type and weight (Bold Text, higher contrast) rather than on a fixed size threshold.
///
/// It replaced a fixed rule that wrapped only at accessibility sizes. The labels grew from 8 to
/// 10pt on 2026-09-20, and a 10pt label reaches its six-across share a few Dynamic Type steps
/// sooner, so the wrap has to follow the text, not a named size.
///
/// TWIN: android ui/Components.kt `categoryTilesPerRow`, the same rule with Android's own
/// geometry (its tiles pad the sides, so its share subtracts the padding). Each platform derives
/// its own numbers; the RULE is shared.
struct CategoryStripLayout: Layout {
    var preferred: Int
    var spacing: CGFloat

    /// The decision, apart from any view, so BeaconsTests can pin it. The fit is tested in the
    /// additive form (n tiles plus n - 1 gaps against the row) so that the ideal width built in
    /// sizeThatFits round-trips exactly instead of landing a hair under the share.
    static func columns(widestTile: CGFloat, rowWidth: CGFloat, preferred: Int, count: Int,
                        spacing: CGFloat) -> Int {
        let wanted = max(1, min(preferred, count))
        func fits(_ n: Int) -> Bool {
            widestTile * CGFloat(n) + spacing * CGFloat(n - 1) <= rowWidth
        }
        return [wanted, 3, 2].filter { $0 <= wanted }.first { $0 <= 2 || fits($0) } ?? wanted
    }

    private func columns(_ width: CGFloat, _ subviews: Subviews) -> Int {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return Self.columns(widestTile: widest, rowWidth: width, preferred: preferred,
                            count: subviews.count, spacing: spacing)
    }

    private func columnWidth(_ width: CGFloat, _ columns: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    private func rowHeights(_ subviews: Subviews, _ columns: Int, _ columnWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? {
            let wanted = CGFloat(max(1, min(preferred, subviews.count)))
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            return widest * wanted + spacing * (wanted - 1)
        }()
        let cols = columns(width, subviews)
        let heights = rowHeights(subviews, cols, columnWidth(width, cols))
        return CGSize(width: width,
                      height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let cols = columns(bounds.width, subviews)
        let colWidth = columnWidth(bounds.width, cols)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, cols, colWidth).enumerated() {
            for col in 0..<cols {
                let i = row * cols + col
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(col) * (colWidth + spacing), y: y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: colWidth, height: height))
            }
            y += height + spacing
        }
    }
}

// MARK: - Tab header (M2)

/// Does a tab root draw its title and buttons as ONE header row at this text size? Yes below the
/// accessibility sizes; at accessibility sizes the root falls back to the system bar (TabHeader),
/// because the bar cannot grow and the title must never clip.
func tabHeaderUsesSingleRow(_ size: DynamicTypeSize) -> Bool { !size.isAccessibilitySize }

/// One header row for each tab root (Status, Map, Log, Beacon): the title at the leading edge and
/// that tab's buttons trailing, on the same line, inside the system navigation bar so the Log's
/// `.searchable` keeps working and pushed screens keep their standard bars.
///
/// - `.navigationTitle(title)` stays, so a pushed screen's back label still names the tab.
/// - Single-row form (tabHeaderUsesSingleRow): the bar is `.inline`; a VoiceOver-hidden empty
///   principal item keeps the inline title from drawing a second time; the leading item draws the
///   title in `.title` bold with the header trait. Title1, not LargeTitle: at xxxLarge (the
///   largest non-accessibility size) Title1 is 34pt on a 41pt line and fits the 44pt bar, while
///   LargeTitle reaches 40pt on a 48pt line and would clip (Apple's Dynamic Type size table).
///   On iOS 26 the title and the empty principal item carry `.sharedBackgroundVisibility(.hidden)`
///   so no glass capsule is drawn around them; the buttons keep the system glass. The branch is
///   at the VIEW level, because availability branching inside a ToolbarContentBuilder is not
///   assumed (the plain `if` on usesHiddenPrincipal inside it is an ordinary builder branch).
/// - No principal at regular width on iOS 26 (usesHiddenPrincipal): there the tab bar floats at
///   the top in the bar's centre, the inline title has no centre slot to draw in, and a principal
///   item is given a second bar row of its own. Measured on the iPad Pro 13-inch (M5) simulator,
///   iOS 27, 2026-09-25, Beacon tab: with the principal the navigation bar was 108pt tall and
///   the hero sat 54pt lower, the empty band under the tab bar row that the Status, Map and Log
///   roots showed too; without it the bar is 54pt, the content starts right under that row, and
///   the title still draws once, leading.
/// - Accessibility sizes: today's system bar, `accessibilityTitleMode` (`.large` for Status, Log
///   and Beacon; `.inline` for the Map, which keeps as much map height as possible), with the
///   same buttons as trailing items.
/// - A root with no buttons passes `{ EmptyView() }` and gets no trailing item group
///   (`hasTrailingItems`).
///
/// The buttons pass through unchanged: labels, hints, gates and hit targets are the caller's.
/// TWIN: android MainScreen.kt's per-tab top bar, which has always drawn the title and actions in
/// one row.
struct TabHeader<Trailing: View>: ViewModifier {
    let title: String
    let accessibilityTitleMode: NavigationBarItem.TitleDisplayMode
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var hSize

    /// Compact width only: there the tab bar is at the bottom and the bar's centre is free, so the
    /// inline title would draw there a second time. At regular width the floating tab bar holds
    /// the centre (see the type's doc comment for the measurement). The iOS 18 branch below keeps
    /// its principal at every width: no iPadOS 18 runtime was measured.
    private var usesHiddenPrincipal: Bool { hSize != .regular }

    /// False for a root that passes no buttons (`{ EmptyView() }`, the Map, whose buttons float
    /// on the map): then no trailing group is added at all, so iOS 26 draws no empty glass
    /// capsule at the bar's trailing edge. An ordinary builder branch, like usesHiddenPrincipal.
    private var hasTrailingItems: Bool { Trailing.self != EmptyView.self }

    @ViewBuilder
    func body(content: Content) -> some View {
        let titled = content.navigationTitle(title)
        if tabHeaderUsesSingleRow(dynamicTypeSize) {
            if #available(iOS 26, *) {
                titled
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if usesHiddenPrincipal {
                            ToolbarItem(placement: .principal) { hiddenPrincipal }
                                .sharedBackgroundVisibility(.hidden)
                        }
                        ToolbarItem(placement: .topBarLeading) { titleText }
                            .sharedBackgroundVisibility(.hidden)
                        if hasTrailingItems {
                            ToolbarItemGroup(placement: .topBarTrailing) { trailing() }
                        }
                    }
            } else {
                titled
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .principal) { hiddenPrincipal }
                        ToolbarItem(placement: .topBarLeading) { titleText }
                        if hasTrailingItems {
                            ToolbarItemGroup(placement: .topBarTrailing) { trailing() }
                        }
                    }
            }
        } else {
            titled
                .navigationBarTitleDisplayMode(accessibilityTitleMode)
                .toolbar {
                    if hasTrailingItems {
                        ToolbarItemGroup(placement: .topBarTrailing) { trailing() }
                    }
                }
        }
    }

    /// Takes the principal slot so the inline title is not drawn a second time in the middle.
    private var hiddenPrincipal: some View {
        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(ACABTheme.font(.title, weight: .bold))
            .foregroundStyle(ACABTheme.text)
            .lineLimit(1)
            // A bar item is offered less width than its text on iOS 26, which truncated the title
            // to "..." (simulator, every tab). Its ideal width is the title's own.
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A tab root's header row (TabHeader): `title` leading, `trailing` buttons on the same line.
    func tabHeader<Trailing: View>(_ title: String,
                                   accessibilityTitleMode: NavigationBarItem.TitleDisplayMode = .large,
                                   @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        modifier(TabHeader(title: title, accessibilityTitleMode: accessibilityTitleMode,
                           trailing: trailing))
    }
}
