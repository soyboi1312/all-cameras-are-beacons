# Hardware notes: enclosure & antenna

Building an OUI-Spy into a case? The board is a Seeed XIAO ESP32-S3, and the one
RF choice that shapes how the finished thing *looks* is the 2.4 GHz antenna.

## Internal PCB antenna vs external whip

ACAB only ever *listens* (BLE advertisements + WiFi promiscuous frames), so the
2.4 GHz radio is doing receive, not transmit - the only thing it sends out is the
short-range BLE link to your phone. You're therefore optimising for **RX
sensitivity**, not transmit power, and a decent flat PCB/FPC antenna lands within
a couple of dB of a stubby external whip for listening. For a pocket "is there a
camera near me" gadget, that gap isn't worth a knob sticking out of the case.

**Recommendation for the OUI-Spy (phone-app) build: go internal.** A flat antenna
taped to an inside wall keeps the device discreet - which suits a thing whose
whole job is to *quietly* notice surveillance - for a sensitivity hit small enough
not to matter.

### Do it right, or the internal antenna underperforms

A PCB antenna is only as good as what surrounds it:

- **Use an RF-transparent case** - ABS, PC, PETG, nylon, resin. Not metal, not
  metal-flake paint, not carbon fibre. A metal enclosure kills an internal antenna
  dead; go external if that's what you've got.
- **Keep it off the battery.** A LiPo pouch is foil - an RF mirror, and the number
  one way people wreck an internal antenna is laying it flat against one. Mount the
  antenna against the *opposite* wall, radiating end pointing into open plastic,
  clear of the battery, the board's ground plane, and any wiring.
- **You probably already own the antenna.** The XIAO ESP32-S3 ships with a flat
  flexible 2.4 GHz antenna on a u.FL pigtail - double-sided-tape that to an inside
  wall and you're done. No extra part to buy.
- **Buying one? Pick MHF1, not MHF4.** MHF1 is intermateable with the XIAO's
  u.FL / IPEX-1 connector; MHF4 is a smaller, different connector that won't fit.

### When the external whip is worth it

- **Metal enclosure**, or mounting in/under metal (vehicle dash, Pelican case) -
  internal isn't an option there; run a bulkhead RP-SMA.
- **Fixed-site monitoring** - leaving the unit somewhere to map an area, where you
  want every last dB of range.
- **Mesh-Detect builds already have an antenna sticking out.** The two-board XIAO +
  Heltec V3 rig ([mesh-setup.md](mesh-setup.md)) needs an external 915 MHz LoRa whip
  on the Heltec regardless, so the "no knob" look is already gone - the
  internal-vs-external call only really buys you anything on the single-board
  OUI-Spy.

> Single band keeps this simple: BLE and WiFi are both 2.4 GHz, and the XIAO has no
> sub-GHz radio, so one antenna covers every detector on the board.
