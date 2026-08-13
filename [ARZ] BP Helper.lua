-- =====================================================================
--  BP Helper - вывод заданий Battle Pass (Arizona RP, CEF)
--  Версия 2.0
--
--  !!! ВАЖНО !!!
--  Файл сохранён в кодировке UTF-8.
--  НЕ пересохраняйте его в ANSI/CP1251 - весь русский текст сломается.
--  Строки для ImGui пишутся как есть (UTF-8), для чата используется cp().
--
--  Команды:
--    /bph      - показать/скрыть окно
--    /bphset   - настройки
--    /bpdebug  - диагностика сопоставления заданий (если тексты не те)
-- =====================================================================

script_name('BP Helper')
script_version('2.0')

local effil    = require 'effil'
local imgui    = require 'mimgui'
local ffi      = require 'ffi'
local sampev   = require 'samp.events'
local encoding = require 'encoding'
local inicfg   = require 'inicfg'
local vkeys    = require 'vkeys'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local fa_status, faicons = pcall(require, 'fAwesome6')

local new = imgui.new

-- iconRanges ОБЯЗАН быть глобальным (требование ImGui: диапазон
-- должен жить всё время работы атласа шрифтов, иначе GC его соберёт)
iconRanges = nil

-- ---------------------------------------------------------------------
--  Утилиты
-- ---------------------------------------------------------------------

-- UTF-8 -> CP1251, для sampAddChatMessage
local function cp(s) return u8:decode(s) end

local function chat(msg)
    sampAddChatMessage('{32CD32}[BP Helper] {FFFFFF}' .. cp(msg), -1)
end

local function getIcon(name)
    if not fa_status then return '' end
    -- fAwesome6 может отдавать иконки как faicons('car') либо как
    -- faicons.ICON_FA_CAR - поддерживаем оба варианта и никогда не падаем
    local ok, res = pcall(faicons, name)
    if ok and type(res) == 'string' then return res end
    local const = 'ICON_FA_' .. name:upper():gsub('%-', '_')
    if type(faicons[const]) == 'string' then return faicons[const] end
    return ''
end

-- Отложенные действия. Сетевые запросы нельзя запускать прямо из
-- обработчика пакетов или из колбэка отрисовки imgui - складываем их
-- сюда, а выполняет главный цикл.
local pendingActions = {}
local function defer(fn) pendingActions[#pendingActions + 1] = fn end

local function runPendingActions()
    if #pendingActions == 0 then return end
    local queue = pendingActions
    pendingActions = {}
    for _, fn in ipairs(queue) do pcall(fn) end
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ---------------------------------------------------------------------
--  Конфиг
-- ---------------------------------------------------------------------

local configPath = 'BP Helper.ini'

local config = inicfg.load({
    settings = {
        cursor_key           = 18,   -- Alt: удержание = временно показать курсор
        transparent_mode_key = 116,  -- F5: переключение оверлей/активный режим
        group_quests         = true,
        show_instructions    = true,
        hide_completed       = false,
        show_bp_level        = true,
        -- Схема сопоставления id -> миссия. 'auto' = подобрать по покрытию.
        -- Если тексты заданий смещены на одну позицию - переключите вручную
        -- в настройках (раздел "Данные").
        strategy_daily       = 'auto',
        strategy_premium     = 'auto',
        -- Номер сервера Arizona. Таблицы миссий у разных серверов могут
        -- различаться, поэтому неверный номер = чужие тексты заданий.
        server               = 1,
    },
    hidden = {},
    pinned = {},
}, configPath)

config.hidden = config.hidden or {}
config.pinned = config.pinned or {}

local settings = {
    cursor_key           = new.int(config.settings.cursor_key),
    transparent_mode_key = new.int(config.settings.transparent_mode_key),
    group_quests         = new.bool(config.settings.group_quests),
    show_instructions    = new.bool(config.settings.show_instructions),
    hide_completed       = new.bool(config.settings.hide_completed),
    show_bp_level        = new.bool(config.settings.show_bp_level),
    server               = new.int(tonumber(config.settings.server) or 1),
    waiting_for_key      = new.bool(false),
    key_mode             = new.int(0),
}

local function saveConfig()
    config.settings.cursor_key           = settings.cursor_key[0]
    config.settings.transparent_mode_key = settings.transparent_mode_key[0]
    config.settings.group_quests         = settings.group_quests[0]
    config.settings.show_instructions    = settings.show_instructions[0]
    config.settings.hide_completed       = settings.hide_completed[0]
    config.settings.show_bp_level        = settings.show_bp_level[0]
    config.settings.server               = settings.server[0]
    -- ВАЖНО: hidden/pinned НЕ пересобираются из списка заданий.
    -- В старой версии они перезаписывались из quests, и если сохранение
    -- происходило до открытия БП (список пуст) - все настройки стирались.
    inicfg.save(config, configPath)
end

-- ---------------------------------------------------------------------
--  Состояние
-- ---------------------------------------------------------------------

local win_state         = new.bool(false)
local settings_window   = new.bool(false)
local hidden_window     = new.bool(false)
-- true = активный режим (курсор, кнопки, полная непрозрачность),
-- false = оверлей поверх игры. Стартуем в активном, иначе при первом
-- /bph окно нельзя было бы ни подвинуть, ни настроить.
local overlay_mode      = new.bool(true)
local search_buf        = new.char[64]()

local saved_size = imgui.ImVec2(430, 560)

local quests   = {}          -- активный список заданий
local bpInfo   = nil         -- {level, exp, maxExp, premium}
local premiumBP = false

local filter_category = 'all'   -- all | daily | premium
local filter_state    = 'all'   -- all | active | done

local category_states = {}      -- имя категории -> открыта ли

-- Таблицы миссий с сервера
local missions = {
    daily   = { key = 'battlepass_mission_default', store = nil, lookup = nil, strategy = nil, loaded = false },
    premium = { key = 'battlepass_mission_premium', store = nil, lookup = nil, strategy = nil, loaded = false },
}

-- ---------------------------------------------------------------------
--  Асинхронные HTTP-запросы
-- ---------------------------------------------------------------------

local function requestRunner()
    return effil.thread(function(u)
        local https = require 'ssl.https'
        local ok, result = pcall(https.request, u)
        if ok then return { true, result } else return { false, result } end
    end)
end

local function async_http_request(url, resolve, reject)
    reject = reject or function() end
    local runner = requestRunner()
    lua_thread.create(function()
        local t = runner(url)
        local r = t:get(0)
        while not r do
            r = t:get(0)
            wait(0)
        end
        local status = t:status()
        if status == 'completed' then
            local ok, result = r[1], r[2]
            if ok then resolve(result) else reject(tostring(result)) end
        else
            -- В старой версии здесь была ветка `elseif err then` с
            -- несуществующей переменной err - она никогда не срабатывала
            reject(tostring(status))
        end
        t:cancel(0)
    end)
end

-- ---------------------------------------------------------------------
--  Разбор таблицы миссий + резолвер id -> миссия
--
--  CEF присылает только {id, categoryId, progress, visible} - без текста.
--  Текст берётся из таблицы API. Проблема в том, что неизвестно, чем
--  является id из CEF: полем "id" внутри записи или порядковым номером
--  строки. Если угадать неверно - показываются ЧУЖИЕ задания.
--
--  Поэтому пробуем все схемы и выбираем ту, которая разрешает максимум
--  пришедших id. Выбранная схема видна в /bpdebug.
-- ---------------------------------------------------------------------

local F_TEXT  = { 'description', 'desc', 'text', 'task', 'mission' }
local F_TITLE = { 'title', 'name', 'header' }
local F_MAX   = { 'totalProgress', 'needProgress', 'maxProgress', 'total', 'need', 'count' }

local function field(entry, names)
    for _, n in ipairs(names) do
        local v = entry[n]
        if v ~= nil and v ~= '' then return v end
    end
    return nil
end

local function asArray(t)
    if type(t) == 'table' and #t > 0 then return t end
    return nil
end

-- Приводит любой разумный вид ответа к {list=..., byId=..., byKey=...}
local function normalizeTable(decoded)
    if type(decoded) ~= 'table' then return nil end
    local store = {}

    local list = asArray(decoded)

    -- Arizona часто заворачивает массив ещё раз: [[{...},{...}]]
    if list and #list == 1 and asArray(list[1]) then
        list = asArray(list[1])
    end

    -- Либо это объект вида {"data": [...]}
    if not list then
        for _, k in ipairs({ 'data', 'items', 'result', 'rows', 'table', 'missions', 'list' }) do
            local inner = type(decoded[k]) == 'table' and asArray(decoded[k]) or nil
            if inner then list = inner break end
        end
    end

    store.list = list

    if list then
        local byId, n = {}, 0
        for _, e in ipairs(list) do
            local id = type(e) == 'table' and tonumber(e.id) or nil
            if id then byId[id] = e; n = n + 1 end
        end
        if n > 0 then store.byId = byId end
    else
        -- Возможно, это словарь {"14": {...}, "117": {...}}
        store.byKey = decoded
    end

    return store
end

local function lookupsFor(store)
    local out = {}
    if store.byId then
        out[#out + 1] = { 'поле id', function(id) return store.byId[id] end }
    end
    if store.list then
        out[#out + 1] = { 'индекс с 1', function(id) return store.list[id] end }
        out[#out + 1] = { 'индекс с 0', function(id) return store.list[id + 1] end }
    end
    if store.byKey then
        out[#out + 1] = { 'строковый ключ', function(id) return store.byKey[tostring(id)] end }
    end
    return out
end

-- Выбирает схему сопоставления по покрытию пришедших id.
--
-- Оговорка: покрытие НЕ различает "индекс с 0" и "индекс с 1", если таблица
-- плотная - обе схемы дают 100%. Если тексты заданий смещены ровно на одну
-- позицию, переключите схему вручную в настройках -> Данные.
local function chooseStrategy(cat, ids)
    local m = missions[cat]
    if not m or not m.store or #ids == 0 then return end

    m.lastIds = ids

    local forced = config.settings['strategy_' .. cat]
    local bestFn, bestName, bestScore = nil, nil, -1

    for _, s in ipairs(lookupsFor(m.store)) do
        local score = 0
        for _, id in ipairs(ids) do
            local e = s[2](id)
            if type(e) == 'table' and field(e, F_TEXT) then score = score + 1 end
        end
        if forced and forced ~= 'auto' and s[1] == forced then
            -- Ручной выбор пользователя имеет приоритет над автоподбором
            m.lookup, m.strategy = s[2], s[1] .. ' (вручную)'
            m.coverage = string.format('%d/%d', score, #ids)
            return
        end
        if score > bestScore then bestFn, bestName, bestScore = s[2], s[1], score end
    end

    if bestFn then
        local changed = (m.strategy ~= bestName)
        m.lookup   = bestFn
        m.strategy = bestName
        m.coverage = string.format('%d/%d', bestScore, #ids)
        -- Сообщаем только при смене схемы, иначе чат засоряется
        -- при каждом открытии БП
        if changed then
            chat(('таблица "%s": схема "%s", распознано %s'):format(cat, bestName, m.coverage))
            if bestScore < #ids then
                chat(('часть заданий "%s" не распозналась. Введите /bpdebug'):format(cat))
            end
        end
    end
end

-- Пересобрать список заданий (объявлено заранее: нужно из колбэка загрузки)
local rebuildQuests
local lastCefItems
local lastUnresolved = {}   -- id, для которых не нашлось описания

local function buildUrl(server, key)
    return ('https://reserve-server-api.arizona.games/client/json/table/get?project=arizona&server=%d&key=%s')
        :format(server, key)
end

-- Сколько id из списка вообще находится в этой таблице (любой схемой)
local function bestCoverage(store, ids)
    local best = 0
    for _, lk in ipairs(lookupsFor(store)) do
        local score = 0
        for _, id in ipairs(ids) do
            local e = lk[2](id)
            if type(e) == 'table' and field(e, F_TEXT) then score = score + 1 end
        end
        if score > best then best = score end
    end
    return best
end

local function loadMissionTable(cat)
    local m = missions[cat]
    local server = tonumber(config.settings.server) or 1
    local url = buildUrl(server, m.key)

    async_http_request(url, function(result)
        if not result or #result == 0 then
            chat(('пустой ответ сервера для "%s"'):format(cat))
            return
        end
        -- JSON приходит в UTF-8 и таким и остаётся: ImGui ждёт UTF-8.
        -- В старой версии тут был лишний прогон UTF-8 -> CP1251 -> UTF-8,
        -- который портил символы, отсутствующие в CP1251.
        local ok, decoded = pcall(decodeJson, result)
        if not ok or type(decoded) ~= 'table' then
            chat(('не удалось разобрать JSON для "%s"'):format(cat))
            return
        end
        m.store  = normalizeTable(decoded)
        m.loaded = true
        if not m.store or (not m.store.list and not m.store.byKey) then
            chat(('неизвестный формат таблицы "%s"'):format(cat))
            return
        end
        -- Таблица могла приехать уже после того, как БП прислал задания -
        -- в этом случае пересобираем список сразу, без перезахода в БП
        if lastCefItems and rebuildQuests then rebuildQuests(lastCefItems) end
    end, function(err)
        chat(('ошибка загрузки "%s": %s'):format(cat, tostring(err)))
    end)
end

-- ---------------------------------------------------------------------
--  Автоподбор номера сервера
--
--  Таблицы миссий раздаются отдельно для каждого сервера, и на разных
--  серверах они разного размера. Если номер не тот, часть id из БП
--  просто отсутствует в таблице (симптом: coverage вида 10/26).
--  Перебираем номера и берём первый, который покрывает все id.
-- ---------------------------------------------------------------------

local probing      = false
local serverProbed = false
local probeLog     = {}

local function probeServers(ids, maxServer)
    if probing or #ids == 0 then return end
    probing = true
    serverProbed = true
    probeLog = {}

    lua_thread.create(function()
        chat(('подбираю номер сервера по %d заданиям, это займёт минуту...'):format(#ids))

        local bestServer, bestScore, bestSize = nil, -1, 0

        for s = 1, (maxServer or 30) do
            local done, body = false, nil
            async_http_request(buildUrl(s, missions.daily.key),
                function(r) body = r; done = true end,
                function() done = true end)

            local waited = 0
            while not done and waited < 8000 do wait(100); waited = waited + 100 end

            local score, size = -1, 0
            if body and #body > 0 then
                local ok, decoded = pcall(decodeJson, body)
                if ok and type(decoded) == 'table' then
                    local store = normalizeTable(decoded)
                    if store then
                        size  = store.list and #store.list or 0
                        score = bestCoverage(store, ids)
                    end
                end
            end
            probeLog[#probeLog + 1] = ('сервер %d: записей %d, покрытие %d/%d')
                :format(s, size, math.max(score, 0), #ids)

            if score > bestScore then bestServer, bestScore, bestSize = s, score, size end

            if score >= #ids then
                config.settings.server = s
                settings.server[0]     = s
                saveConfig()
                chat(('найден сервер %d (записей %d) - распознаны все %d заданий')
                    :format(s, size, #ids))
                loadMissionTable('daily')
                loadMissionTable('premium')
                probing = false
                return
            end
            wait(150)
        end

        chat(('полного совпадения нет. Лучший: сервер %s, покрытие %d/%d')
            :format(tostring(bestServer), math.max(bestScore, 0), #ids))
        chat('введите /bpdebug - в файле будет отчёт по всем серверам')
        probing = false
    end)
end

-- ---------------------------------------------------------------------
--  Модель заданий
-- ---------------------------------------------------------------------

local function questKey(q) return q.category .. '_' .. tostring(q.id) end
local function isHidden(q) return config.hidden[questKey(q)] == true end
local function isPinned(q) return config.pinned[questKey(q)] == true end

local function setHidden(q, v)
    config.hidden[questKey(q)] = v and true or nil
    saveConfig()
end

local function setPinned(q, v)
    config.pinned[questKey(q)] = v and true or nil
    saveConfig()
end

-- Категоризация по ключевым словам всего текста задания.
-- Старая версия группировала по ПЕРВОМУ СЛОВУ - из-за этого категории
-- выглядели случайным набором ("Проведите", "Заработайте", ...).
local CATEGORY_RULES = {
    { cat = 'Транспорт',  icon = 'car',              prio = 1, words = { 'машин', 'автомобил', 'транспорт', 'проедь', 'км ', 'километр', 'заправ', 'мотоцикл' } },
    { cat = 'Работа',     icon = 'briefcase',        prio = 2, words = { 'работ', 'смен', 'заработ', 'зарплат', 'груз', 'развоз', 'таксист', 'дальнобой' } },
    { cat = 'Покупки',    icon = 'cart-shopping',    prio = 3, words = { 'купи', 'покуп', 'потрат', 'магазин', 'приобрет' } },
    { cat = 'Рыбалка',    icon = 'fish',             prio = 4, words = { 'рыб', 'улов', 'удочк' } },
    { cat = 'Криминал',   icon = 'skull',            prio = 5, words = { 'ограб', 'угон', 'кража', 'украд', 'нелегал', 'наркот', 'склад', 'банд' } },
    { cat = 'Казино',     icon = 'dice',             prio = 6, words = { 'казино', 'ставк', 'рулетк', 'слот', 'ферм' } },
    { cat = 'Игроки',     icon = 'users',            prio = 7, words = { 'игрок', 'друз', 'семь', 'обмен', 'передай' } },
    { cat = 'Дом/Бизнес', icon = 'house',            prio = 8, words = { 'дом', 'бизнес', 'аренд', 'налог' } },
    { cat = 'Активность', icon = 'person-running',   prio = 9, words = { 'онлайн', 'час', 'минут', 'ивент', 'мероприят' } },
}

local function categorizeQuest(q)
    local text = q.text or ''
    for _, rule in ipairs(CATEGORY_RULES) do
        for _, w in ipairs(rule.words) do
            if text:find(w, 1, true) then
                return rule.cat, rule.icon, rule.prio
            end
        end
    end
    return 'Прочее', 'list', 50
end

-- Пересобирает список заданий из данных CEF.
-- lastCefItems хранит последнюю пачку, чтобы пересобрать список после
-- смены схемы/сервера без перезахода в БП.
rebuildQuests = function(items)
    lastCefItems = items

    -- сгруппировать id по категориям, чтобы подобрать схему сопоставления
    local idsByCat = {}
    for _, it in ipairs(items) do
        local cat = it.categoryId
        if cat == 'premium' and not premiumBP then cat = nil end
        if cat and missions[cat] then
            idsByCat[cat] = idsByCat[cat] or {}
            table.insert(idsByCat[cat], tonumber(it.id))
        end
    end
    for cat, ids in pairs(idsByCat) do
        chooseStrategy(cat, ids)
    end

    local list, missing, noTable = {}, 0, {}
    local unresolved = {}
    for _, it in ipairs(items) do
        -- В старой версии флаг visible игнорировался, из-за чего в окно
        -- попадали задания, которых нет в самом БП
        local visible = (it.visible == nil) or (tonumber(it.visible) ~= 0)
        local cat = it.categoryId
        if cat == 'premium' and not premiumBP then visible = false end

        if visible and missions[cat] and not missions[cat].lookup then
            -- Таблица миссий не загрузилась - без неё текста задания нет.
            -- Раньше такие задания просто молча пропадали.
            noTable[cat] = (noTable[cat] or 0) + 1
        elseif visible and missions[cat] then
            local entry = missions[cat].lookup(tonumber(it.id))
            if type(entry) == 'table' then
                local text = field(entry, F_TEXT)
                if text then
                    local max  = tonumber(field(entry, F_MAX)) or 1
                    if max < 1 then max = 1 end  -- иначе задание всегда "выполнено"
                    local curr = tonumber(it.progress) or 0
                    table.insert(list, {
                        id       = tonumber(it.id),
                        category = cat,
                        title    = tostring(field(entry, F_TITLE) or text),
                        text     = tostring(text),
                        curr     = clamp(curr, 0, max),
                        max      = max,
                        done     = curr >= max,
                    })
                else
                    missing = missing + 1
                    unresolved[#unresolved + 1] = tonumber(it.id)
                end
            else
                missing = missing + 1
                unresolved[#unresolved + 1] = tonumber(it.id)
            end
        end
    end

    quests = list
    lastUnresolved = unresolved

    for cat, n in pairs(noTable) do
        chat(('таблица "%s" не загружена, пропущено заданий: %d'):format(cat, n))
        chat('проверьте интернет и нажмите "Перезагрузить таблицы миссий" в /bphset')
    end

    if missing > 0 then
        chat(('не найдено описаний: %d из %d'):format(missing, #items))
        -- Чаще всего это значит, что таблица взята не от того сервера:
        -- нужных id в ней просто нет. Пробуем подобрать номер сервера.
        if not serverProbed and missions.daily.loaded then
            local ids = {}
            for _, it in ipairs(items) do
                if it.categoryId == 'daily' then ids[#ids + 1] = tonumber(it.id) end
            end
            defer(function() probeServers(ids, 30) end)
        end
    end
end

-- Фильтрация для отображения
local function visibleQuests(includeHidden)
    local search = ffi.string(search_buf)
    local out = {}
    for _, q in ipairs(quests) do
        local ok = includeHidden or not isHidden(q)
        if ok and filter_category ~= 'all' and q.category ~= filter_category then ok = false end
        if ok and filter_state == 'active' and q.done then ok = false end
        if ok and filter_state == 'done' and not q.done then ok = false end
        if ok and settings.hide_completed[0] and q.done then ok = false end
        if ok and #search > 0 and not q.text:lower():find(search:lower(), 1, true) then ok = false end
        if ok then table.insert(out, q) end
    end
    return out
end

local function sortQuests(list)
    table.sort(list, function(a, b)
        local pa, pb = isPinned(a) and not a.done, isPinned(b) and not b.done
        if pa ~= pb then return pa end
        if a.done ~= b.done then return not a.done end
        local ra = (a.max > 0) and (a.curr / a.max) or 0
        local rb = (b.max > 0) and (b.curr / b.max) or 0
        if ra ~= rb then return ra > rb end
        return a.text < b.text
    end)
    return list
end

-- ---------------------------------------------------------------------
--  Стиль
-- ---------------------------------------------------------------------

local function apply_custom_style()
    local style  = imgui.GetStyle()
    local colors = style.Colors
    local clr    = imgui.Col
    local V4     = imgui.ImVec4

    style.WindowRounding    = 8.0
    style.ChildRounding     = 6.0
    style.FrameRounding     = 5.0
    style.GrabRounding      = 5.0
    style.PopupRounding     = 6.0
    style.ScrollbarRounding = 9.0
    style.ScrollbarSize     = 10.0
    style.WindowPadding     = imgui.ImVec2(10, 10)
    style.FramePadding      = imgui.ImVec2(8, 5)
    style.ItemSpacing       = imgui.ImVec2(8, 6)
    style.WindowBorderSize  = 0.0

    colors[clr.Text]           = V4(0.92, 0.92, 0.95, 1.00)
    colors[clr.TextDisabled]   = V4(0.50, 0.50, 0.55, 1.00)
    colors[clr.WindowBg]       = V4(0.11, 0.11, 0.13, 0.98)
    colors[clr.ChildBg]        = V4(0.14, 0.14, 0.17, 0.55)
    colors[clr.PopupBg]        = V4(0.11, 0.11, 0.13, 0.98)
    colors[clr.Border]         = V4(0.25, 0.25, 0.28, 0.50)
    colors[clr.FrameBg]        = V4(0.18, 0.18, 0.21, 1.00)
    colors[clr.FrameBgHovered] = V4(0.23, 0.23, 0.27, 1.00)
    colors[clr.FrameBgActive]  = V4(0.26, 0.26, 0.30, 1.00)
    colors[clr.TitleBg]        = V4(0.09, 0.09, 0.11, 1.00)
    colors[clr.TitleBgActive]  = V4(0.09, 0.09, 0.11, 1.00)
    colors[clr.Button]         = V4(0.20, 0.20, 0.24, 1.00)
    colors[clr.ButtonHovered]  = V4(0.26, 0.26, 0.31, 1.00)
    colors[clr.ButtonActive]   = V4(0.16, 0.16, 0.19, 1.00)
    colors[clr.Header]         = V4(0.20, 0.22, 0.27, 1.00)
    colors[clr.HeaderHovered]  = V4(0.25, 0.27, 0.33, 1.00)
    colors[clr.HeaderActive]   = V4(0.17, 0.19, 0.23, 1.00)
    colors[clr.Separator]      = V4(0.25, 0.25, 0.28, 0.60)
    colors[clr.ScrollbarBg]    = V4(0.09, 0.09, 0.11, 0.60)
    colors[clr.ScrollbarGrab]  = V4(0.28, 0.28, 0.33, 1.00)
    colors[clr.CheckMark]      = V4(0.35, 0.70, 0.45, 1.00)
    colors[clr.PlotHistogram]  = V4(0.26, 0.59, 0.98, 1.00)
end

imgui.OnInitialize(function()
    -- Кириллический шрифт нужен обязательно: стандартный шрифт ImGui
    -- не содержит русских глифов, без этого весь текст будет квадратами
    local fontsDir = getFolderPath(0x14)
    for _, name in ipairs({ 'trebucbd.ttf', 'trebuc.ttf', 'arialbd.ttf', 'arial.ttf', 'segoeui.ttf' }) do
        local path = fontsDir .. '\\' .. name
        if doesFileExist(path) then
            imgui.GetIO().Fonts:AddFontFromFileTTF(path, 15, nil,
                imgui.GetIO().Fonts:GetGlyphRangesCyrillic())
            break
        end
    end

    if fa_status then
        local cfg = imgui.ImFontConfig()
        cfg.MergeMode  = true
        cfg.PixelSnapH = true
        iconRanges = new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
        imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(
            faicons.get_font_data_base85('solid'), 14, cfg, iconRanges)
    end

    imgui.GetIO().MouseDrawCursor = false
    apply_custom_style()
end)

-- ---------------------------------------------------------------------
--  Виджеты
-- ---------------------------------------------------------------------

local uid = 0
local function pushUID()
    uid = uid + 1
    imgui.PushIDInt(uid)
end

local function progressColor(ratio, alpha)
    if ratio >= 1.0    then return imgui.ImVec4(0.30, 0.75, 0.35, alpha) end
    if ratio >= 0.75   then return imgui.ImVec4(0.45, 0.75, 0.35, alpha) end
    if ratio >= 0.50   then return imgui.ImVec4(0.90, 0.70, 0.30, alpha) end
    if ratio >  0.0    then return imgui.ImVec4(0.90, 0.50, 0.20, alpha) end
    return imgui.ImVec4(0.26, 0.59, 0.98, alpha)
end

-- Прозрачность главного окна меняется правкой глобального стиля, поэтому
-- остальные окна обязаны выставлять её себе сами - иначе они наследуют
-- полупрозрачность режима оверлея
local function setWindowAlpha(a)
    local c = imgui.GetStyle().Colors
    c[imgui.Col.WindowBg].w      = a
    c[imgui.Col.TitleBg].w       = a
    c[imgui.Col.TitleBgActive].w = a
    c[imgui.Col.ChildBg].w       = 0.55
    c[imgui.Col.Text].w          = 1.0
end

local function segButton(label, active, width)
    local clicked
    if active then
        imgui.PushStyleColor(imgui.Col.Button,        imgui.ImVec4(0.26, 0.45, 0.75, 1.00))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.30, 0.50, 0.82, 1.00))
        imgui.PushStyleColor(imgui.Col.ButtonActive,  imgui.ImVec4(0.22, 0.40, 0.68, 1.00))
        clicked = imgui.Button(label, imgui.ImVec2(width, 24))
        imgui.PopStyleColor(3)
    else
        clicked = imgui.Button(label, imgui.ImVec2(width, 24))
    end
    return clicked
end

-- Карточка задания
local function drawQuestCard(q, is_active)
    local ratio  = (q.max > 0) and (q.curr / q.max) or 0
    local text   = q.text
    if q.max > 1 then
        text = string.format('%s (%d/%d)', q.text, q.curr, q.max)
    end

    local accent = imgui.ImVec4(0.28, 0.28, 0.32, 1.0)
    local tcol   = imgui.ImVec4(0.92, 0.92, 0.95, 1.0)
    if q.done then
        accent = imgui.ImVec4(0.25, 0.70, 0.35, 1.0)
        tcol   = imgui.ImVec4(0.55, 0.62, 0.55, 1.0)
    elseif isPinned(q) then
        accent = imgui.ImVec4(1.00, 0.75, 0.10, 1.0)
        tcol   = imgui.ImVec4(1.00, 0.87, 0.55, 1.0)
    elseif isHidden(q) then
        tcol   = imgui.ImVec4(0.45, 0.45, 0.48, 1.0)
    end

    if not is_active then
        -- Оверлей: только текст, без кнопок и без скрытых заданий
        if isHidden(q) then return end
        imgui.PushStyleColor(imgui.Col.Text, tcol)
        imgui.PushTextWrapPos(imgui.GetWindowWidth() - 16)
        imgui.Text((q.done and getIcon('circle-check') .. ' ' or '') .. text)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()
        return
    end

    local draw_list = imgui.GetWindowDrawList()
    local btnW      = 58
    local avail     = imgui.GetContentRegionAvail().x
    local textW     = math.max(60, avail - btnW - 10)
    local p         = imgui.GetCursorScreenPos()
    local startX    = imgui.GetCursorPosX()
    local startY    = imgui.GetCursorPosY()

    imgui.BeginGroup()
        imgui.Indent(6)
        imgui.PushStyleColor(imgui.Col.Text, tcol)
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + textW)
        imgui.Text(text)
        imgui.PopTextWrapPos()
        imgui.PopStyleColor()

        if not q.done and q.max > 1 then
            imgui.PushStyleColor(imgui.Col.PlotHistogram, progressColor(ratio, 0.9))
            imgui.ProgressBar(ratio, imgui.ImVec2(textW, 4), '')
            imgui.PopStyleColor()
        end
        imgui.Unindent(6)
    imgui.EndGroup()

    local blockH = math.max(imgui.GetItemRectSize().y, 26)

    -- Кнопки справа, на той же высоте
    imgui.SameLine()
    imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - btnW)
    imgui.SetCursorPosY(startY)

    local pinned = isPinned(q)
    if pinned then
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.55, 0.45, 0.10, 0.60))
        imgui.PushStyleColor(imgui.Col.Text,   imgui.ImVec4(1.00, 0.82, 0.25, 1.00))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.20, 0.20, 0.23, 0.45))
        imgui.PushStyleColor(imgui.Col.Text,   imgui.ImVec4(0.55, 0.55, 0.58, 1.00))
    end
    if imgui.Button(getIcon('thumbtack') .. '##pin', imgui.ImVec2(24, 24)) then
        setPinned(q, not pinned)
    end
    imgui.PopStyleColor(2)
    if imgui.IsItemHovered() then imgui.SetTooltip('Закрепить сверху') end

    imgui.SameLine(0, 4)
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.20, 0.20, 0.23, 0.45))
    imgui.PushStyleColor(imgui.Col.Text,   imgui.ImVec4(0.75, 0.40, 0.40, 1.00))
    -- В старой версии тут было getIcon('eye_slash') с подчёркиванием -
    -- такой иконки не существует, кнопка выходила пустой
    local eyeIcon = isHidden(q) and getIcon('eye') or getIcon('eye-slash')
    if imgui.Button(eyeIcon .. '##hide', imgui.ImVec2(24, 24)) then
        setHidden(q, not isHidden(q))
    end
    imgui.PopStyleColor(2)
    if imgui.IsItemHovered() then imgui.SetTooltip('Скрыть задание') end

    -- Цветная полоска слева
    draw_list:AddRectFilled(
        imgui.ImVec2(p.x - 4, p.y),
        imgui.ImVec2(p.x - 1, p.y + blockH),
        imgui.ColorConvertFloat4ToU32(accent), 2.0)

    -- Возвращаем курсор и по X тоже: после SameLine он остался у кнопок,
    -- и разделитель рисовался бы со смещением
    imgui.SetCursorPos(imgui.ImVec2(startX, startY + blockH + 4))
    imgui.Separator()
end

local function drawFlatList(list, is_active)
    for _, q in ipairs(sortQuests(list)) do
        pushUID()
        drawQuestCard(q, is_active)
        imgui.PopID()
    end
end

local function drawGroupedList(list, is_active)
    local cats, order = {}, {}
    for _, q in ipairs(list) do
        local name, icon, prio = categorizeQuest(q)
        if not cats[name] then
            cats[name] = { name = name, icon = icon, prio = prio, items = {}, done = 0 }
            table.insert(order, cats[name])
        end
        table.insert(cats[name].items, q)
        if q.done then cats[name].done = cats[name].done + 1 end
    end

    table.sort(order, function(a, b)
        local fa_ = (a.done == #a.items)
        local fb  = (b.done == #b.items)
        if fa_ ~= fb then return not fa_ end
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.name < b.name
    end)

    for _, c in ipairs(order) do
        local pct = (#c.items > 0) and math.floor(c.done / #c.items * 100) or 0
        local col = progressColor(pct / 100, is_active and 1.0 or 0.75)
        imgui.PushStyleColor(imgui.Col.Header,        imgui.ImVec4(col.x * 0.35, col.y * 0.35, col.z * 0.35, 1.0))
        imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(col.x * 0.45, col.y * 0.45, col.z * 0.45, 1.0))
        imgui.PushStyleColor(imgui.Col.HeaderActive,  imgui.ImVec4(col.x * 0.28, col.y * 0.28, col.z * 0.28, 1.0))

        if category_states[c.name] == nil then category_states[c.name] = true end
        imgui.SetNextItemOpen(category_states[c.name], imgui.Cond.Always)

        local header = string.format('%s %s  -  %d%% (%d/%d)',
            getIcon(c.icon), c.name, pct, c.done, #c.items)
        local open = imgui.CollapsingHeader(header)

        if imgui.IsItemClicked() and is_active then
            category_states[c.name] = not category_states[c.name]
        end

        if open then
            imgui.Indent(8)
            for _, q in ipairs(sortQuests(c.items)) do
                pushUID()
                drawQuestCard(q, is_active)
                imgui.PopID()
            end
            imgui.Unindent(8)
        end
        imgui.PopStyleColor(3)
    end
end

-- ---------------------------------------------------------------------
--  Главное окно
-- ---------------------------------------------------------------------

imgui.OnFrame(function() return win_state[0] end, function(player)
    uid = 0

    local is_active   = overlay_mode[0]
    local key_held    = isKeyDown(settings.cursor_key[0])
    local interactive = is_active or key_held
    local style       = imgui.GetStyle()

    local alpha_bg = is_active and 0.98 or 0.60
    style.Colors[imgui.Col.WindowBg].w     = alpha_bg
    style.Colors[imgui.Col.TitleBg].w      = alpha_bg
    style.Colors[imgui.Col.TitleBgActive].w = alpha_bg
    style.Colors[imgui.Col.ChildBg].w      = is_active and 0.55 or 0.35
    style.Colors[imgui.Col.Text].w         = is_active and 1.0 or 0.95

    local flags = imgui.WindowFlags.NoCollapse
    if interactive then
        player.HideCursor = false
        imgui.SetNextWindowSize(saved_size, imgui.Cond.FirstUseEver)
    else
        player.HideCursor = not sampIsCursorActive()
        imgui.GetIO().WantCaptureMouse = false
        imgui.SetNextWindowSize(saved_size, imgui.Cond.Always)
        flags = imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
              + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoFocusOnAppearing
    end
    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(320, 220), imgui.ImVec2(900, 1200))

    -- ВАЖНО: imgui.End() вызывается ВСЕГДА, вне зависимости от того,
    -- что вернул Begin. В старой версии End() стоял внутри if - при
    -- сворачивании/выходе окна за экран это ломало стек ImGui и роняло игру.
    local shown = imgui.Begin(getIcon('scroll') .. ' BP Helper', win_state, flags)
    if shown then
        if interactive then saved_size = imgui.GetWindowSize() end

        -- Уровень БП
        if settings.show_bp_level[0] and bpInfo then
            local expRatio = (bpInfo.maxExp > 0) and (bpInfo.exp / bpInfo.maxExp) or 0
            imgui.Text(string.format('%s Уровень %d', getIcon('star'), bpInfo.level))
            if premiumBP then
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(1.0, 0.78, 0.20, 1.0), '[PREMIUM]')
            end
            imgui.SameLine()
            imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - 120)
            imgui.PushStyleColor(imgui.Col.PlotHistogram, imgui.ImVec4(0.55, 0.40, 0.85, 1.0))
            imgui.ProgressBar(expRatio, imgui.ImVec2(120, 14),
                string.format('%d/%d', bpInfo.exp, bpInfo.maxExp))
            imgui.PopStyleColor()
        end

        -- Общий прогресс по заданиям
        local shownList = visibleQuests(false)
        local total, done = #shownList, 0
        for _, q in ipairs(shownList) do if q.done then done = done + 1 end end
        local pct = (total > 0) and (done / total) or 0

        imgui.PushStyleColor(imgui.Col.PlotHistogram, progressColor(pct, is_active and 1.0 or 0.85))
        imgui.ProgressBar(pct, imgui.ImVec2(-1, is_active and 18 or 14),
            string.format('Выполнено %d%%  (%d из %d)', math.floor(pct * 100), done, total))
        imgui.PopStyleColor()

        if interactive then
            imgui.Spacing()

            -- Фильтр по типу
            local w = (imgui.GetContentRegionAvail().x - 16) / 3
            if segButton('Все##c', filter_category == 'all', w) then filter_category = 'all' end
            imgui.SameLine(0, 8)
            if segButton('Дейли', filter_category == 'daily', w) then filter_category = 'daily' end
            imgui.SameLine(0, 8)
            if segButton('Премиум', filter_category == 'premium', w) then filter_category = 'premium' end

            -- Фильтр по состоянию
            if segButton('Все##s', filter_state == 'all', w) then filter_state = 'all' end
            imgui.SameLine(0, 8)
            if segButton('Активные', filter_state == 'active', w) then filter_state = 'active' end
            imgui.SameLine(0, 8)
            if segButton('Готовые', filter_state == 'done', w) then filter_state = 'done' end

            imgui.PushItemWidth(-1)
            imgui.InputTextWithHint('##search', getIcon('magnifying-glass') .. ' Поиск по тексту...',
                search_buf, ffi.sizeof(search_buf))
            imgui.PopItemWidth()
            imgui.Spacing()
        end

        -- Список
        imgui.BeginChild('QuestsList', imgui.ImVec2(0, interactive and -36 or 0), true)
            if #quests == 0 then
                if settings.show_instructions[0] then
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.85, 0.3, 1))
                    imgui.Text(getIcon('circle-info') .. ' Как пользоваться:')
                    imgui.PopStyleColor()
                    imgui.Separator()
                    imgui.Spacing()
                    imgui.TextWrapped('1. Откройте Battle Pass в игре (клавиша B) - скрипт перехватит список заданий.')
                    imgui.Spacing()
                    imgui.TextWrapped('2. /bph - показать или скрыть это окно.')
                    imgui.Spacing()
                    imgui.TextWrapped(string.format('3. %s - переключение между оверлеем и активным режимом.',
                        vkeys.id_to_name(settings.transparent_mode_key[0]) or '?'))
                    imgui.Spacing()
                    imgui.TextWrapped(string.format('4. Удерживайте %s, чтобы временно получить курсор.',
                        vkeys.id_to_name(settings.cursor_key[0]) or '?'))
                    imgui.Spacing()
                    imgui.TextWrapped('5. /bpdebug - если тексты заданий не совпадают с игрой.')
                end
            elseif #shownList == 0 then
                imgui.TextDisabled('Ничего не найдено по текущим фильтрам.')
            else
                if settings.group_quests[0] then
                    drawGroupedList(shownList, is_active)
                else
                    drawFlatList(shownList, is_active)
                end
            end
        imgui.EndChild()

        -- Нижняя панель
        if interactive then
            local hiddenCount = 0
            for _, q in ipairs(quests) do if isHidden(q) then hiddenCount = hiddenCount + 1 end end

            local bw = (imgui.GetContentRegionAvail().x - 16) / 3
            if imgui.Button(getIcon('chevron-up') .. ' Свернуть', imgui.ImVec2(bw, 26)) then
                for k in pairs(category_states) do category_states[k] = false end
            end
            imgui.SameLine(0, 8)
            if imgui.Button(string.format('%s Скрытые (%d)', getIcon('eye-slash'), hiddenCount),
                    imgui.ImVec2(bw, 26)) then
                hidden_window[0] = true
            end
            imgui.SameLine(0, 8)
            if imgui.Button(getIcon('gear') .. ' Настройки', imgui.ImVec2(bw, 26)) then
                settings_window[0] = true
            end
        end
    end
    imgui.End()
end)

-- ---------------------------------------------------------------------
--  Окно настроек
-- ---------------------------------------------------------------------

imgui.OnFrame(function() return settings_window[0] end, function(player)
    player.HideCursor = false
    setWindowAlpha(0.98)
    imgui.SetNextWindowSize(imgui.ImVec2(520, 400), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(
        imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2, imgui.GetIO().DisplaySize.y / 2),
        imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))

    local shown = imgui.Begin(getIcon('gear') .. ' BP Helper - настройки',
        settings_window, imgui.WindowFlags.NoCollapse)
    if shown then
        imgui.BeginChild('SettingsContent', imgui.ImVec2(0, -40), true)
            imgui.Text(getIcon('keyboard') .. ' Управление')
            imgui.Separator()
            imgui.Spacing()

            imgui.Text('Курсор (удержание):')
            imgui.SameLine()
            imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - 140)
            if imgui.Button((vkeys.id_to_name(settings.cursor_key[0]) or '?') .. '##ck',
                    imgui.ImVec2(130, 24)) then
                settings.waiting_for_key[0] = true
                settings.key_mode[0] = 0
            end
            if settings.waiting_for_key[0] and settings.key_mode[0] == 0 then
                imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), 'Нажмите клавишу...')
            end

            imgui.Spacing()
            imgui.Text('Режим оверлея:')
            imgui.SameLine()
            imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - 140)
            if imgui.Button((vkeys.id_to_name(settings.transparent_mode_key[0]) or '?') .. '##tk',
                    imgui.ImVec2(130, 24)) then
                settings.waiting_for_key[0] = true
                settings.key_mode[0] = 1
            end
            if settings.waiting_for_key[0] and settings.key_mode[0] == 1 then
                imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), 'Нажмите клавишу...')
            end

            imgui.Spacing()
            imgui.Separator()
            imgui.Spacing()
            imgui.Text(getIcon('sliders') .. ' Отображение')
            imgui.Separator()
            imgui.Spacing()

            if imgui.Checkbox('Группировать задания по категориям', settings.group_quests) then saveConfig() end
            if imgui.Checkbox('Скрывать выполненные задания', settings.hide_completed) then saveConfig() end
            if imgui.Checkbox('Показывать уровень Battle Pass', settings.show_bp_level) then saveConfig() end
            if imgui.Checkbox('Показывать инструкцию, когда нет заданий', settings.show_instructions) then saveConfig() end

            imgui.Spacing()
            imgui.Separator()
            imgui.Spacing()
            imgui.Text(getIcon('database') .. ' Данные и сопоставление заданий')
            imgui.Separator()
            imgui.Spacing()
            imgui.TextWrapped('Если тексты заданий не совпадают с игрой - сначала проверьте '
                .. 'номер сервера, затем переключите схему сопоставления. Ниже показан пример: '
                .. 'слева id из БП, справа найденный текст. Верная схема та, при которой текст '
                .. 'совпадает с игрой.')
            imgui.Spacing()

            imgui.Text('Номер сервера Arizona:')
            imgui.SameLine()
            imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - 140)
            imgui.PushItemWidth(130)
            if imgui.InputInt('##server', settings.server) then
                settings.server[0] = clamp(settings.server[0], 1, 99)
                saveConfig()
            end
            imgui.PopItemWidth()
            imgui.TextDisabled('  после смены нажмите "Перезагрузить таблицы миссий"')
            imgui.Spacing()

            for ci, cat in ipairs({ 'daily', 'premium' }) do
                imgui.PushIDInt(30000 + ci)
                local m = missions[cat]
                imgui.Text(string.format('%s  -  %s', cat,
                    m.loaded and string.format('записей: %d',
                        m.store and m.store.list and #m.store.list or 0)
                        or 'таблица не загружена'))

                if m.loaded and m.store then
                    local names = { 'auto' }
                    for _, s in ipairs(lookupsFor(m.store)) do names[#names + 1] = s[1] end

                    local cur = config.settings['strategy_' .. cat] or 'auto'
                    local bw = (imgui.GetContentRegionAvail().x - (#names - 1) * 4) / #names
                    for i, n in ipairs(names) do
                        if i > 1 then imgui.SameLine(0, 4) end
                        if segButton((n == 'auto' and 'авто' or n) .. '##' .. i, cur == n, bw) then
                            config.settings['strategy_' .. cat] = n
                            saveConfig()
                            -- сразу пересобрать список с новой схемой
                            if m.lastIds then chooseStrategy(cat, m.lastIds) end
                            if lastCefItems then rebuildQuests(lastCefItems) end
                        end
                    end

                    imgui.TextDisabled(string.format('  текущая: %s, распознано %s',
                        tostring(m.strategy), tostring(m.coverage)))

                    -- Предпросмотр: первые два задания
                    if m.lookup and m.lastIds then
                        for i = 1, math.min(2, #m.lastIds) do
                            local id = m.lastIds[i]
                            local e  = m.lookup(id)
                            local tx = (type(e) == 'table') and field(e, F_TEXT) or nil
                            imgui.TextDisabled(string.format('  id %d -> %s', id,
                                tx and tostring(tx) or '<не найдено>'))
                        end
                    end
                end
                imgui.Spacing()
                imgui.PopID()
            end

            if imgui.Button(getIcon('rotate') .. ' Перезагрузить таблицы миссий', imgui.ImVec2(-1, 26)) then
                defer(function()
                    loadMissionTable('daily')
                    loadMissionTable('premium')
                end)
            end

            if probing then
                imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), 'Идёт подбор сервера, подождите...')
            elseif imgui.Button(getIcon('magnifying-glass') .. ' Подобрать номер сервера автоматически',
                    imgui.ImVec2(-1, 26)) then
                if lastCefItems then
                    local ids = {}
                    for _, it in ipairs(lastCefItems) do
                        if it.categoryId == 'daily' then ids[#ids + 1] = tonumber(it.id) end
                    end
                    serverProbed = false
                    defer(function() probeServers(ids, 30) end)
                else
                    chat('сначала откройте Battle Pass в игре, чтобы скрипт увидел задания')
                end
            end
        imgui.EndChild()

        if imgui.Button('Сохранить', imgui.ImVec2(120, 28)) then
            saveConfig()
            chat('настройки сохранены')
        end
        imgui.SameLine()
        if imgui.Button('Закрыть', imgui.ImVec2(120, 28)) then
            settings_window[0] = false
        end
    end
    imgui.End()

    if settings.waiting_for_key[0] then
        for key = 3, 255 do
            if isKeyJustPressed(key) then
                if settings.key_mode[0] == 0 then
                    settings.cursor_key[0] = key
                else
                    settings.transparent_mode_key[0] = key
                end
                settings.waiting_for_key[0] = false
                saveConfig()
                break
            end
        end
    end
end)

-- ---------------------------------------------------------------------
--  Окно скрытых заданий
-- ---------------------------------------------------------------------

imgui.OnFrame(function() return hidden_window[0] end, function(player)
    player.HideCursor = false
    setWindowAlpha(0.98)
    imgui.SetNextWindowSize(imgui.ImVec2(600, 450), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(
        imgui.ImVec2(imgui.GetIO().DisplaySize.x / 2, imgui.GetIO().DisplaySize.y / 2),
        imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))

    local shown = imgui.Begin(getIcon('eye-slash') .. ' BP Helper - скрытые задания',
        hidden_window, imgui.WindowFlags.NoCollapse)
    if shown then
        local list = {}
        for _, q in ipairs(quests) do
            if isHidden(q) then table.insert(list, q) end
        end

        if #list == 0 then
            imgui.Spacing()
            imgui.TextDisabled('Скрытых заданий нет.')
        else
            imgui.Text(string.format('Скрыто заданий: %d', #list))
            imgui.Separator()

            imgui.BeginChild('HiddenList', imgui.ImVec2(0, -40), true)
                for i, q in ipairs(list) do
                    imgui.PushIDInt(20000 + i)
                    local t = q.text
                    if q.max > 1 then t = string.format('%s (%d/%d)', q.text, q.curr, q.max) end
                    imgui.PushStyleColor(imgui.Col.Text,
                        q.done and imgui.ImVec4(0.5, 0.8, 0.5, 1) or imgui.ImVec4(0.85, 0.85, 0.9, 1))
                    imgui.PushTextWrapPos(imgui.GetWindowContentRegionMax().x - 140)
                    imgui.Text(t)
                    imgui.PopTextWrapPos()
                    imgui.PopStyleColor()

                    imgui.SameLine()
                    imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - 130)
                    if imgui.Button(getIcon('eye') .. ' Показать', imgui.ImVec2(125, 24)) then
                        setHidden(q, false)
                    end
                    imgui.Separator()
                    imgui.PopID()
                end
            imgui.EndChild()

            if imgui.Button('Показать все', imgui.ImVec2(140, 28)) then
                config.hidden = {}
                saveConfig()
                chat('все задания показаны')
            end
            imgui.SameLine()
        end

        if imgui.Button('Закрыть', imgui.ImVec2(140, 28)) then
            hidden_window[0] = false
        end
    end
    imgui.End()
end)

-- ---------------------------------------------------------------------
--  Диагностика
-- ---------------------------------------------------------------------

local function dumpDebug()
    chat('--- диагностика ---')
    for _, cat in ipairs({ 'daily', 'premium' }) do
        local m = missions[cat]
        if not m.loaded then
            chat(('%s: таблица не загружена'):format(cat))
        else
            local size = m.store and m.store.list and #m.store.list or 0
            chat(('%s: записей %d, схема %s, покрытие %s'):format(
                cat, size, tostring(m.strategy), tostring(m.coverage)))
        end
    end
    chat(('заданий в списке: %d, премиум БП: %s'):format(#quests, tostring(premiumBP)))

    local path = getWorkingDirectory() .. '\\BP Helper debug.txt'
    local f = io.open(path, 'w')
    if f then
        f:write('=== BP Helper debug ===\n')
        for _, cat in ipairs({ 'daily', 'premium' }) do
            local m = missions[cat]
            f:write(('\n[%s] loaded=%s strategy=%s coverage=%s size=%s\n'):format(
                cat, tostring(m.loaded), tostring(m.strategy), tostring(m.coverage),
                tostring(m.store and m.store.list and #m.store.list or 0)))
            -- первые 5 записей таблицы, чтобы увидеть реальные имена полей
            if m.store and m.store.list then
                for i = 1, math.min(5, #m.store.list) do
                    local e = m.store.list[i]
                    if type(e) == 'table' then
                        local parts = {}
                        for k, v in pairs(e) do
                            if type(v) ~= 'table' then
                                parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
                            end
                        end
                        f:write(('  [%d] %s\n'):format(i, table.concat(parts, ' | ')))
                    end
                end
            end
        end
        f:write(('\nномер сервера: %s\n'):format(tostring(config.settings.server)))

        if #lastUnresolved > 0 then
            f:write(('\n=== НЕ найдено описаний (%d) ===\n'):format(#lastUnresolved))
            f:write('id: ' .. table.concat(lastUnresolved, ', ') .. '\n')
            f:write('Если эти id больше размера таблицы - таблица не от вашего сервера.\n')
        end

        if #probeLog > 0 then
            f:write('\n=== перебор серверов ===\n')
            for _, line in ipairs(probeLog) do f:write('  ' .. line .. '\n') end
        end

        f:write('\n=== распознанные задания ===\n')
        for _, q in ipairs(quests) do
            f:write(('%s #%d  %d/%d  %s\n'):format(q.category, q.id, q.curr, q.max, q.text))
        end
        f:close()
        chat('подробности записаны в moonloader\\BP Helper debug.txt')
    end
end

-- ---------------------------------------------------------------------
--  Приём данных от CEF
-- ---------------------------------------------------------------------

addEventHandler('onReceivePacket', function(id, bs)
    if id ~= 220 then return true end

    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 17 then return true end
    raknetBitStreamIgnoreBits(bs, 32)

    local length  = raknetBitStreamReadInt16(bs)
    local encoded = raknetBitStreamReadInt8(bs)
    local str = (encoded ~= 0)
        and raknetBitStreamDecodeString(bs, length + encoded)
        or raknetBitStreamReadString(bs, length)
    if not str then return true end

    if str:find('event.battlePass.initializeBattlePassData', 1, true) then
        local payload = str:match('`(.+)`')
        if payload then
            local ok, data = pcall(decodeJson, payload)
            if ok and type(data) == 'table' and type(data[1]) == 'table' then
                local d = data[1]
                premiumBP = (tonumber(d.premium) or 0) ~= 0
                bpInfo = {
                    level  = tonumber(d.level) or 0,
                    exp    = tonumber(d.exp) or 0,
                    maxExp = tonumber(d.maxExp) or 0,
                }
            end
        end
        quests = {}

    elseif str:find('event.battlePass.updateQuestsProgress', 1, true) then
        local inner = str:match('%[%[(.-)%]%]')
        if inner then
            local ok, data = pcall(decodeJson, '[' .. inner .. ']')
            if ok and type(data) == 'table' then
                rebuildQuests(data)
            end
        end
    end

    return true
end)

-- Отметка выполнения по сообщению в чате
function sampev.onServerMessage(color, text)
    if not text:find(cp('выполнили задание'), 1, true) then return end
    local title = text:match("'(.-)'")
    if not title then return end
    title = u8(title)
    for _, q in ipairs(quests) do
        if q.title == title or q.text == title then
            q.done = true
            q.curr = q.max
            config.pinned[questKey(q)] = nil
            break
        end
    end
end

-- ---------------------------------------------------------------------
--  main
-- ---------------------------------------------------------------------

function main()
    while not isSampAvailable() do wait(100) end

    chat('скрипт успешно загружен')
    chat('команды: {32CD32}/bph{FFFFFF}, {32CD32}/bphset{FFFFFF}, {32CD32}/bpdebug')

    loadMissionTable('daily')
    loadMissionTable('premium')

    sampRegisterChatCommand('bph', function()
        win_state[0] = not win_state[0]
    end)
    sampRegisterChatCommand('bphset', function()
        settings_window[0] = not settings_window[0]
    end)
    sampRegisterChatCommand('bpdebug', dumpDebug)

    while true do
        wait(0)
        runPendingActions()
        if win_state[0] and not sampIsChatInputActive() and not sampIsDialogActive()
                and isKeyJustPressed(settings.transparent_mode_key[0]) then
            overlay_mode[0] = not overlay_mode[0]
        end
    end
end
