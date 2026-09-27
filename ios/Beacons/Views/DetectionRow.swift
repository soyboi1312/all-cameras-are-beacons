import SwiftUI

/// The provenance words above a Log row's title, in ONE order on both phones: OFFLINE (where the
/// row came from), MUTED (why a retained row is absent from nearby surfaces), then what its
/// first-seen time is worth (TimeBasisCopy.tag: RECON / RANGE / NO TIME). nil when no word applies.
/// TWIN: Android `logRowOverline` in LogScreen.kt (contracts 3.6), same words, same order.
func logRowOverline(offline: Bool, muted: Bool, basis: TimeBasis) -> String? {
    var words: [String] = []
    if offline { words.append("OFFLINE") }
    if muted { words.append("MUTED") }
    if let tag = TimeBasisCopy.tag(for: basis) { words.append(tag) }
    return words.isEmpty ? nil : words.joined(separator: " \u{00B7} ")
}

/// One Log row: category glyph, a provenance overline, the name, how it was seen with its
/// confidence, and the current signal number. MapTabView's cluster sheet draws it too.
struct DetectionRow: View {
    let detection: Detection
    /// How honest the row's timestamp is. .exact adds no time word. Every caller passes the row's
    /// first-seen basis (the Log's row(_:), MapTabView's cluster sheet).
    var timeBasis: TimeBasis = .exact
    /// Active mute state is supplied only by the Log. Other call sites keep their active-surface
    /// presentation and default to false.
    var isMuted = false
    private var d: Detection { detection }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The existing mute explanation, spoken as the row's hint: the overline's MUTED word alone
    /// does not tell a VoiceOver user why this retained row is absent from nearby surfaces.
    static let mutedHint = "This active mute hides the device from nearby status and alerts"

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                compactLayout
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isMuted ? Self.mutedHint : "")
    }

    /// The row at ordinary text sizes. No chevron: in the Log the List's NavigationLink draws the
    /// system disclosure indicator.
    private var compactLayout: some View {
        HStack(alignment: .center, spacing: 12) {
            // Hidden: the category is already spoken through the title or the subtitle, and the
            // symbol's own label would be read before the overline.
            CatGlyph(type: d.type, style: .bare)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                overlineText
                titleText
                supportingText
            }
            Spacer(minLength: 8)
            signalText
        }
    }

    /// At accessibility sizes every fact gets its own line, in the compact order, with the signal
    /// at the trailing edge of the last line. The name never shares a line with the glyph: beside
    /// the glyph it broke mid-word at the largest size on a 390pt phone ("FlockSafet" / "y").
    /// TWIN: Android StackedDetectionRow in LogScreen.kt, same order (glyph, overline, title,
    /// subtitle, confidence, signal).
    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            CatGlyph(type: d.type, style: .bare)
                .accessibilityHidden(true)  // same reason as compactLayout
            overlineText
            titleText
            subtitleText
            confidenceText
            HStack {
                Spacer()
                signalText
            }
        }
    }

    @ViewBuilder private var overlineText: some View {
        if let o = logRowOverline(offline: d.offline, muted: isMuted, basis: timeBasis) {
            Text(o)
                .font(ACABTheme.telemetry(.caption2, weight: .semibold))
                .tracking(ACABTheme.telemetryTracking)
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Lead with the advertised name / UAS-ID / broadcast manufacturer when there is one, else the
    /// device class's title fallback (Detection.titleName: "body cam", "network camera"; the
    /// export label stays in displayName). No lineLimit or scale factor: a cap would cut a long
    /// name short.
    private var titleText: some View {
        Text(d.titleName)
            .font(ACABTheme.font(.body))
            .foregroundStyle(ACABTheme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The compact row's secondary line: the subtitle and the confidence drawn as ONE Text
    /// ("BLE \u{00B7} OUI match \u{00B7} 65%"), so a long subtitle wraps as a whole instead of
    /// wrapping around a percent column that moves from row to row. One verbatim string, not
    /// Text + Text (deprecated since iOS 26); the whole line takes the tabular digits. Spoken as
    /// the subtitle, then the confidence words. The percent is hidden at 0 (see confidenceText).
    /// Drawn through keepingMiddleDotsAttached (SettingsView.swift): a no-break space before each
    /// dot, so a wrap never starts the second line with an orphan "· 65%". The spoken label keeps
    /// the plain subtitle.
    private var supportingText: some View {
        let sub = subtitle
        let pct = d.confidence
        return Text(verbatim: keepingMiddleDotsAttached(pct > 0 ? "\(sub) \u{00B7} \(pct)%" : sub))
            .font(ACABTheme.font(.subheadline, tabular: true))
            .foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(pct > 0 ? "\(sub), \(confidenceSpoken)" : sub)
    }

    private var subtitleText: some View {
        Text(verbatim: keepingMiddleDotsAttached(subtitle))
            .font(ACABTheme.font(.subheadline))
            .foregroundStyle(ACABTheme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Confidence as plain secondary text, so the list answers "is this definitely something, or
    /// just suspected?" without opening the dossier. HIDDEN at 0: Desert-mode nearby devices
    /// carry confidence 0 by construction (no signature was matched), and a wall of "0%" would be
    /// pure noise. The verdict word is spoken, never drawn.
    @ViewBuilder private var confidenceText: some View {
        if d.confidence > 0 {
            Text("\(d.confidence)%")
                .font(ACABTheme.telemetry(.subheadline, weight: .regular))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize()
                .accessibilityLabel(confidenceSpoken)
        }
    }

    /// The bare signal number (Int's description uses the ASCII hyphen-minus); the unit is spoken.
    private var signalText: some View {
        Text("\(d.rssi)")
            .font(ACABTheme.telemetry(.subheadline, weight: .regular))
            .foregroundStyle(ACABTheme.dim)
            .fixedSize()
            .accessibilityLabel("Signal strength \(d.rssi) decibels relative to one milliwatt")
    }

    /// The named row leads with DeviceType.inlineLabel ("ALPR camera", "body cam", "network
    /// camera"), the lowercase-first form every row uses, never `label`, which mixes Title Case
    /// and sentence case in one list ("ALPR Camera" beside "Network camera"). `label` stays the
    /// export, search and managed-list word. TWIN: android LogScreen.kt `detectionRowSubtitle`,
    /// the same choice (drift 'inlineLabel' and the row "Log row subtitle leads with
    /// inlineLabel"). Pure and static so DetectionRowSubtitleTests can pin it.
    private var subtitle: String { Self.subtitle(for: d) }

    static func subtitle(for d: Detection) -> String {
        d.hasName
            ? "\(d.type.inlineLabel) \u{00B7} \(d.method.label)"
            : "\(d.source.label) \u{00B7} \(d.method.label)"
    }

    private var confidenceSpoken: String {
        "confidence \(d.confidence) percent, \(confidenceWord)"
    }

    /// Same bands as the dossier's confidence verdict in DetectionDetailView.swift (<50 / <80).
    /// Spoken only; the row draws the number. TWIN: Android `confidenceWord(pct:)` in
    /// LogScreen.kt (contracts 3.6; drift 'confidence verdict words').
    private var confidenceWord: String {
        switch d.confidence {
        case ..<50: return "weak match, verify"
        case ..<80: return "partial match"
        default:    return "strong match"
        }
    }
}
