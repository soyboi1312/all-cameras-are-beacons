import SwiftUI
import UIKit
import XCTest
@testable import Beacons

/// Locks the palette to the contrast it claims. Every ratio is measured the way the screen
/// shows it: a translucent tint is composited onto the surface it sits on, then compared
/// against that same surface (WCAG 2.x relative luminance). Android twin: AcabPaletteTest.
/// Surface, ink and tint values are per platform since Route A (2026-09-23); only the tone
/// bytes are twins (testCategoryHuesAreTheSharedBytes).
final class ContrastPaletteTests: XCTestCase {

    // MARK: type weight

    /// Higher contrast has to reach TYPE, not only colour. The palette swap lifts colour alone,
    /// so before TypePrefs.highContrast existed the switch left every glyph exactly as thin as
    /// it was, which is what a user reported as "toggling contrast changes nothing". Bold Text
    /// is not an input any more (the system emboldens SF itself), and bold stays bold.
    @MainActor
    func testHigherContrastStepsWeightOneCutAndBoldStaysBold() {
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }

        prefs.highContrast = false
        XCTAssertEqual(prefs.effectiveWeight(.regular), .regular, "off: unchanged")
        XCTAssertEqual(prefs.effectiveWeight(.medium), .medium)

        prefs.highContrast = true
        XCTAssertEqual(prefs.effectiveWeight(.regular), .medium, "contrast must step one cut")
        XCTAssertEqual(prefs.effectiveWeight(.medium), .semibold)
        XCTAssertEqual(prefs.effectiveWeight(.semibold), .bold)
        XCTAssertEqual(prefs.effectiveWeight(.bold), .bold, "bold stays bold")
        XCTAssertEqual(prefs.effectiveWeight(.heavy), .heavy)
    }

    /// The ONE font helper (and its fixed-size sibling) must carry the step, or the weight rule
    /// above never reaches a glyph. Every expected Font is built along the helper's own path
    /// (explicit `design: .default`, explicit `.weight(...)`): SwiftUI Font equality treats an
    /// explicit default design as different from an omitted one, and `.weight(.regular)` as
    /// different from no weight call.
    @MainActor
    func testTheOneFontHelperAppliesTheContrastStep() {
        let prefs = TypePrefs.shared
        let contrast = prefs.highContrast
        defer { prefs.highContrast = contrast }

        prefs.highContrast = true
        XCTAssertEqual(ACABTheme.font(.body), Font.system(.body, design: .default).weight(.medium))
        XCTAssertEqual(ACABTheme.fixed(13), Font.system(size: 13, weight: .medium, design: .default))

        prefs.highContrast = false
        XCTAssertEqual(ACABTheme.font(.body), Font.system(.body, design: .default).weight(.regular))
        XCTAssertEqual(ACABTheme.fixed(13), Font.system(size: 13, weight: .regular, design: .default))
        XCTAssertEqual(ACABTheme.font(.body, tabular: true),
                       Font.system(.body, design: .default).weight(.regular).monospacedDigit())
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
    /// Where words are drawn. bg3 is a fill (glyph tiles, inputs, thumbnails), not a text surface.
    private func textSurfaces(_ p: ACABPalette) -> [(String, ACABTone)] {
        [("bg", p.bg), ("bg2", p.bg2)]
    }
    private func fillSurface(_ p: ACABPalette) -> (String, ACABTone) {
        ("bg3", p.bg3)
    }
    private func inkTokens(_ p: ACABPalette) -> [(String, ACABTone)] {
        [("text", p.text), ("dim", p.dim), ("faint", p.faint), ("tint", p.tint), ("warn", p.warn)]
    }
    /// The category hues that may be words. flockTone is excluded on purpose: it is never text.
    private func toneTokens(_ p: ACABPalette) -> [(String, ACABTone)] {
        [("droneTone", p.droneTone), ("axonTone", p.axonTone), ("trackerTone", p.trackerTone),
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
            for (tn, t) in inkTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 4.5, "\(tn) on \(sn)")
            }
        }
        for (sn, s) in textSurfaces(p) {
            for (tn, t) in toneTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 4.5, "\(tn) on \(sn)")
            }
        }
        let (fn, f) = fillSurface(p)
        for (tn, t) in toneTokens(p) {
            XCTAssertGreaterThanOrEqual(ratio(t, on: f), 3.0, "\(tn) (glyph) on \(fn)")
        }
    }

    /// C3: secondary ink is an app grey held at 7:1 where words sit, not
    /// UIColor.secondaryLabel (which measures under 7:1 on the grouped cell).
    func testNormalSecondaryInkIsAAAOnTheGroupedCell() {
        let p = ACABPalette.normal
        for (sn, s) in textSurfaces(p) {
            XCTAssertGreaterThanOrEqual(ratio(p.dim, on: s), 7.0, "dim on \(sn)")
        }
    }

    /// The ALPR hue is a fill and a glyph, never a word: crimson words are `tint`, which is
    /// text-safe everywhere. If flock ever clears 4.5 on the cell the split may be redundant;
    /// revisit rather than delete.
    func testFlockHueIsNeverTextAndTintIs() {
        let n = ACABPalette.normal
        XCTAssertLessThan(ratio(n.flockTone, on: n.bg2), 4.5, "flock is not text-safe on the cell")
        for p in [ACABPalette.normal, ACABPalette.high] {
            for (sn, s) in surfaces(p) {
                XCTAssertGreaterThanOrEqual(ratio(p.flockTone, on: s), 3.0, "flock (glyph) on \(sn)")
                XCTAssertGreaterThanOrEqual(ratio(p.tint, on: s), 4.5, "tint on \(sn)")
            }
            XCTAssertNotEqual(p.tint, p.flockTone)
        }
    }

    /// `accentText` is kept for its call sites, but it must stay the SAME colour as `tint`,
    /// never drift into a third crimson. The trait flip of `tint` itself is proven in
    /// testThemeColoursResolveByAccessibilityContrastTrait; an alias that is the same value
    /// flips with it.
    func testAccentTextIsAnAliasOfTint() {
        XCTAssertEqual(ACABTheme.accentText, ACABTheme.tint)
    }

    /// The one cross-platform twin left: the category hues are the same bytes on iOS and
    /// Android at both levels (C3). Android twin: AcabPaletteTest.categoryHuesMatchIosAndTheWidgets.
    func testCategoryHuesAreTheSharedBytes() {
        func assertHex(_ t: ACABTone, _ hex: UInt32, _ name: String) {
            let want = ACABTone(hex)
            XCTAssertEqual(t.r, want.r, accuracy: 1.0 / 255, "\(name) red")
            XCTAssertEqual(t.g, want.g, accuracy: 1.0 / 255, "\(name) green")
            XCTAssertEqual(t.b, want.b, accuracy: 1.0 / 255, "\(name) blue")
        }
        let n = ACABPalette.normal, h = ACABPalette.high
        let normal: [(String, ACABTone, UInt32)] = [
            ("flockTone", n.flockTone, 0xEE4034), ("droneTone", n.droneTone, 0xF2B53C),
            ("axonTone", n.axonTone, 0xCDC1C3), ("trackerTone", n.trackerTone, 0x49C5B1),
            ("watchTone", n.watchTone, 0xE0A84B), ("glassesTone", n.glassesTone, 0xB07CFF),
            ("netcamTone", n.netcamTone, 0x3D8BFF), ("sandTone", n.sandTone, 0xD1AB66),
        ]
        let high: [(String, ACABTone, UInt32)] = [
            ("flockTone", h.flockTone, 0xFF5A4E), ("droneTone", h.droneTone, 0xF7C24E),
            ("axonTone", h.axonTone, 0xE4DADC), ("trackerTone", h.trackerTone, 0x6FE0CE),
            ("watchTone", h.watchTone, 0xF0BE5E), ("glassesTone", h.glassesTone, 0xC9A6FF),
            ("netcamTone", h.netcamTone, 0x74ACFF), ("sandTone", h.sandTone, 0xE0BE7A),
        ]
        for (name, tone, hex) in normal { assertHex(tone, hex, "normal \(name)") }
        for (name, tone, hex) in high { assertHex(tone, hex, "high \(name)") }
    }

    /// The Status radar keeps its PRE-REDESIGN colours (owner, 2026-09-25: "the old colors looked
    /// better"): the committed pre-Route-A bg, line, lineStrong and accent-at-0.40 sweep, at both
    /// contrast levels. A drift back to the grey disc, the separator rings or a dull sweep fails
    /// here. Alpha is pinned too: the rings, the edge and the sweep ARE their alphas. Android
    /// twin: AcabPaletteTest's radar-token test (the disc, rings and edge are the same bytes; the
    /// sweep is each platform's own old sweep).
    func testRadarKeepsItsPreRedesignColours() {
        func assertTone(_ t: ACABTone, _ hex: UInt32, _ alpha: Double, _ name: String) {
            let want = ACABTone(hex, alpha: alpha)
            XCTAssertEqual(t.r, want.r, accuracy: 0.5 / 255, "\(name) red")
            XCTAssertEqual(t.g, want.g, accuracy: 0.5 / 255, "\(name) green")
            XCTAssertEqual(t.b, want.b, accuracy: 0.5 / 255, "\(name) blue")
            XCTAssertEqual(t.a, want.a, accuracy: 0.001, "\(name) alpha")
        }
        let n = ACABPalette.normal, h = ACABPalette.high
        let cases: [(String, ACABTone, UInt32, Double)] = [
            ("normal radarDisc", n.radarDisc, 0x0C0A0B, 1),
            ("normal radarRing", n.radarRing, 0xEC968C, 0.11),
            ("normal radarEdge", n.radarEdge, 0xEE4034, 0.30),
            ("normal radarSweep", n.radarSweep, 0xEE4034, 0.40),
            ("high radarDisc", h.radarDisc, 0x0C0A0B, 1),
            ("high radarRing", h.radarRing, 0xEC968C, 0.30),
            ("high radarEdge", h.radarEdge, 0xFF5A4E, 0.72),
            ("high radarSweep", h.radarSweep, 0xFF5A4E, 0.40),
        ]
        for (name, tone, hex, alpha) in cases { assertTone(tone, hex, alpha, name) }

        // Radar-only: the redesign surfaces did not move with it.
        XCTAssertNotEqual(n.radarDisc, n.bg2, "the radar disc is not the grouped cell")
        XCTAssertNotEqual(n.radarRing, n.line, "the radar rings are not the separator")

        // What sits on the disc still reads: the ring words and TOTAL NEARBY are dim, the count
        // is text (faint while the beam is parked), the dots are category hues. TWIN: android
        // AcabPaletteTest.radarKeepsThePreRedesignColours holds its inks to 7:1 and its dot
        // tones to 3:1 on the same disc.
        for (level, p) in [("normal", n), ("high", h)] {
            XCTAssertGreaterThanOrEqual(ratio(p.text, on: p.radarDisc), 7, "\(level) text on the radar disc")
            XCTAssertGreaterThanOrEqual(ratio(p.dim, on: p.radarDisc), 7, "\(level) dim on the radar disc")
            XCTAssertGreaterThanOrEqual(ratio(p.faint, on: p.radarDisc), 4.5, "\(level) faint on the radar disc")
            for (tn, t) in toneTokens(p) + [("flockTone", p.flockTone)] {
                XCTAssertGreaterThanOrEqual(ratio(t, on: p.radarDisc), 3, "\(level) \(tn) dot on the radar disc")
            }
        }

        // And the exported tokens flip on the contrast trait like every other colour.
        func rgba(_ c: UIColor) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { Double($0) }
        }
        let high = UITraitCollection(accessibilityContrast: .high)
        let normal = UITraitCollection(accessibilityContrast: .normal)
        let tokens: [(String, Color, KeyPath<ACABPalette, ACABTone>)] = [
            ("radarDisc", ACABTheme.radarDisc, \.radarDisc), ("radarRing", ACABTheme.radarRing, \.radarRing),
            ("radarEdge", ACABTheme.radarEdge, \.radarEdge), ("radarSweep", ACABTheme.radarSweep, \.radarSweep),
        ]
        for (name, colour, pick) in tokens {
            let ui = UIColor(colour)
            let hv = rgba(ui.resolvedColor(with: high)), nv = rgba(ui.resolvedColor(with: normal))
            let ht = ACABPalette.high[keyPath: pick], nt = ACABPalette.normal[keyPath: pick]
            for (i, (hw, nw)) in zip([ht.r, ht.g, ht.b, ht.a], [nt.r, nt.g, nt.b, nt.a]).enumerated() {
                XCTAssertEqual(hv[i], hw, accuracy: 0.002, "ACABTheme.\(name) under .high")
                XCTAssertEqual(nv[i], nw, accuracy: 0.002, "ACABTheme.\(name) under .normal")
            }
        }
    }

    func testOnAccentReadsOnAccentFillInBothPalettes() {
        for p in [ACABPalette.normal, ACABPalette.high] {
            XCTAssertGreaterThanOrEqual(ratio(p.onAccent, on: p.tint), 4.5)
            // A glyph on a hue tile (GlyphTile): the non-text minimum on every hue.
            for (tn, t) in toneTokens(p) + [("flockTone", p.flockTone)] {
                XCTAssertGreaterThanOrEqual(ratio(p.onAccent, on: t), 3.0, "onAccent on \(tn)")
            }
        }
    }

    /// LinkChip draws its ink over the same ink at `pillFillAlpha`, on bg or bg2 (never bg3).
    /// ONE constant measured against both levels' inks, which is the only alpha it draws.
    func testPillInkReadsOnItsOwnTintedFill() {
        for p in [ACABPalette.normal, ACABPalette.high] {
            for (tn, ink) in [("tint", p.tint), ("warn", p.warn)] {
                let fillTone = ACABTone(r: ink.r, g: ink.g, b: ink.b, a: ACABPalette.pillFillAlpha)
                for (sn, s) in textSurfaces(p) {
                    XCTAssertGreaterThanOrEqual(ratio(ink, on: fillTone.over(s)), 4.5,
                                                "\(tn) on its pill over \(sn)")
                }
            }
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

    /// R19 (review P1-1): the Map's floating buttons draw the crimson glyph on Liquid Glass tinted
    /// toward the page by `mapGlassTintAlpha` (MapTabView MapControlSurface). Untinted glass took
    /// the map's colour and the glyph measured 1.66 to 2.22:1 on the 2026-09-26 shots. Modelled
    /// the way every translucent surface here is: bg at the tint alpha composited over the two
    /// extreme tile colours the forced-dark map showed (the darkest tile and the pale plaza tile),
    /// then the glyph against that, at the 3:1 non-text floor for both palettes. Glass is not
    /// plain alpha compositing, so this is a model of the shots; MapGlassTintTests holds the
    /// finer cases (the measured button backdrop at 4.5:1, and that alpha 0 FAILS this floor).
    func testMapGlassTintKeepsTheCrimsonGlyphAtTheNonTextFloorOverTheExtremeTiles() {
        let darkestTile = ACABTone(0x110A0B), lightestTile = ACABTone(0x7D7386)
        for p in [ACABPalette.normal, ACABPalette.high] {
            for tile in [darkestTile, lightestTile] {
                let glass = ACABTone(r: p.bg.r, g: p.bg.g, b: p.bg.b, a: mapGlassTintAlpha).over(tile)
                XCTAssertGreaterThanOrEqual(ratio(p.tint, on: glass), 3.0)
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
        for (sn, s) in textSurfaces(p) {
            for (tn, t) in inkTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 7.0, "\(tn) on \(sn)")
            }
        }
        let (fn, f) = fillSurface(p)
        for (tn, t) in inkTokens(p) {
            XCTAssertGreaterThanOrEqual(ratio(t, on: f), 4.5, "\(tn) on \(fn)")
        }
        for (sn, s) in surfaces(p) {
            for (tn, t) in toneTokens(p) {
                XCTAssertGreaterThanOrEqual(ratio(t, on: s), 4.5, "\(tn) on \(sn)")
            }
        }
    }

    /// The High control edge is the tint fill now (Route A retired lineStrong, the old strong
    /// hairline); the method keeps its name so the suite's method list does not move.
    func testHighPaletteStrongLineClearsNonTextMinimum() {
        let p = ACABPalette.high
        for (sn, s) in surfaces(p) {
            XCTAssertGreaterThanOrEqual(ratio(p.tint, on: s), 3.0, "tint (control fill) on \(sn)")
        }
    }

    /// Under higher contrast the separator is a visible edge on the page and the cell, not a
    /// decorative hairline.
    func testHighSeparatorIsVisibleOnTheCell() {
        let p = ACABPalette.high
        for (sn, s) in textSurfaces(p) {
            XCTAssertGreaterThanOrEqual(ratio(p.line, on: s), 3.0, "line on \(sn)")
        }
    }

    func testHighPaletteIsNeverLowerContrastThanNormal() {
        let n = ACABPalette.normal, h = ACABPalette.high
        for ((sn, sN), (_, sH)) in zip(surfaces(n), surfaces(h)) {
            for ((tn, tN), (_, tH)) in zip(inkTokens(n) + toneTokens(n), inkTokens(h) + toneTokens(h)) {
                XCTAssertGreaterThanOrEqual(ratio(tH, on: sH), ratio(tN, on: sN), "\(tn) on \(sn)")
            }
            XCTAssertGreaterThan(ratio(h.line, on: sH), ratio(n.line, on: sN), "line on \(sn)")
        }
    }

    func testHighPaletteKeepsSurfaceHierarchy() {
        for p in [ACABPalette.normal, ACABPalette.high] {
            XCTAssertLessThan(luminance(p.bg), luminance(p.bg2))
            XCTAssertLessThan(luminance(p.bg2), luminance(p.bg3))
        }
    }

    // MARK: wiring

    /// The theme colours must actually flip on the trait, or the palette above is decoration.
    /// (a) resolves the EXPORTED tokens through the public path (UIColor(Color) hands back the
    /// dynamic provider for a Color(uiColor:)); (b) resolves the provider itself.
    func testThemeColoursResolveByAccessibilityContrastTrait() {
        func rgba(_ c: UIColor) -> [Double] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { Double($0) }
        }
        func rgba(_ t: ACABTone) -> [Double] { [t.r, t.g, t.b, t.a] }
        let high = UITraitCollection(accessibilityContrast: .high)
        let normal = UITraitCollection(accessibilityContrast: .normal)
        let cases: [(String, UIColor, KeyPath<ACABPalette, ACABTone>)] = [
            ("ACABTheme.tint", UIColor(ACABTheme.tint), \.tint),
            ("ACABTheme.dim", UIColor(ACABTheme.dim), \.dim),
            ("ACABTheme.line", UIColor(ACABTheme.line), \.line),
            ("dynamic tint", ACABTheme.dynamic { $0.tint }, \.tint),
            ("dynamic dim", ACABTheme.dynamic { $0.dim }, \.dim),
        ]
        for (name, ui, pick) in cases {
            let h = rgba(ui.resolvedColor(with: high)), n = rgba(ui.resolvedColor(with: normal))
            for i in 0..<4 {
                XCTAssertEqual(h[i], rgba(ACABPalette.high[keyPath: pick])[i], accuracy: 0.002,
                               "\(name) under .high")
                XCTAssertEqual(n[i], rgba(ACABPalette.normal[keyPath: pick])[i], accuracy: 0.002,
                               "\(name) under .normal")
            }
        }
        // And the two palettes differ where it matters, so every flip is observable.
        XCTAssertNotEqual(ACABPalette.high.tint, ACABPalette.normal.tint)
        XCTAssertNotEqual(ACABPalette.high.dim, ACABPalette.normal.dim)
        XCTAssertNotEqual(ACABPalette.high.line, ACABPalette.normal.line)
    }
}
