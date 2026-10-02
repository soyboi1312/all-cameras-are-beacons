# Bench boards

State of the boards on the desk, so it does not live only in a chat log. A board flashed with
a non-shipping build looks identical to a shipping one and will waste an afternoon otherwise.

Boards are identified by the USB port they are plugged into on the hub, because that is how
they get addressed day to day. **The port does not identify the board.** It has been swapped
mid-session before and cost a wrong-board flash. Confirm against the public address the board
prints at boot before you trust a row here.

| port | public address | flashed with | safe to hand to a phone? |
|---|---|---|---|
| usb1101 until 2026-10-02 (not plugged in that day) | `e8:3d:c1:fa:ff:59` | working tree as of 2026-08-02, `ACAB_BLE_PRIVACY 0` | yes, and it holds a live iOS bond |
| usb101, first board on 2026-10-02 | `14:c1:9f:c5:1a:d5` | working tree as of 2026-10-02 (2.1.0, `beacon-board` env, USB upload, no erase); pre-fix for the coredump defect below | yes, it is a rev-A board and it holds one bond (`bonds=1` in the boot diag) |
| usb1101 for part of 2026-10-02 (usb101 earlier that day, unplugged later) | `28:84:85:bb:af:8d` | working tree as of 2026-10-02 with the coredump fix (2.1.0, `beacon-board-revb` env, USB upload, no erase); it ran 2.0.9 rev-B before | yes, it is a rev-B battery board; `bonds=0` in the boot diag after the fix flash |
| usb101, third board on 2026-10-02 | `e8:3d:c1:fb:03:59` | working tree as of 2026-10-02 with the coredump fix (2.1.0, `beacon-board` env, USB upload, no erase); it ran the pre-fix 2.1.0 tree before | yes, a rev-A board per the owner; paired to the owner's phone on 2026-10-02 (`bonds=1`) |
| usb1101, from late 2026-10-02 | `e8:3d:c1:fb:02:89` | released 2.0.9 (`beacon board` label), not reflashed; kept as the pre-fix control for the coredump comparison | yes, a rev-A board per the owner; `bonds=0` in the boot diag |

## usb101 history

On 2026-08-01 the board on usb101 held a build with address privacy forced on
(`-DACAB_BLE_PRIVACY=1`), and its address was not recorded. Such a board shows up in the iOS
picker, sounds its connect chirp when tapped, and then nothing happens. That is the known
failure documented in `../docs/ble-protocol.md` (section "Peripheral address, bonding and
privacy"), not a new bug and not a bad board. The build option is removed now.

The board found on usb101 on 2026-10-02 ran 2.0.0 and printed `revision: rev-A`. It is not
recorded whether it is the same board. It now runs the normal build:

```
pio run -e beacon-board -t upload --upload-port /dev/cu.usbmodem<port>
```

Both 2026-10-02 boards print this line on every boot of the pre-fix 2.1.0 working tree, and the
rev-B board printed it on 2.0.9 too (the rev-A board came off 2.0.0, which has no coredump probe):
`[coredump] retained dump state UNREADABLE/INVALID (0 B reported); erase required`.
The firmware then reports that it erased the dump, and the next boot prints the line again. The
partition read back blank after the erase. This was a firmware defect, not a bad board: on the
pinned IDF 4.4 a blank partition reads as `ESP_ERR_INVALID_SIZE`, and the 2.0.6 to 2.1.0 probe
treated only `ESP_ERR_NOT_FOUND` as empty. Fixed in the 2.1.0 working tree on 2026-10-02
(`coredumpPartitionBlank` in `lib/acab_core/coredump_report.cpp`). Flashed with the fix the same
day, the rev-B board and the third (rev-A) board both boot with no `[coredump]` line over a blank
partition (esptool read: all 0xFF). The `14:c1:9f` board still runs a pre-fix image.

## Boards that are not in the fleet

The flipped-batch board (`14:c1:9f:...`) was an Android bond test only and is retired. No
flipped-batch boards are in the field. The usb101 board above has the same `14:c1:9f` prefix.
That prefix is the module maker's address block, so it does not identify a board.
