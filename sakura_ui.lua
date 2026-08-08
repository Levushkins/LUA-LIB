--[[
    SAKURA UI — аниме-меню с гидом-компаньоном
    ------------------------------------------------------------------
    MoonLoader + mimgui. Всё меню (фон, панели, тумблеры, слайдеры,
    иконки) и сам персонаж-гид рисуются вручную через ImDrawList —
    ни одной картинки, ни одного стороннего пакета иконок.

    Установка:
        1. Положить файл в moonloader/
        2. Нужна библиотека mimgui (moonloader/lib/mimgui)
        3. /sakura  или  клавиша F4 — открыть меню
           /sakura say — случайная реплика гида, ESC — закрыть

    Что где менять:
        THEMES        — палитры (акценты, цвет волос и глаз персонажа)
        Guide.name    — имя гида
        PHRASES       — её реплики «ни о чём»
        drawGirl()    — сама фигура: причёска, форма, бант
        EMO           — набор эмоций (глаза, рот, румянец, наклон головы)
        cfg.main.hotkey — клавиша открытия (коды в lib vkeys)

    Кодировка файла: UTF-8. Строки уже в UTF-8, поэтому оборачивать
    их в u8'' НЕ нужно — imgui принимает UTF-8 как есть. Обратно в
    CP1251 переводим только то, что уходит в чат SA-MP (u8:decode).
]]

script_name('Sakura UI')
script_version('1.0.0')
script_description('Аниме-меню с гидом-компаньоном на mimgui')

local imgui    = require 'mimgui'
local vkeys    = require 'vkeys'
local wm       = require 'windows.message'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ============================================================================
--  КОНФИГ
-- ============================================================================

local INI = 'sakura_ui.ini'

local cfg = inicfg.load({
    main = {
        hotkey    = vkeys.VK_F4,
        greeting  = true,   -- гид здоровается при запуске
        hints     = true,   -- подсказки при наведении
        clock     = true,   -- часы на экране
        fps       = true,   -- счётчик FPS
    },
    ui = {
        theme     = 1,
        rounding  = 12,
        petals    = true,
        density   = 26,     -- количество лепестков
        opacity   = 0.96,
        speed     = 1.0,    -- множитель скорости анимаций
    },
    guide = {
        enabled   = true,
        typing    = 34,     -- символов в секунду
        side      = 2,      -- 1 — слева, 2 — справа
        scale     = 1.0,
    },
}, INI)

-- ============================================================================
--  ПАЛИТРА И ТЕМЫ
-- ============================================================================

-- Базовые (нейтральные) цвета интерфейса — одинаковы для всех тем.
local C = {
    shadow  = 0x05030A,
    bgTop   = 0x1B1526,
    bgBot   = 0x120E1A,
    railTop = 0x171223,
    railBot = 0x100C18,
    panel   = 0x231C33,
    panelHi = 0x2C2440,
    line    = 0x342A4A,
    text    = 0xF0EAF8,
    dim     = 0xA79BC0,
    mute    = 0x6E6488,
    white   = 0xFFFFFF,
    skin    = 0xFBE3DA,
    skinSh  = 0xEEC9BF,
    cloth   = 0x2B2E52,
    clothHi = 0x3B3F66,
}

local THEMES = {
    {
        name  = 'Сакура',
        a1    = 0xFF87B5,  -- основной акцент
        a2    = 0xC77DFF,  -- вторичный (для градиентов)
        hair1 = 0xF7B7CE,  -- волосы: свет
        hair2 = 0xD97BA6,  -- волосы: тень
        eye   = 0xE0567F,
    },
    {
        name  = 'Мятный бриз',
        a1    = 0x6FE3C4,
        a2    = 0x62B6FF,
        hair1 = 0xA9EBDC,
        hair2 = 0x53A896,
        eye   = 0x2E9C86,
    },
    {
        name  = 'Закат',
        a1    = 0xFFA463,
        a2    = 0xFF6B8B,
        hair1 = 0xFFD1A1,
        hair2 = 0xD98552,
        eye   = 0xC85F2E,
    },
    {
        name  = 'Полночь',
        a1    = 0x8FA7FF,
        a2    = 0xB98BFF,
        hair1 = 0xBFC8F5,
        hair2 = 0x6C74B8,
        eye   = 0x5A67C4,
    },
}

local function T() return THEMES[cfg.ui.theme] or THEMES[1] end

-- ============================================================================
--  МАТЕМАТИКА / ЦВЕТ
-- ============================================================================

local floor, min, max, sin, cos, pi = math.floor, math.min, math.max, math.sin, math.cos, math.pi

local function clamp(v, a, b) return v < a and a or (v > b and b or v) end
local function lerp(a, b, t) return a + (b - a) * t end

-- кадронезависимое сглаживание
local function approach(cur, target, speed, dt)
    return lerp(cur, target, 1 - math.exp(-speed * dt))
end

local function easeOutCubic(t) return 1 - (1 - t) ^ 3 end

-- Глобальный множитель прозрачности: даёт единое плавное появление/угасание.
local ALPHA = 1.0

local function rgbOf(hex)
    return floor(hex / 0x10000) % 0x100, floor(hex / 0x100) % 0x100, hex % 0x100
end

-- hex 0xRRGGBB + альфа 0..1  ->  ImU32 (порядок ABGR)
local function col(hex, a)
    a = clamp((a or 1) * ALPHA, 0, 1)
    local r, g, b = rgbOf(hex)
    return floor(a * 255 + 0.5) * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

-- то же, но игнорируя глобальную прозрачность (для оверлеев вне меню)
local function colRaw(hex, a)
    a = clamp(a or 1, 0, 1)
    local r, g, b = rgbOf(hex)
    return floor(a * 255 + 0.5) * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

local function mixHex(h1, h2, t)
    t = clamp(t, 0, 1)
    local r1, g1, b1 = rgbOf(h1)
    local r2, g2, b2 = rgbOf(h2)
    return floor(lerp(r1, r2, t)) * 0x10000 + floor(lerp(g1, g2, t)) * 0x100 + floor(lerp(b1, b2, t))
end

local function shade(hex, k) -- k < 1 темнее, k > 1 светлее
    local r, g, b = rgbOf(hex)
    return floor(clamp(r * k, 0, 255)) * 0x10000 + floor(clamp(g * k, 0, 255)) * 0x100 + floor(clamp(b * k, 0, 255))
end

local function V(x, y) return imgui.ImVec2(x, y) end

-- ============================================================================
--  ПРИМИТИВЫ ОТРИСОВКИ
-- ============================================================================

local CORNER = { all = 15, top = 3, bottom = 12, left = 5, right = 10 }

local polyMode -- 'path' | 'fan' — определяется один раз при первом кадре

-- Гид рисуется поверх окон. Если сборка mimgui не отдаёт foreground-список,
-- аккуратно откатываемся на фоновый — персонаж просто окажется под меню.
local fgCache
local function foregroundList(fallback)
    if fgCache == nil then
        local ok, list = pcall(function() return imgui.GetForegroundDrawList() end)
        fgCache = (ok and list) or false
    end
    return fgCache or fallback
end

local function detectPolyMode(dl)
    local ok = pcall(function()
        dl:PathClear()
        dl:PathLineTo(V(0, 0)); dl:PathLineTo(V(0, 0)); dl:PathLineTo(V(0, 0))
        dl:PathFillConvex(0)
    end)
    return ok and 'path' or 'fan'
end

-- Заливка выпуклого многоугольника. pts — массив {x, y}
local function polyFill(dl, pts, color)
    if #pts < 3 then return end
    if polyMode == 'path' then
        dl:PathClear()
        for i = 1, #pts do dl:PathLineTo(V(pts[i][1], pts[i][2])) end
        dl:PathFillConvex(color)
    else
        for i = 2, #pts - 1 do
            dl:AddTriangleFilled(V(pts[1][1], pts[1][2]), V(pts[i][1], pts[i][2]),
                                 V(pts[i + 1][1], pts[i + 1][2]), color)
        end
    end
end

local function polyLine(dl, pts, color, thickness, closed)
    if #pts < 2 then return end
    if polyMode == 'path' then
        dl:PathClear()
        for i = 1, #pts do dl:PathLineTo(V(pts[i][1], pts[i][2])) end
        dl:PathStroke(color, closed and true or false, thickness)
    else
        for i = 1, #pts - 1 do
            dl:AddLine(V(pts[i][1], pts[i][2]), V(pts[i + 1][1], pts[i + 1][2]), color, thickness)
        end
        if closed then
            dl:AddLine(V(pts[#pts][1], pts[#pts][2]), V(pts[1][1], pts[1][2]), color, thickness)
        end
    end
end

local function ellipsePts(cx, cy, rx, ry, seg, rot, from, to)
    seg = seg or 26
    from, to = from or 0, to or pi * 2
    local c, s = 1, 0
    if rot then c, s = cos(rot), sin(rot) end
    local pts = {}
    for i = 0, seg do
        local a = from + (to - from) * (i / seg)
        local x, y = cos(a) * rx, sin(a) * ry
        pts[#pts + 1] = { cx + x * c - y * s, cy + x * s + y * c }
    end
    return pts
end

local function ellipse(dl, cx, cy, rx, ry, color, seg, rot)
    polyFill(dl, ellipsePts(cx, cy, rx, ry, seg, rot), color)
end

local function bezierPts(p0, c0, c1, p1, seg)
    seg = seg or 18
    local pts = {}
    for i = 0, seg do
        local t = i / seg
        local it = 1 - t
        local x = it * it * it * p0[1] + 3 * it * it * t * c0[1] + 3 * it * t * t * c1[1] + t * t * t * p1[1]
        local y = it * it * it * p0[2] + 3 * it * it * t * c0[2] + 3 * it * t * t * c1[2] + t * t * t * p1[2]
        pts[#pts + 1] = { x, y }
    end
    return pts
end

local function bezier(dl, p0, c0, c1, p1, color, thickness, seg)
    polyLine(dl, bezierPts(p0, c0, c1, p1, seg), color, thickness or 2, false)
end

-- Вертикальный градиент со скруглением углов (AddRectFilledMultiColor скругление не умеет)
local function gradientRect(dl, x1, y1, x2, y2, cTop, cBot, aTop, aBot, rounding, corners, steps)
    steps = steps or 22
    corners = corners or CORNER.all
    local h = (y2 - y1) / steps
    for i = 0, steps - 1 do
        local t0 = i / steps
        local ty = y1 + h * i
        local c = col(mixHex(cTop, cBot, t0), lerp(aTop or 1, aBot or 1, t0))
        local cor = 0
        if i == 0 then
            cor = corners % 4                      -- верхние биты (1|2)
        elseif i == steps - 1 then
            cor = corners - corners % 4            -- нижние биты (4|8)
        end
        dl:AddRectFilled(V(x1, ty - (i > 0 and 0.5 or 0)), V(x2, ty + h + 0.5),
                         c, cor > 0 and rounding or 0, cor)
    end
end

-- Мягкое свечение: несколько окружностей с падающей прозрачностью
local function glow(dl, cx, cy, radius, hex, strength, layers, raw)
    layers = layers or 5
    local mk = raw and colRaw or col
    for i = layers, 1, -1 do
        local t = i / layers
        dl:AddCircleFilled(V(cx, cy), radius * t, mk(hex, strength * (1 - t) * 0.55), 26)
    end
end

-- Цветок сакуры: 5 лепестков + сердцевина
local function sakura(dl, cx, cy, r, rot, hex, aMul, raw)
    local mk = raw and colRaw or col
    aMul = aMul or 1
    for p = 0, 4 do
        local a = rot + p * (pi * 2 / 5)
        local px, py = cx + cos(a) * r * 0.62, cy + sin(a) * r * 0.62
        local pts = {}
        for i = 0, 12 do
            local th = (i / 12) * pi * 2
            local rr = r * 0.52 * (0.72 + 0.28 * cos(th))
            local x, y = cos(th) * rr * 1.05, sin(th) * rr
            pts[#pts + 1] = { px + x * cos(a) - y * sin(a), py + x * sin(a) + y * cos(a) }
        end
        polyFill(dl, pts, mk(hex, 0.95 * aMul))
    end
    dl:AddCircleFilled(V(cx, cy), r * 0.24, mk(mixHex(hex, 0xFFF3B0, 0.7), 0.95 * aMul), 14)
    -- тычинки

    for p = 0, 4 do
        local a = rot + p * (pi * 2 / 5) + 0.4
        dl:AddCircleFilled(V(cx + cos(a) * r * 0.34, cy + sin(a) * r * 0.34),
                           r * 0.07, mk(0xFFE9A8, 0.9 * aMul), 6)
    end
end

-- ============================================================================
--  ШРИФТЫ И ТЕКСТ
-- ============================================================================

local F = {}          -- ImFont*, могут остаться nil — тогда работает шрифт по умолчанию
local jpRangesRef     -- ссылку на диапазоны обязательно держать живой
local winOpen = imgui.new.bool(true)   -- заглушка для Begin: крестик рисуем свой

local FONT_REGULAR = { 'segoeui.ttf', 'tahoma.ttf', 'trebuc.ttf', 'arial.ttf' }
local FONT_BOLD    = { 'segoeuib.ttf', 'trebucbd.ttf', 'tahomabd.ttf', 'arialbd.ttf' }
local FONT_JP      = { 'meiryo.ttc', 'msgothic.ttc', 'YuGothM.ttc', 'msmincho.ttc' }

local fontStack = {}
local function pushF(f)
    fontStack[#fontStack + 1] = (f ~= nil)
    if f then imgui.PushFont(f) end
end
local function popF()
    if table.remove(fontStack) then imgui.PopFont() end
end

local function measure(f, str)
    pushF(f)
    local s = imgui.CalcTextSize(str)
    popF()
    return s.x, s.y
end

local function text(dl, f, x, y, color, str, shadowA)
    pushF(f)
    if shadowA and shadowA > 0 then
        dl:AddText(V(x + 1, y + 1), colRaw(0x000000, shadowA), str)
    end
    dl:AddText(V(x, y), color, str)
    popF()
end

local function textC(dl, f, cx, y, color, str, shadowA)
    local w = measure(f, str)
    text(dl, f, cx - w / 2, y, color, str, shadowA)
end

local function textR(dl, f, rx, y, color, str, shadowA)
    local w = measure(f, str)
    text(dl, f, rx - w, y, color, str, shadowA)
end

-- Подрезает строку под доступную ширину: «длинный текст…»
local function ellipsize(f, str, maxw)
    if measure(f, str) <= maxw then return str end
    local chars = {}
    for ch in str:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = ch end
    while #chars > 1 do
        chars[#chars] = nil
        local probe = table.concat(chars) .. '…'
        if measure(f, probe) <= maxw then return probe end
    end
    return '…'
end

-- ============================================================================
--  ЛЕПЕСТКИ
-- ============================================================================

local Petals = { list = {} }

function Petals:reset(n)
    self.list = {}
    for i = 1, n do
        self.list[i] = {
            x  = math.random(),
            y  = math.random(),
            sp = 0.05 + math.random() * 0.09,
            sz = 4 + math.random() * 5,
            ph = math.random() * pi * 2,
            sw = 0.4 + math.random() * 0.9,
            rt = math.random() * pi * 2,
            rs = (math.random() - 0.5) * 1.6,
            a  = 0.15 + math.random() * 0.35,
        }
    end
end

function Petals:update(dt)
    for _, p in ipairs(self.list) do
        p.y = p.y + p.sp * dt
        p.ph = p.ph + dt * p.sw
        p.rt = p.rt + p.rs * dt
        if p.y > 1.08 then
            p.y = -0.08
            p.x = math.random()
        end
    end
end

function Petals:draw(dl, x, y, w, h, aMul)
    for _, p in ipairs(self.list) do
        if p.y >= 0 and p.y <= 1 then
        local px = x + (p.x * w + sin(p.ph) * 16) % w
        local py = y + p.y * h
        local pts = {}
        for i = 0, 10 do
            local th = (i / 10) * pi * 2
            local rr = p.sz * (0.72 + 0.28 * cos(th))
            local vx, vy = cos(th) * rr * 1.15, sin(th) * rr * 0.72
            pts[#pts + 1] = { px + vx * cos(p.rt) - vy * sin(p.rt), py + vx * sin(p.rt) + vy * cos(p.rt) }
        end
        polyFill(dl, pts, col(mixHex(T().hair1, T().a1, 0.35), p.a * aMul))
        end
    end
end

-- ============================================================================
--  ГИД — АНИМЕ-КОМПАНЬОН
-- ============================================================================

local EMO = {
    idle     = { eye = 1.00, mouth = 'smile', blush = 0.30, brow =  0.00, tilt =  0.00 },
    happy    = { eye = 1.00, mouth = 'open',  blush = 0.70, brow = -0.08, tilt = -0.05, arc = true },
    wink     = { eye = 1.00, mouth = 'smile', blush = 0.55, brow =  0.00, tilt =  0.07, wink = true },
    think    = { eye = 0.88, mouth = 'cat',   blush = 0.25, brow =  0.14, tilt =  0.09, look = {  0.55, -0.5 } },
    surprise = { eye = 1.28, mouth = 'o',     blush = 0.45, brow = -0.28, tilt = -0.02 },
    shy      = { eye = 0.72, mouth = 'wave',  blush = 1.00, brow =  0.18, tilt =  0.11, look = { -0.35, 0.4 } },
}

local Guide = {
    vis      = 0,        -- 0..1 — выезд из-за края экрана
    want     = false,
    emotion  = 'idle',
    eye      = 1, eyeGoal = 1,
    blinkIn  = 1.4, blinking = 0,
    pupilX   = 0, pupilY = 0,
    tilt     = 0, blush = 0.3, brow = 0,
    breathe  = 0, hair = 0,
    text     = nil, lines = nil, wrapKey = nil,
    chars    = 0, total = 0,
    hold     = 0, bubble = 0,
    queue    = {},
    name     = 'Сакура',
}

local function utf8chars(s)
    local t = {}
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do t[#t + 1] = ch end
    return t
end

function Guide:say(str, emotion, hold)
    if not cfg.guide.enabled then return end
    if self.text == str and self.hold > 0.2 then return end   -- не повторяем то же самое
    self.text    = str
    self.emotion = emotion or 'idle'
    self.wrapKey = nil
    self.chars   = 0
    self.total   = #utf8chars(str)
    self.hold    = hold or (2.0 + self.total / 26)
end

function Guide:queueSay(str, emotion, hold)
    self.queue[#self.queue + 1] = { str, emotion, hold }
end

function Guide:silence()
    self.text, self.hold, self.queue = nil, 0, {}
end

function Guide:update(dt, menuOpen, mouseX, mouseY, faceX, faceY)
    -- набор текста
    if self.text then
        local speed = cfg.guide.typing
        if self.chars < self.total then
            self.chars = min(self.total, self.chars + speed * dt)
        else
            self.hold = self.hold - dt
            if self.hold <= 0 then
                if #self.queue > 0 then
                    local nxt = table.remove(self.queue, 1)
                    self:say(nxt[1], nxt[2], nxt[3])
                else
                    self.text = nil
                end
            end
        end
    end

    local speaking = self.text ~= nil
    self.want = cfg.guide.enabled and (speaking or menuOpen)
    self.vis    = approach(self.vis, self.want and 1 or 0, 7 * cfg.ui.speed, dt)
    self.bubble = approach(self.bubble, speaking and 1 or 0, 12 * cfg.ui.speed, dt)

    -- эмоции
    local e = EMO[self.emotion] or EMO.idle
    self.eyeGoal = e.eye
    self.blush   = approach(self.blush, e.blush, 6, dt)
    self.brow    = approach(self.brow, e.brow, 8, dt)
    self.tilt    = approach(self.tilt, e.tilt + sin(self.breathe * 0.6) * 0.012, 5, dt)

    -- дыхание и покачивание волос
    self.breathe = self.breathe + dt
    self.hair    = self.hair + dt * 1.1

    -- моргание
    if self.blinking > 0 then
        self.blinking = self.blinking - dt
        local t = 1 - clamp(self.blinking / 0.13, 0, 1)   -- 0..1 за моргание
        self.eye = self.eyeGoal * math.abs(cos(t * pi))
        if self.blinking <= 0 then self.blinkIn = 1.4 + math.random() * 3.4 end
    else
        self.blinkIn = self.blinkIn - dt
        if self.blinkIn <= 0 then self.blinking = 0.13 end
        self.eye = approach(self.eye, self.eyeGoal, 12, dt)
    end

    -- взгляд: следит за курсором, а в некоторых эмоциях смотрит в сторону
    local gx, gy
    if e.look then
        gx, gy = e.look[1], e.look[2]
    else
        gx = clamp((mouseX - faceX) / 420, -1, 1)
        gy = clamp((mouseY - faceY) / 380, -1, 1)
    end
    self.pupilX = approach(self.pupilX, gx, 7, dt)
    self.pupilY = approach(self.pupilY, gy, 7, dt)
end

-- --- лицо -------------------------------------------------------------------

local function drawEye(dl, x, y, w, h, open, look, arc, closed, th, aMul)
    local lineCol = colRaw(0x33253F, 0.95 * aMul)
    if closed or open < 0.14 then
        -- закрытый глаз: мягкая дуга
        bezier(dl, { x - w / 2, y }, { x - w / 4, y + h * 0.55 }, { x + w / 4, y + h * 0.55 }, { x + w / 2, y },
               lineCol, max(1.6, h * 0.16), 12)
        return
    end
    if arc then
        -- счастливые глаза-дужки ^^
        bezier(dl, { x - w / 2, y + h * 0.25 }, { x - w / 4, y - h * 0.45 }, { x + w / 4, y - h * 0.45 },
               { x + w / 2, y + h * 0.25 }, lineCol, max(1.8, h * 0.17), 14)
        return
    end

    local ry = h * 0.5 * open
    -- белок
    ellipse(dl, x, y, w * 0.5, ry, colRaw(0xFFF7FB, 0.98 * aMul), 22)
    -- радужка
    local ix = x + look[1] * w * 0.13
    local iy = y + look[2] * ry * 0.26
    local irisR = w * 0.33
    ellipse(dl, ix, iy, irisR, min(ry * 0.94, irisR * 1.18), colRaw(shade(th.eye, 0.55), 0.97 * aMul), 20)
    ellipse(dl, ix, iy + ry * 0.16, irisR * 0.82, min(ry * 0.72, irisR * 0.95),
            colRaw(th.eye, 0.95 * aMul), 20)
    ellipse(dl, ix, iy + ry * 0.3, irisR * 0.6, min(ry * 0.46, irisR * 0.62),
            colRaw(mixHex(th.eye, 0xFFFFFF, 0.45), 0.8 * aMul), 18)
    -- зрачок
    ellipse(dl, ix, iy + ry * 0.05, irisR * 0.42, min(ry * 0.62, irisR * 0.72), colRaw(0x241A33, 0.95 * aMul), 16)
    -- блики
    dl:AddCircleFilled(V(ix - irisR * 0.34, iy - ry * 0.32), w * 0.115, colRaw(0xFFFFFF, 0.95 * aMul), 12)
    dl:AddCircleFilled(V(ix + irisR * 0.36, iy + ry * 0.34), w * 0.055, colRaw(0xFFFFFF, 0.7 * aMul), 8)
    -- верхнее веко и ресница
    bezier(dl, { x - w * 0.5, y - ry * 0.56 }, { x - w * 0.2, y - ry * 1.16 }, { x + w * 0.2, y - ry * 1.16 },
           { x + w * 0.52, y - ry * 0.66 }, lineCol, max(1.8, h * 0.15), 14)
    polyFill(dl, {
        { x + w * 0.48, y - ry * 0.72 },
        { x + w * 0.70, y - ry * 1.04 },
        { x + w * 0.42, y - ry * 0.36 },
    }, lineCol)
end

local function drawMouth(dl, kind, x, y, s, aMul)
    local lineCol = colRaw(0x4A2B3C, 0.92 * aMul)
    if kind == 'open' then
        local pts = ellipsePts(x, y + s * 0.6, s * 1.15, s * 1.05, 18, 0, 0, pi)
        pts[#pts + 1] = { x - s * 1.15, y + s * 0.6 }
        polyFill(dl, pts, colRaw(0x6E2A3E, 0.95 * aMul))
        polyFill(dl, ellipsePts(x, y + s * 1.25, s * 0.62, s * 0.42, 14, 0, 0, pi), colRaw(0xE7768F, 0.95 * aMul))
    elseif kind == 'o' then
        ellipse(dl, x, y + s * 0.5, s * 0.62, s * 0.85, colRaw(0x6E2A3E, 0.95 * aMul), 16)
    elseif kind == 'cat' then
        bezier(dl, { x - s * 1.1, y }, { x - s * 0.6, y + s * 0.9 }, { x - s * 0.1, y + s * 0.1 }, { x, y + s * 0.2 },
               lineCol, 1.8, 10)
        bezier(dl, { x, y + s * 0.2 }, { x + s * 0.1, y + s * 0.1 }, { x + s * 0.6, y + s * 0.9 }, { x + s * 1.1, y },
               lineCol, 1.8, 10)
    elseif kind == 'wave' then
        bezier(dl, { x - s * 1.1, y + s * 0.3 }, { x - s * 0.45, y - s * 0.5 }, { x + s * 0.45, y + s * 0.9 },
               { x + s * 1.1, y + s * 0.1 }, lineCol, 1.8, 14)
    else -- smile
        bezier(dl, { x - s * 0.85, y }, { x - s * 0.3, y + s * 0.85 }, { x + s * 0.3, y + s * 0.85 },
               { x + s * 0.85, y }, lineCol, 1.9, 12)
    end
end

--[[ Полная отрисовка персонажа.
     cx, cy — центр головы; s — масштаб (1.0 ≈ голова радиусом 52 px) ]]
local function drawGirl(dl, cx, cy, s, aMul, headOnly)
    local th = T()
    local g = Guide
    local R = 52 * s
    local tilt = g.tilt
    local bob = sin(g.breathe * 1.6) * 2.2 * s
    cy = cy + bob

    local function rot(px, py)        -- поворот вокруг центра головы
        local dx, dy = px - cx, py - cy
        local c, sn = cos(tilt), sin(tilt)
        return cx + dx * c - dy * sn, cy + dx * sn + dy * c
    end
    local function P(px, py) local a, b = rot(px, py) return { a, b } end

    local hairDark  = shade(th.hair2, 0.78)
    local hairMid   = th.hair2
    local hairLight = th.hair1

    -- мягкий ореол за фигурой
    glow(dl, cx, cy + R * 0.2, R * 2.8, th.a1, 0.10 * aMul, 8, true)

    if not headOnly then
        -- ── тело ──────────────────────────────────────────────────────────
        local bodyTop = cy + R * 0.78
        -- задние волосы (длинные, за спиной)
        local sway = sin(g.hair) * 5 * s
        polyFill(dl, {
            P(cx - R * 1.02, cy - R * 0.1), P(cx - R * 1.34, cy + R * 1.5),
            P(cx - R * 1.05 + sway, cy + R * 2.5), P(cx - R * 0.5 + sway, cy + R * 2.55),
            P(cx - R * 0.36, cy + R * 1.1),
        }, colRaw(hairDark, 0.98 * aMul))
        polyFill(dl, {
            P(cx + R * 1.02, cy - R * 0.1), P(cx + R * 1.34, cy + R * 1.5),
            P(cx + R * 1.05 - sway, cy + R * 2.5), P(cx + R * 0.5 - sway, cy + R * 2.55),
            P(cx + R * 0.36, cy + R * 1.1),
        }, colRaw(hairDark, 0.98 * aMul))

        -- шея
        dl:AddRectFilled(V(cx - R * 0.2, cy + R * 0.55), V(cx + R * 0.2, bodyTop + R * 0.2),
                         colRaw(C.skinSh, 0.98 * aMul), R * 0.12)
        -- плечи / школьная форма
        local bx1, bx2 = cx - R * 1.12, cx + R * 1.12
        local by1, by2 = bodyTop, cy + R * 2.9
        for i = 0, 16 do
            local t = i / 16
            local yy = lerp(by1, by2, t)
            local ww = lerp(R * 0.62, R * 1.16, easeOutCubic(min(1, t * 2.2)))
            dl:AddRectFilled(V(cx - ww, yy), V(cx + ww, yy + (by2 - by1) / 16 + 1),
                             colRaw(mixHex(C.clothHi, C.cloth, t), 0.99 * aMul), i == 0 and R * 0.3 or 0, CORNER.top)
        end
        -- рукава
        ellipse(dl, bx1 + R * 0.16, by1 + R * 0.72, R * 0.3, R * 0.5, colRaw(C.cloth, 0.99 * aMul), 18)
        ellipse(dl, bx2 - R * 0.16, by1 + R * 0.72, R * 0.3, R * 0.5, colRaw(C.cloth, 0.99 * aMul), 18)
        -- матросский воротник
        polyFill(dl, {
            { cx - R * 0.72, by1 + R * 0.02 }, { cx - R * 0.16, by1 + R * 0.02 },
            { cx, by1 + R * 0.6 }, { cx - R * 0.5, by1 + R * 0.78 },
        }, colRaw(0xF3F1FA, 0.98 * aMul))
        polyFill(dl, {
            { cx + R * 0.72, by1 + R * 0.02 }, { cx + R * 0.16, by1 + R * 0.02 },
            { cx, by1 + R * 0.6 }, { cx + R * 0.5, by1 + R * 0.78 },
        }, colRaw(0xF3F1FA, 0.98 * aMul))
        -- бант
        local bwx, bwy = cx, by1 + R * 0.5
        polyFill(dl, { { bwx, bwy }, { bwx - R * 0.42, bwy - R * 0.2 }, { bwx - R * 0.42, bwy + R * 0.24 } },
                 colRaw(th.a1, 0.98 * aMul))
        polyFill(dl, { { bwx, bwy }, { bwx + R * 0.42, bwy - R * 0.2 }, { bwx + R * 0.42, bwy + R * 0.24 } },
                 colRaw(th.a1, 0.98 * aMul))
        dl:AddCircleFilled(V(bwx, bwy), R * 0.11, colRaw(shade(th.a1, 1.18), 0.99 * aMul), 12)
        polyFill(dl, { { bwx - R * 0.08, bwy + R * 0.06 }, { bwx + R * 0.08, bwy + R * 0.06 },
                       { bwx + R * 0.02, bwy + R * 0.95 } }, colRaw(shade(th.a1, 0.92), 0.95 * aMul))
    end

    -- ── голова ────────────────────────────────────────────────────────────
    local hp = ellipsePts(cx, cy, R * 0.9, R * 0.98, 30)
    for i, p in ipairs(hp) do local a, b = rot(p[1], p[2]) hp[i] = { a, b } end
    polyFill(dl, hp, colRaw(C.skin, 0.99 * aMul))
    -- тень под чёлкой
    local sp = ellipsePts(cx, cy - R * 0.36, R * 0.82, R * 0.4, 22)
    for i, p in ipairs(sp) do local a, b = rot(p[1], p[2]) sp[i] = { a, b } end
    polyFill(dl, sp, colRaw(C.skinSh, 0.55 * aMul))

    -- румянец
    local blushA = g.blush * 0.55 * aMul
    for _, sgn in ipairs({ -1, 1 }) do
        local bxp, byp = rot(cx + sgn * R * 0.56, cy + R * 0.38)
        ellipse(dl, bxp, byp, R * 0.22, R * 0.13, colRaw(0xFF9BB8, blushA), 16)
        for k = -1, 1 do
            local x1, y1 = rot(cx + sgn * R * (0.56 + k * 0.09), cy + R * 0.33)
            local x2, y2 = rot(cx + sgn * R * (0.56 + k * 0.09) - sgn * R * 0.04, cy + R * 0.44)
            dl:AddLine(V(x1, y1), V(x2, y2), colRaw(0xF07A9E, blushA * 1.4), 1.4 * s)
        end
    end

    -- глаза
    local e = EMO[g.emotion] or EMO.idle
    local eyeW, eyeH = R * 0.46, R * 0.60
    local lx, ly = rot(cx - R * 0.40, cy + R * 0.14)
    local rx, ry = rot(cx + R * 0.40, cy + R * 0.14)
    local look = { g.pupilX, g.pupilY }
    drawEye(dl, lx, ly, eyeW, eyeH, g.eye, look, e.arc, e.wink and true or false, th, aMul)
    drawEye(dl, rx, ry, eyeW, eyeH, g.eye, look, e.arc, false, th, aMul)

    -- нос и рот
    local nx, ny = rot(cx + R * 0.03, cy + R * 0.44)
    dl:AddLine(V(nx, ny), V(nx - R * 0.05, ny + R * 0.05), colRaw(C.skinSh, 0.9 * aMul), 1.6 * s)
    local mx, my = rot(cx, cy + R * 0.62)
    drawMouth(dl, e.mouth, mx, my, R * 0.11, aMul)

    -- ── волосы ────────────────────────────────────────────────────────────
    -- макушка
    local crown = ellipsePts(cx, cy - R * 0.24, R * 0.96, R * 0.88, 26, 0, pi, pi * 2)
    for i, p in ipairs(crown) do local a, b = rot(p[1], p[2]) crown[i] = { a, b } end
    polyFill(dl, crown, colRaw(hairMid, 0.99 * aMul))

    -- чёлка: пряди-клинья, широкие у корней и острые на кончиках
    local fringeCol = colRaw(shade(hairMid, 0.93), 0.99 * aMul)
    local fringe = {
        --  левый край,  правый край, кончик X, кончик Y
        { -0.99, -0.50, -0.86,  0.30 },
        { -0.72, -0.22, -0.44, -0.08 },
        { -0.34,  0.18,  0.00,  0.04 },   -- центральная прядь спускается ниже
        {  0.14,  0.66,  0.42, -0.08 },
        {  0.50,  0.99,  0.86,  0.30 },
    }
    for i, fr in ipairs(fringe) do
        local sway = sin(g.hair * 0.9 + i * 1.3) * 0.022
        polyFill(dl, {
            P(cx + fr[1] * R, cy - R * 0.62),
            P(cx + fr[2] * R, cy - R * 0.62),
            P(cx + (fr[3] + sway) * R, cy + fr[4] * R),
        }, fringeCol)
    end
    -- блик на волосах
    local shine = ellipsePts(cx - R * 0.1, cy - R * 0.58, R * 0.55, R * 0.11, 20, -0.14)
    for i, p in ipairs(shine) do local a, b = rot(p[1], p[2]) shine[i] = { a, b } end
    polyFill(dl, shine, colRaw(hairLight, 0.55 * aMul))

    -- брови поверх чёлки — иначе эмоции не читаются
    for _, sgn in ipairs({ -1, 1 }) do
        local by = cy - R * 0.24 + g.brow * R * 0.14 * sgn
        local p0 = P(cx + sgn * R * 0.20, by + R * 0.05)
        local c0 = P(cx + sgn * R * 0.38, by - R * 0.08)
        local c1 = P(cx + sgn * R * 0.52, by - R * 0.06)
        local p1 = P(cx + sgn * R * 0.62, by + R * 0.02)
        bezier(dl, p0, c0, c1, p1, colRaw(shade(hairMid, 0.62), 0.62 * aMul), 2.2 * s, 10)
    end
    -- боковые пряди
    for _, sgn in ipairs({ -1, 1 }) do
        polyFill(dl, {
            P(cx + sgn * R * 0.96, cy - R * 0.5),
            P(cx + sgn * R * 1.12, cy + R * 0.6),
            P(cx + sgn * R * 0.78, cy + R * 0.92),
            P(cx + sgn * R * 0.72, cy - R * 0.2),
        }, colRaw(mixHex(hairMid, hairDark, 0.35), 0.99 * aMul))
    end

    -- ахогэ (торчащий локон)
    local ah = sin(g.breathe * 2.1) * 0.14
    bezier(dl,
        P(cx - R * 0.04, cy - R * 0.88),
        P(cx + R * 0.06, cy - R * 1.32),
        P(cx + R * (0.34 + ah), cy - R * 1.44),
        P(cx + R * (0.46 + ah * 1.4), cy - R * 1.18),
        colRaw(hairMid, 0.99 * aMul), 3.4 * s, 18)

    -- заколка-сакура
    local px, py = rot(cx - R * 0.78, cy - R * 0.52)
    sakura(dl, px, py, R * 0.26, g.breathe * 0.25, th.a1, aMul, true)
end

-- --- реплика ----------------------------------------------------------------

local function wrapUtf8(f, str, maxw)
    local lines, cur = {}, ''
    for word in str:gmatch('%S+') do
        local probe = (cur == '') and word or (cur .. ' ' .. word)
        if measure(f, probe) > maxw and cur ~= '' then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = probe
        end
    end
    if cur ~= '' then lines[#lines + 1] = cur end
    local out = {}
    for i, ln in ipairs(lines) do out[i] = { str = ln, chars = utf8chars(ln) } end
    return out
end

local function drawBubble(dl, g, ax, ay, side, s, screenW)
    local a = easeOutCubic(clamp(g.bubble, 0, 1))
    if a < 0.02 or not g.text then return end
    local th = T()
    local pad = 16 * s
    local w = 300 * s
    local lineH = select(2, measure(F.text, 'Ай')) + 4

    if g.wrapKey ~= g.text then
        g.lines = wrapUtf8(F.text, g.text, w - pad * 2)
        g.wrapKey = g.text
    end
    local h = pad * 2 + 22 * s + #g.lines * lineH

    -- облачко прижимается к своему краю экрана, чтобы не наползать на меню
    local margin = 24 * s
    local x1 = (side == 2) and (screenW - margin - w) or margin
    local x2 = x1 + w
    local y2 = ay - 26 * s - (1 - a) * 18
    local y1 = y2 - h
    local rr = 16 * s

    -- тень + подложка
    for i = 5, 1, -1 do
        dl:AddRectFilled(V(x1 - i, y1 - i * 0.6), V(x2 + i, y2 + i),
                         colRaw(C.shadow, 0.07 * a), rr + i, CORNER.all)
    end
    for i = 0, 14 do
        local t = i / 14
        local yy = lerp(y1, y2, t)
        local cor = (i == 0 and CORNER.top) or (i == 14 and CORNER.bottom) or 0
        dl:AddRectFilled(V(x1, yy), V(x2, yy + h / 14 + 1),
                         colRaw(mixHex(0x241D33, 0x1A1526, t), 0.95 * a), cor > 0 and rr or 0, cor)
    end
    dl:AddRect(V(x1, y1), V(x2, y2), colRaw(th.a1, 0.4 * a), rr, CORNER.all, 1.4)

    -- хвостик вниз, к голове персонажа
    local tipX = clamp(ax, x1 + 34 * s, x2 - 34 * s)
    polyFill(dl, {
        { tipX - 11 * s, y2 - 3 },
        { tipX + 11 * s, y2 - 3 },
        { tipX + (side == 2 and -3 or 3) * s, y2 + 15 * s },
    }, colRaw(0x1A1526, 0.95 * a))

    -- шапка: цветок + имя
    sakura(dl, x1 + pad + 7 * s, y1 + pad + 6 * s, 8 * s, g.breathe * 0.5, th.a1, a, true)
    text(dl, F.small, x1 + pad + 20 * s, y1 + pad - 3 * s, colRaw(th.a1, 0.95 * a), g.name)
    -- сердечко
    local hx, hy = x1 + pad + 30 * s + measure(F.small, g.name), y1 + pad + 2 * s
    local hs = 4 * s * (1 + sin(g.breathe * 3) * 0.12)
    dl:AddCircleFilled(V(hx, hy), hs, colRaw(th.a2, 0.8 * a), 8)
    dl:AddCircleFilled(V(hx + hs * 1.5, hy), hs, colRaw(th.a2, 0.8 * a), 8)
    polyFill(dl, { { hx - hs, hy + hs * 0.4 }, { hx + hs * 2.5, hy + hs * 0.4 },
                   { hx + hs * 0.75, hy + hs * 2.6 } }, colRaw(th.a2, 0.8 * a))
    dl:AddLine(V(x1 + pad, y1 + pad + 14 * s), V(x2 - pad, y1 + pad + 14 * s), colRaw(C.line, 0.6 * a), 1)

    -- текст с эффектом печатной машинки
    local remain = floor(g.chars)
    local ty = y1 + pad + 22 * s
    for _, ln in ipairs(g.lines) do
        if remain <= 0 then break end
        local take = min(#ln.chars, remain)
        text(dl, F.text, x1 + pad, ty, colRaw(C.text, 0.95 * a), table.concat(ln.chars, '', 1, take))
        remain = remain - take
        ty = ty + lineH
    end

    -- маркер «дочитано»
    if g.chars >= g.total then
        local bl = (sin(g.breathe * 4) * 0.5 + 0.5)
        polyFill(dl, {
            { x2 - pad - 8 * s, y2 - pad * 0.6 - 4 * s },
            { x2 - pad, y2 - pad * 0.6 - 4 * s },
            { x2 - pad - 4 * s, y2 - pad * 0.6 + 1 * s },
        }, colRaw(th.a1, (0.35 + bl * 0.55) * a))
    end
end

function Guide:draw(dl, SW, SH)
    local a = easeOutCubic(clamp(self.vis, 0, 1))
    if a < 0.01 then return end
    local s = cfg.guide.scale
    local side = cfg.guide.side
    local x = side == 2 and (SW - 165 * s) or (165 * s)
    local baseY = SH + 44 * s
    local y = baseY + (1 - a) * 190 * s        -- выезжает снизу
    local headY = y - 250 * s

    drawGirl(dl, x, headY, s, a)
    drawBubble(dl, self, x, headY - 62 * s, side, s, SW)
end

-- ============================================================================
--  ПОДСКАЗКИ ПО НАВЕДЕНИЮ
-- ============================================================================

local Hint = { key = nil, timer = 0, said = nil, pending = nil }

local function hint(key, str, emotion)
    Hint.pending = { key = key, str = str, emotion = emotion }
end

local function hintUpdate(dt)
    local p = Hint.pending
    Hint.pending = nil
    if not cfg.main.hints or not cfg.guide.enabled then return end
    if p then
        if p.key ~= Hint.key then
            Hint.key, Hint.timer, Hint.said = p.key, 0, nil
        end
        Hint.timer = Hint.timer + dt
        if Hint.timer > 0.30 and Hint.said ~= p.key then
            Hint.said = p.key
            Guide:say(p.str, p.emotion, 4.5)
        end
    else
        Hint.key, Hint.timer = nil, 0
    end
end

-- ============================================================================
--  СОСТОЯНИЕ МЕНЮ
-- ============================================================================

local SW, SH = getScreenResolution()

local dt = 1 / 60        -- время кадра, обновляется в OnFrame

local Menu = {
    open   = false,
    anim   = 0,
    tab    = 1,
    tabPos = 1,          -- анимированное положение индикатора вкладок
    x      = SW / 2 - 390,
    y      = SH / 2 - 260,
    w      = 780,
    h      = 520,
}

local TABS = {
    { name = 'Обзор',       jp = 'ホーム', icon = 'home',  sub = 'Состояние скрипта и быстрые действия' },
    { name = 'Функции',     jp = '機能',   icon = 'spark', sub = 'Модули и то, что они делают' },
    { name = 'Внешний вид', jp = '外観',   icon = 'drop',  sub = 'Тема, скругления, эффекты' },
    { name = 'Гид',         jp = '案内',   icon = 'heart', sub = 'Настройки твоей помощницы' },
    { name = 'О скрипте',   jp = '情報',   icon = 'info',  sub = 'Версия, клавиши, благодарности' },
}

local anim = {}                       -- значения плавных переходов по ключам
local function A(key, target, speed, dt)
    anim[key] = approach(anim[key] or 0, target, (speed or 12) * cfg.ui.speed, dt)
    return anim[key]
end

local function R() return cfg.ui.rounding end

-- ============================================================================
--  ИКОНКИ (векторные)
-- ============================================================================

local function icon(dl, kind, cx, cy, s, color)
    if kind == 'home' then
        polyFill(dl, { { cx, cy - s }, { cx + s, cy - s * 0.05 }, { cx - s, cy - s * 0.05 } }, color)
        dl:AddRectFilled(V(cx - s * 0.66, cy - s * 0.15), V(cx + s * 0.66, cy + s * 0.8), color, s * 0.16)
    elseif kind == 'spark' then
        polyFill(dl, { { cx, cy - s }, { cx + s * 0.34, cy - s * 0.24 }, { cx, cy + s * 0.5 },
                       { cx - s * 0.34, cy - s * 0.24 } }, color)
        polyFill(dl, { { cx + s * 0.72, cy + s * 0.1 }, { cx + s * 0.92, cy + s * 0.5 },
                       { cx + s * 0.52, cy + s * 0.5 } }, color)
        dl:AddCircleFilled(V(cx - s * 0.66, cy + s * 0.52), s * 0.18, color, 8)
    elseif kind == 'drop' then
        polyFill(dl, { { cx, cy - s }, { cx + s * 0.68, cy + s * 0.24 }, { cx, cy + s * 0.86 },
                       { cx - s * 0.68, cy + s * 0.24 } }, color)
    elseif kind == 'heart' then
        local r = s * 0.42
        dl:AddCircleFilled(V(cx - r * 0.85, cy - r * 0.3), r, color, 12)
        dl:AddCircleFilled(V(cx + r * 0.85, cy - r * 0.3), r, color, 12)
        polyFill(dl, { { cx - r * 1.72, cy - r * 0.05 }, { cx + r * 1.72, cy - r * 0.05 },
                       { cx, cy + s * 0.92 } }, color)
    elseif kind == 'info' then
        dl:AddCircle(V(cx, cy), s * 0.85, color, 20, 1.8)
        dl:AddCircleFilled(V(cx, cy - s * 0.4), s * 0.13, color, 8)
        dl:AddRectFilled(V(cx - s * 0.1, cy - s * 0.13), V(cx + s * 0.1, cy + s * 0.5), color, s * 0.1)
    end
end

-- крестик закрытия
local function closeGlyph(dl, cx, cy, s, color, th)
    dl:AddLine(V(cx - s, cy - s), V(cx + s, cy + s), color, th or 1.8)
    dl:AddLine(V(cx + s, cy - s), V(cx - s, cy + s), color, th or 1.8)
end

-- ============================================================================
--  ВИДЖЕТЫ
-- ============================================================================

-- Тумблер в строке настроек
local function rowToggle(dl, x, y, w, id, title, desc, value, tip)
    local h = 54
    imgui.SetCursorScreenPos(V(x, y))
    local clicked = imgui.InvisibleButton('##row_' .. id, V(w, h))
    local hov = imgui.IsItemHovered()
    local hv = A('rh_' .. id, hov and 1 or 0, 14, dt)
    local tv = A('rt_' .. id, value and 1 or 0, 16, dt)
    local th = T()

    dl:AddRectFilled(V(x, y), V(x + w, y + h), col(C.panelHi, 0.5 * hv + 0.34), R() * 0.7)
    if hv > 0.01 then
        dl:AddRectFilled(V(x, y + h * 0.25), V(x + 2.5, y + h * 0.75), col(th.a1, 0.9 * hv), 2)
    end

    text(dl, F.text, x + 18, y + 11, col(C.text, 0.92 + 0.08 * hv), ellipsize(F.text, title, w - 100))
    text(dl, F.small, x + 18, y + 30, col(C.dim, 0.85), ellipsize(F.small, desc, w - 100))

    -- переключатель
    local tw, tht = 46, 24
    local tx, ty = x + w - 18 - tw, y + (h - tht) / 2
    local trackHex = mixHex(0x342B48, th.a1, tv)
    dl:AddRectFilled(V(tx, ty), V(tx + tw, ty + tht), col(trackHex, 0.95), tht / 2)
    if tv > 0.02 then
        glow(dl, tx + tw - tht / 2, ty + tht / 2, 20, th.a1, 0.5 * tv, 4)
    end
    dl:AddRect(V(tx, ty), V(tx + tw, ty + tht), col(C.white, 0.07 + 0.12 * tv), tht / 2, CORNER.all, 1)
    local kx = lerp(tx + tht / 2, tx + tw - tht / 2, easeOutCubic(tv))
    dl:AddCircleFilled(V(kx, ty + tht / 2), tht / 2 - 3, col(C.white, 0.97), 20)
    if tv > 0.4 then
        sakura(dl, kx, ty + tht / 2, 5.4, Guide.breathe * 0.8, th.a1, (tv - 0.4) / 0.6)
    end

    if hov and tip then hint(id, tip, value and 'idle' or 'think') end
    return clicked
end

-- Слайдер в строке настроек
local function rowSlider(dl, x, y, w, id, title, value, minv, maxv, fmt, tip)
    local h = 50
    local th = T()
    local trackW = 210
    local tx = x + w - 18 - trackW
    local ty = y + h / 2

    imgui.SetCursorScreenPos(V(x, y))
    imgui.InvisibleButton('##rowbg_' .. id, V(w, h))
    local rowHov = imgui.IsItemHovered()

    imgui.SetCursorScreenPos(V(tx - 8, ty - 12))
    imgui.InvisibleButton('##sl_' .. id, V(trackW + 16, 24))
    local hov = imgui.IsItemHovered()
    local act = imgui.IsItemActive()
    if act then
        local mx = imgui.GetIO().MousePos.x
        value = minv + clamp((mx - tx) / trackW, 0, 1) * (maxv - minv)
    end

    local hv = A('sh_' .. id, (hov or act) and 1 or 0, 14, dt)
    local t = (value - minv) / (maxv - minv)

    dl:AddRectFilled(V(x, y), V(x + w, y + h), col(C.panelHi, 0.3 + 0.2 * hv), R() * 0.7)
    text(dl, F.text, x + 18, y + h / 2 - 9, col(C.text, 0.92), title)

    dl:AddRectFilled(V(tx, ty - 3), V(tx + trackW, ty + 3), col(0x322A45, 0.95), 3)
    if t > 0 then
        gradientRect(dl, tx, ty - 3, tx + trackW * t, ty + 3, th.a1, th.a2, 1, 1, 3, CORNER.all, 6)
    end
    local kx = tx + trackW * t
    glow(dl, kx, ty, 16 + 6 * hv, th.a1, 0.45 + 0.35 * hv, 4)
    dl:AddCircleFilled(V(kx, ty), 8 + hv, col(C.white, 0.98), 20)
    dl:AddCircleFilled(V(kx, ty), 3.4, col(th.a1, 0.95), 12)
    textR(dl, F.small, x + w - 18 - trackW - 16, ty - 8, col(C.dim, 0.95), string.format(fmt, value))

    if (hov or rowHov) and tip then hint(id, tip, 'think') end
    return value
end

-- Кнопка
local function button(dl, x, y, w, h, id, label, primary, tip)
    imgui.SetCursorScreenPos(V(x, y))
    local clicked = imgui.InvisibleButton('##btn_' .. id, V(w, h))
    local hov = imgui.IsItemHovered()
    local act = imgui.IsItemActive()
    local hv = A('bh_' .. id, hov and 1 or 0, 16, dt)
    local th = T()
    local lift = act and 1 or 0
    y = y + lift

    if primary then
        gradientRect(dl, x, y, x + w, y + h, shade(th.a1, 1.0 + 0.12 * hv), shade(th.a2, 0.92),
                     1, 1, R() * 0.75, CORNER.all, 12)
        if hv > 0.01 then glow(dl, x + w / 2, y + h / 2, w * 0.7, th.a1, 0.28 * hv, 4) end
        textC(dl, F.text, x + w / 2, y + h / 2 - 9, col(0x2A1526, 0.95), label)
    else
        dl:AddRectFilled(V(x, y), V(x + w, y + h), col(C.panelHi, 0.6 + 0.35 * hv), R() * 0.75)
        dl:AddRect(V(x, y), V(x + w, y + h), col(th.a1, 0.2 + 0.5 * hv), R() * 0.75, CORNER.all, 1.2)
        textC(dl, F.text, x + w / 2, y + h / 2 - 9, col(C.text, 0.85 + 0.15 * hv), label)
    end
    if hov and tip then hint(id, tip, 'happy') end
    return clicked
end

-- Сегментированный переключатель
local function segmented(dl, x, y, w, h, id, items, current, tip)
    local th = T()
    local segW = w / #items
    local res = current
    dl:AddRectFilled(V(x, y), V(x + w, y + h), col(0x2A2340, 0.85), h / 2)
    local sp = A('seg_' .. id, current - 1, 16, dt)
    gradientRect(dl, x + 3 + sp * segW, y + 3, x + segW - 3 + sp * segW, y + h - 3,
                 th.a1, th.a2, 1, 1, (h - 6) / 2, CORNER.all, 8)
    for i, it in ipairs(items) do
        local sx = x + segW * (i - 1)
        imgui.SetCursorScreenPos(V(sx, y))
        if imgui.InvisibleButton('##seg_' .. id .. i, V(segW, h)) then res = i end
        local on = clamp(1 - math.abs(sp - (i - 1)), 0, 1)
        textC(dl, F.small, sx + segW / 2, y + h / 2 - 8,
              col(mixHex(C.dim, 0x2A1526, on), 0.95), it)
        if imgui.IsItemHovered() and tip then hint(id, tip, 'idle') end
    end
    return res
end

-- Карточка-контейнер
local function card(dl, x, y, w, h, title, kicker)
    dl:AddRectFilled(V(x, y), V(x + w, y + h), col(C.panel, 0.72), R() * 0.9)
    dl:AddRect(V(x, y), V(x + w, y + h), col(C.line, 0.85), R() * 0.9, CORNER.all, 1)
    dl:AddLine(V(x + R() * 0.9, y + 1), V(x + w - R() * 0.9, y + 1), col(C.white, 0.05), 1)
    if title then
        local th = T()
        dl:AddRectFilled(V(x + 18, y + 20), V(x + 20.5, y + 32), col(th.a1, 0.9), 1.5)
        text(dl, F.h1, x + 30, y + 15, col(C.text, 0.95), title)
        if kicker then textR(dl, F.small, x + w - 18, y + 19, col(C.mute, 0.95), kicker) end
    end
end

-- Мелкая метка-капслок
local function kicker(dl, x, y, str, hex)
    text(dl, F.tiny, x, y, col(hex or T().a1, 0.8), string.upper(str))
end

-- Информационная плашка с цветком-маркером
local function notice(dl, x, y, w, line1, line2)
    local th = T()
    local h = line2 and 60 or 42
    dl:AddRectFilled(V(x, y), V(x + w, y + h), col(mixHex(C.panel, th.a1, 0.06), 0.5), R() * 0.7)
    dl:AddRectFilled(V(x, y + 8), V(x + 2.5, y + h - 8), col(th.a1, 0.7), 1.5)
    sakura(dl, x + 24, y + h / 2, 9, Guide.breathe * 0.22, th.a1, 0.85)
    text(dl, F.small, x + 42, y + (line2 and 12 or h / 2 - 8), col(C.dim, 0.92),
         ellipsize(F.small, line1, w - 60))
    if line2 then
        text(dl, F.small, x + 42, y + 32, col(C.mute, 0.92), ellipsize(F.small, line2, w - 60))
    end
end

-- ============================================================================
--  СОДЕРЖИМОЕ ВКЛАДОК
-- ============================================================================

local startClock = os.clock()

local PHRASES = {
    'Если что-то непонятно — просто наведи курсор, я подскажу.',
    'Тебе идёт эта тема оформления. Правда-правда!',
    'Не забывай отдыхать, ладно? Я подожду тут.',
    'Лепестки сакуры настроены на самый уютный режим.',
    'Могу помолчать, если мешаю. Но мне нравится болтать~',
    'Слышала, F4 открывает меня быстрее всего.',
}

-- совет дня выбирается один раз за сессию, чтобы не мигал каждый кадр
local TIP_OF_DAY = PHRASES[math.random(#PHRASES)]

local function activeModules()
    local n = 0
    for _, v in ipairs({ cfg.main.clock, cfg.main.fps, cfg.main.greeting, cfg.main.hints, cfg.guide.enabled }) do
        if v then n = n + 1 end
    end
    return n
end

local function tabHome(dl, x, y, w, h)
    local th = T()
    -- приветственная карточка
    local cw = w * 0.56
    card(dl, x, y, cw, 152)
    kicker(dl, x + 20, y + 20, 'Добро пожаловать')
    text(dl, F.title, x + 20, y + 36, col(C.text, 0.96), 'Sakura UI')
    text(dl, F.small, x + 20, y + 66, col(C.dim, 0.95), 'Интерфейс с живым гидом.')
    text(dl, F.small, x + 20, y + 84, col(C.dim, 0.95), 'Наводи курсор — она объяснит.')
    if button(dl, x + 20, y + 108, 132, 30, 'hi', 'Позвать гида', true,
              'Я всегда рядом — стоит только позвать.') then
        Guide:say('Я тут! Что будем настраивать сегодня?', 'happy', 4)
    end
    if button(dl, x + 162, y + 108, 100, 30, 'rnd', 'Совет', false,
              'Нажми — расскажу что-нибудь полезное.') then
        Guide:say(PHRASES[math.random(#PHRASES)], 'wink', 4.5)
    end
    -- декоративная ветка в верхнем углу карточки
    glow(dl, x + cw - 40, y + 34, 60, th.a1, 0.16, 4)
    sakura(dl, x + cw - 38, y + 32, 18, Guide.breathe * 0.2, th.a1, 0.4)
    sakura(dl, x + cw - 68, y + 20, 10, -Guide.breathe * 0.3, th.a2, 0.28)

    -- статистика
    local sx = x + cw + 16
    local sw = w - cw - 16
    local stats = {
        { 'FPS', string.format('%.0f', imgui.GetIO().Framerate) },
        { 'Время', os.date('%H:%M') },
        { 'В сети', string.format('%d мин', floor((os.clock() - startClock) / 60)) },
    }
    for i, st in ipairs(stats) do
        local cy = y + (i - 1) * 52
        dl:AddRectFilled(V(sx, cy), V(sx + sw, cy + 44), col(C.panel, 0.7), R() * 0.8)
        dl:AddRect(V(sx, cy), V(sx + sw, cy + 44), col(C.line, 0.8), R() * 0.8, CORNER.all, 1)
        dl:AddRectFilled(V(sx, cy + 12), V(sx + 2.5, cy + 32), col(th.a1, 0.85), 1.5)
        text(dl, F.small, sx + 16, cy + 6, col(C.mute, 0.95), st[1])
        text(dl, F.h1, sx + 16, cy + 20, col(C.text, 0.95), st[2])
    end

    -- модули
    y = y + 168
    local cardH = h - 168 - 4
    card(dl, x, y, w, cardH, 'Активные модули',
         string.format('%d из 5', activeModules()))
    local items = {
        { 'Часы на экране',      cfg.main.clock },
        { 'Счётчик FPS',         cfg.main.fps },
        { 'Приветствие гида',    cfg.main.greeting },
        { 'Подсказки',           cfg.main.hints },
        { 'Гид-компаньон',       cfg.guide.enabled },
    }
    local ix, iy = x + 20, y + 52
    for i, it in ipairs(items) do
        local px = ix + ((i - 1) % 2) * (w - 40) / 2
        local py = iy + floor((i - 1) / 2) * 32
        local on = it[2]
        dl:AddCircleFilled(V(px + 6, py + 8), 4.5, col(on and th.a1 or 0x3E3456, 0.95), 12)
        if on then glow(dl, px + 6, py + 8, 14, th.a1, 0.5, 3) end
        text(dl, F.small, px + 20, py, col(on and C.text or C.mute, on and 0.92 or 0.8), it[1])
    end

    -- совет дня внизу карточки
    local ty = y + cardH - 44
    dl:AddLine(V(x + 20, ty), V(x + w - 20, ty), col(C.line, 0.7), 1)
    sakura(dl, x + 29, ty + 22, 8, Guide.breathe * 0.3, th.a1, 0.9)
    text(dl, F.small, x + 44, ty + 14, col(C.dim, 0.9),
         ellipsize(F.small, 'Совет: ' .. TIP_OF_DAY, w - 70))
end

local function tabMods(dl, x, y, w, h)
    kicker(dl, x + 2, y, 'Модули интерфейса')
    y = y + 20
    if rowToggle(dl, x, y, w, 'clock', 'Часы на экране',
                 'Аккуратный виджет с текущим временем в углу экрана', cfg.main.clock,
                 'Часы висят в правом верхнем углу и никому не мешают.') then
        cfg.main.clock = not cfg.main.clock
        Guide:say(cfg.main.clock and 'Часы включила. Теперь не потеряешься во времени~'
                                  or 'Убрала часы. Пусть экран отдохнёт.', 'happy', 3.5)
    end
    y = y + 60
    if rowToggle(dl, x, y, w, 'fps', 'Счётчик FPS',
                 'Показывает частоту кадров рядом с часами', cfg.main.fps,
                 'Полезно, когда хочется понять, тормозит игра или кажется.') then
        cfg.main.fps = not cfg.main.fps
    end
    y = y + 60
    if rowToggle(dl, x, y, w, 'greet', 'Приветствие при запуске',
                 'Гид здоровается, когда скрипт загрузился', cfg.main.greeting,
                 'Обещаю здороваться не слишком навязчиво.') then
        cfg.main.greeting = not cfg.main.greeting
    end
    y = y + 60
    if rowToggle(dl, x, y, w, 'hints', 'Подсказки при наведении',
                 'Гид объясняет элемент, на который наведён курсор', cfg.main.hints,
                 'Вот прямо как сейчас. Наводишь — я рассказываю.') then
        cfg.main.hints = not cfg.main.hints
        Guide:say(cfg.main.hints and 'Снова буду подсказывать!' or 'Хорошо, подсказки выключены.',
                  cfg.main.hints and 'happy' or 'idle', 3)
    end
    y = y + 84
    kicker(dl, x + 2, y - 22, 'Действия')
    if button(dl, x, y, 200, 38, 'reset', 'Сбросить настройки', false,
              'Вернёт всё к тому, как было при первом запуске.') then
        cfg.ui.theme, cfg.ui.rounding, cfg.ui.opacity = 1, 12, 0.96
        cfg.ui.petals, cfg.ui.density, cfg.ui.speed = true, 26, 1.0
        cfg.guide.enabled, cfg.guide.typing, cfg.guide.side, cfg.guide.scale = true, 34, 2, 1.0
        Petals:reset(cfg.ui.density)
        Guide:say('Готово, всё как в первый день. Начнём заново?', 'wink', 4)
    end
    if button(dl, x + 214, y, 150, 38, 'save', 'Сохранить', true,
              'Настройки лягут в sakura_ui.ini рядом со скриптом.') then
        inicfg.save(cfg, INI)
        Guide:say('Сохранила! Теперь всё останется как есть.', 'happy', 3.5)
    end

    notice(dl, x, y + 56, w,
           'Настройки сохраняются сами: при закрытии меню и при выгрузке скрипта.',
           'Файл: moonloader/config/' .. INI)
end

local function tabLook(dl, x, y, w, h)
    local th = T()
    kicker(dl, x + 2, y, 'Цветовая тема')
    y = y + 22
    for i, t in ipairs(THEMES) do
        local bx = x + (i - 1) * 118
        imgui.SetCursorScreenPos(V(bx, y))
        local clicked = imgui.InvisibleButton('##theme' .. i, V(108, 66))
        local hov = imgui.IsItemHovered()
        local sel = (cfg.ui.theme == i)
        local hv = A('th_' .. i, (hov or sel) and 1 or 0, 14, dt)
        dl:AddRectFilled(V(bx, y), V(bx + 108, y + 66), col(C.panelHi, 0.35 + 0.35 * hv), R() * 0.8)
        if sel then
            dl:AddRect(V(bx, y), V(bx + 108, y + 66), col(t.a1, 0.85), R() * 0.8, CORNER.all, 1.4)
        end
        -- превью-градиент
        gradientRect(dl, bx + 14, y + 12, bx + 94, y + 34, t.a1, t.a2, 1, 1, 7, CORNER.all, 10)
        if sel then glow(dl, bx + 54, y + 23, 46, t.a1, 0.35, 4) end
        textC(dl, F.small, bx + 54, y + 40, col(sel and C.text or C.dim, 0.95), t.name)
        if clicked then
            cfg.ui.theme = i
            Guide:say('Тема «' .. t.name .. '». Мой бант тоже перекрасился, видишь?', 'happy', 4)
        end
        if hov then hint('theme' .. i, 'Тема «' .. t.name .. '» — перекрашивает меню, лепестки и меня.', 'shy') end
    end

    y = y + 84
    kicker(dl, x + 2, y - 18, 'Форма и эффекты')
    cfg.ui.rounding = rowSlider(dl, x, y, w, 'round', 'Скругление углов', cfg.ui.rounding, 2, 20, '%.0f px',
                                'Чем больше, тем мягче выглядит меню.')
    y = y + 56
    cfg.ui.opacity = rowSlider(dl, x, y, w, 'opa', 'Плотность фона', cfg.ui.opacity, 0.55, 1.0, '%.2f',
                               'Прозрачность подложки — сквозь неё видно игру.')
    y = y + 56
    cfg.ui.speed = rowSlider(dl, x, y, w, 'spd', 'Скорость анимаций', cfg.ui.speed, 0.5, 2.0, '×%.2f',
                             'Ускоряет или замедляет все переходы разом.')
    y = y + 62
    if rowToggle(dl, x, y, w, 'pet', 'Лепестки сакуры',
                 'Медленный листопад внутри окна меню', cfg.ui.petals,
                 'Мой любимый эффект. Тихо падают и никого не трогают.') then
        cfg.ui.petals = not cfg.ui.petals
    end
    y = y + 60
    local before = cfg.ui.density
    cfg.ui.density = rowSlider(dl, x, y, w, 'den', 'Плотность лепестков', cfg.ui.density, 6, 60, '%.0f шт',
                               'Сколько лепестков кружится одновременно.')
    if floor(cfg.ui.density) ~= floor(before) then Petals:reset(floor(cfg.ui.density)) end
end

local function tabGuide(dl, x, y, w, h)
    kicker(dl, x + 2, y, 'Компаньон')
    y = y + 20
    if rowToggle(dl, x, y, w, 'gon', 'Показывать гида',
                 'Персонаж появляется у края экрана', cfg.guide.enabled,
                 'Если выключишь — я тихо уйду. Но буду скучать.') then
        cfg.guide.enabled = not cfg.guide.enabled
        if cfg.guide.enabled then
            Guide:say('Я вернулась! Скучал?', 'happy', 3.5)
        else
            Guide:silence()
        end
    end
    y = y + 62
    cfg.guide.typing = rowSlider(dl, x, y, w, 'typ', 'Скорость реплик', cfg.guide.typing, 8, 90, '%.0f зн/с',
                                 'Как быстро появляется текст в облачке.')
    y = y + 56
    cfg.guide.scale = rowSlider(dl, x, y, w, 'gsc', 'Размер персонажа', cfg.guide.scale, 0.7, 1.4, '×%.2f',
                                'Можно сделать меня компактнее, если мешаю обзору.')
    y = y + 62

    -- сторона экрана
    local h2 = 42
    dl:AddRectFilled(V(x, y), V(x + w, y + h2 + 12), col(C.panelHi, 0.34), R() * 0.7)
    text(dl, F.text, x + 18, y + 12, col(C.text, 0.92), 'Сторона экрана')
    local newSide = segmented(dl, x + w - 18 - 190, y + 8, 190, 34, 'side',
                              { 'Слева', 'Справа' }, cfg.guide.side,
                              'Выбери, с какой стороны мне стоять.')
    if newSide ~= cfg.guide.side then
        cfg.guide.side = newSide
        Guide:say(newSide == 1 and 'Перебралась налево. Так удобнее?' or 'Стою справа, как раньше.', 'idle', 3.5)
    end

    y = y + h2 + 36
    kicker(dl, x + 2, y - 22, 'Проверка')
    local emo = { { 'happy', 'Радость' }, { 'wink', 'Подмигнуть' }, { 'think', 'Задумчиво' }, { 'surprise', 'Ой!' } }
    for i, e in ipairs(emo) do
        if button(dl, x + (i - 1) * 118, y, 108, 34, 'emo' .. i, e[2], false,
                  'Посмотри, как меняется моё лицо.') then
            local lines = {
                happy    = 'Ня~ Настроение отличное!',
                wink     = 'Это между нами, хорошо?',
                think    = 'Хмм... дай подумать секундочку.',
                surprise = 'Ой! Не ожидала такого поворота.',
            }
            Guide:say(lines[e[1]], e[1], 3.5)
        end
    end

    notice(dl, x, y + 50, w,
           'Наведи курсор на любую строку — она объяснит, за что та отвечает.')
end

local function tabAbout(dl, x, y, w, h)
    local th = T()
    card(dl, x, y, w, 132, 'Sakura UI', 'версия 1.0.0')
    text(dl, F.small, x + 20, y + 48, col(C.dim, 0.95),
         'Меню и персонаж нарисованы кодом: ни одной внешней картинки,')
    text(dl, F.small, x + 20, y + 66, col(C.dim, 0.95),
         'только ImDrawList, немного тригонометрии и много терпения.')
    text(dl, F.small, x + 20, y + 92, col(C.mute, 0.95), 'mimgui · MoonLoader · Lua 5.1 (LuaJIT)')
    glow(dl, x + w - 48, y + 64, 66, th.a1, 0.14, 4)
    sakura(dl, x + w - 46, y + 62, 22, Guide.breathe * 0.15, th.a1, 0.34)
    sakura(dl, x + w - 84, y + 46, 11, -Guide.breathe * 0.22, th.a2, 0.24)

    y = y + 148
    local rows = {
        { 'Открыть меню',        'F4  или  /sakura' },
        { 'Закрыть меню',        'ESC' },
        { 'Файл настроек',       'moonloader/config/' .. INI },
        { 'Позвать гида',        '/sakura say' },
    }
    for i, r in ipairs(rows) do
        local ry = y + (i - 1) * 40
        dl:AddRectFilled(V(x, ry), V(x + w, ry + 34), col(C.panelHi, 0.3), R() * 0.6)
        text(dl, F.text, x + 18, ry + 8, col(C.dim, 0.95), r[1])
        -- клавиша-«капсула»
        local kw = measure(F.small, r[2]) + 22
        dl:AddRectFilled(V(x + w - 18 - kw, ry + 6), V(x + w - 18, ry + 28), col(0x2E2542, 0.9), 7)
        dl:AddRect(V(x + w - 18 - kw, ry + 6), V(x + w - 18, ry + 28), col(th.a1, 0.3), 7, CORNER.all, 1)
        textC(dl, F.small, x + w - 18 - kw / 2, ry + 10, col(C.text, 0.9), r[2])
    end

    y = y + #rows * 40 + 10
    dl:AddLine(V(x, y), V(x + w, y), col(C.line, 0.7), 1)
    sakura(dl, x + 9, y + 22, 8, Guide.breathe * 0.3, th.a1, 0.9)
    text(dl, F.small, x + 24, y + 14, col(C.mute, 0.9),
         'Меню, персонаж и анимации — чистый ImDrawList, без единого спрайта.')
end

-- ============================================================================
--  РАМА МЕНЮ
-- ============================================================================

local function drawMenu(dl, bg)
    local th = T()
    local x, y, w, h = Menu.x, Menu.y, Menu.w, Menu.h
    local rr = R()
    local slide = (1 - easeOutCubic(Menu.anim)) * 26
    y = y + slide

    -- тень (в фоновом списке — окно её не обрежет)
    for i = 10, 1, -1 do
        bg:AddRectFilled(V(x - i * 1.6, y - i * 1.1 + 4), V(x + w + i * 1.6, y + h + i * 1.6 + 4),
                         colRaw(C.shadow, 0.05 * ALPHA), rr + i * 1.4, CORNER.all)
    end
    glow(bg, x + w / 2, y + h / 2, 420, th.a2, 0.05 * ALPHA, 4)

    -- корпус
    gradientRect(dl, x, y, x + w, y + h, C.bgTop, C.bgBot, cfg.ui.opacity, cfg.ui.opacity, rr, CORNER.all, 26)
    -- боковая панель
    local railW = 200
    gradientRect(dl, x, y, x + railW, y + h, C.railTop, C.railBot,
                 cfg.ui.opacity, cfg.ui.opacity, rr, CORNER.left, 20)
    -- разделитель rail: к краям истончается до нуля
    for i = 0, 15 do
        local t = i / 15
        local fade = sin(t * pi)
        dl:AddLine(V(x + railW, y + 8 + (h - 16) * t), V(x + railW, y + 8 + (h - 16) * (t + 1 / 15)),
                   col(mixHex(C.line, T().a1, 0.25), 0.9 * fade), 1)
    end

    -- лепестки внутри окна (с отступом, чтобы не выползали за скруглённые углы)
    if cfg.ui.petals then
        Petals:draw(dl, x + railW + 6, y + 10, w - railW - 18, h - 22, 0.85)
    end

    -- блик по верхней кромке и рамка
    dl:AddRect(V(x, y), V(x + w, y + h), col(th.a1, 0.16), rr, CORNER.all, 1.2)
    dl:AddLine(V(x + rr, y + 1), V(x + w - rr, y + 1), col(C.white, 0.07), 1)

    -- ─── шапка ────────────────────────────────────────────────────────────
    -- зона перетаскивания (создаётся раньше кнопки закрытия, чтобы та была «сверху»)
    imgui.SetCursorScreenPos(V(x, y))
    imgui.InvisibleButton('##drag', V(w, 64))
    if imgui.IsItemActive() then
        local d = imgui.GetIO().MouseDelta
        Menu.x = clamp(Menu.x + d.x, -w * 0.5, SW - w * 0.5)
        Menu.y = clamp(Menu.y + d.y, -10, SH - 60)
    end

    -- логотип
    sakura(dl, x + 34, y + 36, 15, Guide.breathe * 0.18, th.a1, 1)
    text(dl, F.title, x + 56, y + 18, col(C.text, 0.97), 'SAKURA')
    text(dl, F.tiny, x + 58, y + 42, col(th.a1, 0.8), 'UI  ·  GUIDE')
    if F.jp then
        textR(dl, F.jpSmall, x + railW - 18, y + 24, col(th.a2, 0.22), '桜')
    end

    -- кнопка закрытия
    local cx, cy = x + w - 26, y + 26
    imgui.SetCursorScreenPos(V(cx - 14, cy - 14))
    local closeClick = imgui.InvisibleButton('##close', V(28, 28))
    local ch = A('close', imgui.IsItemHovered() and 1 or 0, 16, dt)
    dl:AddCircleFilled(V(cx, cy), 13, col(mixHex(C.panelHi, 0xE05B7A, ch), 0.35 + 0.55 * ch), 18)
    closeGlyph(dl, cx, cy, 4.6, col(C.text, 0.7 + 0.3 * ch), 1.8)
    if imgui.IsItemHovered() then hint('close', 'Закрыть меню. Я никуда не денусь, честно.', 'idle') end

    -- ─── вкладки ──────────────────────────────────────────────────────────
    local navY = y + 84
    local itemH = 46
    Menu.tabPos = approach(Menu.tabPos, Menu.tab, 16 * cfg.ui.speed, dt)
    -- скользящая подсветка активной вкладки
    local selY = navY + (Menu.tabPos - 1) * (itemH + 6)
    gradientRect(dl, x + 14, selY, x + railW - 14, selY + itemH,
                 mixHex(C.panelHi, th.a1, 0.28), mixHex(C.panelHi, th.a2, 0.16),
                 0.95, 0.95, rr * 0.8, CORNER.all, 10)
    dl:AddRectFilled(V(x + 14, selY + 10), V(x + 17, selY + itemH - 10), col(th.a1, 0.95), 1.6)
    glow(dl, x + 16, selY + itemH / 2, 30, th.a1, 0.4, 4)

    for i, tb in ipairs(TABS) do
        local iy = navY + (i - 1) * (itemH + 6)
        imgui.SetCursorScreenPos(V(x + 14, iy))
        local clicked = imgui.InvisibleButton('##tab' .. i, V(railW - 28, itemH))
        local hov = imgui.IsItemHovered()
        local sel = (Menu.tab == i)
        local hv = A('tab_' .. i, hov and 1 or 0, 14, dt)
        if hov and not sel then
            dl:AddRectFilled(V(x + 14, iy), V(x + railW - 14, iy + itemH),
                             col(C.panelHi, 0.35 * hv), rr * 0.8)
        end
        local tint = sel and th.a1 or mixHex(C.mute, C.text, hv * 0.7)
        icon(dl, tb.icon, x + 44, iy + itemH / 2, 10, col(tint, sel and 0.98 or 0.8))
        text(dl, F.text, x + 66, iy + itemH / 2 - 10,
             col(sel and C.text or mixHex(C.dim, C.text, hv), sel and 0.97 or 0.85), tb.name)
        if F.jp then
            -- иероглиф-подпись рисуем, только если она не столкнётся с названием
            local nameW = measure(F.text, tb.name)
            local jpW   = measure(F.jpSmall, tb.jp)
            if 66 + nameW + 12 <= railW - 24 - jpW then
                textR(dl, F.jpSmall, x + railW - 24, iy + itemH / 2 - 8,
                      col(th.a2, sel and 0.34 or 0.16), tb.jp)
            end
        end
        if clicked and Menu.tab ~= i then
            Menu.tab = i
            Hint.said = nil
            Guide:say(({
                'Обзор: тут видно, что включено и как себя чувствует скрипт.',
                'Функции — включай модули, я расскажу про каждый.',
                'Внешний вид: цвета, скругления, лепестки. Твоя песочница.',
                'Раздел про меня~ Можно даже попросить помолчать.',
                'Скучные, но полезные детали: версия и горячие клавиши.',
            })[i], i == 4 and 'shy' or 'idle', 4.5)
        end
        if hov and not sel then hint('tab' .. i, tb.sub, 'idle') end
    end

    -- ─── быстрый доступ ───────────────────────────────────────────────────
    local qy = navY + #TABS * (itemH + 6) + 18
    dl:AddLine(V(x + 20, qy), V(x + railW - 20, qy), col(C.line, 0.7), 1)
    kicker(dl, x + 20, qy + 14, 'Быстрый доступ')
    do
        local label = 'F4'
        local kw = measure(F.small, label) + 20
        text(dl, F.small, x + 20, qy + 36, col(C.dim, 0.9), 'Открыть меню')
        dl:AddRectFilled(V(x + railW - 20 - kw, qy + 32), V(x + railW - 20, qy + 54), col(0x2E2542, 0.9), 7)
        dl:AddRect(V(x + railW - 20 - kw, qy + 32), V(x + railW - 20, qy + 54), col(th.a1, 0.28), 7, CORNER.all, 1)
        textC(dl, F.small, x + railW - 20 - kw / 2, qy + 36, col(C.text, 0.9), label)
    end

    -- ─── карточка гида внизу боковой панели ───────────────────────────────
    local gy = y + h - 78
    dl:AddRectFilled(V(x + 14, gy), V(x + railW - 14, gy + 62), col(C.panelHi, 0.42), rr * 0.8)
    dl:AddRect(V(x + 14, gy), V(x + railW - 14, gy + 62), col(th.a1, 0.16), rr * 0.8, CORNER.all, 1)
    do  -- миниатюрный портрет
        local px, py = x + 46, gy + 34
        dl:AddCircleFilled(V(px, py), 22, col(mixHex(C.panel, th.a1, 0.18), 0.9), 24)
        drawGirl(dl, px, py + 4, 0.29, ALPHA * 0.98, true)
    end
    text(dl, F.text, x + 76, gy + 12, col(C.text, 0.94), Guide.name)
    local online = cfg.guide.enabled
    dl:AddCircleFilled(V(x + 78, gy + 38), 3.4, col(online and 0x7BE0A0 or C.mute, 0.95), 10)
    text(dl, F.small, x + 88, gy + 30, col(online and C.dim or C.mute, 0.9),
         online and 'на связи' or 'отдыхает')

    -- ─── контент ──────────────────────────────────────────────────────────
    local px = x + railW + 30
    local py = y + 26
    local pw = w - railW - 60
    local tb = TABS[Menu.tab]

    if F.jp then  -- крупный иероглиф-водяной знак у правого края
        textR(dl, F.jpBig, x + w - 26, y + 44, col(th.a2, 0.055), tb.jp)
    end
    text(dl, F.title, px, py, col(C.text, 0.97), tb.name)
    text(dl, F.small, px, py + 28, col(C.mute, 0.95), tb.sub)
    dl:AddLine(V(px, py + 52), V(px + pw, py + 52), col(C.line, 0.8), 1)
    -- короткая акцентная подчёркивающая черта под названием раздела
    gradientRect(dl, px, py + 51, px + 46, py + 53.5, th.a1, th.a2, 1, 1, 1.2, CORNER.all, 6)

    local cy2 = py + 68
    local ch2 = h - (cy2 - y) - 24
    if Menu.tab == 1 then tabHome(dl, px, cy2, pw, ch2)
    elseif Menu.tab == 2 then tabMods(dl, px, cy2, pw, ch2)
    elseif Menu.tab == 3 then tabLook(dl, px, cy2, pw, ch2)
    elseif Menu.tab == 4 then tabGuide(dl, px, cy2, pw, ch2)
    else tabAbout(dl, px, cy2, pw, ch2) end

    return closeClick
end

-- ============================================================================
--  ВИДЖЕТ ЧАСОВ / FPS
-- ============================================================================

local function drawHud(dl)
    if not (cfg.main.clock or cfg.main.fps) then return end
    local th = T()
    local parts = {}
    if cfg.main.clock then parts[#parts + 1] = os.date('%H:%M') end
    if cfg.main.fps then parts[#parts + 1] = string.format('%d FPS', floor(imgui.GetIO().Framerate + 0.5)) end
    local str = table.concat(parts, '   ')
    local tw = measure(F.small, str)
    local w, h = tw + 54, 34
    local x, y = SW - w - 18, 18

    for i = 4, 1, -1 do
        dl:AddRectFilled(V(x - i, y - i * 0.5), V(x + w + i, y + h + i), colRaw(C.shadow, 0.06), 11 + i, CORNER.all)
    end
    dl:AddRectFilled(V(x, y), V(x + w, y + h), colRaw(C.bgBot, 0.72), 11)
    dl:AddRect(V(x, y), V(x + w, y + h), colRaw(th.a1, 0.28), 11, CORNER.all, 1)
    sakura(dl, x + 20, y + h / 2, 9, Guide.breathe * 0.3, th.a1, 0.9, true)
    text(dl, F.small, x + 36, y + h / 2 - 9, colRaw(C.text, 0.9), str, 0.35)
end

-- ============================================================================
--  ИНИЦИАЛИЗАЦИЯ IMGUI
-- ============================================================================

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil

    local dir = getFolderPath(0x14)   -- CSIDL_FONTS
    local function pick(list)
        for _, f in ipairs(list) do
            local p = dir .. '\\' .. f
            if doesFileExist(p) then return p end
        end
    end

    local fonts   = imgui.GetIO().Fonts
    local cyr     = fonts:GetGlyphRangesCyrillic()
    local regular = pick(FONT_REGULAR)
    local bold    = pick(FONT_BOLD) or regular
    local jp      = pick(FONT_JP)

    if regular then
        F.text  = fonts:AddFontFromFileTTF(regular, 15.0, nil, cyr)
        F.small = fonts:AddFontFromFileTTF(regular, 12.5, nil, cyr)
    else
        print('[Sakura UI] Системные шрифты не найдены — кириллица может не отображаться.')
    end
    if bold then
        F.title = fonts:AddFontFromFileTTF(bold, 21.0, nil, cyr)
        F.h1    = fonts:AddFontFromFileTTF(bold, 16.0, nil, cyr)
        F.tiny  = fonts:AddFontFromFileTTF(bold, 10.5, nil, cyr)
    end
    if jp then
        -- узкий диапазон: кана + ровно те иероглифы, что встречаются в меню
        local pairsList = {
            { 0x3040, 0x30FF },                     -- хирагана + катакана
            { 0x685C, 0x685C }, { 0x6A5F, 0x6A5F },  -- 桜 機
            { 0x80FD, 0x80FD }, { 0x5916, 0x5916 },  -- 能 外
            { 0x89B3, 0x89B3 }, { 0x6848, 0x6848 },  -- 観 案
            { 0x5185, 0x5185 }, { 0x60C5, 0x60C5 },  -- 内 情
            { 0x5831, 0x5831 },                      -- 報
        }
        local arr = imgui.new.ImWchar[#pairsList * 2 + 1]()
        local k = 0
        for _, p in ipairs(pairsList) do
            arr[k] = p[1]; k = k + 1
            arr[k] = p[2]; k = k + 1
        end
        arr[k] = 0
        jpRangesRef = arr   -- диапазоны должны жить столько же, сколько шрифт
        F.jpSmall = fonts:AddFontFromFileTTF(jp, 13.0, nil, arr)
        F.jpBig   = fonts:AddFontFromFileTTF(jp, 64.0, nil, arr)
        F.jp      = true
    end

    local style = imgui.GetStyle()
    style.WindowPadding    = imgui.ImVec2(0, 0)
    style.WindowBorderSize = 0
    style.WindowRounding   = 0
    style.ItemSpacing      = imgui.ImVec2(0, 0)
    style.FramePadding     = imgui.ImVec2(0, 0)
    style.AntiAliasedLines = true

    Petals:reset(floor(cfg.ui.density))
end)

imgui.OnFrame(
    function() return Menu.anim > 0.002 or Guide.vis > 0.002 or cfg.main.clock or cfg.main.fps end,
    function(player)
        player.HideCursor = not Menu.open
        player.LockPlayer = Menu.open

        dt = clamp(imgui.GetIO().DeltaTime, 0.0005, 0.05)
        local dlBg = imgui.GetBackgroundDrawList()
        local dlFg = foregroundList(dlBg)
        if polyMode == nil then polyMode = detectPolyMode(dlBg) end

        Menu.anim = approach(Menu.anim, Menu.open and 1 or 0, 11 * cfg.ui.speed, dt)
        ALPHA = easeOutCubic(clamp(Menu.anim, 0, 1))

        if cfg.ui.petals then Petals:update(dt) end

        -- HUD живёт своей жизнью и рисуется независимо от прозрачности меню
        drawHud(dlBg)

        -- окно меню
        local closed = false
        if Menu.anim > 0.002 then
            imgui.SetNextWindowPos(V(Menu.x, Menu.y), imgui.Cond.Always)
            imgui.SetNextWindowSize(V(Menu.w, Menu.h + 40), imgui.Cond.Always)
            imgui.Begin('##sakura_root', winOpen,
                imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove +
                imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse +
                imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoBackground +
                imgui.WindowFlags.NoSavedSettings)
            -- координаты внутри окна абсолютные, поэтому рисуем в его же drawlist
            closed = drawMenu(imgui.GetWindowDrawList(), dlBg)
            imgui.End()
        end
        if closed then Menu.open = false end

        -- гид
        local io = imgui.GetIO()
        local gx = cfg.guide.side == 2 and (SW - 165 * cfg.guide.scale) or (165 * cfg.guide.scale)
        local gy = SH + 44 * cfg.guide.scale - 250 * cfg.guide.scale
        Guide:update(dt, Menu.open, io.MousePos.x, io.MousePos.y, gx, gy)
        Guide:draw(dlFg, SW, SH)

        hintUpdate(dt)
    end
)

-- ============================================================================
--  ЛОГИКА СКРИПТА
-- ============================================================================

local function toggleMenu(state)
    if state == nil then state = not Menu.open end
    Menu.open = state
    if state then
        Hint.said, Hint.key = nil, nil
        Guide:say('С возвращением! Что настраиваем на этот раз?', 'happy', 4)
    else
        inicfg.save(cfg, INI)
    end
end

function main()
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('sakura', function(arg)
        if arg == 'say' then
            Guide:say(PHRASES[math.random(#PHRASES)], 'wink', 4.5)
        else
            toggleMenu()
        end
    end)

    addEventHandler('onWindowMessage', function(msg, wparam, lparam)
        if msg == wm.WM_KEYDOWN or msg == wm.WM_SYSKEYDOWN then
            if wparam == cfg.main.hotkey and not sampIsChatInputActive()
               and not sampIsDialogActive() and not isPauseMenuActive() then
                consumeWindowMessage(true, false)
                toggleMenu()
            elseif wparam == vkeys.VK_ESCAPE and Menu.open then
                consumeWindowMessage(true, false)
                toggleMenu(false)
            end
        end
    end)

    sampAddChatMessage(u8:decode('{FF87B5}[Sakura UI]{FFFFFF} загружено. Открыть: {FF87B5}/sakura{FFFFFF} или {FF87B5}F4'), -1)

    if cfg.main.greeting and cfg.guide.enabled then
        wait(2500)
        Guide:say('Привет! Я Сакура, твой гид по этому меню.', 'happy', 4)
        Guide:queueSay('Нажми F4 — покажу, что тут к чему.', 'wink', 4)
    end

    wait(-1)
end

function onScriptTerminate(scr, quit)
    if scr == thisScript() then
        inicfg.save(cfg, INI)
    end
end
