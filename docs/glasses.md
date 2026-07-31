# Smart / recording glasses detection (capture-pending)

**Status: signature-sourced, capture-pending.** The company IDs below are verified
against the Bluetooth SIG registry, but ACAB has not yet field-confirmed that a pair
of glasses advertises them *while worn and recording*. Because the Meta company IDs are
shared with the Meta Quest headset, the shipped firmware does **not** flag a bare
shared-ID hit at all: a Quest on its own stays silent, and a Meta ID is only reported
when it co-signals the `META_RB_GLASS` token that marks the glasses (see the gate below).
The eyewear-only IDs ship enabled (like Axon), report honestly as "possible recording
glasses," and get promoted to field-validated once we have a capture.

## Its own category, not trackers and not body cam

Recording glasses are a distinct threat and get their own device type,
`ACAB_GLASSES` (`t=9`, label **"Recording glasses"**). They are not folded into the
BLE item-tracker category (those are AirTags and Tiles, a different signature set and
a different privacy story) and not folded into body cam (Axon is fixed body-worn gear on a
single OUI; glasses are consumer camera eyewear keyed off Bluetooth company IDs). Giving
them their own type keeps the map, log, and detail views honest about what was actually
seen.

Camera glasses are worth their own line because they are the covert case: a body cam is
worn openly and a tracker is inanimate, but a person wearing Ray-Ban Meta or Snap
Spectacles is recording the people around them with nothing on the outside that reads as
a camera.

## Verified BLE company IDs

Match is on the BLE **manufacturer-specific data** (AD type `0xFF`): the first two
payload bytes are the company ID, **little-endian**. This is the existing `M_MFG_ID`
method. Keying on the payload company ID (not the MAC) is deliberate: it survives the
BLE MAC randomization that these devices do, which is the whole point of an external
detector.

| Company ID | Registrant | Product | Eyewear-specific? | Confidence |
|---|---|---|---|---|
| `0x0D53` | Luxottica Group S.p.A | Ray-Ban Meta frames (EssilorLuxottica) | yes, eyewear-only registrant | higher |
| `0x03C2` | Snapchat Inc | Snap Spectacles camera glasses | yes, Snap's only BLE hardware is Spectacles | higher |
| `0x060C` | Vuzix Corporation | Vuzix camera AR glasses (Blade, M400, Shield, Z100) | yes, eyewear-only registrant | higher (70) |
| `0x058E` | Meta Platforms Technologies, LLC | Ray-Ban / Oakley Meta AI glasses **and** Meta Quest VR | no, shared across Meta hardware | bare hit gated off; token-confirmed only (72) |
| `0x01AB` | Meta Platforms, Inc. | Meta corporate/parent ID, appears across Meta hardware | no, not eyewear-specific | bare hit gated off; token-confirmed only (72) |
| `0x0BC6` | TCL COMMUNICATION EQUIPMENT CO.,LTD. | RayNeo AR/smart glasses (a TCL sub-brand), also TCL phones/tablets/TVs | no, TCL corporate ID | gated off (no token to confirm) |
| none | RayNeo | RayNeo smart glasses | no dedicated SIG company ID exists | n/a |

**Provenance.** All seven were pulled from the Bluetooth SIG Assigned Numbers company-ID
list (mirrored in the Nordic DB) during the Signatures phase and matched against the
authoritative registrant strings:

- Bluetooth SIG Assigned Numbers (company IDs): https://www.bluetooth.com/specifications/assigned-numbers/
- Nordic company-ID mirror: https://github.com/NordicSemiconductor/bluetooth-numbers-database

Registrant-string notes worth keeping straight:
- `0x0D53` is Luxottica, an eyewear-only registrant. The initial "not found" on the Nordic
  fetch was a truncation false-negative; it is present. This is the cleanest Ray-Ban Meta tell.
- `0x03C2` reads as **"Snapchat Inc"** in the authoritative registry, not "Snap Inc" as it is
  sometimes reported. Snap's only BLE hardware is Spectacles, so it is effectively eyewear-only.
- `0x060C` is **Vuzix Corporation**, an eyewear-only AR maker whose entire hardware line is
  camera-equipped smart glasses (Blade, M400, Shield, Z100). Like Luxottica and Snap it ships
  no phones, watches, or headsets, so a hit is glasses with no shared-hardware caveat, which is
  why it sits in the higher (70) eyewear-only band and needs no payload discriminator. Do **not** confuse
  it with `0x0820` Brilliant Home Technology (a smart-home hub vendor), which is a different
  company from the Brilliant Labs AR-glasses startup and is not a glasses signal.
- `0x0BC6` is TCL's corporate ID (decimal 3014). RayNeo is a TCL-incubated brand and would
  advertise under this shared ID or under a silicon-vendor ID, so a hit here is not
  glasses-specific.
- A full grep of the registry returns **no** entry containing "RayNeo," so there is no clean
  glasses-only detector for RayNeo. It inherits TCL `0x0BC6` or a chipset-vendor ID.

## The Meta Quest false positive, and why we gate it

`0x058E` (Meta Platforms Technologies, LLC) and `0x01AB` (Meta Platforms, Inc.) are
**corporate** BLE company IDs shared across Meta's whole hardware line, most importantly
the Meta Quest VR headsets. A person walking by carrying a Quest advertises the same
`0x058E` company ID as the Ray-Ban/Oakley Meta glasses, so a match on the Meta IDs alone
cannot prove it is glasses. Worse, a Quest advertises from a rotating private address, so a
bare shared-ID match would re-alert on every rotation and the per-MAC Ignore could never
silence it, a permanent false alarm on hardware with tens of millions of units.

So the shipped firmware **gates the bare shared-ID match off** (`0x058E`, `0x01AB`, and
TCL's `0x0BC6`). A Quest on its own does not flag as recording glasses. A Meta-ID advert
only emits when it also carries the `META_RB_GLASS` token described below, in which case it
is reported as confirmed glasses ("Ray-Ban Meta: recording glasses") with no Quest caveat.
Ray-Ban Meta coverage does **not** depend on the shared ID: the frames also advertise the
eyewear-only Luxottica ID `0x0D53`, which stays enabled. The "nearby glasses" Android app
documents the same underlying overlap, that matches on the Meta IDs "will also trigger on
other Bluetooth-enabled products from the same companies, including VR headsets," and where
it falls back on visual context, ACAB instead stays silent on the bare hit rather than
guess.

Luxottica (`0x0D53`), Snapchat (`0x03C2`), and Vuzix (`0x060C`) sidestep the ambiguity
entirely, because those registrants only ship eyewear, so they carry higher confidence with
no payload discriminator needed. TCL `0x0BC6` is shared with phones and TVs and has no token
to rescue it, so it stays gated off until a field capture gives RayNeo a clean discriminator.

## Capture-pending: what to confirm in the field

Two things gate promoting this from capture-pending to field-validated:

1. **Advertise-while-worn.** Confirm that a pair of Ray-Ban/Oakley Meta, Snap Spectacles,
   or a Luxottica frame actually broadcasts its company ID passively while worn and
   recording (not only during pairing). The device **name** does identify the glasses, but
   per Help Net Security's reporting that name is generally only exposed during pairing, so
   it is rarely visible in the field against someone who paired in advance. Net: continuous
   field detection has to rely on the company ID (plus, for Meta, the payload subtype below),
   not the name.
2. **A Quest discriminator (already gating).** The way to separate Ray-Ban/Oakley Meta
   glasses from a Quest under the shared `0x058E` ID is a manufacturer-data payload
   **token**, not a service UUID: the glasses' BLE manufacturer data is reported to carry
   the ASCII token **`META_RB_GLASS`**, which detection projects (the Spectacle keychain,
   the "nearby glasses" app) parse before alerting. No distinguishing 16-bit service UUID
   has been documented. The shipped firmware already relies on this: a bare Meta ID stays
   silent, and a Meta-ID advert only emits when the token co-signals, which raises the hit
   to a confident glasses call and drops the Quest caveat. What is still capture-pending is
   confirming the token's exact byte framing against a real worn-and-recording advert, so
   for now the token is only a confidence bump layered on the company-ID (`M_MFG_ID`) match,
   never a standalone signal.

## The beacon advantage

The reason an external radio is the right tool here: the phone-only "nearby glasses" apps
are hamstrung by iOS, which does not let a backgrounded app run a continuous BLE scan, so
they only catch glasses when the app is open in the foreground. ACAB's beacon is a
dedicated radio that scans 24/7 regardless of what your phone is doing, then pushes hits
to the app over its own link. It sidesteps the iOS background-scan limit that blocks the
phone-only approach, and the buzzer means it works with the phone away entirely.

## Config

Toggled with `{"glasses": true|false}` on the Config characteristic, mirroring the
`axon` / `tracker` enable pattern, NVS-persisted, and **on by default** (like Axon). The
Status JSON reports it as `"glasses"` beside `"axon"` and `"tracker"`. Detail strings name
the vendor and say "possible recording glasses"; a bare Meta or TCL shared-ID hit does not
emit at all, and a token-confirmed Meta hit reports as "Ray-Ban Meta: recording glasses"
with no Quest caveat. See [docs/ble-protocol.md](ble-protocol.md) for the wire fields and
[docs/signatures.md](signatures.md) for the signature table.

## Sources

- Bluetooth SIG Assigned Numbers: https://www.bluetooth.com/specifications/assigned-numbers/
- Nordic company-ID mirror: https://github.com/NordicSemiconductor/bluetooth-numbers-database
- Help Net Security, on the glasses name being pairing-only: https://www.helpnetsecurity.com/
