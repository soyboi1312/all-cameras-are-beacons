import SwiftUI

/// The sample-data tour: three cards shown when someone chooses See How It Works, non-persisting,
/// replaying on every entry to sample data. The real first connection gets the checklist
/// (ChecklistView) instead. EVERY CARD STRING IS SHARED COPY with Android's SAMPLE_TOUR_CARDS in
/// FirstRunTour.kt, word for word; edit both in the same change.
struct FirstRunTourView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Card {
        let glyph: String
        let title: String
        let body: String
        let note: String?
    }

    private let sampleCards: [Card] = [
        Card(glyph: "dot.radiowaves.left.and.right",
             title: "this is sample data",
             body: "six fictional nearby devices fill the app so you can try every screen without a beacon. nothing here came from your surroundings.",
             note: "sample settings are safe to explore. they do not configure hardware or replace the setup checklist shown when your real beacon connects."),
        Card(glyph: "list.bullet.rectangle",
             title: "follow a sample hit",
             body: "tap a category on Status to open its filtered Log, tap a row for the full details, and use Map to see where your phone heard each example.",
             note: "the examples cover ALPR, a drone, body camera, tracker, recording glasses, and a network camera."),
        Card(glyph: "switch.2",
             title: "leave whenever you are ready",
             body: "an Exit Sample Data banner stays at the top of the app, so you can return to beacon scanning from any tab.",
             note: "your real saved Log is restored after you exit. sample detections are never added to it."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Kicker("SAMPLE DATA TOUR")
                Spacer()
                // R8b: Skip reads on the Dynamic Type scale (.body semibold), not the old fixed
                // mono size, and keeps its dim ink and its 44 pt minimum hit target. TWIN: android
                // FirstRunTour.kt FirstRunTourOverlay's Skip TextButton, labelLarge in
                // onSurfaceVariant.
                Button("Skip") { dismiss() }
                    .font(ACABTheme.font(.body, weight: .semibold))
                    .foregroundStyle(ACABTheme.dim)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 20).padding(.top, 18)

            TabView(selection: $page) {
                ForEach(sampleCards.indices, id: \.self) { i in
                    cardView(sampleCards[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // The page indicator alone (P3-12, "say it once"): the "step N of 3" text that sat
            // above the dots said the same thing 8pt apart, so the dots keep the words as their
            // spoken value and the text is gone. TWIN: android FirstRunTour.kt
            // FirstRunTourOverlay's dot Row, whose contentDescription (tourStepDescription) is
            // the same words.
            HStack(spacing: 7) {
                ForEach(sampleCards.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? ACABTheme.tint : ACABTheme.faint)
                        .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                }
            }
            .padding(.bottom, 18)
            .animation(.easeOut(duration: 0.18), value: page)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(FirstRunTour.tourStepValue(page: page, count: sampleCards.count))

            Button {
                if page < sampleCards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    dismiss()
                }
            } label: {
                // R8b: the label reads on the Dynamic Type scale (.body semibold), not the old
                // fixed mono size; the full-width frame and the 15 pt vertical padding keep the hit
                // target, and a label that wraps at accessibility sizes stays centred. TWIN: android
                // FirstRunTour.kt FirstRunTourOverlay's next button label, labelLarge.
                Text(page < sampleCards.count - 1 ? "Next" : "Explore Sample Data")
                    .font(ACABTheme.font(.body, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ACABTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(ACABTheme.tint, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
        }
        .background(ACABTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()      // dismissed only by Skip or Explore Sample Data, so a
                                           // stray swipe cannot drop a first-time sample user
                                           // mid-explanation
    }

    /// Wrapped in a ScrollView so large Dynamic Type never clips a card: at accessibility
    /// sizes a page's text outgrows the fixed TabView page and was simply cut off. The inner
    /// minHeight keeps the Spacer-centering at default sizes, so the page looks exactly as
    /// before whenever the content still fits; it only starts scrolling once it does not.
    private func cardView(_ c: Card) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    Image(systemName: c.glyph)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(ACABTheme.tint)
                    Text(c.title)
                        .font(ACABTheme.display(23, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // R8: the body and the note read on the Dynamic Type scale (.body, then
                    // .subheadline, both in dim), not the old fixed mono sizes, and take the
                    // styles' own line heights, so both follow the text size. The note is
                    // secondary ink, never faint: it is the sentence that says sample settings are
                    // safe to explore. TWIN: android FirstRunTour.kt FirstRunTourOverlay's pager
                    // page, body bodyLarge and note bodyMedium, both in onSurfaceVariant.
                    Text(c.body)
                        .font(ACABTheme.font(.body))
                        .foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let n = c.note {
                        Text(n)
                            .font(ACABTheme.font(.subheadline))
                            .foregroundStyle(ACABTheme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

}

/// The durable marker of the real first-run onboarding (key acab.firstRunTour.seen), written when
/// the checklist completes, plus the checklist's shared copy constants. UserDefaults, not
/// @AppStorage, so RootView can decide before any sheet is built.
enum FirstRunTour {
    private static let key = "acab.firstRunTour.seen"
    static var hasSeen: Bool { hasSeen(in: .standard) }
    static func hasSeen(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    // The setup checklist's copy, one home per string. Each is compared with its Android twin on
    // `object FirstRunTour` in FirstRunTour.kt (same meaning, SCREAMING_CASE names). The title,
    // the subtitle and the preview note are TEMPLATES naming the board's kind: render them with
    // renderBoardCopy and ChecklistRows.kind. "under Beacon" is the tab's name and stays.

    /// The checklist sheet's title. TWIN: Android FirstRunTour.CHECKLIST_TITLE_TEMPLATE.
    static let checklistTitle = "your {noun} is listening"
    /// The line under the title. TWIN: Android FirstRunTour.CHECKLIST_SUBTITLE_TEMPLATE.
    static let checklistSubtitle = "detection is already active. these optional phone and {noun} features can be changed later under Beacon."
    /// The replay's preview line (J7), drawn under the subtitle only when the replay has no live
    /// board to describe (sample data, or no board connected: checklistIsPreview). It says the
    /// sheet is a picture of the post-connect state, so the unticked facts and the default-detector
    /// note do not read as a failed setup. TWIN: Android FirstRunTour.CHECKLIST_PREVIEW_NOTE_TEMPLATE.
    static let checklistPreviewNote = "preview: this is what you see after your {noun} connects."
    /// What an empty radar does and does not mean, as one sentence, with the window read from
    /// `activeNearbyInterval` so the number cannot drift from the Status count it explains.
    /// TWIN: Android FirstRunTour.QUIET_SENTENCE (built from ACTIVE_NEARBY_WINDOW_MS).
    static let quietSentence = "quiet does not mean clear. zero nearby means no supported broadcast was recognized in the last \(Int(activeNearbyInterval)) seconds. silent, wired, cellular-only, 5 GHz-only, powered-off, or unsupported gear can still be there."
    /// Which detectors start on and why. TWIN: Android FirstRunTour.DETECTORS_NOTE.
    static let detectorsNote = "ALPR, drones, body cams, and glasses start on. trackers and network cameras start off because they can be noisy. desert mode reports every nearby broadcast when you want proof of life, so turn it back off when you are done."
    /// Why Location is asked for. Only iOS carries the Live Mode clause: docs/app-guide.md says
    /// iPhone needs Location to start Live Mode and Android Live Mode does not request background
    /// Location, so the Android twin leads without it. The rest is shared and ends on the
    /// canonical privacy sentence. A TEMPLATE: {noun} is the checklist's board (ChecklistRows.kind,
    /// rendered by ChecklistView.locationArmSentence), so an OUI-Spy owner reads "lets the OUI-Spy
    /// label buffered hits". TWIN: Android FirstRunTour.LOCATION_RATIONALE_TEMPLATE.
    static let locationRationale = "Location is optional. it keeps Live Mode current in the background, shows where your phone heard detections on Map, and lets the {noun} label buffered hits with the last location your phone shared over encrypted Bluetooth. choose Not Now and detection still works. nothing is uploaded automatically."
    /// The checklist's fixed row titles, in row order (the detectors row is counted, so it is
    /// built at runtime and is not here). TWIN: Android FirstRunTour.CHECKLIST_ROW_TITLES.
    static let checklistRowTitles = ["Paired over encrypted Bluetooth", "Location", "Phone notifications", "Live Mode", "Offline buffer"]

    /// What the tour's page indicator speaks for the card at `page` (zero-based) of `count`: the
    /// "step N of 3" the cards once drew as text (P3-12), now the dots' accessibility value only.
    /// Pinned in BeaconPagePolishTests. TWIN: Android FirstRunTour.kt tourStepDescription.
    static func tourStepValue(page: Int, count: Int) -> String { "step \(page + 1) of \(count)" }
}
