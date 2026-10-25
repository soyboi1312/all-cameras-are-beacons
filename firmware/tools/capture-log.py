#!/usr/bin/env python3
"""Timestamped serial capture for field work, with typed ground-truth markers.

WHY THIS EXISTS. A drive/park capture is only worth anything if you can line the RF up against
what you were standing next to. Reading the serial firehose live is useless, and a bare log with
no marks is nearly as bad, because a parking lot is full of phones and store APs and nothing in
the log says which rows were the target. So: every line gets a wall clock AND an elapsed stamp,
and anything you TYPE while it runs is stamped into the same stream as a marker.

    ./capture-log.py                       # auto-find the board, write ./capture-<stamp>.log
    ./capture-log.py -o lvt-lot1.log       # name it yourself
    ./capture-log.py -p /dev/cu.usbmodem1101

While it runs, type a note and hit return. It lands in the log as:

    [   142.7s  10:41:33] ### unit 2, standing 5m from the trailer

Then grep the log by marker afterwards, or split on them.

Requires a firmware build with -DACAB_DIAG (BLE) and/or -DACAB_CAPTURE_BUILD (WiFi), otherwise there
is nothing to capture but the ordinary [diag] counters. Desert-mode reminder: the toggle IS
persisted to NVS now (desertSetEnabled / desertRestoreEnabled in desert_detect.cpp, since
2026-08-08), so an ordinary app reflash keeps it; only a full flash erase, or a board that never
had it enabled, starts with it off. A stale build without persistence once voided a drive test,
because without Desert you only log devices that already match a known signature - exactly the
wrong thing when you are hunting an unknown vendor. So the checklist stands: enable Desert,
confirm you are seeing junk, THEN drive.

Survives USB CDC drops (the ESP32-S3's CDC goes away on reset) by reopening, so a board reboot
mid-capture costs you a line, not the session.

Keep the host awake for the whole capture: lid open, on power, and run it as
`caffeinate -i ./capture-log.py`. On battery a Mac sleeps when the lid closes whatever caffeinate
says, and while it sleeps the board's USB output is dropped, not queued. On 2026-10-21 that lost
every body-cam minute of a downtown walk. If the host does sleep, the log carries a
"-- host slept N s; the next lines may predate this stamp --" line: the few lines right after it
may have been printed before the sleep.
"""

import argparse
import glob
import os
import sys
import threading
import time

try:
    import serial
except ImportError:
    for cand in glob.glob(os.path.expanduser("~/.platformio/penv/lib/python*/site-packages")):
        sys.path.insert(0, cand)
    try:
        import serial
    except ImportError:
        sys.exit("pyserial not found. Try: pip3 install pyserial")


def find_port():
    ports = sorted(glob.glob("/dev/cu.usbmodem*")) + sorted(glob.glob("/dev/ttyACM*"))
    if not ports:
        sys.exit("No board found. Plug it in, or pass -p /dev/cu.usbmodemXXXX")
    if len(ports) > 1:
        print(f"!! {len(ports)} ports found, using {ports[0]}. Pass -p to pick another: {ports}",
              file=sys.stderr)
    return ports[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-p", "--port", help="serial port (default: auto-detect)")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("-o", "--out", help="output file (default: capture-<stamp>.log)")
    ap.add_argument("-q", "--quiet", action="store_true", help="do not echo to the terminal")
    args = ap.parse_args()

    port = args.port or find_port()
    out = args.out or time.strftime("capture-%Y%m%d-%H%M%S.log")
    t0 = time.time()
    lock = threading.Lock()

    # Wall clock vs monotonic: time.monotonic() stops while the host sleeps (mach_absolute_time on
    # macOS, CLOCK_MONOTONIC on Linux), so wall time racing ahead of it means the host slept.
    clocks = [time.time(), time.monotonic()]

    def emit(line):
        fh.write(line + "\n")
        fh.flush()              # flush every line: a capture you lose to a crash is not a capture
        if not args.quiet:
            print(line, flush=True)

    def stamp(text, marker=False):
        with lock:
            wall, mono = time.time(), time.monotonic()
            slept = (wall - clocks[0]) - (mono - clocks[1])
            clocks[:] = [wall, mono]
            head = f"[{wall - t0:8.1f}s  {time.strftime('%H:%M:%S', time.localtime(wall))}] "
            if slept > 2:
                # Board output is dropped while the host sleeps, and the first lines read after a
                # wake were printed before the sleep: say so, or they read as live at this stamp.
                emit(f"{head}-- host slept {slept:.0f} s; the next lines may predate this stamp --")
            emit(head + ("### " if marker else "") + text)

    fh = open(out, "a", buffering=1)
    stamp(f"capture start  port={port}  baud={args.baud}")
    stamp("type a note + return at any time to drop a ground-truth marker; ctrl-C to stop")

    def reader():
        while True:
            try:
                sp = serial.Serial(port, args.baud, timeout=1)
            except Exception:
                time.sleep(1)
                continue
            try:
                while True:
                    raw = sp.readline()
                    if not raw:
                        continue
                    stamp(raw.decode(errors="replace").rstrip())
            except Exception as e:
                stamp(f"-- serial dropped ({type(e).__name__}), reopening --")
                try:
                    sp.close()
                except Exception:
                    pass
                time.sleep(1)

    threading.Thread(target=reader, daemon=True).start()

    try:
        for note in sys.stdin:
            note = note.strip()
            if note:
                stamp(note, marker=True)
    except KeyboardInterrupt:
        pass
    finally:
        stamp("capture end")
        fh.close()
        print(f"\nwrote {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
