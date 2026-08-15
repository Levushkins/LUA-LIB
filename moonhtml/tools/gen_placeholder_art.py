#!/usr/bin/env python3
"""Generate the placeholder art used by examples/shop.

These are stand-ins for real artwork: abstract shapes, no licensing worries.
Drop your own PNGs over them and the markup does not change.

    python3 tools/gen_placeholder_art.py
"""
import os
import math
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "examples", "shop", "art")
os.makedirs(os.path.abspath(OUT), exist_ok=True)
SS = 4  # supersampling factor for smooth edges


def canvas(w, h):
    img = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save(img, name, size):
    img.resize(size, Image.LANCZOS).save(os.path.join(OUT, name))


def s(*vals):
    return [v * SS for v in vals]


def banknote(d, x, y, w, h, tone=(214, 184, 140)):
    d.rounded_rectangle(s(x, y, x + w, y + h), radius=3 * SS,
                        fill=tone + (255,), outline=(120, 96, 64, 255), width=SS)
    d.ellipse(s(x + w / 2 - 7, y + h / 2 - 7, x + w / 2 + 7, y + h / 2 + 7),
              fill=(150, 120, 82, 255))
    d.rectangle(s(x + 5, y + 4, x + w - 5, y + 6), fill=(160, 130, 90, 255))
    d.rectangle(s(x + 5, y + h - 6, x + w - 5, y + h - 4), fill=(160, 130, 90, 255))


# ---------------------------------------------------------------- products --

img, d = canvas(220, 150)
for i, (x, y, ang) in enumerate([(20, 70, 0), (70, 90, 0), (120, 66, 0),
                                 (46, 40, 0), (104, 30, 0), (150, 96, 0)]):
    banknote(d, x, y, 62, 38, (216, 186, 142) if i % 2 else (203, 170, 126))
save(img, "money.png", (220, 150))

img, d = canvas(220, 150)
d.rounded_rectangle(s(30, 44, 190, 132), radius=6 * SS, fill=(30, 32, 36, 255),
                    outline=(70, 74, 82, 255), width=SS)
d.rounded_rectangle(s(36, 50, 184, 126), radius=4 * SS, fill=(22, 24, 27, 255))
for row in range(2):
    for col in range(3):
        banknote(d, 44 + col * 48, 58 + row * 36, 42, 28)
d.rounded_rectangle(s(92, 30, 128, 46), radius=4 * SS, fill=(0, 0, 0, 0),
                    outline=(90, 95, 104, 255), width=2 * SS)
save(img, "case.png", (220, 150))

img, d = canvas(220, 150)
for cx, cy, r in [(70, 92, 34), (120, 74, 30), (152, 100, 26), (96, 46, 24)]:
    d.ellipse(s(cx - r, cy - r * 0.86, cx + r, cy + r * 0.86),
              fill=(240, 186, 62, 255), outline=(178, 128, 26, 255), width=SS)
    d.ellipse(s(cx - r * 0.62, cy - r * 0.54, cx + r * 0.62, cy + r * 0.54),
              fill=(252, 214, 108, 255))
save(img, "coins.png", (220, 150))

img, d = canvas(220, 150)
d.rounded_rectangle(s(24, 34, 196, 76), radius=8 * SS, fill=(246, 246, 248, 255))
d.polygon(s(96, 76, 118, 76, 100, 96), fill=(246, 246, 248, 255))
d.rounded_rectangle(s(40, 96, 180, 132), radius=6 * SS, fill=(126, 92, 58, 255))
for i in range(3):
    d.ellipse(s(52 + i * 46, 104, 82 + i * 46, 128), fill=(58, 60, 66, 255))
save(img, "deal.png", (220, 150))

# ------------------------------------------------------------------- icons --

ICONS = {
    "home": ((88, 148, 232), "house"),
    "sale": ((242, 140, 48), "tag"),
    "box": ((240, 196, 72), "box"),
    "vip": ((236, 176, 60), "crown"),
    "skins": ((196, 132, 220), "person"),
    "acc": ((120, 200, 180), "cap"),
    "car": ((92, 166, 240), "car"),
    "tuning": ((228, 108, 96), "gear"),
    "guard": ((150, 158, 172), "shield"),
    "other": ((200, 176, 120), "dots"),
}

for name, (tint, kind) in ICONS.items():
    img, d = canvas(56, 44)
    base = tint + (255,)
    dark = tuple(int(c * 0.65) for c in tint) + (255,)
    if kind == "house":
        d.polygon(s(28, 8, 50, 24, 6, 24), fill=base)
        d.rounded_rectangle(s(12, 24, 44, 40), radius=2 * SS, fill=dark)
        d.rectangle(s(23, 28, 33, 40), fill=base)
    elif kind == "tag":
        d.rounded_rectangle(s(10, 10, 46, 36), radius=6 * SS, fill=base)
        d.ellipse(s(16, 16, 26, 26), fill=dark)
        d.ellipse(s(30, 24, 40, 34), fill=dark)
        d.line(s(18, 32, 38, 14), fill=dark, width=3 * SS)
    elif kind == "box":
        d.rounded_rectangle(s(8, 16, 48, 40), radius=3 * SS, fill=base)
        d.rectangle(s(8, 16, 48, 22), fill=dark)
        d.rectangle(s(25, 16, 31, 40), fill=dark)
    elif kind == "crown":
        d.polygon(s(10, 34, 14, 12, 24, 24, 28, 10, 32, 24, 42, 12, 46, 34), fill=base)
        d.rectangle(s(10, 34, 46, 40), fill=dark)
    elif kind == "person":
        d.ellipse(s(20, 8, 36, 24), fill=base)
        d.rounded_rectangle(s(12, 26, 44, 42), radius=6 * SS, fill=dark)
    elif kind == "cap":
        d.pieslice(s(10, 12, 46, 46), 180, 360, fill=base)
        d.rounded_rectangle(s(6, 28, 50, 34), radius=3 * SS, fill=dark)
    elif kind == "car":
        d.rounded_rectangle(s(6, 22, 50, 34), radius=5 * SS, fill=base)
        d.polygon(s(14, 22, 20, 12, 38, 12, 44, 22), fill=dark)
        d.ellipse(s(12, 30, 22, 40), fill=(34, 36, 40, 255))
        d.ellipse(s(34, 30, 44, 40), fill=(34, 36, 40, 255))
    elif kind == "gear":
        d.ellipse(s(12, 8, 44, 40), fill=base)
        d.ellipse(s(21, 17, 35, 31), fill=(26, 28, 32, 255))
        for k in range(8):
            a = k * math.pi / 4
            cx, cy = 28 + 18 * math.cos(a), 24 + 18 * math.sin(a)
            d.ellipse(s(cx - 4, cy - 4, cx + 4, cy + 4), fill=dark)
    elif kind == "shield":
        d.polygon(s(28, 6, 46, 14, 42, 34, 28, 42, 14, 34, 10, 14), fill=base)
        d.polygon(s(28, 14, 38, 18, 35, 30, 28, 34, 21, 30, 18, 18), fill=dark)
    else:
        for k in range(3):
            d.ellipse(s(10 + k * 14, 18, 22 + k * 14, 30), fill=base if k % 2 else dark)
    save(img, "icon-%s.png" % name, (56, 44))

print("wrote placeholder art to", os.path.abspath(OUT))
