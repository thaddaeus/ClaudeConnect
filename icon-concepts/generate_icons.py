#!/usr/bin/env python3
"""Generate ConsoleForge app icon concepts at 1024x1024."""

from PIL import Image, ImageDraw, ImageFont
import math
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024
CORNER = 220  # macOS icon corner radius at 1024px


def rounded_rect_mask(size, radius):
    """Create a rounded rectangle mask for macOS icon shape."""
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def apply_mask(img):
    mask = rounded_rect_mask(SIZE, CORNER)
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    result.paste(img, mask=mask)
    return result


def draw_anvil(d, cx, cy, scale=1.0):
    """Draw a stylized anvil shape."""
    s = scale
    # Anvil body - flat top, tapered base
    points = [
        (cx - 120*s, cy - 30*s),   # top left
        (cx + 140*s, cy - 30*s),   # top right (horn extends right)
        (cx + 180*s, cy - 10*s),   # horn tip
        (cx + 140*s, cy + 10*s),   # horn bottom
        (cx + 80*s, cy + 10*s),    # body right
        (cx + 60*s, cy + 80*s),    # base right
        (cx - 60*s, cy + 80*s),    # base left
        (cx - 80*s, cy + 10*s),    # body left
        (cx - 120*s, cy + 10*s),   # heel bottom
        (cx - 160*s, cy - 10*s),   # heel tip
    ]
    d.polygon(points, fill="#8A8A8E")
    # Top surface highlight
    top_points = [
        (cx - 120*s, cy - 30*s),
        (cx + 140*s, cy - 30*s),
        (cx + 140*s, cy - 15*s),
        (cx - 120*s, cy - 15*s),
    ]
    d.polygon(top_points, fill="#A0A0A5")


def draw_terminal_prompt(d, x, y, size, color="#00FF88"):
    """Draw a > _ terminal prompt."""
    thick = max(4, int(size * 0.08))
    # >
    chevron_pts = [
        (x, y),
        (x + size * 0.3, y + size * 0.2),
        (x, y + size * 0.4),
    ]
    d.line(chevron_pts, fill=color, width=thick, joint="curve")
    # _
    ux = x + size * 0.38
    uy = y + size * 0.35
    d.line([(ux, uy), (ux + size * 0.25, uy)], fill=color, width=thick)


# ─────────────────────────────────────────────
# Concept 1: Terminal window on an anvil
# Dark terminal window sitting on a metallic anvil
# ─────────────────────────────────────────────
def concept_1():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Background gradient (dark blue-gray)
    for y in range(SIZE):
        t = y / SIZE
        r = int(25 + t * 15)
        g = int(28 + t * 18)
        b = int(45 + t * 25)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    # Anvil at bottom
    draw_anvil(d, 512, 680, scale=2.8)

    # Terminal window
    tw, th = 560, 380
    tx, ty = (SIZE - tw) // 2, 140
    # Window shadow
    d.rounded_rectangle([tx+8, ty+8, tx+tw+8, ty+th+8], radius=20, fill=(0, 0, 0, 100))
    # Window body
    d.rounded_rectangle([tx, ty, tx+tw, ty+th], radius=20, fill=(30, 33, 46, 255))
    # Title bar
    d.rounded_rectangle([tx, ty, tx+tw, ty+36], radius=20, fill=(45, 48, 65, 255))
    d.rectangle([tx, ty+20, tx+tw, ty+36], fill=(45, 48, 65, 255))
    # Traffic lights
    d.ellipse([tx+16, ty+10, tx+28, ty+22], fill="#FF5F56")
    d.ellipse([tx+34, ty+10, tx+46, ty+22], fill="#FFBD2E")
    d.ellipse([tx+52, ty+10, tx+64, ty+22], fill="#27C93F")

    # Terminal content
    draw_terminal_prompt(d, tx + 40, ty + 60, 280, "#00FF88")
    # Second line - dimmer
    draw_terminal_prompt(d, tx + 40, ty + 140, 280, "#00CC66")
    # Cursor block
    d.rectangle([tx + 40 + 280*0.38, ty + 220, tx + 40 + 280*0.38 + 16, ty + 250], fill="#00FF88")

    # Sparks near anvil
    spark_color = (255, 165, 0, 200)
    for angle_deg in [-60, -30, 0, 20, 50]:
        angle = math.radians(angle_deg)
        for dist in [40, 70, 100]:
            sx = int(512 + math.cos(angle) * dist * 2)
            sy = int(600 + math.sin(angle) * dist - 60)
            size = max(3, 8 - dist // 20)
            d.ellipse([sx-size, sy-size, sx+size, sy+size], fill=spark_color)

    return apply_mask(img)


# ─────────────────────────────────────────────
# Concept 2: Hammer striking a terminal cursor
# Minimalist — forge hammer coming down on a glowing cursor
# ─────────────────────────────────────────────
def concept_2():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Background gradient (deep indigo to dark)
    for y in range(SIZE):
        t = y / SIZE
        r = int(20 + t * 10)
        g = int(15 + t * 15)
        b = int(50 + t * 20)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    # Glowing cursor/block at center-bottom — the thing being "forged"
    cx, cy = 512, 580
    # Glow
    for radius in range(80, 0, -2):
        alpha = int(60 * (1 - radius / 80))
        glow_color = (255, 140, 0, alpha)
        d.ellipse([cx-radius, cy-radius//2, cx+radius, cy+radius//2], fill=glow_color)
    # The cursor block itself (hot metal orange)
    bw, bh = 60, 80
    d.rectangle([cx-bw//2, cy-bh//2, cx+bw//2, cy+bh//2], fill="#FF6600")
    d.rectangle([cx-bw//2+4, cy-bh//2+4, cx+bw//2-4, cy+bh//2-4], fill="#FF9933")

    # Hammer coming from upper-right
    # Handle
    hx1, hy1 = 700, 100  # grip end
    hx2, hy2 = 560, 420  # near head
    d.line([(hx1, hy1), (hx2, hy2)], fill="#8B6914", width=28)
    d.line([(hx1+2, hy1+2), (hx2+2, hy2+2)], fill="#A07828", width=22)

    # Hammer head (rotated rectangle)
    head_cx, head_cy = 540, 440
    hw, hh = 140, 70
    angle = -35
    cos_a = math.cos(math.radians(angle))
    sin_a = math.sin(math.radians(angle))
    corners = []
    for dx, dy in [(-hw//2, -hh//2), (hw//2, -hh//2), (hw//2, hh//2), (-hw//2, hh//2)]:
        rx = head_cx + dx * cos_a - dy * sin_a
        ry = head_cy + dx * sin_a + dy * cos_a
        corners.append((rx, ry))
    d.polygon(corners, fill="#666670")
    # Highlight on head
    highlight_corners = []
    for dx, dy in [(-hw//2+5, -hh//2+5), (hw//2-5, -hh//2+5), (hw//2-5, -hh//2+20), (-hw//2+5, -hh//2+20)]:
        rx = head_cx + dx * cos_a - dy * sin_a
        ry = head_cy + dx * sin_a + dy * cos_a
        highlight_corners.append((rx, ry))
    d.polygon(highlight_corners, fill="#7A7A82")

    # Terminal prompt text above
    draw_terminal_prompt(d, 200, 180, 400, "#00FFAA")

    # Sparks from impact point
    for angle_deg in range(-150, 30, 15):
        angle = math.radians(angle_deg)
        for dist in [30, 55, 85, 120]:
            sx = int(cx + math.cos(angle) * dist * 1.5)
            sy = int(cy - 30 + math.sin(angle) * dist)
            size = max(2, 7 - dist // 25)
            alpha = max(50, 255 - dist * 2)
            d.ellipse([sx-size, sy-size, sx+size, sy+size], fill=(255, 200, 50, alpha))

    return apply_mask(img)


# ─────────────────────────────────────────────
# Concept 3: Forge flame with terminal brackets
# A stylized flame/forge with </> code symbol inside
# ─────────────────────────────────────────────
def concept_3():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Background (very dark with warm tint)
    for y in range(SIZE):
        t = y / SIZE
        r = int(30 + t * 20)
        g = int(18 + t * 12)
        b = int(18 + t * 8)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Forge/flame shape — layered teardrop flames
    flame_layers = [
        (280, 500, (255, 60, 0, 40)),    # outer glow - red
        (220, 440, (255, 100, 0, 60)),   # mid glow - orange
        (170, 380, (255, 140, 0, 80)),   # inner glow
        (130, 320, (255, 180, 20, 120)), # hot core
        (90, 260, (255, 220, 80, 160)),  # white-hot center
    ]
    for w, h, color in flame_layers:
        # Flame shape: wide at bottom, pointed at top
        for row in range(h):
            t = row / h  # 0=top, 1=bottom
            # Width increases toward bottom
            row_w = int(w * (0.1 + 0.9 * t * t))
            y_pos = int(200 + row * 1.4)
            alpha = color[3]
            d.line([(cx - row_w, y_pos), (cx + row_w, y_pos)],
                   fill=(color[0], color[1], color[2], alpha))

    # Terminal window inside the flame
    tw, th = 360, 280
    tx, ty = (SIZE - tw) // 2, 360
    # Window body (semi-transparent dark)
    d.rounded_rectangle([tx, ty, tx+tw, ty+th], radius=16, fill=(20, 22, 35, 220))
    # Title bar
    d.rounded_rectangle([tx, ty, tx+tw, ty+30], radius=16, fill=(40, 42, 58, 240))
    d.rectangle([tx, ty+16, tx+tw, ty+30], fill=(40, 42, 58, 240))
    # Traffic lights
    d.ellipse([tx+12, ty+8, tx+22, ty+18], fill="#FF5F56")
    d.ellipse([tx+28, ty+8, tx+38, ty+18], fill="#FFBD2E")
    d.ellipse([tx+44, ty+8, tx+54, ty+18], fill="#27C93F")

    # Prompt inside
    draw_terminal_prompt(d, tx + 30, ty + 50, 200, "#00FF88")

    # Cursor
    d.rectangle([tx + 30 + 200*0.38 + 10, ty + 120, tx + 30 + 200*0.38 + 26, ty + 148], fill=(0, 255, 136, 200))

    # Anvil base at very bottom
    base_y = 720
    d.rounded_rectangle([cx-200, base_y, cx+200, base_y+80], radius=10, fill="#5A5A5E")
    d.rounded_rectangle([cx-140, base_y+80, cx+140, base_y+140], radius=8, fill="#48484C")

    return apply_mask(img)


# ─────────────────────────────────────────────
# Concept 4: Clean/modern — anvil silhouette with
# terminal prompt, gradient background
# ─────────────────────────────────────────────
def concept_4():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Gradient background (teal-blue)
    for y in range(SIZE):
        t = y / SIZE
        r = int(0 + t * 20)
        g = int(120 - t * 40)
        b = int(200 - t * 30)
        d.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

    cx = 512

    # Large anvil silhouette (white/light)
    s = 3.0
    cy = 520
    anvil_pts = [
        (cx - 130*s, cy - 35*s),
        (cx + 130*s, cy - 35*s),
        (cx + 170*s, cy - 15*s),
        (cx + 130*s, cy + 5*s),
        (cx + 70*s, cy + 5*s),
        (cx + 55*s, cy + 70*s),
        (cx - 55*s, cy + 70*s),
        (cx - 70*s, cy + 5*s),
        (cx - 130*s, cy + 5*s),
        (cx - 170*s, cy - 15*s),
    ]
    d.polygon(anvil_pts, fill=(255, 255, 255, 40))

    # Terminal window (centered, prominent)
    tw, th = 520, 360
    tx, ty = (SIZE - tw) // 2, 200
    # Shadow
    d.rounded_rectangle([tx+6, ty+6, tx+tw+6, ty+th+6], radius=24, fill=(0, 0, 0, 60))
    # Window
    d.rounded_rectangle([tx, ty, tx+tw, ty+th], radius=24, fill=(22, 25, 40, 240))
    # Title bar
    d.rounded_rectangle([tx, ty, tx+tw, ty+38], radius=24, fill=(35, 38, 55, 255))
    d.rectangle([tx, ty+24, tx+tw, ty+38], fill=(35, 38, 55, 255))
    # Traffic lights
    d.ellipse([tx+18, ty+11, tx+30, ty+23], fill="#FF5F56")
    d.ellipse([tx+38, ty+11, tx+50, ty+23], fill="#FFBD2E")
    d.ellipse([tx+58, ty+11, tx+70, ty+23], fill="#27C93F")

    # Terminal content - multiple lines
    draw_terminal_prompt(d, tx + 40, ty + 60, 300, "#00FFAA")
    # Second line
    thick = 6
    d.line([(tx+40, ty+155), (tx+200, ty+155)], fill=(0, 255, 170, 100), width=thick)
    d.line([(tx+210, ty+155), (tx+350, ty+155)], fill=(0, 255, 170, 60), width=thick)
    # Third line
    draw_terminal_prompt(d, tx + 40, ty + 190, 300, "#00FFAA")
    # Cursor
    d.rectangle([tx + 40 + 300*0.38, ty + 270, tx + 40 + 300*0.38 + 18, ty + 300], fill="#00FFAA")

    return apply_mask(img)


if __name__ == "__main__":
    concepts = [
        ("concept1_anvil_terminal.png", concept_1, "Terminal window on anvil with sparks"),
        ("concept2_hammer_cursor.png", concept_2, "Hammer striking a glowing cursor"),
        ("concept3_forge_flame.png", concept_3, "Terminal inside forge flame"),
        ("concept4_clean_modern.png", concept_4, "Clean terminal with anvil silhouette"),
    ]

    for filename, func, desc in concepts:
        print(f"Generating {filename}: {desc}")
        icon = func()
        path = os.path.join(OUT_DIR, filename)
        icon.save(path, "PNG")
        print(f"  Saved: {path}")

    print("\nDone! Review the concepts in icon-concepts/")
