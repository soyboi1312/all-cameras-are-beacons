import SwiftUI
import UIKit
import Observation

// MARK: - Palette values

/// One sRGB colour with alpha, kept as plain numbers so the palette can be measured (WCAG
/// contrast in ContrastPaletteTests) without resolving a UIColor.
struct ACABTone: Equatable {
    let r: Double, g: Double, b: Double, a: Double

    init(_ hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8)  & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    /// This tone composited over an opaque surface (alpha blending in sRGB space, which is
    /// how the renderer blends it and what the contrast measurement must therefore use).
    func over(_ bg: ACABTone) -> ACABTone {
        ACABTone(r: r * a + bg.r * (1 - a),
                 g: g * a + bg.g * (1 - a),
                 b: b * a + bg.b * (1 - a))
    }
}

/// The complete set of colour tokens for ONE contrast level. Two instances exist: `.normal`
/// (the default look) and `.high` (what "increase contrast" resolves to). Every ACABTheme
/// colour is a dynamic UIColor that picks between the two by the `accessibilityContrast`
/// trait, so the choice is made per render, not at launch.
///
/// Derivation (Route A, 2026-09-23). Surfaces, inks, `tint` and `line` are iOS-derived: the
/// dark system grouped backgrounds (page, cell, tertiary fill), label white, the dark system
/// separator, and `dim`, an app grey held >= 7:1 on the grouped cell (ContrastPaletteTests),
/// because UIColor.secondaryLabel measures under that on the cell.
/// The seven category tones and `sandTone` are the same colour to 8-bit precision as Android
/// `AcabPalette` at both levels (`axonTone` here is `bodyCamTone` there), and the hue columns
/// of the widget target's `WidgetTheme` (DetectionsWidget.swift) match the Normal values,
/// except the Live Activity's netcam column (`teal`, 6EA8E0), a per-surface difference.
/// Android documents its own M3 derivation of surfaces, inks and accent in Theme.kt.
/// RETIRED on 2026-09-23: the rule that every shared token is the same colour on iOS, Android
/// and the web css. Surfaces, inks, `tint` and `onAccent` differ per platform ON PURPOSE; do not
/// "fix" them back to Android's values. Only the tone bytes are twins.
///
/// Rules the measurements force (ContrastPaletteTests):
/// 1. Text surfaces are `bg` and `bg2`. `bg3` is a FILL (glyph tiles, inputs, thumbnails):
///    words on it are only AA at either level; the 7:1 promises hold on bg and bg2.
/// 2. `flockTone` is never text. Crimson words are `tint` (DeviceType.textTint routes them).
/// 3. Category tones as words clear AA on bg and bg2; on bg3 they are glyphs (3:1).
/// 4. A tinted pill (`pillFillAlpha`) sits on bg or bg2, never on bg3.
/// 5. Destructive rows use `Button(role: .destructive)` (system red); there is no token for it.
struct ACABPalette: Equatable {
    // Surfaces
    let bg: ACABTone, bg2: ACABTone, bg3: ACABTone
    let line: ACABTone
    // Text
    let text: ACABTone, dim: ACABTone, faint: ACABTone
    // The one accent (crimson) + amber
    let tint: ACABTone
    let onAccent: ACABTone, warn: ACABTone
    // Category tones
    let flockTone: ACABTone, droneTone: ACABTone, axonTone: ACABTone, trackerTone: ACABTone
    let watchTone: ACABTone, glassesTone: ACABTone, netcamTone: ACABTone, sandTone: ACABTone
    // The Status radar only (RadarScope, SweepBeam). These are the pre-redesign instrument
    // colours, from the committed palette before Route A, which the owner kept on 2026-09-25
    // ("the old colors looked better"). Nothing but the radar reads them; do not route another
    // surface through them, and do not "fix" them to bg2 / line / tint.
    // radarDisc: the disc and the dots' knockout ring (the ring-word and TOTAL NEARBY plates went with R18);
    // the old warm near-black page the radar used to sit on.
    // radarRing: the inner and middle rings (the old `line`).
    // radarEdge: the outer ring, the disc edge (the old `lineStrong`, crimson).
    // radarSweep: the sweep beam's leading edge, alpha included (the old `accent` at 0.40,
    // drawn with a .screen blend). TWIN: android AcabPalette's radar tokens, same names; the
    // sweep value is each platform's OWN old sweep, so it differs from Android on purpose.
    let radarDisc: ACABTone, radarRing: ACABTone, radarEdge: ACABTone, radarSweep: ACABTone

    /// The alpha of a tinted pill fill (LinkChip and any tinted capsule): the ink over its own
    /// colour at this alpha. ONE constant, not a field of each level, because nothing draws it
    /// per level; ContrastPaletteTests measures it against both levels' inks.
    static let pillFillAlpha = 0.18

    // Map information must not inherit contrast from translucent system material or the tile
    // underneath it. Keep both the surface and the readable ink opaque in either appearance.
    var mapInfoBackground: ACABTone { bg2 }
    var mapInfoText: ACABTone { text }

    /// The warm off-white the higher-contrast secondary inks are built from.
    private static let ink = (r: 240.0 / 255, g: 224.0 / 255, b: 226.0 / 255)
    private static func inkAt(_ alpha: Double) -> ACABTone {
        ACABTone(r: ink.r, g: ink.g, b: ink.b, a: alpha)
    }

    /// The default look: iOS dark grouped surfaces. The measurements are alpha-composited onto
    /// each surface (see ACABTone.over) and locked in by ContrastPaletteTests.
    static let normal = ACABPalette(
        bg:   ACABTone(0x000000),            // page (systemGroupedBackground, dark)
        bg2:  ACABTone(0x1C1C1E),            // grouped cell (secondarySystemGroupedBackground)
        bg3:  ACABTone(0x2C2C2E),            // tertiary FILL, not a text surface (rule 1)
        // UIColor.separator (dark), declared as numbers so the tests can composite it.
        line:       ACABTone(r: 84 / 255, g: 84 / 255, b: 88 / 255, a: 0.60),
        text:  ACABTone(0xFFFFFF),
        // An app grey, not UIColor.secondaryLabel: that one measures under 7:1 on the cell.
        dim:   ACABTone(0xAEAEB2),
        // Tertiary ink: chevrons in hand-built rows, disabled glyphs, unfilled dots. Quieter
        // than dim, still AA on every surface.
        faint: ACABTone(0x9A9A9E),
        // THE accent: interactive elements, crimson words, the strongest hit.
        tint:       ACABTone(0xFF6A5E),
        onAccent:   ACABTone(0x120A0A),      // dark ink on a tint or hue fill
        warn:       ACABTone(0xF2B53C),      // amber - attention
        flockTone:   ACABTone(0xEE4034),     // ALPR hue: fills and glyphs only, never text
        droneTone:   ACABTone(0xF2B53C),
        axonTone:    ACABTone(0xCDC1C3),
        trackerTone: ACABTone(0x49C5B1),     // teal - BLE item trackers
        watchTone:   ACABTone(0xE0A84B),     // gold - user-starred (watched) devices
        glassesTone: ACABTone(0xB07CFF),     // violet - smart / recording glasses
        netcamTone:  ACABTone(0x3D8BFF),     // blue - branded IP / network cameras on WiFi
        sandTone:    ACABTone(r: 0.82, g: 0.67, b: 0.40),   // desert sand - nearby devices
        // The radar's pre-redesign colours (see the field comment).
        radarDisc:   ACABTone(0x0C0A0B),                                        // old bg
        radarRing:   ACABTone(r: 236 / 255, g: 150 / 255, b: 140 / 255, a: 0.11), // old line
        radarEdge:   ACABTone(0xEE4034, alpha: 0.30),                           // old lineStrong
        radarSweep:  ACABTone(0xEE4034, alpha: 0.40)                            // old accent, 0.40
    )

    /// The higher-contrast look. Surfaces are untouched so the bg < bg2 < bg3 hierarchy still
    /// reads; what changes is everything drawn ON them. Secondary text and crimson words clear
    /// 7:1 (AAA) on the text surfaces (rule 1). `line` is the separator, made visible on the
    /// cell under higher contrast.
    static let high = ACABPalette(
        bg:   ACABTone(0x000000),
        bg2:  ACABTone(0x1C1C1E),
        bg3:  ACABTone(0x2C2C2E),
        line:       ACABTone(0x8E8E93, alpha: 0.85),
        text:  ACABTone(0xFFFFFF),
        dim:   inkAt(0.85),
        faint: inkAt(0.75),
        tint:       ACABTone(0xFF8C82),
        onAccent:   ACABTone(0x120A0A),
        warn:       ACABTone(0xF7C24E),
        flockTone:   ACABTone(0xFF5A4E),
        droneTone:   ACABTone(0xF7C24E),
        axonTone:    ACABTone(0xE4DADC),
        trackerTone: ACABTone(0x6FE0CE),
        watchTone:   ACABTone(0xF0BE5E),
        glassesTone: ACABTone(0xC9A6FF),
        netcamTone:  ACABTone(0x74ACFF),
        sandTone:    ACABTone(0xE0BE7A),
        // The radar's pre-redesign colours at the old higher-contrast level.
        radarDisc:   ACABTone(0x0C0A0B),                                        // old bg
        radarRing:   ACABTone(r: 236 / 255, g: 150 / 255, b: 140 / 255, a: 0.30), // old line
        radarEdge:   ACABTone(0xFF5A4E, alpha: 0.72),                           // old lineStrong
        radarSweep:  ACABTone(0xFF5A4E, alpha: 0.40)                            // old accent, 0.40
    )
}

// MARK: - Theme

/// The app's colour, type and shape tokens: iOS dark grouped surfaces, one crimson `tint` for
/// interactive elements and crimson words, amber `warn` for attention, and the category hues.
///
/// Every colour below is dynamic: it resolves against the view's trait collection at draw
/// time and picks `ACABPalette.high` when `accessibilityContrast == .high`. That trait is set
/// by the iOS "Increase Contrast" setting, and ContrastPreference forces it on the window when
/// the in-app "always use higher contrast" switch is on. No view has to know either exists.
enum ACABTheme {
    /// A UIColor that reads the palette matching the resolving trait collection. Internal (not
    /// private) so ContrastPaletteTests can resolve the provider itself.
    static func dynamic(_ pick: @escaping (ACABPalette) -> ACABTone) -> UIColor {
        UIColor { traits in
            pick(traits.accessibilityContrast == .high ? ACABPalette.high : ACABPalette.normal).uiColor
        }
    }
    private static func color(_ pick: @escaping (ACABPalette) -> ACABTone) -> Color {
        Color(uiColor: dynamic(pick))
    }

    // Surfaces
    static let bg   = color { $0.bg }
    static let bg2  = color { $0.bg2 }
    static let bg3  = color { $0.bg3 }
    static let line = color { $0.line }

    // Text
    static let text  = color { $0.text }
    static let dim   = color { $0.dim }
    static let faint = color { $0.faint }
    static let mapInfoBackground = color { $0.mapInfoBackground }
    static let mapInfoText = color { $0.mapInfoText }

    // The one accent + amber
    /// One crimson for interactive elements AND crimson words. Fills that must stay the ALPR
    /// category hue (map pins, legend swatches) use `flockTone` instead.
    static let tint       = color { $0.tint }
    /// Permanent alias of `tint` (DeviceType.textTint and the crimson-word call sites read it).
    static let accentText = tint
    static let onAccent   = color { $0.onAccent }
    static let warn       = color { $0.warn }

    // Category tones
    static let flockTone   = color { $0.flockTone }
    static let droneTone   = color { $0.droneTone }
    static let axonTone    = color { $0.axonTone }
    static let trackerTone = color { $0.trackerTone }
    static let watchTone   = color { $0.watchTone }
    static let glassesTone = color { $0.glassesTone }
    static let netcamTone  = color { $0.netcamTone }
    static let sandTone    = color { $0.sandTone }

    // The Status radar only: its pre-redesign colours (ACABPalette's radar fields say why).
    static let radarDisc  = color { $0.radarDisc }
    static let radarRing  = color { $0.radarRing }
    static let radarEdge  = color { $0.radarEdge }
    static let radarSweep = color { $0.radarSweep }

    // Shape. System inset-grouped geometry: where a `List` is used the system draws the cell
    // and these numbers are not read. They serve the hand-built cells of ScrollView screens.
    static let radius:   CGFloat = 12   // grouped cell
    static let radiusSm: CGFloat = 10   // hand-built inputs and the search field
    static let pad:      CGFloat = 16   // cell interior AND page gutter

    // MARK: Type
    // System text styles (Dynamic Type) through ONE helper, `font(_:weight:design:tabular:)`;
    // `fixed` is the documented exception off the Dynamic Type curve. Higher contrast steps the
    // weight one cut (TypePrefs.highContrast). Bold Text is not an input here: the system
    // emboldens SF itself.
    // All @MainActor because TypePrefs is: fonts are built only inside view bodies.
}

extension ACABTheme {
    /// THE text helper. A system text style (Dynamic Type) at the requested weight, stepped one
    /// cut by TypePrefs.highContrast. `tabular` = monospacedDigit() for numbers that change while
    /// the view is on screen; `design: .monospaced` for MAC addresses, hex and coordinates.
    @MainActor
    static func font(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                     design: Font.Design = .default, tabular: Bool = false) -> Font {
        // A site that asks for a monospaced design is a MAC, hex or coordinate: an identifier,
        // so it gets the instrument face (JetBrains Mono) rather than SF Mono.
        if design == .monospaced { return telemetry(style, weight: weight) }
        let f = Font.system(style, design: design).weight(TypePrefs.shared.effectiveWeight(weight))
        return tabular ? f.monospacedDigit() : f
    }

    /// Pinned OFF the Dynamic Type curve, for instrument chrome inside fixed geometry (the
    /// scope's TOTAL NEARBY caption, DashboardView ring labels) and for a size the caller scales
    /// itself with @ScaledMetric (the radar count). Carries the weight step. Every call site
    /// documents why it is an exception. Font.system(size:) is fixed size by definition.
    @MainActor
    static func fixed(_ size: CGFloat, weight: Font.Weight = .regular,
                      design: Font.Design = .default, tabular: Bool = false) -> Font {
        let f = Font.system(size: size, weight: TypePrefs.shared.effectiveWeight(weight), design: design)
        return tabular ? f.monospacedDigit() : f
    }

    // MARK: Instrument layer (JetBrains Mono)
    // The ONE place the bundled mono face is chosen. It is for SHORT instrument text only:
    // section kickers (uppercase identifiers), telemetry lines, trailing row values, numbers and
    // identifiers (dBm, MAC, uptime, counts, coordinates), the radar's ring words and caption,
    // the category tile labels. Titles, row titles, buttons, body copy, help text and the sample
    // banner stay on `font` (SF); the wordmark and the motto keep their own faces.

    /// JetBrains Mono on a system text style's Dynamic Type curve. The size is the style's
    /// default (Large) size times `telemetryScale`: the mono face has a taller x-height and wider
    /// advance than SF, so at SF's own point size it reads a step larger than the SF beside it.
    /// relativeTo: keeps it scaling with the text-size setting; the weight step for higher
    /// contrast reaches it through effectiveWeight, and all four cuts are bundled so it resolves.
    @MainActor
    static func telemetry(_ style: Font.TextStyle, weight: Font.Weight = .medium) -> Font {
        Font.custom(jetBrains(TypePrefs.shared.effectiveWeight(weight)),
                    size: (defaultSize(style) * telemetryScale).rounded(),
                    relativeTo: style)
    }

    /// JetBrains Mono pinned OFF the Dynamic Type curve: the mono twin of `fixed`, for the same
    /// documented instrument chrome (the radar's ring words, TOTAL NEARBY, the count the caller
    /// scales itself). Mono is monospaced, so the higher-contrast weight step costs no width.
    @MainActor
    static func telemetryFixed(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.custom(jetBrains(TypePrefs.shared.effectiveWeight(weight)), fixedSize: size)
    }

    /// Letter spacing for uppercase instrument labels (kickers, ring words, tile labels): the
    /// 2.0.8 kickers' spaced-out capitals, at about half their old 1.6 so a label wraps no sooner
    /// than it must.
    static let telemetryTracking: CGFloat = 0.8

    /// Pure: whether a label is an instrument identifier (the C2 rule: uppercase identifiers are
    /// chrome, anything with a lowercase letter is copy). "6 ON · 1 EXP" is; "radios, detectors,
    /// desert mode" is not. A string with no letters at all (a bare count) is not a label.
    static func isInstrumentLabel(_ text: String) -> Bool {
        text.contains(where: \.isLetter) && !text.contains(where: \.isLowercase)
    }

    /// Mono reads optically larger than SF at the same point size; 0.9 matches cap heights.
    static let telemetryScale: CGFloat = 0.9

    /// The system text styles' default (Large content size) point sizes.
    static func defaultSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:  return 34
        case .title:       return 28
        case .title2:      return 22
        case .title3:      return 20
        case .headline:    return 17
        case .body:        return 17
        case .callout:     return 16
        case .subheadline: return 15
        case .footnote:    return 13
        case .caption:     return 12
        case .caption2:    return 11
        @unknown default:  return 17
        }
    }

    private static func jetBrains(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "JetBrainsMono-Bold"
        case .semibold:             return "JetBrainsMono-SemiBold"
        case .medium:               return "JetBrainsMono-Medium"
        default:                    return "JetBrainsMono-Regular"
        }
    }
}

/// The one observable the font helpers read: whether higher contrast is on.
///
/// Kept as an @Observable singleton rather than an environment value because the helpers are
/// static and called from hundreds of sites; Observation tracks the property read wherever it
/// happens inside a body, so the dependency is registered without threading anything through
/// views. RootView mirrors `@Environment(\.colorSchemeContrast)` into `highContrast` (the
/// SwiftUI-side signal), and the UIAccessibility notification covers the case where no view
/// has rendered yet.
@Observable
@MainActor
final class TypePrefs {
    static let shared = TypePrefs()

    /// Higher contrast, from either input: the in-app "always use higher contrast" switch
    /// (ContrastPreference forces the window trait) or the iOS Increase Contrast setting.
    /// Weight is the one thing iOS will not brighten for us: the palette swap lifts colour only,
    /// so on a dark theme the switch used to leave every glyph exactly as thin as before.
    /// ANDROID DOES NOT MIRROR THIS, on purpose: its system "high contrast text" (API 36) and
    /// `fontWeightAdjustment` restyle app text in the platform, so bumping weight in the app
    /// there would double the effect. Android's switch stays palette-only; see ContrastMode.
    var highContrast: Bool

    private init() {
        highContrast = ContrastPreference.shared.alwaysHigher
            || UIAccessibility.isDarkerSystemColorsEnabled
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                TypePrefs.shared.highContrast = ContrastPreference.shared.alwaysHigher
                    || UIAccessibility.isDarkerSystemColorsEnabled
            }
        }
    }

    /// One cut heavier while higher contrast is on (iOS-only by design; Android is palette-only).
    /// Bold Text is NOT an input any more: SF is emboldened by the system, and stepping here as
    /// well double-bumped. Bold stays bold: the step exists for thin glyphs, and the system-drawn
    /// bold chrome (large titles, tab labels) does not step either.
    func effectiveWeight(_ w: Font.Weight) -> Font.Weight {
        guard highContrast else { return w }
        switch w {
        case .ultraLight, .thin, .light, .regular: return .medium
        case .medium:                              return .semibold
        case .semibold:                            return .bold
        default:                                   return w
        }
    }
}

/// A hand-built inset-grouped cell for ScrollView screens (Status, Connect, the banners). A
/// screen that is a List uses .listStyle(.insetGrouped) and NOTHING from here. No border, no
/// shadow: rows inside a hand-built cell separate with `Divider().overlay(ACABTheme.line)`
/// (the token follows the contrast trait; a bare Divider does not brighten at High).
struct PanelModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
    }
}

extension View {
    /// A hand-built grouped cell (PanelModifier).
    func groupedCell(padding: CGFloat = 16) -> some View { modifier(PanelModifier(padding: padding)) }
}

/// The app's ONE secondary footnote label: section headers (uppercase identifiers), footers
/// and captions (sentences), trailing telegrams (presenter strings). An uppercase identifier
/// (isInstrumentLabel) sets in the instrument face, telemetry(.footnote) with telemetryTracking
/// (R16); a sentence stays system footnote with no tracking. No case transform (renders as
/// written), always wraps. TWIN: android Components.kt Kicker, the same rule.
struct Kicker: View {
    let text: String
    var color: Color = ACABTheme.dim
    init(_ text: String, color: Color = ACABTheme.dim) { self.text = text; self.color = color }

    var body: some View {
        // Instrument layer: an uppercase identifier (a section header, a telegram) sets in
        // JetBrains Mono with spaced capitals; a sentence (a footer, a caption) stays SF.
        let instrument = ACABTheme.isInstrumentLabel(text)
        Text(text)
            .font(instrument ? ACABTheme.telemetry(.footnote) : ACABTheme.font(.footnote))
            .tracking(instrument ? ACABTheme.telemetryTracking : 0)
            .foregroundStyle(color)
            // A List header slot upper-cases its content; a runtime string (and the Log's
            // lowercase copy headers) must render exactly as written.
            .textCase(nil)
            // NEVER `fixedSize(horizontal: true)`, and never `lineLimit(1)` without it. That
            // modifier means "do not compress me, take my ideal width", and a Kicker sits inside
            // rows that have no way to refuse. It has broken the layout TWICE, along two
            // different axes, and the second time is why this now reads as a flat "may wrap".
            //
            // 1. FONT SIZE. Dynamic Type only started reaching this label when the old mono helper
            //    gained `relativeTo:`; before that Font.custom(_:size:) was frozen at the literal
            //    point size so the hug was harmless. Once the text scaled, every row carrying a
            //    Kicker grew wider than the screen and the Beacon page ran off the left edge.
            //    That round gated the hug on `dynamicTypeSize > .large`, which fixed the symptom
            //    it was looking at and left the real one open.
            // 2. STRING LENGTH, which the size gate does nothing about. The Beacon tab's Scan
            //    radios row fed this a RUNTIME string (until Route A moved row values into
            //    GroupedRow, which wraps the same way): `radioPresentation.scanLabel`, 14-25
            //    characters in every steady state but 39 while a firmware update runs
            //    ("UPDATING FIRMWARE \u{00B7} DETECTION MAY PAUSE") and 45 on the co-processor leg.
            //    In the old 10.5pt mono face with 1.6 tracking that was ~7.9pt per character,
            //    so 39 characters was ~308pt of label in a column with ~245pt to give. Reported
            //    from a device 2026-09-12: the whole Beacon page went wider than the screen
            //    mid-update and was clipped on BOTH edges, because `.frame(maxWidth: .infinity)`
            //    upstream CENTERS an oversized child rather than clamping it (a maxWidth frame
            //    only clamps a SMALLER child). It healed itself when the update ended and the
            //    string got short again.
            //    The reconnect arm is 39 characters too, so an ordinary link drop reaches it.
            //
            // A wrapping Text that is offered more width than it needs draws identically to a
            // hugging one, so every short kicker is unchanged. Do NOT reintroduce the hug behind
            // a length threshold: several steady strings already run past any sane cutoff
            // ("WAITING FOR BEACON \u{00B7} COUNTS VISIBLE" is 35, "UPDATE BLOCKED \u{00B7} REVISION
            // MISMATCH" 34), and a character count cannot see the width it is actually offered.
            // Pinned by check-signature-drift.py. TWIN: android Components.kt's Kicker sets no
            // maxLines and no softWrap, so Compose has always wrapped; Android never had this.
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A grouped-section header for screens built from ScrollView + cells (Status, Connect). List
/// screens put Kicker in the header: slot; the two paths must look the same, which is why this
/// is Kicker plus the List header's insets and the header trait, nothing else. `color` forwards
/// to Kicker (default dim): the Status strongest header passes accentText for a match.
/// Headers are uppercase identifiers (OS chrome); a lowercase copy header (the Log's time
/// sections) is a plain Kicker in a List header: slot, never this.
struct SectionHeader: View {
    let text: String
    var color: Color = ACABTheme.dim
    init(_ text: String, color: Color = ACABTheme.dim) {
        #if DEBUG
        assert(text == text.uppercased(), "section headers are uppercase identifiers (C2)")
        #endif
        self.text = text
        self.color = color
    }

    var body: some View {
        Kicker(text, color: color)
            .padding(.leading, 16)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
