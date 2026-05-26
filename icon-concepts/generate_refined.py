#!/usr/bin/env python3
"""Refined icon concepts based on concepts 3 and 4."""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024
CORNER = 220


def rounded_rect_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def apply_mask(img):
    mask = rounded_rect_mask(SIZE, CORNER)
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def draw_terminal_window(d, tx, ty, tw, th, radius=20, opacity=240):
    """Draw a macOS-style terminal window."""
    # Shadow
    d.rounded_rectangle([tx+5, ty+5, tx+tw+5, ty+th+5], radius=radius, fill=(0, 0, 0, 50))
    # Window body
    d.rounded_rectangle([tx, ty, tx+tw, ty+th], radius=radius, fill=(22, 24, 38, opacity))
    # Title bar
    bar_h = int(th * 0.085)
    d.rounded_rectangle([tx, ty, tx+tw, ty+bar_h+10], radius=radius, fill=(38, 40, 58, min(255, opacity+15)))
    d.rectangle([tx, ty+bar_h, tx+tw, ty+bar_h+10], fill=(38, 40, 58, min(255, opacity+15)))
    # Traffic lights
    dot_r = max(4, int(th * 0.018))
    dot_y = ty + bar_h // 2 + 2
    dot_x = tx + int(tw * 0.035)
    gap = int(dot_r * 2.4)
    d.ellipse([dot_x, dot_y-dot_r, dot_x+dot_r*2, dot_y+dot_r], fill="#FF5F56")
    d.ellipse([dot_x+gap, dot_y-dot_r, dot_x+gap+dot_r*2, dot_y+dot_r], fill="#FFBD2E")
    d.ellipse([dot_x+gap*2, dot_y-dot_r, dot_x+gap*2+dot_r*2, dot_y+dot_r], fill="#27C93F")
    return bar_h + 10


def draw_prompt_line(d, x, y, scale=1.0, color=(0, 255, 136), alpha=255):
    """Draw a >_ prompt line."""
    thick = max(3, int(8 * scale))
    s = scale
    c = (*color, alpha)
    # Chevron >
    d.line([(x, y), (x + 40*s, y + 25*s), (x, y + 50*s)], fill=c, width=thick, joint="curve")
    # Underscore _
    d.line([(x + 55*s, y + 42*s), (x + 100*s, y + 42*s)], fill=c, width=thick)


def draw_cursor_block(d, x, y, w, h, color=(0, 255, 136)):
    """Draw a blinking cursor block."""
    d.rectangle([x, y, x+w, y+h], fill=(*color, 220))


def draw_text_lines(d, x, y, scale=1.0, color=(0, 255, 136)):
    """Draw fake terminal text output lines."""
    thick = max(3, int(5 * scale))
    s = scale
    alpha_vals = [80, 50, 35]
    widths = [160, 220, 120]
    for i, (a, w) in enumerate(zip(alpha_vals, widths)):
        ly = y + i * int(22 * s)
        d.line([(x, ly), (x + w*s, ly)], fill=(*color, a), width=thick)


# ─────────────────────────────────────────────
# 3A: Forge flame — refined, richer flame layers
# Terminal centered in a well-shaped flame
# ─────────────────────────────────────────────
def concept_3a():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Dark background with subtle warm tint
    for y in range(SIZE):
        t = y / SIZE
        r = int(22 + t * 18)
        g = int(14 + t * 10)
        b = int(20 + t * 8)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Build flame on a separate layer and blur for softness
    flame_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    fd = ImageDraw.Draw(flame_layer)

    # Flame: draw as filled ellipses stacked, narrower at top
    flame_specs = [
        # (y_center, width, height, color)
        (380, 380, 520, (180, 40, 0, 30)),    # outermost red glow
        (370, 320, 460, (220, 60, 0, 45)),
        (360, 260, 400, (255, 90, 0, 55)),
        (350, 210, 340, (255, 130, 10, 70)),
        (340, 160, 280, (255, 170, 30, 90)),
        (330, 110, 220, (255, 200, 60, 110)),
        (320, 70, 160, (255, 225, 100, 130)),
    ]
    for yc, w, h, color in flame_specs:
        fd.ellipse([cx - w, yc - h//2, cx + w, yc + h//2], fill=color)

    # Blur the flame for a soft glow effect
    flame_layer = flame_layer.filter(ImageFilter.GaussianBlur(radius=25))
    img = Image.alpha_composite(img, flame_layer)
    d = ImageDraw.Draw(img)

    # Terminal window
    tw, th = 400, 300
    tx, ty = (SIZE - tw) // 2, 330
    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=18, opacity=230)

    # Content
    draw_prompt_line(d, tx + 35, ty + bar_h + 20, scale=1.2)
    draw_text_lines(d, tx + 35, ty + bar_h + 85, scale=1.2)
    draw_prompt_line(d, tx + 35, ty + bar_h + 160, scale=1.2, alpha=200)
    draw_cursor_block(d, tx + 35 + 130, ty + bar_h + 167, 14, 28)

    # Anvil base
    base_y = 700
    # Main surface
    d.rounded_rectangle([cx - 220, base_y, cx + 220, base_y + 40], radius=6, fill=(100, 100, 106))
    d.rounded_rectangle([cx - 220, base_y, cx + 220, base_y + 12], radius=6, fill=(120, 120, 128))
    # Pedestal
    d.rounded_rectangle([cx - 140, base_y + 40, cx + 140, base_y + 110], radius=8, fill=(70, 70, 76))
    # Base
    d.rounded_rectangle([cx - 180, base_y + 110, cx + 180, base_y + 140], radius=6, fill=(55, 55, 60))

    return apply_mask(img)


# ─────────────────────────────────────────────
# 3B: Forge flame — more dramatic, flame wraps
# around terminal edges, ember particles
# ─────────────────────────────────────────────
def concept_3b():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Very dark background
    for y in range(SIZE):
        t = y / SIZE
        r = int(15 + t * 12)
        g = int(10 + t * 8)
        b = int(18 + t * 6)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Larger, more dramatic flame
    flame_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    fd = ImageDraw.Draw(flame_layer)

    # Taller flame
    flame_specs = [
        (340, 400, 620, (140, 20, 0, 25)),
        (330, 340, 560, (180, 40, 0, 40)),
        (320, 280, 500, (220, 70, 0, 50)),
        (310, 230, 420, (255, 100, 0, 65)),
        (300, 180, 350, (255, 140, 10, 80)),
        (290, 140, 280, (255, 180, 40, 100)),
        (280, 100, 210, (255, 210, 80, 120)),
        (270, 60, 140, (255, 235, 120, 140)),
    ]
    for yc, w, h, color in flame_specs:
        fd.ellipse([cx - w, yc - h//2, cx + w, yc + h//2], fill=color)

    flame_layer = flame_layer.filter(ImageFilter.GaussianBlur(radius=30))
    img = Image.alpha_composite(img, flame_layer)
    d = ImageDraw.Draw(img)

    # Ember particles floating up
    import random
    random.seed(42)
    ember_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ed = ImageDraw.Draw(ember_layer)
    for _ in range(60):
        ex = cx + random.randint(-300, 300)
        ey = random.randint(80, 650)
        er = random.randint(2, 5)
        ea = random.randint(80, 200)
        # Brighter near bottom, dimmer near top
        brightness = max(0.3, 1.0 - (650 - ey) / 600)
        ec = (255, int(160 * brightness), int(30 * brightness), int(ea * brightness))
        ed.ellipse([ex-er, ey-er, ex+er, ey+er], fill=ec)
    ember_layer = ember_layer.filter(ImageFilter.GaussianBlur(radius=2))
    img = Image.alpha_composite(img, ember_layer)
    d = ImageDraw.Draw(img)

    # Terminal window (slightly transparent to let flame glow through edges)
    tw, th = 420, 320
    tx, ty = (SIZE - tw) // 2, 310
    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=20, opacity=220)

    # Content
    draw_prompt_line(d, tx + 35, ty + bar_h + 20, scale=1.3)
    draw_text_lines(d, tx + 35, ty + bar_h + 90, scale=1.3)
    draw_prompt_line(d, tx + 35, ty + bar_h + 170, scale=1.3, alpha=180)
    draw_cursor_block(d, tx + 35 + 140, ty + bar_h + 178, 15, 30)

    # Simple anvil base
    base_y = 710
    d.rounded_rectangle([cx - 200, base_y, cx + 200, base_y + 35], radius=6, fill=(90, 90, 96))
    d.rounded_rectangle([cx - 200, base_y, cx + 200, base_y + 10], radius=6, fill=(110, 110, 118))
    d.rounded_rectangle([cx - 130, base_y + 35, cx + 130, base_y + 95], radius=6, fill=(60, 60, 66))
    d.rounded_rectangle([cx - 170, base_y + 95, cx + 170, base_y + 120], radius=6, fill=(48, 48, 54))

    return apply_mask(img)


# ─────────────────────────────────────────────
# 4A: Clean modern — dark terminal on gradient,
# subtle anvil silhouette, polished
# ─────────────────────────────────────────────
def concept_4a():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Rich gradient background (indigo to deep blue)
    for y in range(SIZE):
        t = y / SIZE
        r = int(40 - t * 20)
        g = int(50 + t * 10)
        b = int(180 - t * 40)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Subtle anvil silhouette (very faint, behind everything)
    anvil_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ad = ImageDraw.Draw(anvil_layer)
    s = 2.8
    acy = 560
    anvil_pts = [
        (cx - 130*s, acy - 35*s),
        (cx + 130*s, acy - 35*s),
        (cx + 165*s, acy - 15*s),
        (cx + 130*s, acy + 5*s),
        (cx + 70*s, acy + 5*s),
        (cx + 55*s, acy + 70*s),
        (cx - 55*s, acy + 70*s),
        (cx - 70*s, acy + 5*s),
        (cx - 130*s, acy + 5*s),
        (cx - 165*s, acy - 15*s),
    ]
    ad.polygon(anvil_pts, fill=(255, 255, 255, 20))
    anvil_layer = anvil_layer.filter(ImageFilter.GaussianBlur(radius=8))
    img = Image.alpha_composite(img, anvil_layer)
    d = ImageDraw.Draw(img)

    # Terminal window — centered, prominent
    tw, th = 540, 380
    tx, ty = (SIZE - tw) // 2, 220
    # Larger shadow for depth
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([tx+8, ty+12, tx+tw+8, ty+th+12], radius=24, fill=(0, 0, 0, 80))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=12))
    img = Image.alpha_composite(img, shadow)
    d = ImageDraw.Draw(img)

    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=24, opacity=245)

    # Terminal content — richer
    draw_prompt_line(d, tx + 40, ty + bar_h + 25, scale=1.4, color=(0, 255, 170))
    # Output line
    thick = 5
    d.line([(tx+40, ty+bar_h+100), (tx+240, ty+bar_h+100)], fill=(0, 255, 170, 70), width=thick)
    d.line([(tx+250, ty+bar_h+100), (tx+400, ty+bar_h+100)], fill=(0, 255, 170, 40), width=thick)
    # Second output
    d.line([(tx+40, ty+bar_h+128), (tx+180, ty+bar_h+128)], fill=(0, 255, 170, 50), width=thick)
    d.line([(tx+190, ty+bar_h+128), (tx+320, ty+bar_h+128)], fill=(0, 255, 170, 30), width=thick)
    # Active prompt
    draw_prompt_line(d, tx + 40, ty + bar_h + 170, scale=1.4, color=(0, 255, 170))
    draw_cursor_block(d, tx + 40 + 150, ty + bar_h + 180, 16, 30, (0, 255, 170))

    return apply_mask(img)


# ─────────────────────────────────────────────
# 4B: Clean modern — warm accent, orange/amber
# tones suggesting forge heat, cleaner geometry
# ─────────────────────────────────────────────
def concept_4b():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Dark gradient with warm accent
    for y in range(SIZE):
        t = y / SIZE
        r = int(30 + t * 25)
        g = int(25 + t * 15)
        b = int(45 + t * 10)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Warm glow behind terminal (forge heat effect)
    glow_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow_layer)
    for r in range(300, 0, -3):
        alpha = int(30 * (1 - r / 300))
        gd.ellipse([cx-r, 400-r//2, cx+r, 400+r//2], fill=(255, 120, 20, alpha))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=40))
    img = Image.alpha_composite(img, glow_layer)
    d = ImageDraw.Draw(img)

    # Terminal window
    tw, th = 500, 360
    tx, ty = (SIZE - tw) // 2, 200

    # Shadow
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([tx+6, ty+10, tx+tw+6, ty+th+10], radius=22, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=10))
    img = Image.alpha_composite(img, shadow)
    d = ImageDraw.Draw(img)

    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=22, opacity=240)

    # Terminal content with amber/orange accent color
    accent = (255, 170, 50)
    draw_prompt_line(d, tx + 40, ty + bar_h + 22, scale=1.3, color=accent)
    # Output lines
    thick = 5
    d.line([(tx+40, ty+bar_h+95), (tx+220, ty+bar_h+95)], fill=(*accent, 60), width=thick)
    d.line([(tx+230, ty+bar_h+95), (tx+380, ty+bar_h+95)], fill=(*accent, 35), width=thick)
    d.line([(tx+40, ty+bar_h+120), (tx+160, ty+bar_h+120)], fill=(*accent, 45), width=thick)
    # Active prompt
    draw_prompt_line(d, tx + 40, ty + bar_h + 160, scale=1.3, color=accent)
    draw_cursor_block(d, tx + 40 + 140, ty + bar_h + 168, 14, 28, accent)

    # Anvil at bottom — cleaner, more geometric
    base_y = 650
    # Top surface with slight highlight
    d.rounded_rectangle([cx - 240, base_y, cx + 240, base_y + 30], radius=4, fill=(85, 85, 92))
    d.rounded_rectangle([cx - 240, base_y, cx + 240, base_y + 8], radius=4, fill=(105, 105, 112))
    # Horn right
    horn_pts = [
        (cx + 240, base_y),
        (cx + 300, base_y + 10),
        (cx + 240, base_y + 30),
    ]
    d.polygon(horn_pts, fill=(85, 85, 92))
    # Horn left (heel)
    heel_pts = [
        (cx - 240, base_y),
        (cx - 290, base_y + 12),
        (cx - 240, base_y + 30),
    ]
    d.polygon(heel_pts, fill=(85, 85, 92))
    # Body
    d.rounded_rectangle([cx - 150, base_y + 30, cx + 150, base_y + 100], radius=6, fill=(65, 65, 72))
    # Base plate
    d.rounded_rectangle([cx - 190, base_y + 100, cx + 190, base_y + 125], radius=4, fill=(50, 50, 56))

    return apply_mask(img)


if __name__ == "__main__":
    concepts = [
        ("refined_3a_forge_clean.png", concept_3a, "Forge flame + terminal, clean anvil base"),
        ("refined_3b_forge_dramatic.png", concept_3b, "Dramatic flame with embers, dark mood"),
        ("refined_4a_modern_blue.png", concept_4a, "Clean terminal on indigo gradient, faint anvil"),
        ("refined_4b_modern_warm.png", concept_4b, "Terminal with warm forge glow, amber accents"),
    ]

    for filename, func, desc in concepts:
        print(f"Generating {filename}: {desc}")
        icon = func()
        path = os.path.join(OUT_DIR, filename)
        icon.save(path, "PNG")
        print(f"  Saved: {path}")

    print("\nDone!")
