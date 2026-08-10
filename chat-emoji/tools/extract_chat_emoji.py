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


def extract_panel(pe):
    """
    Достаёт списки панели смайлов.

    Панель строится не из именованной таблицы, а из семи отдельных массивов
    uint32 в .rdata — по одному на вкладку. Каждый массив адресуется прямо
    из кода константой, поэтому:

      * стартовые адреса ищем среди 4-байтовых immediate в .text,
        проверяя, что по адресу лежит правдоподобный массив кодовых точек;
      * порядок категорий = порядок первого обращения в .text (именно в нём
        панель их и рисует);
      * длина массива = расстояние до следующего старта минус хвостовые нули;
        последний массив читаем, пока значения похожи на кодовые точки.

    Компилятор разворачивает копирование коротких массивов в несколько
    16-байтовых кусков, поэтому адреса, отстоящие от предыдущего меньше
    чем на 64 байта, считаем продолжением того же массива, а не новой
    категорией.
    """
    rdata = None
    text = None
    for s in pe.sections:
        if s["name"] == ".rdata":
            rdata = s
        elif s["name"] == ".text":
            text = s
    if rdata is None or text is None:
        raise ValueError("нет секции .rdata или .text")

    def u32(off):
        return struct.unpack_from("<I", pe.data, off)[0]

    def looks_like_list(off, need=8):
        """Первые need значений похожи на кодовые точки эмодзи."""
        end = rdata["rawptr"] + rdata["rawsize"]
        if off + need * 4 > end:
            return False
        for k in range(need):
            v = u32(off + k * 4)
            if not (0x2000 <= v <= 0x1FFFF):
                return False
        return True

    # --- собираем кандидатов из .text ---
    lo_va = pe.image_base + rdata["vaddr"]
    hi_va = lo_va + rdata["rawsize"]
    hits = {}                       # va -> самое раннее смещение в .text
    tlo = text["rawptr"]
    thi = tlo + text["rawsize"]
    for p in range(tlo, thi - 4):
        v = struct.unpack_from("<I", pe.data, p)[0]
        if v & 3 or not (lo_va <= v < hi_va):
            continue
        off = pe.va_to_off(v)
        if off is None or not looks_like_list(off):
            continue
        if v not in hits:
            hits[v] = p

    if not hits:
        raise ValueError("массивы панели не найдены")

    # --- схлопываем развёрнутые копии одного массива ---
    starts = []
    for va in sorted(hits):
        if starts and va - starts[-1] < 64:
            continue                # продолжение предыдущего массива
        starts.append(va)

    # --- читаем содержимое ---
    # Массив кончается там, где начинается следующий, либо там, где значения
    # перестают быть похожими на кодовые точки (нули между массивами —
    # выравнивание, их пропускаем и обрезаем в конце).
    lists = {}
    for i, va in enumerate(starts):
        off = pe.va_to_off(va)
        limit = rdata["rawptr"] + rdata["rawsize"]
        if i + 1 < len(starts):
            limit = min(limit, pe.va_to_off(starts[i + 1]))
        end = off
        while end + 4 <= limit:
            v = u32(end)
            if v != 0 and not (0x20 <= v <= 0x1FFFF):
                break
            end += 4
        vals = [u32(o) for o in range(off, end, 4)]
        while vals and vals[-1] == 0:
            vals.pop()
        if len(vals) >= 16:         # короткие совпадения — случайные
            lists[va] = vals

    starts = [va for va in starts if va in lists]
    if not starts:
        raise ValueError("массивы панели не найдены")

    # --- порядок категорий = порядок обращения в коде ---
    order = sorted(starts, key=lambda va: hits[va])
    return [(va, lists[va]) for va in order]


def extract_emoji_table(pe):
    """
    Ищет массив структур { const char* name; uint32_t codepoint; }.
    Это словарь для текстовых шорткатов, а не список панели: часть смайлов
    панели имён не имеет, а часть имён (серверные иконки) в панель не попала.
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

# Названия вкладок панели. Порядок — как в чате; группировка у Arizona своя,
# не по CLDR: животные лежат вместе со смайлами, растения — с едой, а часы —
# с сердцами. Имена подобраны по фактическому содержимому массивов.
PANEL_CATEGORIES = [
    "Смайлы и животные",
    "Люди и жесты",
    "Праздники и предметы",
    "Еда и растения",
    "Транспорт и места",
    "Символы",
    "Буквы",
]

# Смайлы, у которых имя в таблице есть, а в панели их нет (серверные иконки
# Arizona и подобное). В чат их можно вставить токеном, поэтому в атлас они
# идут отдельной группой в конец.
EXTRA_CATEGORY = "Сервер"


# --------------------------------------------------------------------------

LUA_HEADER = """-- Автоматически сгенерировано extract_chat_emoji.py из _chat.asi.
-- Не редактировать вручную.
--
-- Порядок записей повторяет порядок панели смайлов в чате Arizona.
--
-- Формат: { cp = 0x1F603, cat = 'Смайлы и животные', names = { 'smiley' } }
--   cp    — кодовая точка Unicode; в текст чата вставляется как ':u%x:'
--           (например :u1f603:)
--   cat   — вкладка панели
--   names — имена из таблицы шорткатов чата; у части смайлов имён нет

return {
"""


def lua_str(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def write_lua(items, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write(LUA_HEADER)
        for it in items:
            names = ", ".join(lua_str(n) for n in it["names"])
            f.write("  { cp = 0x%05X, cat = %s, names = { %s } },\n" % (
                it["cp"], lua_str(it["cat"]), names))
        f.write("}\n")


def build_items(panel, table):
    """Сводит списки панели с таблицей имён в один упорядоченный список."""
    names_by_cp = {}
    for name, cp in table:
        names_by_cp.setdefault(cp, []).append(name)

    items = []
    seen = set()
    for idx, (_va, cps) in enumerate(panel):
        cat = (PANEL_CATEGORIES[idx] if idx < len(PANEL_CATEGORIES)
               else "Группа %d" % (idx + 1))
        for cp in cps:
            if cp in seen:
                continue
            seen.add(cp)
            items.append({"cp": cp, "cat": cat,
                          "names": names_by_cp.get(cp, [])})

    # именованные, но не попавшие в панель — в конец отдельной группой,
    # порядок сохраняем как в таблице шорткатов
    for name, cp in table:
        if cp in seen:
            continue
        seen.add(cp)
        items.append({"cp": cp, "cat": EXTRA_CATEGORY,
                      "names": names_by_cp.get(cp, [])})

    for i, it in enumerate(items):
        it["index"] = i
        it["hex"] = "%05X" % it["cp"]
        it["name"] = it["names"][0] if it["names"] else "u%x" % it["cp"]
    return items


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

    # --- списки панели ----------------------------------------------------
    panel = extract_panel(pe)
    print("  массивов панели: %d" % len(panel))
    for idx, (va, cps) in enumerate(panel):
        cat = (PANEL_CATEGORIES[idx] if idx < len(PANEL_CATEGORIES)
               else "группа %d" % (idx + 1))
        print("    0x%08X  %4d  %s" % (va, len(cps), cat))

    # --- таблица имён -----------------------------------------------------
    table = extract_emoji_table(pe)
    print("  имён в таблице шорткатов: %d" % len(table))

    items = build_items(panel, table)
    named = sum(1 for it in items if it["names"])
    print("  всего смайлов: %d (с именем %d, без имени %d)"
          % (len(items), named, len(items) - named))

    with open(os.path.join(args.out, "emoji.json"), "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    write_lua(items, os.path.join(args.out, "emoji_list.lua"))
    print("  записано: emoji.json, emoji_list.lua")


if __name__ == "__main__":
    main()
