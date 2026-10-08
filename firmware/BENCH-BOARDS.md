# Bench boards

State of the boards on the desk, so it does not live only in a chat log. A board flashed with
a non-shipping build looks identical to a shipping one and will waste an afternoon otherwise.

Boards are identified by the USB port they are plugged into on the hub, because that is how
they get addressed day to day. **The port does not identify the board.** It has been swapped
mid-session before and cost a wrong-board flash. Confirm against the public address the board
prints at boot before you trust a row here. A USB serial number in a row does identify the
board (it is the chip's MAC, not its BLE address); `pio device list` shows it as `SER=` without
opening the port.

| port | public address | flashed with | safe to hand to a phone? |
|---|---|---|---|
| usb1101 until 2026-10-02 (not plugged in that day) | `e8:3d:c1:fa:ff:59` | working tree as of 2026-08-02, `ACAB_BLE_PRIVACY 0` | yes, and it holds a live iOS bond |
| usb101, first board on 2026-10-02 | `14:c1:9f:c5:1a:d5` | working tree as of 2026-10-02 (2.1.0, `beacon-board` env, USB upload, no erase); pre-fix for the coredump defect below | yes, it is a rev-A board and it holds one bond (`bonds=1` in the boot diag) |
| usb1101 for part of 2026-10-02 (usb101 earlier that day, unplugged later) | `28:84:85:bb:af:8d` | working tree as of 2026-10-02 with the coredump fix (2.1.0, `beacon-board-revb` env, USB upload, no erase); it ran 2.0.9 rev-B before | yes, it is a rev-B battery board; `bonds=0` in the boot diag after the fix flash |
| usb101, third board on 2026-10-02 | `e8:3d:c1:fb:03:59` | working tree as of 2026-10-02 with the coredump fix (2.1.0, `beacon-board` env, USB upload, no erase); it ran the pre-fix 2.1.0 tree before | yes, a rev-A board per the owner; paired to the owner's phone on 2026-10-02 (`bonds=1`) |
| usb1101, from late 2026-10-02 | `e8:3d:c1:fb:02:89` | released 2.0.9 (`beacon board` label), not reflashed; kept as the pre-fix control for the coredump comparison | yes, a rev-A board per the owner; `bonds=0` in the boot diag |
| usb101 on 2026-10-05, USB serial `10:BD:A3:CA:3A:04` | `10:bd:a3:ca:3a:06` | working tree as of about 10:30 on 2026-10-05 (2.1.0, `beacon-c5` env: one XIAO ESP32-C5, no nRF); not released | yes, and a bonded phone reconnected by itself after each reset. Opening its USB serial port resets it. Only a real power-on (unplug and replug) opens the pairing window; a flash, an RTS reset or a port open is a warm start and leaves it closed |
| usb2101 on 2026-10-05, USB serial `28:84:85:BB:76:B0` | `28:84:85:bb:76:b1` (USB serial + 1, the S3 rule; seen in an Android scan 2026-10-05) | not recorded; the owner's test rev-B board (a second rev-B, not the `28:84:85:bb:af:8d` one above) | ask the owner |
| usb1101 on 2026-10-04, USB serial `1C:DB:D4:75:BB:D4` | not recorded | released 2.1.0 `oui-spy` image (`ACAB-ouispy` label); an OUI-Spy, one XIAO ESP32-S3 | yes, it runs a released image |

Every image recorded above predates the 2.2.0 pairing-window fix (the 2.2.0 entry in
`lib/acab_core/acab_version.h`). On those images, a board with a bond that stays powered with no
connection attempt for about 25 days after its window closes reads the window as open again for
about the next 25 days, and a stranger in range can then pair. Reflash a board before you leave it
powered on the hub that long.

A board that ran Stationary capture (Config `{"bufall":true}`, removed in 2.2.0): sync it with the
app, or update it by OTA from the app, before a USB flash to 2.2.0. Otherwise the 6-boot auto-wipe
can erase its undrained log on its first 2.2.0 boot (2.1.0 waited 64 boots on such a board).

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
