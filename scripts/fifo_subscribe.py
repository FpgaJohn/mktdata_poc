#!/usr/bin/env python3
"""fifo_subscribe.py -- subscribe to fifo_server.py and print frames.

Usage (from the dev machine or the board):
  ./fifo_subscribe.py [--host kr260u] [--port 5555] [--json] [fifo ...]

With no fifo names, subscribes to all (cmd, debug, mdebug). Default output
is a hex dump in the same format as `mktdata_poc_test poll`; --json passes
the raw NDJSON through instead (pipe to jq, a file, or another tool).

Start it right before running a test; stop with Ctrl-C.
"""

import argparse
import json
import socket
import sys


def hexdump(msg):
    data = bytes.fromhex(msg["data"])
    partial = " (partial)" if msg.get("partial") else ""
    out = [f"[{msg['fifo']}] frame {msg['frame']} ({msg['len']} bytes){partial}:"]
    for off in range(0, len(data), 8):
        chunk = data[off:off + 8]
        out.append(f"  {off:04x}: {chunk.hex()}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="kr260u")
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--json", action="store_true",
                    help="print raw NDJSON lines instead of hex dumps")
    ap.add_argument("fifos", nargs="*", help="cmd / debug / mdebug (default all)")
    args = ap.parse_args()

    with socket.create_connection((args.host, args.port), timeout=10) as s:
        sel = " ".join(args.fifos) if args.fifos else "*"
        s.sendall(f"SUBSCRIBE {sel}\n".encode())
        f = s.makefile("rb")
        try:
            for line in f:
                if args.json:
                    sys.stdout.write(line.decode())
                    sys.stdout.flush()
                    continue
                msg = json.loads(line)
                if "hello" in msg:
                    print(f"subscribed to {msg['subscribed']} on "
                          f"{args.host}:{args.port}", file=sys.stderr)
                    continue
                print(hexdump(msg))
                sys.stdout.flush()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
