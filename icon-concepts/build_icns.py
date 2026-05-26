#!/usr/bin/env python3
"""Build AppIcon.icns from icon_dark.png for ConsoleForge."""

from PIL import Image
import os
import subprocess
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
SOURCE = os.path.join(SCRIPT_DIR, "icon_dark.png")
ICONSET_DIR = os.path.join(SCRIPT_DIR, "AppIcon.iconset")
OUTPUT_ICNS = os.path.join(PROJECT_DIR, "ConsoleForge", "Assets", "AppIcon.icns")

# macOS iconset requires these exact filenames and sizes
SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

def main():
    img = Image.open(SOURCE).convert("RGBA")
    assert img.size == (1024, 1024), f"Source should be 1024x1024, got {img.size}"

    os.makedirs(ICONSET_DIR, exist_ok=True)

    for filename, size in SIZES:
        resized = img.resize((size, size), Image.LANCZOS)
        path = os.path.join(ICONSET_DIR, filename)
        resized.save(path, "PNG")
        print(f"  {filename} ({size}x{size})")

    # Use iconutil to create .icns
    os.makedirs(os.path.dirname(OUTPUT_ICNS), exist_ok=True)
    result = subprocess.run(
        ["iconutil", "-c", "icns", ICONSET_DIR, "-o", OUTPUT_ICNS],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"iconutil failed: {result.stderr}")
        return

    print(f"\nCreated: {OUTPUT_ICNS}")

    # Also copy to build app bundle for immediate use
    build_resources = os.path.join(PROJECT_DIR, "build", "ConsoleForge.app", "Contents", "Resources")
    if os.path.isdir(build_resources):
        import shutil
        dest = os.path.join(build_resources, "AppIcon.icns")
        shutil.copy2(OUTPUT_ICNS, dest)
        print(f"Copied to: {dest}")

if __name__ == "__main__":
    main()
