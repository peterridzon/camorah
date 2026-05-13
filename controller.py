"""
controller.py — bezi na Mac M4
Centralna logika:
  - Zeroconf discovery Orah kamier
  - Camorah: start/stop streaming (kamera → Mac MediaMTX)
  - OBS WebSocket: prepinanie scen na 4x OBS instanciach (localhost)
  - Intel PC nodes: start/stop recording cez HTTP API
  - MIDI: fyzicky pult → prepinanie kamier
"""

import asyncio
import threading
import socket
import httpx
from dataclasses import dataclass, field
from typing import Callable, Optional
from zeroconf import ServiceBrowser, ServiceStateChange, Zeroconf

# ─── Konfigurácia ─────────────────────────────────────────────────────────────
# Načítava sa z config.json — žiadne hardcoded hodnoty

import json
from pathlib import Path

_CFG_PATH = Path(__file__).parent / "config.json"

def load_config() -> dict:
    if _CFG_PATH.exists():
        with open(_CFG_PATH) as f:
            return json.load(f)
    # Defaultný config ak súbor neexistuje
    default = {
        "mac_mediamtx_ip":   "127.0.0.1",
        "mac_mediamtx_port": 1935,
        "obs_instances": [
            {"id": 1, "port": 4455, "stream": "0_0"},
            {"id": 2, "port": 4456, "stream": "0_1"},
            {"id": 3, "port": 4457, "stream": "1_0"},
            {"id": 4, "port": 4458, "stream": "1_1"},
        ],
        # Nodes sa pridávajú dynamicky cez UI — tu je prázdny zoznam
        "intel_nodes": []
    }
    save_config(default)
    return default

def save_config(cfg: dict):
    with open(_CFG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)

CFG = load_config()

MAC_MEDIAMTX_IP   = CFG["mac_mediamtx_ip"]
MAC_MEDIAMTX_PORT = CFG["mac_mediamtx_port"]
OBS_INSTANCES     = CFG["obs_instances"]
INTEL_NODES_CFG   = CFG["intel_nodes"]

CAMERA_SERVICE = "_vscamera._tcp.local."
STREAMS        = ["0_0", "0_1", "1_0", "1_1"]

# ─── Datové triedy ────────────────────────────────────────────────────────────

@dataclass
class Camera:
    id:        int
    ip:        str
    port:      int
    name:      str      = ""
    streaming: bool     = False
    node_id:   int      = 0

@dataclass
class IntelNode:
    id:       int
    ip:       str
    port:     int
    cameras:  list
    online:   bool = False
    recording_count: int = 0

# ─── Hlavný Controller ────────────────────────────────────────────────────────

class OrahController:

    def __init__(
        self,
        on_camera_discovered: Callable = None,
        on_status_update:     Callable = None,
    ):
        self.cameras:        dict[int, Camera]    = {}
        self.nodes:          dict[int, IntelNode] = {}
        self.active_cam_id:  int                  = 0
        self._ws_connections = {}
        self._cam_counter    = 0

        self.on_camera_discovered = on_camera_discovered
        self.on_status_update     = on_status_update

        # Init Intel nodes
        for n in INTEL_NODES:
            self.nodes[n["id"]] = IntelNode(
                id=n["id"], ip=n["ip"],
                port=n["port"], cameras=n["cameras"]
            )

    # ── Zeroconf — discovery kamier ───────────────────────────────────────────

    def start_discovery(self):
        self._zeroconf = Zeroconf()
        self._browser  = ServiceBrowser(
            self._zeroconf, CAMERA_SERVICE,
            handlers=[self._on_service_change]
        )
        print("Hladam Orah kamery v sieti...")

    def _on_service_change(self, zeroconf, service_type, name, state_change):
        if state_change is not ServiceStateChange.Added:
            return

        info = zeroconf.get_service_info(service_type, name)
        if not info:
            return

        ip   = socket.inet_ntoa(info.address)
        port = info.port

        self._cam_counter += 1
        cam_id  = self._cam_counter
        node_id = self._node_for_camera(cam_id)

        cam = Camera(id=cam_id, ip=ip, port=port,
                     name=name, node_id=node_id)
        self.cameras[cam_id] = cam

        print(f"[CAM] Najdena cam{cam_id:02d} → {ip}:{port}  node={node_id}")

        if self.on_camera_discovered:
            self.on_camera_discovered(cam)

    def _node_for_camera(self, cam_id: int) -> int:
        """
        Najdi node pre kameru.
        1. Ak je kamera uz pridelena nejakemu node (z config.json) → pouzij ho
        2. Inak auto-assign: pridelit node s najmenšim poctom kamier
           (rovnomerne rozdelenie bez hardcoded rozsahov)
        """
        # Skontroluj ci je uz pridelena
        for node in self.nodes.values():
            if cam_id in node.cameras:
                return node.id

        # Auto-assign na node s najmenej kamerami
        if not self.nodes:
            return 0

        target = min(self.nodes.values(), key=lambda n: len(n.cameras))
        target.cameras.append(cam_id)
        target.cameras.sort()

        # Uloz do config.json aby sa zachovalo pri reštarte
        self._persist_node_cameras()
        return target.id

    def _persist_node_cameras(self):
        """Uloz aktualne pridelenie kamier do config.json"""
        cfg = load_config()
        for node in self.nodes.values():
            for n in cfg["intel_nodes"]:
                if n["id"] == node.id:
                    n["cameras"] = node.cameras
        save_config(cfg)

    def add_node(self, ip: str, port: int = 8000) -> IntelNode:
        """
        Pridaj novy Intel PC node za behu (cez UI Settings).
        node_id = auto-increment
        """
        new_id = max(self.nodes.keys(), default=0) + 1
        node   = IntelNode(id=new_id, ip=ip, port=port, cameras=[])
        self.nodes[new_id] = node

        # Uloz do config.json
        cfg = load_config()
        cfg["intel_nodes"].append({
            "id": new_id, "ip": ip, "port": port, "cameras": []
        })
        save_config(cfg)
        print(f"[NODE] Pridany node {new_id} → {ip}:{port}")
        return node

    def remove_node(self, node_id: int):
        """Odstran node (kamery sa redistribuuju pri dalsom reštarte)"""
        self.nodes.pop(node_id, None)
        cfg = load_config()
        cfg["intel_nodes"] = [n for n in cfg["intel_nodes"] if n["id"] != node_id]
        save_config(cfg)
        print(f"[NODE] Odstraneny node {node_id}")

    # ── Kamera — start/stop streaming → Mac MediaMTX ─────────────────────────

    def start_camera(self, cam_id: int):
        """Spusti Orah kameru — bude streamovat na Mac MediaMTX"""
        cam = self.cameras.get(cam_id)
        if not cam or cam.streaming:
            return

        # RTMP URL na Mac MediaMTX — kamery streamuju sem
        rtmp_url = f"rtmp://{MAC_MEDIAMTX_IP}:{MAC_MEDIAMTX_PORT}/"

        # Pouzij Camorah WSocket na start kamery
        try:
            import sys
            sys.path.insert(0, ".")
            import wsock
            import config as cam_config

            cam_config.STREAM_URL = rtmp_url

            ws = wsock.WSocket()
            ws_url = f"ws://{cam.ip}:{cam.port}/control"
            ws.connect(ws_url, cam.ip, cam.port)
            self._ws_connections[cam_id] = ws

            cam.streaming = True
            print(f"[CAM] cam{cam_id:02d} streaming → {rtmp_url}")

        except Exception as e:
            print(f"[CAM] Chyba start cam{cam_id:02d}: {e}")

    def stop_camera(self, cam_id: int):
        ws = self._ws_connections.pop(cam_id, None)
        if ws:
            try:
                ws.stop()
            except Exception:
                pass
        cam = self.cameras.get(cam_id)
        if cam:
            cam.streaming = False
            print(f"[CAM] cam{cam_id:02d} stopped")

    def start_all_cameras(self):
        for cam_id in self.cameras:
            self.start_camera(cam_id)

    def stop_all_cameras(self):
        for cam_id in list(self._ws_connections.keys()):
            self.stop_camera(cam_id)

    # ── OBS — prepínanie scén (localhost) ─────────────────────────────────────

    async def switch_obs_to_camera(self, cam_id: int):
        """
        Prepne vsetky 4 OBS instancie na scenar danej kamery.
        OBS musi mat scenare pomenovat: cam01, cam02 ... cam22
        Kazda scena ma Media Source: rtmp://127.0.0.1:1935/camXX/stream
        """
        if cam_id == self.active_cam_id:
            return

        cam = self.cameras.get(cam_id)
        if not cam or not cam.streaming:
            print(f"[OBS] Kamera {cam_id} nie je streaming")
            return

        scene_name = f"cam{cam_id:02d}"
        switched   = []

        try:
            import obsws_python as obs

            for instance in OBS_INSTANCES:
                try:
                    cl = obs.ReqClient(
                        host="localhost",
                        port=instance["port"],
                        password="",     # nastav ak mas heslo v OBS
                        timeout=3
                    )
                    cl.set_current_program_scene(scene_name)
                    cl.disconnect()
                    switched.append(instance["id"])
                except Exception as e:
                    print(f"[OBS] Instance {instance['id']} port {instance['port']}: {e}")

        except ImportError:
            print("[OBS] obsws_python nie je nainstalovane: pip install obsws-python")

        if switched:
            self.active_cam_id = cam_id
            print(f"[OBS] Prepnute na cam{cam_id:02d} — OBS instances: {switched}")

            if self.on_status_update:
                self.on_status_update()

        return switched

    # ── Intel PC nodes — recording ────────────────────────────────────────────

    async def start_all_recording(self):
        """
        Spusti recording na vsetkych Intel PC nodes.
        Nezavisle od OBS — bezi vzdy kym su kamery streaming.
        """
        async with httpx.AsyncClient() as client:
            for node in self.nodes.values():
                try:
                    r = await client.post(
                        f"http://{node.ip}:{node.port}/record/start/all",
                        timeout=5
                    )
                    node.online = True
                    print(f"[REC] Node {node.id} recording started")
                except Exception as e:
                    node.online = False
                    print(f"[REC] Node {node.id} nedostupny: {e}")

    async def stop_all_recording(self):
        async with httpx.AsyncClient() as client:
            for node in self.nodes.values():
                try:
                    await client.post(
                        f"http://{node.ip}:{node.port}/record/stop/all",
                        timeout=5
                    )
                    print(f"[REC] Node {node.id} recording stopped")
                except Exception as e:
                    print(f"[REC] Node {node.id} chyba: {e}")

    async def start_recording_camera(self, cam_id: int):
        """Spusti recording jednej kamery na prislusnom node"""
        cam = self.cameras.get(cam_id)
        if not cam:
            return
        node = self.nodes.get(cam.node_id)
        if not node:
            return
        async with httpx.AsyncClient() as client:
            try:
                await client.post(
                    f"http://{node.ip}:{node.port}/record/start",
                    json={"camera_id": cam_id},
                    timeout=5
                )
            except Exception as e:
                print(f"[REC] Chyba cam{cam_id:02d}: {e}")

    # ── Status polling ────────────────────────────────────────────────────────

    async def poll_status(self):
        """Kazdych 5s pyta status vsetkych Intel nodes"""
        async with httpx.AsyncClient() as client:
            for node in self.nodes.values():
                try:
                    r = await client.get(
                        f"http://{node.ip}:{node.port}/status",
                        timeout=3
                    )
                    data = r.json()
                    node.online          = True
                    node.recording_count = data.get("active_procs", 0)
                except Exception:
                    node.online          = False
                    node.recording_count = 0

        if self.on_status_update:
            self.on_status_update()

    # ── Pomocná metóda ────────────────────────────────────────────────────────

    def run_async(self, loop: asyncio.AbstractEventLoop, coro):
        """Spusti async coroutine z UI threadu"""
        return asyncio.run_coroutine_threadsafe(coro, loop)
