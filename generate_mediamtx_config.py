"""
generate_mediamtx_config.py
Generuje mediamtx.yml dynamicky podla poctu kamier.
Spusti pred startom MediaMTX — alebo pri pridani novej kamery.

Pouzitie:
  python generate_mediamtx_config.py            # zo config.json
  python generate_mediamtx_config.py --cameras 30  # pre 30 kamier
"""

import argparse
import json
from pathlib import Path

STREAMS = ["0_0", "0_1", "1_0", "1_1"]

def generate(num_cameras: int, output_path: str = "mediamtx.yml"):
    lines = [
        "# mediamtx.yml — auto-generovany, nemen rucne",
        f"# Kamery: {num_cameras}  Streamy: {num_cameras * 4}",
        "",
        "logLevel: info",
        "logDestinations: [stdout]",
        "",
        "rtmp: yes",
        "rtmpAddress: :1935",
        "",
        "api: yes",
        "apiAddress: :9997",
        "",
        "hls: no",
        "webrtc: no",
        "srt: no",
        "",
        "paths:",
        "",
    ]

    for cam_id in range(1, num_cameras + 1):
        lines.append(f"  # Kamera {cam_id:02d}")
        for stream in STREAMS:
            lines.append(f"  cam{cam_id:02d}/{stream}:")
            lines.append(f"    source: publisher")
        lines.append("")

    content = "\n".join(lines)
    Path(output_path).write_text(content)
    print(f"Generovany {output_path} pre {num_cameras} kamier ({num_cameras * 4} streamov)")
    return content


def generate_from_config(config_path: str = "config.json", output_path: str = "mediamtx.yml"):
    """
    Generuj konfig podla config.json.
    num_cameras = pocet unikatnych kamier vo vsetkych nodoch,
    alebo ak nodes su prazdne, pouzij poslednu znamu kameru.
    """
    cfg_file = Path(config_path)
    if not cfg_file.exists():
        print(f"{config_path} nenajdeny, generujem pre 1 kameru")
        generate(1, output_path)
        return

    cfg = json.loads(cfg_file.read_text())
    nodes = cfg.get("intel_nodes", [])

    # Zisti max camera_id zo vsetkych nodov
    all_cams = []
    for node in nodes:
        all_cams.extend(node.get("cameras", []))

    num_cameras = max(all_cams) if all_cams else cfg.get("max_cameras_hint", 1)
    generate(num_cameras, output_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cameras", type=int, default=None,
                        help="Pocet kamier (default: zo config.json)")
    parser.add_argument("--output",  type=str, default="mediamtx.yml")
    parser.add_argument("--config",  type=str, default="config.json")
    args = parser.parse_args()

    if args.cameras:
        generate(args.cameras, args.output)
    else:
        generate_from_config(args.config, args.output)
