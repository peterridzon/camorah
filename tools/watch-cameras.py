#!/usr/bin/env python3
"""
Watches the network and reports what cameras do, as they do it.

Built for the moment a camera is plugged in and nobody is sure what happens
next: it appears in ARP, then answers ping, then opens its control port, then
announces itself — or it gets partway and stops. A one-shot check sees only the
end state and calls it "not there". This prints the sequence.

Prints only changes, with a timestamp, so it can be left running while cameras
are rigged.

    ./watch-cameras.py                      # 192.168.0.x
    ./watch-cameras.py --subnet 10.41.0     # somewhere else
"""

import argparse
import re
import socket
import subprocess
import sys
import time
from datetime import datetime

ORAH_OUI = "48:65:ee"
CONTROL_PORT = 9989


def sweep(subnet: str) -> None:
    """ARP only knows hosts something has spoken to, so speak to all of them."""
    procs = [
        subprocess.Popen(["/sbin/ping", "-c", "1", "-t", "1", f"{subnet}.{i}"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for i in range(1, 255)
    ]
    for p in procs:
        p.wait()


def orah_hosts() -> dict[str, str]:
    """Address → MAC, for anything with Orah's OUI."""
    try:
        output = subprocess.run(["/usr/sbin/arp", "-an"],
                                capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return {}

    found = {}
    for line in output.splitlines():
        if ORAH_OUI not in line.lower():
            continue
        match = re.search(r"\((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-fA-F:]+)", line)
        if match:
            found[match.group(1)] = match.group(2)
    return found


def port_open(host: str, port: int = CONTROL_PORT, timeout: float = 1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def reachable(host: str) -> bool:
    return subprocess.run(["/sbin/ping", "-c", "1", "-t", "1", host],
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def bonjour_names() -> set[str]:
    """One short browse. Not authoritative — mDNS keeps departed cameras for a
    while — but it is what the app itself sees."""
    try:
        proc = subprocess.Popen(["/usr/bin/dns-sd", "-B", "_vscamera._tcp"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True)
        time.sleep(3)
        proc.terminate()
        out, _ = proc.communicate(timeout=3)
    except Exception:
        return set()

    names = set()
    for line in out.splitlines():
        if "_vscamera._tcp." in line and "Add" in line:
            names.add(line.split()[-1])
    return names


def stamp() -> str:
    return datetime.now().strftime("%H:%M:%S")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subnet", default="192.168.0")
    parser.add_argument("--interval", type=float, default=4.0)
    args = parser.parse_args()

    print(f"{stamp()}  watching {args.subnet}.x for Orah hardware — ctrl-c to stop",
          flush=True)

    # Each address carries its own little state machine, and only transitions
    # are printed. A camera that comes up and dies leaves a legible trail.
    state: dict[str, dict] = {}
    known_names: set[str] = set()
    round_number = 0

    while True:
        round_number += 1
        sweep(args.subnet)
        hosts = orah_hosts()

        for host, mac in sorted(hosts.items()):
            was = state.get(host)
            if was is None:
                print(f"{stamp()}  {host}  appeared on the network   ({mac})", flush=True)
                state[host] = {"ping": None, "port": None, "seen": round_number}
                was = state[host]
            was["seen"] = round_number

            now_ping = reachable(host)
            if now_ping != was["ping"]:
                print(f"{stamp()}  {host}  "
                      + ("answers ping" if now_ping else "stopped answering ping"),
                      flush=True)
                was["ping"] = now_ping

            now_port = port_open(host) if now_ping else False
            if now_port != was["port"]:
                print(f"{stamp()}  {host}  "
                      + (f"control port {CONTROL_PORT} open — ready for a check"
                         if now_port else f"control port {CONTROL_PORT} closed"),
                      flush=True)
                was["port"] = now_port

        for host in [h for h, v in state.items() if v["seen"] < round_number - 1]:
            print(f"{stamp()}  {host}  gone from the network", flush=True)
            del state[host]

        # Bonjour every few rounds: the browse costs three seconds.
        if round_number % 3 == 1:
            names = bonjour_names()
            for name in names - known_names:
                print(f"{stamp()}  announced itself: {name}", flush=True)
            for name in known_names - names:
                print(f"{stamp()}  stopped announcing: {name}", flush=True)
            known_names = names

        time.sleep(args.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("")
