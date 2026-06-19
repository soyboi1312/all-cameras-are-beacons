#!/usr/bin/env python3
# Beacon app-icon generator (Pillow).
#
# Draws the full beacon ONCE on a transparent, supersampled canvas, then writes
# the opaque iOS 1024 icon AND all five Android adaptive-icon foregrounds from
# that single source, so the two platforms can never drift again.
#
# Tweak the PARAMS block and re-run:
#     python3 ios/icon/genicon_beacon.py
#
# Notes:
#  - The iOS PNG is saved as RGB (no alpha). App Store Connect rejects icons
#    that carry an alpha channel, so do NOT change that.
#  - The Android foregrounds are transparent (the pupil is a real hole) so the
#    adaptive background colour (#0d0a0b, in res/values/ic_launcher_background.xml)
#    shows through; keep that colour in sync with BG below.
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ---- PARAMS (all in 1024-icon space) ---------------------------------------
SIZE       = 1024
BG         = (13, 10, 11)        # near-black background
LENS       = (238, 64, 52)       # bright crimson "eye"
CATCH      = (244, 238, 240)     # catchlight
RING_IN    = (120, 42, 38)       # inner ring
RING_OUT   = (78, 32, 32)        # outer ring
RING_W     = 34                  # ring thickness  <-- knob: bump for bolder rings
SCALE      = 1.30                # overall fill    <-- knob: 1.0 = ~60% of the icon, 1.30 = ~78%
R_LENS     = 127
R_PUPIL    = 48
R_RING_IN  = 196
R_RING_OUT = 289
R_CATCH    = 17
CATCH_OFF  = (32, -38)           # catchlight offset from center (x, y)
SS         = 4                   # supersample factor (smooth edges)
# ----------------------------------------------------------------------------

ANDROID = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def draw_beacon():
    """Beacon on a transparent canvas (pupil is a real hole), returned at SIZE px."""
    W = SIZE * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = W / 2

    def ring(radius, width, color):
        ro = (radius + width / 2) * SS
        d.ellipse([c - ro, c - ro, c + ro, c + ro], outline=color + (255,), width=int(width * SS))

    def disc(ox, oy, radius, rgba):
        x, y, r = c + ox * SS, c + oy * SS, radius * SS
        d.ellipse([x - r, y - r, x + r, y + r], fill=rgba)

    ring(R_RING_OUT * SCALE, RING_W * SCALE, RING_OUT)
    ring(R_RING_IN  * SCALE, RING_W * SCALE, RING_IN)
    disc(0, 0, R_LENS * SCALE, LENS + (255,))
    disc(0, 0, R_PUPIL * SCALE, (0, 0, 0, 0))          # punch the pupil transparent
    disc(CATCH_OFF[0] * SCALE, CATCH_OFF[1] * SCALE, R_CATCH * SCALE, CATCH + (255,))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


beacon = draw_beacon()

# iOS: composite over the opaque background, save without alpha
ios_path = os.path.join(ROOT, "ios/Beacons/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
ios = Image.new("RGBA", (SIZE, SIZE), BG + (255,))
ios.alpha_composite(beacon)
ios.convert("RGB").save(ios_path)
print("iOS  ->", os.path.relpath(ios_path, ROOT))

# Android: the same beacon, transparent, one foreground per density
for dens, px in ANDROID.items():
    p = os.path.join(ROOT, f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png")
    beacon.resize((px, px), Image.LANCZOS).save(p)
    print(f"Android {dens:8} ({px}) ->", os.path.relpath(p, ROOT))

print("done")
