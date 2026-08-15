#!/usr/bin/env python3
"""Rasterise a moonhtml display list (JSON) into a PNG.

This mirrors what backends/mimgui.lua does with an ImDrawList, so the picture
is a faithful preview of what the game will show.

    python3 tools/render_png.py snapshot.json preview.png
"""
import json
import sys
from PIL import Image, ImageDraw, ImageFont

FONTS = {
    ("default", "normal"): "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ("default", "bold"): "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ("mono", "normal"): "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    ("mono", "bold"): "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
}
_font_cache = {}


def font_for(family, weight, size):
    weight = "bold" if weight in ("bold", "bolder") or (
        weight.isdigit() and int(weight) >= 600) else "normal"
    family = family if family in ("mono",) else "default"
    key = (family, weight, round(size))
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(FONTS[(family, weight)], round(size))
    return _font_cache[key]


def rgba(col, alpha=1.0):
    if not col:
        return (0, 0, 0, 0)
    r, g, b = [int(max(0, min(255, round(c)))) for c in col[:3]]
    a = col[3] if len(col) > 3 else 1.0
    return (r, g, b, int(max(0, min(255, round(a * alpha * 255)))))


def radius_of(cmd):
    r = cmd.get("radius")
    if not r:
        return 0
    return max(r)


def mix(c1, c2, t):
    return [c1[i] + (c2[i] - c1[i]) * t for i in range(4)]


def color_at(stops, t, flip):
    if flip:
        t = 1 - t
    prev = stops[0]
    for i in range(1, len(stops)):
        s = stops[i]
        if t <= s["pos"] or i == len(stops) - 1:
            span = s["pos"] - prev["pos"]
            k = 0 if span <= 0 else max(0.0, min(1.0, (t - prev["pos"]) / span))
            return mix(prev["color"], s["color"], k)
        prev = s
    return stops[-1]["color"]


def render(data, out_path, scale=2):
    W, H = int(data["width"]), int(data["height"])
    img = Image.new("RGBA", (W * scale, H * scale), (24, 26, 31, 255))
    clip_stack = []

    def current_clip():
        if not clip_stack:
            return None
        x0 = max(c[0] for c in clip_stack)
        y0 = max(c[1] for c in clip_stack)
        x1 = min(c[2] for c in clip_stack)
        y1 = min(c[3] for c in clip_stack)
        return (x0, y0, x1, y1)

    def composite(layer):
        clip = current_clip()
        if clip:
            x0, y0, x1, y1 = [int(v * scale) for v in clip]
            mask = Image.new("L", layer.size, 0)
            ImageDraw.Draw(mask).rectangle([x0, y0, max(x0, x1), max(y0, y1)], fill=255)
            layer.putalpha(Image.composite(layer.getchannel("A"), mask, mask))
        img.alpha_composite(layer)

    def new_layer():
        return Image.new("RGBA", img.size, (0, 0, 0, 0))

    for cmd in data["commands"]:
        op = cmd["op"]
        alpha = cmd.get("alpha", 1.0)

        if op == "clip":
            clip_stack.append((cmd["x"], cmd["y"], cmd["x"] + cmd["w"], cmd["y"] + cmd["h"]))
        elif op == "unclip":
            if clip_stack:
                clip_stack.pop()
        elif op == "rect":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            x, y, w, h = cmd["x"], cmd["y"], cmd["w"], cmd["h"]
            box = [x * scale, y * scale, (x + w) * scale, (y + h) * scale]
            r = radius_of(cmd) * scale
            if r > 0.5:
                d.rounded_rectangle(box, radius=min(r, min(w, h) * scale / 2),
                                    fill=rgba(cmd["color"], alpha))
            else:
                d.rectangle(box, fill=rgba(cmd["color"], alpha))
            composite(layer)
        elif op == "gradient":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            x, y, w, h = cmd["x"], cmd["y"], cmd["w"], cmd["h"]
            angle = cmd.get("angle", 180) % 360
            horizontal = (45 <= angle < 135) or (225 <= angle < 315)
            flip = (angle < 45 or angle >= 315) or (225 <= angle < 315)
            stops = cmd["stops"]
            bands = 48
            r = radius_of(cmd) * scale
            base = Image.new("RGBA", img.size, (0, 0, 0, 0))
            bd = ImageDraw.Draw(base)
            for i in range(bands):
                t0, t1 = i / bands, (i + 1) / bands
                col = rgba(color_at(stops, (t0 + t1) / 2, flip), alpha)
                if horizontal:
                    bd.rectangle([(x + w * t0) * scale, y * scale,
                                  (x + w * t1) * scale + 1, (y + h) * scale], fill=col)
                else:
                    bd.rectangle([x * scale, (y + h * t0) * scale,
                                  (x + w) * scale, (y + h * t1) * scale + 1], fill=col)
            if r > 0.5:
                mask = Image.new("L", img.size, 0)
                ImageDraw.Draw(mask).rounded_rectangle(
                    [x * scale, y * scale, (x + w) * scale, (y + h) * scale],
                    radius=min(r, min(w, h) * scale / 2), fill=255)
                base.putalpha(Image.composite(base.getchannel("A"), mask, mask))
            layer.alpha_composite(base)
            composite(layer)
        elif op == "border":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            x, y, w, h = cmd["x"], cmd["y"], cmd["w"], cmd["h"]
            widths = cmd["widths"]
            colors = cmd["colors"]
            r = radius_of(cmd) * scale
            uniform = len(set(widths)) == 1 and all(
                colors[0] == c for c in colors)
            if uniform and widths[0] > 0:
                inset = widths[0] * scale / 2
                box = [x * scale + inset, y * scale + inset,
                       (x + w) * scale - inset, (y + h) * scale - inset]
                if r > 0.5:
                    d.rounded_rectangle(box, radius=min(r, min(w, h) * scale / 2),
                                        outline=rgba(colors[0], alpha),
                                        width=max(1, round(widths[0] * scale)))
                else:
                    d.rectangle(box, outline=rgba(colors[0], alpha),
                                width=max(1, round(widths[0] * scale)))
            else:
                if widths[0] > 0:
                    d.rectangle([x * scale, y * scale, (x + w) * scale,
                                 (y + widths[0]) * scale], fill=rgba(colors[0], alpha))
                if widths[2] > 0:
                    d.rectangle([x * scale, (y + h - widths[2]) * scale,
                                 (x + w) * scale, (y + h) * scale], fill=rgba(colors[2], alpha))
                if widths[3] > 0:
                    d.rectangle([x * scale, y * scale, (x + widths[3]) * scale,
                                 (y + h) * scale], fill=rgba(colors[3], alpha))
                if widths[1] > 0:
                    d.rectangle([(x + w - widths[1]) * scale, y * scale,
                                 (x + w) * scale, (y + h) * scale], fill=rgba(colors[1], alpha))
            composite(layer)
        elif op == "text" or (op == "native" and cmd.get("text")):
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            size = cmd.get("fontSize", 14) * scale
            font = font_for(cmd.get("fontFamily", "default"),
                            cmd.get("fontWeight", "normal"), size)
            y = cmd["y"] * scale
            if op == "native":
                y = (cmd["y"] + (cmd.get("h", size) - cmd.get("fontSize", 14)) / 2) * scale
            d.text((cmd["x"] * scale, y), cmd.get("text", ""),
                   font=font, fill=rgba(cmd["color"], alpha), anchor="la")
            composite(layer)
        elif op == "line":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            d.line([cmd["x1"] * scale, cmd["y1"] * scale,
                    cmd["x2"] * scale, cmd["y2"] * scale],
                   fill=rgba(cmd["color"], alpha),
                   width=max(1, round(cmd.get("thickness", 1) * scale)))
            composite(layer)
        elif op == "circle":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            cx, cy, r = cmd["cx"] * scale, cmd["cy"] * scale, cmd["r"] * scale
            box = [cx - r, cy - r, cx + r, cy + r]
            if cmd.get("filled", True):
                d.ellipse(box, fill=rgba(cmd["color"], alpha))
            else:
                d.ellipse(box, outline=rgba(cmd["color"], alpha))
            composite(layer)
        elif op == "triangle":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            p = [v * scale for v in cmd["points"]]
            d.polygon([(p[0], p[1]), (p[2], p[3]), (p[4], p[5])],
                      fill=rgba(cmd["color"], alpha))
            composite(layer)
        elif op == "image":
            layer = new_layer()
            d = ImageDraw.Draw(layer)
            d.rectangle([cmd["x"] * scale, cmd["y"] * scale,
                         (cmd["x"] + cmd["w"]) * scale, (cmd["y"] + cmd["h"]) * scale],
                        fill=(90, 90, 90, int(90 * alpha)))
            composite(layer)

    img.convert("RGB").save(out_path)
    print("wrote", out_path, img.size)


if __name__ == "__main__":
    src = sys.argv[1] if len(sys.argv) > 1 else "snapshot.json"
    dst = sys.argv[2] if len(sys.argv) > 2 else "preview.png"
    with open(src) as fh:
        render(json.load(fh), dst)
