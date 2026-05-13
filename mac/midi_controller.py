"""
midi_controller.py — bezi na Mac M4
Pocuva MIDI pult, note 1-22 = kamera 1-22
pip install mido python-rtmidi
"""

import mido
import threading
from typing import Callable


class MidiController:

    def __init__(self, on_camera_switch: Callable[[int], None]):
        self.on_camera_switch = on_camera_switch
        self._running   = False
        self._thread    = None
        self.port_name  = None

        # note → camera_id  (uprav podla svojho pultu)
        self.mapping: dict[int, int] = {i: i for i in range(1, 23)}

    def list_ports(self) -> list[str]:
        return mido.get_input_names()

    def connect(self, port_name: str = None) -> bool:
        ports = self.list_ports()
        if not ports:
            print("[MIDI] Ziadny port")
            return False
        self.port_name = port_name or ports[0]
        self._running  = True
        self._thread   = threading.Thread(
            target=self._listen, daemon=True, name="MidiListener")
        self._thread.start()
        print(f"[MIDI] Pripojeny: {self.port_name}")
        return True

    def disconnect(self):
        self._running = False

    def _listen(self):
        try:
            with mido.open_input(self.port_name) as port:
                for msg in port:
                    if not self._running:
                        break
                    if msg.type == "note_on" and msg.velocity > 0:
                        cam_id = self.mapping.get(msg.note)
                        if cam_id:
                            print(f"[MIDI] note {msg.note} → cam{cam_id:02d}")
                            self.on_camera_switch(cam_id)
        except Exception as e:
            print(f"[MIDI] Chyba: {e}")

    def remap(self, note: int, cam_id: int):
        self.mapping[note] = cam_id

    def save_mapping(self, path: str):
        import json
        with open(path, "w") as f:
            json.dump(self.mapping, f, indent=2)

    def load_mapping(self, path: str):
        import json
        with open(path) as f:
            self.mapping = {int(k): v for k, v in json.load(f).items()}
