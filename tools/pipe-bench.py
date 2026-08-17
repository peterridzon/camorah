#!/usr/bin/env python3
"""
Measures what the FFmpeg streamcopy pipe actually costs.

The switcher design leans on one assumption: that FFmpeg can act as a thin
protocol adapter — RTMP in, RTMP out, container rewrap only — for a negligible
amount of CPU and latency, leaving all real video work to VideoToolbox and Metal.
This measures whether that assumption holds.

    source ──► ffmpeg -c copy ──► pipe (mpegts) ──► ffmpeg -c copy ──► output

Latency is measured by matching presentation timestamps between the source and
the output stream and comparing when each packet actually arrived. Both sides are
read the same way, so whatever buffering the reader adds cancels out of the
difference.

Usage:
    ./pipe-bench.py                       # cam01/0_0 on localhost
    ./pipe-bench.py --path cam03/1_1 --seconds 30
"""

import argparse
import json
import os
import pty
import select
import subprocess
import sys
import threading
import time
import urllib.request
from collections import deque

DEFAULT_SERVER = "rtmp://127.0.0.1:1935"

# How long a freshly connected reader needs before it stops racing through the
# server's catch-up burst and starts receiving packets as they are produced.
SETTLE_SECONDS = 8.0


def probe_arrivals(url, stop_event, samples, label):
    """Records (pts, arrival_monotonic) for video packets as they turn up.

    ffprobe is run behind a pseudo-terminal on purpose. Writing to a plain pipe
    makes its stdout block-buffered, so packet lines sit in a 4 KB buffer —
    hundreds of frames, many seconds — before appearing. Timestamping the moment
    a line is read then measures the buffer rather than the stream, which is what
    made an earlier version of this script report the output arriving over a
    second *before* its own source. A pty makes it line-buffered.
    """
    cmd = [
        "ffprobe", "-v", "error",
        "-fflags", "nobuffer", "-flags", "low_delay",
        "-select_streams", "v",
        "-show_entries", "packet=pts_time",
        "-of", "csv=p=0",
        url,
    ]

    controller, peripheral = pty.openpty()
    proc = subprocess.Popen(cmd, stdout=peripheral, stderr=subprocess.DEVNULL, close_fds=True)
    os.close(peripheral)

    buf = b""
    try:
        while not stop_event.is_set():
            ready, _, _ = select.select([controller], [], [], 0.5)
            if not ready:
                continue
            try:
                chunk = os.read(controller, 4096)
            except OSError:
                break
            if not chunk:
                break
            now = time.monotonic()
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                text = raw.strip().decode(errors="replace")
                if not text or text == "N/A":
                    continue
                try:
                    samples.append((round(float(text), 4), now))
                except ValueError:
                    continue
    finally:
        os.close(controller)
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def cpu_of(pids):
    """Total %CPU across the given pids, as ps reports it."""
    alive = [str(p) for p in pids]
    if not alive:
        return 0.0
    out = subprocess.run(["ps", "-o", "%cpu=", "-p", ",".join(alive)],
                         capture_output=True, text=True).stdout
    total = 0.0
    for line in out.splitlines():
        try:
            total += float(line.strip())
        except ValueError:
            pass
    return total


def path_stats(api, name):
    try:
        with urllib.request.urlopen(f"{api}/v3/paths/get/{name}", timeout=2) as r:
            return json.load(r)
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default=DEFAULT_SERVER)
    ap.add_argument("--api", default="http://127.0.0.1:9997")
    ap.add_argument("--path", default="cam01/0_0", help="source path to pull")
    ap.add_argument("--out", default="bench/out", help="path to publish through the pipe")
    ap.add_argument("--seconds", type=int, default=20)
    args = ap.parse_args()

    src_url = f"{args.server}/{args.path}"
    out_url = f"{args.server}/{args.out}"

    print(f"source   {src_url}")
    print(f"through  ffmpeg -c copy │ mpegts │ ffmpeg -c copy")
    print(f"output   {out_url}")
    print()

    # ── the pipe under test ─────────────────────────────────────────────────
    # Leg 1: pull RTMP, rewrap to mpegts on stdout. No decode.
    leg1 = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-fflags", "nobuffer", "-flags", "low_delay",
         "-i", src_url,
         "-c", "copy", "-copyts",
         # The mpegts muxer otherwise shifts every timestamp forward by its
         # default muxdelay (0.7s) + muxpreload (0.5s). That shift is pure
         # labelling — no data is held back — but it makes timestamps from this
         # leg incomparable with the source, and would mislead anything
         # downstream that trusts them.
         "-muxdelay", "0", "-muxpreload", "0",
         "-f", "mpegts", "pipe:1"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # Leg 2: read mpegts from stdin, rewrap to FLV, publish. No encode.
    leg2 = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error",
         "-fflags", "nobuffer", "-flags", "low_delay",
         "-f", "mpegts", "-i", "pipe:0",
         "-c", "copy", "-copyts",
         "-f", "flv", out_url],
        stdin=leg1.stdout, stderr=subprocess.PIPE)
    leg1.stdout.close()   # leg2 owns the read end now

    # The second leg cannot publish until the first has parsed enough of the
    # source, so wait for the server to report the output live rather than
    # guessing at a sleep — guessing is what made the first run measure nothing.
    print("waiting for the output path to go live...")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        stats = path_stats(args.api, args.out)
        if stats and stats.get("ready"):
            print(f"  live after {30 - (deadline - time.monotonic()):.1f}s, "
                  f"tracks {stats.get('tracks')}")
            break
        if leg1.poll() is not None or leg2.poll() is not None:
            break
        time.sleep(0.25)
    else:
        print("  output never became ready")

    # Let both legs settle before timing anything.
    time.sleep(2)

    if leg1.poll() is not None or leg2.poll() is not None:
        print("\nPIPE FAILED TO START")
        for name, proc in (("leg1", leg1), ("leg2", leg2)):
            err = proc.stderr.read().decode(errors="replace").strip()
            if err:
                print(f"  {name}: {err[:600]}")
        return 1

    # ── measure ─────────────────────────────────────────────────────────────
    stop = threading.Event()
    src_samples, out_samples = deque(maxlen=20000), deque(maxlen=20000)
    probe_start = time.monotonic()

    threads = [
        threading.Thread(target=probe_arrivals, args=(src_url, stop, src_samples, "src"), daemon=True),
        threading.Thread(target=probe_arrivals, args=(out_url, stop, out_samples, "out"), daemon=True),
    ]
    for t in threads:
        t.start()

    print(f"measuring for {args.seconds}s ({SETTLE_SECONDS:.0f}s of that discarded as warm-up)...")
    cpu_samples = []
    for _ in range(args.seconds):
        time.sleep(1)
        cpu_samples.append(cpu_of([leg1.pid, leg2.pid]))

    stop.set()
    time.sleep(1)

    # ── latency: match packets by presentation timestamp ────────────────────
    #
    # A reader that has just connected is handed a burst of recent packets and
    # races through them far faster than real time. Timing anything from that
    # window measures the burst, not the pipe — it is what made the first
    # attempt report a physically impossible negative latency. So both sides are
    # cut back to the part of the run where they were genuinely live.
    settle = probe_start + SETTLE_SECONDS
    src_live = [(p, t) for p, t in src_samples if t >= settle]
    out_live = [(p, t) for p, t in out_samples if t >= settle]

    def rate(samples):
        if len(samples) < 2:
            return 0.0
        span = samples[-1][1] - samples[0][1]
        return (len(samples) - 1) / span if span > 0 else 0.0

    src_rate, out_rate = rate(src_live), rate(out_live)

    src_by_pts = dict(src_live)
    deltas = []
    for pts, t_out in out_live:
        t_src = src_by_pts.get(pts)
        if t_src is not None:
            deltas.append((t_out - t_src) * 1000.0)

    print()
    print("─" * 52)
    print(f"steady-state rate   source {src_rate:5.1f} fps   output {out_rate:5.1f} fps")

    # If either side is still catching up, the numbers below mean nothing.
    if src_rate > 0 and out_rate > 0 and max(src_rate, out_rate) / min(src_rate, out_rate) > 1.25:
        print("  readers are not both live — treat the latency below with suspicion")

    if len(deltas) < 10:
        print(f"only {len(deltas)} matched packets in the live window — unreliable")
        print(f"  source packets: {len(src_samples)} total, {len(src_live)} live")
        print(f"  output packets: {len(out_samples)} total, {len(out_live)} live")
    else:
        deltas.sort()
        mid = len(deltas) // 2
        print(f"matched packets     {len(deltas)}")
        print(f"added latency")
        print(f"  median            {deltas[mid]:7.1f} ms")
        print(f"  5th percentile    {deltas[len(deltas)//20]:7.1f} ms")
        print(f"  95th percentile   {deltas[len(deltas)*19//20]:7.1f} ms")
        print(f"  spread            {deltas[-1] - deltas[0]:7.1f} ms")

    if cpu_samples:
        steady = cpu_samples[2:] or cpu_samples
        print(f"cpu, both legs")
        print(f"  mean              {sum(steady)/len(steady):7.1f} %")
        print(f"  peak              {max(steady):7.1f} %")

    stats = path_stats(args.api, args.out)
    if stats:
        print(f"published           {stats.get('bytesReceived', 0)/1e6:7.1f} MB, "
              f"tracks {stats.get('tracks')}")
    print("─" * 52)

    for proc in (leg2, leg1):
        proc.terminate()
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            proc.kill()
    return 0


if __name__ == "__main__":
    sys.exit(main())
