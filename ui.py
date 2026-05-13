"""
ui.py — Hlavna Mac Control App (CustomTkinter)
Spusti na Mac M4 ako: python ui.py

Zavislosti:
  pip install customtkinter httpx obsws-python mido python-rtmidi zeroconf
  + ffmpeg v PATH (pre pripadne lokalne testy)
  + MediaMTX bezi lokalne: ./mediamtx mediamtx.yml
"""

import customtkinter as ctk
import asyncio
import threading
from controller import OrahController, Camera
from midi_controller import MidiController

# ─── Tema ─────────────────────────────────────────────────────────────────────

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("dark-blue")

C_BG        = "#161616"
C_PANEL     = "#1e1e1e"
C_CARD      = "#252525"
C_BORDER    = "#333333"
C_CAM_OFF   = "#252525"
C_CAM_LIVE  = "#0f2a0f"    # streaming, zelena
C_CAM_SEL   = "#0f1e3a"    # aktivna v OBS, modra
C_ACCENT    = "#3b82f6"
C_GREEN     = "#22c55e"
C_RED       = "#ef4444"
C_AMBER     = "#f59e0b"
C_MUTED     = "#666666"
C_TEXT      = "#e5e5e5"

FONT_SM  = ("SF Pro Display", 11)
FONT_MD  = ("SF Pro Display", 13)
FONT_LG  = ("SF Pro Display", 15, "bold")

# ─── App ──────────────────────────────────────────────────────────────────────

class OrahApp(ctk.CTk):

    def __init__(self):
        super().__init__()
        self.title("Orah Control — M4")
        self.geometry("1440x860")
        self.configure(fg_color=C_BG)
        self.minsize(1200, 700)

        # Async event loop v separatnom threade
        self._loop = asyncio.new_event_loop()
        threading.Thread(
            target=self._loop.run_forever, daemon=True, name="AsyncLoop"
        ).start()

        # Controllers
        self._ctrl = OrahController(
            on_camera_discovered=self._on_camera_found,
            on_status_update=lambda: self.after(0, self._refresh_nodes)
        )
        self._midi = MidiController(
            on_camera_switch=self._on_midi_switch
        )

        self._recording_active = False

        self._build()
        self._start()

    # ──────────────────────────────────────────────────────────────────────────
    # UI Build
    # ──────────────────────────────────────────────────────────────────────────

    def _build(self):
        self._build_topbar()

        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        body.grid_columnconfigure(0, weight=1)
        body.grid_columnconfigure(1, weight=0)
        body.grid_rowconfigure(0, weight=1)

        left = ctk.CTkFrame(body, fg_color="transparent")
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        left.grid_rowconfigure(1, weight=1)

        right = ctk.CTkFrame(body, fg_color=C_PANEL, corner_radius=12,
                              border_width=1, border_color=C_BORDER, width=290)
        right.grid(row=0, column=1, sticky="nsew")
        right.grid_propagate(False)

        self._build_cam_grid(left)
        self._build_obs_row(left)
        self._build_sidebar(right)

    # ── Topbar ────────────────────────────────────────────────────────────────

    def _build_topbar(self):
        tb = ctk.CTkFrame(self, fg_color=C_PANEL, height=52,
                          corner_radius=0, border_width=0)
        tb.pack(fill="x")
        tb.pack_propagate(False)

        ctk.CTkLabel(tb, text="ORAH CONTROL",
                     font=ctk.CTkFont(*FONT_LG),
                     text_color=C_ACCENT).pack(side="left", padx=16)

        self._lbl_cams = ctk.CTkLabel(
            tb, text="Hľadám kamery...",
            font=ctk.CTkFont(*FONT_SM), text_color=C_MUTED)
        self._lbl_cams.pack(side="left", padx=12)

        self._lbl_active = ctk.CTkLabel(
            tb, text="",
            font=ctk.CTkFont("SF Pro Display", 13, "bold"),
            text_color=C_AMBER)
        self._lbl_active.pack(side="left", padx=12)

        self._lbl_rec = ctk.CTkLabel(
            tb, text="⏺  REC OFF",
            font=ctk.CTkFont(*FONT_SM), text_color=C_MUTED)
        self._lbl_rec.pack(side="right", padx=16)

        self._lbl_midi_tb = ctk.CTkLabel(
            tb, text="MIDI —",
            font=ctk.CTkFont(*FONT_SM), text_color=C_MUTED)
        self._lbl_midi_tb.pack(side="right", padx=12)

    # ── Camera grid ───────────────────────────────────────────────────────────

    def _build_cam_grid(self, parent):
        wrap = ctk.CTkFrame(parent, fg_color=C_PANEL, corner_radius=10,
                            border_width=1, border_color=C_BORDER)
        wrap.grid(row=0, column=0, sticky="ew", pady=(0, 10))

        ctk.CTkLabel(wrap, text="KAMERY  —  klik alebo MIDI tlačidlo = prepnúť všetky 4 OBS",
                     font=ctk.CTkFont(*FONT_SM),
                     text_color=C_MUTED).pack(anchor="w", padx=14, pady=(10, 6))

        grid = ctk.CTkFrame(wrap, fg_color="transparent")
        grid.pack(fill="x", padx=14, pady=(0, 14))

        self._cam_btns: dict[int, ctk.CTkButton] = {}

        for i in range(1, 23):
            col = (i - 1) % 11
            row = (i - 1) // 11
            btn = ctk.CTkButton(
                grid, text=f"CAM\n{i:02d}",
                width=78, height=64,
                font=ctk.CTkFont(*FONT_SM),
                fg_color=C_CAM_OFF,
                hover_color="#2a2a2a",
                border_color=C_BORDER,
                border_width=1,
                corner_radius=8,
                command=lambda cid=i: self._cam_click(cid)
            )
            btn.grid(row=row, column=col, padx=3, pady=3)
            self._cam_btns[i] = btn

    # ── OBS row ───────────────────────────────────────────────────────────────

    def _build_obs_row(self, parent):
        wrap = ctk.CTkFrame(parent, fg_color=C_PANEL, corner_radius=10,
                            border_width=1, border_color=C_BORDER)
        wrap.grid(row=1, column=0, sticky="nsew")

        ctk.CTkLabel(wrap, text="OBS INŠTANCIE (Mac M4 localhost)  →  VAHANA VR",
                     font=ctk.CTkFont(*FONT_SM),
                     text_color=C_MUTED).pack(anchor="w", padx=14, pady=(10, 6))

        row = ctk.CTkFrame(wrap, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(0, 14))
        row.grid_columnconfigure((0, 1, 2, 3), weight=1)

        self._obs_cards = []
        streams = ["0_0", "0_1", "1_0", "1_1"]

        for i, st in enumerate(streams):
            card = ctk.CTkFrame(row, fg_color=C_CARD, corner_radius=8,
                                border_width=1, border_color=C_BORDER)
            card.grid(row=0, column=i, padx=4, sticky="nsew")

            hdr = ctk.CTkFrame(card, fg_color="transparent")
            hdr.pack(fill="x", padx=10, pady=(8, 0))

            ctk.CTkLabel(hdr, text=f"OBS {i+1}",
                         font=ctk.CTkFont("SF Pro Display", 12, "bold"),
                         text_color=C_TEXT).pack(side="left")

            lbl_status = ctk.CTkLabel(hdr, text="●",
                                       font=ctk.CTkFont(*FONT_SM),
                                       text_color=C_MUTED)
            lbl_status.pack(side="right")

            lbl_cam = ctk.CTkLabel(card, text="—",
                                    font=ctk.CTkFont(*FONT_SM),
                                    text_color=C_MUTED)
            lbl_cam.pack(anchor="w", padx=10, pady=(2, 0))

            preview = ctk.CTkFrame(card, fg_color="#0a0a0a",
                                    height=80, corner_radius=4)
            preview.pack(fill="x", padx=10, pady=6)
            preview.pack_propagate(False)

            lbl_prev = ctk.CTkLabel(preview,
                                     text=f"stream {st}\nws://localhost:{4455+i}",
                                     font=ctk.CTkFont(*FONT_SM),
                                     text_color=C_MUTED,
                                     justify="center")
            lbl_prev.place(relx=0.5, rely=0.5, anchor="center")

            self._obs_cards.append({
                "frame": card, "lbl_cam": lbl_cam,
                "lbl_status": lbl_status, "lbl_prev": lbl_prev,
                "stream": st, "port": 4455 + i
            })

    # ── Sidebar ───────────────────────────────────────────────────────────────

    def _build_sidebar(self, parent):

        def section(title):
            f = ctk.CTkFrame(parent, fg_color="transparent")
            f.pack(fill="x", padx=14, pady=(14, 0))
            ctk.CTkLabel(f, text=title,
                         font=ctk.CTkFont(*FONT_SM),
                         text_color=C_MUTED).pack(anchor="w", pady=(0, 6))
            return f

        def divider():
            ctk.CTkFrame(parent, fg_color=C_BORDER, height=1).pack(
                fill="x", padx=14, pady=8)

        # ── Broadcast ─────────────────────────────────────────────────────────
        s1 = section("BROADCAST")
        ctk.CTkButton(s1, text="▶  Spustiť všetky kamery",
                       fg_color=C_ACCENT, hover_color="#2563eb",
                       font=ctk.CTkFont(*FONT_MD),
                       command=self._start_all).pack(fill="x", pady=(0, 4))
        ctk.CTkButton(s1, text="■  Stop všetky",
                       fg_color="transparent", hover_color="#2a1a1a",
                       border_width=1, border_color=C_RED,
                       text_color=C_RED, font=ctk.CTkFont(*FONT_MD),
                       command=self._stop_all).pack(fill="x")

        divider()

        # ── Recording (Intel PC — nezávislé) ──────────────────────────────────
        s2 = section("RECORDING  (Intel PC — FFmpeg, nezávislé od OBS)")
        self._btn_rec = ctk.CTkButton(
            s2, text="⏺  Spustiť nahrávanie",
            fg_color="transparent", hover_color="#2a1a1a",
            border_width=1, border_color=C_MUTED,
            text_color=C_MUTED, font=ctk.CTkFont(*FONT_MD),
            command=self._toggle_rec
        )
        self._btn_rec.pack(fill="x")

        divider()

        # ── Intel nodes ───────────────────────────────────────────────────────
        s3 = section("INTEL PC NODES")
        self._nodes_frame = s3   # refrencia pre dynamicke pridavanie
        self._node_rows: dict[int, dict] = {}

        # Nacitaj nodes z config.json — nie hardcoded
        from controller import load_config
        cfg = load_config()
        for n in cfg.get("intel_nodes", []):
            self._add_node_row(n["id"], n["ip"])

        ctk.CTkButton(
            s3, text="+ Pridať node",
            fg_color=C_CARD, hover_color="#333333",
            border_width=1, border_color=C_BORDER,
            font=ctk.CTkFont(*FONT_SM),
            command=self._add_node_dialog
        ).pack(fill="x", pady=(4, 0))

        divider()

        # ── MIDI ──────────────────────────────────────────────────────────────
        s4 = section("MIDI PULT")
        self._lbl_midi_port = ctk.CTkLabel(
            s4, text="Nepripojený",
            font=ctk.CTkFont(*FONT_SM), text_color=C_MUTED)
        self._lbl_midi_port.pack(anchor="w", pady=(0, 4))

        ctk.CTkButton(s4, text="Pripojiť MIDI",
                       fg_color=C_CARD, hover_color="#333333",
                       border_width=1, border_color=C_BORDER,
                       font=ctk.CTkFont(*FONT_MD),
                       command=self._connect_midi).pack(fill="x")

        # ── Vahana status ─────────────────────────────────────────────────────
        divider()
        s5 = section("VAHANA VR — vstupy")
        self._vahana_rows = []
        for i in range(1, 5):
            row = ctk.CTkFrame(s5, fg_color="transparent")
            row.pack(fill="x", pady=1)
            ctk.CTkLabel(row, text=f"Feed {i}",
                         font=ctk.CTkFont(*FONT_SM),
                         text_color=C_MUTED).pack(side="left")
            lbl = ctk.CTkLabel(row, text="—",
                                font=ctk.CTkFont(*FONT_SM),
                                text_color=C_MUTED)
            lbl.pack(side="right")
            self._vahana_rows.append(lbl)

        # padding dole
        ctk.CTkFrame(parent, fg_color="transparent", height=14).pack()

    # ──────────────────────────────────────────────────────────────────────────
    # Actions
    # ──────────────────────────────────────────────────────────────────────────

    def _start_all(self):
        self._ctrl.start_all_cameras()
        self._update_cam_grid()

    def _stop_all(self):
        self._ctrl.stop_all_cameras()
        self._update_cam_grid()

    def _toggle_rec(self):
        if not self._recording_active:
            self._ctrl.run_async(self._loop, self._ctrl.start_all_recording())
            self._recording_active = True
            self._btn_rec.configure(
                text="⏹  Zastaviť nahrávanie",
                border_color=C_RED, text_color=C_RED)
            self._lbl_rec.configure(text="⏺  REC", text_color=C_RED)
        else:
            self._ctrl.run_async(self._loop, self._ctrl.stop_all_recording())
            self._recording_active = False
            self._btn_rec.configure(
                text="⏺  Spustiť nahrávanie",
                border_color=C_MUTED, text_color=C_MUTED)
            self._lbl_rec.configure(text="⏺  REC OFF", text_color=C_MUTED)

    def _cam_click(self, cam_id: int):
        self._ctrl.run_async(
            self._loop, self._ctrl.switch_obs_to_camera(cam_id)
        )
        self.after(0, lambda: self._set_active_cam(cam_id))

    def _on_midi_switch(self, cam_id: int):
        """Callback z MIDI threadu"""
        self._ctrl.run_async(
            self._loop, self._ctrl.switch_obs_to_camera(cam_id)
        )
        self.after(0, lambda: self._set_active_cam(cam_id))

    def _connect_midi(self):
        ports = self._midi.list_ports()
        if ports:
            self._midi.connect(ports[0])
            self._lbl_midi_port.configure(
                text=ports[0], text_color=C_GREEN)
            self._lbl_midi_tb.configure(
                text=f"MIDI  {ports[0]}", text_color=C_GREEN)
        else:
            self._lbl_midi_port.configure(
                text="Žiadny MIDI port", text_color=C_RED)

    # ──────────────────────────────────────────────────────────────────────────
    # UI Updates
    # ──────────────────────────────────────────────────────────────────────────

    def _on_camera_found(self, cam: Camera):
        self.after(0, lambda: self._mark_cam_online(cam))

    def _add_cam_btn(self, cam_id: int):
        """
        Dynamicky prida tlacidlo pre novu kameru do gridu.
        Volane ked Zeroconf objavi kameru — pocet je neznamy dopredu.
        Grid sa automaticky preskupuje podla poctu kamier.
        """
        if cam_id in self._cam_btns:
            return  # uz existuje

        # Pocet stlpcov: max 11 pre sirky obrazovky, inak menej
        cols = min(11, len(self._cam_btns) + 1)
        # Prepocitaj vsetky pozicie (grid sa moze zmenit)
        for cid, btn in self._cam_btns.items():
            col = (cid - 1) % cols
            row = (cid - 1) // cols
            btn.grid(row=row, column=col, padx=3, pady=3)

        col = (cam_id - 1) % cols
        row = (cam_id - 1) // cols

        btn = ctk.CTkButton(
            self._cam_grid_frame,
            text=f"CAM\n{cam_id:02d}",
            width=78, height=64,
            font=ctk.CTkFont(*FONT_SM),
            fg_color=C_CAM_OFF,
            hover_color="#2a2a2a",
            border_color=C_BORDER,
            border_width=1,
            corner_radius=8,
            command=lambda cid=cam_id: self._cam_click(cid)
        )
        btn.grid(row=row, column=col, padx=3, pady=3)
        self._cam_btns[cam_id] = btn

    def _mark_cam_online(self, cam: Camera):
        # Pridaj tlacidlo ak este neexistuje
        self._add_cam_btn(cam.id)

        btn = self._cam_btns.get(cam.id)
        if btn:
            btn.configure(
                fg_color="#0f2a0f",
                border_color=C_GREEN, border_width=1,
                text_color=C_GREEN
            )
        # Pocet kamier je dynamicky — nezname dopredu
        online = sum(1 for c in self._ctrl.cameras.values())
        total  = online  # vsetky objavene = total (pridavaju sa za behu)
        self._lbl_cams.configure(text=f"{online} kamier online")

    def _set_active_cam(self, cam_id: int):
        """Zvýrazni aktívnu kameru, zosedi ostatné"""
        for cid, btn in self._cam_btns.items():
            cam = self._ctrl.cameras.get(cid)
            if cid == cam_id:
                btn.configure(fg_color=C_CAM_SEL,
                               border_color=C_ACCENT, border_width=2)
            elif cam and cam.streaming:
                btn.configure(fg_color=C_CAM_LIVE,
                               border_color=C_GREEN, border_width=1)
            else:
                btn.configure(fg_color=C_CAM_OFF,
                               border_color=C_BORDER, border_width=1)

        self._lbl_active.configure(text=f"▶  CAM {cam_id:02d}")

        # Update OBS cards
        for i, card in enumerate(self._obs_cards):
            card["lbl_cam"].configure(
                text=f"cam{cam_id:02d} / {card['stream']}",
                text_color=C_GREEN)
            card["lbl_status"].configure(text_color=C_GREEN)
            card["lbl_prev"].configure(
                text=f"rtmp://127.0.0.1:1935/cam{cam_id:02d}/{card['stream']}\n"
                     f"ws://localhost:{card['port']}",
                text_color=C_TEXT)

        # Vahana feeds
        for i, lbl in enumerate(self._vahana_rows):
            lbl.configure(
                text=f"cam{cam_id:02d}/{self._obs_cards[i]['stream']}",
                text_color=C_GREEN)

    def _update_cam_grid(self):
        for cam_id, btn in self._cam_btns.items():
            cam = self._ctrl.cameras.get(cam_id)
            if not cam:
                continue
            if cam_id == self._ctrl.active_cam_id:
                btn.configure(fg_color=C_CAM_SEL, border_color=C_ACCENT)
            elif cam.streaming:
                btn.configure(fg_color=C_CAM_LIVE, border_color=C_GREEN)
            else:
                btn.configure(fg_color=C_CAM_OFF, border_color=C_BORDER)

    def _add_node_row(self, node_id: int, ip: str):
        """Prida riadok pre node do sidebaru — volane dynamicky"""
        if node_id in self._node_rows:
            return

        row = ctk.CTkFrame(self._nodes_frame, fg_color=C_CARD,
                           corner_radius=6, border_width=1,
                           border_color=C_BORDER)
        row.pack(fill="x", pady=2)

        ctk.CTkLabel(row, text=f"Node {node_id}  {ip}",
                     font=ctk.CTkFont(*FONT_SM),
                     text_color=C_TEXT).pack(side="left", padx=8, pady=5)

        lbl_dot = ctk.CTkLabel(row, text="●",
                                font=ctk.CTkFont(*FONT_SM),
                                text_color=C_MUTED)
        lbl_dot.pack(side="right", padx=8)

        lbl_cnt = ctk.CTkLabel(row, text="",
                                font=ctk.CTkFont(*FONT_SM),
                                text_color=C_MUTED)
        lbl_cnt.pack(side="right", padx=2)

        self._node_rows[node_id] = {"dot": lbl_dot, "cnt": lbl_cnt}

    def _add_node_dialog(self):
        """Jednoduchy dialog na pridanie noveho Intel node"""
        dialog = ctk.CTkInputDialog(
            text="IP adresa noveho Intel PC node:",
            title="Pridať node"
        )
        ip = dialog.get_input()
        if ip and ip.strip():
            ip = ip.strip()
            node = self._ctrl.add_node(ip)
            self.after(0, lambda: self._add_node_row(node.id, ip))
            print(f"[UI] Pridany node {node.id} → {ip}")

    def _refresh_nodes(self):
        """Aktualizuj status vsetkych nodov — dynamicky podla self._ctrl.nodes"""
        # Pridaj riadky pre nove nodes ktore ešte nemaju UI
        for node in self._ctrl.nodes.values():
            if node.id not in self._node_rows:
                self.after(0, lambda nid=node.id, nip=node.ip:
                           self._add_node_row(nid, nip))

        for node_id, widgets in self._node_rows.items():
            node = self._ctrl.nodes.get(node_id)
            if node and node.online:
                cams = node.cameras
                label = f"{node.recording_count} rec / {len(cams)} cam"
                widgets["dot"].configure(text_color=C_GREEN)
                widgets["cnt"].configure(text=label,
                    text_color=C_GREEN if node.recording_count > 0 else C_MUTED)
            else:
                widgets["dot"].configure(text_color=C_MUTED)
                widgets["cnt"].configure(text="offline", text_color=C_RED)

    # ──────────────────────────────────────────────────────────────────────────
    # Startup
    # ──────────────────────────────────────────────────────────────────────────

    def _start(self):
        self._ctrl.start_discovery()
        self._connect_midi()
        self._poll()

    def _poll(self):
        self._ctrl.run_async(self._loop, self._ctrl.poll_status())
        self.after(5000, self._poll)


# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    app = OrahApp()
    app.mainloop()
