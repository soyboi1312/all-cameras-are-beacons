# Axon body-camera detection (field-validated)

**Status: field-validated, on by default.** As of June 2026 the detector has caught
real Axon body cameras on patrolling officers in the field, so it ships enabled.

## How it works

Axon body cams advertise BLE with a stable, non-randomised signature, so passive
detection works. ACAB keys off two public facts:

- **MAC OUI `00:25:DF`** — Axon Enterprise's only IEEE block (MA-L, registered 2010
  as TASER International, updated 2025-01-30). This is the loose match: it flags any
  Axon product (body cam, dock, TASER, fleet gear).
- **The `BWCDEVICE` service-data tag** — when an advert on that OUI also carries this
  tag, the classifier confirms it's specifically a *body-worn camera* (vs other Axon
  hardware) and raises confidence to 90.

> Heads up: the unrelated **"Axon Networks Inc."** OUIs (`00:58:28`, `84:70:03`)
> belong to a different, legacy company. Don't use them.

## Field validation

June 2026: driving past multiple officers at different stops, ACAB picked up their
body cams on `00:25:DF`, confirming that Body 3 / Body 4 units advertise on the
public OUI (not a resolvable random address) in normal holstered operation.

## Tuning

`lib/acab_core/axon_detect.*` is data-driven via `AxonSignature`. The registry OUI
loads with `axonUseRegistryCandidate()`; set `usePayload = true` to *require* the
`BWCDEVICE` tag (strictest match) if OUI-only false positives ever appear. It's
enabled by default (`gEnabled = true`); the iOS app (`{"axon":true}`) and the mesh
config can toggle it.
