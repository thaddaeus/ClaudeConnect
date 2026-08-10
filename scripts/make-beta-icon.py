#!/usr/bin/env python3
"""Regenerate ConsoleForge/Assets/AppIconBeta.icns from AppIcon.icns.

The beta icon is just the production icon hue-rotated, so beta and production are
tellable apart in the Dock and the app switcher at a glance. The result is
committed — beta.sh copies it and never runs this — so run this by hand whenever
AppIcon.icns is redesigned, otherwise the beta icon quietly goes stale.

    python3 scripts/make-beta-icon.py

Requires Pillow (`pip install Pillow`) and iconutil (ships with macOS).
"""

import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

# Degrees. 150 takes the terminal text orange -> cyan and the background
# purple -> dark green: unmistakable at 32px without redrawing anything.
HUE_SHIFT_DEGREES = 150

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ConsoleForge", "Assets")
SOURCE_ICNS = os.path.join(ASSETS, "AppIcon.icns")
OUTPUT_ICNS = os.path.join(ASSETS, "AppIconBeta.icns")


def main():
    if not os.path.exists(SOURCE_ICNS):
        sys.exit(f"Source icon not found: {SOURCE_ICNS}")

    work = tempfile.mkdtemp(prefix="beta-icon-")
    try:
        src_set = os.path.join(work, "AppIcon.iconset")
        dst_set = os.path.join(work, "AppIconBeta.iconset")
        subprocess.run(
            ["iconutil", "-c", "iconset", "-o", src_set, SOURCE_ICNS], check=True
        )
        os.makedirs(dst_set)

        offset = int(HUE_SHIFT_DEGREES * 255 / 360)
        for name in sorted(os.listdir(src_set)):
            image = Image.open(os.path.join(src_set, name)).convert("RGBA")
            alpha = image.getchannel("A")
            hue, sat, val = image.convert("RGB").convert("HSV").split()
            hue = hue.point(lambda p: (p + offset) % 256)
            shifted = Image.merge("HSV", (hue, sat, val)).convert("RGB")
            shifted.putalpha(alpha)
            shifted.save(os.path.join(dst_set, name))

        subprocess.run(
            ["iconutil", "-c", "icns", "-o", OUTPUT_ICNS, dst_set], check=True
        )
        print(f"Wrote {OUTPUT_ICNS}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
