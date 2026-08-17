#!/usr/bin/env python3
"""
Measures how far apart free-running cameras drift.

The cameras have no genlock and no real-time clock (see MEASUREMENTS M2, M3), so
each one runs on its own crystal. The specification assumes that matters — that a
delay set at the start of a show slowly goes wrong. This measures by how much.

Method: count video packets arriving from each camera over a long window. Every
camera claims 30 fps; the difference between their actual rates is the drift.

    ./drift-measure.py --minutes 10 cam01/0_0 cam02/0_0 cam03/0_0
"""

import argparse
import os
import pty
import select
import subprocess
import sys
import time

SERVER = "rtmp://127.0.0.1:1935"


def count_packets(path, stop_at, counts, key):
    """Counts video packets until stop_at, timestamping the first and last."""
    cmd = [
        "ffprobe", "-v", "error",
        "-fflags", "nobuffer",
        "-select_streams", "v",
        "-show_entries", "packet=pts_time",
        "-of", "csv=p=0",
        f"{SERVER}/{path}",
    ]
    # A pty keeps ffprobe line-buffered; over a plain pipe it batches output and
    # the timing is meaningless (see MEASUREMENTS M1).
    controller, peripheral = pty.openpty()
    proc = subprocess.Popen(cmd, stdout=peripheral, stderr=subprocess.DEVNULL, close_fds=True)
    os.close(peripheral)

    n, first, last, buf = 0, None, None, b""
    try:
        while time.monotonic() < stop_at:
            ready, _, _ = select.select([controller], [], [], 0.5)
            if not ready:
                continue
            try:
                chunk = os.read(controller, 8192)
            except OSError:
                break
            if not chunk:
                break
            now = time.monotonic()
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if line.strip():
                    n += 1
                    if first is None:
                        first = now
                    last = now
    finally:
        os.close(controller)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    counts[key] = (n, first, last)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+", help="e.g. cam01/0_0 cam02/0_0")
    ap.add_argument("--minutes", type=float, default=10)
    args = ap.parse_args()

    import threading
    duration = args.minutes * 60
    stop_at = time.monotonic() + duration
    counts = {}

    print(f"Counting frames from {len(args.paths)} cameras for {args.minutes:g} minutes.")
    print("Cameras claim 30 fps each; any difference between them is drift.\n")

    threads = [threading.Thread(target=count_packets, args=(p, stop_at, counts, p), daemon=True)
               for p in args.paths]
    for t in threads:
        t.start()

    started = time.monotonic()
    while time.monotonic() < stop_at:
        time.sleep(30)
        elapsed = time.monotonic() - started
        line = "  ".join(f"{p.split('/')[0]}:{counts.get(p, (0,))[0]:>6}" for p in args.paths)
        print(f"  {elapsed/60:5.1f} min   {line}")

    for t in threads:
        t.join(timeout=5)

    print("\n" + "─" * 62)
    print(f"{'camera':<12}{'frames':>9}{'window s':>11}{'fps':>10}{'drift':>14}")
    print("─" * 62)

    rates = {}
    for path in args.paths:
        n, first, last = counts.get(path, (0, None, None))
        if not n or first is None or last is None or last <= first:
            print(f"{path.split('/')[0]:<12}{n:>9}{'—':>11}{'—':>10}{'no data':>14}")
            continue
        window = last - first
        fps = (n - 1) / window
        rates[path] = fps
        print(f"{path.split('/')[0]:<12}{n:>9}{window:>11.1f}{fps:>10.4f}", end="")
        print(f"{(fps - 30.0) * 1000 / 30.0:>+13.1f} ppm")

    print("─" * 62)
    if len(rates) >= 2:
        fastest = max(rates.values())
        slowest = min(rates.values())
        spread_ppm = (fastest - slowest) / 30.0 * 1e6
        drift_ms_per_hour = spread_ppm * 3600 / 1000
        print(f"spread between fastest and slowest: {spread_ppm:.0f} ppm")
        print(f"→ they separate by about {drift_ms_per_hour:.0f} ms per hour")
        print()
        if drift_ms_per_hour < 20:
            print("Small. A delay set once will hold for a whole show.")
        elif drift_ms_per_hour < 100:
            print("Noticeable over a long show. The app should offer a re-measure.")
        else:
            print("Large. Delay must be re-measured during the show, not set once.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
