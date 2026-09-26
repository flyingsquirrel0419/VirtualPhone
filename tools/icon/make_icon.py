#!/usr/bin/env python3
"""Renders VirtualPhone's app icon: a phone inside a phone, original artwork.

    python3 tools/icon/make_icon.py   -> app/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png

Drawn with Pillow at 4x and downsampled for smooth edges. iOS applies the
rounded mask itself, so the square is filled edge to edge.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "app/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
S = 4096  # 4x supersampling


def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.resize((size, size))


def phone(draw, box, radius, body, screen, bezel):
    x0, y0, x1, y1 = box
    draw.rounded_rectangle(box, radius=radius, fill=body)
    draw.rounded_rectangle((x0 + bezel, y0 + bezel, x1 - bezel, y1 - bezel), radius=radius - bezel, fill=screen)


def main():
    img = gradient(S, (38, 44, 92), (14, 16, 36))
    shadow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((1310, 700, 2850, 3500), radius=300, fill=160)
    img.paste((0, 0, 0), mask=shadow.filter(ImageFilter.GaussianBlur(90)))

    d = ImageDraw.Draw(img)
    # Outer (host) phone.
    phone(d, (1250, 600, 2846, 3496), 300, (226, 230, 245), (24, 28, 58), 70)
    # Inner (guest) phone, glowing.
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).rounded_rectangle((1640, 1180, 2456, 2716), radius=170, fill=255)
    img.paste((90, 200, 255), mask=glow.filter(ImageFilter.GaussianBlur(70)).point(lambda v: v * 0.55))
    d = ImageDraw.Draw(img)
    phone(d, (1680, 1220, 2416, 2676), 150, (120, 214, 255), (10, 22, 48), 34)
    # A few "icons" on the guest screen.
    cols, rows, cell, pad = 3, 4, 150, 62
    gx0 = 1680 + 34 + (736 - 68 - cols * cell - (cols - 1) * pad) // 2
    gy0 = 1220 + 34 + 110
    palette = [(255, 159, 67), (84, 219, 132), (255, 99, 132), (132, 146, 255), (255, 211, 92), (90, 200, 255)]
    for r in range(rows):
        for c in range(cols):
            x = gx0 + c * (cell + pad)
            y = gy0 + r * (cell + pad)
            d.rounded_rectangle((x, y, x + cell, y + cell), radius=38, fill=palette[(r * cols + c) % len(palette)])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.resize((1024, 1024), Image.LANCZOS).save(OUT, optimize=True)
    print(OUT)


if __name__ == "__main__":
    main()
