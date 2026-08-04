# Bench boards

State of the boards on the desk, so it does not live only in a chat log. A board flashed with
a non-shipping build looks identical to a shipping one and will waste an afternoon otherwise.

Boards are identified by the USB port they are plugged into on the hub, because that is how
they get addressed day to day. **The port does not identify the board.** It has been swapped
mid-session before and cost a wrong-board flash. Confirm against the public address the board
prints at boot before you trust a row here.

| port | public address | flashed with | safe to hand to a phone? |
|---|---|---|---|
| usb1101 | `e8:3d:c1:fa:ff:59` | working tree as of 2026-08-02, `ACAB_BLE_PRIVACY 0` | yes, and it holds a live iOS bond |
| usb101 | not recorded | **`-DACAB_BLE_PRIVACY=1`** as of 2026-08-01 | **no. iOS cannot connect to it. Reflash first.** |

## usb101 is a trap until it is reflashed

It is on a build with address privacy forced on. It will show up in the iOS picker, it will
sound its connect chirp when tapped, and then nothing will happen, forever. That is the known
failure documented in `lib/acab_core/acab_ble_service.h`, not a new bug and not a bad board.

Clear it with a normal build:

```
pio run -e beacon-board -t upload --upload-port /dev/cu.usbmodem<port>
```

## Boards that are not in the fleet

The flipped-batch board (`14:c1:9f:...`) was an Android bond test only and is retired. No
flipped-batch boards are in the field.
