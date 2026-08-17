#!/usr/bin/env python3
"""
Fleet report — compares the calibration of every camera checked out so far.

Reads the .ptv files archived by `orahctl checkout` and answers the question that
decides whether cameras can be switched without swapping Vahana's calibration:
how far apart are these units?

    ./fleet-report.py [directory ...]
"""

import glob
import json
import os
import sys

LENS_NAMES = ["0_0", "0_1", "1_0", "1_1"]


def load(path):
    with open(path) as f:
        return json.load(f)


def geometry(inp):
    for item in inp.get("geometries", []):
        if isinstance(item, dict):
            return item
    return {}


def angle_delta(a, b):
    d = b - a
    while d > 180:
        d -= 360
    while d < -180:
        d += 360
    return d


def main():
    roots = sys.argv[1:] or ["docs", "camera-records"]
    files = []
    for root in roots:
        files += glob.glob(os.path.join(root, "*.ptv"))
    files = sorted(set(files))

    if len(files) < 2:
        print(f"Need at least two calibrations to compare; found {len(files)}.")
        print("Run `orahctl checkout` with cameras plugged in.")
        return 1

    cams = []
    for path in files:
        try:
            d = load(path)
        except Exception as e:
            print(f"  skipping {path}: {e}")
            continue
        name = os.path.basename(path)
        for token in name.replace(".ptv", "").split("_"):
            if token.startswith("AQ"):
                name = token
                break
        cams.append((name, path, d))

    print(f"Comparing {len(cams)} calibrations\n")

    width = cams[0][2]["pano"]["width"]
    px_per_deg = width / 360.0
    print(f"panorama width {width} px  →  1° = {px_per_deg:.1f} px at the equator\n")

    # Per lens, per angle: spread across the whole fleet.
    print(f"{'lens':<7}{'angle':<8}{'min':>10}{'max':>10}{'spread':>10}{'px':>8}")
    print("─" * 53)
    worst_px, worst_where = 0.0, ""
    for i, lens in enumerate(LENS_NAMES):
        for field in ("yaw", "pitch", "roll"):
            values = []
            for name, _, d in cams:
                inputs = d["pano"]["inputs"]
                if i < len(inputs):
                    v = geometry(inputs[i]).get(field)
                    if v is not None:
                        values.append(v)
            if len(values) < 2:
                continue
            lo, hi = min(values), max(values)
            spread = abs(angle_delta(lo, hi))
            px = spread * px_per_deg
            if px > worst_px:
                worst_px, worst_where = px, f"lens {lens} {field}"
            print(f"{lens:<7}{field:<8}{lo:>10.2f}{hi:>10.2f}{spread:>10.2f}{px:>8.1f}")
        print()

    # Crop is the other axis that matters: it decides how much of the fisheye
    # circle is used, so a wrong crop can pull in the lens edge.
    print("crop spread (input pixels)")
    print("─" * 53)
    crop_keys = ("crop_left", "crop_right", "crop_top", "crop_bottom")
    safe_crop = {}
    for i, lens in enumerate(LENS_NAMES):
        parts = []
        for key in crop_keys:
            values = [d["pano"]["inputs"][i].get(key) for _, _, d in cams
                      if i < len(d["pano"]["inputs"])]
            values = [v for v in values if v is not None]
            if not values:
                continue
            parts.append(f"{key.replace('crop_',''):<7}{max(values)-min(values):>4}")
            # The intersection never includes any camera's unusable margin.
            safe_crop.setdefault(lens, {})[key] = (
                max(values) if key in ("crop_left", "crop_top") else min(values))
        print(f"  {lens}   " + "   ".join(parts))

    print()
    print("─" * 53)
    print(f"worst angular spread: {worst_px:.1f} px  ({worst_where})")
    print(f"on a {width} px panorama")
    print()
    if worst_px < 3:
        print("Small enough that a single shared calibration should not be visible.")
    elif worst_px < 10:
        print("Visible only as slight seam softness. A shared calibration is workable;")
        print("switching calibration with the source is better if Vahana allows it.")
    else:
        print("Large enough to show at the seams. Calibration should follow the source.")

    print()
    print("If one shared calibration is used, these crops never include any")
    print("camera's unusable margin:")
    for lens, crop in safe_crop.items():
        print(f"  {lens}  " + "  ".join(f"{k.replace('crop_','')}={v}" for k, v in crop.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
