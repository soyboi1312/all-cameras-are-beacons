import SwiftUI

/// One-time orientation, shown the first time a board connects (and re-openable from the Device
/// tab). WHY THIS EXISTS: RootView switches straight from ConnectView to MainTabView the instant a
/// board is found, so the moment of peak confusion - "I'm connected, now what?" - had zero
/// guidance. New users landed on tabs full of vocabulary (Desert mode, watchlist, confidence,
/// category toggles) with nothing telling them where to look first. Friends kept getting stuck
/// exactly here (2026-07-29).
///
/// Deliberately NOT a feature tour. Four cards, each answering one question a first-timer actually
/// asks, in the order they ask it. It is skippable, it never shows twice, and it teaches the two
/// ideas the rest of the app assumes you already have: what a confidence number means, and that
/// silence is a real (good) result rather than a broken device.
struct FirstRunTourView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Card {
        let glyph: String
        let title: String
        let body: String
        let note: String?
    }

    private let cards: [Card] = [
        Card(glyph: "dot.radiowaves.left.and.right",
             title: "your beacon is listening",
             body: "It scans on two radios at once and sends what it hears to your phone. You don't have to point it, aim it, or press anything.",
             note: "It never transmits, jams, or spoofs. It only writes down what is already being broadcast."),
        Card(glyph: "list.bullet.rectangle",
             title: "the Log is the answer",
             body: "Every device it recognizes lands in the Log, newest first. Tap any row to see what it is, how sure the beacon is, and where you were when it was heard.",
             note: "The Log lives on your phone, not on the beacon. It survives the board going flat, and you can export it as CSV."),
        Card(glyph: "percent",
             title: "read the confidence number",
             body: "Each hit carries a percentage. 80 and up is a strong signature match. Under 50 means something looked similar and is worth a second glance, not an alarm.",
             note: "Tap a row for the full reasoning: which signal matched, and why the beacon scored it that way."),
        Card(glyph: "checkmark.circle",
             title: "quiet is a real result",
             body: "Most places are quiet, and an empty Log usually means there is nothing to find, not that something is broken.",
             note: "Want to see it work? Body cams and drones are common. Trackers and body cams are opt-in, switch them on in Device settings."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(ACABTheme.mono(12, weight: .medium))
                    .foregroundStyle(ACABTheme.dim)
            }
            .padding(.horizontal, 20).padding(.top, 18)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { i in
                    cardView(cards[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // dots
            HStack(spacing: 7) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? ACABTheme.accent : ACABTheme.faint)
                        .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                }
            }
            .padding(.bottom, 18)
            .animation(.easeOut(duration: 0.18), value: page)

            Button {
                if page < cards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < cards.count - 1 ? "Next" : "Start listening")
                    .font(ACABTheme.mono(14, weight: .bold))
                    .foregroundStyle(ACABTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
        }
        .background(ACABTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()      // must be dismissed via Skip / Start, so it can't be
                                           // half-swiped away and marked seen without being read
    }

    private func cardView(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Image(systemName: c.glyph)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(ACABTheme.accent)
            Text(c.title)
                .font(ACABTheme.display(23, weight: .semibold))
                .foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(c.body)
                .font(ACABTheme.mono(12.5))
                .foregroundStyle(ACABTheme.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let n = c.note {
                Text(n)
                    .font(ACABTheme.mono(10.5))
                    .foregroundStyle(ACABTheme.faint)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
    }

    private func finish() {
        FirstRunTour.markSeen()
        dismiss()
    }
}

/// Persistence for the one-time tour. UserDefaults (not @AppStorage on the view) so RootView can
/// decide whether to present BEFORE the sheet is ever constructed, and so Device settings can
/// re-arm it for a user who wants to read it again.
enum FirstRunTour {
    private static let key = "acab.firstRunTour.seen"
    static var hasSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
    /// "Show the tour again" from Device settings.
    static func reset() { UserDefaults.standard.set(false, forKey: key) }
}
