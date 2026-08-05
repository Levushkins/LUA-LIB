--[[
    ARZ AutoReconnect - автоматический реконнект после рестарта сервера (Arizona RP)

    Зачем: рестарт на Arizona RP в 5:05 по МСК (в Удмуртии, МСК+1, это 6:05 по местному).
    Тебя выкидывает с сервера, сервер поднимается не сразу. Скрипт ловит вылет,
    ждёт 10 минут и сам заходит обратно, пока ты спишь.

    Куда класть: moonloader\arz_autoreconnect.lua
    Требуется: MoonLoader + SAMPFUNCS.
    Настройки создадутся сами: moonloader\config\arz_autoreconnect.ini

    Команды в чате:
        /arc                - статус
        /arc on | off       - вкл/выкл автореконнект
        /arc time 10        - задержка перед заходом, в минутах
        /arc window on|off  - работать только в окно рестарта (по времени)
        /arc window 05:55 07:30 - границы окна (локальное время ПК)
        /arc pass 12345     - пароль для автовхода (пишется в ini открытым текстом!)
        /arc login on|off   - автоввод пароля в окно авторизации
        /arc test           - проверить прямо сейчас (отключит и зайдёт обратно)
]]

script_name('ARZ AutoReconnect')
script_version('1.0.0')
script_description('Автоматический реконнект на Arizona RP после ночного рестарта сервера')

local inicfg = require 'inicfg'

-- Состояния SA-MP (SAMPFUNCS)
local GAMESTATE_NONE         = 0 -- полный дисконнект, клиент ничего не делает
local GAMESTATE_WAIT_CONNECT = 1 -- команда "подключиться к последнему серверу"
local GAMESTATE_CONNECTED    = 3 -- мы в игре

local DIALOG_STYLE_PASSWORD  = 3 -- окно с полем для пароля (авторизация)

local CFG_NAME = 'arz_autoreconnect'
local default = {
    main = {
        enabled      = true,    -- работает ли автореконнект
        delay_min    = 10,      -- сколько ждать после кика, минут
        retry_sec    = 45,      -- сколько ждать результата одной попытки входа
        max_tries    = 40,      -- сколько попыток сделать, если сервер ещё лежит
        window_only  = false,   -- true = реагировать только в окно рестарта
        window_start = '05:55', -- локальное время (МСК+1)
        window_end   = '07:30',
        direct_connect = true,  -- коннект по сохранённому IP:port, а не только через gamestate
        autologin    = false,   -- автоввод пароля в окно авторизации
        password     = '',
        spawn_dialogs = '',     -- ID диалогов, где надо просто нажать 1-ю кнопку: "123,456"
        notify       = true,    -- писать в чат
    }
}

local cfg = inicfg.load(default, CFG_NAME)
-- добиваем недостающие ключи, если ini остался от старой версии
for k, v in pairs(default.main) do
    if cfg.main[k] == nil then cfg.main[k] = v end
end
inicfg.save(cfg, CFG_NAME)
local s = cfg.main

local server = { ip = nil, port = nil } -- последний сервер, на котором мы были
local busy = false                      -- идёт процедура реконнекта
local everConnected = false             -- были ли мы вообще в игре (чтобы не срабатывать в главном меню)

-- ============================ утилиты ============================

local function saveCfg()
    inicfg.save(cfg, CFG_NAME)
end

local function log(text, toChat)
    print(text)
    if toChat and s.notify and isSampAvailable() then
        sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} ' .. text, -1)
    end
end

local function parseTime(str)
    local h, m = tostring(str):match('^%s*(%d+):(%d+)%s*$')
    if not h then return nil end
    return tonumber(h) * 60 + tonumber(m)
end

local function inWindow()
    if not s.window_only then return true end
    local from, to = parseTime(s.window_start), parseTime(s.window_end)
    if not from or not to then return true end
    local t = os.date('*t')
    local cur = t.hour * 60 + t.min
    if from <= to then
        return cur >= from and cur <= to
    end
    return cur >= from or cur <= to -- окно через полночь
end

local function isConnected()
    return sampGetGamestate() == GAMESTATE_CONNECTED
end

-- запоминаем адрес сервера, пока мы на нём: после вылета его уже не узнать
local function cacheServer()
    if not isConnected() then return end
    local ip, port = sampGetCurrentServerAddress()
    if ip and ip ~= '' and ip ~= '0.0.0.0' then
        server.ip, server.port = ip, port
    end
end

local function fmtTime(sec)
    return string.format('%d:%02d', math.floor(sec / 60), sec % 60)
end

-- ============================ реконнект ============================

local function tryConnect()
    if s.direct_connect and server.ip then
        sampConnectToServer(server.ip, server.port)
    else
        sampSetGamestate(GAMESTATE_WAIT_CONNECT)
    end
end

-- ждём подключения не дольше timeout секунд
local function waitForConnect(timeout)
    local waited = 0
    while waited < timeout do
        wait(1000)
        waited = waited + 1
        if isConnected() then return true end
    end
    return false
end

local function reconnectRoutine(reason)
    busy = true
    log(reason .. ' Захожу обратно через ' .. s.delay_min .. ' мин.', false)

    -- гасим собственные попытки клиента переподключиться: сервер ещё лежит,
    -- долбиться в него каждые пару секунд смысла нет
    sampSetGamestate(GAMESTATE_NONE)

    local left = math.max(0, math.floor(tonumber(s.delay_min) * 60))
    while left > 0 do
        wait(1000)
        left = left - 1
        if isConnected() then -- зашли руками, дальше сами
            busy = false
            return
        end
        if left > 0 and left % 60 == 0 then
            log('До реконнекта ' .. fmtTime(left), false)
        end
    end

    for try = 1, s.max_tries do
        log('Попытка входа #' .. try .. (server.ip and (' -> ' .. server.ip .. ':' .. tostring(server.port)) or ''), false)
        tryConnect()
        if waitForConnect(tonumber(s.retry_sec)) then
            log('Подключились к серверу.', true)
            busy = false
            return
        end
        sampSetGamestate(GAMESTATE_NONE) -- сброс перед следующей попыткой
        wait(2000)
    end

    log('Не удалось подключиться за ' .. s.max_tries .. ' попыток. Жду ручного захода.', false)
    everConnected = false -- чтобы цикл не начался заново сам по себе
    busy = false
end

-- ============================ автовход ============================

local spawnIds = {}
local function reloadSpawnIds()
    spawnIds = {}
    for id in tostring(s.spawn_dialogs):gmatch('%d+') do
        spawnIds[tonumber(id)] = true
    end
end

local function autologinThread()
    while true do
        wait(300)
        if s.autologin and isConnected() and sampIsDialogActive() then
            local id = sampGetCurrentDialogId()
            if sampGetCurrentDialogType() == DIALOG_STYLE_PASSWORD and s.password ~= '' then
                sampSetCurrentDialogEditboxText(tostring(s.password))
                sampCloseCurrentDialogWithButton(1)
                log('Ввёл пароль в окно авторизации.', false)
                wait(1500)
            elseif spawnIds[id] then
                sampCloseCurrentDialogWithButton(1)
                log('Нажал кнопку в диалоге ' .. id .. '.', false)
                wait(1500)
            end
        end
    end
end

-- ============================ команды ============================

local function status()
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} автореконнект: ' ..
        (s.enabled and '{7CFC00}вкл' or '{FF4500}выкл'), -1)
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} задержка: {FFFFFF}' .. s.delay_min ..
        ' мин, попыток: ' .. s.max_tries .. ' по ' .. s.retry_sec .. ' сек', -1)
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} окно рестарта: ' ..
        (s.window_only and ('{7CFC00}' .. s.window_start .. '-' .. s.window_end) or '{FFFFFF}круглосуточно'), -1)
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} автовход паролем: ' ..
        (s.autologin and (s.password ~= '' and '{7CFC00}вкл' or '{FF4500}вкл, но пароль не задан') or '{FF4500}выкл'), -1)
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} сервер: {FFFFFF}' ..
        (server.ip and (server.ip .. ':' .. tostring(server.port)) or 'ещё не определён'), -1)
    sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} /arc on|off, time, window, pass, login, test', -1)
end

local function onCommand(param)
    local cmd, arg1, arg2 = param:match('^%s*(%S*)%s*(%S*)%s*(%S*)')
    cmd = cmd:lower()

    if cmd == '' then
        status()
    elseif cmd == 'on' or cmd == 'off' then
        s.enabled = (cmd == 'on')
        saveCfg()
        sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} автореконнект ' ..
            (s.enabled and '{7CFC00}включён' or '{FF4500}выключен'), -1)
    elseif cmd == 'time' then
        local n = tonumber(arg1)
        if not n or n < 0 then
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} использование: /arc time 10', -1)
        else
            s.delay_min = n
            saveCfg()
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} задержка перед входом: ' .. n .. ' мин', -1)
        end
    elseif cmd == 'window' then
        if arg1 == 'on' or arg1 == 'off' then
            s.window_only = (arg1 == 'on')
            saveCfg()
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} режим окна рестарта: ' ..
                (s.window_only and 'вкл (' .. s.window_start .. '-' .. s.window_end .. ')' or 'выкл'), -1)
        elseif parseTime(arg1) and parseTime(arg2) then
            s.window_start, s.window_end, s.window_only = arg1, arg2, true
            saveCfg()
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} окно рестарта: ' .. arg1 .. '-' .. arg2, -1)
        else
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} /arc window on|off  или  /arc window 05:55 07:30', -1)
        end
    elseif cmd == 'pass' then
        local pass = param:match('^%s*%S+%s+(.+)$')
        if not pass then
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} использование: /arc pass твой_пароль', -1)
        else
            s.password = pass
            saveCfg()
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} пароль сохранён в config\\' .. CFG_NAME ..
                '.ini {FF4500}открытым текстом', -1)
        end
    elseif cmd == 'login' then
        if arg1 == 'on' or arg1 == 'off' then
            s.autologin = (arg1 == 'on')
            saveCfg()
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} автовход паролем: ' ..
                (s.autologin and 'вкл' or 'выкл'), -1)
        else
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} использование: /arc login on|off', -1)
        end
    elseif cmd == 'test' then
        if busy then
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} процедура уже идёт', -1)
        else
            sampAddChatMessage('{FFA500}[AutoReconnect]{FFFFFF} тест: отключаюсь и захожу обратно через ' ..
                s.delay_min .. ' мин', -1)
            cacheServer()
            busy = true
            lua_thread.create(function()
                wait(500)
                reconnectRoutine('Тестовый реконнект.')
            end)
        end
    else
        status()
    end
end

-- ============================ main ============================

function main()
    if not isSampfuncsLoaded() or not isSampLoaded() then
        print('Нужен SAMPFUNCS. Скрипт выгружен.')
        return
    end
    while not isSampAvailable() do wait(500) end

    reloadSpawnIds()
    sampRegisterChatCommand('arc', onCommand)
    lua_thread.create(autologinThread)

    log('Загружен. Реконнект через ' .. s.delay_min .. ' мин после вылета. /arc - настройки', true)

    while true do
        wait(1000)

        if isConnected() then
            everConnected = true
            cacheServer()
        elseif s.enabled and everConnected and not busy and inWindow() then
            -- нас выкинуло: рестарт, таймаут, обрыв связи
            reconnectRoutine('Отключило от сервера.')
        end
    end
end

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() and not quitGame then
        saveCfg()
    end
end
