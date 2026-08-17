#!/usr/bin/env python3
"""
Recording node agent.

Runs on each recording machine (cheap Intel mini PCs). One node owns a small
number of cameras — two in the reference deployment — and does three things:

  1. Watches MediaMTX record every stream its cameras publish straight to disk
  2. Produces one small proxy stream per camera so the Mac can show a multiview
     without pulling full-resolution video across the network
  3. Announces itself over Bonjour so nobody has to type twelve IP addresses

Cameras publish *to this machine*, not to the Mac (docs/SPECIFICATION.md §3.1).

**Recording is done by MediaMTX itself**, not by this agent. The packets arrive and
land on the SSD in the same process — no ffmpeg, no second RTMP hop, no transcode.
Measured at 1.8% CPU and 48 MB for four streams. The original Orah setup worked the
same way (nginx-rtmp with a `recorder` block, see nginx_file/nginx.conf); this is the
same idea with software that is still maintained.

The agent's job is therefore: report status, manage the proxy, and answer the Mac.

Two rules are load-bearing and are enforced here rather than left to operators:

  · Recording always wins. Proxy work runs at lower priority and is the first
    thing dropped when the machine is under strain. A blind multiview is an
    inconvenience; a hole in a recording is unrecoverable.

  · Proxy never falls back to software encoding. On a two-core Celeron a single
    software 1080p transcode consumes the whole machine, and the recorder is on
    that same machine. If no hardware encoder is present the node reports itself
    degraded and simply serves no proxy.

Install:
    pip install fastapi uvicorn zeroconf
    ffmpeg and mediamtx must be on PATH

Run:
    python agent.py --node-id 1 --record-dir /mnt/rec --cameras 1,2
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import os
import platform
import re
import shutil
import socket
import subprocess
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, PlainTextResponse
from pydantic import BaseModel
import urllib.request
import uvicorn

# ─── Constants ────────────────────────────────────────────────────────────────

LENSES = ["0_0", "0_1", "1_0", "1_1"]
IS_WINDOWS = platform.system() == "Windows"
IS_MACOS = platform.system() == "Darwin"

SERVICE_TYPE = "_orahnode._tcp.local."

# Proxy shape. Small on purpose: the Mac may decode two dozen of these.
PROXY_WIDTH = 480
PROXY_HEIGHT = 270
PROXY_FPS = 10
PROXY_BITRATE = "220k"

# ─── Arguments ────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser(description="Orah recording node agent")
parser.add_argument("--node-id", type=int, default=1)
parser.add_argument("--cameras", type=str, default="",
                    help="Camera slots this node owns, e.g. 1,2. May be empty; "
                         "the Mac assigns them at run time.")
parser.add_argument("--record-dir", type=str, default="./recordings")
parser.add_argument("--port", type=int, default=8000)
parser.add_argument("--mediamtx", type=str, default="rtmp://127.0.0.1:1935",
                    help="Local MediaMTX the cameras publish into")
parser.add_argument("--no-announce", action="store_true",
                    help="Skip Bonjour announcement")
parser.add_argument("--mediamtx-api", type=str, default="http://127.0.0.1:9997",
                    help="Local MediaMTX API, used to read what is recording")
args = parser.parse_args()

RECORD_DIR = Path(args.record_dir).expanduser().resolve()
RECORD_DIR.mkdir(parents=True, exist_ok=True)


# ─── Hardware encoder detection ───────────────────────────────────────────────

@dataclass
class Encoder:
    """A hardware H.264 encoder, plus how to feed it."""
    name: str
    hwaccel: Optional[str] = None
    scale_filter: str = f"scale={PROXY_WIDTH}:{PROXY_HEIGHT}"
    extra: list[str] = field(default_factory=list)


# Ordered by preference per platform. Software encoders are deliberately absent.
CANDIDATES: list[Encoder] = (
    [Encoder("h264_videotoolbox", hwaccel="videotoolbox",
             extra=["-realtime", "1"])]
    if IS_MACOS else
    [
        Encoder("h264_qsv", hwaccel="qsv",
                scale_filter=f"scale_qsv=w={PROXY_WIDTH}:h={PROXY_HEIGHT}"),
        Encoder("h264_vaapi", hwaccel="vaapi",
                scale_filter=f"scale_vaapi=w={PROXY_WIDTH}:h={PROXY_HEIGHT}"),
        Encoder("h264_nvenc", hwaccel="cuda"),
    ]
)


def ffmpeg_has_encoder(name: str) -> bool:
    try:
        out = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                             capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return re.search(rf"^\s*\S+\s+{re.escape(name)}\s", out, re.MULTILINE) is not None


def encoder_actually_works(enc: Encoder) -> bool:
    """Listing an encoder is not the same as being able to use it.

    A machine can advertise h264_qsv and still fail at runtime because the iGPU
    is disabled, the driver is missing, or the user lacks render-group access.
    Finding that out during a show is not acceptable, so we encode two frames now.
    """
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=10",
        "-frames:v", "2",
        "-c:v", enc.name, *enc.extra,
        "-f", "null", "-",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()
        if detail:
            print(f"[hw] {enc.name} rejected: {detail[-1][:160]}")
        return False
    return True


def detect_encoder() -> Optional[Encoder]:
    for enc in CANDIDATES:
        if not ffmpeg_has_encoder(enc.name):
            continue
        if encoder_actually_works(enc):
            print(f"[hw] hardware encoder: {enc.name}")
            return enc
    print("[hw] NO WORKING HARDWARE ENCODER — node runs degraded, no proxy.")
    print("[hw] Recording is unaffected. Software encoding is deliberately not")
    print("[hw] used: it would starve the recorder on this class of machine.")
    return None


ENCODER: Optional[Encoder] = None   # resolved at startup


# ─── Process bookkeeping ──────────────────────────────────────────────────────

@dataclass
class Job:
    proc: subprocess.Popen
    started: float
    target: str

    @property
    def alive(self) -> bool:
        return self.proc.poll() is None

    @property
    def uptime(self) -> float:
        return time.monotonic() - self.started


cameras: list[int] = [int(x) for x in args.cameras.split(",") if x.strip()]
proxies: dict[int, Job] = {}        # slot → job
proxy_lens: str = LENSES[0]         # which lens the multiview is showing
degraded_reason: Optional[str] = None


def stream_key(slot: int, lens: str) -> str:
    return f"cam{slot:02d}/{lens}"


def source_url(slot: int, lens: str) -> str:
    return f"{args.mediamtx}/cam{slot:02d}/{lens}"


def proxy_url(slot: int) -> str:
    return f"{args.mediamtx}/cam{slot:02d}/proxy"


def spawn(cmd: list[str], *, low_priority: bool = False) -> subprocess.Popen:
    kwargs: dict = {}
    if IS_WINDOWS:
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW | (
            subprocess.BELOW_NORMAL_PRIORITY_CLASS if low_priority else 0)
    elif low_priority:
        # Proxy work must yield to the recorder under load.
        kwargs["preexec_fn"] = lambda: os.nice(10)
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, **kwargs)


def stop_job(job: Optional[Job], timeout: float = 5.0) -> bool:
    if job is None or not job.alive:
        return False
    job.proc.terminate()
    try:
        job.proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        job.proc.kill()
    return True


# ─── Recording — MediaMTX does it, we only report on it ──────────────────────

def mediamtx_paths() -> list[dict]:
    """What MediaMTX currently has, straight from its API."""
    try:
        with urllib.request.urlopen(f"{args.mediamtx_api}/v3/paths/list", timeout=2) as r:
            import json
            return json.load(r).get("items", [])
    except Exception:
        return []


def recording_state() -> dict:
    """Per camera, per lens: is a stream arriving and being written?"""
    live = {p["name"]: p for p in mediamtx_paths()}
    state = {}
    for slot in cameras:
        lenses = {}
        for lens in LENSES:
            path = live.get(stream_key(slot, lens))
            if path and path.get("ready"):
                lenses[lens] = {
                    "recording": True,
                    "bytes": path.get("bytesReceived", 0),
                    "tracks": path.get("tracks", []),
                }
            else:
                lenses[lens] = {"recording": False, "bytes": 0, "tracks": []}
        state[f"cam{slot:02d}"] = lenses
    return state


def recording_summary() -> tuple[int, int]:
    """(streams arriving, streams expected)."""
    state = recording_state()
    arriving = sum(1 for lenses in state.values()
                   for v in lenses.values() if v["recording"])
    return arriving, len(cameras) * len(LENSES)


# ─── Proxy ────────────────────────────────────────────────────────────────────

def start_proxy(slot: int) -> bool:
    """One small stream per camera, from whichever lens the multiview shows.

    Only the selected lens is transcoded. Doing all four would be four times the
    work for a view that shows one at a time — and beyond the weakest node's iGPU.
    """
    if ENCODER is None:
        return False
    existing = proxies.get(slot)
    if existing and existing.alive:
        return False

    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    if ENCODER.hwaccel:
        cmd += ["-hwaccel", ENCODER.hwaccel]
    cmd += [
        "-i", source_url(slot, proxy_lens),
        "-map", "0:v:0", "-map", "0:a:0?",
        "-vf", ENCODER.scale_filter,
        "-r", str(PROXY_FPS),
        "-c:v", ENCODER.name, "-b:v", PROXY_BITRATE,
        "-g", str(PROXY_FPS * 2),
        *ENCODER.extra,
        "-c:a", "copy",               # audio passes through untouched
        "-f", "flv", proxy_url(slot),
    ]
    proxies[slot] = Job(spawn(cmd, low_priority=True), time.monotonic(), proxy_url(slot))
    print(f"[proxy] cam{slot:02d} lens {proxy_lens} → {proxy_url(slot)}")
    return True


def stop_proxy(slot: int) -> bool:
    return stop_job(proxies.pop(slot, None))


def restart_all_proxies() -> None:
    for slot in list(proxies):
        stop_proxy(slot)
    for slot in cameras:
        start_proxy(slot)


# ─── Disk ─────────────────────────────────────────────────────────────────────

def disk_status() -> dict:
    """Free space and, more usefully, how much longer this node can record.

    "Is it online" is the wrong question during a show. "How much longer will it
    keep recording" is the one that decides whether somebody has to act.
    """
    usage = shutil.disk_usage(RECORD_DIR)
    arriving, expected = recording_summary()

    size = _directory_size(RECORD_DIR)
    now = time.monotonic()
    _size_history.append((now, size))

    # Measure over the widest window still inside the horizon, so the figure is
    # steady rather than jumping with each sample.
    rate = 0.0
    while len(_size_history) > 1 and now - _size_history[0][0] > _RATE_WINDOW:
        _size_history.popleft()
    if len(_size_history) > 1:
        first_time, first_size = _size_history[0]
        span = now - first_time
        if span >= 3 and size > first_size:
            rate = (size - first_size) / span

    seconds_left = usage.free / rate if rate > 0 else None

    return {
        "path": str(RECORD_DIR),
        "free_bytes": usage.free,
        "total_bytes": usage.total,
        "recorded_bytes": size,
        "write_bytes_per_second": round(rate),
        "seconds_remaining": round(seconds_left) if seconds_left else None,
        "streams_arriving": arriving,
        "streams_expected": expected,
    }


# Rolling history of how big the recording directory is, used to derive the
# write rate from what is actually landing on disk rather than from a nominal
# bitrate — a stream that stopped arriving writes nothing, and the estimate
# should reflect that.
_RATE_WINDOW = 60.0
_size_history: "deque[tuple[float, int]]" = deque(maxlen=64)
_size_cache: dict = {"at": 0.0, "value": 0}


def _directory_size(path: Path) -> int:
    """Cached briefly: walking a recording tree on every request would become
    its own load once there are thousands of segments."""
    now = time.monotonic()
    if now - _size_cache["at"] < 3:
        return _size_cache["value"]
    total = 0
    try:
        for entry in path.rglob("*"):
            if entry.is_file():
                total += entry.stat().st_size
    except OSError:
        pass
    _size_cache.update(at=now, value=total)
    return total


# ─── Machine load ─────────────────────────────────────────────────────────────
#
# Without this the status page can only say what the node is *supposed* to be
# doing. A node that is quietly running out of CPU still reports four streams
# arriving right up until it drops one.

_cpu_previous: Optional[tuple[int, int]] = None


def _cpu_percent() -> Optional[float]:
    """System-wide CPU use since the previous call."""
    global _cpu_previous

    # Linux — the deployment target — has this exactly.
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        values = [int(x) for x in parts[1:]]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        total = sum(values)
        if _cpu_previous is not None:
            prev_idle, prev_total = _cpu_previous
            d_total = total - prev_total
            d_idle = idle - prev_idle
            _cpu_previous = (idle, total)
            if d_total > 0:
                return round(100.0 * (d_total - d_idle) / d_total, 1)
        _cpu_previous = (idle, total)
        return None
    except OSError:
        pass

    # macOS and anything else: sum what the processes report.
    try:
        out = subprocess.run(["ps", "-A", "-o", "%cpu="],
                             capture_output=True, text=True, timeout=3).stdout
        total = sum(float(line) for line in out.splitlines() if line.strip())
        cores = os.cpu_count() or 1
        return round(min(total / cores, 100.0), 1)
    except Exception:
        return None


def _memory() -> dict:
    try:
        info = {}
        with open("/proc/meminfo") as f:
            for line in f:
                key, _, rest = line.partition(":")
                info[key] = int(rest.split()[0]) * 1024
        total = info.get("MemTotal", 0)
        available = info.get("MemAvailable", info.get("MemFree", 0))
        return {"total_bytes": total, "available_bytes": available,
                "used_percent": round(100.0 * (total - available) / total, 1) if total else None}
    except OSError:
        return {"total_bytes": None, "available_bytes": None, "used_percent": None}


def machine_status() -> dict:
    try:
        load1, load5, load15 = os.getloadavg()
    except (OSError, AttributeError):
        load1 = load5 = load15 = None

    cores = os.cpu_count() or 1
    return {
        "cpu_percent": _cpu_percent(),
        "cores": cores,
        # Load above the core count means work is queueing, whatever the CPU
        # percentage says — on a two-core node that threshold is 2.0.
        "load_average": [load1, load5, load15],
        "load_per_core": round(load1 / cores, 2) if load1 is not None else None,
        "memory": _memory(),
        "platform": platform.system(),
    }


# ─── Recording disks ──────────────────────────────────────────────────────────
#
# Several USB-C disks are pooled into one recording directory. Each stays its own
# filesystem, so any of them can be unplugged and carried away with whole files
# on it; when one runs low, new segments land on the next. Segments are ~3 GB, so
# the changeover always falls on a file boundary.
#
# The agent is unprivileged. Mounting goes through one narrow helper, which is
# the only privileged operation on the node.

MOUNT_HELPER = "/opt/orah/mount-disk.sh"


def list_disks() -> list[dict]:
    if not Path(MOUNT_HELPER).exists():
        return []
    try:
        out = subprocess.run(["sudo", "-n", MOUNT_HELPER, "list"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode != 0:
            return []
        import json
        return json.loads(out.stdout or "[]")
    except Exception as e:
        print(f"[disks] could not list: {e}")
        return []


def mount_disk(uuid: str) -> tuple[bool, str]:
    try:
        out = subprocess.run(["sudo", "-n", MOUNT_HELPER, "mount", uuid],
                             capture_output=True, text=True, timeout=30)
        return out.returncode == 0, (out.stdout or out.stderr).strip()
    except Exception as e:
        return False, str(e)


def eject_disk(uuid: str) -> tuple[bool, str]:
    try:
        out = subprocess.run(["sudo", "-n", MOUNT_HELPER, "eject", uuid],
                             capture_output=True, text=True, timeout=30)
        return out.returncode == 0, (out.stdout or out.stderr).strip()
    except Exception as e:
        return False, str(e)


# ─── Bonjour ──────────────────────────────────────────────────────────────────

_zeroconf = None
_service_info = None


async def announce() -> None:
    """Advertise this node so the Mac finds it without anyone typing an address.

    Uses the async API deliberately. The synchronous `Zeroconf.register_service`
    drives its own event loop and, called from inside a running one, deadlocks
    until it gives up with EventLoopBlocked — which is exactly what happened the
    first time this ran under the FastAPI lifespan.
    """
    global _zeroconf, _service_info
    if args.no_announce:
        return
    try:
        from zeroconf import ServiceInfo
        from zeroconf.asyncio import AsyncZeroconf
    except ImportError:
        print("[mdns] zeroconf not installed — not announcing (pip install zeroconf)")
        return

    hostname = socket.gethostname().split(".")[0]
    try:
        address = socket.inet_aton(_primary_address())
    except OSError:
        print("[mdns] could not determine a local address — not announcing")
        return

    _service_info = ServiceInfo(
        SERVICE_TYPE,
        f"orah-node-{args.node_id:02d}.{SERVICE_TYPE}",
        addresses=[address],
        port=args.port,
        properties={
            "node": str(args.node_id),
            "host": hostname,
            "cameras": ",".join(str(c) for c in cameras),
            "proxy": "yes" if ENCODER else "no",
            "encoder": ENCODER.name if ENCODER else "none",
        },
        server=f"{hostname}.local.",
    )
    _zeroconf = AsyncZeroconf()
    await _zeroconf.async_register_service(_service_info)
    print(f"[mdns] announced as orah-node-{args.node_id:02d} on {SERVICE_TYPE}")


def _primary_address() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))   # no packet is sent; picks the default route
        return sock.getsockname()[0]
    finally:
        sock.close()


async def withdraw() -> None:
    if _zeroconf and _service_info:
        with contextlib.suppress(Exception):
            await _zeroconf.async_unregister_service(_service_info)
            await _zeroconf.async_close()


# ─── Supervision ──────────────────────────────────────────────────────────────

async def supervise() -> None:
    """Keeps proxy transcodes alive. Recording needs no supervision — MediaMTX
    owns it, and a stream that stops arriving is a camera problem, not a process
    that needs restarting."""
    while True:
        await asyncio.sleep(5)
        for slot, job in list(proxies.items()):
            if not job.alive:
                proxies.pop(slot, None)
                start_proxy(slot)


# ─── API ──────────────────────────────────────────────────────────────────────

class CameraCmd(BaseModel):
    camera_id: int


class AssignCmd(BaseModel):
    cameras: list[int]


class LensCmd(BaseModel):
    lens: str


class DiskCmd(BaseModel):
    uuid: str


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    global ENCODER
    ENCODER = detect_encoder()
    await announce()

    print(f"╭─ Orah node {args.node_id:02d}")
    print(f"│  cameras   {cameras or 'none yet — awaiting assignment'}")
    print(f"│  record    {RECORD_DIR}")
    print(f"│  source    {args.mediamtx}")
    print(f"│  proxy     {ENCODER.name if ENCODER else 'DEGRADED — no hardware encoder'}")
    print(f"╰─ api on :{args.port}")

    # Same at startup: whatever this node owns, it starts proxying.
    for slot in cameras:
        start_proxy(slot)

    task = asyncio.create_task(supervise())
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        for slot in list(proxies):
            stop_proxy(slot)
        await withdraw()
        print("stopped cleanly")


app = FastAPI(title=f"Orah node {args.node_id}", lifespan=lifespan)


@app.get("/health")
def health():
    return {
        "ok": True,
        "node_id": args.node_id,
        "platform": platform.system(),
        "cameras": cameras,
        "proxy_available": ENCODER is not None,
        "encoder": ENCODER.name if ENCODER else None,
        "degraded": ENCODER is None,
    }


@app.get("/status")
def status():
    return {
        "node_id": args.node_id,
        "cameras": cameras,
        "recording": recording_state(),
        "proxy": {
            "available": ENCODER is not None,
            "encoder": ENCODER.name if ENCODER else None,
            "lens": proxy_lens,
            "running": [s for s, j in proxies.items() if j.alive],
        },
        "disk": disk_status(),
        "machine": machine_status(),
        "disks": list_disks(),
    }


@app.post("/cameras")
def assign(cmd: AssignCmd):
    """The Mac decides which cameras live here; the agent is told, not configured.

    Previously this was fixed by a command-line flag at launch, so a camera the
    Mac assigned later was rejected outright.
    """
    global cameras
    removed = [s for s in cameras if s not in cmd.cameras]
    for slot in removed:
        stop_proxy(slot)
    cameras = sorted(set(cmd.cameras))
    print(f"[assign] cameras now {cameras}")

    # A node that owns cameras serves proxies for them. Waiting to be told would
    # only mean a multiview with holes in it after every restart.
    started = [slot for slot in cameras if start_proxy(slot)]
    return {"cameras": cameras, "removed": removed, "proxy_started": started}


@app.get("/recording")
def recording():
    """What is actually being written, straight from MediaMTX."""
    arriving, expected = recording_summary()
    return {
        "streams_arriving": arriving,
        "streams_expected": expected,
        "detail": recording_state(),
    }


@app.get("/disks")
def disks():
    """Every disk the node can see, and whether it is part of the pool."""
    return {"pool": str(RECORD_DIR), "disks": list_disks()}


@app.post("/disks/mount")
def disks_mount(cmd: DiskCmd):
    """Add a disk to the recording pool, live.

    Recording is not interrupted: the branch is appended to the running pool, so
    a disk can be plugged in mid-show and start taking segments immediately.
    """
    ok, detail = mount_disk(cmd.uuid)
    if not ok:
        raise HTTPException(500, detail or "mount failed")
    print(f"[disks] mounted {cmd.uuid}: {detail}")
    return {"mounted": cmd.uuid, "detail": detail}


@app.post("/disks/eject")
def disks_eject(cmd: DiskCmd):
    """Take a disk out of the pool and unmount it, so it can be unplugged.

    Refuses while a file is still being written to it — pulling a disk mid-write
    is how a recording gets truncated.
    """
    ok, detail = eject_disk(cmd.uuid)
    if not ok:
        raise HTTPException(409, detail or "still busy")
    print(f"[disks] ejected {cmd.uuid}")
    return {"ejected": cmd.uuid, "detail": detail}


@app.post("/proxy/start")
def proxy_start():
    if ENCODER is None:
        raise HTTPException(409, "no hardware encoder; proxy is disabled by design")
    return {"started": [s for s in cameras if start_proxy(s)]}


@app.post("/proxy/stop")
def proxy_stop():
    return {"stopped": [s for s in list(proxies) if stop_proxy(s)]}


@app.post("/proxy/lens")
def proxy_set_lens(cmd: LensCmd):
    """Switch which lens the multiview shows. Costs a restart of the transcodes,
    hence roughly a second before pictures return."""
    global proxy_lens
    if cmd.lens not in LENSES:
        raise HTTPException(400, f"lens must be one of {LENSES}")
    proxy_lens = cmd.lens
    restart_all_proxies()
    return {"lens": proxy_lens}


# ─── Status display ───────────────────────────────────────────────────────────
#
# Served by the node itself, so it works from the Mac, from a phone, or from a
# monitor plugged into the node — without installing anything anywhere. The page
# is static and pulls /status; there is no templating to drift out of step with
# the API.

STATUS_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Orah node</title>
<style>
:root{
      /* Greys, one amber, one red — matching the fleet view:
           YR07 Cadmium Orange #F8980A   accent, warnings
           Y17  Golden Yellow  #FED040   emphasised values
           (no green here: green means "next" on the desk and nowhere else)
           R29  Lipstick Red   #D81030   fault, REC                          */
      --bg:#0C0C0C;--panel:#161615;--raised:#1F1F1E;--line:#2E2E2C;
      --am:#F8980A;--hi:#FED040;--ok:#F8980A;--live:#D81030;
      --fg:#D8D6D0;--dim:#8E8C86;--faint:#5E5C57;--dead:#333331;
      --sans:"Helvetica Neue",Helvetica,Roboto,-apple-system,"Segoe UI",Arial,sans-serif;
      --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-family:var(--sans);
     font-size:14px;padding:18px;-webkit-font-smoothing:antialiased}
/* Numbers keep a fixed advance so they do not shuffle on every refresh. */
.big,.val,.ds,.db{font-variant-numeric:tabular-nums}
h1{margin:0 0 4px;font-size:20px;color:var(--am);letter-spacing:.06em}
.sub{color:var(--dim);font-size:12px;margin-bottom:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px}
.card h2{margin:0 0 8px;font-size:11px;letter-spacing:.14em;color:var(--faint);
         text-transform:uppercase;font-weight:600}
.big{font-size:26px;color:var(--fg)}
.big.warn{color:var(--hi)}
.big.bad{color:var(--live)}
.row{display:flex;justify-content:space-between;padding:3px 0;font-size:12px}
.row span:last-child{color:var(--fg)}
.row span:first-child{color:var(--dim)}
.cam{margin-top:10px}
.cam .name{font-size:12px;color:var(--fg);margin-bottom:4px}
.cells{display:flex;gap:4px}
.cell{flex:1;text-align:center;padding:5px 0;border-radius:3px;font-size:10px;
      border:1px solid var(--line);background:var(--raised);color:var(--faint)}
/* A stream that is arriving is violet, matching the fleet view. Red is kept for
   what is wrong; painting every healthy stream red makes a working node look
   like an emergency and leaves a real fault nowhere to show. */
.cell.on{background:var(--ok);border-color:var(--ok);color:#1A1200}
.bar{height:4px;background:var(--line);border-radius:2px;margin-top:6px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ok)}
.bar i.low{background:var(--live)}
.stale{opacity:.45}
footer{margin-top:16px;color:var(--faint);font-size:11px}
.disk{display:flex;align-items:center;gap:8px;padding:6px 0;border-top:1px solid var(--line)}
.disk:first-of-type{border-top:none}
.disk .dn{font-size:12px;color:var(--fg);flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis}
.disk .ds{font-size:11px;color:var(--dim);white-space:nowrap}
.disk.on .dn{color:var(--am)}
.btn{font-family:var(--sans);font-size:10px;font-weight:600;letter-spacing:.06em;padding:5px 9px;
     border-radius:3px;border:1px solid var(--am);background:transparent;
     color:var(--am);cursor:pointer}
.btn:hover{background:rgba(248,152,10,.16)}
.btn.out{border-color:var(--line);color:var(--dim)}
</style></head><body>
<h1 id="title">Orah node</h1>
<div class="sub" id="sub">connecting…</div>
<div class="grid" id="grid"></div>
<footer id="foot"></footer>
<script>
function fmtBytes(b){ if(!b) return "0 B";
  const u=["B","KB","MB","GB","TB"]; let i=0; while(b>=1024&&i<u.length-1){b/=1024;i++;}
  return b.toFixed(i?1:0)+" "+u[i]; }
function disksCard(disks){
  if(!disks.length) return '<div class="card"><h2>Disks</h2>'
    +'<div class="row"><span>none detected</span><span>—</span></div></div>';
  let rows = "";
  for(const k of disks){
    const name = k.label || k.device;
    const free = k.free_bytes ? fmtBytes(k.free_bytes)+" free" : "not mounted";
    // Buttons carry the uuid in a data attribute rather than an inline handler:
    // building JS string literals inside an HTML attribute inside a Python
    // string is three layers of quoting and it broke exactly as you would expect.
    const act = k.in_pool ? "eject" : "mount";
    const cls = k.in_pool ? "btn out" : "btn";
    rows += '<div class="disk'+(k.in_pool?" on":"")+'">'
          + '<div class="dn">'+name+'</div>'
          + '<div class="ds">'+k.size+' \u00b7 '+free+'</div>'
          + '<button class="'+cls+'" data-act="'+act+'" data-uuid="'+k.uuid+'">'
          + act.toUpperCase()+'</button></div>';
  }
  return '<div class="card"><h2>Disks</h2>'+rows
    +'<div class="row"><span>pooled disks take segments in turn</span><span></span></div></div>';
}

document.addEventListener("click", async (e) => {
  const b = e.target.closest("button[data-uuid]");
  if(!b) return;
  const uuid = b.dataset.uuid, act = b.dataset.act;
  b.disabled = true;
  const r = await fetch("/disks/"+act, {
    method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({uuid})
  }).catch(()=>null);
  if(act==="eject" && r && !r.ok)
    alert("Still writing to that disk. Try again in a moment.");
  b.disabled = false;
  tick();
});

function fmtTime(s){ if(s==null) return "—";
  const h=Math.floor(s/3600), m=Math.floor((s%3600)/60);
  return h>0 ? h+" h "+m+" min" : m+" min"; }

async function tick(){
  let d;
  try { d = await (await fetch("/status",{cache:"no-store"})).json(); }
  catch(e){ document.body.classList.add("stale");
            document.getElementById("sub").textContent="no answer from agent";
            return; }
  document.body.classList.remove("stale");

  document.getElementById("title").textContent = "Node " + String(d.node_id).padStart(2,"0");
  const rec = d.disk.streams_arriving, exp = d.disk.streams_expected;
  document.getElementById("sub").textContent =
    d.cameras.length + " camera(s) assigned · " + location.host;

  // Amber for an incomplete set, not red: red is reserved for what is live.
  const verdictClass = exp===0 ? "" : (rec===exp ? "" : "warn");
  let cams = "";
  for (const [cam, lenses] of Object.entries(d.recording||{})) {
    let cells = "";
    for (const [lens, v] of Object.entries(lenses))
      cells += '<div class="cell'+(v.recording?" on":"")+'">'+lens+'</div>';
    cams += '<div class="cam"><div class="name">'+cam+'</div><div class="cells">'+cells+'</div></div>';
  }

  const used = d.disk.total_bytes ? 1-(d.disk.free_bytes/d.disk.total_bytes) : 0;
  const low = d.disk.seconds_remaining!=null && d.disk.seconds_remaining < 3600;

  const m = d.machine || {};
  const cpu = m.cpu_percent;
  const lpc = m.load_per_core;
  // Load per core above 1 means work is queueing regardless of what the CPU
  // percentage says — the number that actually predicts dropped streams.
  const cpuClass = (lpc!=null && lpc>1.5) || (cpu!=null && cpu>90) ? "bad"
                 : (lpc!=null && lpc>0.9) || (cpu!=null && cpu>75) ? "warn" : "";
  const mem = (m.memory||{}).used_percent;

  document.getElementById("grid").innerHTML =
    '<div class="card"><h2>Recording</h2>'
      +'<div class="big '+verdictClass+'">'+rec+' / '+exp+'</div>'
      // Say it in words. "3 / 4" and "4 / 4" look far too alike at a glance,
      // and a missing stream is exactly the thing that must not be missed.
      +'<div class="row"><span>streams arriving</span><span>'
        +(exp===0 ? "—" : rec===exp ? "all" : (exp-rec)+" MISSING")+'</span></div>'
      + cams + '</div>'
    +'<div class="card"><h2>Disk</h2>'
      +'<div class="big '+(low?"bad":"")+'">'+fmtTime(d.disk.seconds_remaining)+'</div>'
      +'<div class="row"><span>remaining</span><span>'+fmtBytes(d.disk.free_bytes)+' free</span></div>'
      +'<div class="row"><span>writing</span><span>'+fmtBytes(d.disk.write_bytes_per_second)+'/s</span></div>'
      +'<div class="row"><span>recorded</span><span>'+fmtBytes(d.disk.recorded_bytes)+'</span></div>'
      +'<div class="bar"><i class="'+(low?"low":"")+'" style="width:'+(used*100).toFixed(0)+'%"></i></div>'
      +'<div class="row"><span>path</span><span>'+d.disk.path+'</span></div></div>'
    +'<div class="card"><h2>Proxy</h2>'
      +'<div class="big '+(d.proxy.available?"":"bad")+'">'+(d.proxy.available?d.proxy.running.length:"off")+'</div>'
      +'<div class="row"><span>encoder</span><span>'+(d.proxy.encoder||"none — degraded")+'</span></div>'
      +'<div class="row"><span>lens shown</span><span>'+d.proxy.lens+'</span></div></div>'
    +'<div class="card"><h2>Machine</h2>'
      +'<div class="big '+cpuClass+'">'+(cpu!=null?cpu.toFixed(0)+'%':'—')+'</div>'
      +'<div class="row"><span>cpu</span><span>'+(m.cores||'?')+' cores</span></div>'
      +'<div class="bar"><i class="'+(cpuClass==="bad"?"low":"")+'" style="width:'+(cpu||0)+'%"></i></div>'
      +'<div class="row"><span>load per core</span><span>'+(lpc!=null?lpc.toFixed(2):'—')+'</span></div>'
      +'<div class="row"><span>load 1/5/15</span><span>'
        +(m.load_average||[]).map(v=>v==null?'—':v.toFixed(2)).join(' ')+'</span></div>'
      +'<div class="row"><span>memory used</span><span>'+(mem!=null?mem.toFixed(0)+'%':'—')+'</span></div>'
      +'</div>'
    + disksCard(d.disks||[]);

  document.getElementById("foot").textContent =
    "updated " + new Date().toLocaleTimeString();
}
tick(); setInterval(tick, 2000);
</script></body></html>"""


@app.get("/", response_class=HTMLResponse)
def status_page():
    """Live status, readable from anywhere on the network."""
    return STATUS_HTML


@app.get("/status.txt", response_class=PlainTextResponse)
def status_text():
    """The same thing for a terminal — what shows on a monitor plugged into the
    node, where there is no browser."""
    disk = disk_status()
    machine = machine_status()
    arriving, expected = recording_summary()
    lines = [
        f"ORAH NODE {args.node_id:02d}   {socket.gethostname()}",
        "=" * 52,
        f"recording   {arriving}/{expected} streams",
        f"cameras     {cameras or 'none assigned'}",
        f"disk        {disk['free_bytes'] / 1e9:.1f} GB free",
        f"remaining   {(disk['seconds_remaining'] or 0) / 3600:.1f} h"
        if disk["seconds_remaining"] else "remaining   —",
        f"writing     {disk['write_bytes_per_second'] / 1e6:.1f} MB/s",
        f"proxy       {ENCODER.name if ENCODER else 'DEGRADED — no hardware encoder'}",
        f"cpu         {machine['cpu_percent'] if machine['cpu_percent'] is not None else '—'}%"
        f"   load/core {machine['load_per_core'] if machine['load_per_core'] is not None else '—'}"
        f"   mem {machine['memory']['used_percent'] if machine['memory']['used_percent'] is not None else '—'}%",
        "",
    ]
    for cam, lenses in recording_state().items():
        marks = "  ".join(f"{lens}:{'REC' if v['recording'] else ' - '}"
                          for lens, v in lenses.items())
        lines.append(f"  {cam}   {marks}")
    return "\n".join(lines)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")
