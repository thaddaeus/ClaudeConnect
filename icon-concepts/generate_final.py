#!/usr/bin/env python3
"""Final icon concepts — 4A light mode, 4B dark mode, polished."""

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


def draw_terminal_window(d, tx, ty, tw, th, radius=22, body_color=(22, 24, 38), bar_color=(38, 40, 58), opacity=245):
    """Draw a macOS-style terminal window."""
    bc = (*body_color, opacity)
    brc = (*bar_color, min(255, opacity + 10))
    d.rounded_rectangle([tx, ty, tx+tw, ty+th], radius=radius, fill=bc)
    bar_h = int(th * 0.085)
    d.rounded_rectangle([tx, ty, tx+tw, ty+bar_h+10], radius=radius, fill=brc)
    d.rectangle([tx, ty+bar_h, tx+tw, ty+bar_h+10], fill=brc)
    dot_r = max(4, int(th * 0.018))
    dot_y = ty + bar_h // 2 + 2
    dot_x = tx + int(tw * 0.035)
    gap = int(dot_r * 2.4)
    d.ellipse([dot_x, dot_y-dot_r, dot_x+dot_r*2, dot_y+dot_r], fill="#FF5F56")
    d.ellipse([dot_x+gap, dot_y-dot_r, dot_x+gap+dot_r*2, dot_y+dot_r], fill="#FFBD2E")
    d.ellipse([dot_x+gap*2, dot_y-dot_r, dot_x+gap*2+dot_r*2, dot_y+dot_r], fill="#27C93F")
    return bar_h + 10


def draw_prompt_line(d, x, y, scale=1.0, color=(0, 255, 170), alpha=255):
    thick = max(3, int(8 * scale))
    s = scale
    c = (*color, alpha)
    d.line([(x, y), (x + 40*s, y + 25*s), (x, y + 50*s)], fill=c, width=thick, joint="curve")
    d.line([(x + 55*s, y + 42*s), (x + 100*s, y + 42*s)], fill=c, width=thick)


def draw_cursor_block(d, x, y, w, h, color=(0, 255, 170)):
    d.rectangle([x, y, x+w, y+h], fill=(*color, 220))


def draw_anvil_silhouette(img, cx, cy, scale, color, blur=8):
    """Draw a blurred anvil silhouette on a separate layer."""
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    s = scale
    pts = [
        (cx - 130*s, cy - 35*s),
        (cx + 130*s, cy - 35*s),
        (cx + 165*s, cy - 15*s),
        (cx + 130*s, cy + 5*s),
        (cx + 70*s, cy + 5*s),
        (cx + 55*s, cy + 70*s),
        (cx - 55*s, cy + 70*s),
        (cx - 70*s, cy + 5*s),
        (cx - 130*s, cy + 5*s),
        (cx - 165*s, cy - 15*s),
    ]
    ld.polygon(pts, fill=color)
    if blur > 0:
        layer = layer.filter(ImageFilter.GaussianBlur(radius=blur))
    return Image.alpha_composite(img, layer)


def draw_shadow(img, tx, ty, tw, th, radius=24):
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle([tx+8, ty+12, tx+tw+8, ty+th+12], radius=radius, fill=(0, 0, 0, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=12))
    return Image.alpha_composite(img, shadow)


# ─────────────────────────────────────────────
# 4A Light Mode — bright indigo/blue gradient,
# dark terminal, teal-green accents
# ─────────────────────────────────────────────
def icon_light():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Bright gradient (light indigo to blue)
    for y in range(SIZE):
        t = y / SIZE
        r = int(55 - t * 15)
        g = int(70 + t * 20)
        b = int(210 - t * 30)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Subtle anvil silhouette
    img = draw_anvil_silhouette(img, cx, 560, 2.8, (255, 255, 255, 18), blur=10)
    d = ImageDraw.Draw(img)

    # Terminal window
    tw, th = 540, 380
    tx, ty = (SIZE - tw) // 2, 220

    img = draw_shadow(img, tx, ty, tw, th)
    d = ImageDraw.Draw(img)

    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=24)

    # Content — teal-green accent
    accent = (0, 255, 170)
    draw_prompt_line(d, tx + 40, ty + bar_h + 25, scale=1.4, color=accent)
    thick = 5
    d.line([(tx+40, ty+bar_h+100), (tx+240, ty+bar_h+100)], fill=(*accent, 70), width=thick)
    d.line([(tx+250, ty+bar_h+100), (tx+400, ty+bar_h+100)], fill=(*accent, 40), width=thick)
    d.line([(tx+40, ty+bar_h+128), (tx+180, ty+bar_h+128)], fill=(*accent, 50), width=thick)
    d.line([(tx+190, ty+bar_h+128), (tx+320, ty+bar_h+128)], fill=(*accent, 30), width=thick)
    draw_prompt_line(d, tx + 40, ty + bar_h + 170, scale=1.4, color=accent)
    draw_cursor_block(d, tx + 40 + 150, ty + bar_h + 180, 16, 30, accent)

    return apply_mask(img)


# ─────────────────────────────────────────────
# 4B Dark Mode — dark background, warm forge
# glow, amber accents, anvil details
# ─────────────────────────────────────────────
def icon_dark():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Dark gradient with warm undertone
    for y in range(SIZE):
        t = y / SIZE
        r = int(28 + t * 22)
        g = int(22 + t * 14)
        b = int(38 + t * 10)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Warm forge glow behind terminal
    glow_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow_layer)
    for r in range(320, 0, -3):
        alpha = int(28 * (1 - r / 320))
        gd.ellipse([cx-r, 380-r//2, cx+r, 380+r//2], fill=(255, 110, 15, alpha))
    glow_layer = glow_layer.filter(ImageFilter.GaussianBlur(radius=45))
    img = Image.alpha_composite(img, glow_layer)
    d = ImageDraw.Draw(img)

    # Terminal window
    tw, th = 500, 360
    tx, ty = (SIZE - tw) // 2, 200

    img = draw_shadow(img, tx, ty, tw, th, radius=22)
    d = ImageDraw.Draw(img)

    bar_h = draw_terminal_window(d, tx, ty, tw, th, radius=22, opacity=240)

    # Content — amber accent
    accent = (255, 170, 50)
    draw_prompt_line(d, tx + 40, ty + bar_h + 22, scale=1.3, color=accent)
    thick = 5
    d.line([(tx+40, ty+bar_h+95), (tx+220, ty+bar_h+95)], fill=(*accent, 60), width=thick)
    d.line([(tx+230, ty+bar_h+95), (tx+380, ty+bar_h+95)], fill=(*accent, 35), width=thick)
    d.line([(tx+40, ty+bar_h+120), (tx+160, ty+bar_h+120)], fill=(*accent, 45), width=thick)
    draw_prompt_line(d, tx + 40, ty + bar_h + 160, scale=1.3, color=accent)
    draw_cursor_block(d, tx + 40 + 140, ty + bar_h + 168, 14, 28, accent)

    # Anvil at bottom — geometric with horn details
    base_y = 650
    d.rounded_rectangle([cx - 240, base_y, cx + 240, base_y + 30], radius=4, fill=(85, 85, 92))
    d.rounded_rectangle([cx - 240, base_y, cx + 240, base_y + 8], radius=4, fill=(105, 105, 112))
    # Horn right
    d.polygon([(cx+240, base_y), (cx+300, base_y+10), (cx+240, base_y+30)], fill=(85, 85, 92))
    # Heel left
    d.polygon([(cx-240, base_y), (cx-290, base_y+12), (cx-240, base_y+30)], fill=(85, 85, 92))
    # Body
    d.rounded_rectangle([cx-150, base_y+30, cx+150, base_y+100], radius=6, fill=(65, 65, 72))
    # Base plate
    d.rounded_rectangle([cx-190, base_y+100, cx+190, base_y+125], radius=4, fill=(50, 50, 56))

    return apply_mask(img)


if __name__ == "__main__":
    pairs = [
        ("icon_light.png", icon_light, "4A Light mode — indigo gradient, teal accents"),
        ("icon_dark.png", icon_dark, "4B Dark mode — warm forge glow, amber accents"),
    ]

    for filename, func, desc in pairs:
        print(f"Generating {filename}: {desc}")
        icon = func()
        path = os.path.join(OUT_DIR, filename)
        icon.save(path, "PNG")
        print(f"  Saved: {path}")

    print("\nDone!")
