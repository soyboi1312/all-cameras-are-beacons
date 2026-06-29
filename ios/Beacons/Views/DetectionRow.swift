import SwiftUI

/// One Logbook row: category glyph, node handle, how it was seen, and current signal.
struct DetectionRow: View {
    let detection: Detection
    private var d: Detection { detection }

    var body: some View {
        HStack(spacing: 12) {
            CatGlyph(type: d.type, size: 40, filled: true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Lead with the advertised name / UAS-ID when we have one, else the
                    // device class. displayName falls back to type.label on its own.
                    Text(d.hasName ? d.displayName : d.type.label)
                        .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("NODE \(d.nodeName)")
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    if d.type.isExperimental { Tag(text: "EXP", color: ACABTheme.warn) }
                }
                HStack(spacing: 6) {
                    // When a name leads, keep the device class visible as the subtitle.
                    Text(d.hasName
                         ? "\(d.type.label) \u{00B7} \(d.method.label)"
                         : "\(d.source.label) \u{00B7} \(d.method.label)")
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint).lineLimit(1)
                    if let age = d.locationAgeText {
                        Text("LOC \(age)")
                            .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                            .foregroundStyle(ACABTheme.warn)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(ACABTheme.warn.opacity(0.14), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text("\(d.rssi)")
                    .font(ACABTheme.mono(13, weight: .semibold))
                    .foregroundStyle(d.type.tint).monospacedDigit()
                SignalBars(bars: d.signalBars, tint: d.type.tint)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(ACABTheme.faint)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
