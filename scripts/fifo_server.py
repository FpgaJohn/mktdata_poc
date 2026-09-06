#!/usr/bin/env python3
"""fifo_server.py -- stream the capture-FIFO frames to TCP subscribers.

Polls the three RX-only PG080 capture FIFOs (cmd/debug/mdebug) via UIO,
exactly like `mktdata_poc_test poll`, and broadcasts every frame to any
connected TCP subscriber as NDJSON (one JSON object per line):

  {"fifo":"CMD","frame":3,"ts":1699.123,"len":16,"partial":false,
   "data":"beefbeef00000000..."}

"data" is the frame in wire order (first byte on the stream first), hex.

Protocol: connect, send one line -- e.g. "SUBSCRIBE cmd debug" (or
"SUBSCRIBE *" / empty line for all) -- then read NDJSON lines forever.

Run as root on the board (needs /dev/uioN):
  sudo ./fifo_server.py [--port 5555] [--fifos cmd debug mdebug]

Do NOT run it at the same time as `mktdata_poc_test poll` (or the `debug`/
`mdebug`/`cmd` subcommands) -- both would pop the same FIFOs.

The server drains the FIFOs continuously whether or not anyone is
subscribed, so late subscribers start clean at the moment they connect;
subscribe right before starting a test to capture that test's frames.
Slow subscribers are dropped-from, not waited-for (per-client queue,
frames are discarded for that client when it falls > QUEUE_MAX behind).
"""

import argparse
import ctypes
import json
import mmap
import os
import signal
import socket
import struct
import sys
import threading
import time
import queue

# PS address map (M_AXI_HPM0_LPD) -- must match vivado/mktdata_poc.tcl and
# apps/mktdata_poc_test/main.c.
FIFOS = {
    "debug":  {"tag": "DEBUG",  "ctrl": 0x80070000, "data": 0x80080000},
    "mdebug": {"tag": "MDEBUG", "ctrl": 0x80050000, "data": 0x80060000},
    "cmd":    {"tag": "CMD",    "ctrl": 0x800A0000, "data": 0x800B0000},
}
MAP_SIZE = 0x10000

# AXI4-Stream FIFO (PG080) registers
FIFO_ISR = 0x00
FIFO_RDFR = 0x18
FIFO_RDFO = 0x1C
FIFO_RLR = 0x24
FIFO_SRR = 0x28
FIFO_AXI4_RDFD = 0x1000
FIFO_RESET_MAGIC = 0xA5

POLL_IDLE_S = 0.0005   # idle backoff when RDFO == 0
QUEUE_MAX = 4096       # per-subscriber frame queue before dropping

g_stop = threading.Event()


def find_uio(addr):
    """Find /dev/uioN whose map0 physical address == addr."""
    base = "/sys/class/uio"
    for name in sorted(os.listdir(base)):
        if not name.startswith("uio"):
            continue
        try:
            with open(f"{base}/{name}/maps/map0/addr") as f:
                if int(f.read().strip(), 16) == addr:
                    return f"/dev/{name}"
        except OSError:
            continue
    return None


class UioMap:
    """A UIO mapping exposed as a c_uint32 array (each access = one 32-bit
    load/store, matching the platform's PIO width rules)."""

    def __init__(self, addr, label):
        dev = find_uio(addr)
        if dev is None:
            raise RuntimeError(f"{label}: no UIO device at 0x{addr:08x} -- "
                               "is the mktdata_poc app loaded (xmutil loadapp)?")
        self.fd = os.open(dev, os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, MAP_SIZE, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=0)
        self.regs = (ctypes.c_uint32 * (MAP_SIZE // 4)).from_buffer(self.mm)
        print(f"  {label:<22}: {dev} @ 0x{addr:08x}")

    def r32(self, off):
        return self.regs[off // 4]

    def w32(self, off, val):
        self.regs[off // 4] = val


class Broker:
    """Fan frames out to subscriber queues."""

    def __init__(self):
        self.lock = threading.Lock()
        self.subs = []  # list of (set_of_fifo_names, queue)

    def add(self, names, q):
        with self.lock:
            self.subs.append((names, q))

    def remove(self, q):
        with self.lock:
            self.subs = [(n, sq) for (n, sq) in self.subs if sq is not q]

    def publish(self, name, msg):
        line = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        with self.lock:
            for names, q in self.subs:
                if name in names:
                    try:
                        q.put_nowait(line)
                    except queue.Full:
                        pass  # slow client: drop this frame for it


def fifo_poller(name, info, broker):
    """Poll one RX-only PG080 FIFO forever; publish each frame."""
    tag = info["tag"]
    ctrl = UioMap(info["ctrl"], f"axi_fifo_{name} (ctrl)")
    data = UioMap(info["data"], f"axi_fifo_{name} (data)")

    def reset_rx():
        ctrl.w32(FIFO_RDFR, FIFO_RESET_MAGIC)
        time.sleep(0.001)
        ctrl.w32(FIFO_ISR, 0xFFFFFFFF)

    # RX-only core reset: SRR + RDFR, then clear sticky ISR.
    ctrl.w32(FIFO_SRR, FIFO_RESET_MAGIC)
    time.sleep(0.001)
    reset_rx()
    print(f"[{tag}] polling (post-reset RDFO={ctrl.r32(FIFO_RDFO)})")

    frame = 0
    warned_no_tlast = False
    while not g_stop.is_set():
        if ctrl.r32(FIFO_RDFO) == 0:
            time.sleep(POLL_IDLE_S)
            continue

        # RLR is valid only once a complete (TLAST-terminated) frame is in
        # the FIFO; reading it pops the next frame's byte length.
        rlr = ctrl.r32(FIFO_RLR)
        if rlr == 0:
            if not warned_no_tlast:
                print(f"[{tag}] words present but no complete frame "
                      "(stream without TLAST?)", file=sys.stderr)
                warned_no_tlast = True
            time.sleep(POLL_IDLE_S)
            continue
        warned_no_tlast = False

        length = rlr & 0x7FFFFFFF
        partial = bool(rlr >> 31)

        # A frame can't exceed the RX FIFO (512 x 64-bit words); an
        # implausible RLR means we've lost sync -- reset and resync.
        if length == 0 or length > 4096:
            print(f"[{tag}] implausible RLR=0x{rlr:08x} -- resetting RX FIFO",
                  file=sys.stderr)
            reset_rx()
            continue

        nwords = (length + 7) // 8
        raw = bytearray()
        for _ in range(nwords):
            # 64-bit RDFD word as the two 32-bit halves of the same beat;
            # LSB of the word is the first byte on the stream.
            lo = data.r32(FIFO_AXI4_RDFD)
            hi = data.r32(FIFO_AXI4_RDFD + 4)
            raw += struct.pack("<Q", lo | (hi << 32))

        frame += 1
        broker.publish(name, {
            "fifo": tag,
            "frame": frame,
            "ts": round(time.time(), 6),
            "len": length,
            "partial": partial,
            "data": bytes(raw[:length]).hex(),
        })


def client_thread(conn, addr, broker, available):
    peer = f"{addr[0]}:{addr[1]}"
    q = queue.Queue(maxsize=QUEUE_MAX)
    try:
        conn.settimeout(30.0)
        f = conn.makefile("rb")
        req = f.readline().decode(errors="replace").strip()
        words = req.split()
        if words and words[0].upper() == "SUBSCRIBE":
            words = words[1:]
        names = set(w.lower() for w in words) & set(available)
        if not names or "*" in words:
            names = set(available)
        conn.settimeout(None)
        conn.sendall((json.dumps({"hello": "mktdata_poc fifo_server",
                                  "subscribed": sorted(names)}) + "\n").encode())
        print(f"[server] {peer} subscribed to {sorted(names)}")
        broker.add(names, q)
        while not g_stop.is_set():
            try:
                line = q.get(timeout=1.0)
            except queue.Empty:
                continue
            conn.sendall(line)
    except (OSError, ValueError):
        pass
    finally:
        broker.remove(q)
        conn.close()
        print(f"[server] {peer} disconnected")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--fifos", nargs="*", default=sorted(FIFOS),
                    choices=sorted(FIFOS), metavar="FIFO")
    args = ap.parse_args()

    broker = Broker()
    print("Opening UIOs:")
    for name in args.fifos:
        t = threading.Thread(target=fifo_poller, args=(name, FIFOS[name], broker),
                             daemon=True, name=f"poll-{name}")
        t.start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.bind, args.port))
    srv.listen(8)
    print(f"[server] listening on {args.bind}:{args.port} "
          f"(fifos: {', '.join(args.fifos)}). Ctrl-C to stop.")

    signal.signal(signal.SIGINT, lambda *a: g_stop.set())
    signal.signal(signal.SIGTERM, lambda *a: g_stop.set())
    srv.settimeout(1.0)
    while not g_stop.is_set():
        try:
            conn, addr = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=client_thread,
                         args=(conn, addr, broker, args.fifos),
                         daemon=True).start()
    print("\nStopped.")


if __name__ == "__main__":
    main()
