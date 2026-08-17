#!/usr/bin/env python3
"""
Generates the documentation screenshots of the node interface.

Screenshots in documentation rot: the interface changes, nobody re-takes them,
and the help ends up showing something that no longer exists. So they are
generated, not captured by hand — run this again after any UI change.

Each shot is a state worth recognising, not just a pretty picture: what a healthy
node looks like, and what each way it can go wrong looks like.

    ./make-screenshots.py                 # all states → docs/ui/
    ./make-screenshots.py --keep-running  # leave the last one up to poke at
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "node" / "agent.py"
OUT = REPO / "docs" / "ui"
PORT = 8019
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# Each entry is a state the operator should be able to recognise at a glance.
STATES = {
    "node-healthy": {
        "caption": "Everything running: four streams arriving, two disks pooled",
        "disks": [
            dict(device="/dev/sda1", size="2.0T", label="REC-A", uuid="a1",
                 mountpoint="/mnt/orah/REC-A", in_pool=True, free_bytes=412_000_000_000),
            dict(device="/dev/sdb1", size="2.0T", label="REC-B", uuid="b2",
                 mountpoint="/mnt/orah/REC-B", in_pool=True, free_bytes=1_890_000_000_000),
            dict(device="/dev/sdc1", size="4.0T", label="REC-C", uuid="c3",
                 mountpoint="", in_pool=False, free_bytes=0),
        ],
        "encoder": "h264_vaapi",
        "streams": 4,
        "force_free": 1_420_000_000_000,
        "force_rate": 30_100_000,
        "proxies": 4,
    },
    "node-disk-low": {
        "caption": "Disk running out — the number that decides whether to act",
        "disks": [
            dict(device="/dev/sda1", size="2.0T", label="REC-A", uuid="a1",
                 mountpoint="/mnt/orah/REC-A", in_pool=True, free_bytes=9_000_000_000),
        ],
        "encoder": "h264_vaapi",
        "streams": 4,
        "force_free": 9_000_000_000,
        "force_rate": 7_500_000,
        "proxies": 4,
    },
    "node-degraded": {
        "caption": "No hardware encoder: still recording, but serving no proxy",
        "disks": [
            dict(device="/dev/sda1", size="2.0T", label="REC-A", uuid="a1",
                 mountpoint="/mnt/orah/REC-A", in_pool=True, free_bytes=1_400_000_000_000),
        ],
        "encoder": None,
        "streams": 4,
        "force_free": 1_400_000_000_000,
        "force_rate": 30_000_000,
        "proxies": 0,
    },
    "node-stream-missing": {
        "caption": "One lens not arriving — the failure a list would hide",
        "disks": [
            dict(device="/dev/sda1", size="2.0T", label="REC-A", uuid="a1",
                 mountpoint="/mnt/orah/REC-A", in_pool=True, free_bytes=1_400_000_000_000),
        ],
        "encoder": "h264_vaapi",
        "streams": 3,
        "force_free": 1_400_000_000_000,
        "force_rate": 22_600_000,
        "proxies": 4,
    },
}


def build_demo_agent(state: dict, path: Path) -> None:
    """A copy of the real agent with its outward-facing state pinned.

    The page itself is untouched — only what it is told is mocked, so a screenshot
    can never show a layout the real interface does not produce.
    """
    source = AGENT.read_text()

    # repr, not json.dumps: this is being written into Python source, and JSON
    # spells booleans "true" where Python needs "True".
    disks_literal = repr(state["disks"])
    source = source.replace(
        "def list_disks() -> list[dict]:\n    if not Path(MOUNT_HELPER).exists():\n        return []",
        f"def list_disks() -> list[dict]:\n    return {disks_literal}\n"
        "    if not Path(MOUNT_HELPER).exists():\n        return []")

    if state["encoder"] is None:
        source = source.replace("ENCODER = detect_encoder()", "ENCODER = None")
    else:
        source = source.replace(
            "ENCODER = detect_encoder()",
            f'ENCODER = Encoder("{state["encoder"]}", hwaccel="vaapi")')

    if state["streams"] < 4:
        # Drop the last lens, as a camera with one SoC down would.
        source = source.replace(
            'for lens in LENSES:\n            path = live.get(stream_key(slot, lens))',
            'for lens in LENSES:\n            path = live.get(stream_key(slot, lens))\n'
            '            if lens == LENSES[-1]: path = None')

    if state.get("proxies"):
        source = source.replace(
            '"running": [s for s, j in proxies.items() if j.alive],',
            f'"running": {list(range(1, state["proxies"] + 1))},')

    if "force_free" in state:
        source = source.replace(
            '        "free_bytes": usage.free,',
            f'        "free_bytes": {state["force_free"]},')
        source = source.replace(
            '        "write_bytes_per_second": round(rate),',
            f'        "write_bytes_per_second": {state["force_rate"]},')
        source = source.replace(
            '        "seconds_remaining": round(seconds_left) if seconds_left else None,',
            f'        "seconds_remaining": {state["force_free"] // state["force_rate"]},')

    path.write_text(source)


def wait_for(url: str, timeout: float = 60) -> bool:
    """Waits for the agent to answer *anything*.

    An HTTP error still means the server is up — treating it as "not started"
    hides the real fault behind a timeout, which is exactly what happened the
    first time this ran.
    """
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status >= 500:
                    last_error = f"HTTP {r.status}"
                return True
        except urllib.error.HTTPError as e:
            print(f" [agent answered {e.code} — check the mock]", end="")
            return True
        except Exception as e:
            last_error = e
            time.sleep(1)
    print(f" [{last_error}]", end="")
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-running", action="store_true")
    ap.add_argument("--python", default=sys.executable)
    args = ap.parse_args()

    if not Path(CHROME).exists():
        print("Chrome not found — needed for headless screenshots")
        return 1

    OUT.mkdir(parents=True, exist_ok=True)
    work = Path("/tmp/orah-shots")
    work.mkdir(exist_ok=True)
    (work / "rec").mkdir(exist_ok=True)

    for name, state in STATES.items():
        print(f"  {name} …", end="", flush=True)
        demo = work / f"{name}.py"
        build_demo_agent(state, demo)

        proc = subprocess.Popen(
            [args.python, str(demo), "--node-id", "3", "--cameras", "1",
             "--record-dir", str(work / "rec"), "--port", str(PORT),
             "--no-announce"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        try:
            if not wait_for(f"http://127.0.0.1:{PORT}/status"):
                print(" agent did not start")
                continue

            # Let the page poll a few times so derived figures settle.
            for _ in range(4):
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/status", timeout=3).read()
                time.sleep(2)

            target = OUT / f"{name}.png"
            subprocess.run(
                [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                 f"--screenshot={target}", "--window-size=1500,470",
                 "--virtual-time-budget=7000", f"http://127.0.0.1:{PORT}/"],
                capture_output=True, timeout=90)
            print(f" → {target.relative_to(REPO)}")
        finally:
            if not (args.keep_running and name == list(STATES)[-1]):
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill()

    # An index so the shots carry their meaning with them.
    index = ["# Node interface\n",
             "Generated by `tools/make-screenshots.py`. Re-run it after any UI change —",
             "screenshots that are taken by hand stop matching the software.\n"]
    for name, state in STATES.items():
        index.append(f"\n## {state['caption']}\n")
        index.append(f"![{name}]({name}.png)\n")
    (OUT / "README.md").write_text("\n".join(index))
    print(f"\n  index → {(OUT / 'README.md').relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
