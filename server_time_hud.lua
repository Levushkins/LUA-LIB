--[[---------------------------------------------------------------------------
    SERVER TIME HUD — редизайн под игровой интерфейс Arizona RP
--------------------------------------------------------------------------------
    Что изменилось по сравнению с исходной версией:
      * стандартные текстдравы (sampTextdraw*) заменены на отрисовку через
        mimgui — только так можно получить скруглённую тёмную панель, круглые
        плашки-«бейджи» и зелёный блок статуса, как в HUD на скриншоте;
      * разбор диалога со временем переписан: цветовые теги вырезаются заранее,
        шаблоны не привязаны к конкретным кодам цвета и разделителям даты;
      * время больше не пересобирается через os.time() каждую секунду —
        хранится смещение относительно момента синхронизации, поэтому
        перевод часов/DST на локальной машине не сдвигает показания;
      * добавлены конфиг (позиция, масштаб, блок даты) и команда /timehud.

    Стиль взят с игрового HUD Arizona RP:
      тёмная скруглённая панель ~90% непрозрачности, круглые плашки #2C3138
      с цветной иконкой, подпись мелким серым шрифтом + жирное значение,
      справа — цветной блок-«пилюля» в две строки (аналог «Зеленая зона»).

    Зависимости: MoonLoader 0.26+, SAMPFUNCS, mimgui, SAMP.Lua (samp.events).
    Команды:
      /timehud            — включить/выключить панель
      /timehud move       — режим перетаскивания панели мышью
      /timehud date       — показать/скрыть блок с датой
      /timehud scale 1.2  — масштаб панели (0.7 – 2.0), скрипт перезагрузится

    ВАЖНО: файл сохранён в UTF-8. Строки в коде уже в UTF-8 (их ждёт mimgui),
    текст из игры приходит в CP1251 и переводится функцией fromGame().
    Не пересохраняйте файл в ANSI/CP1251 — сломается вывод панели.
-------------------------------------------------------------------------------]]

script_name('server_time_hud')
script_author('LUA-LIB')
script_version('2.0.0')
script_description('Серверное время в стиле HUD Arizona RP (mimgui)')

require 'lib.moonloader'

local encoding = require 'encoding'
local inicfg   = require 'inicfg'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local function fromGame(str) return u8(str) end        -- CP1251 (игра) -> UTF-8
local function toGame(str)   return u8:decode(str) end -- UTF-8 (код)   -> CP1251

local function chat(text)
    sampAddChatMessage(toGame('{FFA62B}[Time HUD]{FFFFFF} ' .. text), -1)
end

---------------------------------- ЗАВИСИМОСТИ ---------------------------------

local function tryRequire(name)
    local ok, lib = pcall(require, name)
    if ok then return lib end
end

local imgui  = tryRequire('mimgui')
local sampev = tryRequire('samp.events')

if not imgui or not sampev then
    local missing = {}
    if not imgui  then missing[#missing + 1] = 'mimgui' end
    if not sampev then missing[#missing + 1] = 'SAMP.Lua (samp.events)' end

    function main()
        while not isSampAvailable() do wait(100) end
        chat('Не найдены библиотеки: {FF5C5C}' .. table.concat(missing, ', '))
        chat('Положите их в moonloader/lib и перезапустите скрипт.')
        thisScript():unload()
    end

    do return end
end

------------------------------------ КОНФИГ -----------------------------------

local INI_FILE = 'server_time_hud.ini'

local cfg = inicfg.load({
    hud = {
        enabled  = true,
        posX     = -1,   -- -1 = позиция подбирается автоматически при первом запуске
        posY     = -1,
        scale    = 1.0,
        showDate = true,
    }
}, INI_FILE)

local function toBool(value, default)
    if type(value) == 'boolean' then return value end
    if value == 'true'  or value == 1 or value == '1' then return true  end
    if value == 'false' or value == 0 or value == '0' then return false end
    return default
end

cfg.hud          = cfg.hud or {}
cfg.hud.enabled  = toBool(cfg.hud.enabled, true)
cfg.hud.showDate = toBool(cfg.hud.showDate, true)
cfg.hud.posX     = tonumber(cfg.hud.posX) or -1
cfg.hud.posY     = tonumber(cfg.hud.posY) or -1
cfg.hud.scale    = math.max(0.7, math.min(2.0, tonumber(cfg.hud.scale) or 1.0))

local function saveConfig() inicfg.save(cfg, INI_FILE) end

------------------------------- ПАЛИТРА И РАЗМЕТКА -----------------------------

-- Цвета сняты с HUD на скриншоте: нейтральный тёмный корпус, серые плашки,
-- оранжевый/синий акценты иконок и «зелёная зона» для блока статуса.
local COLOR = {
    panel      = 0x171A1F,
    border     = 0xFFFFFF,
    shadow     = 0x000000,
    highlight  = 0xFFFFFF,
    badge      = 0x2C3138,
    divider    = 0xFFFFFF,
    label      = 0x8A929E,
    value      = 0xFFFFFF,
    accentTime = 0xFFA62B,  -- как оранжевая иконка сытости в оригинальном HUD
    accentIdle = 0x8A929E,  -- время не синхронизировано — акцент гасим
    accentDate = 0x5AA9FF,
    green      = 0x2FA84F,  -- блок «Зеленая зона»
    amber      = 0xD8912B,
    white      = 0xFFFFFF,
}

local LAYOUT = {
    margin   = 16,  -- запас внутри окна, чтобы тень не обрезалась клипректом ImGui
    radius   = 20,
    padX     = 15,
    padY     = 14,
    contentH = 44,
    badgeR   = 21,
    iconGap  = 11,
    blockGap = 15,
    lineGap  = 3,
    dividerH = 34,
    pillR    = 14,
    pillPadX = 12,
    pillGap  = 9,
    shieldW  = 20,
    hintH    = 26,
}

local SCALE = cfg.hud.scale
local function S(value) return value * SCALE end

local gAlpha = 1.0 -- общая прозрачность (плавное появление панели)

local function rgba(hex, alpha)
    alpha = math.floor((alpha or 255) * gAlpha)
    if alpha < 0 then alpha = 0 elseif alpha > 255 then alpha = 255 end
    local r = math.floor(hex / 0x10000) % 0x100
    local g = math.floor(hex / 0x100) % 0x100
    local b = hex % 0x100
    return alpha * 0x1000000 + b * 0x10000 + g * 0x100 + r
end

------------------------------------ ШРИФТЫ ------------------------------------

local FONT_FILES = { 'segoeuib.ttf', 'trebucbd.ttf', 'tahomabd.ttf', 'arialbd.ttf' }
local FONT_SIZES = { label = 11, value = 20, pill = 12 }
local fonts = {}

local function findFontFile()
    local dir = getFolderPath(0x14) -- CSIDL_FONTS
    for _, name in ipairs(FONT_FILES) do
        local path = dir .. '\\' .. name
        if doesFileExist(path) then return path end
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local path = findFontFile()
    if not path then return end -- останемся на встроенном шрифте ImGui
    local ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    for key, size in pairs(FONT_SIZES) do
        fonts[key] = imgui.GetIO().Fonts:AddFontFromFileTTF(path, math.floor(S(size) + 0.5), nil, ranges)
    end
end)

local function pushFont(key)
    local font = fonts[key]
    if font then
        imgui.PushFont(font)
        return true
    end
    return false
end

local function textSize(key, str)
    local pushed = pushFont(key)
    local size = imgui.CalcTextSize(str)
    if pushed then imgui.PopFont() end
    return size.x, size.y
end

local function textWidth(key, str)
    local width = textSize(key, str)
    return width
end

local function drawText(dl, key, x, y, color, str)
    local pushed = pushFont(key)
    dl:AddText(imgui.ImVec2(x, y), color, str)
    if pushed then imgui.PopFont() end
end

------------------------------- ВРЕМЯ И СИНХРОНИЗАЦИЯ --------------------------

-- Храним не «поправку к os.time()», а срез серверного времени и момент,
-- когда он был получен. Разница двух os.time() не зависит от часового пояса,
-- поэтому показания не съезжают на час при переводе часов на компьютере.
local sync = { active = false, at = 0, secOfDay = 0, noon = 0 }

local function applyServerTime(hour, min, sec, day, month, year)
    local now = os.date('*t')
    sync.active   = true
    sync.at       = os.time()
    sync.secOfDay = hour * 3600 + min * 60 + sec
    sync.noon     = os.time({
        year  = year  or now.year,
        month = month or now.month,
        day   = day   or now.day,
        hour  = 12, min = 0, sec = 0, -- полдень: сутки прибавляются без сюрпризов DST
    })
end

local function getDisplayTime()
    if sync.active then
        local total = sync.secOfDay + (os.time() - sync.at)
        local days  = math.floor(total / 86400)
        local secs  = total % 86400
        return math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60,
               os.date('*t', sync.noon + days * 86400), true
    end
    local now = os.date('*t')
    return now.hour, now.min, now.sec, now, false
end

local function parseTimeDialog(raw)
    local converted, text = pcall(fromGame, raw)
    if not converted then return false end
    text = text:gsub('{%x%x%x%x%x%x}', '')

    local hour, min, sec = text:match('Текущее время[^%d]*(%d+):(%d+):(%d+)')
    if not hour then
        hour, min = text:match('Текущее время[^%d]*(%d+):(%d+)')
        sec = 0
    end
    if not hour then return false end

    hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)
    if hour > 23 or min > 59 or sec > 59 then return false end

    -- дата на разных серверах пишется как 26.07.2026, 26:07:2026 или 26/07/2026
    local day, month, year = text:match('дата[^%d]*(%d+)%D+(%d+)%D+(%d+)')
    day, month, year = tonumber(day), tonumber(month), tonumber(year)
    if day and (day < 1 or day > 31 or month < 1 or month > 12) then
        day, month, year = nil, nil, nil
    end
    if year and year < 100 then year = year + 2000 end

    applyServerTime(hour, min, sec, day, month, year)
    return true
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if parseTimeDialog(text) then
        local hour, min, sec = getDisplayTime()
        chat(('Время синхронизировано с сервером: {2FA84F}%02d:%02d:%02d'):format(hour, min, sec))
    end
end

---------------------------------- ИКОНКИ (векторные) --------------------------

-- Иконки рисуются примитивами дравлиста: не нужен FontAwesome в moonloader/lib,
-- и они остаются чёткими на любом масштабе.

local function drawClockGlyph(dl, cx, cy, size, color, hour, min)
    local r = size / 2
    local center = imgui.ImVec2(cx, cy)
    dl:AddCircle(center, r, color, 32, S(1.7))
    local function hand(angle, length, thickness)
        dl:AddLine(center, imgui.ImVec2(cx + math.sin(angle) * length, cy - math.cos(angle) * length), color, thickness)
    end
    hand((min / 60) * math.pi * 2, r * 0.72, S(1.6))                      -- минутная
    hand(((hour % 12) / 12 + min / 720) * math.pi * 2, r * 0.48, S(2.0))  -- часовая
    dl:AddCircleFilled(center, S(1.4), color, 8)
end

local function drawCalendarGlyph(dl, cx, cy, size, color)
    local hw, hh = size * 0.5, size * 0.46
    local x1, y1 = cx - hw, cy - hh + S(2)
    local x2, y2 = cx + hw, cy + hh
    dl:AddRect(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), color, S(3), 0xF, S(1.7))
    dl:AddRectFilled(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y1 + S(4.5)), color, S(3), 0x3) -- «шапка», скругление сверху
    dl:AddLine(imgui.ImVec2(cx - hw * 0.45, y1 - S(3)), imgui.ImVec2(cx - hw * 0.45, y1 + S(1)), color, S(1.7))
    dl:AddLine(imgui.ImVec2(cx + hw * 0.45, y1 - S(3)), imgui.ImVec2(cx + hw * 0.45, y1 + S(1)), color, S(1.7))
    dl:AddRectFilled(imgui.ImVec2(cx - S(3), cy + S(1)), imgui.ImVec2(cx + S(3), cy + S(4)), color, S(1))
end

local function drawShieldGlyph(dl, cx, cy, size, color, innerColor, ok)
    local w, h = size * 0.42, size * 0.5
    dl:PathClear()
    dl:PathLineTo(imgui.ImVec2(cx - w, cy - h))
    dl:PathLineTo(imgui.ImVec2(cx + w, cy - h))
    dl:PathLineTo(imgui.ImVec2(cx + w, cy + h * 0.1))
    dl:PathLineTo(imgui.ImVec2(cx, cy + h))
    dl:PathLineTo(imgui.ImVec2(cx - w, cy + h * 0.1))
    dl:PathFillConvex(color)
    if ok then -- галочка: время получено с сервера
        dl:AddLine(imgui.ImVec2(cx - w * 0.45, cy - h * 0.05), imgui.ImVec2(cx - w * 0.08, cy + h * 0.33), innerColor, S(2.1))
        dl:AddLine(imgui.ImVec2(cx - w * 0.08, cy + h * 0.33), imgui.ImVec2(cx + w * 0.52, cy - h * 0.42), innerColor, S(2.1))
    else       -- восклицательный знак: показываем локальное время
        dl:AddLine(imgui.ImVec2(cx, cy - h * 0.42), imgui.ImVec2(cx, cy + h * 0.10), innerColor, S(2.1))
        dl:AddCircleFilled(imgui.ImVec2(cx, cy + h * 0.40), S(1.5), innerColor, 8)
    end
end

------------------------------- ЭЛЕМЕНТЫ ПАНЕЛИ --------------------------------

local function drawBadge(dl, cx, cy, radius, progress, accent)
    local center = imgui.ImVec2(cx, cy)
    dl:AddCircleFilled(center, radius, rgba(COLOR.badge, 255), 48)
    dl:AddCircle(center, radius - S(0.5), rgba(COLOR.highlight, 16), 48, 1.0)
    if progress and progress > 0 then -- тонкое кольцо секунд по краю плашки
        dl:PathArcTo(center, radius - S(1.5), -math.pi / 2, -math.pi / 2 + math.pi * 2 * progress, 48)
        dl:PathStroke(rgba(accent, 210), false, S(2.0))
    end
end

local function drawInfoBlock(dl, x, cy, label, value)
    local _, labelH = textSize('label', label)
    local _, valueH = textSize('value', value)
    local total = labelH + S(LAYOUT.lineGap) + valueH
    local top = cy - total / 2
    drawText(dl, 'label', x, top, rgba(COLOR.label, 255), label)
    drawText(dl, 'value', x, top + labelH + S(LAYOUT.lineGap), rgba(COLOR.value, 255), value)
end

local function drawStatusPill(dl, x, y, w, h, ok, lineTop, lineBottom)
    local base = ok and COLOR.green or COLOR.amber
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), rgba(base, 255), S(LAYOUT.pillR))
    dl:AddLine(imgui.ImVec2(x + S(8), y + 1), imgui.ImVec2(x + w - S(8), y + 1), rgba(COLOR.highlight, 40), 1.0)

    local cy = y + h / 2
    drawShieldGlyph(dl, x + S(LAYOUT.pillPadX) + S(LAYOUT.shieldW) / 2, cy, S(LAYOUT.shieldW),
                    rgba(COLOR.white, 250), rgba(base, 255), ok)

    local textX = x + S(LAYOUT.pillPadX) + S(LAYOUT.shieldW) + S(LAYOUT.pillGap)
    local _, lineH = textSize('pill', lineTop)
    local top = cy - (lineH * 2 + S(2)) / 2
    drawText(dl, 'pill', textX, top, rgba(COLOR.white, 255), lineTop)
    drawText(dl, 'pill', textX, top + lineH + S(2), rgba(COLOR.white, 225), lineBottom)
end

--------------------------------- СБОРКА ПАНЕЛИ --------------------------------

local function buildState()
    local hour, min, sec, date, synced = getDisplayTime()
    return {
        hour = hour, min = min, sec = sec, synced = synced,
        timeLabel  = 'ВРЕМЯ СЕРВЕРА',
        timeValue  = ('%02d:%02d:%02d'):format(hour, min, sec),
        dateLabel  = 'ДАТА',
        dateValue  = ('%02d.%02d.%04d'):format(date.day, date.month, date.year),
        accent     = synced and COLOR.accentTime or COLOR.accentIdle,
        pillTop    = synced and 'Точное' or 'Локальное',
        pillBottom = 'время',
    }
end

local function layoutState(state)
    local badgeD = S(LAYOUT.badgeR) * 2

    -- ширину значения считаем по эталону «00:00:00», иначе панель дёргалась бы
    -- каждую секунду из-за разной ширины цифр
    state.timeBlockW = math.max(textWidth('label', state.timeLabel), textWidth('value', '00:00:00'))
    local width = S(LAYOUT.padX) + badgeD + S(LAYOUT.iconGap) + state.timeBlockW

    if cfg.hud.showDate then
        state.dateBlockW = math.max(textWidth('label', state.dateLabel), textWidth('value', '00.00.0000'))
        width = width + S(LAYOUT.blockGap) + 1 + S(LAYOUT.blockGap) + badgeD + S(LAYOUT.iconGap) + state.dateBlockW
    end

    local pillTextW = math.max(textWidth('pill', state.pillTop), textWidth('pill', state.pillBottom))
    state.pillW = S(LAYOUT.pillPadX) * 2 + S(LAYOUT.shieldW) + S(LAYOUT.pillGap) + pillTextW
    width = width + S(LAYOUT.blockGap) + state.pillW + S(LAYOUT.padX)

    return width, S(LAYOUT.padY) * 2 + S(LAYOUT.contentH)
end

local function drawHud(dl, x, y, w, h, state)
    local radius = S(LAYOUT.radius)

    -- мягкая тень под панелью
    for i = 5, 1, -1 do
        dl:AddRectFilled(imgui.ImVec2(x - i, y - i + 2), imgui.ImVec2(x + w + i, y + h + i + 2),
                         rgba(COLOR.shadow, 9), radius + i)
    end

    -- корпус панели
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), rgba(COLOR.panel, 235), radius)
    dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), rgba(COLOR.border, 20), radius, 0xF, 1.0)
    dl:AddLine(imgui.ImVec2(x + radius * 0.6, y + 1), imgui.ImVec2(x + w - radius * 0.6, y + 1),
               rgba(COLOR.highlight, 18), 1.0)

    local cy     = y + h / 2
    local badgeR = S(LAYOUT.badgeR)
    local cursor = x + S(LAYOUT.padX)

    -- блок времени: круглая плашка с часами + кольцо секунд
    drawBadge(dl, cursor + badgeR, cy, badgeR, state.sec / 60, state.accent)
    drawClockGlyph(dl, cursor + badgeR, cy, badgeR * 1.2, rgba(state.accent, 255), state.hour, state.min)
    cursor = cursor + badgeR * 2 + S(LAYOUT.iconGap)
    drawInfoBlock(dl, cursor, cy, state.timeLabel, state.timeValue)
    cursor = cursor + state.timeBlockW

    -- блок даты
    if cfg.hud.showDate then
        cursor = cursor + S(LAYOUT.blockGap)
        dl:AddLine(imgui.ImVec2(cursor, cy - S(LAYOUT.dividerH) / 2),
                   imgui.ImVec2(cursor, cy + S(LAYOUT.dividerH) / 2), rgba(COLOR.divider, 22), 1.0)
        cursor = cursor + 1 + S(LAYOUT.blockGap)

        drawBadge(dl, cursor + badgeR, cy, badgeR)
        drawCalendarGlyph(dl, cursor + badgeR, cy, badgeR * 0.9, rgba(COLOR.accentDate, 255))
        cursor = cursor + badgeR * 2 + S(LAYOUT.iconGap)
        drawInfoBlock(dl, cursor, cy, state.dateLabel, state.dateValue)
        cursor = cursor + state.dateBlockW
    end

    -- статус справа — тот самый блок «Зеленая зона» из оригинального HUD
    local pillH = S(LAYOUT.contentH)
    drawStatusPill(dl, x + w - S(LAYOUT.padX) - state.pillW, cy - pillH / 2, state.pillW, pillH,
                   state.synced, state.pillTop, state.pillBottom)
end

local MOVE_HINT = 'Перетащите панель мышью, затем /timehud move'

local function drawMoveHint(dl, x, y, w)
    local hint = MOVE_HINT
    local textW, textH = textSize('label', hint)
    local h = S(LAYOUT.hintH)
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), rgba(COLOR.panel, 225), S(8))
    dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), rgba(COLOR.accentTime, 90), S(8), 0xF, 1.0)
    drawText(dl, 'label', x + (w - textW) / 2, y + (h - textH) / 2, rgba(COLOR.value, 235), hint)
end

----------------------------------- ОТРИСОВКА ----------------------------------

local WINDOW_FLAGS = imgui.WindowFlags.NoDecoration
                   + imgui.WindowFlags.NoSavedSettings
                   + imgui.WindowFlags.NoBackground
                   + imgui.WindowFlags.NoFocusOnAppearing
                   + imgui.WindowFlags.NoBringToFrontOnFocus
                   + imgui.WindowFlags.NoScrollWithMouse

local moveMode, movePlaced, fade = false, false, 0.0

imgui.OnFrame(
    function()
        return cfg.hud.enabled and isSampAvailable() and not isPauseMenuActive()
    end,
    function(player)
        player.HideCursor = not moveMode -- курсор нужен только для перетаскивания
        player.LockPlayer = false

        fade = fade + (1.0 - fade) * math.min(1.0, imgui.GetIO().DeltaTime * 8)
        gAlpha = fade

        local state = buildState()
        local w, h  = layoutState(state)
        local m     = S(LAYOUT.margin)
        local hintH = moveMode and (S(LAYOUT.hintH) + S(6)) or 0
        -- подсказка переноса может быть шире панели — окно расширяем под неё,
        -- иначе текст обрежется клипректом окна
        local blockW = moveMode and math.max(w, textWidth('label', MOVE_HINT) + S(24)) or w

        if cfg.hud.posX < 0 or cfg.hud.posY < 0 then -- первый запуск: по центру снизу
            local screenW, screenH = getScreenResolution()
            cfg.hud.posX = math.floor((screenW - (blockW + m * 2)) / 2)
            cfg.hud.posY = math.floor(screenH * 0.86 - (h + m * 2))
            saveConfig()
        end

        local flags = WINDOW_FLAGS
        if not moveMode then
            flags = flags + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs
        end

        -- позицию навязываем каждый кадр, кроме режима переноса: там окно
        -- ставится один раз, дальше им управляет мышь
        if not moveMode or not movePlaced then
            imgui.SetNextWindowPos(imgui.ImVec2(cfg.hud.posX, cfg.hud.posY), imgui.Cond.Always)
            movePlaced = moveMode
        end
        imgui.SetNextWindowSize(imgui.ImVec2(blockW + m * 2, h + m * 2 + hintH), imgui.Cond.Always)

        imgui.Begin('##server_time_hud', nil, flags)
            local pos = imgui.GetWindowPos()
            if moveMode then
                cfg.hud.posX = math.floor(pos.x + 0.5)
                cfg.hud.posY = math.floor(pos.y + 0.5)
            end

            local dl = imgui.GetWindowDrawList()
            drawHud(dl, pos.x + m, pos.y + m, w, h, state)
            if moveMode then
                drawMoveHint(dl, pos.x + m, pos.y + m + h + S(6), blockW)
            end
        imgui.End()
    end
).HideCursor = true

------------------------------------ КОМАНДЫ -----------------------------------

local function printHelp()
    chat('{FFA62B}/timehud{FFFFFF} — вкл/выкл панель')
    chat('{FFA62B}/timehud move{FFFFFF} — перенести панель мышью')
    chat('{FFA62B}/timehud date{FFFFFF} — показать/скрыть блок с датой')
    chat('{FFA62B}/timehud scale 1.2{FFFFFF} — масштаб панели (0.7 – 2.0)')
end

local function cmdTimeHud(param)
    local action, value = tostring(param or ''):match('^%s*(%S*)%s*(.-)%s*$')
    action = action:lower()

    if action == '' then
        cfg.hud.enabled = not cfg.hud.enabled
        if cfg.hud.enabled then fade = 0.0 end
        if not cfg.hud.enabled then moveMode, movePlaced = false, false end
        saveConfig()
        chat(cfg.hud.enabled and 'Панель включена.' or 'Панель выключена.')

    elseif action == 'move' or action == 'pos' then
        moveMode, movePlaced = not moveMode, false
        if moveMode then
            cfg.hud.enabled = true
            chat('Режим переноса: тащите панель мышью, для сохранения введите {FFA62B}/timehud move')
        else
            saveConfig()
            chat(('Позиция сохранена: {FFA62B}%d, %d'):format(cfg.hud.posX, cfg.hud.posY))
        end

    elseif action == 'date' then
        cfg.hud.showDate = not cfg.hud.showDate
        saveConfig()
        chat(cfg.hud.showDate and 'Блок с датой показан.' or 'Блок с датой скрыт.')

    elseif action == 'scale' then
        local scale = tonumber((value:gsub(',', '.')))
        if not scale or scale < 0.7 or scale > 2.0 then
            chat('Укажите масштаб от {FFA62B}0.7{FFFFFF} до {FFA62B}2.0{FFFFFF}, например: {FFA62B}/timehud scale 1.2')
            return
        end
        cfg.hud.scale = scale
        saveConfig()
        chat(('Масштаб {FFA62B}%.2f{FFFFFF} — перезагружаю скрипт для пересборки шрифтов...'):format(scale))
        thisScript():reload()

    else
        printHelp()
    end
end

------------------------------------- MAIN -------------------------------------

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('timehud', cmdTimeHud)

    if not findFontFile() then
        chat('{FF5C5C}Системный шрифт не найден{FFFFFF} — панель отрисуется встроенным шрифтом ImGui (без кириллицы).')
    end

    chat('Загружен. Панель синхронизируется, когда сервер покажет диалог со временем.')
    printHelp()

    wait(-1)
end

function onScriptTerminate(script, quitGame)
    if script == thisScript() then saveConfig() end
end
