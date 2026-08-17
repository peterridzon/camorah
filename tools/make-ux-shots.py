#!/usr/bin/env python3
"""
Generates the desk screenshots used in the README, from docs/ux/main-window.html.

The UX page is the drawing the app was built from, so it is also the honest place
to take a picture of the surface: it renders identically on any machine, whereas a
capture of the running app depends on which cameras happen to be plugged in.

    ./make-ux-shots.py            # → docs/ui/desk.png, docs/ui/matrix.png
"""

import subprocess
import sys
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parent.parent
PAGE = REPO / "docs" / "ux" / "main-window.html"
OUT = REPO / "docs" / "ui"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# The page is a fixed-width document: 60px of padding either side of a 1232px
# column. Rendered at exactly this width the layout is deterministic, so the
# panels can be cropped by coordinate. Measured once against the page; if the
# page grows a section above one of these, re-measure with the browser's
# getBoundingClientRect and update the numbers here.
WIDTH = 1352
HEIGHT = 3700
SCALE = 2

SHOTS = {
    "desk": (60, 361, 1292, 1445),
    "matrix": (60, 2000, 1292, 2718),
}


def main() -> int:
    if not Path(CHROME).exists():
        print("Chrome not found — needed for headless rendering")
        return 1

    full = OUT / ".ux-full.png"
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
         f"--force-device-scale-factor={SCALE}",
         f"--screenshot={full}", f"--window-size={WIDTH},{HEIGHT}",
         PAGE.as_uri()],
        check=True, capture_output=True)

    page = Image.open(full)
    for name, (x0, y0, x1, y1) in SHOTS.items():
        shot = page.crop((x0 * SCALE, y0 * SCALE, x1 * SCALE, y1 * SCALE))
        # A crop that landed on empty background means the coordinates have
        # drifted; better to say so than to commit a black rectangle. getcolors
        # returns None once the image is richer than the limit, which is exactly
        # the healthy case.
        colours = shot.convert("RGB").getcolors(maxcolors=4096)
        if colours is not None and len(colours) < 12:
            print(f"{name}: crop looks empty — re-measure the coordinates")
            return 1
        target = OUT / f"{name}.png"
        shot.save(target)
        print(f"  {target.relative_to(REPO)}  {shot.width}×{shot.height}")

    full.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())
