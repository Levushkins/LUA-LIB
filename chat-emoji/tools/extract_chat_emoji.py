#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_chat_emoji.py — извлекает из _chat.asi (Arizona Games chat plugin)
всё, что нужно для работы со смайлами:

  * встроенные шрифты (RCDATA, сжаты алгоритмом stb_compress из ImGui
    binary_to_compressed_c) -> icons.ttf / big_icons.ttf / arial_bold.ttf /
    heading_now.ttf
  * таблицу смайлов {const char* name; uint32_t codepoint} (825 записей)
    -> emoji.json / emoji_list.lua

Зависимостей нет, только стандартная библиотека.

    python3 extract_chat_emoji.py _chat.asi -o ../data
"""

import argparse
import json
import os
import re
import struct
import sys

# --------------------------------------------------------------------------
# Минимальный парсер PE32
# --------------------------------------------------------------------------


class PE:
    def __init__(self, data):
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("не MZ/PE файл")
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
            raise ValueError("нет PE-сигнатуры")
        coff = e_lfanew + 4
        num_sections, = struct.unpack_from("<H", data, coff + 2)
        size_opt, = struct.unpack_from("<H", data, coff + 16)
        opt = coff + 20
        magic, = struct.unpack_from("<H", data, opt)
        if magic != 0x10B:
            raise ValueError("поддерживается только PE32 (x86)")
        self.image_base, = struct.unpack_from("<I", data, opt + 28)
        num_dirs, = struct.unpack_from("<I", data, opt + 92)
        self.dirs = []
        for i in range(num_dirs):
            self.dirs.append(struct.unpack_from("<II", data, opt + 96 + i * 8))

        self.sections = []
        sec = opt + size_opt
        for i in range(num_sections):
            name, vsize, vaddr, rawsize, rawptr = struct.unpack_from(
                "<8sIIII", data, sec + i * 40)
            self.sections.append({
                "name": name.rstrip(b"\0").decode("latin-1"),
                "vsize": vsize, "vaddr": vaddr,
                "rawsize": rawsize, "rawptr": rawptr,
            })

    def rva_to_off(self, rva):
        for s in self.sections:
            if s["vaddr"] <= rva < s["vaddr"] + max(s["vsize"], s["rawsize"]):
                off = s["rawptr"] + (rva - s["vaddr"])
                if off < s["rawptr"] + s["rawsize"]:
                    return off
        return None

    def va_to_off(self, va):
        if va < self.image_base:
            return None
        return self.rva_to_off(va - self.image_base)

    def off_to_va(self, off):
        for s in self.sections:
            if s["rawptr"] <= off < s["rawptr"] + s["rawsize"]:
                return self.image_base + s["vaddr"] + (off - s["rawptr"])
        return None

    def resources(self):
        """Возвращает список (type_id, name_id, lang_id, bytes)."""
        rva, size = self.dirs[2]
        if not rva:
            return []
        root = self.rva_to_off(rva)
        out = []

        def walk(off, path):
            n_named, n_id = struct.unpack_from("<HH", self.data, off + 12)
            for i in range(n_named + n_id):
                eid, data_off = struct.unpack_from(
                    "<II", self.data, off + 16 + i * 8)
                if data_off & 0x80000000:
                    walk(root + (data_off & 0x7FFFFFFF), path + [eid])
                else:
                    d_rva, d_size = struct.unpack_from(
                        "<II", self.data, root + data_off)
                    d_off = self.rva_to_off(d_rva)
                    out.append((path + [eid], self.data[d_off:d_off + d_size]))

        walk(root, [])
        return out


# --------------------------------------------------------------------------
# stb_decompress (тот же формат, что у ImGui binary_to_compressed_c)
# --------------------------------------------------------------------------

STB_MAGIC = 0x57BC0000


def is_stb_compressed(src):
    return len(src) > 16 and struct.unpack_from(">I", src, 0)[0] == STB_MAGIC


def stb_decompress(src):
    def in2(p):
        return (src[p] << 8) + src[p + 1]

    def in3(p):
        return (src[p] << 16) + in2(p + 1)

    def in4(p):
        return (src[p] << 24) + in3(p + 1)

    if in4(0) != STB_MAGIC:
        raise ValueError("не stb_compress поток")
    if in4(4) != 0:
        raise ValueError("поток больше 4 ГБ")
    olen = in4(8)
    out = bytearray()

    def match(off, length):
        start = len(out) - off
        if start < 0:
            raise ValueError("повреждённый поток")
        for k in range(length):
            out.append(out[start + k])

    i = 16
    while True:
        old = i
        c = src[i]
        if c >= 0x20:
            if c >= 0x80:
                match(src[i + 1] + 1, c - 0x80 + 1)
                i += 2
            elif c >= 0x40:
                match(in2(i) - 0x4000 + 1, src[i + 2] + 1)
                i += 3
            else:
                n = c - 0x20 + 1
                out += src[i + 1:i + 1 + n]
                i += 1 + n
        elif c >= 0x18:
            match(in3(i) - 0x180000 + 1, src[i + 3] + 1)
            i += 4
        elif c >= 0x10:
            match(in3(i) - 0x100000 + 1, in2(i + 3) + 1)
            i += 5
        elif c >= 0x08:
            n = in2(i) - 0x0800 + 1
            out += src[i + 2:i + 2 + n]
            i += 2 + n
        elif c == 0x07:
            n = in2(i + 1) + 1
            out += src[i + 3:i + 3 + n]
            i += 3 + n
        elif c == 0x06:
            match(in3(i + 1) + 1, src[i + 4] + 1)
            i += 5
        elif c == 0x04:
            match(in3(i + 1) + 1, in2(i + 4) + 1)
            i += 6
        if i == old:
            if not (src[i] == 0x05 and src[i + 1] == 0xFA):
                raise ValueError("неизвестный токен 0x%02X" % src[i])
            break
    if len(out) != olen:
        raise ValueError("длина не совпала: %d != %d" % (len(out), olen))
    return bytes(out)


# --------------------------------------------------------------------------
# Таблица смайлов
# --------------------------------------------------------------------------

def font_family(ttf):
    """Достаёт family name из таблицы 'name' TTF, чтобы назвать файл."""
    try:
        num_tables, = struct.unpack_from(">H", ttf, 4)
        for i in range(num_tables):
            tag, _, off, ln = struct.unpack_from(">4sIII", ttf, 12 + i * 16)
            if tag != b"name":
                continue
            count, str_off = struct.unpack_from(">HH", ttf, off + 2)
            for j in range(count):
                pid, eid, lid, nid, slen, soff = struct.unpack_from(
                    ">6H", ttf, off + 6 + j * 12)
                if nid != 1:
                    continue
                raw = ttf[off + str_off + soff: off + str_off + soff + slen]
                s = raw.decode("utf-16-be" if pid == 3 else "latin-1", "ignore")
                s = re.sub(r"[^A-Za-z0-9_]+", "_", s).strip("_").lower()
                if s:
                    return s
    except Exception:
        pass
    return None


def read_cstring(pe, va, maxlen=48):
    off = pe.va_to_off(va)
    if off is None:
        return None
    end = pe.data.find(b"\0", off, off + maxlen + 1)
    if end < 0 or end == off:
        return None
    s = pe.data[off:end]
    if not all(32 <= c < 127 for c in s):
        return None
    return s.decode("ascii")


def extract_emoji_table(pe):
    """
    Ищет массив структур { const char* name; uint32_t codepoint; }.
    Якорь — указатель на строку "smiley"; дальше массив разворачивается
    в обе стороны по признаку «валидная пара».
    """
    anchor_str = pe.data.find(b"smiley\0")
    if anchor_str < 0:
        raise ValueError('строка "smiley" не найдена')
    va = pe.off_to_va(anchor_str)
    refs = [m.start() for m in
            re.finditer(re.escape(struct.pack("<I", va)), pe.data)]
    if not refs:
        raise ValueError("нет ссылок на строку smiley")

    def entry(p):
        if p < 0 or p + 8 > len(pe.data):
            return None
        ptr, cp = struct.unpack_from("<II", pe.data, p)
        name = read_cstring(pe, ptr)
        if name is None or not (0x20 <= cp <= 0x10FFFF):
            return None
        return name, cp

    best = []
    for anchor in refs:
        if entry(anchor) is None:
            continue
        start = anchor
        while entry(start - 8):
            start -= 8
        end = anchor
        while entry(end + 8):
            end += 8
        items = [entry(p) for p in range(start, end + 1, 8)]
        if len(items) > len(best):
            best = items
    if not best:
        raise ValueError("таблица смайлов не найдена")
    return best


# --------------------------------------------------------------------------
# Категории (эвристика по порядку в таблице — он совпадает с порядком
# в панели смайлов чата)
# --------------------------------------------------------------------------

CATEGORIES = [
    (0,   "Смайлы"),
    (100, "Животные"),
    (212, "Люди"),
    (278, "Праздники и одежда"),
    (325, "Спорт и игры"),
    (359, "Предметы"),
    (475, "Еда и напитки"),
    (564, "Растения"),
    (578, "Транспорт"),
    (615, "Места"),
    (660, "Природа"),
    (680, "Символы"),
    (751, "Сервер"),
    (789, "Буквы"),
]


def category_of(index):
    name = CATEGORIES[0][1]
    for start, cat in CATEGORIES:
        if index >= start:
            name = cat
        else:
            break
    return name


# --------------------------------------------------------------------------

LUA_HEADER = """-- Автоматически сгенерировано extract_chat_emoji.py из _chat.asi.
-- Не редактировать вручную.
--
-- Формат записи: { name = 'smiley', cp = 0x1F603, cat = 'Смайлы' }
--   name — имя смайла в чате
--   cp   — кодовая точка Unicode; в текст чата вставляется как ':u%x:'
--          (например :u1f603:)
--   cat  — категория для панели выбора

return {
"""


def write_lua(items, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER)
        for i, (name, cp) in enumerate(items):
            f.write("  { name = %-16s cp = 0x%05X, cat = %s },\n" % (
                "'" + name.replace("\\", "\\\\").replace("'", "\\'") + "',",
                cp,
                "'" + category_of(i) + "'"))
        f.write("}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("asi", help="путь к _chat.asi")
    ap.add_argument("-o", "--out", default="out", help="каталог для результата")
    args = ap.parse_args()

    data = open(args.asi, "rb").read()
    pe = PE(data)
    os.makedirs(args.out, exist_ok=True)

    print("ImageBase 0x%08X, секций: %d" % (pe.image_base, len(pe.sections)))

    # --- шрифты -----------------------------------------------------------
    fonts = 0
    for path, blob in pe.resources():
        if not is_stb_compressed(blob):
            continue
        ttf = stb_decompress(blob)
        if ttf[:4] not in (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf"):
            continue
        name = font_family(ttf) or ("res%d" % path[1])
        dst = os.path.join(args.out, name + ".ttf")
        with open(dst, "wb") as f:
            f.write(ttf)
        print("  шрифт: %-16s %8d байт  (сжат %d)" % (
            name + ".ttf", len(ttf), len(blob)))
        fonts += 1
    if not fonts:
        print("  ВНИМАНИЕ: шрифты не найдены", file=sys.stderr)

    # --- таблица смайлов --------------------------------------------------
    items = extract_emoji_table(pe)
    print("  смайлов: %d" % len(items))

    js = [{"index": i, "name": n, "cp": cp,
           "hex": "%05X" % cp, "cat": category_of(i)}
          for i, (n, cp) in enumerate(items)]
    with open(os.path.join(args.out, "emoji.json"), "w", encoding="utf-8") as f:
        json.dump(js, f, ensure_ascii=False, indent=1)
    write_lua(items, os.path.join(args.out, "emoji_list.lua"))
    print("  записано: emoji.json, emoji_list.lua")


if __name__ == "__main__":
    main()
