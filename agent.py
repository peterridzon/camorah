"""
agent.py — bezi na Intel PC (Linux alebo Windows)
Jedina uloha: prijat RTMP streamy z Mac MediaMTX a zapisovat na disk

Tok:
  Mac MediaMTX → [tato masina] FFmpeg streamcopy → disk

Instalacia:
  pip install fastapi uvicorn httpx
  + ffmpeg musi byt v PATH

Spustenie Linux:
  python agent.py --node-id 1 --cameras 1,2,3,4,5,6
                  --mac-ip 192.168.1.10
                  --record-dir /mnt/recordings

Spustenie Windows:
  python agent.py --node-id 1 --cameras 1,2,3,4,5,6
                  --mac-ip 192.168.1.10
                  --record-dir D:/recordings
"""

import asyncio
import subprocess
import os
import argparse
import datetime
import platform
from pathlib import Path
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn

# ─── Argumenty ────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser(description="Orah Recording Agent")
parser.add_argument("--node-id",     type=int,   default=1)
parser.add_argument("--cameras",     type=str,   default="1,2,3,4,5,6",
                    help="Zoznam kamier oddeleny ciarkou")
parser.add_argument("--mac-ip",      type=str,   default="192.168.1.10",
                    help="IP adresa Mac M4 kde bezi MediaMTX")
parser.add_argument("--mac-rtmp-port", type=int, default=1935)
parser.add_argument("--record-dir",  type=str,   default="./recordings")
parser.add_argument("--port",        type=int,   default=8000,
                    help="Port tohto API servera")
args = parser.parse_args()

CAMERAS    = [int(x.strip()) for x in args.cameras.split(",")]
RECORD_DIR = Path(args.record_dir)
MAC_IP     = args.mac_ip
MAC_PORT   = args.mac_rtmp_port
STREAMS    = ["0_0", "0_1", "1_0", "1_1"]
IS_WINDOWS = platform.system() == "Windows"

RECORD_DIR.mkdir(parents=True, exist_ok=True)

# ─── Stav ─────────────────────────────────────────────────────────────────────

# kluc: "cam07_0_0" → subprocess
recording_procs: dict[str, subprocess.Popen] = {}

app = FastAPI(title=f"Orah Recording Agent — Node {args.node_id}")

# ─── Modely ───────────────────────────────────────────────────────────────────

class CameraCmd(BaseModel):
    camera_id: int

# ─── Pomocne funkcie ──────────────────────────────────────────────────────────

def _key(cam_id: int, stream: str) -> str:
    return f"cam{cam_id:02d}_{stream}"

def _rtmp_source(cam_id: int, stream: str) -> str:
    """RTMP URL na Mac MediaMTX"""
    return f"rtmp://{MAC_IP}:{MAC_PORT}/cam{cam_id:02d}/{stream}"

def _output_path(cam_id: int, stream: str) -> Path:
    """Vystupny subor — cam07/20240315_143022_0_0.mkv"""
    now = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = RECORD_DIR / f"cam{cam_id:02d}"
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir / f"{now}_{stream}.mkv"

def _is_running(proc: subprocess.Popen) -> bool:
    return proc is not None and proc.poll() is None

def _start_ffmpeg(cam_id: int, stream: str) -> subprocess.Popen:
    """
    Spusti jeden FFmpeg proces — streamcopy, 0 CPU narok.
    MKV format je bezpecny pri nahlom vypnuti (nevyzaduje finalizaciu).
    """
    src = _rtmp_source(cam_id, stream)
    dst = str(_output_path(cam_id, stream))

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "warning",
        "-rtmp_live", "live",
        "-i", src,
        "-c", "copy",        # ZERO prekodevanie
        "-f", "matroska",    # MKV — bezpecny kontajner
        dst
    ]

    # Windows: skry konzolove okno
    kwargs = {}
    if IS_WINDOWS:
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    proc = subprocess.Popen(cmd, **kwargs)
    print(f"[REC] START cam{cam_id:02d}/{stream} → {dst}  PID={proc.pid}")
    return proc

# ─── Recording logika ─────────────────────────────────────────────────────────

def start_camera_recording(cam_id: int) -> dict:
    if cam_id not in CAMERAS:
        raise HTTPException(400, f"Kamera {cam_id} nie je na tomto node ({CAMERAS})")

    started = []
    already = []

    for stream in STREAMS:
        key = _key(cam_id, stream)
        existing = recording_procs.get(key)

        if _is_running(existing):
            already.append(stream)
            continue

        proc = _start_ffmpeg(cam_id, stream)
        recording_procs[key] = proc
        started.append(stream)

    return {
        "camera": cam_id,
        "started": started,
        "already_running": already
    }

def stop_camera_recording(cam_id: int) -> dict:
    stopped = []

    for stream in STREAMS:
        key = _key(cam_id, stream)
        proc = recording_procs.pop(key, None)

        if proc and _is_running(proc):
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            stopped.append(stream)
            print(f"[REC] STOP cam{cam_id:02d}/{stream}")

    return {"camera": cam_id, "stopped": stopped}

def start_all_recording() -> list:
    return [start_camera_recording(cam_id) for cam_id in CAMERAS]

def stop_all_recording() -> dict:
    for cam_id in list(CAMERAS):
        stop_camera_recording(cam_id)
    return {"stopped": "all", "cameras": CAMERAS}

def get_recording_status() -> dict:
    status = {}
    for cam_id in CAMERAS:
        streams = {}
        for stream in STREAMS:
            key = _key(cam_id, stream)
            proc = recording_procs.get(key)
            streams[stream] = "recording" if _is_running(proc) else "stopped"
        status[f"cam{cam_id:02d}"] = streams
    return status

# ─── API Endpoints ────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    """Zivotny signal — Mac Control App pyta kazdych 5s"""
    return {
        "ok": True,
        "node_id": args.node_id,
        "cameras": CAMERAS,
        "mac_ip": MAC_IP,
        "platform": platform.system()
    }

@app.get("/status")
def status():
    """Detailny status — ake kamery nahravaju"""
    return {
        "node_id": args.node_id,
        "cameras": CAMERAS,
        "recording": get_recording_status(),
        "active_procs": len([p for p in recording_procs.values()
                              if _is_running(p)])
    }

@app.post("/record/start/all")
def record_start_all():
    """Spusti recording vsetkych kamier na tomto node"""
    return start_all_recording()

@app.post("/record/stop/all")
def record_stop_all():
    """Zastavi vsetky recordings"""
    return stop_all_recording()

@app.post("/record/start")
def record_start(cmd: CameraCmd):
    """Spusti recording jednej kamery"""
    return start_camera_recording(cmd.camera_id)

@app.post("/record/stop")
def record_stop(cmd: CameraCmd):
    """Zastavi recording jednej kamery"""
    return stop_camera_recording(cmd.camera_id)

# ─── Startup / Shutdown ───────────────────────────────────────────────────────

@app.on_event("startup")
async def on_startup():
    print(f"╔══════════════════════════════════════╗")
    print(f"║  Orah Recording Agent — Node {args.node_id}      ║")
    print(f"║  Kamery:    {str(CAMERAS):<26}║")
    print(f"║  Mac RTMP:  {MAC_IP}:{MAC_PORT:<20}║")
    print(f"║  Rec dir:   {str(RECORD_DIR):<26}║")
    print(f"║  Platform:  {platform.system():<26}║")
    print(f"╚══════════════════════════════════════╝")

@app.on_event("shutdown")
async def on_shutdown():
    print("Zastavujem vsetky FFmpeg procesy...")
    stop_all_recording()

# ─── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")
