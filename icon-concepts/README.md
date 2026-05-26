# App Icon Source Material

This folder holds the **design exploration and generator scripts** behind the
ConsoleForge app icon. It is the source-of-truth for *how* the shipped icon was
made — kept in the repo so the icon can be tweaked and regenerated later instead
of being a one-off binary with no provenance.

The actual icon used by the app lives at `../ConsoleForge/Assets/AppIcon.icns`.
This folder is **not** referenced by the build — it's tooling/design history.

## What shipped

The final icon is the **dark "forge" concept**: a macOS-style terminal window
with a warm forge glow. The pipeline that produced it:

1. `generate_final.py` → renders `icon_dark.png` and `icon_light.png` (1024×1024).
   The dark variant is the one we shipped.
2. `build_icns.py` → resizes `icon_dark.png` into the 10 required sizes under
   `AppIcon.iconset/`, runs `iconutil -c icns`, and writes the result to
   `../ConsoleForge/Assets/AppIcon.icns` (also copies into a local
   `build/ConsoleForge.app` bundle if present).

To regenerate the shipped `.icns` after editing the icon:

```bash
cd icon-concepts
python3 generate_final.py   # if changing the artwork; rewrites icon_dark.png
python3 build_icns.py        # rebuilds ../ConsoleForge/Assets/AppIcon.icns
```

Requires Python with Pillow (`pip install Pillow`) and macOS `iconutil`.

## Files

| File | Purpose |
|------|---------|
| `concept1_anvil_terminal.png` … `concept4_clean_modern.png` | First-round 1024² concept mockups (anvil, hammer cursor, forge flame, clean modern) |
| `generate_icons.py` | Generates the round-one concept mockups above |
| `refined_3a/3b_forge_*.png`, `refined_4a/4b_modern_*.png` | Second-round refinements of the forge and modern directions |
| `generate_refined.py` | Generates the refined variants above |
| `generate_final.py` | Produces the final `icon_dark.png` / `icon_light.png` (chosen design) |
| `icon_dark.png` / `icon_light.png` | Final 1024² source images; `icon_dark.png` is what ships |
| `build_icns.py` | Builds `AppIcon.icns` from `icon_dark.png` via `iconutil` |
| `AppIcon.iconset/` | Intermediate per-size PNGs emitted by `build_icns.py` |

## Why this is committed

The `.icns` in the app bundle is a flattened binary with no editable source.
Keeping these generators + concept art means a future change to the icon is a
script edit and a rerun, not a from-scratch redesign.
