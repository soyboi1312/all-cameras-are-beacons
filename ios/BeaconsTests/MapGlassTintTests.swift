import XCTest
@testable import Beacons

/// The Map's floating buttons (legend, options, locate) draw the crimson `tint` glyph on Liquid
/// Glass tinted toward the page by `mapGlassTintAlpha` (MapTabView.swift, MapControlSurface).
/// Untinted, the glass took the map's colour and the glyph measured 1.66 to 2.22:1 on the
/// 2026-09-26 shots, under the 3:1 non-text floor (HIG Materials, HIG Accessibility). This models
/// the composite the way ContrastPaletteTests models every translucent surface: the page colour
/// at the tint alpha composited over the backdrop, then the glyph measured against that.
///
/// The backdrops are what the forced-dark map put under the buttons in the shots: the darkest
/// tile (0x110A0B), the lightest backdrop the untinted glass showed under a button (0x566D8A)
/// and the pale plaza tile (0x7D7386), the lightest tile in the map region. Glass is not plain
/// alpha compositing, so the numbers are a model of the shots, not a measurement; the shots
/// are the check.
///
/// Since R21 (2026-09-27) the same tinted glass carries the legend card, the scope segments pill
/// and every unselected category chip, each its own floating pill over the tiles (the full-width
/// header strip is gone). The chip tests below pin the chips' inks: `dim` on the tinted glass,
/// `onAccent` on the selected chip's opaque hue.
final class MapGlassTintTests: XCTestCase {

    // MARK: WCAG maths (the same arithmetic as ContrastPaletteTests, private there)

    private func channel(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    private func luminance(_ t: ACABTone) -> Double {
        0.2126 * channel(t.r) + 0.7152 * channel(t.g) + 0.0722 * channel(t.b)
    }
    private func ratio(_ fg: ACABTone, on bg: ACABTone) -> Double {
        let f = luminance(fg.over(bg)), b = luminance(bg)
        return (max(f, b) + 0.05) / (min(f, b) + 0.05)
    }
    /// The page colour at `alpha` composited over a tile: what the tinted glass shows.
    private func glass(_ p: ACABPalette, alpha: Double, over tile: ACABTone) -> ACABTone {
        ACABTone(r: p.bg.r, g: p.bg.g, b: p.bg.b, a: alpha).over(tile)
    }

    private let darkestTile = ACABTone(0x110A0B)
    private let lightestButtonBackdrop = ACABTone(0x566D8A)
    private let lightestTile = ACABTone(0x7D7386)

    /// The floor: the glyph is a non-text symbol, so 3:1 over every backdrop, at both contrast
    /// levels (the opaque higher-contrast surface is measured by ContrastPaletteTests; this is
    /// the glass branch).
    func testTintedGlassKeepsTheGlyphAtTheNonTextFloorOverEveryTile() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            for (name, tile) in [("darkest tile", darkestTile), ("lightest button backdrop", lightestButtonBackdrop),
                                 ("lightest tile", lightestTile)] {
                let backdrop = glass(p, alpha: mapGlassTintAlpha, over: tile)
                XCTAssertGreaterThanOrEqual(ratio(p.tint, on: backdrop), 3.0, "\(level) tint over \(name)")
            }
        }
    }

    /// What the tint was set for: over the backdrop the shots measured under a button, the glyph
    /// reaches the 4.5:1 text floor (about 4.7:1 at the normal level, the number the
    /// mapGlassTintAlpha doc quotes as "near (39, 49, 62)").
    func testTintedGlassReachesTheTextFloorOverTheMeasuredButtonBackdrop() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            let backdrop = glass(p, alpha: mapGlassTintAlpha, over: lightestButtonBackdrop)
            XCTAssertGreaterThanOrEqual(ratio(p.tint, on: backdrop), 4.5, "\(level) tint over the button backdrop")
        }
    }

    /// The legend card sits on the same tinted glass and keeps the palette's inks (R19 verify,
    /// 2026-09-26: the system's vibrant secondary label measured 2.7 to 3.2:1 on the shots, tinted
    /// or not, so it was dropped). Over the lightest tile the text inks (`text` = mapInfoText for
    /// the headline, keys and credit; `dim` for the qualifier line) clear the 4.5:1 text floor and
    /// the close glyph's `faint` clears the 3:1 non-text floor, at both levels.
    func testTintedGlassKeepsTheLegendInksAtTheirFloorsOverTheLightestTile() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            let backdrop = glass(p, alpha: mapGlassTintAlpha, over: lightestTile)
            XCTAssertGreaterThanOrEqual(ratio(p.mapInfoText, on: backdrop), 4.5, "\(level) headline and keys")
            XCTAssertGreaterThanOrEqual(ratio(p.dim, on: backdrop), 4.5, "\(level) qualifier line")
            XCTAssertGreaterThanOrEqual(ratio(p.faint, on: backdrop), 3.0, "\(level) close glyph")
        }
    }

    /// R21: an unselected category chip is `dim` text on the interactive tinted glass, a floating
    /// capsule over any tile, so `dim` clears the 4.5:1 text floor over the lightest tile at both
    /// levels. The same ink and glass the legend's qualifier line uses, pinned here in the chips'
    /// name so a chip-ink change cannot hide behind the legend test.
    func testTintedGlassKeepsTheUnselectedChipInkAtTheTextFloorOverTheLightestTile() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            let backdrop = glass(p, alpha: mapGlassTintAlpha, over: lightestTile)
            XCTAssertGreaterThanOrEqual(ratio(p.dim, on: backdrop), 4.5, "\(level) chip ink on the tinted glass")
        }
        // And the chip's glass is the same tint as the buttons': no chip-only alpha exists, so
        // the button floors above cover the chips too. The untinted case fails (alpha 0 leaves
        // dim at about 2:1 over the lightest tile), which is what the tint is for.
        XCTAssertLessThan(ratio(ACABPalette.normal.dim, on: glass(ACABPalette.normal, alpha: 0, over: lightestTile)), 4.5)
    }

    /// R21: the selected chip is the category hue, opaque, with `onAccent` text (the chip stays
    /// opaque so the selection cue never depends on what tile is under it). Text, so 4.5:1 on
    /// every chip hue at both levels: the seven category tones the Map chip reads from
    /// `DetectionCategory.type.tint` (ALPR, DRONE, BODY CAM, TRACKER, GLASSES, CAMERA, WATCHED)
    /// and `tint` for ALL.
    /// ContrastPaletteTests pins the same ink at the 3:1 glyph floor; the chip is text, so the
    /// floor here is the text one.
    func testSelectedChipInkClearsTheTextFloorOnEveryChipHue() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            let hues: [(String, ACABTone)] = [("ALL", p.tint), ("ALPR", p.flockTone), ("DRONE", p.droneTone),
                                              ("BODY CAM", p.axonTone), ("TRACKER", p.trackerTone),
                                              ("GLASSES", p.glassesTone), ("CAMERA", p.netcamTone),
                                              ("WATCHED", p.watchTone)]
            for (name, hue) in hues {
                XCTAssertGreaterThanOrEqual(ratio(p.onAccent, on: hue), 4.5, "\(level) onAccent on the \(name) chip")
            }
        }
    }

    /// The tint is load-bearing, and this file can fail: with no tint (alpha 0, the shipped
    /// 2026-09-26 state) the same glyph over the same lightest tile is under the floor at both
    /// levels, which is the defect the shots measured. Removing the tint fails the test above.
    func testUntintedGlassFailsTheFloorOverTheLightestTile() {
        for (level, p) in [("normal", ACABPalette.normal), ("high", ACABPalette.high)] {
            let backdrop = glass(p, alpha: 0, over: lightestTile)
            XCTAssertLessThan(ratio(p.tint, on: backdrop), 3.0, "\(level): untinted glass must fail, or the tint is decoration")
        }
        // And the alpha is a real tint, not opaque paint: the map still shows through the button.
        XCTAssertGreaterThan(mapGlassTintAlpha, 0)
        XCTAssertLessThan(mapGlassTintAlpha, 1)
    }
}
