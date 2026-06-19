// ACAB Android launcher-icon generator. Derives the Android assets from the iOS
// AppIcon-1024.png so both platforms wear the same face. CoreGraphics/ImageIO
// only (no AppKit, which crashes when run headless). Emits into the res tree:
//   - adaptive foreground PNGs: the monogram inset into the mask-safe zone, on a
//     transparent margin, so the launcher mask only ever crops empty space.
//   - legacy square launcher PNGs: full bleed, for completeness.
// and, separately, a 512px no-alpha icon for the Play Store listing.
//
// Run:
//   swiftc genicon-android.swift -o /tmp/genandroid
//   /tmp/genandroid <AppIcon-1024.png> <res-dir> <store-out.png>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count == 4 else {
    FileHandle.standardError.write(Data("usage: genandroid <src> <resDir> <storeOut>\n".utf8))
    exit(1)
}
let srcPath = a[1], resDir = a[2], storeOut = a[3]
let cs = CGColorSpaceCreateDeviceRGB()

func load(_ p: String) -> CGImage {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
          let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { fatalError("load \(p)") }
    return i
}
func writePNG(_ img: CGImage, _ p: String) {
    guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { fatalError("dest \(p)") }
    CGImageDestinationAddImage(d, img, nil)
    if !CGImageDestinationFinalize(d) { fatalError("finalize \(p)") }
}
func mkdir(_ p: String) {
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
}

let src = load(srcPath)

// Opaque, full bleed (legacy launcher + the Play Store icon). noneSkipLast = no
// alpha channel, which the Play Store requires of the listing icon.
func fullBleed(_ n: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
    return ctx.makeImage()!
}

// Transparent, the art inset to `scale` of the canvas. The art's own dark edges
// match the adaptive background colour, so the inset reads as one seamless icon
// while keeping the monogram inside the safe zone no matter the device mask.
func foreground(_ n: Int, _ scale: CGFloat = 0.64) -> CGImage {
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let inset = CGFloat(n) * (1 - scale) / 2
    ctx.draw(src, in: CGRect(x: inset, y: inset, width: CGFloat(n) * scale, height: CGFloat(n) * scale))
    return ctx.makeImage()!
}

// Android density buckets: a 48dp legacy icon, and the 108dp adaptive layer.
let legacy = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]
let adaptive = [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]

for (d, px) in legacy {
    let dir = "\(resDir)/mipmap-\(d)"; mkdir(dir)
    let img = fullBleed(px)
    writePNG(img, "\(dir)/ic_launcher.png")
    writePNG(img, "\(dir)/ic_launcher_round.png")
}
for (d, px) in adaptive {
    let dir = "\(resDir)/mipmap-\(d)"; mkdir(dir)
    writePNG(foreground(px), "\(dir)/ic_launcher_foreground.png")
}
mkdir((storeOut as NSString).deletingLastPathComponent)
writePNG(fullBleed(512), storeOut)
print("android icons written under \(resDir), store icon at \(storeOut)")
