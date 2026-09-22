import SwiftUI
import UIKit
import XCTest
@testable import Beacons

/// Locks the palette to the contrast it claims. Every ratio is measured the way the screen
/// shows it: a translucent tint is composited onto the surface it sits on, then compared
/// against that same surface (WCAG 2.x relative luminance). Android twin: AcabPaletteTest.
final class ContrastPaletteTests: XCTestCase {

    // MARK: type weight

    /// Higher contrast has to reach TYPE, not only colour. The palette swap lifts colour alone,
    /// so before TypePrefs.highContrast existed the switch left every glyph exactly as thin as
    /// it was, which is what a user reported as "toggling contrast changes nothing". The two
    /// inputs (iOS Bold Text, higher contrast) each bump one cut and never stack, because that
    /// is the whole weight vocabulary Space Grotesk and JetBrains Mono ship here.
    @MainActor
    func testHigherContrastBumpsTypeWeightLikeBoldTextDoes() {
        let prefs = TypePrefs.shared
        let bold = prefs.bold, contrast = prefs.highContrast
        defer { prefs.bold = bold; prefs.highContrast = contrast }

        prefs.bold = false; prefs.highContrast = false
        XCTAssertEqual(prefs.effectiveWeight(.regular), .regular, "neither input: unchanged")
        XCTAssertEqual(prefs.effectiveWeight(.medium), .medium)

        prefs.highContrast = true
        XCTAssertEqual(prefs.effectiveWeight(.regular), .medium, "contrast alone must bump")
        XCTAssertEqual(prefs.effectiveWeight(.medium), .semibold)
        XCTAssertEqual(prefs.effectiveWeight(.semibold), .bold)
        XCTAssertEqual(prefs.effectiveWeight(.bold), .bold, "already the heaviest cut bundled")

        prefs.bold = true
        XCTAssertEqual(prefs.effectiveWeight(.regular), .medium, "both inputs still bump one cut")

        prefs.highContrast = false
        XCTAssertEqual(prefs.effectiveWeight(.regular), .medium, "bold alone is unchanged")
    }

    // MARK: WCAG maths

    private func channel(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private func luminance(_ t: ACABTone) -> Double {
        0.2126 * channel(t.r) + 0.7152 * channel(t.g) + 0.0722 * channel(t.b)
    }
    /// Contrast of `fg` drawn on opaque `bg`, with fg's alpha composited first.
    private func ratio(_ fg: ACABTone, on bg: ACABTone) -> Double {
        let f = luminance(fg.over(bg)), b = luminance(bg)
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }
    private func surfaces(_ p: ACABPalette) -> [(String, ACABTone)] {
        [("bg", p.bg), ("bg2", p.bg2), ("bg3", p.bg3)]
    }
    private func textTokens(_ p: ACABPalette) -> [(String, ACABTone)] {
        [("text", p.text), ("dim", p.dim), ("faint", p.faint), ("accentText", p.accentText),
         ("warn", p.warn), ("danger", p.danger),
         ("droneTone", p.droneTone), ("axonTone", p.axonTone), ("trackerTone", p.trackerTone),
         ("watchTone", p.watchTone), ("glassesTone", p.glassesTone), ("netcamTone", p.netcamTone),
         ("sandTone", p.sandTone)]
    }

    func testWcagMathMatchesKnownAnchors() {
        // Pure white on pure black is 21:1 by definition; mid grey on white is the textbook 4.5-ish.
        XCTAssertEqual(ratio(ACABTone(0xFFFFFF), on: ACABTone(0x000000)), 21, accuracy: 0.01)
        XCTAssertEqual(ratio(ACABTone(0x767676), on: ACABTone(0xFFFFFF)), 4.54, accuracy: 0.01)
        // Compositing: 50% white over black is mid grey, not white.
        let half = ACABTone(0xFFFFFF, alpha: 0.5).over(ACABTone(0x000000))
        XCTAssertEqual(half.r, 0.5, accuracy: 0.001)
    }

    // MARK: normal palette

    func testNormalPaletteTextTokensClearAAOnEverySurface() {
        let p = ACABPalette.normal
        for (sn, s) in surfaces(p) {
            for (tn, t) in textTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 4.5, "\(tn) on \(sn)")
            }
        }
    }

    /// The reason accentText exists: the fill accent is NOT text-safe on the raised surface.
    /// If this ever passes 4.5 the token may be redundant; revisit rather than delete.
    func testNormalFillAccentIsUnderAAOnRaisedSurface() {
        let p = ACABPalette.normal
        XCTAssertLessThan(ratio(p.accent, on: p.bg3), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(p.accent, on: p.bg3), 3.0, "still fine as a glyph / fill")
    }

    func testOnAccentReadsOnAccentFillInBothPalettes() {
        for p in [ACABPalette.normal, ACABPalette.high] {
            XCTAssertGreaterThanOrEqual(ratio(p.onAccent, on: p.accent), 4.5)
        }
    }

    /// Map callouts and legends float over arbitrary tiles. What keeps them readable is that
    /// `mapInfoBackground` is OPAQUE: an opaque layer screens the tile off, so the composited
    /// backdrop IS the surface and one measurement covers every tile. The real ink is therefore
    /// measured once, not re-measured per tile for the same number.
    ///
    /// The opacity assertion is also the only reliable detector of a surface going translucent,
    /// which is why it is asserted directly: a DARK tile bleeding through a sheer surface RAISES
    /// contrast against pale ink, so a tile sweep alone could miss it.
    ///
    /// The sweep instead runs a deliberately sheer cut of the same surface, the one arrangement
    /// in which a tile reaches the ink, and asserts every tile MOVES the measurement. That is the
    /// compositing path this whole file rests on, kept live. It deliberately does not assert how
    /// far the bleed hurts: that number is a fact about this palette being dark, not about the
    /// invariant, and it would fire spuriously if the callout were ever restyled light-on-dark.
    /// Android twin: `mapInformationSurfaceIsOpaqueAndItsTextStaysReadableOverAnyTile`.
    func testMapInformationStaysOpaqueAndReadableOverAnyMapTile() {
        let pale = ACABTone(0xFFFFFF), mid = ACABTone(0x808080), dark = ACABTone(0x000000)
        for palette in [ACABPalette.normal, ACABPalette.high] {
            XCTAssertEqual(palette.mapInfoBackground.a, 1)
            XCTAssertEqual(palette.mapInfoText.a, 1)
            let onSurface = ratio(palette.mapInfoText, on: palette.mapInfoBackground)
            XCTAssertGreaterThanOrEqual(onSurface, 7)

            let sheer = ACABTone(r: palette.mapInfoBackground.r,
                                 g: palette.mapInfoBackground.g,
                                 b: palette.mapInfoBackground.b, a: 0.5)
            for tile in [pale, mid, dark] {
                XCTAssertNotEqual(ratio(palette.mapInfoText, on: sheer.over(tile)), onSurface,
                                  accuracy: 0.01, "a sheer surface must let the tile through")
            }
        }
    }

    func testFaintStaysQuieterThanDimWhichStaysQuieterThanText() {
        for p in [ACABPalette.normal, ACABPalette.high] {
            for (_, s) in surfaces(p) {
                XCTAssertLessThan(ratio(p.faint, on: s), ratio(p.dim, on: s))
                XCTAssertLessThan(ratio(p.dim, on: s), ratio(p.text, on: s))
            }
        }
    }

    // MARK: high-contrast palette

    func testHighPaletteSecondaryTextClearsAAA() {
        let p = ACABPalette.high
        for (sn, s) in surfaces(p) {
            for (tn, t) in [("text", p.text), ("dim", p.dim), ("faint", p.faint), ("accentText", p.accentText)] {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 7.0, "\(tn) on \(sn)")
            }
            for (tn, t) in textTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 4.5, "\(tn) on \(sn)")
            }
        }
    }

    func testHighPaletteStrongLineClearsNonTextMinimum() {
        let p = ACABPalette.high
        for (sn, s) in surfaces(p) {
            XCTAssertGreaterThanOrEqual(ratio(p.lineStrong, on: s), 3.0, "lineStrong on \(sn)")
            XCTAssertGreaterThanOrEqual(ratio(p.accent, on: s), 3.0, "accent (control fill) on \(sn)")
        }
    }

    func testHighPaletteIsNeverLowerContrastThanNormal() {
        let n = ACABPalette.normal, h = ACABPalette.high
        for ((sn, sN), (_, sH)) in zip(surfaces(n), surfaces(h)) {
            for ((tn, tN), (_, tH)) in zip(textTokens(n), textTokens(h)) {
                XCTAssertGreaterThanOrEqual(ratio(tH, on: sH), ratio(tN, on: sN), "\(tn) on \(sn)")
            }
            XCTAssertGreaterThan(ratio(h.line, on: sH), ratio(n.line, on: sN), "line on \(sn)")
        }
    }

    func testHighPaletteKeepsSurfaceHierarchy() {
        let p = ACABPalette.high
        XCTAssertLessThan(luminance(p.bg), luminance(p.bg2))
        XCTAssertLessThan(luminance(p.bg2), luminance(p.bg3))
    }

    // MARK: wiring

    /// The theme colours must actually flip on the trait, or the palette above is decoration.
    func testThemeColoursResolveByAccessibilityContrastTrait() {
        func rgba(_ c: UIColor) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { Double($0) }
        }
        func rgba(_ t: ACABTone) -> [Double] { [t.r, t.g, t.b, t.a] }
        let high = UITraitCollection(accessibilityContrast: .high)
        let normal = UITraitCollection(accessibilityContrast: .normal)
        for (ui, pick) in [(ACABTheme.uiAccent, \ACABPalette.accent),
                           (ACABTheme.uiFaint, \ACABPalette.faint),
                           (ACABTheme.uiTabBarBackground, \ACABPalette.tabBarBackground)] {
            let h = rgba(ui.resolvedColor(with: high)), n = rgba(ui.resolvedColor(with: normal))
            for i in 0..<4 {
                XCTAssertEqual(h[i], rgba(ACABPalette.high[keyPath: pick])[i], accuracy: 0.002)
                XCTAssertEqual(n[i], rgba(ACABPalette.normal[keyPath: pick])[i], accuracy: 0.002)
            }
        }
        // And the two palettes differ where it matters, so the flip is observable.
        XCTAssertNotEqual(ACABPalette.high.faint, ACABPalette.normal.faint)
    }

    @MainActor
    func testBoldTextStepsEveryWeightUpOneCut() {
        let prefs = TypePrefs.shared
        let before = prefs.bold, contrastBefore = prefs.highContrast
        defer { prefs.bold = before; prefs.highContrast = contrastBefore }
        // Pin BOTH inputs. This singleton seeds itself from the real install (the in-app switch
        // and the iOS Increase Contrast setting), and a hosted test inherits whatever the host
        // app's container and the simulator happen to hold, which is exactly how this test
        // started failing the moment higher contrast became a second weight input.
        prefs.highContrast = false
        prefs.bold = false
        XCTAssertEqual(prefs.effectiveWeight(.regular), .regular)
        prefs.bold = true
        XCTAssertEqual(prefs.effectiveWeight(.regular), .medium)
        XCTAssertEqual(prefs.effectiveWeight(.medium), .semibold)
        XCTAssertEqual(prefs.effectiveWeight(.semibold), .bold)
        XCTAssertEqual(prefs.effectiveWeight(.bold), .bold)
    }
}
