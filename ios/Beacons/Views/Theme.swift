import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// ACAB's look — the "Crimson" cyber-noir theme. Dark surfaces, one crimson accent,
/// amber kept for drones.
enum ACABTheme {
    // Surfaces
    static let bg   = Color(hex: 0x0C0A0B)            // warm near-black
    static let bg2  = Color(hex: 0x161214)            // card / panel
    static let bg3  = Color(hex: 0x201A1D)            // raised / inputs / tiles
    static let line       = Color(red: 236/255, green: 150/255, blue: 140/255).opacity(0.11)
    static let lineStrong = Color(hex: 0xEE4034).opacity(0.30)

    // Text
    static let text  = Color(hex: 0xF4EEF0)
    static let dim   = Color(red: 240/255, green: 224/255, blue: 226/255).opacity(0.60)
    static let faint = Color(red: 240/255, green: 224/255, blue: 226/255).opacity(0.33)

    // Accent (crimson) + amber
    static let accent     = Color(hex: 0xEE4034)
    static let accentSoft = Color(hex: 0xEE4034).opacity(0.13)
    static let accentGlow = Color(hex: 0xEE4034).opacity(0.55)
    static let onAccent   = Color(hex: 0x120A0A)
    static let warn       = Color(hex: 0xF2B53C)      // amber - drones / warnings
    static let danger     = Color(hex: 0xFF7A4D)

    // Category tones (3-tone system)
    static let flockTone = Color(hex: 0xEE4034)
    static let droneTone = Color(hex: 0xF2B53C)
    static let axonTone  = Color(hex: 0xCDC1C3)
    static let trackerTone = Color(hex: 0x49C5B1)     // teal - BLE item trackers

    // Back-compat aliases — older views still reference these names.
    static let black  = bg
    static let panel  = bg2
    static let ink    = text
    static let red    = accent
    static let amber  = warn
    static let ok     = accent
    static let cyan   = droneTone
    static let violet = axonTone

    // Shape
    static let radius:   CGFloat = 18
    static let radiusSm: CGFloat = 12
    static let pad:      CGFloat = 20

    // MARK: Type
    // Display = Space Grotesk, data = JetBrains Mono (bundled in Resources/Fonts).
    // Each weight maps to the nearest bundled cut.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(spaceGrotesk(weight), size: size)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(jetBrains(weight), size: size)
    }

    private static func spaceGrotesk(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black, .semibold: return "SpaceGrotesk-Bold"
        case .medium:                          return "SpaceGrotesk-Medium"
        default:                               return "SpaceGrotesk-Regular"
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

/// Card container: panel fill, hairline border, rounded corners.
struct PanelModifier: ViewModifier {
    var strong = false
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
                    .strokeBorder(strong ? ACABTheme.lineStrong : ACABTheme.line, lineWidth: 1)
            )
    }
}

extension View {
    func panel(strong: Bool = false, padding: CGFloat = 16) -> some View {
        modifier(PanelModifier(strong: strong, padding: padding))
    }
}

/// Small all-caps mono label ("kicker") for section headers and data captions.
struct Kicker: View {
    let text: String
    var color: Color = ACABTheme.faint
    init(_ text: String, color: Color = ACABTheme.faint) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(ACABTheme.mono(10.5, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
