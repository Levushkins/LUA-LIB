script_name("FriendChecker")
script_author("@lua_arz")
script_version("1.1")

--[[
    FriendChecker v1.1

    Что исправлено по сравнению с 1.0 (скрипт отвечал на команду только один раз):

    1. Любая ошибка Lua внутри цикла main(), внутри обработчика чат-команды или
       внутри кадра mimgui выгружала скрипт целиком. После выгрузки MoonLoader
       снимает регистрацию чат-команд, поэтому /fc переставал реагировать —
       ровно то поведение, которое описано в проблеме ("сработало один раз,
       дальше тишина"). Теперь все три точки входа обёрнуты в pcall, ошибка
       пишется в чат/лог, а скрипт продолжает жить.

    2. sampGetMaxPlayerId() вызывался без обязательного аргумента
       (int id = sampGetMaxPlayerId(bool streamed)). В зависимости от сборки
       MoonLoader это либо ошибка аргумента, либо nil в качестве предела цикла
       ("'for' limit must be a number") — падение происходило на первом же
       сканировании, то есть через 3 секунды после загрузки. Теперь аргумент
       передаётся явно, результат валидируется и ограничивается 0..1003.

    3. ffi.copy(editNoteBuf, friend.note) копировал заметку без учёта размера
       буфера: заметка длиннее 255 байт затирала соседнюю память (тихий краш).
       Копирование теперь идёт через безопасный setBuf() с обрезкой по длине.

    4. Модальный попап заметки: если окно закрывали крестиком, пока попап открыт,
       кадр переставал рисоваться, а попап оставался в стеке ImGui и блокировал
       ввод при следующем открытии окна. Редактор заметки переделан на обычную
       встроенную панель — стек попапов больше не участвует.

    5. Результаты imgui.OnFrame/imgui.OnInitialize сохраняются в переменные
       (как в официальных примерах mimgui), чтобы объект кадра гарантированно
       не был собран сборщиком мусора.

    6. Значения из конфига приводятся к нужным типам перед записью в ffi-буферы
       (битый или частично заполненный JSON больше не роняет загрузку), а
       saveConfig() честно сообщает, если JSON-энкодер недоступен, вместо того
       чтобы молча записать "{}" и потерять список друзей.

    7. Пользовательский текст (ники, заметки) выводится через TextUnformatted:
       символ '%' в заметке больше не попадает в форматную строку ImGui.
       Обрезка длинной заметки не рвёт UTF-8 символ пополам.
]]

local imgui = require 'mimgui'
local encoding = require 'encoding'
local ffi = require 'ffi'
local new = imgui.new

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local IS_UTF8 = #'А' > 1

local _uiCache = {}
local function ui(s)
    if not _uiCache[s] then
        _uiCache[s] = IS_UTF8 and s or u8(s)
    end
    return _uiCache[s]
end

local function tc(s)
    if IS_UTF8 then return u8:decode(s) end
    return s
end

local function noteForChat(s)
    if not s or s == '' then return '' end
    return u8:decode(s)
end

local function cmdNoteToUtf8(s)
    if not s or s == '' then return '' end
    return u8(s)
end

-- ========== Защита от выгрузки скрипта ==========

local CHAT_PREFIX = '{00BFFF}[Friends] '

local function chatMsg(text, color)
    sampAddChatMessage(text, color or 0xFFFFFF)
end

local lastErrorText, lastErrorTime = nil, 0

local function reportError(where, err)
    err = tostring(err)
    print('[FriendChecker] error in ' .. where .. ': ' .. err)
    -- один и тот же текст ошибки не спамим чаще раза в 10 секунд
    if err ~= lastErrorText or os.clock() - lastErrorTime > 10 then
        lastErrorText, lastErrorTime = err, os.clock()
        if sampAddChatMessage then
            chatMsg(CHAT_PREFIX .. '{FF6347}' .. tc('Ошибка (') .. where .. '): ' .. err, 0x00BFFF)
        end
    end
end

-- Выполняет fn, но не даёт ошибке уронить (и выгрузить) скрипт.
local function safeCall(where, fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        reportError(where, res)
        return nil
    end
    return res
end

-- ========== JSON ==========

local cjsonOk, cjsonMod = pcall(require, 'cjson')

local function jsonEncode(t)
    if cjsonOk and cjsonMod then
        local ok, res = pcall(cjsonMod.encode, t)
        if ok and type(res) == 'string' then return res end
    end
    if encodeJson then
        local ok, res = pcall(encodeJson, t)
        if ok and type(res) == 'string' then return res end
    end
    return nil
end

local function jsonDecode(s)
    if cjsonOk and cjsonMod then
        local ok, result = pcall(cjsonMod.decode, s)
        if ok and type(result) == 'table' then return result end
    end
    if decodeJson then
        local ok, result = pcall(decodeJson, s)
        if ok and type(result) == 'table' then return result end
    end
    return {}
end

-- ========== Конфиг ==========

local CONFIG_DIR = getWorkingDirectory() .. '/config'
local CONFIG_PATH = CONFIG_DIR .. '/FriendChecker.json'

local config = {
    friends = {},
    settings = {
        mode = 3,
        notifyJoin = true,
        notifyLeave = true,
        showLevel = true
    }
}

local onlineFriends = {}
local prevOnlineSet = {}
local firstScan = true

local mainWindow = new.bool(false)
local addNickBuf = new.char[128]()
local addNoteBuf = new.char[256]()
local addIdBuf = new.char[16]()
local searchBuf = new.char[128]()
local editNoteBuf = new.char[256]()
local editNoteTarget = ''
local friendToRemoveNick = nil
local filterMode = new.int(0)
local settingsMode = new.int(2)
local notifyJoinChk = new.bool(true)
local notifyLeaveChk = new.bool(true)
local showLevelChk = new.bool(true)
local addStatusText = ''
local addStatusColor = nil
local addStatusTime = 0
local saveWarned = false

local COLOR_GREEN = imgui.ImVec4(0.0, 1.0, 0.0, 1.0)
local COLOR_RED = imgui.ImVec4(1.0, 0.35, 0.3, 1.0)
local COLOR_WHITE = imgui.ImVec4(0.92, 0.92, 0.95, 1.0)
local COLOR_GRAY = imgui.ImVec4(0.50, 0.50, 0.55, 1.0)
local COLOR_YELLOW = imgui.ImVec4(1.0, 0.85, 0.0, 1.0)
local COLOR_CYAN = imgui.ImVec4(0.26, 0.72, 0.96, 1.0)
local COLOR_ACTIVE_BTN = imgui.ImVec4(0.26, 0.72, 0.96, 0.80)
local COLOR_ACTIVE_BTN_H = imgui.ImVec4(0.26, 0.72, 0.96, 0.90)

-- ========== Безопасная работа с буферами и текстом ==========

-- Копирование строки в char-буфер с обрезкой по его размеру (без выхода за границы).
local function setBuf(buf, s)
    s = tostring(s or '')
    local size = ffi.sizeof(buf)
    if #s > size - 1 then s = s:sub(1, size - 1) end
    ffi.fill(buf, size)
    if #s > 0 then ffi.copy(buf, s, #s) end
end

local function clearBuf(buf)
    ffi.fill(buf, ffi.sizeof(buf))
end

-- Вывод текста, пришедшего от пользователя (ник, заметка): '%' не должен
-- попасть в форматную строку ImGui.
local function textSafe(s)
    s = tostring(s or '')
    if imgui.TextUnformatted then
        imgui.TextUnformatted(s)
    else
        imgui.Text((s:gsub('%%', '%%%%')))
    end
end

local function textColoredSafe(color, s)
    imgui.PushStyleColor(imgui.Col.Text, color)
    textSafe(s)
    imgui.PopStyleColor()
end

-- Обрезка UTF-8 строки по количеству байт без разрыва символа.
local function utf8Trim(s, maxBytes)
    if #s <= maxBytes then return s end
    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        -- не режем посреди многобайтовой последовательности
        if not b or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut) .. '...'
end

local function toBool(v, default)
    if type(v) == 'boolean' then return v end
    if v == nil then return default end
    if type(v) == 'number' then return v ~= 0 end
    if v == 'true' then return true end
    if v == 'false' then return false end
    return default
end

local function toInt(v, default)
    local n = tonumber(v)
    if not n then return default end
    return math.floor(n)
end

-- ========== Загрузка/сохранение ==========

local function ensureConfigDir()
    if doesDirectoryExist and createDirectory then
        if not doesDirectoryExist(CONFIG_DIR) then
            createDirectory(CONFIG_DIR)
        end
    end
end

local function saveConfig()
    config.settings.mode = settingsMode[0] + 1
    config.settings.notifyJoin = notifyJoinChk[0]
    config.settings.notifyLeave = notifyLeaveChk[0]
    config.settings.showLevel = showLevelChk[0]

    local encoded = jsonEncode(config)
    if not encoded then
        if not saveWarned then
            saveWarned = true
            chatMsg(CHAT_PREFIX .. '{FF6347}'
                .. tc('Не найден JSON-энкодер, список друзей не сохраняется.'), 0x00BFFF)
        end
        return false
    end

    ensureConfigDir()
    local f, err = io.open(CONFIG_PATH, 'w')
    if not f then
        reportError('saveConfig', err or 'io.open failed')
        return false
    end
    f:write(encoded)
    f:close()
    return true
end

local function loadConfig()
    local f = io.open(CONFIG_PATH, 'r')
    if f then
        local content = f:read('*a')
        f:close()
        if content and content ~= '' then
            local data = jsonDecode(content)
            if type(data) == 'table' then
                if type(data.friends) == 'table' then
                    local list = {}
                    for _, fr in ipairs(data.friends) do
                        -- пропускаем битые записи вместо падения на них позже
                        if type(fr) == 'table' and type(fr.nickname) == 'string' and fr.nickname ~= '' then
                            list[#list + 1] = {
                                nickname = fr.nickname,
                                note = type(fr.note) == 'string' and fr.note or '',
                                marked = toBool(fr.marked, false)
                            }
                        end
                    end
                    config.friends = list
                end
                if type(data.settings) == 'table' then
                    local s = data.settings
                    config.settings.mode = toInt(s.mode, config.settings.mode)
                    config.settings.notifyJoin = toBool(s.notifyJoin, config.settings.notifyJoin)
                    config.settings.notifyLeave = toBool(s.notifyLeave, config.settings.notifyLeave)
                    config.settings.showLevel = toBool(s.showLevel, config.settings.showLevel)
                end
            end
        end
    end

    -- значения в ffi-буферы кладём только после нормализации типов
    local mode = config.settings.mode
    if mode < 1 or mode > 3 then mode = 3 end
    config.settings.mode = mode
    settingsMode[0] = mode - 1
    notifyJoinChk[0] = config.settings.notifyJoin and true or false
    notifyLeaveChk[0] = config.settings.notifyLeave and true or false
    showLevelChk[0] = config.settings.showLevel and true or false
end

-- ========== Список друзей ==========

local function findFriend(nickname)
    for i, f in ipairs(config.friends) do
        if f.nickname == nickname then return i, f end
    end
    return nil, nil
end

local function addFriendEntry(nickname, note)
    if findFriend(nickname) then return false end
    table.insert(config.friends, {
        nickname = nickname,
        note = note or '',
        marked = false
    })
    saveConfig()
    return true
end

local function removeFriendEntry(nickname)
    local idx = findFriend(nickname)
    if not idx then return false end
    table.remove(config.friends, idx)
    saveConfig()
    return true
end

local function toggleMark(nickname)
    local _, fr = findFriend(nickname)
    if not fr then return nil end
    fr.marked = not fr.marked
    saveConfig()
    return fr.marked
end

local function isFriendOnline(nickname)
    return onlineFriends[nickname] ~= nil
end

-- int id = sampGetMaxPlayerId(bool streamed) — аргумент обязателен.
local function getMaxPlayerIdSafe()
    if sampGetMaxPlayerId then
        local ok, id = pcall(sampGetMaxPlayerId, false)
        id = ok and tonumber(id) or nil
        if id and id >= 0 then
            return math.min(math.floor(id), 1003)
        end
    end
    return 1003
end

-- ========== Чат ==========

local function notifyJoinChat(nick, data)
    if config.settings.mode == 2 then return end
    if not config.settings.notifyJoin then return end
    local msg = CHAT_PREFIX .. '{FFFFFF}' .. nick .. ' {00BFFF}[' .. data.id .. ']'
    if config.settings.showLevel then
        msg = msg .. ' {FFFFFF}(Lvl: ' .. data.score .. ')'
    end
    msg = msg .. ' {00FF00}' .. tc('зашел на сервер.')
    chatMsg(msg, 0x00BFFF)
end

local function notifyLeaveChat(nick)
    if config.settings.mode == 2 then return end
    if not config.settings.notifyLeave then return end
    chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. nick .. ' {FF6347}' .. tc('вышел с сервера.'), 0x00BFFF)
end

local function showOnlineInChat()
    local count = 0
    for _, fr in ipairs(config.friends) do
        if isFriendOnline(fr.nickname) then
            local d = onlineFriends[fr.nickname]
            local msg = CHAT_PREFIX .. '{00FF00}[ON] {FFFFFF}' .. fr.nickname
                .. ' {00BFFF}[ID: ' .. d.id .. ']'
            if config.settings.showLevel then
                msg = msg .. ' {FFFFFF}(Lvl: ' .. d.score .. ')'
            end
            msg = msg .. ' {AAAAAA}Ping: ' .. d.ping
            chatMsg(msg, 0x00BFFF)
            count = count + 1
        end
    end
    if count == 0 then
        chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. tc('Нет друзей онлайн.'), 0x00BFFF)
    else
        chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. tc('Итого онлайн: ') .. count, 0x00BFFF)
    end
end

local function showListInChat()
    if #config.friends == 0 then
        chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. tc('Список друзей пуст.'), 0x00BFFF)
        return
    end
    chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. tc('Список друзей:'), 0x00BFFF)
    for _, fr in ipairs(config.friends) do
        local status = isFriendOnline(fr.nickname) and '{00FF00}[ON]' or '{FF6347}[OFF]'
        local mark = fr.marked and ' {FFD700}*' or ''
        local msg = CHAT_PREFIX .. status .. ' {FFFFFF}' .. fr.nickname .. mark
        if fr.note and fr.note ~= '' then
            msg = msg .. ' {AAAAAA}- ' .. noteForChat(fr.note)
        end
        chatMsg(msg, 0x00BFFF)
    end
end

local function showHelp()
    chatMsg(CHAT_PREFIX .. '{FFFFFF}=== Friend Checker v1.1 ===', 0x00BFFF)
    chatMsg('{FFFFFF}/fc, /friends  -  ' .. tc('открыть/закрыть меню'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc add <nick> [note]  -  ' .. tc('добавить друга'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc del <nick>  -  ' .. tc('удалить друга'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc mark <nick>  -  ' .. tc('пометить/снять'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc online  -  ' .. tc('друзья онлайн'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc list  -  ' .. tc('весь список'), 0xFFFFFF)
    chatMsg('{FFFFFF}/fc help  -  ' .. tc('справка'), 0xFFFFFF)
end

-- ========== Сканирование ==========

local function scanPlayers()
    local current = {}
    local maxId = getMaxPlayerIdSafe()
    for id = 0, maxId do
        if sampIsPlayerConnected(id) then
            local nick = sampGetPlayerNickname(id)
            if nick and nick ~= '' and findFriend(nick) then
                current[nick] = {
                    id = id,
                    score = sampGetPlayerScore(id) or 0,
                    ping = sampGetPlayerPing(id) or 0
                }
            end
        end
    end

    if firstScan then
        local count = 0
        for _ in pairs(current) do count = count + 1 end
        if count > 0 then
            chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. tc('Друзей онлайн: ') .. count, 0x00BFFF)
        end
        firstScan = false
    else
        for nick, data in pairs(current) do
            if not prevOnlineSet[nick] then
                notifyJoinChat(nick, data)
            end
        end
        for nick in pairs(prevOnlineSet) do
            if not current[nick] then
                notifyLeaveChat(nick)
            end
        end
    end

    onlineFriends = current
    prevOnlineSet = {}
    for nick in pairs(current) do
        prevOnlineSet[nick] = true
    end
end

-- ========== Команды ==========

local function cmdHandlerImpl(arg)
    local parts = {}
    for w in tostring(arg or ''):gmatch('%S+') do
        parts[#parts + 1] = w
    end
    local cmd = parts[1]

    if not cmd or cmd == '' then
        mainWindow[0] = not mainWindow[0]
        return
    end

    cmd = cmd:lower()

    if cmd == 'add' then
        local nick = parts[2]
        if not nick then
            chatMsg(CHAT_PREFIX .. '{FF6347}/fc add <nick> [note]', 0x00BFFF)
            return
        end
        local note = ''
        if #parts > 2 then
            local np = {}
            for i = 3, #parts do np[#np + 1] = parts[i] end
            note = cmdNoteToUtf8(table.concat(np, ' '))
        end
        if addFriendEntry(nick, note) then
            chatMsg(CHAT_PREFIX .. '{00FF00}' .. tc('Добавлен: ') .. nick, 0x00BFFF)
        else
            chatMsg(CHAT_PREFIX .. '{FF6347}' .. tc('Уже в списке: ') .. nick, 0x00BFFF)
        end

    elseif cmd == 'del' then
        local nick = parts[2]
        if not nick then
            chatMsg(CHAT_PREFIX .. '{FF6347}/fc del <nick>', 0x00BFFF)
            return
        end
        if removeFriendEntry(nick) then
            chatMsg(CHAT_PREFIX .. '{00FF00}' .. tc('Удален: ') .. nick, 0x00BFFF)
        else
            chatMsg(CHAT_PREFIX .. '{FF6347}' .. tc('Не найден: ') .. nick, 0x00BFFF)
        end

    elseif cmd == 'mark' then
        local nick = parts[2]
        if not nick then
            chatMsg(CHAT_PREFIX .. '{FF6347}/fc mark <nick>', 0x00BFFF)
            return
        end
        local result = toggleMark(nick)
        if result ~= nil then
            local state = result and tc('помечен') or tc('пометка снята')
            chatMsg(CHAT_PREFIX .. '{FFFFFF}' .. nick .. ': ' .. state, 0x00BFFF)
        else
            chatMsg(CHAT_PREFIX .. '{FF6347}' .. tc('Не найден: ') .. nick, 0x00BFFF)
        end

    elseif cmd == 'online' then
        showOnlineInChat()

    elseif cmd == 'list' then
        showListInChat()

    elseif cmd == 'help' then
        showHelp()

    else
        chatMsg(CHAT_PREFIX .. '{FF6347}' .. tc('Неизвестная команда. /fc help'), 0x00BFFF)
    end
end

-- Ошибка внутри обработчика больше не выгружает скрипт вместе с командами.
local function cmdHandler(arg)
    safeCall('/fc', cmdHandlerImpl, arg)
end

local function cmdFriends()
    safeCall('/friends', function()
        mainWindow[0] = not mainWindow[0]
    end)
end

-- ========== Интерфейс ==========

local function setAddStatus(text, color)
    addStatusText = text
    addStatusColor = color or COLOR_WHITE
    addStatusTime = os.clock()
end

local function filterButton(label, mode)
    if filterMode[0] == mode then
        imgui.PushStyleColor(imgui.Col.Button, COLOR_ACTIVE_BTN)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, COLOR_ACTIVE_BTN_H)
    end
    local clicked = imgui.Button(label)
    if filterMode[0] == mode then
        imgui.PopStyleColor(2)
    end
    if clicked then filterMode[0] = mode end
end

local function renderNoteEditor()
    if editNoteTarget == '' then return end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.TextColored(COLOR_CYAN, ui('Заметка для:'))
    imgui.SameLine()
    textSafe(editNoteTarget)

    imgui.PushItemWidth(-1)
    imgui.InputText('##editnoteinput', editNoteBuf, ffi.sizeof(editNoteBuf))
    imgui.PopItemWidth()

    if imgui.Button(ui('Сохранить') .. '##savenote', imgui.ImVec2(130, 0)) then
        local _, fr = findFriend(editNoteTarget)
        if fr then
            fr.note = ffi.string(editNoteBuf)
            saveConfig()
        end
        editNoteTarget = ''
        clearBuf(editNoteBuf)
    end
    imgui.SameLine()
    if imgui.Button(ui('Отмена') .. '##cancelnote', imgui.ImVec2(130, 0)) then
        editNoteTarget = ''
        clearBuf(editNoteBuf)
    end
end

local function renderFriendsTab()
    local totalCount = #config.friends
    local onlineCount = 0
    for _, f in ipairs(config.friends) do
        if isFriendOnline(f.nickname) then onlineCount = onlineCount + 1 end
    end
    imgui.TextColored(COLOR_CYAN,
        ui('Всего: ') .. tostring(totalCount)
        .. '  |  ' .. ui('Онлайн: ') .. tostring(onlineCount))
    imgui.Spacing()

    filterButton(ui('Все'), 0)
    imgui.SameLine()
    filterButton(ui('Онлайн'), 1)
    imgui.SameLine()
    filterButton(ui('Оффлайн'), 2)
    imgui.SameLine()
    filterButton(ui('Помеченные'), 3)

    imgui.Spacing()
    imgui.Text(ui('Поиск:'))
    imgui.SameLine()
    imgui.PushItemWidth(-1)
    imgui.InputText('##search', searchBuf, ffi.sizeof(searchBuf))
    imgui.PopItemWidth()
    imgui.Spacing()

    local searchStr = ffi.string(searchBuf):lower()

    -- место под редактор заметки резервируем заранее, чтобы список не прыгал
    local avail = imgui.GetContentRegionAvail()
    local listHeight = avail.y
    if editNoteTarget ~= '' then
        listHeight = listHeight - 100
    end
    if listHeight < 60 then listHeight = 60 end

    imgui.BeginChild('##friendlist', imgui.ImVec2(avail.x, listHeight), true)

    local hasVisible = false
    for i, friend in ipairs(config.friends) do
        local online = isFriendOnline(friend.nickname)

        local show = true
        if filterMode[0] == 1 and not online then show = false end
        if filterMode[0] == 2 and online then show = false end
        if filterMode[0] == 3 and not friend.marked then show = false end
        if searchStr ~= '' and not friend.nickname:lower():find(searchStr, 1, true) then
            show = false
        end

        if show then
            hasVisible = true
            imgui.PushID(i)

            if online then
                imgui.TextColored(COLOR_GREEN, '[ON]')
            else
                imgui.TextColored(COLOR_GRAY, '[OFF]')
            end
            imgui.SameLine()

            if friend.marked then
                imgui.TextColored(COLOR_YELLOW, '*')
                imgui.SameLine()
            end

            textSafe(friend.nickname)

            if friend.note and friend.note ~= '' then
                imgui.SameLine()
                textColoredSafe(COLOR_GRAY, '- ' .. utf8Trim(friend.note, 25))
            end

            local curX = imgui.GetCursorPosX()
            local winW = imgui.GetWindowWidth()
            local btnOffset = winW - 200
            if btnOffset > curX then
                imgui.SameLine(btnOffset)
            else
                imgui.SameLine()
            end

            if imgui.SmallButton(ui('Пометить')) then
                toggleMark(friend.nickname)
            end
            imgui.SameLine()
            if imgui.SmallButton(ui('Заметка')) then
                editNoteTarget = friend.nickname
                setBuf(editNoteBuf, friend.note)
            end
            imgui.SameLine()
            if imgui.SmallButton(ui('Удалить')) then
                friendToRemoveNick = friend.nickname
            end

            imgui.PopID()
            imgui.Separator()
        end
    end

    if not hasVisible then
        imgui.TextColored(COLOR_GRAY, ui('Список пуст'))
    end

    imgui.EndChild()

    if friendToRemoveNick then
        if editNoteTarget == friendToRemoveNick then
            editNoteTarget = ''
            clearBuf(editNoteBuf)
        end
        removeFriendEntry(friendToRemoveNick)
        friendToRemoveNick = nil
    end

    renderNoteEditor()
end

local function renderAddTab()
    imgui.TextColored(COLOR_CYAN, ui('Добавить по нику:'))
    imgui.Spacing()

    imgui.Text(ui('Никнейм:'))
    imgui.SameLine(90)
    imgui.PushItemWidth(-1)
    imgui.InputText('##addnick', addNickBuf, ffi.sizeof(addNickBuf))
    imgui.PopItemWidth()

    imgui.Text(ui('Заметка:'))
    imgui.SameLine(90)
    imgui.PushItemWidth(-1)
    imgui.InputText('##addnote', addNoteBuf, ffi.sizeof(addNoteBuf))
    imgui.PopItemWidth()

    imgui.Spacing()
    if imgui.Button(ui('Добавить'), imgui.ImVec2(200, 28)) then
        local nick = ffi.string(addNickBuf)
        if nick ~= '' then
            local note = ffi.string(addNoteBuf)
            if addFriendEntry(nick, note) then
                setAddStatus(ui('Добавлен: ') .. nick, COLOR_GREEN)
                clearBuf(addNickBuf)
                clearBuf(addNoteBuf)
            else
                setAddStatus(ui('Уже в списке: ') .. nick, COLOR_RED)
            end
        else
            setAddStatus(ui('Введите никнейм!'), COLOR_RED)
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(COLOR_CYAN, ui('Добавить по ID игрока:'))
    imgui.Spacing()

    imgui.Text('ID:')
    imgui.SameLine(90)
    imgui.PushItemWidth(100)
    imgui.InputText('##addid', addIdBuf, ffi.sizeof(addIdBuf))
    imgui.PopItemWidth()

    imgui.Spacing()
    if imgui.Button(ui('Добавить по ID'), imgui.ImVec2(200, 28)) then
        local id = tonumber(ffi.string(addIdBuf))
        if id and id >= 0 and id <= 1003 and sampIsPlayerConnected(id) then
            local nick = sampGetPlayerNickname(id)
            if nick and nick ~= '' then
                local note = ffi.string(addNoteBuf)
                if addFriendEntry(nick, note) then
                    setAddStatus(ui('Добавлен: ') .. nick .. ' (ID: ' .. id .. ')', COLOR_GREEN)
                    clearBuf(addIdBuf)
                    clearBuf(addNoteBuf)
                else
                    setAddStatus(ui('Уже в списке: ') .. nick, COLOR_RED)
                end
            else
                setAddStatus(ui('Не удалось получить ник игрока'), COLOR_RED)
            end
        else
            setAddStatus(ui('Игрок не подключён или неверный ID'), COLOR_RED)
        end
    end

    imgui.Spacing()
    if addStatusText ~= '' then
        if os.clock() - addStatusTime > 3.0 then
            addStatusText = ''
        else
            textColoredSafe(addStatusColor, addStatusText)
        end
    end
end

local function renderOnlineTab()
    local onlineList = {}
    for _, fr in ipairs(config.friends) do
        if isFriendOnline(fr.nickname) then
            local d = onlineFriends[fr.nickname]
            onlineList[#onlineList + 1] = {
                nickname = fr.nickname,
                id = d.id,
                score = d.score,
                ping = d.ping
            }
        end
    end

    imgui.TextColored(COLOR_CYAN, ui('Друзей онлайн: ') .. tostring(#onlineList))
    imgui.Spacing()

    imgui.Columns(4, '##online_cols', true)
    imgui.SetColumnWidth(0, 200)
    imgui.SetColumnWidth(1, 60)
    imgui.SetColumnWidth(2, 80)
    imgui.SetColumnWidth(3, 80)

    imgui.TextColored(COLOR_CYAN, ui('Ник'))
    imgui.NextColumn()
    imgui.TextColored(COLOR_CYAN, 'ID')
    imgui.NextColumn()
    imgui.TextColored(COLOR_CYAN, ui('Уровень'))
    imgui.NextColumn()
    imgui.TextColored(COLOR_CYAN, ui('Пинг'))
    imgui.NextColumn()
    imgui.Separator()

    for _, p in ipairs(onlineList) do
        textSafe(p.nickname)
        imgui.NextColumn()
        imgui.Text(tostring(p.id))
        imgui.NextColumn()
        imgui.Text(tostring(p.score))
        imgui.NextColumn()
        imgui.Text(tostring(p.ping))
        imgui.NextColumn()
    end

    imgui.Columns(1)

    if #onlineList == 0 then
        imgui.Spacing()
        imgui.TextColored(COLOR_GRAY, ui('Нет друзей онлайн'))
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    if imgui.Button(ui('Показать в чате'), imgui.ImVec2(200, 28)) then
        showOnlineInChat()
    end
end

local function renderSettingsTab()
    imgui.TextColored(COLOR_CYAN, ui('Режим работы:'))
    imgui.Spacing()

    local changed = false

    if imgui.RadioButton(ui('Режим 1: Уведомления в чат'), settingsMode[0] == 0) then
        settingsMode[0] = 0
        changed = true
    end
    imgui.SameLine()
    imgui.TextColored(COLOR_GRAY, ui('(авто-уведомления)'))

    if imgui.RadioButton(ui('Режим 2: Только по команде'), settingsMode[0] == 1) then
        settingsMode[0] = 1
        changed = true
    end
    imgui.SameLine()
    imgui.TextColored(COLOR_GRAY, ui('(без авто)'))

    if imgui.RadioButton(ui('Режим 3: Всё вместе'), settingsMode[0] == 2) then
        settingsMode[0] = 2
        changed = true
    end
    imgui.SameLine()
    imgui.TextColored(COLOR_GRAY, ui('(рекомендуется)'))

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(COLOR_CYAN, ui('Уведомления:'))
    imgui.Spacing()

    if imgui.Checkbox(ui('Уведомлять о входе друга'), notifyJoinChk) then changed = true end
    if imgui.Checkbox(ui('Уведомлять о выходе друга'), notifyLeaveChk) then changed = true end
    if imgui.Checkbox(ui('Показывать уровень игрока'), showLevelChk) then changed = true end

    if changed then saveConfig() end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(COLOR_CYAN, ui('Команды:'))
    imgui.Spacing()

    imgui.Columns(2, '##help_cols', false)
    imgui.SetColumnWidth(0, 220)

    local rows = {
        { '/fc, /friends',         ui('открыть/закрыть меню') },
        { '/fc add <nick> [note]', ui('добавить друга') },
        { '/fc del <nick>',        ui('удалить друга') },
        { '/fc mark <nick>',       ui('пометить/снять') },
        { '/fc online',            ui('друзья онлайн') },
        { '/fc list',              ui('весь список') },
        { '/fc help',              ui('справка') },
    }
    for _, row in ipairs(rows) do
        imgui.TextColored(COLOR_WHITE, row[1])
        imgui.NextColumn()
        imgui.TextColored(COLOR_GRAY, row[2])
        imgui.NextColumn()
    end

    imgui.Columns(1)
end

-- Ссылки на объекты mimgui держим в переменных (как в примерах mimgui),
-- чтобы сборщик мусора не убрал кадр вместе с окном.
local initHandler = imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil

    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.ChildRounding = 6.0
    style.FrameRounding = 4.0
    style.PopupRounding = 6.0
    style.ScrollbarRounding = 4.0
    style.GrabRounding = 4.0
    style.TabRounding = 4.0
    style.WindowPadding = imgui.ImVec2(10, 10)
    style.FramePadding = imgui.ImVec2(6, 4)
    style.ItemSpacing = imgui.ImVec2(8, 6)
    style.ItemInnerSpacing = imgui.ImVec2(6, 4)
    style.ScrollbarSize = 12.0

    local c = imgui.Col
    local v = imgui.ImVec4
    local cl = style.Colors

    cl[c.Text]                   = v(0.92, 0.92, 0.95, 1.00)
    cl[c.TextDisabled]           = v(0.50, 0.50, 0.55, 1.00)
    cl[c.WindowBg]               = v(0.08, 0.08, 0.10, 0.96)
    cl[c.ChildBg]                = v(0.10, 0.10, 0.13, 1.00)
    cl[c.PopupBg]                = v(0.10, 0.10, 0.13, 0.96)
    cl[c.Border]                 = v(0.22, 0.22, 0.28, 0.50)
    cl[c.BorderShadow]           = v(0.00, 0.00, 0.00, 0.00)
    cl[c.FrameBg]                = v(0.14, 0.14, 0.18, 1.00)
    cl[c.FrameBgHovered]         = v(0.22, 0.22, 0.28, 1.00)
    cl[c.FrameBgActive]          = v(0.28, 0.28, 0.36, 1.00)
    cl[c.TitleBg]                = v(0.06, 0.06, 0.08, 1.00)
    cl[c.TitleBgActive]          = v(0.10, 0.10, 0.14, 1.00)
    cl[c.TitleBgCollapsed]       = v(0.06, 0.06, 0.08, 0.60)
    cl[c.MenuBarBg]              = v(0.12, 0.12, 0.14, 1.00)
    cl[c.ScrollbarBg]            = v(0.08, 0.08, 0.10, 1.00)
    cl[c.ScrollbarGrab]          = v(0.24, 0.24, 0.30, 1.00)
    cl[c.ScrollbarGrabHovered]   = v(0.30, 0.30, 0.38, 1.00)
    cl[c.ScrollbarGrabActive]    = v(0.36, 0.36, 0.46, 1.00)
    cl[c.CheckMark]              = v(0.26, 0.72, 0.96, 1.00)
    cl[c.SliderGrab]             = v(0.26, 0.72, 0.96, 1.00)
    cl[c.SliderGrabActive]       = v(0.36, 0.82, 1.00, 1.00)
    cl[c.Button]                 = v(0.18, 0.18, 0.24, 1.00)
    cl[c.ButtonHovered]          = v(0.26, 0.52, 0.76, 0.70)
    cl[c.ButtonActive]           = v(0.26, 0.72, 0.96, 0.80)
    cl[c.Header]                 = v(0.18, 0.18, 0.24, 1.00)
    cl[c.HeaderHovered]          = v(0.26, 0.52, 0.76, 0.50)
    cl[c.HeaderActive]           = v(0.26, 0.72, 0.96, 0.60)
    cl[c.Separator]              = v(0.22, 0.22, 0.28, 0.50)
    cl[c.SeparatorHovered]       = v(0.26, 0.72, 0.96, 0.50)
    cl[c.SeparatorActive]        = v(0.26, 0.72, 0.96, 0.80)
    cl[c.ResizeGrip]             = v(0.26, 0.72, 0.96, 0.20)
    cl[c.ResizeGripHovered]      = v(0.26, 0.72, 0.96, 0.50)
    cl[c.ResizeGripActive]       = v(0.26, 0.72, 0.96, 0.80)
    cl[c.Tab]                    = v(0.14, 0.14, 0.18, 1.00)
    cl[c.TabHovered]             = v(0.26, 0.52, 0.76, 0.60)
    cl[c.TabActive]              = v(0.20, 0.40, 0.60, 1.00)
    cl[c.TextSelectedBg]         = v(0.26, 0.72, 0.96, 0.30)
end)

-- Содержимое окна: ошибка внутри вкладки не должна ронять скрипт, но
-- Begin/End и Tab-стек обязаны закрыться в любом случае.
local function drawWindowContents()
    if imgui.BeginTabBar('##fc_tabs') then
        if imgui.BeginTabItem(ui('Друзья') .. '##tab1') then
            safeCall('tab:friends', renderFriendsTab)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem(ui('Добавить') .. '##tab2') then
            safeCall('tab:add', renderAddTab)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem(ui('Онлайн') .. '##tab3') then
            safeCall('tab:online', renderOnlineTab)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem(ui('Настройки') .. '##tab4') then
            safeCall('tab:settings', renderSettingsTab)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

local mainFrame = imgui.OnFrame(
    function() return mainWindow[0] end,
    function(player)
        player.HideCursor = false

        local sx, sy = getScreenResolution()
        imgui.SetNextWindowPos(
            imgui.ImVec2(sx / 2 - 290, sy / 2 - 225),
            imgui.Cond.FirstUseEver
        )
        imgui.SetNextWindowSize(
            imgui.ImVec2(580, 450),
            imgui.Cond.FirstUseEver
        )

        imgui.Begin('Friend Checker v1.1##fc_main', mainWindow)
        safeCall('frame', drawWindowContents)
        imgui.End()
    end
)

-- ========== main ==========

function main()
    while not isSampAvailable() do wait(100) end

    safeCall('loadConfig', loadConfig)

    if sampIsChatCommandDefined and sampIsChatCommandDefined('fc') then
        chatMsg(CHAT_PREFIX .. '{FF6347}'
            .. tc('Команда /fc уже занята другим скриптом.'), 0x00BFFF)
    end
    sampRegisterChatCommand('fc', cmdHandler)
    sampRegisterChatCommand('friends', cmdFriends)

    chatMsg(CHAT_PREFIX .. '{FFFFFF}Friend Checker v1.1 '
        .. tc('загружен.') .. ' /fc - ' .. tc('меню'), 0x00BFFF)

    while true do
        wait(3000)

        local paused = false
        if isGamePaused then paused = isGamePaused() end

        -- 3 = CONNECTED; при реконнекте счётчик "первого скана" сбрасываем,
        -- иначе после возврата на сервер посыплются ложные "зашёл/вышел".
        local connected = true
        if sampGetGamestate then
            local ok, gs = pcall(sampGetGamestate)
            if ok and type(gs) == 'number' then connected = (gs == 3) end
        end

        if not connected then
            onlineFriends = {}
            prevOnlineSet = {}
            firstScan = true
        elseif not paused then
            safeCall('scanPlayers', scanPlayers)
        end
    end
end
