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
                    Text(d.type.label)
                        .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text("NODE \(d.nodeName)")
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    if d.type.isExperimental { Tag(text: "EXP", color: ACABTheme.warn) }
                }
                Text("\(d.source.label) \u{00B7} \(d.method.label)")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint).lineLimit(1)
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
