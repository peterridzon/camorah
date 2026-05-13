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

_SCRIPT_DIR = Path(__file__).resolve().parent

STREAMS = ["0_0", "0_1", "1_0", "1_1"]


def generate(num_cameras: int, output_path: str | None = None):
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

    out = output_path if output_path is not None else str(_SCRIPT_DIR / "mediamtx.yml")
    content = "\n".join(lines)
    Path(out).write_text(content)
    print(f"Generovany {out} pre {num_cameras} kamier ({num_cameras * 4} streamov)")
    return content


def generate_from_config(
    config_path: str | None = None,
    output_path: str | None = None,
):
    """
    Generuj konfig podla config.json.
    num_cameras = pocet unikatnych kamier vo vsetkych nodoch,
    alebo ak nodes su prazdne, pouzij poslednu znamu kameru.
    """
    cfg_p = config_path if config_path is not None else str(_SCRIPT_DIR / "config.json")
    out_p = output_path
    cfg_file = Path(cfg_p)
    if not cfg_file.exists():
        print(f"{cfg_p} nenajdeny, generujem pre 1 kameru")
        generate(1, out_p)
        return

    cfg = json.loads(cfg_file.read_text())
    nodes = cfg.get("intel_nodes", [])

    # Zisti max camera_id zo vsetkych nodov
    all_cams = []
    for node in nodes:
        all_cams.extend(node.get("cameras", []))

    num_cameras = max(all_cams) if all_cams else cfg.get("max_cameras_hint", 1)
    generate(num_cameras, out_p)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cameras", type=int, default=None,
                        help="Pocet kamier (default: zo config.json)")
    parser.add_argument("--output", type=str, default=None)
    parser.add_argument("--config", type=str, default=None)
    args = parser.parse_args()

    if args.cameras:
        generate(args.cameras, args.output)
    else:
        generate_from_config(args.config, args.output)
