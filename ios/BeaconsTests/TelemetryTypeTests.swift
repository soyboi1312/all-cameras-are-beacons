import SwiftUI
import UIKit
import XCTest
@testable import Beacons

/// Pins the instrument layer (decision R16): JetBrains Mono for short instrument text only, at
/// 0.9 of the system text style's size, spaced capitals at 0.8 on uppercase labels, and the
/// system face everywhere else. Also pins that every cut the helpers name is in the app bundle
/// and registered (UIAppFonts), because a missing TTF fails silently: Font.custom falls back to
/// the system face and nothing crashes. Android twin: TelemetryTypeTest.
final class TelemetryTypeTests: XCTestCase {

    // MARK: the shared constants (drift rows "telemetry scale" and "telemetry tracking")

    func testScaleAndTrackingAreTheSharedValues() {
        XCTAssertEqual(ACABTheme.telemetryScale, 0.9)
        XCTAssertEqual(ACABTheme.telemetryTracking, 0.8)
    }

    // MARK: the face and the size

    /// The expected Fonts are built the way the helper builds them (the cut's PostScript name,
    /// the style's default size times 0.9 rounded, relativeTo the style), so Font equality holds
    /// the face, the size and the Dynamic Type curve in one comparison.
    @MainActor
    func testTelemetryIsJetBrainsMonoAtNineTenthsOfTheStyle() {
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }
        prefs.highContrast = false

        // body 17 -> 15.3 -> 15; subheadline 15 -> 13.5 -> 14; footnote 13 -> 11.7 -> 12;
        // caption2 11 -> 9.9 -> 10; title 28 -> 25.2 -> 25.
        XCTAssertEqual(ACABTheme.telemetry(.body),
                       Font.custom("JetBrainsMono-Medium", size: 15, relativeTo: .body))
        XCTAssertEqual(ACABTheme.telemetry(.subheadline, weight: .regular),
                       Font.custom("JetBrainsMono-Regular", size: 14, relativeTo: .subheadline))
        XCTAssertEqual(ACABTheme.telemetry(.footnote),
                       Font.custom("JetBrainsMono-Medium", size: 12, relativeTo: .footnote))
        XCTAssertEqual(ACABTheme.telemetry(.caption2, weight: .semibold),
                       Font.custom("JetBrainsMono-SemiBold", size: 10, relativeTo: .caption2))
        XCTAssertEqual(ACABTheme.telemetry(.title, weight: .bold),
                       Font.custom("JetBrainsMono-Bold", size: 25, relativeTo: .title))
        XCTAssertEqual(ACABTheme.telemetryFixed(12),
                       Font.custom("JetBrainsMono-Medium", fixedSize: 12))

        // Higher contrast steps the cut, as it does for SF.
        prefs.highContrast = true
        XCTAssertEqual(ACABTheme.telemetry(.body),
                       Font.custom("JetBrainsMono-SemiBold", size: 15, relativeTo: .body))
    }

    /// A MAC, hex or coordinate site asks for `design: .monospaced`; it gets the instrument face,
    /// never SF Mono.
    @MainActor
    func testMonospacedDesignRoutesToTheInstrumentFace() {
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }
        prefs.highContrast = false

        XCTAssertEqual(ACABTheme.font(.footnote, design: .monospaced),
                       ACABTheme.telemetry(.footnote, weight: .regular))
    }

    /// Titles, row titles, body copy and buttons stay the system face (L1 holds outside the
    /// instrument layer). Built along the helper's own path, as ContrastPaletteTests does.
    @MainActor
    func testBodyAndTitleRolesStayTheSystemFace() {
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }
        prefs.highContrast = false

        for style: Font.TextStyle in [.largeTitle, .title, .title3, .headline, .body, .subheadline, .footnote] {
            XCTAssertEqual(ACABTheme.font(style),
                           Font.system(style, design: .default).weight(.regular), "\(style)")
        }
        XCTAssertEqual(ACABTheme.font(.title3, weight: .semibold),
                       Font.system(.title3, design: .default).weight(.semibold))
    }

    /// The face as the text system resolves it, not only as it was asked for: a Font.custom
    /// whose name is not registered resolves to the system face without an error.
    @MainActor
    func testTheResolvedFacesAreJetBrainsMonoAndTheSystemFace() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Font.resolve(in:) needs iOS 26") }
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }
        prefs.highContrast = false

        let context = EnvironmentValues().fontResolutionContext
        func family(_ font: Font) -> String {
            CTFontCopyFamilyName(font.resolve(in: context).ctFont) as String
        }
        XCTAssertEqual(family(ACABTheme.telemetry(.subheadline, weight: .regular)), "JetBrains Mono")
        XCTAssertEqual(family(ACABTheme.telemetryFixed(12)), "JetBrains Mono")
        for font in [ACABTheme.font(.body), ACABTheme.font(.title), ACABTheme.font(.headline)] {
            XCTAssertNotEqual(family(font), "JetBrains Mono")
            XCTAssertNotEqual(family(font), "Space Grotesk")
        }
    }

    // MARK: bundling

    /// Every cut the helpers name, and the wordmark's Space Grotesk Bold (ACABWordmark), is in the
    /// app bundle and registered by UIAppFonts. The suite is hosted in the app, so UIFont(name:)
    /// sees exactly what the app sees.
    func testEveryNamedCutIsRegistered() {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-SemiBold",
                     "JetBrainsMono-Bold"] {
            XCTAssertEqual(UIFont(name: name, size: 12)?.familyName, "JetBrains Mono", name)
        }
        XCTAssertEqual(UIFont(name: "SpaceGrotesk-Bold", size: 46)?.familyName, "Space Grotesk")
    }

    // MARK: which labels are instrument labels (C2)

    /// Twin cases: android TelemetryTypeTest.instrumentLabelRule.
    func testInstrumentLabelRule() {
        XCTAssertTrue(ACABTheme.isInstrumentLabel("SIGHTINGS"))
        XCTAssertTrue(ACABTheme.isInstrumentLabel("6 ON \u{00B7} 1 EXP"))
        XCTAssertTrue(ACABTheme.isInstrumentLabel("WI-FI ECO"))
        XCTAssertFalse(ACABTheme.isInstrumentLabel("radios, detectors, desert mode"))
        XCTAssertFalse(ACABTheme.isInstrumentLabel("v2.0.9 \u{00B7} LATEST KNOWN"), "one lowercase letter is copy")
        XCTAssertFalse(ACABTheme.isInstrumentLabel("-54"), "a bare number is not a label")
        XCTAssertFalse(ACABTheme.isInstrumentLabel(""))
    }
}
