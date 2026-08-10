#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_emoji_atlas.py — рендерит смайлы из emoji.json в один цветной атлас
(PNG) и генерирует Lua-описание с координатами.

Зачем атлас, а не шрифт: mimgui собран со stb_truetype и 16-битным ImWchar,
поэтому он не умеет ни цветные глифы (COLR/CPAL, SVG), ни кодовые точки
выше U+FFFF. Смайлы же живут в U+1F300…U+1FAFF. Единственный рабочий путь —
заранее растеризовать их в текстуру и рисовать через imgui.Image.

Смайлы берутся из двух шрифтов:
  * icons.ttf   — распакован из _chat.asi, содержит серверные иконки
                  (U+F2xx/U+F3xx, U+1FCxx) и буквы-плашки U+1F1Ex
  * Segoe UI Emoji (seguiemj.ttf) — стандартные смайлы U+1F300+,
                  именно его использует сам чат

    python3 build_emoji_atlas.py ../data/emoji.json \
        --icons ../data/icons.ttf \
        --emoji "C:/Windows/Fonts/seguiemj.ttf" \
        -o ../assets

Требуется Pillow (pip install pillow).
"""

import argparse
import json
import os
import struct
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("нужен Pillow:  pip install pillow")


# --------------------------------------------------------------------------
# Разбор cmap — чтобы понять, какие кодовые точки есть в шрифте
# --------------------------------------------------------------------------

def font_codepoints(path):
    data = open(path, "rb").read()
    if data[:4] == b"ttcf":
        off = struct.unpack_from(">I", data, 12)[0]
    else:
        off = 0
    num_tables, = struct.unpack_from(">H", data, off + 4)
    cmap_off = None
    for i in range(num_tables):
        tag, _, toff, tlen = struct.unpack_from(">4sIII", data, off + 12 + i * 16)
        if tag == b"cmap":
            cmap_off = toff
            break
    if cmap_off is None:
        return set()

    n, = struct.unpack_from(">H", data, cmap_off + 2)
    subtables = []
    for i in range(n):
        pid, eid, sub = struct.unpack_from(">HHI", data, cmap_off + 4 + i * 8)
        subtables.append((pid, eid, cmap_off + sub))

    # (3,10) — полный Unicode, (3,1) — только BMP
    subtables.sort(key=lambda s: 0 if (s[0], s[1]) == (3, 10) else 1)
    out = set()
    for pid, eid, sub in subtables:
        fmt, = struct.unpack_from(">H", data, sub)
        if fmt == 12:
            ngroups, = struct.unpack_from(">I", data, sub + 12)
            for g in range(ngroups):
                start, end, _ = struct.unpack_from(">III", data, sub + 16 + g * 12)
                out.update(range(start, min(end, start + 0x10000) + 1))
        elif fmt == 4:
            segx2, = struct.unpack_from(">H", data, sub + 6)
            seg = segx2 // 2
            ends = struct.unpack_from(">%dH" % seg, data, sub + 14)
            starts = struct.unpack_from(">%dH" % seg, data, sub + 16 + segx2)
            for s, e in zip(starts, ends):
                if s == 0xFFFF:
                    continue
                out.update(range(s, e + 1))
        if out:
            break
    return out


# --------------------------------------------------------------------------
# Рендер
# --------------------------------------------------------------------------

def open_font(path, px):
    """Открывает шрифт; для битмап-шрифтов (Noto Color Emoji) подбирает
    ближайший доступный размер, вернув коэффициент масштаба."""
    try:
        return ImageFont.truetype(path, px), 1.0
    except OSError:
        for native in (109, 136, 128, 96, 64, 32):
            try:
                return ImageFont.truetype(path, native), px / float(native)
            except OSError:
                continue
        raise


# У цветных шрифтов (COLR/CPAL — Segoe UI Emoji, icons.ttf) базовый контур
# глифа часто пустой: всё изображение лежит в слоях COLR. Pillow вычисляет
# размер маски по контурам, поэтому строка из одного такого символа даёт
# маску нулевой высоты и на холст не попадает ничего.
#
# Обход: дорисовываем справа «распорку» — символ, которого в шрифте заведомо
# нет. Он рисуется как .notdef (прямоугольник с непустым контуром), маска
# получает нормальную высоту, а сам .notdef отрезается по ширине аванса
# нужного символа.
SPACER = "\uE123"   # приватная область, в эмодзи-шрифтах не занята


def _draw(text, font, canvas, origin):
    tmp = Image.new("RGBA", canvas, (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    try:
        d.text(origin, text, font=font, embedded_color=True)
    except Exception:
        return None
    return tmp


def render_glyph(ch, font, box):
    """Рисует символ и возвращает обрезанное по содержимому RGBA-изображение."""
    try:
        adv = font.getlength(ch)
    except Exception:
        adv = 0

    # Холст считаем от ширины самого глифа: серверные баннеры («ВИП ЧАТ»,
    # «РЕКЛАМА») бывают в 6 раз шире своей высоты, и на холсте фиксированного
    # размера у них обрезался хвост.
    origin = (box, box)
    width = max(box * 4, origin[0] + int(adv) + box * 2)
    canvas = (width, box * 4)

    tmp = _draw(ch, font, canvas, origin)
    if tmp is not None:
        bb = tmp.getbbox()
        if bb is not None:
            return tmp.crop(bb)

    # путь для цветных шрифтов с пустыми базовыми контурами
    if adv <= 0:
        return None
    tmp = _draw(ch + SPACER, font, canvas, origin)
    if tmp is None:
        return None
    tmp = tmp.crop((0, 0, min(canvas[0], origin[0] + int(round(adv))), canvas[1]))
    bb = tmp.getbbox()
    if bb is None:
        return None
    return tmp.crop(bb)


def fit_into(img, cell, pad):
    """Вписывает глиф в квадратную ячейку, сохраняя пропорции."""
    target = cell - pad * 2
    w, h = img.size
    scale = float(target) / max(w, h)
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    img = img.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
    out.paste(img, ((cell - nw) // 2, (cell - nh) // 2))
    return out


def lua_str(s):
    """Строка для Lua целиком в ASCII: не-ASCII байты уходят в \\ddd.

    Так сгенерированные файлы невозможно испортить пересохранением в другой
    кодировке — а именно на этом всё и спотыкается: ImGui ждёт UTF-8, а
    блокнот по умолчанию пишет cp1251.
    """
    out = []
    for b in s.encode("utf-8"):
        c = chr(b)
        if b < 0x20 or b >= 0x7F:
            out.append("\\%03d" % b)     # ровно три цифры: Lua дальше не читает
        elif c in ("'", "\\"):
            out.append("\\" + c)
        else:
            out.append(c)
    return "'" + "".join(out) + "'"


LUA_HEADER = """-- Автоматически сгенерировано build_emoji_atlas.py.
-- Не редактировать вручную.
--
-- slot — номер ячейки в атласе, отсчёт слева направо, сверху вниз.
-- UV-координаты считаются в chat_emoji.lua как:
--   u0 = (slot %% cols) * cell / width,  v0 = floor(slot / cols) * cell / height

return {
  file   = '%s',
  width  = %d,
  height = %d,
  cell   = %d,
  cols   = %d,
  count  = %d,
  emoji  = {
"""


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("json", help="emoji.json от extract_chat_emoji.py")
    ap.add_argument("--icons", required=True, help="icons.ttf из _chat.asi")
    ap.add_argument("--emoji", help="цветной эмодзи-шрифт (seguiemj.ttf)")
    ap.add_argument("-o", "--out", default=".", help="каталог результата")
    ap.add_argument("--cell", type=int, default=64, help="размер ячейки, px")
    ap.add_argument("--pad", type=int, default=2, help="отступ внутри ячейки")
    ap.add_argument("--width", type=int, default=2048, help="ширина атласа")
    ap.add_argument("--name", default="chat_emoji", help="имя выходных файлов")
    args = ap.parse_args()

    if not args.emoji:
        guess = os.path.join(os.environ.get("WINDIR", r"C:\Windows"),
                             "Fonts", "seguiemj.ttf")
        if os.path.exists(guess):
            args.emoji = guess
        else:
            sys.exit("укажите --emoji (путь к seguiemj.ttf или другому "
                     "цветному эмодзи-шрифту)")

    items = json.load(open(args.json, encoding="utf-8"))
    os.makedirs(args.out, exist_ok=True)

    icons_cps = font_codepoints(args.icons)
    emoji_cps = font_codepoints(args.emoji)
    print("icons.ttf: %d кодовых точек, эмодзи-шрифт: %d" %
          (len(icons_cps), len(emoji_cps)))

    f_icons, s_icons = open_font(args.icons, args.cell)
    f_emoji, s_emoji = open_font(args.emoji, args.cell)

    cols = args.width // args.cell
    rendered = []
    missing = []
    for it in items:
        cp = it["cp"]
        ch = chr(cp)
        # серверные иконки есть только в icons.ttf, поэтому он в приоритете
        if cp in icons_cps:
            font, scale = f_icons, s_icons
        elif cp in emoji_cps:
            font, scale = f_emoji, s_emoji
        else:
            missing.append(it)
            continue
        box = int(args.cell / scale) if scale != 1.0 else args.cell
        img = render_glyph(ch, font, box)
        if img is None:
            missing.append(it)
            continue
        rendered.append((it, fit_into(img, args.cell, args.pad)))

    rows = (len(rendered) + cols - 1) // cols
    height = 1
    while height < rows * args.cell:
        height *= 2
    atlas = Image.new("RGBA", (args.width, height), (0, 0, 0, 0))
    for slot, (_it, img) in enumerate(rendered):
        x = (slot % cols) * args.cell
        y = (slot // cols) * args.cell
        atlas.paste(img, (x, y))

    png = os.path.join(args.out, args.name + ".png")
    atlas.save(png, optimize=True)
    print("атлас: %s  %dx%d, ячейка %d, %d смайлов" %
          (png, args.width, height, args.cell, len(rendered)))
    if missing:
        print("не найдено в шрифтах (%d): %s" %
              (len(missing), ", ".join(m["name"] for m in missing[:20])))

    lua = os.path.join(args.out, args.name + "_atlas.lua")
    with open(lua, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER % (args.name + ".png", args.width, height,
                              args.cell, cols, len(rendered)))
        q = lua_str

        for slot, (it, _img) in enumerate(rendered):
            names = it.get("names") or []
            row = "    { %s, 0x%05X, %s, %d" % (
                q(it["name"]), it["cp"], q(it["cat"]), slot)
            if len(names) > 1:      # синонимы: ':)', '<3' и подобные
                row += ", { %s }" % ", ".join(q(a) for a in names[1:])
            f.write(row + " },\n")
        f.write("  },\n}\n")
    print("описание: %s" % lua)


if __name__ == "__main__":
    main()
