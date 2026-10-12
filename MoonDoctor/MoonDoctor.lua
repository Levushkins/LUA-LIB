script_name('MoonDoctor')
script_author('Levushkins')
script_version('1.0')
script_version_number(10)
script_url('https://github.com/Levushkins/LUA-LIB')
script_description('Explains script crashes, finds conflicts and measures FPS impact')

local ffi = require 'ffi'
local bit = require 'bit'
local vkeys = require 'vkeys'
local memory = require 'memory'

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local imgui
do
    local ok, lib = pcall(require, 'mimgui')
    if ok then imgui = lib end
end

local VERSION = '1.0'
local ML_DIR = getWorkingDirectory()
local CFG_DIR = ML_DIR .. '\\config\\MoonDoctor'
local REPORTS_DIR = CFG_DIR .. '\\reports'
local SETTINGS_FILE = CFG_DIR .. '\\settings.json'
local CRASHES_FILE = CFG_DIR .. '\\crashes.json'
local FPS_FILE = CFG_DIR .. '\\fps.json'

local MSG_ERROR = 3
local MAX_CRASHES = 60
local CHAT_COLOR = 0x2EC4A0

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

local function round(v)
    return math.floor(v + 0.5)
end

local function plural(n, one, few, many)
    n = math.abs(n) % 100
    local last = n % 10
    if n > 10 and n < 20 then return many end
    if last == 1 then return one end
    if last >= 2 and last <= 4 then return few end
    return many
end

local function isUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4
        else return false end
        for j = i + 1, i + len - 1 do
            local cc = s:byte(j)
            if not cc or cc < 0x80 or cc > 0xBF then return false end
        end
        i = i + len
    end
    return true
end

local function toU8(s)
    if s == nil then return '' end
    s = tostring(s)
    if not s:find('[\128-\255]') or isUtf8(s) then return s end
    local ok, res = pcall(u8, s)
    return ok and res or s
end

local function fromU8(s)
    if s == nil then return '' end
    local ok, res = pcall(u8.decode, u8, s)
    return ok and res or s
end

local function utf8Chars(s)
    local list = {}
    for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        list[#list + 1] = ch
    end
    return list
end

local function cutText(s, maxChars)
    local chars = utf8Chars(s)
    if #chars <= maxChars then return s end
    return table.concat(chars, '', 1, maxChars) .. '...'
end

local function capitalize(s)
    local b1, b2 = s:byte(1, 2)
    if not b1 then return s end
    if b1 < 0x80 then return s:sub(1, 1):upper() .. s:sub(2) end
    if b1 == 0xD0 and b2 and b2 >= 0xB0 then return string.char(0xD0, b2 - 0x20) .. s:sub(3) end
    if b1 == 0xD1 and b2 and b2 >= 0x80 and b2 <= 0x8F then return string.char(0xD0, b2 + 0x20) .. s:sub(3) end
    if b1 == 0xD1 and b2 == 0x91 then return string.char(0xD0, 0x81) .. s:sub(3) end
    return s
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function firstLine(s)
    return (s or ''):match('^[^\n]*') or ''
end

local function fileName(path)
    return path:match('([^\\/]+)$') or path
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function ensureDir(path)
    if not doesDirectoryExist(path) then createDirectory(path) end
end

local function loadJson(path)
    local data = readFile(path)
    if not data or data == '' then return nil end
    local ok, res = pcall(decodeJson, data)
    if ok and type(res) == 'table' then return res end
    os.remove(path .. '.broken')
    os.rename(path, path .. '.broken')
    return nil
end

local function saveJson(path, tbl)
    ensureDir(ML_DIR .. '\\config')
    ensureDir(CFG_DIR)
    local ok, data = pcall(encodeJson, tbl)
    if ok and data then writeFile(path, data) end
end

local function whenText(t)
    if not t then return '' end
    local d, today = os.date('*t', t), os.date('*t')
    local hm = os.date('%H:%M', t)
    if d.year == today.year and d.yday == today.yday then return 'сегодня в ' .. hm end
    local y = os.date('*t', os.time() - 86400)
    if d.year == y.year and d.yday == y.yday then return 'вчера в ' .. hm end
    return os.date('%d.%m', t) .. ' в ' .. hm
end

local settings = {
    chat = true,
    toast = true,
    autoOpen = false,
    hotkey = 0,
    scanOnStart = true,
    measureSec = 2,
}

local function loadSettings()
    local saved = loadJson(SETTINGS_FILE)
    if not saved then return end
    for k, v in pairs(settings) do
        if type(saved[k]) == type(v) then settings[k] = saved[k] end
    end
    settings.measureSec = clamp(math.floor(settings.measureSec), 1, 5)
end

local function saveSettings()
    saveJson(SETTINGS_FILE, settings)
end

local SAMP_VERSIONS = {
    [0x31DF13] = '0.3.7-R1',
    [0x3195DD] = '0.3.7-R2',
    [0xCC4D0] = '0.3.7-R3',
    [0xCBCB0] = '0.3.7-R4',
    [0xCBC90] = '0.3.7-R4-2',
    [0xFDB60] = '0.3.DL-R1',
}

local env = {}

local function sfLoaded()
    local ok, res = pcall(isSampfuncsLoaded)
    return ok and res or false
end

local function sampReady()
    if not sfLoaded() or not isSampLoaded() then return false end
    local ok, res = pcall(isSampAvailable)
    return ok and res or false
end

local function sampVersion()
    if env.samp then return env.samp end
    if not isSampLoaded() then return nil end
    local base = getModuleHandle('samp.dll')
    if not base or base == 0 then return nil end
    local ok, entry = pcall(function()
        local pe = base + memory.getint32(base + 0x3C, true)
        return memory.getuint32(pe + 0x28, true)
    end)
    if not ok or not entry then return nil end
    env.samp = SAMP_VERSIONS[entry] or string.format('неизвестная (0x%X)', entry)
    return env.samp
end

local function mlVersion()
    if env.mlFull then return env.mlFull end
    local ok, v = pcall(getMoonloaderVersion)
    if ok and v then return string.format('v.%03d', v) end
    return '?'
end

local function mlVersionNumber()
    local ok, v = pcall(getMoonloaderVersion)
    return ok and tonumber(v) or 0
end

local function serverInfo()
    if not sampReady() then return nil end
    local ok, name = pcall(sampGetCurrentServerName)
    if not ok or not name then return nil end
    local res = toU8(name)
    local ok2, ip, port = pcall(sampGetCurrentServerAddress)
    if ok2 and ip then res = string.format('%s (%s:%s)', res, ip, tostring(port)) end
    return res
end

local function scriptField(s, key)
    if not s then return nil end
    local ok, v = pcall(function() return s[key] end)
    if ok then return v end
end

local function isSelf(s)
    if not s then return false end
    local me = thisScript()
    if s == me then return true end
    local id = scriptField(s, 'id')
    return id ~= nil and id == scriptField(me, 'id')
end

local function snapshot(s)
    if not s then return nil end
    local info = {}
    info.name = toU8(scriptField(s, 'name') or '')
    info.path = toU8(scriptField(s, 'path') or '')
    info.file = toU8(scriptField(s, 'filename') or '')
    if info.file == '' and info.path ~= '' then info.file = fileName(info.path) end
    info.version = toU8(scriptField(s, 'version') or '')
    local authors = scriptField(s, 'authors')
    if type(authors) == 'table' then
        local list = {}
        for _, a in ipairs(authors) do list[#list + 1] = toU8(a) end
        info.authors = table.concat(list, ', ')
    end
    info.url = toU8(scriptField(s, 'url') or '')
    return info
end

local runningCache = { map = {}, time = -1 }

local function getRunning(force)
    local now = localClock()
    if not force and now - runningCache.time < 1 then return runningCache.map end
    local map = {}
    local ok, list = pcall(script.list)
    if ok and type(list) == 'table' then
        for _, s in ipairs(list) do
            if not scriptField(s, 'dead') then
                local fn = scriptField(s, 'filename')
                if not fn or fn == '' then fn = fileName(scriptField(s, 'path') or '') end
                if fn ~= '' then map[toU8(fn):lower()] = s end
            end
        end
    end
    runningCache.map, runningCache.time = map, now
    return map
end

local function runningScript(file)
    if not file then return nil end
    return getRunning()[file:lower()]
end

for _, decl in ipairs({
    'int __stdcall OpenClipboard(void* hWndNewOwner);',
    'int __stdcall CloseClipboard(void);',
    'int __stdcall EmptyClipboard(void);',
    'void* __stdcall SetClipboardData(unsigned int uFormat, void* hMem);',
    'void* __stdcall GlobalAlloc(unsigned int uFlags, size_t dwBytes);',
    'void* __stdcall GlobalLock(void* hMem);',
    'int __stdcall GlobalUnlock(void* hMem);',
    'void* __stdcall GlobalFree(void* hMem);',
    'int __stdcall MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char* lpMultiByteStr, int cbMultiByte, void* lpWideCharStr, int cchWideChar);',
    'void* __stdcall ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);',
}) do
    pcall(ffi.cdef, decl)
end

local function copyText(textU8)
    local C = ffi.C
    local mem
    local ok = pcall(function()
        local len = C.MultiByteToWideChar(65001, 0, textU8, #textU8, nil, 0)
        mem = C.GlobalAlloc(0x0002, (len + 1) * 2)
        if mem == nil then error('GlobalAlloc') end
        local buf = C.GlobalLock(mem)
        C.MultiByteToWideChar(65001, 0, textU8, #textU8, buf, len)
        ffi.cast('uint16_t*', buf)[len] = 0
        C.GlobalUnlock(mem)
        if C.OpenClipboard(nil) == 0 then error('clipboard busy') end
        C.EmptyClipboard()
        if C.SetClipboardData(13, mem) ~= nil then mem = nil end
        C.CloseClipboard()
        if mem ~= nil then error('SetClipboardData') end
    end)
    if mem ~= nil then pcall(C.GlobalFree, mem) end
    if not ok then setClipboardText(fromU8(textU8)) end
end

local shell32
local function shellOpen(target, params)
    return pcall(function()
        shell32 = shell32 or ffi.load('shell32')
        shell32.ShellExecuteA(nil, 'open', target, params, nil, 1)
    end)
end

local crashes = {}
local crashById = {}
local nextCrashId = 1
local crashesDirty = false
local sessionStart = os.time()

local function isLibPath(path)
    return path:lower():find('[\\/]lib[\\/]') ~= nil or path:lower():find('^lib[\\/]') ~= nil
end

local function findLocations(text)
    local list = {}
    for pos, path, line in text:gmatch('()([^\n\t:<>"]-%.luac?):(%d+):') do
        if pos > 2 and text:sub(pos - 2, pos - 1):match('^%a:$') then
            path = text:sub(pos - 2, pos - 1) .. path
        end
        path = trim(path)
        list[#list + 1] = { path = path, file = fileName(path), line = tonumber(line) }
    end
    return list
end

local function splitError(text)
    local head, tb = text:match('^(.-)\nstack traceback:\n(.*)$')
    if not head then head = text end
    local msg = head
    while true do
        local rest = msg:match('^[^\n]-%.luac?:%d+: (.*)$')
        if not rest then break end
        msg = rest
    end
    return msg, tb
end

local function crashSignature(file, line, msg)
    local core = firstLine(msg):gsub('0x%x+', '0x?'):gsub('%(%x%x%x%x%x%x%x%x%)', '')
    return (file or '?'):lower() .. '|' .. tostring(line or 0) .. '|' .. core
end

local MAX_RAW = 16000

local function buildCrash(rawText, info)
    local text = toU8(rawText):gsub('\r', '')
    text = trim(text)
    if #text > MAX_RAW then text = cutText(text, MAX_RAW) end
    local msg, tb = splitError(text)
    local locs = findLocations(text)
    local myFile = info and info.file ~= '' and info.file:lower() or nil

    local main, lib
    for _, l in ipairs(locs) do
        if isLibPath(l.path) then
            lib = lib or l
        elseif not main and (not myFile or l.file:lower() == myFile) then
            main = l
        end
    end
    if not main then
        for _, l in ipairs(locs) do
            if not isLibPath(l.path) then main = l break end
        end
    end

    local c = {
        file = (info and info.file ~= '' and info.file) or (main and main.file) or (info and info.name ~= '' and info.name) or 'неизвестный скрипт',
        name = info and info.name or '',
        version = info and info.version or '',
        authors = info and info.authors or nil,
        url = info and info.url or '',
        line = main and main.line or nil,
        message = msg,
        raw = text,
        traceback = tb,
        first = os.time(),
        last = os.time(),
        count = 1,
        unread = true,
        session = sessionStart,
    }
    if main and main.file:lower() ~= c.file:lower() then c.where = main.file end
    if lib then
        c.libFile, c.libLine, c.libPath = lib.file, lib.line, lib.path
    end

    local path
    if info and info.path ~= '' and fileName(info.path):lower() == c.file:lower() then path = info.path end
    if not path and main and main.path:find('^%a:') then path = main.path end
    if not path then
        local guess = toU8(ML_DIR) .. '\\' .. c.file
        if doesFileExist(fromU8(guess)) then path = guess end
    end
    if c.where and main and main.path:find('^%a:') then path = main.path end
    c.path = path or ''

    c.sig = crashSignature(c.file, c.line, msg)
    return c
end

local function findCrash(sig)
    for i, c in ipairs(crashes) do
        if c.sig == sig then return c, i end
    end
end

local explainCache = setmetatable({}, { __mode = 'k' })
local sourceCache = {}

local function addCrash(c, fromLog)
    local old, idx = findCrash(c.sig)
    if old then
        if fromLog and c.last <= (old.last or 0) + 2 then return old, false end
        old.count = (old.count or 1) + 1
        old.last = c.last
        old.raw, old.traceback, old.message = c.raw, c.traceback, c.message
        if c.libFile then old.libFile, old.libLine, old.libPath = c.libFile, c.libLine, c.libPath end
        if c.version ~= '' then old.version = c.version end
        old.unread = true
        old.session = sessionStart
        table.remove(crashes, idx)
        table.insert(crashes, 1, old)
        explainCache[old] = nil
        sourceCache[old.path] = nil
        crashesDirty = true
        return old, true
    end
    c.id = nextCrashId
    nextCrashId = nextCrashId + 1
    table.insert(crashes, 1, c)
    crashById[c.id] = c
    while #crashes > MAX_CRASHES do
        local gone = table.remove(crashes)
        crashById[gone.id] = nil
    end
    sourceCache[c.path] = nil
    crashesDirty = true
    return c, true
end

local function removeCrash(c)
    for i, x in ipairs(crashes) do
        if x == c then table.remove(crashes, i) break end
    end
    crashById[c.id] = nil
    crashesDirty = true
end

local SAVED_KEYS = {
    'id', 'sig', 'file', 'name', 'path', 'version', 'authors', 'url', 'line', 'where',
    'libFile', 'libLine', 'libPath', 'message', 'raw', 'traceback', 'first', 'last', 'count', 'session',
}

local function saveCrashes()
    local list = {}
    for _, c in ipairs(crashes) do
        if not c.demo then
            local t = {}
            for _, k in ipairs(SAVED_KEYS) do t[k] = c[k] end
            list[#list + 1] = t
        end
    end
    saveJson(CRASHES_FILE, { nextId = nextCrashId, list = list })
    crashesDirty = false
end

local function loadCrashes()
    local data = loadJson(CRASHES_FILE)
    if not data or type(data.list) ~= 'table' then return end
    local maxId = 0
    for _, c in ipairs(data.list) do
        if type(c) == 'table' and type(c.sig) == 'string' and type(c.file) == 'string' and tonumber(c.id) then
            c.id = tonumber(c.id)
            c.count = tonumber(c.count) or 1
            c.line = tonumber(c.line)
            c.libLine = tonumber(c.libLine)
            c.first = tonumber(c.first) or 0
            c.last = tonumber(c.last) or c.first
            c.session = tonumber(c.session) or 0
            c.message = c.message or ''
            c.raw = c.raw or c.message
            c.path = c.path or ''
            c.name = c.name or ''
            c.version = c.version or ''
            c.url = c.url or ''
            c.unread = false
            if not crashById[c.id] then
                crashes[#crashes + 1] = c
                crashById[c.id] = c
                maxId = math.max(maxId, c.id)
            end
        end
    end
    nextCrashId = math.max(nextCrashId, tonumber(data.nextId) or 1, maxId + 1)
end

local function sourceLines(path)
    if not path or path == '' then return nil end
    local cached = sourceCache[path]
    if cached ~= nil then return cached or nil end
    local data = readFile(fromU8(path))
    if not data or data:sub(1, 3) == '\27LJ' then
        sourceCache[path] = false
        return nil
    end
    local lines = {}
    for l in (data .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = (l:gsub('\r$', ''))
    end
    sourceCache[path] = lines
    return lines
end

local LIB_INFO = {
    ['mimgui'] = { 'mimgui', 'библиотека для окон и меню' },
    ['imgui'] = { 'Moon ImGui', 'старая библиотека для окон и меню' },
    ['samp.events'] = { 'SAMP.Lua', 'через неё скрипты видят диалоги, сообщения и пакеты сервера' },
    ['lib.samp.events'] = { 'SAMP.Lua', 'через неё скрипты видят диалоги, сообщения и пакеты сервера' },
    ['samp.raknet'] = { 'SAMP.Lua', 'работа с пакетами сервера' },
    ['requests'] = { 'requests (и к ней luasocket + luasec)', 'запросы в интернет' },
    ['socket'] = { 'luasocket', 'работа с сетью' },
    ['socket.http'] = { 'luasocket', 'работа с сетью' },
    ['ssl'] = { 'luasec', 'https-запросы' },
    ['ssl.https'] = { 'luasec', 'https-запросы' },
    ['effil'] = { 'effil', 'многопоточность' },
    ['lfs'] = { 'LuaFileSystem (lfs)', 'работа с файлами и папками' },
    ['fAwesome5'] = { 'fAwesome5', 'иконки для меню' },
    ['fAwesome6'] = { 'fAwesome6', 'иконки для меню' },
    ['fAwesome6_solid'] = { 'fAwesome6', 'иконки для меню' },
    ['MoonAdditions'] = { 'MoonAdditions', 'дополнительные функции для рендера и игры' },
    ['lib.MoonAdditions'] = { 'MoonAdditions', 'дополнительные функции для рендера и игры' },
    ['rkeys'] = { 'rkeys', 'горячие клавиши' },
    ['cjson'] = { 'lua-cjson', 'чтение json' },
    ['dkjson'] = { 'dkjson', 'чтение json' },
}

local STD_LIBS = {
    ['vkeys'] = true, ['inicfg'] = true, ['encoding'] = true, ['moonloader'] = true, ['memory'] = true,
    ['sampfuncs'] = true, ['game.keys'] = true, ['game.models'] = true, ['game.weapons'] = true, ['game.globals'] = true,
    ['windows.message'] = true, ['vector3d'] = true, ['matrix3x3'] = true, ['bitex'] = true,
}

local function libInfo(mod)
    local short = mod:gsub('^lib%.', '')
    return LIB_INFO[mod] or LIB_INFO[short], STD_LIBS[short] == true
end

local explain

do

local ORIGINS = {
    { 'match', { ':match%(', 'string%.match%(', ':gmatch%(', 'string%.gmatch%(', ':find%(', 'string%.find%(' } },
    { 'dialog', { 'sampGetDialog', 'sampGetCurrentDialog', 'sampGetListboxItem' } },
    { 'config', { 'decodeJson', 'json%.decode', 'cjson', 'inicfg%.load' } },
    { 'file', { 'io%.open', 'io%.lines', ':read%(' } },
    { 'stream', { 'sampGetPlayer', 'sampGetCharHandle', 'sampGetCarHandle', 'sampGetObjectHandle', 'getCharPlayerIsTargeting' } },
    { 'textdraw', { 'sampTextdraw' } },
    { 'web', { 'requests%.', 'http%.', 'downloadUrlToFile', 'asyncHttpRequest' } },
    { 'lib', { 'require', 'import%s*%(' } },
}

local function classifyOrigin(code)
    if not code then return nil end
    for _, origin in ipairs(ORIGINS) do
        for _, pat in ipairs(origin[2]) do
            if code:find(pat) then return origin[1] end
        end
    end
end

local function splitAssign(line)
    local pos = 1
    while true do
        local s = line:find('=', pos, true)
        if not s then return nil end
        local prev, nxt = line:sub(s - 1, s - 1), line:sub(s + 1, s + 1)
        if nxt == '=' then
            pos = s + 2
        elseif prev == '=' or prev == '~' or prev == '<' or prev == '>' then
            pos = s + 1
        else
            return line:sub(1, s - 1), line:sub(s + 1)
        end
    end
end

local function findOrigin(lines, lineNo, name)
    if not lines or not lineNo or not name or name == '?' then return nil end
    local word = '%f[%w_]' .. name:gsub('%p', '%%%0') .. '%f[^%w_]'
    for i = lineNo, math.max(1, lineNo - 80), -1 do
        local l = lines[i]
        if l then
            local lhs, rhs = splitAssign(l)
            if lhs and lhs:find(word) and not lhs:find('^%s*%-%-') then
                return classifyOrigin(rhs), i
            end
        end
    end
end

local TYPE_NAME = {
    ['nil'] = 'пусто (nil)', boolean = 'true/false', number = 'число', string = 'текст',
    table = 'таблица', ['function'] = 'функция', userdata = 'объект', cdata = 'FFI-объект', thread = 'поток',
}
local TYPE_ACC = {
    ['nil'] = 'пустое значение (nil)', ['no value'] = 'ничего', boolean = 'true/false', number = 'число',
    string = 'текст', table = 'таблицу', ['function'] = 'функцию', userdata = 'объект', cdata = 'FFI-объект', thread = 'поток',
}

local TYPE_INS = {
    ['nil'] = 'пустым значением (nil)', ['no value'] = 'ничем', boolean = 'true/false', number = 'числом',
    string = 'текстом', table = 'таблицей', ['function'] = 'функцией', userdata = 'объектом', cdata = 'FFI-объектом', thread = 'потоком',
}

local function typeName(t) return TYPE_NAME[t] or t end
local function typeAcc(t) return TYPE_ACC[t] or t end
local function typeIns(t) return TYPE_INS[t] or t end

local CONFIG_NAMES = { cfg = true, ini = true, config = true, settings = true, mainini = true, conf = true, sets = true, db = true }
local LIB_NAMES = { imgui = true, sampev = true, inicfg = true, encoding = true, requests = true, effil = true, lfs = true, json = true, fa = true, vkeys = true, memory = true, ffi = true, notf = true, rkeys = true, u8 = true }

local UPDATE = 'Обнови скрипт до последней версии. Такое обычно чинят быстро, возможно, уже починили.'
local REPORT = 'Не помогло? Нажми «Скопировать отчёт для автора» и отправь ему. Там строка, текст ошибки и всё про твою игру, этого хватит, чтобы найти место.'
local REPORT_ONLY = 'Скопируй отчёт и отправь автору. Это ошибка в коде самого скрипта, сам ты её не починишь.'
local CONFIG_RESET = 'Если у скрипта есть файл настроек в moonloader\\config, перенеси его, например, на рабочий стол. Обычно при запуске скрипт создаёт новый.'

local ORIGIN_WHY = {
    match = 'Значение «%s» скрипт достаёт из текста поиском по шаблону (строка %d). Если сервер поменял формат сообщения или диалога, шаблон перестаёт совпадать, поиск ничего не находит, и дальше скрипт падает. Чаще всего так бывает сразу после обновления сервера.',
    dialog = 'Значение «%s» берётся из диалога сервера (строка %d). Скорее всего, сервер поменял этот диалог, и скрипт не нашёл в нём то, что искал.',
    config = 'Значение «%s» читается из файла настроек (строка %d). Похоже, файл повреждён, пустой или остался от старой версии скрипта.',
    file = 'Значение «%s» должно было прийти из файла (строка %d). Видимо, файл не открылся: его нет или к нему нет доступа.',
    stream = 'Значение «%s» связано с игроком или машиной (строка %d). Если игрок ушёл из зоны прорисовки или вышел с сервера, данных о нём уже нет.',
    textdraw = 'Значение «%s» берётся из текстдрава (строка %d). Если сервер поменял интерфейс, нужного текстдрава может просто не быть.',
    web = 'Значение «%s» должно было прийти из интернета (строка %d). Похоже, сайт не ответил или ответил не так, как ждал скрипт.',
    lib = 'Значение «%s» это подключённая библиотека или другой скрипт (строка %d). Видимо, загрузить его не получилось.',
}

local ORIGIN_WHY_INLINE = {
    match = 'На этой строке скрипт ищет что-то в тексте по шаблону. Если сервер поменял формат сообщения или диалога, поиск возвращает пустоту, и скрипт падает. Чаще всего так бывает после обновления сервера.',
    dialog = 'На этой строке скрипт читает диалог сервера. Скорее всего, сервер поменял этот диалог.',
    config = 'На этой строке скрипт читает свои настройки. Похоже, файл повреждён или остался от старой версии.',
    stream = 'На этой строке скрипт работает с игроком или машиной. Если их уже нет в зоне прорисовки, данных нет.',
    textdraw = 'На этой строке скрипт читает текстдрав. Если сервер поменял интерфейс, его может не быть.',
    web = 'На этой строке скрипт работает с ответом из интернета. Похоже, ответ не пришёл.',
}

local GENERIC_NIL_WHY = 'Чаще всего так бывает, когда сервер после обновления поменял диалог или текст, и скрипт не нашёл там то, что ждал. Реже виноват повреждённый файл настроек или другой скрипт, который лезет в те же данные.'

local function isServerPacketLib(c)
    local p = (c.libPath or ''):lower()
    return p:find('samp[\\/]events') ~= nil or p:find('samp[\\/]raknet') ~= nil
end

explain = function(c)
    local cached = explainCache[c]
    if cached then return cached end

    local ex = { todo = {}, title = c.file .. ' упал' }
    local msg = cutText(firstLine(c.message or ''), 400)
    local low = msg:lower()
    local lines = c.demoLines or sourceLines(c.path)
    local L = c.line
    local code = lines and L and lines[L] or nil
    local samp = sampVersion() or 'неизвестна'

    local at
    if c.where and L then
        at = string.format('В файле %s на строке %d скрипт', c.where, L)
    elseif L then
        at = 'На строке ' .. L .. ' скрипт'
    elseif c.libFile then
        at = string.format('Внутри библиотеки %s скрипт', c.libFile)
    else
        at = 'Скрипт'
    end

    local function todo(s) ex.todo[#ex.todo + 1] = s end

    local packetNote = isServerPacketLib(c) and 'Упало, пока скрипт разбирал данные от сервера (через SAMP.Lua). ' or ''

    local kind, name, vtype = msg:match("attempt to index (%a+) '([^']*)' %(a (%a+) value%)")
    if not kind then vtype = msg:match('attempt to index a (%a+) value') end

    if vtype then
        ex.kind = 'index'
        if name == '?' then name = nil end
        if vtype == 'nil' then
            ex.short = 'обратился к данным, которых нет'
            if kind == 'field' and name then
                ex.what = string.format('%s обратился к полю «%s», а его нет (nil). Проще говоря, скрипт полез за данными, которых нет.', at, name)
            elseif name then
                ex.what = string.format('%s полез внутрь «%s», а там пусто (nil). Проще говоря, скрипт обратился к данным, которых нет.', at, name)
            else
                ex.what = at .. ' обратился к данным, которых нет: значение оказалось пустым (nil).'
            end

            local origin, originLine = findOrigin(lines, L, name)
            local lname = name and name:lower() or ''
            if origin and ORIGIN_WHY[origin] then
                ex.why = string.format(ORIGIN_WHY[origin], name, originLine)
                ex.originLine = originLine
            elseif not origin and classifyOrigin(code) and ORIGIN_WHY_INLINE[classifyOrigin(code)] then
                origin = classifyOrigin(code)
                ex.why = ORIGIN_WHY_INLINE[origin]
            elseif kind == 'global' and CONFIG_NAMES[lname] then
                origin = 'config'
                ex.why = string.format('«%s» похоже на настройки скрипта. Видимо, они не загрузились: файл в moonloader\\config повреждён или его нет.', name)
            elseif kind == 'global' and LIB_NAMES[lname] then
                origin = 'lib'
                ex.why = string.format('«%s» похоже на библиотеку. Видимо, она не загрузилась, поэтому вместо неё пусто.', name)
            elseif kind == 'field' and name then
                ex.why = string.format('В данных нет поля «%s». Обычно это значит, что сервер, файл настроек или другой скрипт отдали данные не в том виде, на который рассчитан скрипт.', name)
            else
                ex.why = GENERIC_NIL_WHY
            end
            ex.why = packetNote .. ex.why

            todo(UPDATE)
            if origin == 'config' then todo(CONFIG_RESET) end
            if origin == 'file' then todo('Проверь, что рядом со скриптом лежат все его файлы из архива (папки с настройками, картинками, звуками).') end
            if origin == 'stream' then todo('Если падает только рядом с определённым игроком или после его выхода, напиши об этом автору, это поможет.') end
            todo(REPORT)
            ex.dev = 'Перед использованием проверяй значение: if data then ... end. Особенно результат :match(), диалоги и всё, что приходит от сервера.'
        else
            ex.short = 'ждал таблицу, а получил ' .. typeName(vtype)
            ex.what = string.format('%s обратился к %s как к таблице, а там %s.', at, name and ('«' .. name .. '»') or 'значению', typeName(vtype))
            if vtype == 'boolean' then
                ex.why = 'Обычно так бывает, когда функция вернула false вместо результата: например, нужный игрок, машина или файл не нашлись.'
            else
                ex.why = 'Скрипт ждал одни данные, а пришли другие. Возможно, поменялся формат настроек или ответа сервера.'
            end
            ex.why = packetNote .. ex.why
            todo(UPDATE)
            todo(CONFIG_RESET)
            todo(REPORT)
            ex.dev = 'Проверь тип перед обращением: type(x) == "table".'
        end

    elseif msg:find('attempt to call') then
        ex.kind = 'call'
        ex.short = 'вызвал функцию, которой нет'
        local ckind, cname, ctype = msg:match("attempt to call (%a+) '([^']*)' %(a (%a+) value%)")
        if cname == '?' then cname = nil end
        if cname then
            ex.what = string.format('%s вызвал функцию «%s», но такой функции нет.', at, cname)
        else
            ex.what = at .. ' вызвал функцию, которой нет.'
        end
        if ctype and ctype ~= 'nil' then
            ex.what = string.format('%s попытался вызвать «%s» как функцию, а там %s.', at, cname or '?', typeName(ctype))
        end

        local isSF = cname and (cname:find('^samp%u') or cname:find('^raknet') or cname:find('^sampfuncs') or cname:find('^isSampfuncs'))
        if isSF and not sfLoaded() then
            ex.why = string.format('«%s» это функция из SAMPFUNCS, а SAMPFUNCS у тебя не загружен.', cname)
            todo(string.format('Поставь SAMPFUNCS под свою версию SA-MP (у тебя %s).', samp))
        elseif isSF then
            ex.why = string.format('«%s» похожа на функцию из SAMPFUNCS, но у тебя её нет. Либо SAMPFUNCS старее, чем нужно скрипту, либо в скрипте опечатка.', cname)
            todo(string.format('Обнови SAMPFUNCS. Бери версию под свой SA-MP (у тебя %s).', samp))
        elseif ckind == 'method' then
            ex.why = string.format('У объекта нет метода «%s». Обычно это значит, что библиотека другой версии, не той, под которую писали скрипт.', cname)
            todo('Обнови библиотеки, которые указаны в теме скрипта.')
        elseif code and code:find('imgui%.') then
            ex.why = 'Это функция из imgui. Скорее всего, у тебя стоит другая версия mimgui или imgui, не та, под которую писали скрипт.'
            todo('Скачай ту версию mimgui/imgui, которая указана в теме скрипта.')
        elseif ckind == 'global' then
            ex.why = string.format('Функции «%s» нет ни в скрипте, ни в MoonLoader. Возможно, скрипту не хватает библиотеки, или он рассчитан на MoonLoader новее твоего (%s).', cname or '?', mlVersion())
            todo('Обнови MoonLoader до последней версии.')
            todo('Проверь, что стоят все библиотеки из темы скрипта.')
        elseif ckind == 'field' then
            ex.why = string.format('Скрипт берёт «%s» из библиотеки или таблицы, а там такого нет. Обычно виновата другая версия библиотеки.', cname or '?')
            todo('Обнови библиотеки, которые указаны в теме скрипта.')
        else
            ex.why = 'Обычно так бывает, когда не хватает библиотеки или стоит её другая версия.'
            todo('Проверь, что стоят все библиотеки из темы скрипта.')
        end
        todo(UPDATE)
        todo(REPORT)
        ex.dev = 'Если функция есть только в новых версиях библиотеки, проверяй её наличие: if lib.func then ... end.'

    elseif msg:find('attempt to perform arithmetic') then
        local _, aname, atype = msg:match("arithmetic on (%a+) '([^']*)' %(a (%a+) value%)")
        atype = atype or msg:match('arithmetic on a (%a+) value')
        ex.kind = 'math'
        ex.short = 'посчитал что-то с пустым значением'
        if atype and atype ~= 'nil' then ex.short = 'хотел посчитать, а получил ' .. typeName(atype) end
        ex.what = string.format('%s пытался посчитать что-то с %s, а там %s.', at, aname and aname ~= '?' and ('«' .. aname .. '»') or 'значением', typeName(atype or 'nil'))
        if atype == 'string' then
            ex.why = 'Вместо числа пришёл текст. Например, в файле настроек вместо числа оказались буквы, или сервер прислал не то.'
        else
            ex.why = 'Число, с которым работает скрипт, не пришло: его нет в настройках или в тексте от сервера.'
        end
        ex.why = packetNote .. ex.why
        todo(UPDATE)
        todo(CONFIG_RESET)
        todo(REPORT)
        ex.dev = 'tonumber(x) or 0 спасает от пустых значений и текста.'

    elseif msg:find('attempt to concatenate') then
        local _, cname, ctype = msg:match("concatenate (%a+) '([^']*)' %(a (%a+) value%)")
        ctype = ctype or msg:match('concatenate a (%a+) value')
        ex.kind = 'concat'
        ex.short = 'склеивал текст, а одна часть пустая'
        local part = cname and cname ~= '?' and (' («' .. cname .. '»)') or ''
        ex.what = string.format('%s собирал строку из кусков, и одна из частей%s оказалась %s.', at, part, typeIns(ctype or 'nil'))
        ex.why = packetNote .. 'Обычно один из кусков должен был прийти от сервера или из настроек, но не пришёл.'
        todo(UPDATE)
        todo(REPORT)
        ex.dev = 'Оборачивай куски, которые могут быть nil, в tostring().'

    elseif msg:find('attempt to compare') then
        local a, b = msg:match('attempt to compare (%a+) with (%a+)')
        local two = msg:match('attempt to compare two (%a+) values')
        ex.kind = 'compare'
        ex.short = 'сравнивал несравнимое'
        if a then
            ex.what = string.format('%s сравнивал %s с %s, а так нельзя.', at, typeAcc(a), typeIns(b))
        else
            ex.what = string.format('%s сравнивал два значения типа «%s», а так нельзя.', at, typeName(two or '?'))
        end
        ex.why = packetNote .. 'Одно из значений пришло не того типа. Почти всегда это пустое значение (nil) вместо числа: в настройках или в данных от сервера его не оказалось.'
        todo(UPDATE)
        todo(CONFIG_RESET)
        todo(REPORT)

    elseif msg:find('attempt to get length') then
        local _, lname, ltype = msg:match("length of (%a+) '([^']*)' %(a (%a+) value%)")
        ltype = ltype or msg:match('length of a (%a+) value')
        ex.kind = 'len'
        ex.short = 'считал длину того, чего нет'
        ex.what = string.format('%s считал длину %s, а там %s.', at, lname and lname ~= '?' and ('«' .. lname .. '»') or 'списка или текста', typeName(ltype or 'nil'))
        ex.why = packetNote .. 'Список или текст, который скрипт ждал, не пришёл: от сервера, из настроек или из файла.'
        todo(UPDATE)
        todo(CONFIG_RESET)
        todo(REPORT)

    elseif msg:find("bad argument #%d+ to '") then
        local n, fn, detail = msg:match("bad argument #(%d+) to '([^']+)' %(([^)]*)%)")
        n, fn, detail = n or '?', fn or '?', detail or ''
        ex.kind = 'arg'
        ex.short = 'передал функции не то, что она ждёт'
        local exp, got = detail:match('^(.-) expected, got (.+)$')
        local detailRu = exp and string.format('она ждала %s, а получила %s', typeAcc(exp), typeAcc(got)) or detail
        ex.what = string.format('%s вызвал «%s» и передал ей не то в %s-м параметре: %s.', at, fn, n, detailRu)
        if fn == 'ipairs' or fn == 'pairs' or fn == 'next' then
            ex.short = 'хотел перебрать список, которого нет'
            ex.why = 'Скрипт хотел пройтись по списку, а списка нет. Обычно его не удалось загрузить из настроек или получить от сервера.'
            todo(CONFIG_RESET)
        elseif fn:find('^samp') then
            ex.why = 'В функцию SA-MP попало пустое или неверное значение. Часто это id игрока, которого уже нет, или текст, который не пришёл.'
        else
            ex.why = 'Чаще всего в функцию попало пустое значение: то, что скрипт ждал из настроек или от сервера, не пришло.'
        end
        ex.why = packetNote .. ex.why
        todo(UPDATE)
        todo(REPORT)
        ex.dev = 'Проверяй значения перед вызовом, особенно то, что пришло от сервера или из файла.'

    elseif msg:find("module '[^']+' not found") then
        local mod = msg:match("module '([^']+)' not found")
        local info, std = libInfo(mod)
        ex.kind = 'module'
        ex.startup = true
        ex.module = mod
        ex.short = 'не хватает библиотеки ' .. mod
        ex.title = c.file .. ' не запустился'
        ex.what = string.format('Скрипту нужна библиотека «%s», а её нет в папке moonloader\\lib.', mod)
        if std then
            ex.why = 'Это стандартная библиотека MoonLoader, она должна стоять у всех. Похоже, MoonLoader установлен не полностью или папку lib кто-то почистил.'
            todo('Переустанови MoonLoader (скрипты из папки moonloader при этом не пропадут, но на всякий случай сделай копию).')
        elseif info then
            ex.why = string.format('Это %s, %s. Без неё скрипт не запустится.', info[1], info[2])
            todo(string.format('Скачай %s и положи в moonloader\\lib. Именно в lib, а не в саму папку moonloader.', info[1]))
        else
            ex.why = 'Без неё скрипт работать не может, поэтому MoonLoader его остановил.'
            todo(string.format('Найди библиотеку «%s» и положи её в moonloader\\lib.', mod))
        end
        local short = mod:gsub('^lib%.', ''):gsub('%.', '\\')
        if doesFileExist(ML_DIR .. '\\' .. short .. '.lua') or doesDirectoryExist(ML_DIR .. '\\' .. short) then
            ex.why = ex.why .. ' Кстати, похожий файл или папка лежит прямо в moonloader. Библиотекам место в moonloader\\lib.'
        end
        todo('Ссылки на нужные библиотеки обычно есть в теме скрипта, в разделе с требованиями или зависимостями.')

    elseif msg:find("error loading module '[^']+'") then
        local mod = msg:match("error loading module '([^']+)'")
        ex.kind = 'module'
        ex.startup = true
        ex.module = mod
        ex.short = 'библиотека ' .. mod .. ' не загрузилась'
        ex.title = c.file .. ' не запустился'
        ex.what = string.format('Библиотека «%s» нашлась, но не загрузилась: внутри неё ошибка.', mod)
        ex.why = 'Файл библиотеки повреждён, недокачан, или это версия, которая не подходит к твоему MoonLoader.'
        todo(string.format('Скачай библиотеку «%s» заново и замени файлы в moonloader\\lib.', mod))
        todo(REPORT)

    elseif msg:find('loop or previous error loading module') then
        local mod = msg:match("module '([^']+)'") or '?'
        ex.kind = 'module'
        ex.short = 'библиотека ' .. mod .. ' не загрузилась раньше'
        ex.what = string.format('Библиотека «%s» не загрузилась ещё раньше, и скрипт споткнулся об это второй раз.', mod)
        ex.why = 'Это последствие другой ошибки. В списке крашей посмотри тот, что случился раньше: настоящая причина там.'
        todo('Разберись с первой ошибкой, эта уйдёт вместе с ней.')

    elseif low:find('expected near') or low:find('expected %(to close') or msg:find("^'[^']+' expected")
        or low:find('unexpected symbol') or low:find('unfinished string')
        or low:find('unfinished long') or low:find('malformed number') or low:find('<eof>')
        or low:find('syntax error') or low:find('invalid escape') or low:find('ambiguous syntax') then
        ex.kind = 'syntax'
        ex.startup = true
        ex.short = 'ошибка в самом файле скрипта'
        ex.title = c.file .. ' не запустился'
        ex.what = (L and ('Скрипт даже не запустился: на строке ' .. L .. ' в его коде ошибка') or 'Скрипт даже не запустился: в его коде ошибка') .. ', MoonLoader не может его прочитать.'
        local firstSrc = lines and lines[1] or ''
        if (code and code:lower():find('<!doctype')) or (code and code:lower():find('<html')) or firstSrc:lower():find('<!doctype') or firstSrc:lower():find('<html') then
            ex.why = 'Вместо скрипта скачалась веб-страница: внутри файла HTML. Так бывает, если сохранить страницу по ссылке, а не сам файл.'
            todo('Скачай скрипт заново, нажав именно на кнопку скачивания файла.')
        else
            ex.why = 'Обычно файл скачался не полностью, его поправили руками и что-то сломали, или его сохранили не в той кодировке.'
            todo('Скачай скрипт заново из оригинальной темы.')
            todo('Если правил файл сам, верни как было или проверь строку ' .. (L or '?') .. '.')
        end
        ex.dev = 'Проверь файл через luajit -bl или в редакторе с подсветкой Lua.'

    elseif low:find('attempt to yield') or low:find('yield across') then
        ex.kind = 'yield'
        ex.short = 'ошибка в коде: wait() там, где нельзя'
        ex.what = at .. ' вызвал wait() (задержку) там, где ждать нельзя.'
        ex.why = 'Это баг в самом скрипте: внутри обработчиков событий и колбэков задержки запрещены.'
        todo(REPORT_ONLY)
        ex.dev = 'Оберни кусок с wait() в lua_thread.create(function() ... end).'

    elseif low:find('stack overflow') then
        ex.kind = 'overflow'
        ex.short = 'ушёл в бесконечные вызовы'
        ex.what = 'Скрипт ушёл в бесконечный цикл: функция вызывает сама себя, пока не кончится место.'
        ex.why = 'Это ошибка в логике скрипта. Иногда её запускает другой скрипт: например, два скрипта отвечают друг другу на одно и то же сообщение.'
        todo('Загляни на вкладку «Конфликты», вдруг там что-то найдётся.')
        todo(REPORT_ONLY)
        ex.dev = 'Ищи функцию, которая вызывает себя без условия выхода, или два хука, которые вызывают друг друга.'

    elseif low:find('not enough memory') or low:find('out of memory') then
        ex.kind = 'memory'
        ex.short = 'кончилась память'
        ex.what = 'Скриптам не хватило памяти.'
        ex.why = 'У игры памяти немного. Когда стоит много тяжёлых модов, текстур и скриптов, она заканчивается. Ещё бывает, что какой-то скрипт понемногу забирает память и не отдаёт, пока не упрётся в потолок.'
        todo('Перезапусти игру.')
        todo('Убери скрипты и моды, которыми не пользуешься.')
        todo('Проверь вкладку «Нагрузка»: скрипт, который ест FPS, часто и память ест.')

    elseif low:find("invalid key to 'next'") then
        ex.kind = 'bug'
        ex.short = 'ошибка в коде скрипта'
        ex.what = at .. ' менял список прямо во время его перебора.'
        ex.why = 'Это баг в самом скрипте.'
        todo(REPORT_ONLY)
        ex.dev = 'Не добавляй новые ключи в таблицу внутри pairs(), собирай изменения отдельно.'

    elseif low:find('table index is nil') or low:find('table index is nan') then
        ex.kind = 'tindex'
        ex.short = 'записывал данные под пустым ключом'
        ex.what = at .. ' пытался записать что-то в таблицу под пустым ключом.'
        ex.why = packetNote .. 'Ключ (например, ник или id) должен был прийти от сервера или из настроек, но не пришёл.'
        todo(UPDATE)
        todo(REPORT)

    elseif low:find("in table for 'concat'") then
        ex.kind = 'concat'
        ex.short = 'склеивал список, а в нём не текст'
        ex.what = at .. ' склеивал список строк, а в нём оказалось что-то кроме текста и чисел.'
        ex.why = 'Обычно в список попало пустое значение или таблица из данных сервера.'
        todo(UPDATE)
        todo(REPORT)

    elseif low:find('cannot resume dead coroutine') or low:find('cannot resume non%-suspended') then
        ex.kind = 'bug'
        ex.short = 'ошибка в потоках скрипта'
        ex.what = at .. ' попытался продолжить поток (lua_thread), который уже закончился.'
        ex.why = 'Это баг в самом скрипте.'
        todo(REPORT_ONLY)

    elseif low:find("opcode '") or low:find('opcode 0x') then
        local op = msg:match("opcode '?([%x]+)'?") or '?'
        ex.kind = 'opcode'
        ex.short = 'упала игровая функция'
        ex.what = string.format('Внутри игровой функции (опкод %s) случилась ошибка.', op)
        ex.why = 'Обычно скрипт передал ей то, чего уже нет: машину, игрока или объект, который пропал из зоны прорисовки.'
        todo('Если падает в одном и том же месте (например, при посадке в машину), напиши об этом автору вместе с отчётом.')
        todo(REPORT)

    elseif low:find('exception') or low:find('access violation') or low:find('0xc0000005') then
        ex.kind = 'native'
        ex.short = 'полез в память игры не туда'
        ex.what = 'Скрипт обратился к памяти игры по неправильному адресу, и его остановили.'
        ex.why = string.format('Почти всегда это несовместимость: скрипт сделан под другую версию SA-MP (у тебя %s) или конфликтует с другим модом, который меняет те же места в памяти.', samp)
        todo('Проверь в теме скрипта, под какую версию SA-MP он сделан.')
        todo('Если стоят похожие моды (тоже меняют HUD, чат, камеру), попробуй выключить их.')
        todo(REPORT)
        ex.dev = 'Проверяй версию SA-MP по entry point samp.dll и не трогай адреса, если версия неизвестна.'

    elseif low:find('cannot convert') or low:find('has no member named') or low:find('cannot resolve symbol')
        or low:find('cdata') or low:find('ctype') or low:find('cannot load module') then
        ex.kind = 'ffi'
        ex.short = 'ошибка в работе с памятью (FFI)'
        ex.what = at .. ' упал в той части, которая работает напрямую с памятью игры или с системными DLL (FFI).'
        ex.why = string.format('Такой код рассчитан на конкретную версию игры и SA-MP. Если скрипт сделан, например, под 0.3.7-R1, а у тебя %s, адреса не совпадают.', samp)
        todo('Проверь в теме скрипта, под какую версию SA-MP он сделан.')
        todo(REPORT)
        ex.dev = 'Проверяй версию SA-MP перед работой с адресами, а cdef оборачивай в pcall.'

    elseif low:find('no such file or directory') then
        local missing = msg:match('^(.-):%s*[Nn]o such file') or ''
        ex.kind = 'file'
        ex.short = 'не нашёл свой файл'
        ex.what = 'Скрипт не нашёл нужный ему файл' .. (missing ~= '' and (': ' .. missing) or '') .. '.'
        ex.why = 'Скорее всего, при установке скопировали только .lua, а папку с файлами скрипта (картинки, шрифты, звуки, настройки) забыли.'
        todo('Открой архив скрипта ещё раз и скопируй в moonloader всё, что там есть, вместе с папками.')
        todo(REPORT)

    elseif low:find('permission denied') then
        ex.kind = 'file'
        ex.short = 'Windows не дала записать файл'
        ex.what = 'Скрипт хотел записать файл, но Windows не разрешила.'
        ex.why = 'Игра стоит в защищённой папке (например, Program Files), или файл держит другая программа, чаще всего антивирус.'
        todo('Перенеси игру в простую папку, например C:\\Games.')
        todo('Или запусти игру от имени администратора.')

    elseif low:find('json') then
        ex.kind = 'config'
        ex.short = 'сломан файл настроек'
        ex.what = 'Скрипт не смог прочитать файл в формате JSON.'
        ex.why = 'Скорее всего, это его файл настроек, и он повреждён: игра закрылась во время записи, или его правили руками.'
        todo(CONFIG_RESET)
        todo(REPORT)

    elseif low:find('requires moonloader') or low:find('moonloader version') then
        ex.kind = 'mlversion'
        ex.startup = true
        ex.short = 'нужен MoonLoader новее'
        ex.title = c.file .. ' не запустился'
        ex.what = 'Скрипту нужен MoonLoader новее, чем у тебя (' .. mlVersion() .. ').'
        ex.why = 'Скрипт использует то, чего в твоей версии ещё нет.'
        todo('Обнови MoonLoader до последней версии.')

    else
        ex.kind = 'unknown'
        ex.short = 'упал с непонятной ошибкой'
        ex.what = 'Скрипт упал с ошибкой, которую я пока не умею объяснять по-человечески.'
        ex.why = 'Полный текст ошибки есть ниже и в отчёте. Автор скрипта поймёт, что там.'
        todo(UPDATE)
        todo(REPORT)
    end

    if (c.count or 1) >= 3 and not ex.startup then
        ex.repeatNote = string.format('Падает уже %d %s. Похоже, это не случайность, а что-то стабильно ломается.', c.count, plural(c.count, 'раз', 'раза', 'раз'))
    end

    explainCache[c] = ex
    return ex
end

end

local scan

local function prepCode(line, maxChars)
    return cutText(toU8(line or ''):gsub('\t', '    '), maxChars or 160)
end

local function runningList()
    local list = {}
    local ok, all = pcall(script.list)
    if ok and type(all) == 'table' then
        for _, s in ipairs(all) do
            local info = snapshot(s)
            if info and not isSelf(s) then
                list[#list + 1] = info.file .. (info.version ~= '' and (' ' .. info.version) or '')
            end
        end
    end
    table.sort(list, function(a, b) return a:lower() < b:lower() end)
    return list
end

local function buildReport(c, forForum)
    local ex = explain(c)
    local out = {}
    local function add(s) out[#out + 1] = s end
    local lines = c.demoLines or sourceLines(c.path)

    add('Отчёт MoonDoctor ' .. VERSION .. (c.demo and ' (ПРИМЕР, на самом деле ничего не падало)' or ''))
    add('')
    local title = 'Скрипт: ' .. c.file
    if c.version ~= '' then title = title .. ' (версия ' .. c.version .. ')' end
    add(title)
    if c.name ~= '' and c.name ~= c.file then add('Название: ' .. c.name) end
    local when = 'Когда: ' .. os.date('%d.%m.%Y %H:%M:%S', c.last)
    if (c.count or 1) > 1 then when = when .. string.format(' (всего %d %s)', c.count, plural(c.count, 'раз', 'раза', 'раз')) end
    add(when)
    add('Ошибка: ' .. firstLine(c.message))
    if c.line then
        local where = c.where and (c.where .. ', строка ') or 'Строка '
        local codeLine = lines and lines[c.line]
        add(where .. c.line .. ': ' .. (codeLine and trim(prepCode(codeLine, 200)) or '(исходник недоступен)'))
    end
    if c.libFile then
        local libName = (c.libPath or ''):match('[\\/]lib[\\/](.+)$') or c.libFile
        add('Внутри библиотеки: ' .. libName .. (c.libLine and (', строка ' .. c.libLine) or ''))
    end
    add('Что это значит: ' .. ex.what)
    add('')
    add('Полный текст ошибки:')
    if forForum then add('[code]') end
    local raw, cut = {}, 0
    for l in (c.raw .. '\n'):gmatch('([^\n]*)\n') do
        if l:find('^%s*no file ') or l:find('^%s*no field package') then
            cut = cut + 1
        else
            raw[#raw + 1] = l
        end
    end
    add(table.concat(raw, '\n'))
    if cut > 0 then add(string.format('(ещё %d строк «no file ...» убрал)', cut)) end
    if forForum then add('[/code]') end
    add('')
    add('MoonLoader: ' .. mlVersion())
    add('SA-MP: ' .. (sampVersion() or 'не найден') .. ' | SAMPFUNCS: ' .. (sfLoaded() and 'есть' or 'нет') .. ' | CLEO: ' .. (isCleoLoaded() and 'есть' or 'нет'))
    local server = serverInfo()
    if server then add('Сервер: ' .. server) end
    local sw, sh = getScreenResolution()
    add(string.format('Разрешение: %dx%d', sw, sh))

    if scan and scan.done then
        local related = {}
        for _, issue in ipairs(scan.issues) do
            if issue.files and issue.files[c.file:lower()] then related[#related + 1] = '- ' .. issue.title end
        end
        if #related > 0 then
            add('')
            add('Конфликты с этим скриптом:')
            for i = 1, math.min(#related, 6) do add(related[i]) end
        end
    end

    local others = runningList()
    add('')
    add(string.format('Запущенные скрипты (%d):', #others))
    for i = 1, #others, 4 do
        add('  ' .. table.concat(others, ', ', i, math.min(i + 3, #others)))
    end
    return (table.concat(out, '\n'):gsub('\n', '\r\n'))
end

local function saveReport(c)
    ensureDir(ML_DIR .. '\\config')
    ensureDir(CFG_DIR)
    ensureDir(REPORTS_DIR)
    local base = c.file:gsub('%.luac?$', ''):gsub('[\\/:%*%?"<>|%s]', '_')
    local name = string.format('%s_%s.txt', base, os.date('%Y-%m-%d_%H-%M-%S'))
    local path = REPORTS_DIR .. '\\' .. fromU8(name)
    local ok = writeFile(path, '\239\187\191' .. buildReport(c, false))
    return ok, toU8(path)
end

local MODIFIERS, keyName, listMoonloaderDir, runScan

do

local function stripComments(src)
    local out = {}
    local i, n = 1, #src
    while i <= n do
        local s = src:find('[%-%[\'"]', i)
        if not s then
            out[#out + 1] = src:sub(i)
            break
        end
        out[#out + 1] = src:sub(i, s - 1)
        local ch = src:sub(s, s)
        if ch == '-' then
            if src:sub(s + 1, s + 1) == '-' then
                local eq = src:match('^%[(=*)%[', s + 2)
                local e
                if eq then
                    local _, close = src:find(']' .. eq .. ']', s + 2, true)
                    e = close or n
                else
                    e = (src:find('\n', s + 2, true) or (n + 1)) - 1
                end
                out[#out + 1] = (src:sub(s, e):gsub('[^\n]', ''))
                i = e + 1
            else
                out[#out + 1] = ch
                i = s + 1
            end
        elseif ch == '[' then
            local eq = src:match('^%[(=*)%[', s)
            if eq then
                local _, close = src:find(']' .. eq .. ']', s, true)
                close = close or n
                out[#out + 1] = src:sub(s, close)
                i = close + 1
            else
                out[#out + 1] = ch
                i = s + 1
            end
        else
            local j = s + 1
            while true do
                local q = src:find('[\\\n' .. ch .. ']', j)
                if not q then j = n break end
                if src:sub(q, q) == '\\' then
                    j = q + 2
                else
                    j = q
                    break
                end
            end
            out[#out + 1] = src:sub(s, j)
            i = j + 1
        end
    end
    return table.concat(out)
end

MODIFIERS = {
    [0x10] = 'Shift', [0xA0] = 'Shift', [0xA1] = 'Shift',
    [0x11] = 'Ctrl', [0xA2] = 'Ctrl', [0xA3] = 'Ctrl',
    [0x12] = 'Alt', [0xA4] = 'Alt', [0xA5] = 'Alt',
    [0x01] = 'ЛКМ', [0x02] = 'ПКМ', [0x04] = 'СКМ',
}
local NOT_HOTKEYS = {
    [0x05] = true, [0x06] = true, [0x08] = true, [0x09] = true, [0x0D] = true, [0x1B] = true, [0x20] = true,
    [0x25] = true, [0x26] = true, [0x27] = true, [0x28] = true,
    [0x57] = true, [0x41] = true, [0x53] = true, [0x44] = true,
}
local KEY_FUNCS = { 'isKeyJustPressed', 'isKeyDown', 'wasKeyPressed', 'wasKeyReleased', 'isKeyPressed', 'isKeyReleased' }

function keyName(id)
    local ok, name = pcall(vkeys.id_to_name, id)
    if ok and type(name) == 'string' and name ~= '' then return name end
    return string.format('0x%02X', id)
end

local function scanKeys(line, lineNo, out)
    local isKeyLine = line:find('wparam', 1, true) ~= nil
    if not isKeyLine then
        for _, f in ipairs(KEY_FUNCS) do
            if line:find(f, 1, true) then isKeyLine = true break end
        end
    end
    if not isKeyLine then return end

    local ids = {}
    for tok in line:gmatch('VK_[%w_]+') do
        local id = vkeys[tok]
        if type(id) == 'number' then ids[#ids + 1] = id end
    end
    for _, f in ipairs(KEY_FUNCS) do
        for num in line:gmatch(f .. '%s*%(%s*(0[xX]%x+)%s*%)') do ids[#ids + 1] = tonumber(num) end
        for num in line:gmatch(f .. '%s*%(%s*(%d+)%s*%)') do ids[#ids + 1] = tonumber(num) end
    end

    local mods, modSeen, mains = {}, {}, {}
    for _, id in ipairs(ids) do
        local m = MODIFIERS[id]
        if m then
            if not modSeen[m] then
                modSeen[m] = true
                mods[#mods + 1] = m
            end
        elseif not NOT_HOTKEYS[id] then
            mains[#mains + 1] = id
        end
    end
    table.sort(mods)
    local prefix = #mods > 0 and (table.concat(mods, ' + ') .. ' + ') or ''
    for _, id in ipairs(mains) do
        out[#out + 1] = { combo = prefix .. keyName(id), line = lineNo }
    end
end

local function scanSource(src)
    local res = { commands = {}, keys = {}, requires = {}, imports = {}, deps = {} }
    local clean = stripComments(src)

    res.name = clean:match('script_name%s*%(?%s*["\']([^"\']+)["\']')
    res.mlMin = tonumber(clean:match('script_moonloader%s*%(%s*(%d+)'))
    local deps = clean:match('script_dependencies%s*(%b())')
    if deps then
        for d in deps:gmatch('["\']([^"\']+)["\']') do res.deps[#res.deps + 1] = d end
    end
    res.changesPath = clean:find('package%.c?path%s*=') ~= nil
    res.usesSF = clean:find('%f[%w_]samp%u%w*%s*%(') ~= nil or clean:find('%f[%w_]raknet%u%w*%s*%(') ~= nil

    local n = 0
    for line in (clean .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if line:find('sampRegisterChatCommand', 1, true) then
            for cmd in line:gmatch('sampRegisterChatCommand%s*%(%s*["\']/?([^"\']+)["\']') do
                res.commands[#res.commands + 1] = { cmd = cmd:lower(), line = n }
            end
        end
        if line:find('require', 1, true) then
            for pos, mod in line:gmatch('()%f[%w_]require%s*%(?%s*["\']([^"\']+)["\']') do
                local before = pos > 1 and line:sub(pos - 1, pos - 1) or ''
                if before ~= '.' and before ~= ':' then
                    res.requires[#res.requires + 1] = { mod = mod, line = n }
                end
            end
            for mod in line:gmatch('pcall%s*%(%s*require%s*,%s*["\']([^"\']+)["\']') do
                res.requires[#res.requires + 1] = { mod = mod, line = n, optional = true }
            end
        end
        if line:find('import', 1, true) then
            for pos, f in line:gmatch('()%f[%w_]import%s*%(?%s*["\']([^"\']+)["\']') do
                local before = pos > 1 and line:sub(pos - 1, pos - 1) or ''
                if before ~= '.' and before ~= ':' then
                    res.imports[#res.imports + 1] = { file = f, line = n }
                end
            end
        end
        scanKeys(line, n, res.keys)
    end

    local optional = {}
    for _, r in ipairs(res.requires) do
        if r.optional then optional[r.mod] = true end
    end
    for _, r in ipairs(res.requires) do
        if optional[r.mod] then r.optional = true end
    end
    return res
end

function listMoonloaderDir()
    local files, dirs, others = {}, {}, {}
    local handle, name = findFirstFile(ML_DIR .. '\\*')
    if handle then
        while name do
            if name ~= '.' and name ~= '..' then
                local full = ML_DIR .. '\\' .. name
                local low = name:lower()
                if doesDirectoryExist(full) then
                    dirs[#dirs + 1] = name
                elseif low:find('%.luac?$') then
                    files[#files + 1] = { name = toU8(name), path = full, compiled = low:find('%.luac$') ~= nil }
                else
                    others[#others + 1] = name
                end
            end
            name = findNextFile(handle)
        end
        findClose(handle)
    end
    table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)
    return files, dirs, others
end

local BUILTIN_MODULES = {
    ffi = true, bit = true, jit = true, ['jit.util'] = true, ['jit.opt'] = true, ['jit.profile'] = true,
    ['table.new'] = true, ['table.clear'] = true, ['string.buffer'] = true,
    string = true, table = true, math = true, io = true, os = true, coroutine = true, debug = true, package = true,
}

local function searchPath(name, paths)
    local fname = name:gsub('%.', '\\')
    for tpl in (paths or ''):gmatch('[^;]+') do
        local p = tpl:gsub('%?', function() return fname end)
        if doesFileExist(p) then return p end
    end
end

local moduleCache = {}
local function moduleExists(mod)
    if moduleCache[mod] ~= nil then return moduleCache[mod] end
    local found = false
    if BUILTIN_MODULES[mod] or package.loaded[mod] or package.preload[mod] then
        found = true
    else
        for _, name in ipairs({ mod, (mod:gsub('^lib%.', '')) }) do
            if searchPath(name, package.path) or searchPath(name, package.cpath) then found = true break end
            local root = name:match('^([^%.]+)%.')
            if root and searchPath(root, package.cpath) then found = true break end
        end
    end
    moduleCache[mod] = found
    return found
end

local ROOT_LIB_FILES = {
    ['vkeys.lua'] = true, ['inicfg.lua'] = true, ['encoding.lua'] = true, ['imgui.lua'] = true, ['moonloader.lua'] = true,
    ['sampfuncs.lua'] = true, ['memory.lua'] = true, ['requests.lua'] = true, ['effil.lua'] = true, ['fawesome5.lua'] = true,
    ['fawesome6.lua'] = true, ['vector3d.lua'] = true, ['matrix3x3.lua'] = true, ['bitex.lua'] = true, ['rkeys.lua'] = true,
    ['imgui_addons.lua'] = true, ['dkjson.lua'] = true, ['copas.lua'] = true, ['ltn12.lua'] = true, ['mime.lua'] = true,
}
local ROOT_LIB_DIRS = { mimgui = true, samp = true, socket = true, ssl = true }

local function baseKey(name)
    local b = name:lower():gsub('%.luac?$', '')
    b = b:gsub('%s*%(%d+%)$', ''):gsub('%s*%-%s*copy$', ''):gsub('%s+copy$', '')
    for _, suffix in ipairs({ ' - копия', ' - Копия', ' копия', ' Копия' }) do
        if b:sub(-#suffix) == suffix then b = b:sub(1, -#suffix - 1) end
    end
    return trim(b)
end

scan = {
    running = false,
    done = false,
    time = nil,
    progress = 0,
    issues = {},
    files = {},
    compiled = {},
    unreadable = {},
    counts = { red = 0, yellow = 0, info = 0 },
}

local function fileRef(f, line)
    local s = f.file
    if line then s = s .. ', строка ' .. line end
    if not f.running then s = s .. ' (сейчас не запущен)' end
    return s
end

local function scriptIdentity(f)
    if f.name and f.name ~= '' then return 'n:' .. f.name:lower() end
    return 'f:' .. baseKey(f.file)
end

local function countDistinct(list, onlyRunning)
    local set, n = {}, 0
    for _, x in ipairs(list) do
        local id = scriptIdentity(x.f)
        if not set[id] and (not onlyRunning or x.f.running) then
            set[id] = true
            n = n + 1
        end
    end
    return n
end

local function collectIssues(results, dirs, others)
    local issues = {}
    local function add(issue)
        issue.files = issue.files or {}
        issues[#issues + 1] = issue
    end

    local cmds = {}
    for _, f in ipairs(results) do
        local seen = {}
        for _, c in ipairs(f.commands or {}) do
            if not seen[c.cmd] then
                seen[c.cmd] = true
                cmds[c.cmd] = cmds[c.cmd] or {}
                table.insert(cmds[c.cmd], { f = f, line = c.line })
            end
        end
    end
    for cmd, list in pairs(cmds) do
        local n = countDistinct(list)
        if n >= 2 then
            local details, files = {}, {}
            for _, x in ipairs(list) do
                details[#details + 1] = fileRef(x.f, x.line)
                files[x.f.file:lower()] = true
            end
            add({
                group = 'commands',
                level = countDistinct(list, true) >= 2 and 'red' or 'yellow',
                title = string.format('Команда /%s есть сразу в %d %s', cmd, n, plural(n, 'скрипте', 'скриптах', 'скриптах')),
                text = 'Работать будет только один из них, второй молча проиграет. Отсюда и жалобы, что команда не работает. Убери лишний скрипт или поменяй команду в одном из них, если в настройках это можно.',
                details = details,
                files = files,
                key = cmd,
            })
        end
    end

    local keys = {}
    for _, f in ipairs(results) do
        local seen = {}
        for _, k in ipairs(f.keys or {}) do
            if not seen[k.combo] then
                seen[k.combo] = true
                keys[k.combo] = keys[k.combo] or {}
                table.insert(keys[k.combo], { f = f, line = k.line })
            end
        end
    end
    for combo, list in pairs(keys) do
        local n = countDistinct(list)
        if n >= 2 then
            local details, files = {}, {}
            for _, x in ipairs(list) do
                details[#details + 1] = fileRef(x.f, x.line)
                files[x.f.file:lower()] = true
            end
            add({
                group = 'keys',
                level = 'yellow',
                title = string.format('Клавиша %s нужна сразу %d %s', combo, n, plural(n, 'скрипту', 'скриптам', 'скриптам')),
                text = 'Нажмёшь её, и сработают все сразу: откроется два меню, или один скрипт перебьёт другой. Если так не задумано, поменяй клавишу в одном из них.',
                details = details,
                files = files,
                key = combo,
            })
        end
    end

    local missing = {}
    for _, f in ipairs(results) do
        local seen = {}
        for _, r in ipairs(f.requires or {}) do
            if not r.optional and not seen[r.mod] and not moduleExists(r.mod) then
                seen[r.mod] = true
                missing[r.mod] = missing[r.mod] or {}
                table.insert(missing[r.mod], { f = f, line = r.line })
            end
        end
    end
    for mod, list in pairs(missing) do
        local details, files, dead, guess = {}, {}, 0, 0
        for _, x in ipairs(list) do
            details[#details + 1] = fileRef(x.f, x.line)
            files[x.f.file:lower()] = true
            if not x.f.running then dead = dead + 1 end
            if x.f.changesPath then guess = guess + 1 end
        end
        local info, std = libInfo(mod)
        local text
        if std then
            text = 'Это стандартная библиотека MoonLoader, она должна быть у всех. Похоже, MoonLoader стоит не полностью. Переустанови его.'
        elseif info then
            text = string.format('Это %s, %s. Скачай её и положи в moonloader\\lib (именно в lib).', info[1], info[2])
        else
            text = 'Найди эту библиотеку (ссылка обычно есть в теме скрипта) и положи в moonloader\\lib.'
        end
        local level = dead > 0 and 'red' or 'yellow'
        if dead == 0 then
            text = text .. ' Скрипт сейчас работает, но упадёт, когда дойдёт до места, где она нужна.'
        end
        if guess == #list then
            level = 'info'
            text = text .. ' Правда, скрипт сам меняет пути поиска библиотек, так что она может лежать в другом месте.'
        end
        add({
            group = 'libs',
            level = level,
            title = string.format('Нет библиотеки %s', mod),
            text = text,
            details = details,
            files = files,
            key = mod,
        })
    end

    for _, f in ipairs(results) do
        for _, imp in ipairs(f.imports or {}) do
            local name = imp.file
            local candidates = { name, name .. '.lua', name .. '.luac' }
            local found = false
            for _, cand in ipairs(candidates) do
                if doesFileExist(fromU8(cand)) or doesFileExist(ML_DIR .. '\\' .. fromU8(cand)) then found = true break end
            end
            if not found then
                add({
                    group = 'libs',
                    level = f.running and 'yellow' or 'red',
                    title = string.format('%s подключает %s, а его нет', f.file, name),
                    text = 'Скрипт берёт часть функций из другого скрипта, а того в папке нет. Обычно он идёт в том же архиве, просто его забыли скопировать.',
                    details = { fileRef(f, imp.line) },
                    files = { [f.file:lower()] = true },
                    key = 'import:' .. name,
                })
            end
        end
    end

    local mlNow = mlVersionNumber()
    local sf, sampLoaded, cleo = sfLoaded(), isSampLoaded(), isCleoLoaded()
    local missingDeps = {}
    for _, f in ipairs(results) do
        if f.mlMin and mlNow > 0 and f.mlMin > mlNow then
            add({
                group = 'files',
                level = 'red',
                title = string.format('%s нужен MoonLoader поновее', f.file),
                text = string.format('Скрипт просит MoonLoader не ниже v.%03d, а у тебя %s. Обнови MoonLoader.', f.mlMin, mlVersion()),
                details = { fileRef(f) },
                files = { [f.file:lower()] = true },
            })
        end
        local function need(what)
            missingDeps[what] = missingDeps[what] or {}
            local list = missingDeps[what]
            if list[#list] ~= f then list[#list + 1] = f end
        end
        for _, d in ipairs(f.deps or {}) do
            local up = d:upper()
            if up:find('SAMPFUNCS') and not sf then need('SAMPFUNCS') end
            if (up == 'SA:MP' or up == 'SAMP' or up:find('^SA%-?MP')) and not sampLoaded then need('SA-MP') end
            if up:find('CLEO') and not cleo then need('CLEO') end
        end
        if f.usesSF and not sf then need('SAMPFUNCS') end
    end
    local DEP_TEXT = {
        ['SAMPFUNCS'] = 'Без SAMPFUNCS не работают команды в чате, диалоги и почти всё, что связано с SA-MP. Поставь SAMPFUNCS под свою версию SA-MP (у тебя %s).',
        ['SA-MP'] = 'Эти скрипты рассчитаны на игру в SA-MP, а SA-MP не загружен. В одиночной игре они работать не будут.',
        ['CLEO'] = 'Эти скрипты просят CLEO, а он не загружен. Поставь CLEO 4 в папку с игрой.',
    }
    for what, list in pairs(missingDeps) do
        local details, files = {}, {}
        for _, f in ipairs(list) do
            details[#details + 1] = fileRef(f)
            files[f.file:lower()] = true
        end
        add({
            group = 'files',
            level = 'red',
            title = string.format('Нет %s, а он нужен %d %s', what, #list, plural(#list, 'скрипту', 'скриптам', 'скриптам')),
            text = string.format(DEP_TEXT[what], sampVersion() or 'неизвестна'),
            details = details,
            files = files,
            key = 'dep:' .. what,
        })
    end

    local groups, byName = {}, {}
    for _, f in ipairs(results) do
        local k = baseKey(f.file)
        groups[k] = groups[k] or {}
        table.insert(groups[k], f)
        if f.name and f.name ~= '' then
            local nk = toU8(f.name):lower()
            byName[nk] = byName[nk] or {}
            table.insert(byName[nk], f)
        end
    end
    local reported = {}
    local function reportDupes(list)
        if #list < 2 then return end
        local names, files = {}, {}
        for _, f in ipairs(list) do
            names[#names + 1] = f.file
            files[f.file:lower()] = true
        end
        table.sort(names)
        local key = table.concat(names, '|'):lower()
        if reported[key] then return end
        reported[key] = true
        add({
            group = 'files',
            level = 'yellow',
            title = 'Похоже, один скрипт стоит несколько раз',
            text = 'MoonLoader запускает все копии сразу, поэтому команды и клавиши срабатывают дважды, а настройки путаются. Оставь одну, самую новую.',
            details = names,
            files = files,
        })
    end
    for _, list in pairs(groups) do reportDupes(list) end
    for _, list in pairs(byName) do reportDupes(list) end

    for _, f in ipairs(results) do
        if ROOT_LIB_FILES[f.file:lower()] then
            add({
                group = 'files',
                level = 'yellow',
                title = string.format('%s лежит не в той папке', f.file),
                text = 'Это библиотека, а лежит прямо в moonloader. MoonLoader запускает её как обычный скрипт, а те скрипты, которым она нужна, её не видят. Перенеси в moonloader\\lib.',
                details = { f.file },
                files = { [f.file:lower()] = true },
            })
        end
    end
    for _, d in ipairs(dirs) do
        local low = d:lower()
        if ROOT_LIB_DIRS[low] and not doesDirectoryExist(ML_DIR .. '\\lib\\' .. d) then
            add({
                group = 'files',
                level = 'red',
                title = string.format('Папка %s лежит не там', toU8(d)),
                text = string.format('Это библиотека, ей место в moonloader\\lib. Сейчас скрипты её не находят. Перенеси папку %s в moonloader\\lib.', toU8(d)),
                details = { 'moonloader\\' .. toU8(d) },
            })
        end
    end
    if not doesDirectoryExist(ML_DIR .. '\\lib') then
        add({
            group = 'files',
            level = 'red',
            title = 'Нет папки moonloader\\lib',
            text = 'Там лежат все библиотеки. Без неё почти ни один скрипт не запустится. Переустанови MoonLoader.',
            details = {},
        })
    end
    for _, o in ipairs(others) do
        local low, name = o:lower(), toU8(o)
        if low:find('%.luac?%.txt$') then
            add({
                group = 'files',
                level = 'red',
                title = string.format('%s не запустится', name),
                text = 'У файла на самом деле расширение .txt (Windows прячет его по умолчанию), поэтому MoonLoader его не видит. Переименуй, чтобы в конце было просто .lua.',
                details = { name },
            })
        elseif low:find('%.cs$') or low:find('%.cs4$') or low:find('%.cs3$') then
            add({
                group = 'files',
                level = 'yellow',
                title = string.format('%s это CLEO-скрипт', name),
                text = 'MoonLoader запускает только .lua и .luac. CLEO-скриптам место в папке cleo в корне игры.',
                details = { name },
            })
        elseif low:find('%.asi$') then
            add({
                group = 'files',
                level = 'yellow',
                title = string.format('%s лежит не там', name),
                text = 'Это ASI-плагин. Из папки moonloader он не загрузится, его кладут в корень игры, рядом с gta_sa.exe.',
                details = { name },
            })
        elseif low:find('%.sf$') then
            add({
                group = 'files',
                level = 'yellow',
                title = string.format('%s лежит не там', name),
                text = 'Это плагин SAMPFUNCS. Ему место в папке SAMPFUNCS в корне игры.',
                details = { name },
            })
        end
    end

    local order = { red = 1, yellow = 2, info = 3 }
    local groupOrder = { commands = 1, keys = 2, libs = 3, files = 4 }
    table.sort(issues, function(a, b)
        if groupOrder[a.group] ~= groupOrder[b.group] then return groupOrder[a.group] < groupOrder[b.group] end
        if order[a.level] ~= order[b.level] then return order[a.level] < order[b.level] end
        return a.title < b.title
    end)
    return issues
end

local function doScan()
    moduleCache = {}
    local files, dirs, others = listMoonloaderDir()
    local running = getRunning(true)
    local seen, results, compiled, unreadable = {}, {}, {}, {}

    for key, s in pairs(running) do
        local found = false
        for _, f in ipairs(files) do
            if f.name:lower() == key then found = true break end
        end
        if not found then
            local path = scriptField(s, 'path')
            if path and path ~= '' then
                files[#files + 1] = { name = toU8(fileName(path)), path = path, compiled = path:lower():find('%.luac$') ~= nil, outside = true }
            end
        end
    end

    local me = toU8(scriptField(thisScript(), 'filename') or ''):lower()
    for i, f in ipairs(files) do
        local key = f.name:lower()
        if not seen[key] and key ~= me then
            seen[key] = true
            local info = { file = f.name, path = toU8(f.path), running = running[key] ~= nil, compiled = f.compiled }
            local data = readFile(f.path)
            if data and #data > 3 * 1024 * 1024 then
                data = nil
                unreadable[#unreadable + 1] = f.name .. ' (слишком большой)'
            elseif not data then
                info.unreadable = true
                unreadable[#unreadable + 1] = f.name
            elseif data:sub(1, 3) == '\27LJ' then
                info.compiled = true
                compiled[#compiled + 1] = f.name
            else
                local ok, res = pcall(scanSource, data)
                if ok then
                    for k, v in pairs(res) do info[k] = v end
                    if info.name then info.name = toU8(info.name) end
                else
                    unreadable[#unreadable + 1] = f.name
                end
            end
            results[#results + 1] = info
        end
        scan.progress = i / math.max(1, #files)
        wait(0)
    end

    local issues = collectIssues(results, dirs, others)
    local counts = { red = 0, yellow = 0, info = 0 }
    for _, issue in ipairs(issues) do counts[issue.level] = counts[issue.level] + 1 end

    scan.files = results
    scan.issues = issues
    scan.counts = counts
    scan.compiled = compiled
    scan.unreadable = unreadable
    scan.time = os.time()
    scan.done = true
end

function runScan()
    if scan.running then return end
    scan.running = true
    scan.progress = 0
    lua_thread.create(function()
        local ok, err = pcall(doScan)
        if not ok then
            scan.error = tostring(err)
            print('[MoonDoctor] проверка конфликтов сломалась: ' .. tostring(err))
        else
            scan.error = nil
        end
        scan.running = false
    end)
end

end

local fps = {
    running = false,
    cancel = false,
    waiting = false,
    phase = '',
    index = 0,
    total = 0,
    current = '',
    startedAt = 0,
    estimate = 0,
    results = nil,
    error = nil,
    paused = {},
}

local function frameLimiterOn()
    if not isGameVersionOriginal() then return false end
    local ok, v = pcall(memory.getint8, 0xBA6794)
    return ok and v == 1
end

local function resumePaused()
    for i = #fps.paused, 1, -1 do
        local s = fps.paused[i]
        pcall(function()
            if not s.dead then s:resume() end
        end)
        fps.paused[i] = nil
    end
end

local function gameActive()
    return isGameWindowForeground() and not isGamePaused() and not isPauseMenuActive()
end

local function measureFps(seconds)
    for _ = 1, 5 do
        while not gameActive() do
            if fps.cancel then return nil end
            fps.waiting = true
            wait(200)
        end
        fps.waiting = false
        local times, broken = {}, false
        local start = localClock()
        local last = start
        while localClock() - start < seconds do
            wait(0)
            if fps.cancel then return nil end
            local now = localClock()
            local dt = now - last
            last = now
            if dt > 0.25 or not gameActive() then
                broken = true
                break
            end
            times[#times + 1] = dt
        end
        if not broken and #times >= 10 then
            table.sort(times)
            local from = math.floor(#times * 0.03) + 1
            local to = math.max(from, math.floor(#times * 0.92))
            local sum = 0
            for i = from, to do sum = sum + times[i] end
            if sum > 0 then return (to - from + 1) / sum end
        end
    end
    return nil
end

local function fpsTargets()
    local list = {}
    local ok, all = pcall(script.list)
    if not ok or type(all) ~= 'table' then return list end
    for _, s in ipairs(all) do
        if not isSelf(s) and not scriptField(s, 'dead') then
            local info = snapshot(s)
            info.s = s
            info.frozen = scriptField(s, 'frozen') and true or false
            list[#list + 1] = info
        end
    end
    return list
end

local SETTLE = 0.4

local function estimateFpsTest(n, sec)
    local base = math.max(1, sec * 0.75)
    return 0.8 + n * (base + sec + SETTLE * 2) + base
end

local function mean(list)
    if #list == 0 then return nil end
    local sum = 0
    for _, v in ipairs(list) do sum = sum + v end
    return sum / #list
end

local function runFpsTest()
    local targets = fpsTargets()
    local sec = settings.measureSec
    local baseSec = math.max(1, sec * 0.75)
    fps.total = #targets
    fps.index = 0
    fps.startedAt = localClock()
    fps.estimate = estimateFpsTest(#targets, sec)
    fps.phase = 'warmup'
    fps.current = ''
    wait(800)

    local bases, rows = {}, {}
    for i, t in ipairs(targets) do
        fps.index, fps.current = i, t.file
        fps.phase = 'base'
        bases[i] = measureFps(baseSec)
        if fps.cancel then return end

        local row = { file = t.file, name = t.name, version = t.version }
        if t.frozen then
            row.skip = 'был на паузе ещё до проверки'
        elseif scriptField(t.s, 'dead') then
            row.skip = 'выгрузился во время проверки'
        else
            fps.phase = 'paused'
            local ok = pcall(function() t.s:pause() end)
            if ok then
                fps.paused[#fps.paused + 1] = t.s
                wait(SETTLE * 1000)
                row.paused = measureFps(sec)
                resumePaused()
                if fps.cancel then return end
                wait(SETTLE * 1000)
                if not row.paused then row.skip = 'не получилось замерить' end
            else
                row.skip = 'не ставится на паузу'
            end
        end
        rows[i] = row
    end
    fps.phase = 'base'
    fps.current = ''
    bases[#targets + 1] = measureFps(baseSec)
    if fps.cancel then return end

    local valid = {}
    for i = 1, #targets + 1 do
        if bases[i] then valid[#valid + 1] = bases[i] end
    end
    local avgBase = mean(valid)
    if not avgBase then
        fps.error = 'Не получилось замерить FPS. Проверь, что игра не свёрнута, и запусти ещё раз.'
        return
    end
    local diffs = {}
    for i = 2, #targets + 1 do
        if bases[i] and bases[i - 1] then diffs[#diffs + 1] = math.abs(bases[i] - bases[i - 1]) end
    end
    local noise = mean(diffs) or avgBase * 0.02
    local threshold = math.max(1, noise * 1.5)

    local measured, allZero = 0, true
    for i, row in ipairs(rows) do
        if row.paused then
            local b1, b2 = bases[i], bases[i + 1]
            local base = (b1 and b2) and (b1 + b2) / 2 or b1 or b2 or avgBase
            row.base = base
            row.delta = row.paused - base
            row.ms = 1000 / base - 1000 / row.paused
            measured = measured + 1
            if row.delta < threshold then
                row.level = 'green'
                row.zero = true
            elseif row.delta >= 10 or row.delta / base >= 0.10 then
                row.level = 'red'
                allZero = false
            elseif row.delta >= 3 or row.delta / base >= 0.03 then
                row.level = 'yellow'
                allZero = false
            else
                row.level = 'green'
                allZero = false
            end
        end
    end

    table.sort(rows, function(a, b)
        if (a.paused ~= nil) ~= (b.paused ~= nil) then return a.paused ~= nil end
        if a.paused and b.paused then return (a.delta or 0) > (b.delta or 0) end
        return a.file:lower() < b.file:lower()
    end)

    fps.results = {
        time = os.time(),
        base = avgBase,
        noise = noise,
        threshold = threshold,
        sec = sec,
        rows = rows,
        capped = measured >= 2 and allZero,
    }
    saveJson(FPS_FILE, fps.results)
end

local function startFpsTest()
    if fps.running then return end
    fps.running, fps.cancel, fps.error, fps.waiting = true, false, nil, false
    lua_thread.create(function()
        local ok, err = pcall(runFpsTest)
        resumePaused()
        if not ok then
            fps.error = 'Проверка сломалась: ' .. tostring(err)
            print('[MoonDoctor] замер FPS сломался: ' .. tostring(err))
        end
        fps.running = false
        fps.phase = ''
    end)
end

local function stopFpsTest()
    if fps.running then fps.cancel = true end
end

local function loadFpsResults()
    local data = loadJson(FPS_FILE)
    if data and type(data.rows) == 'table' and tonumber(data.base) then fps.results = data end
end

local function fpsResultsText()
    local r = fps.results
    if not r then return '' end
    local out = {
        string.format('MoonDoctor: нагрузка скриптов (%s)', os.date('%d.%m.%Y %H:%M', r.time)),
        string.format('Средний FPS со всеми скриптами: %d, погрешность около %d', round(r.base), math.max(1, round(r.noise or 1))),
        '',
    }
    for _, row in ipairs(r.rows) do
        if row.paused then
            local impact = row.zero and 'не влияет' or string.format('-%d FPS (%.1f мс на кадр)', round(row.delta), row.ms or 0)
            out[#out + 1] = string.format('%s: %s', row.file, impact)
        else
            out[#out + 1] = string.format('%s: %s', row.file, row.skip or 'пропущен')
        end
    end
    out[#out + 1] = ''
    out[#out + 1] = 'MoonLoader ' .. mlVersion() .. ', SA-MP ' .. (sampVersion() or 'не найден')
    return (table.concat(out, '\n'):gsub('\n', '\r\n'))
end

local toasts = {}
local toastId = 0
local commandName
local missedOnStart = 0

local ui = {
    page = 'crashes',
    crashView = 'list',
    selected = nil,
    scale = 1,
    styleK = 1,
    fontK = 1,
    fonts = {},
    flash = {},
    folds = {},
    cardH = {},
    navAnim = {},
    pageAlpha = 1,
    wrapDepth = 0,
    capturingKey = false,
}

local function chat(textU8)
    if not sampReady() then return false end
    pcall(sampAddChatMessage, fromU8('{2EC4A0}[MoonDoctor]{FFFFFF} ' .. textU8), CHAT_COLOR)
    return true
end

local function pushToast(t)
    if not imgui then return end
    toastId = toastId + 1
    t.id = toastId
    t.born = localClock()
    t.ttl = t.ttl or 9
    table.insert(toasts, 1, t)
    while #toasts > 3 do table.remove(toasts) end
end

local function openText()
    if commandName then return '/' .. commandName end
    if settings.hotkey ~= 0 then return keyName(settings.hotkey) end
    return 'Ctrl + Shift + D'
end

local function openWindow(page)
    if not imgui then return end
    ui.show[0] = true
    if page then ui.page = page end
    ui.pageAlpha = 0
    toasts = {}
end

local function openCrash(c)
    if not c then return end
    ui.selected = c.id
    ui.crashView = 'detail'
    c.unread = false
    openWindow('crashes')
end

local function notifyCrash(c, isRepeat)
    local ex = explain(c)
    print(string.format('[MoonDoctor] %s: %s', fromU8(c.file), fromU8(ex.what)))

    local now = localClock()
    if isRepeat and c.notifiedAt and now - c.notifiedAt < 10 then return end
    c.notifiedAt = now

    if not sampReady() then missedOnStart = missedOnStart + 1 end
    if settings.chat then
        local again = isRepeat and string.format(' (уже %d-й раз)', c.count) or ''
        chat(string.format('%s упал%s: %s. Подробнее: %s', c.file, again, ex.short, openText()))
    end
    if settings.autoOpen and imgui then
        openCrash(c)
    elseif settings.toast then
        pushToast({
            kind = 'crash',
            crashId = c.id,
            title = ex.title,
            text = capitalize(ex.short),
            color = 'red',
        })
    end
end

local function handleError(msg, s)
    if s and isSelf(s) then return end
    local text = tostring(msg or '')
    if trim(text) == '' and not s then return end
    local info = snapshot(s)

    if text:find('Script died due to an error', 1, true) then
        local file = info and info.file or ''
        for _, c in ipairs(crashes) do
            if c.file:lower() == file:lower() and os.time() - (c.last or 0) <= 3 then return end
        end
        if file == '' then return end
        text = 'Script died due to an error (сама ошибка в лог не попала)'
    end

    local c = buildCrash(text, info)
    local entry, isNew = addCrash(c)
    if isNew then notifyCrash(entry, entry.count > 1) end
end

function onSystemMessage(msg, msgType, s)
    if msgType ~= MSG_ERROR and not (s and tostring(msg):find('[Ee]xception 0x%x+')) then return end
    local ok, err = pcall(handleError, msg, s)
    if not ok then print('[MoonDoctor] не смог разобрать ошибку: ' .. tostring(err)) end
end

local function parseLogTime(stamp)
    local h, m, s = stamp:match('^(%d+):(%d+):(%d+)')
    if not h then return os.time() end
    local t = os.date('*t')
    t.hour, t.min, t.sec = tonumber(h), tonumber(m), tonumber(s)
    local res = os.time(t)
    if res > os.time() + 60 then res = res - 86400 end
    return res
end

local function readLogTail(path, maxBytes)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local size = f:seek('end')
    if size > maxBytes then
        f:seek('set', size - maxBytes)
        f:read('*l')
    else
        f:seek('set', 0)
    end
    local data = f:read('*a')
    f:close()
    return data
end

local function scanStartupLog()
    local data = readLogTail(ML_DIR .. '\\moonloader.log', 3 * 1024 * 1024)
    if not data then return 0 end
    local mlv = data:match('MoonLoader (v%.[%w%.%-]+)')
    if mlv then env.mlFull = mlv end

    local me = (scriptField(thisScript(), 'filename') or 'MoonDoctor.lua'):lower()
    local found, cur = 0, nil
    local function flush()
        if not cur then return end
        local text = table.concat(cur.lines, '\n')
        local who = toU8(cur.who or '')
        local isMe = who:lower() == 'moondoctor' or who:lower() == toU8(me)
        if not isMe and not text:find('Script died due to an error', 1, true) and trim(text) ~= '' then
            local info = { file = '', name = who, path = '', version = '' }
            if who:lower():find('%.luac?$') then info.file = who end
            local c = buildCrash(text, info)
            c.first, c.last = cur.time, cur.time
            local entry, isNew = addCrash(c, true)
            if isNew then
                found = found + 1
                entry.fromLog = true
            end
        end
        cur = nil
    end

    for line in (data .. '\n'):gmatch('([^\n]*)\n') do
        line = line:gsub('\r$', '')
        local stamp, tag, rest = line:match('^%[([^%]]*)%]%s*%((%a+)%)%s*(.*)$')
        if stamp then
            flush()
            if tag == 'error' then
                local who, msg = rest:match('^(.-):%s(.*)$')
                cur = { who = who, time = parseLogTime(stamp), lines = { msg or rest } }
            end
        elseif cur then
            cur.lines[#cur.lines + 1] = line
        end
    end
    flush()
    return found
end

local DEMO_LINES = {
    [38] = '-- ник игрока из диалога статистики',
    [39] = 'function sampev.onShowDialog(id, style, title, b1, b2, text)',
    [40] = '    if not title:find("Статистика") then return end',
    [41] = '    local data = text:match("Имя: (%w+_%w+)")',
    [42] = '    local nick = data:gsub("_", " ")',
    [43] = '    sampAddChatMessage("Привет, " .. nick, -1)',
    [44] = 'end',
}

local function addDemoCrash()
    local raw = table.concat({
        "...\\moonloader\\helper_example.lua:42: attempt to index local 'data' (a nil value)",
        'stack traceback:',
        "\t...\\moonloader\\helper_example.lua:42: in function 'onShowDialog'",
        "\t...\\moonloader\\lib\\samp\\events\\core.lua:79: in function <...\\moonloader\\lib\\samp\\events\\core.lua:53>",
    }, '\n')
    local c = buildCrash(raw, { file = 'helper_example.lua', name = 'Helper (пример)', version = '2.3', path = '' })
    c.demo = true
    c.demoLines = DEMO_LINES
    c.sig = c.sig .. '|demo' .. os.time()
    c.unread = false
    addCrash(c)
    crashesDirty = false
    return c
end

local toggleWindow

do

local stacks = { color = 0, var = 0, font = 0, child = 0, width = 0 }

local function pushColor(idx, col) imgui.PushStyleColor(idx, col) stacks.color = stacks.color + 1 end
local function popColor(n) n = n or 1 imgui.PopStyleColor(n) stacks.color = stacks.color - n end
local function pushVarFloat(idx, v) imgui.PushStyleVarFloat(idx, v) stacks.var = stacks.var + 1 end
local function pushVarVec2(idx, v) imgui.PushStyleVarVec2(idx, v) stacks.var = stacks.var + 1 end
local function popVar(n) n = n or 1 imgui.PopStyleVar(n) stacks.var = stacks.var - n end
local function beginChild(id, size, border, flags)
    imgui.BeginChild(id, size, border or false, flags or 0)
    stacks.child = stacks.child + 1
end
local function endChild() imgui.EndChild() stacks.child = stacks.child - 1 end

local function openMark()
    return { color = stacks.color, var = stacks.var, font = stacks.font, child = stacks.child, width = stacks.width }
end

local function unwindTo(mark)
    while stacks.width > mark.width do imgui.PopItemWidth() stacks.width = stacks.width - 1 end
    while stacks.font > mark.font do imgui.PopFont() stacks.font = stacks.font - 1 end
    if stacks.color > mark.color then popColor(stacks.color - mark.color) end
    if stacks.var > mark.var then popVar(stacks.var - mark.var) end
    while stacks.child > mark.child do endChild() end
end

local C = {}

local function vec(x, y) return imgui.ImVec2(x, y) end
local function rgba(r, g, b, a) return imgui.ImVec4(r / 255, g / 255, b / 255, a or 1) end
local function px(v) return v * ui.scale end

local function initColors()
    C.bg = rgba(20, 22, 27)
    C.side = rgba(15, 17, 21)
    C.card = rgba(28, 31, 38)
    C.cardHi = rgba(36, 40, 48)
    C.line = rgba(40, 44, 53)
    C.code = rgba(13, 15, 19)
    C.text = rgba(230, 232, 236)
    C.muted = rgba(141, 147, 158)
    C.faint = rgba(96, 102, 114)
    C.accent = rgba(46, 196, 160)
    C.accentHi = rgba(72, 214, 180)
    C.accentLo = rgba(36, 166, 136)
    C.onAccent = rgba(8, 30, 25)
    C.red = rgba(239, 83, 80)
    C.yellow = rgba(242, 184, 75)
    C.green = rgba(76, 195, 138)
    C.blue = rgba(96, 156, 255)
    C.none = rgba(0, 0, 0, 0)
end

local function levelColor(level)
    if level == 'red' then return C.red end
    if level == 'yellow' then return C.yellow end
    if level == 'green' then return C.green end
    if level == 'info' then return C.blue end
    return C.accent
end

local function u32(col, alpha)
    local a = col.w * (alpha or 1) * imgui.GetStyle().Alpha
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(col.x, col.y, col.z, a))
end

local function winFont(...)
    local dir = getFolderPath(0x14)
    if not dir then return nil end
    for _, name in ipairs({ ... }) do
        local p = dir .. '\\' .. name
        if doesFileExist(p) then return p end
    end
end

local function glyphRanges(atlas)
    local ok, ranges = pcall(function()
        local builder = imgui.ImFontGlyphRangesBuilder()
        builder:AddRanges(atlas:GetGlyphRangesCyrillic())
        builder:AddText('‚„…†‡€‰‹‘’“”•–—™›№«»±×≈→←')
        ui.glyphs = imgui.ImVector_ImWchar()
        builder:BuildRanges(ui.glyphs)
        return ui.glyphs[0].Data
    end)
    return ok and ranges or atlas:GetGlyphRangesCyrillic()
end

local function loadFonts()
    local atlas = imgui.GetIO().Fonts
    local regular = winFont('segoeui.ttf', 'tahoma.ttf', 'arial.ttf')
    if not regular then return end
    local bold = winFont('segoeuib.ttf', 'tahomabd.ttf', 'arialbd.ttf') or regular
    local mono = winFont('consola.ttf', 'cour.ttf', 'lucon.ttf') or regular
    local ranges = glyphRanges(atlas)
    local s = ui.scale / ui.fontK
    atlas:Clear()
    ui.fonts.regular = atlas:AddFontFromFileTTF(regular, 15 * s, nil, ranges)
    ui.fonts.small = atlas:AddFontFromFileTTF(regular, 13 * s, nil, ranges)
    ui.fonts.bold = atlas:AddFontFromFileTTF(bold, 15 * s, nil, ranges)
    ui.fonts.title = atlas:AddFontFromFileTTF(bold, 21 * s, nil, ranges)
    ui.fonts.mono = atlas:AddFontFromFileTTF(mono, 14 * s, nil, ranges)
end

local function applyTheme()
    local style = imgui.GetStyle()
    local s = ui.scale / ui.styleK
    style.WindowRounding = 10 * s
    style.ChildRounding = 8 * s
    style.FrameRounding = 6 * s
    style.PopupRounding = 8 * s
    style.ScrollbarRounding = 8 * s
    style.GrabRounding = 6 * s
    style.WindowBorderSize = 1
    style.ChildBorderSize = 0
    style.FrameBorderSize = 0
    style.PopupBorderSize = 1
    style.WindowPadding = vec(14 * s, 14 * s)
    style.FramePadding = vec(10 * s, 6 * s)
    style.ItemSpacing = vec(8 * s, 8 * s)
    style.ItemInnerSpacing = vec(6 * s, 6 * s)
    style.ScrollbarSize = 10 * s
    style.GrabMinSize = 12 * s
    style.ButtonTextAlign = vec(0.5, 0.5)

    local col = style.Colors
    local K = imgui.Col
    col[K.Text] = C.text
    col[K.TextDisabled] = C.faint
    col[K.WindowBg] = C.bg
    col[K.ChildBg] = C.none
    col[K.PopupBg] = C.card
    col[K.Border] = C.line
    col[K.BorderShadow] = C.none
    col[K.FrameBg] = rgba(34, 38, 46)
    col[K.FrameBgHovered] = rgba(40, 45, 54)
    col[K.FrameBgActive] = rgba(46, 51, 61)
    col[K.TitleBg] = C.side
    col[K.TitleBgActive] = C.side
    col[K.TitleBgCollapsed] = C.side
    col[K.ScrollbarBg] = C.none
    col[K.ScrollbarGrab] = rgba(48, 53, 63)
    col[K.ScrollbarGrabHovered] = rgba(60, 66, 78)
    col[K.ScrollbarGrabActive] = rgba(70, 77, 90)
    col[K.CheckMark] = C.accent
    col[K.SliderGrab] = C.accent
    col[K.SliderGrabActive] = C.accentHi
    col[K.Button] = rgba(38, 42, 51)
    col[K.ButtonHovered] = rgba(47, 52, 63)
    col[K.ButtonActive] = rgba(56, 62, 75)
    col[K.Header] = rgba(38, 42, 51)
    col[K.HeaderHovered] = rgba(47, 52, 63)
    col[K.HeaderActive] = rgba(56, 62, 75)
    col[K.Separator] = C.line
    col[K.ResizeGrip] = C.none
    col[K.ResizeGripHovered] = rgba(46, 196, 160, 0.4)
    col[K.ResizeGripActive] = C.accent
    col[K.PlotHistogram] = C.accent
    col[K.PlotHistogramHovered] = C.accentHi
    col[K.TextSelectedBg] = rgba(46, 196, 160, 0.3)
end

local function pushFont(name)
    local f = ui.fonts[name]
    if f then
        imgui.PushFont(f)
        stacks.font = stacks.font + 1
    end
    return f ~= nil
end

local function popFont(pushed)
    if pushed then
        imgui.PopFont()
        stacks.font = stacks.font - 1
    end
end

local function text(s, col)
    if col then pushColor(imgui.Col.Text, col) end
    imgui.TextUnformatted(s)
    if col then popColor(1) end
end

local function wrapped(s, col)
    local own = ui.wrapDepth == 0
    if own then imgui.PushTextWrapPos(0) end
    text(s, col)
    if own then imgui.PopTextWrapPos() end
end

local function small(s, col)
    local p = pushFont('small')
    wrapped(s, col or C.muted)
    popFont(p)
end

local function label(s)
    local p = pushFont('small')
    text(s, C.faint)
    popFont(p)
end

local function hand()
    if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
end

local function tooltip(s)
    if not s or not imgui.IsItemHovered() then return end
    imgui.BeginTooltip()
    imgui.PushTextWrapPos(px(340))
    imgui.TextUnformatted(s)
    imgui.PopTextWrapPos()
    imgui.EndTooltip()
end

local function ellipsize(s, maxW)
    if maxW <= 0 then return '' end
    if imgui.CalcTextSize(s).x <= maxW then return s end
    local chars = utf8Chars(s)
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if imgui.CalcTextSize(table.concat(chars, '', 1, mid) .. '...').x <= maxW then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, '', 1, lo) .. '...'
end

local function flash(key, seconds)
    ui.flash[key] = localClock() + (seconds or 2)
end

local function flashing(key)
    return ui.flash[key] and localClock() < ui.flash[key]
end

local function buttonWidth(label)
    return imgui.CalcTextSize(label, nil, true).x + imgui.GetStyle().FramePadding.x * 2
end

local function button(label, w, kind, h)
    local pushed = 0
    if kind == 'primary' then
        pushColor(imgui.Col.Button, C.accent)
        pushColor(imgui.Col.ButtonHovered, C.accentHi)
        pushColor(imgui.Col.ButtonActive, C.accentLo)
        pushColor(imgui.Col.Text, C.onAccent)
        pushed = 4
    elseif kind == 'danger' then
        pushColor(imgui.Col.Button, rgba(239, 83, 80, 0.16))
        pushColor(imgui.Col.ButtonHovered, rgba(239, 83, 80, 0.28))
        pushColor(imgui.Col.ButtonActive, rgba(239, 83, 80, 0.4))
        pushColor(imgui.Col.Text, rgba(255, 140, 136))
        pushed = 4
    elseif kind == 'ghost' then
        pushColor(imgui.Col.Button, C.none)
        pushColor(imgui.Col.ButtonHovered, rgba(255, 255, 255, 0.06))
        pushColor(imgui.Col.ButtonActive, rgba(255, 255, 255, 0.1))
        pushColor(imgui.Col.Text, C.muted)
        pushed = 4
    end
    local clicked = imgui.Button(label, vec(w or 0, h or px(30)))
    hand()
    if pushed > 0 then popColor(pushed) end
    return clicked
end

local function buttonOff(label, w, h, tip)
    pushVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
    imgui.Button(label, vec(w or 0, h or px(30)))
    popVar(1)
    tooltip(tip)
end

local row = {}
local function rowBegin()
    row.limit = imgui.GetContentRegionAvail().x
    row.used = nil
end

local function rowPlace(w)
    local sp = imgui.GetStyle().ItemSpacing.x
    if row.used and row.used + sp + w <= row.limit then
        imgui.SameLine()
        row.used = row.used + sp + w
    else
        row.used = w
    end
end

local function rowButton(label, kind, tip)
    local w = buttonWidth(label)
    rowPlace(w)
    local clicked = button(label, w, kind)
    tooltip(tip)
    return clicked
end

local function dot(col, r)
    local p = imgui.GetCursorScreenPos()
    local h = imgui.GetTextLineHeight()
    r = r or px(4)
    imgui.GetWindowDrawList():AddCircleFilled(vec(p.x + r, p.y + h / 2), r, u32(col), 16)
    imgui.Dummy(vec(r * 2, h))
end

local function pill(s, col)
    local p = imgui.GetCursorScreenPos()
    local f = pushFont('small')
    local ts = imgui.CalcTextSize(s)
    local padX, padY = px(8), px(3)
    local w, h = ts.x + padX * 2, ts.y + padY * 2
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(col, 0.16), h / 2)
    dl:AddText(vec(p.x + padX, p.y + padY), u32(col), s)
    popFont(f)
    imgui.Dummy(vec(w, h))
end

local function checkMark(cx, cy, r, col)
    local dl = imgui.GetWindowDrawList()
    dl:AddCircleFilled(vec(cx, cy), r, u32(col, 0.16), 32)
    local s = r / 10
    dl:AddLine(vec(cx - 4.2 * s, cy + 0.2 * s), vec(cx - 1.2 * s, cy + 3.4 * s), u32(col), 2.2 * s)
    dl:AddLine(vec(cx - 1.2 * s, cy + 3.4 * s), vec(cx + 4.8 * s, cy - 3.2 * s), u32(col), 2.2 * s)
end

local cardStack = {}

local function beginCard(id, accent, bg)
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local h = ui.cardH[id]
    local dl = imgui.GetWindowDrawList()
    local pad = px(14)
    local bar = accent and px(4) or 0
    if h and h > 0 then
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(bg or C.card), px(8))
        if accent then
            dl:AddRectFilled(vec(p.x + px(6), p.y + px(12)), vec(p.x + px(9), p.y + h - px(12)), u32(accent), px(2))
        end
    end
    cardStack[#cardStack + 1] = { id = id, y = p.y, pad = pad, indent = pad + bar, inner = w - pad * 2 - bar }
    imgui.SetCursorPosY(imgui.GetCursorPosY() + pad)
    imgui.Indent(pad + bar)
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + w - pad * 2 - bar)
    ui.wrapDepth = ui.wrapDepth + 1
end

local function cardInner()
    local top = cardStack[#cardStack]
    return top and top.inner or imgui.GetContentRegionAvail().x
end

local function endCard()
    local top = table.remove(cardStack)
    ui.wrapDepth = ui.wrapDepth - 1
    imgui.PopTextWrapPos()
    imgui.Unindent(top.indent)
    local spacing = imgui.GetStyle().ItemSpacing.y
    imgui.Dummy(vec(0, math.max(0, top.pad - spacing)))
    ui.cardH[top.id] = imgui.GetCursorScreenPos().y - spacing - top.y
end

local function foldout(id, s)
    local open = ui.folds[id]
    local p = imgui.GetCursorScreenPos()
    local h = imgui.GetTextLineHeight()
    local w = imgui.CalcTextSize(s).x + px(20)
    if imgui.InvisibleButton('##fold' .. id, vec(w, h)) then
        open = not open
        ui.folds[id] = open
    end
    hand()
    local col = u32(imgui.IsItemHovered() and C.text or C.muted)
    local dl = imgui.GetWindowDrawList()
    local cx, cy, r = p.x + px(5), p.y + h / 2, px(4)
    if open then
        dl:AddTriangleFilled(vec(cx - r, cy - r * 0.5), vec(cx + r, cy - r * 0.5), vec(cx, cy + r * 0.6), col)
    else
        dl:AddTriangleFilled(vec(cx - r * 0.5, cy - r), vec(cx + r * 0.6, cy), vec(cx - r * 0.5, cy + r), col)
    end
    dl:AddText(vec(p.x + px(16), p.y), col, s)
    return open
end

local function numbered(i, s)
    local ind = px(22)
    imgui.Indent(ind)
    local p = imgui.GetCursorScreenPos()
    local b = pushFont('bold')
    imgui.GetWindowDrawList():AddText(vec(p.x - ind, p.y), u32(C.accent), i .. '.')
    popFont(b)
    wrapped(s)
    imgui.Unindent(ind)
end

local function bullet(s, col)
    local ind = px(16)
    imgui.Indent(ind)
    local p = imgui.GetCursorScreenPos()
    local h = imgui.GetTextLineHeight()
    imgui.GetWindowDrawList():AddCircleFilled(vec(p.x - ind + px(5), p.y + h / 2), px(2), u32(col or C.faint), 8)
    wrapped(s, col)
    imgui.Unindent(ind)
end

local function backLink(s)
    local p = imgui.GetCursorScreenPos()
    local h = imgui.GetTextLineHeight()
    local w = imgui.CalcTextSize(s).x + px(20)
    local clicked = imgui.InvisibleButton('##back', vec(w, h))
    hand()
    local col = u32(imgui.IsItemHovered() and C.text or C.muted)
    local dl = imgui.GetWindowDrawList()
    local cy = p.y + h / 2
    dl:AddLine(vec(p.x + px(1), cy), vec(p.x + px(11), cy), col, px(1.6))
    dl:AddLine(vec(p.x + px(1), cy), vec(p.x + px(5), cy - px(4)), col, px(1.6))
    dl:AddLine(vec(p.x + px(1), cy), vec(p.x + px(5), cy + px(4)), col, px(1.6))
    dl:AddText(vec(p.x + px(18), p.y), col, s)
    return clicked
end

local function pageHeader(title, sub, actions)
    local startX, startY = imgui.GetCursorPosX(), imgui.GetCursorPosY()
    local availW = imgui.GetContentRegionAvail().x
    local t = pushFont('title')
    text(title)
    popFont(t)
    local afterY = imgui.GetCursorPosY()
    if actions and #actions > 0 then
        local total = 0
        for _, a in ipairs(actions) do total = total + buttonWidth(a.label) end
        total = total + (#actions - 1) * imgui.GetStyle().ItemSpacing.x
        imgui.SetCursorPos(vec(startX + availW - total, startY - px(2)))
        for i, a in ipairs(actions) do
            if i > 1 then imgui.SameLine() end
            if a.off then
                buttonOff(a.label, buttonWidth(a.label), nil, a.tip)
            else
                if button(a.label, buttonWidth(a.label), a.kind) then a.fn() end
                tooltip(a.tip)
            end
        end
        imgui.SetCursorPos(vec(startX, afterY))
    end
    if sub then
        imgui.PushTextWrapPos(startX + availW - px(4))
        text(sub, C.muted)
        imgui.PopTextWrapPos()
    end
    imgui.Dummy(vec(0, px(6)))
end

local function drawPulse(dl, x, y, w, h, col, thick)
    local pts = { { 0, 0.55 }, { 0.28, 0.55 }, { 0.38, 0.1 }, { 0.52, 1 }, { 0.64, 0.3 }, { 0.72, 0.55 }, { 1, 0.55 } }
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        dl:AddLine(vec(x + a[1] * w, y + a[2] * h), vec(x + b[1] * w, y + b[2] * h), col, thick or px(2))
    end
end

local function drawIcon(kind, dl, cx, cy, col)
    local s = px(1)
    if kind == 'crash' then
        dl:AddCircle(vec(cx, cy), 7 * s, col, 24, 1.6 * s)
        dl:AddLine(vec(cx, cy - 3.6 * s), vec(cx, cy + 0.8 * s), col, 1.8 * s)
        dl:AddCircleFilled(vec(cx, cy + 3.4 * s), 1.1 * s, col, 8)
    elseif kind == 'fps' then
        dl:AddRectFilled(vec(cx - 6.5 * s, cy + 1 * s), vec(cx - 3.5 * s, cy + 6.5 * s), col, 1 * s)
        dl:AddRectFilled(vec(cx - 1.5 * s, cy - 2.5 * s), vec(cx + 1.5 * s, cy + 6.5 * s), col, 1 * s)
        dl:AddRectFilled(vec(cx + 3.5 * s, cy - 6.5 * s), vec(cx + 6.5 * s, cy + 6.5 * s), col, 1 * s)
    elseif kind == 'conflict' then
        dl:AddCircle(vec(cx - 2.7 * s, cy), 4.8 * s, col, 20, 1.6 * s)
        dl:AddCircle(vec(cx + 2.7 * s, cy), 4.8 * s, col, 20, 1.6 * s)
    elseif kind == 'scripts' then
        for i = -1, 1 do
            dl:AddCircleFilled(vec(cx - 5 * s, cy + i * 4.6 * s), 1.3 * s, col, 8)
            dl:AddLine(vec(cx - 2 * s, cy + i * 4.6 * s), vec(cx + 6.5 * s, cy + i * 4.6 * s), col, 1.6 * s)
        end
    elseif kind == 'settings' then
        dl:AddLine(vec(cx - 6.5 * s, cy - 3.2 * s), vec(cx + 6.5 * s, cy - 3.2 * s), col, 1.6 * s)
        dl:AddLine(vec(cx - 6.5 * s, cy + 3.6 * s), vec(cx + 6.5 * s, cy + 3.6 * s), col, 1.6 * s)
        dl:AddCircleFilled(vec(cx + 2.6 * s, cy - 3.2 * s), 2.5 * s, col, 12)
        dl:AddCircleFilled(vec(cx - 2.6 * s, cy + 3.6 * s), 2.5 * s, col, 12)
    elseif kind == 'help' then
        dl:AddCircle(vec(cx, cy), 7 * s, col, 24, 1.6 * s)
        local b = pushFont('small')
        local ts = imgui.CalcTextSize('?')
        dl:AddText(vec(cx - ts.x / 2, cy - ts.y / 2), col, '?')
        popFont(b)
    end
end

local NAV = {
    { id = 'crashes', label = 'Краши', icon = 'crash' },
    { id = 'fps', label = 'Нагрузка', icon = 'fps' },
    { id = 'conflicts', label = 'Конфликты', icon = 'conflict' },
    { id = 'scripts', label = 'Скрипты', icon = 'scripts' },
    { id = 'settings', label = 'Настройки', icon = 'settings' },
    { id = 'help', label = 'Справка', icon = 'help' },
}

local function unreadCount()
    local n = 0
    for _, c in ipairs(crashes) do
        if c.unread then n = n + 1 end
    end
    return n
end

local function navBadge(id)
    if id == 'crashes' then
        local n = unreadCount()
        if n > 0 then return tostring(n), C.red end
    elseif id == 'conflicts' and scan.done then
        local n = scan.counts.red + scan.counts.yellow
        if n > 0 then return tostring(n), scan.counts.red > 0 and C.red or C.yellow end
    elseif id == 'fps' and fps.running then
        return 'идёт', C.accent
    end
end

local function switchPage(id)
    if ui.page == id then
        if id == 'crashes' then ui.crashView = 'list' end
        return
    end
    ui.page = id
    ui.pageAlpha = 0
    ui.pageError = nil
    if id == 'conflicts' and not scan.done and not scan.running then runScan() end
end

local function drawHeader(w)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local h = px(54)
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(C.side), px(10), 3)
    dl:AddLine(vec(p.x, p.y + h), vec(p.x + w, p.y + h), u32(C.line), 1)

    local cx, cy = p.x + px(30), p.y + h / 2
    dl:AddCircleFilled(vec(cx, cy), px(16), u32(C.accent, 0.14), 32)
    drawPulse(dl, cx - px(10), cy - px(7), px(20), px(14), u32(C.accent))

    local t = pushFont('title')
    local th = imgui.GetTextLineHeight()
    dl:AddText(vec(p.x + px(56), cy - th / 2), u32(C.text), 'MoonDoctor')
    local tw = imgui.CalcTextSize('MoonDoctor').x
    popFont(t)

    local sm = pushFont('small')
    local sh = imgui.GetTextLineHeight()
    dl:AddText(vec(p.x + px(56) + tw + px(8), cy - sh / 2 + px(2)), u32(C.faint), 'v' .. VERSION)
    local envText = 'MoonLoader ' .. mlVersion() .. '  ·  SA-MP ' .. (sampVersion() or 'нет')
    if not sfLoaded() then envText = envText .. '  ·  без SAMPFUNCS' end
    local ew = imgui.CalcTextSize(envText).x
    if p.x + w - px(60) - ew > p.x + px(56) + tw + px(60) then
        dl:AddText(vec(p.x + w - px(58) - ew, cy - sh / 2), u32(C.faint), envText)
    end
    popFont(sm)

    local bs = px(30)
    local bx, by = p.x + w - px(14) - bs, cy - bs / 2
    imgui.SetCursorScreenPos(vec(bx, by))
    if imgui.InvisibleButton('##close', vec(bs, bs)) then ui.show[0] = false end
    hand()
    local hov = imgui.IsItemHovered()
    local mx, my, r = bx + bs / 2, by + bs / 2, px(5)
    if hov then dl:AddCircleFilled(vec(mx, my), bs / 2, u32(C.red, 0.18), 24) end
    local xc = u32(hov and C.red or C.muted)
    dl:AddLine(vec(mx - r, my - r), vec(mx + r, my + r), xc, px(1.7))
    dl:AddLine(vec(mx + r, my - r), vec(mx - r, my + r), xc, px(1.7))

    imgui.SetCursorScreenPos(vec(p.x, p.y + h))
    return h
end

local function navItem(item, y, w)
    imgui.SetCursorPos(vec(px(10), y))
    local p = imgui.GetCursorScreenPos()
    local iw, h = w - px(20), px(38)
    local clicked = imgui.InvisibleButton('##nav' .. item.id, vec(iw, h))
    hand()
    local hovered = imgui.IsItemHovered()
    local active = ui.page == item.id
    local dl = imgui.GetWindowDrawList()

    local t = ui.navAnim[item.id] or 0
    local target = active and 1 or (hovered and 1 or 0)
    t = t + (target - t) * math.min(1, imgui.GetIO().DeltaTime * 14)
    ui.navAnim[item.id] = t
    if t > 0.01 then
        dl:AddRectFilled(p, vec(p.x + iw, p.y + h), u32(active and rgba(46, 196, 160, 0.13) or C.cardHi, t), px(7))
    end
    if active then
        dl:AddRectFilled(vec(p.x, p.y + px(10)), vec(p.x + px(3), p.y + h - px(10)), u32(C.accent), px(2))
    end

    local col = (active or hovered) and C.text or C.muted
    drawIcon(item.icon, dl, p.x + px(22), p.y + h / 2, u32(active and C.accent or col))
    local th = imgui.GetTextLineHeight()
    dl:AddText(vec(p.x + px(42), p.y + (h - th) / 2), u32(col), item.label)

    local badge, bcol = navBadge(item.id)
    if badge then
        local f = pushFont('small')
        local ts = imgui.CalcTextSize(badge)
        local bw, bh = math.max(ts.x + px(12), px(22)), ts.y + px(4)
        local bx, by = p.x + iw - px(10) - bw, p.y + (h - bh) / 2
        dl:AddRectFilled(vec(bx, by), vec(bx + bw, by + bh), u32(bcol, 0.2), bh / 2)
        dl:AddText(vec(bx + (bw - ts.x) / 2, by + px(2)), u32(bcol), badge)
        popFont(f)
    end
    if clicked then switchPage(item.id) end
end

local function sidebarStatus(h)
    local dead = 0
    for _, c in ipairs(crashes) do
        if c.session == sessionStart and not c.demo and not runningScript(c.file) then dead = dead + 1 end
    end
    local red = scan.done and scan.counts.red or 0
    local col, title
    if dead > 0 then
        col, title = C.red, 'Не работают: ' .. dead
    elseif red > 0 then
        col, title = C.yellow, 'Конфликтов: ' .. red
    else
        col, title = C.green, 'Всё спокойно'
    end
    imgui.SetCursorPos(vec(px(20), h - px(58)))
    dot(col)
    imgui.SameLine(0, px(8))
    text(title, C.text)
    imgui.SetCursorPos(vec(px(20), h - px(34)))
    label('Открыть: ' .. openText())
end

local function drawSidebar(w, h)
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(C.side), px(10), 4)
    dl:AddLine(vec(p.x + w, p.y), vec(p.x + w, p.y + h), u32(C.line), 1)
    beginChild('##side', vec(w, h), false, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
    local y = px(14)
    for _, item in ipairs(NAV) do
        navItem(item, y, w)
        y = y + px(42)
    end
    if h > px(400) then sidebarStatus(h) end
    endChild()
end

local PAGES = {}

do

local function emptyState(title, sub, buttonLabel, fn)
    local avail = imgui.GetContentRegionAvail()
    local p = imgui.GetCursorScreenPos()
    local top = math.max(px(30), avail.y * 0.22)
    checkMark(p.x + avail.x / 2, p.y + top, px(30), C.green)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + top + px(46))
    local t = pushFont('title')
    local tw = imgui.CalcTextSize(title).x
    imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail.x - tw) / 2)
    text(title)
    popFont(t)
    local maxW = math.min(avail.x, px(440))
    local x0 = imgui.GetCursorPosX() + (avail.x - maxW) / 2
    imgui.SetCursorPosX(x0)
    imgui.PushTextWrapPos(x0 + maxW)
    text(sub, C.muted)
    imgui.PopTextWrapPos()
    if buttonLabel then
        imgui.Dummy(vec(0, px(6)))
        local bw = buttonWidth(buttonLabel)
        imgui.SetCursorPosX(imgui.GetCursorPosX() + (avail.x - bw) / 2)
        if button(buttonLabel, bw) then fn() end
    end
end

local function crashItem(c)
    local w = imgui.GetContentRegionAvail().x
    local h = px(62)
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton('##crash' .. c.id, vec(w, h))
    hand()
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(hovered and C.cardHi or C.card), px(8))
    if c.unread then
        dl:AddRectFilled(vec(p.x + px(6), p.y + px(14)), vec(p.x + px(9), p.y + h - px(14)), u32(C.red), px(2))
    end

    local ex = explain(c)
    local alive = runningScript(c.file) ~= nil
    local x, right = p.x + px(20), p.x + w - px(16)
    local y1, y2 = p.y + px(10), p.y + px(34)

    local sm = pushFont('small')
    local when = whenText(c.last)
    local whenW = imgui.CalcTextSize(when).x
    dl:AddText(vec(right - whenW, y1 + px(2)), u32(C.faint), when)
    popFont(sm)

    local b = pushFont('bold')
    local lh = imgui.GetTextLineHeight()
    local statusCol = c.demo and C.blue or (alive and C.green or C.red)
    dl:AddCircleFilled(vec(x + px(4), y1 + lh / 2), px(4), u32(statusCol), 12)
    dl:AddText(vec(x + px(16), y1), u32(C.text), ellipsize(c.file, right - whenW - x - px(40)))
    popFont(b)

    sm = pushFont('small')
    local status = c.demo and 'пример' or (alive and 'работает' or 'не работает')
    if (c.count or 1) > 1 then status = 'x' .. c.count .. '   ' .. status end
    local stW = imgui.CalcTextSize(status).x
    dl:AddText(vec(right - stW, y2 + px(1)), u32(c.demo and C.blue or (alive and C.muted or C.red)), status)
    dl:AddText(vec(x + px(16), y2 + px(1)), u32(C.muted), ellipsize(capitalize(ex.short), right - stW - x - px(40)))
    popFont(sm)

    if clicked then openCrash(c) end
end

local function crashList()
    local actions = {}
    if #crashes > 0 then
        actions[1] = { label = 'Очистить', kind = 'ghost', tip = 'Убрать всю историю крашей. Сами скрипты это не трогает.', fn = function()
            crashes, crashById = {}, {}
            ui.selected = nil
            crashesDirty = true
        end }
    end
    pageHeader('Краши', #crashes > 0 and 'Нажми на краш, чтобы увидеть, что случилось и что с этим делать.' or nil, actions)

    if #crashes == 0 then
        emptyState('Пока ни одного краша', 'Если какой-нибудь скрипт упадёт, здесь появится понятное объяснение и готовый отчёт для автора.', 'Показать пример', function()
            openCrash(addDemoCrash())
        end)
        return
    end

    beginChild('##crashlist', vec(0, 0), false)
    local shownCurrent, shownOld = false, false
    for _, c in ipairs(crashes) do
        if c.session == sessionStart then
            if not shownCurrent then
                label('В ЭТОЙ ИГРЕ')
                shownCurrent = true
            end
            crashItem(c)
        end
    end
    for _, c in ipairs(crashes) do
        if c.session ~= sessionStart then
            if not shownOld then
                if shownCurrent then imgui.Dummy(vec(0, px(6))) end
                label('РАНЬШЕ')
                shownOld = true
            end
            crashItem(c)
        end
    end
    endChild()
end

local function codeBlock(c, lines, ex)
    local from, to = math.max(1, c.line - 2), c.line + 2
    if ex.originLine and ex.originLine < from and c.line - ex.originLine <= 6 then from = ex.originLine end
    local any = false
    for i = from, to do
        if lines[i] then any = true break end
    end
    if not any then return end

    beginCard('code' .. c.id, nil, C.code)
    label(string.format('КОД, СТРОКА %d', c.line))
    local m = pushFont('mono')
    local lh = imgui.GetTextLineHeight()
    local inner = cardInner()
    local dl = imgui.GetWindowDrawList()
    for i = from, to do
        local l = lines[i]
        if l then
            local p = imgui.GetCursorScreenPos()
            local isErr, isOrigin = i == c.line, i == ex.originLine
            if isErr then
                dl:AddRectFilled(vec(p.x - px(6), p.y - px(1)), vec(p.x + inner + px(6), p.y + lh + px(1)), u32(C.red, 0.16), px(4))
            elseif isOrigin then
                dl:AddRectFilled(vec(p.x - px(6), p.y - px(1)), vec(p.x + inner + px(6), p.y + lh + px(1)), u32(C.yellow, 0.10), px(4))
            end
            text(string.format('%4d', i), isErr and C.red or (isOrigin and C.yellow or C.faint))
            imgui.SameLine(0, px(14))
            text(prepCode(l, 110), (isErr or isOrigin) and C.text or C.muted)
        end
    end
    popFont(m)
    if ex.originLine and ex.originLine >= from and ex.originLine <= to and ex.originLine ~= c.line then
        small('Красным строка, где упало. Жёлтым строка, откуда пришло пустое значение.', C.faint)
    end
    endCard()
end

local function crashButtons(c)
    local list = {}
    list[#list + 1] = {
        label = flashing('copy') and 'Скопировано!###copy' or 'Скопировать отчёт для автора###copy',
        kind = 'primary',
        tip = 'Отчёт попадёт в буфер обмена. Дальше Ctrl+V в личку автору, в тему или в телеграм.',
        fn = function()
            copyText(buildReport(c, false))
            flash('copy')
        end,
    }
    list[#list + 1] = {
        label = flashing('forum') and 'Скопировано!###forum' or 'Для форума###forum',
        tip = 'То же самое, но текст ошибки завёрнут в [code], чтобы на форуме он не поплыл.',
        fn = function()
            copyText(buildReport(c, true))
            flash('forum')
        end,
    }
    list[#list + 1] = {
        label = flashing('save') and 'Сохранено!###save' or 'В файл###save',
        tip = ui.lastReport and ('Последний отчёт: ' .. ui.lastReport) or 'Отчёты складываются в moonloader\\config\\MoonDoctor\\reports.',
        fn = function()
            local ok, path = saveReport(c)
            if ok then
                ui.lastReport = path
                flash('save', 3)
            end
        end,
    }
    if not c.demo then
        local s = runningScript(c.file)
        if s then
            list[#list + 1] = {
                label = flashing('restart') and 'Перезапущен###restart' or 'Перезапустить###restart',
                tip = 'Скрипт сейчас работает. Можно перезапустить его, если он ведёт себя странно.',
                fn = function()
                    pcall(function() s:reload() end)
                    runningCache.time = -1
                    flash('restart')
                end,
            }
        elseif c.path ~= '' and doesFileExist(fromU8(c.path)) then
            list[#list + 1] = {
                label = flashing('restart') and 'Запущен###restart' or 'Запустить###restart',
                tip = 'Попробовать запустить скрипт ещё раз, не перезаходя в игру. Если причина не ушла, он упадёт снова.',
                fn = function()
                    pcall(script.load, fromU8(c.path))
                    runningCache.time = -1
                    flash('restart')
                end,
            }
        end
    end
    return list
end

local function crashDetail(c)
    local ex = explain(c)
    c.unread = false
    local lineY = imgui.GetCursorPosY()
    if backLink('Все краши') then
        ui.crashView = 'list'
        return
    end
    local removeLabel = 'Убрать из списка'
    local sm = pushFont('small')
    local rw = imgui.CalcTextSize(removeLabel).x + px(16)
    imgui.SetCursorPos(vec(imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x - rw, lineY - px(3)))
    pushVarVec2(imgui.StyleVar.FramePadding, vec(px(8), px(3)))
    local removed = button(removeLabel, rw, 'ghost', imgui.GetTextLineHeight() + px(6))
    popVar(1)
    popFont(sm)
    tooltip('Убрать этот краш из истории. Со скриптом ничего не случится.')
    if removed then
        removeCrash(c)
        ui.crashView = 'list'
        return
    end
    imgui.Dummy(vec(0, px(2)))

    local buttons = crashButtons(c)
    local avail = imgui.GetContentRegionAvail()
    local sp = imgui.GetStyle().ItemSpacing.x
    local total = 0
    for i, b in ipairs(buttons) do total = total + buttonWidth(b.label) + (i > 1 and sp or 0) end
    local footerH = total <= avail.x and px(48) or px(86)

    beginChild('##crashdetail', vec(0, avail.y - footerH), false)

    local t = pushFont('title')
    wrapped(ex.title)
    popFont(t)

    local parts = { whenText(c.last) }
    if (c.count or 1) > 1 then parts[#parts + 1] = string.format('всего %d %s', c.count, plural(c.count, 'раз', 'раза', 'раз')) end
    if c.version ~= '' then parts[#parts + 1] = 'версия ' .. c.version end
    if c.authors and c.authors ~= '' then parts[#parts + 1] = 'автор: ' .. c.authors end
    small(table.concat(parts, '  ·  '))

    if c.demo then
        pill('пример', C.blue)
        small('Это пример, на самом деле ничего не падало. Так будет выглядеть разбор настоящего краша.', C.faint)
    elseif runningScript(c.file) then
        pill('сейчас работает', C.green)
    else
        pill('сейчас не работает', C.red)
    end
    imgui.Dummy(vec(0, px(2)))

    if ex.repeatNote then
        beginCard('rep' .. c.id, C.yellow)
        wrapped(ex.repeatNote)
        endCard()
    end

    beginCard('what' .. c.id, C.red)
    label('ЧТО СЛУЧИЛОСЬ')
    wrapped(ex.what)
    endCard()

    beginCard('why' .. c.id)
    label('ПОЧЕМУ ТАК БЫВАЕТ')
    wrapped(ex.why)
    endCard()

    beginCard('todo' .. c.id, C.accent)
    label('ЧТО ДЕЛАТЬ')
    for i, s in ipairs(ex.todo) do numbered(i, s) end
    endCard()

    local lines = c.demoLines or sourceLines(c.path)
    if lines and c.line then codeBlock(c, lines, ex) end

    if foldout('raw' .. c.id, 'Полный текст ошибки') then
        beginCard('raw' .. c.id, nil, C.code)
        local m = pushFont('mono')
        local shown = #c.raw > 3000 and (cutText(c.raw, 3000) .. '\n\n(дальше обрезано, целиком текст есть в отчёте)') or c.raw
        wrapped(shown, C.muted)
        popFont(m)
        endCard()
    end
    if ex.dev and foldout('dev' .. c.id, 'Подсказка для автора скрипта') then
        beginCard('dev' .. c.id)
        wrapped(ex.dev, C.muted)
        endCard()
    end
    if c.url ~= '' and c.url:find('^https?://') then
        if foldout('url' .. c.id, 'Страница скрипта') then
            small(c.url)
            if button('Открыть в браузере', 0, nil, px(26)) then shellOpen(c.url) end
            tooltip('Игра свернётся, откроется браузер.')
        end
    end
    imgui.Dummy(vec(0, px(4)))
    endChild()

    local p = imgui.GetCursorScreenPos()
    imgui.GetWindowDrawList():AddLine(vec(p.x, p.y), vec(p.x + avail.x, p.y), u32(C.line), 1)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + px(9))
    rowBegin()
    for _, b in ipairs(buttons) do
        if rowButton(b.label, b.kind, b.tip) then b.fn() end
    end
end

PAGES.crashes = function()
    local c = ui.selected and crashById[ui.selected]
    if ui.crashView == 'detail' and c then
        crashDetail(c)
    else
        ui.crashView = 'list'
        crashList()
    end
end

end

do

local fpsInfoCache = { time = -10, count = 0, limiter = false }

local function fpsInfo()
    local now = localClock()
    if now - fpsInfoCache.time > 1 then
        fpsInfoCache.count = #fpsTargets()
        fpsInfoCache.limiter = frameLimiterOn()
        fpsInfoCache.time = now
    end
    return fpsInfoCache
end

local function fpsProgress()
    beginCard('fpsrun', C.accent)
    local elapsed = localClock() - fps.startedAt
    local frac = clamp(elapsed / math.max(1, fps.estimate), 0, 0.99)
    local status
    if fps.waiting then
        status = 'Жду, пока вернёшься в игру. Пока игра свёрнута или открыто меню, мерить нельзя.'
    elseif fps.phase == 'paused' then
        status = string.format('Сейчас на паузе: %s (%d из %d)', fps.current, fps.index, fps.total)
    elseif fps.phase == 'warmup' then
        status = 'Готовлюсь...'
    elseif fps.index > 0 and fps.current ~= '' then
        status = string.format('Меряю FPS со всеми скриптами (%d из %d)', fps.index, fps.total)
    else
        status = 'Последний замер со всеми скриптами...'
    end
    local b = pushFont('bold')
    wrapped(status)
    popFont(b)
    pushColor(imgui.Col.FrameBg, C.line)
    imgui.ProgressBar(frac, vec(cardInner(), px(6)), '')
    popColor(1)
    local left = math.max(0, round(fps.estimate - elapsed))
    small(string.format('Осталось около %d с. Стой на месте и не крути камеру, так замер честнее.', left))
    if button('Остановить', 0, 'danger') then stopFpsTest() end
    endCard()
end

local function fpsIntro()
    local info = fpsInfo()
    beginCard('fpsintro')
    wrapped('Я по очереди ставлю каждый скрипт на паузу на пару секунд и смотрю, насколько игре стало легче. Так видно, кто сколько FPS отъедает.')
    small('Пока идёт проверка, стой на месте, не крути камеру и не открывай диалоги. Скрипты при этом ненадолго замирают, так что лучше не запускать это в погоне или на работе.')
    imgui.Dummy(vec(0, px(2)))

    imgui.AlignTextToFramePadding()
    text('На каждый скрипт:')
    imgui.SameLine()
    imgui.PushItemWidth(px(150))
    stacks.width = stacks.width + 1
    if imgui.SliderInt('##sec', ui.secBuf, 1, 5, '%d с') then
        settings.measureSec = clamp(ui.secBuf[0], 1, 5)
        saveSettings()
    end
    imgui.PopItemWidth()
    stacks.width = stacks.width - 1
    imgui.SameLine()
    local total = estimateFpsTest(info.count, settings.measureSec)
    text(string.format('%d %s, займёт примерно %d с', info.count, plural(info.count, 'скрипт', 'скрипта', 'скриптов'), round(total)), C.muted)

    if info.limiter then
        imgui.Dummy(vec(0, px(2)))
        text('Включён Frame Limiter', C.yellow)
        small('FPS упирается в потолок, и разницу между скриптами почти не видно. Выключи его в настройках графики игры на время проверки.')
    end
    imgui.Dummy(vec(0, px(2)))
    if info.count == 0 then
        buttonOff('Проверить нагрузку', 0, nil, 'Нечего проверять: кроме меня, скриптов нет.')
    elseif button('Проверить нагрузку', 0, 'primary') then
        startFpsTest()
    end
    endCard()
end

local function fpsResults()
    local r = fps.results
    imgui.Dummy(vec(0, px(4)))
    label('РЕЗУЛЬТАТ')
    small(string.format('%s  ·  средний FPS со всеми скриптами: %d  ·  погрешность около ±%d',
        whenText(r.time), round(r.base), math.max(1, round(r.noise or 1))))
    imgui.Dummy(vec(0, px(2)))

    local maxDelta = 1
    for _, row in ipairs(r.rows) do
        if row.paused and not row.zero and row.delta > maxDelta then maxDelta = row.delta end
    end

    local w = imgui.GetContentRegionAvail().x
    local msX = w - px(64)
    local impactX = msX - px(128)
    local nameW = w * 0.36
    local barX = nameW + px(10)
    local barW = math.max(px(40), impactX - px(20) - barX)

    local dl = imgui.GetWindowDrawList()
    local p0 = imgui.GetCursorScreenPos()
    local sm = pushFont('small')
    dl:AddText(vec(p0.x + px(12), p0.y), u32(C.faint), 'СКРИПТ')
    dl:AddText(vec(p0.x + impactX, p0.y), u32(C.faint), 'ВЛИЯНИЕ НА FPS')
    dl:AddText(vec(p0.x + msX, p0.y), u32(C.faint), 'МС')
    imgui.Dummy(vec(w, imgui.GetTextLineHeight()))
    popFont(sm)

    for i, row in ipairs(r.rows) do
        local p = imgui.GetCursorScreenPos()
        local h = px(34)
        imgui.InvisibleButton('##fpsrow' .. i, vec(w, h))
        local hovered = imgui.IsItemHovered()
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(hovered and C.cardHi or C.card, (i % 2 == 0) and 0.55 or 0.85), px(6))
        local lh = imgui.GetTextLineHeight()
        local cy = p.y + h / 2

        local col = row.paused and levelColor(row.level) or C.faint
        dl:AddCircleFilled(vec(p.x + px(16), cy), px(4), u32(col), 12)
        local b = pushFont('bold')
        dl:AddText(vec(p.x + px(28), cy - lh / 2), u32(row.paused and C.text or C.muted), ellipsize(row.file, nameW - px(30)))
        popFont(b)

        if row.paused then
            dl:AddRectFilled(vec(p.x + barX, cy - px(3)), vec(p.x + barX + barW, cy + px(3)), u32(C.line), px(3))
            if not row.zero then
                local fw = math.max(px(4), barW * clamp(row.delta / maxDelta, 0, 1))
                dl:AddRectFilled(vec(p.x + barX, cy - px(3)), vec(p.x + barX + fw, cy + px(3)), u32(col), px(3))
            end
            local impact = row.zero and 'не влияет' or string.format('-%d FPS', round(row.delta))
            dl:AddText(vec(p.x + impactX, cy - lh / 2), u32(row.zero and C.muted or col), impact)
            local ms = row.zero and '≈0' or string.format('%.1f', row.ms)
            dl:AddText(vec(p.x + msX, cy - lh / 2), u32(C.muted), ms)
            if hovered then
                tooltip(string.format('С ним: %d FPS, без него: %d FPS.', round(row.base), round(row.paused)))
            end
        else
            local sm2 = pushFont('small')
            local sh = imgui.GetTextLineHeight()
            dl:AddText(vec(p.x + barX, cy - sh / 2), u32(C.faint), row.skip or 'пропущен')
            popFont(sm2)
        end
    end

    imgui.Dummy(vec(0, px(4)))
    local anyRed = false
    for _, row in ipairs(r.rows) do
        if row.level == 'red' then anyRed = true end
    end
    if r.capped then
        beginCard('fpscap', C.yellow)
        wrapped('Ни один скрипт не дал заметной разницы. Либо всё и так хорошо, либо FPS упирается в ограничение (/fpslimit в SA-MP или Frame Limiter в настройках игры). Сними ограничение и проверь ещё раз.')
        endCard()
    elseif anyRed then
        beginCard('fpsred', C.red)
        wrapped('Красным отмечено то, что заметно тормозит игру. Попробуй выключить такой скрипт на вкладке «Скрипты» и посмотри, стало ли лучше. Если скрипт нужен, поищи в его настройках, что можно отключить: обычно больше всего едят рендер на экране и проверки каждый кадр.')
        endCard()
    end
    small('Замер приблизительный. Скрипт, который рисует в отдельном потоке рендера, может показать чуть меньше, чем на самом деле.', C.faint)
    imgui.Dummy(vec(0, px(2)))
    if button(flashing('fpscopy') and 'Скопировано!###fpscopy' or 'Скопировать результат###fpscopy') then
        copyText(fpsResultsText())
        flash('fpscopy')
    end
end

PAGES.fps = function()
    pageHeader('Нагрузка', 'Кто из скриптов съедает FPS.')
    if fps.running then fpsProgress() else fpsIntro() end
    if fps.error and not fps.running then
        beginCard('fpserr', C.red)
        wrapped(fps.error)
        endCard()
    end
    if fps.results and type(fps.results.rows) == 'table' then fpsResults() end
end

end

do

local GROUP_TITLE = { commands = 'КОМАНДЫ', keys = 'КЛАВИШИ', libs = 'БИБЛИОТЕКИ', files = 'ФАЙЛЫ И ВЕРСИИ' }

PAGES.conflicts = function()
    local actions = {
        {
            label = scan.running and 'Проверяю...' or 'Проверить ещё раз',
            off = scan.running,
            fn = runScan,
            tip = 'Заново перечитать все скрипты в папке moonloader.',
        },
    }
    pageHeader('Конфликты', 'Одинаковые команды и клавиши, нехватка библиотек и файлы не на своём месте.', actions)

    if scan.running then
        pushColor(imgui.Col.FrameBg, C.line)
        imgui.ProgressBar(scan.progress, vec(-1, px(6)), '')
        popColor(1)
        small('Читаю скрипты...')
    end
    if scan.error then
        beginCard('scanerr', C.red)
        wrapped('Проверка сломалась: ' .. scan.error)
        endCard()
    end
    if not scan.done then return end

    local n = #scan.files
    small(string.format('Проверил %d %s, %s.', n, plural(n, 'скрипт', 'скрипта', 'скриптов'), whenText(scan.time)))
    if scan.counts.red > 0 then
        pill(scan.counts.red .. ' ' .. plural(scan.counts.red, 'проблема', 'проблемы', 'проблем'), C.red)
        imgui.SameLine()
    end
    if scan.counts.yellow > 0 then
        pill(scan.counts.yellow .. ' ' .. plural(scan.counts.yellow, 'предупреждение', 'предупреждения', 'предупреждений'), C.yellow)
        imgui.SameLine()
    end
    if scan.counts.info > 0 then
        pill(scan.counts.info .. ' ' .. plural(scan.counts.info, 'заметка', 'заметки', 'заметок'), C.blue)
        imgui.SameLine()
    end
    imgui.NewLine()

    if #scan.issues == 0 then
        beginCard('noissues', C.green)
        local b = pushFont('bold')
        wrapped('Конфликтов не нашёл')
        popFont(b)
        wrapped('Команды и клавиши не пересекаются, библиотеки на месте, лишних копий нет.', C.muted)
        endCard()
    else
        local lastGroup
        for i, issue in ipairs(scan.issues) do
            if issue.group ~= lastGroup then
                if lastGroup then imgui.Dummy(vec(0, px(4))) end
                label(GROUP_TITLE[issue.group] or '')
                lastGroup = issue.group
            end
            beginCard('issue' .. i .. (issue.key or issue.title), levelColor(issue.level))
            local b = pushFont('bold')
            wrapped(issue.title)
            popFont(b)
            wrapped(issue.text, C.muted)
            if issue.details and #issue.details > 0 then
                local sm = pushFont('small')
                for d = 1, math.min(#issue.details, 8) do bullet(issue.details[d], C.muted) end
                if #issue.details > 8 then bullet(string.format('и ещё %d', #issue.details - 8), C.faint) end
                popFont(sm)
            end
            endCard()
        end
    end

    imgui.Dummy(vec(0, px(6)))
    label('ЧЕГО Я НЕ ВИЖУ')
    small('Команды и клавиши, которые скрипт берёт из своих настроек, а не прописаны прямо в коде. И всё внутри скомпилированных .luac: их краши я ловлю, а заглянуть внутрь не могу.', C.faint)
    if #scan.compiled > 0 then
        small('Скомпилированы: ' .. table.concat(scan.compiled, ', '), C.faint)
    end
    if #scan.unreadable > 0 then
        small('Не смог прочитать: ' .. table.concat(scan.unreadable, ', '), C.faint)
    end
end

end

do

local scriptsCache = { time = -10, rows = {}, files = {}, filesTime = -10 }

local STATE = {
    running = { 'работает', 'green', 1 },
    paused = { 'на паузе', 'yellow', 2 },
    crashed = { 'упал', 'red', 3 },
    stopped = { 'не запущен', 'faint', 4 },
}

local function lastCrashOf(file)
    for _, c in ipairs(crashes) do
        if not c.demo and c.file:lower() == file:lower() then return c end
    end
end

local function collectScriptRows()
    local now = localClock()
    if now - scriptsCache.time < 1 then return scriptsCache.rows end
    if now - scriptsCache.filesTime > 4 then
        scriptsCache.files = listMoonloaderDir()
        scriptsCache.filesTime = now
    end
    local rows, seen = {}, {}
    local ok, list = pcall(script.list)
    if ok and type(list) == 'table' then
        for _, s in ipairs(list) do
            if not scriptField(s, 'dead') then
                local info = snapshot(s)
                info.s = s
                info.self = isSelf(s)
                info.state = scriptField(s, 'frozen') and 'paused' or 'running'
                rows[#rows + 1] = info
                seen[info.file:lower()] = true
            end
        end
    end
    for _, f in ipairs(scriptsCache.files) do
        if not seen[f.name:lower()] then
            local c = lastCrashOf(f.name)
            rows[#rows + 1] = {
                file = f.name, path = toU8(f.path), name = '', version = '',
                state = (c and c.session == sessionStart) and 'crashed' or 'stopped',
                crash = c,
            }
        end
    end
    table.sort(rows, function(a, b)
        if (a.self or false) ~= (b.self or false) then return not a.self end
        local sa, sb = STATE[a.state][3], STATE[b.state][3]
        if sa ~= sb then return sa < sb end
        return a.file:lower() < b.file:lower()
    end)
    scriptsCache.rows = rows
    scriptsCache.time = now
    return rows
end

local function refreshScripts()
    scriptsCache.time = -10
    runningCache.time = -1
end

local function scriptActions(r)
    local list = {}
    if r.self then return list end
    if r.state == 'running' then
        list[#list + 1] = { 'Пауза', function() pcall(function() r.s:pause() end) end, 'Заморозить скрипт. Он ничего не делает, пока не нажмёшь «Дальше».' }
    elseif r.state == 'paused' then
        list[#list + 1] = { 'Дальше', function() pcall(function() r.s:resume() end) end, 'Снять с паузы.' }
    end
    if r.s then
        list[#list + 1] = { 'Перезапуск', function() pcall(function() r.s:reload() end) end, 'Выключить и сразу включить заново.' }
        list[#list + 1] = { 'Выключить', function() pcall(function() r.s:unload() end) end, 'Выключить до следующего запуска игры. Файл не удаляется.' }
    else
        if r.state == 'crashed' and r.crash then
            list[#list + 1] = { 'Почему?', function() openCrash(r.crash) end, 'Открыть разбор краша.' }
        end
        list[#list + 1] = { 'Запустить', function() pcall(script.load, fromU8(r.path)) end, 'Запустить этот файл прямо сейчас.' }
    end
    return list
end

PAGES.scripts = function()
    local rows = collectScriptRows()
    local counts = { running = 0, paused = 0, crashed = 0, stopped = 0 }
    for _, r in ipairs(rows) do counts[r.state] = counts[r.state] + 1 end

    pageHeader('Скрипты', 'Всё, что лежит в moonloader, и что из этого сейчас работает. Тут же можно поставить скрипт на паузу или выключить, чтобы проверить, не он ли мешает.')
    pill('работают: ' .. counts.running, C.green)
    if counts.paused > 0 then imgui.SameLine() pill('на паузе: ' .. counts.paused, C.yellow) end
    if counts.crashed > 0 then imgui.SameLine() pill('упали: ' .. counts.crashed, C.red) end
    if counts.stopped > 0 then imgui.SameLine() pill('не запущены: ' .. counts.stopped, C.muted) end
    imgui.Dummy(vec(0, px(2)))

    beginChild('##scriptlist', vec(0, 0), false)
    local w = imgui.GetContentRegionAvail().x
    local dl = imgui.GetWindowDrawList()
    local btnH = px(26)
    local sp = imgui.GetStyle().ItemSpacing.x
    for i, r in ipairs(rows) do
        local p = imgui.GetCursorScreenPos()
        local h = px(50)
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), u32(C.card, (i % 2 == 0) and 0.55 or 0.9), px(7))

        local actions = scriptActions(r)
        local actW = 0
        for j, a in ipairs(actions) do actW = actW + buttonWidth(a[1]) + (j > 1 and sp or 0) end
        local st = STATE[r.state]
        local stCol = st[2] == 'faint' and C.faint or levelColor(st[2])
        local sm = pushFont('small')
        local stText = r.self and 'это я' or st[1]
        local stW = imgui.CalcTextSize(stText).x
        popFont(sm)
        local textMax = w - actW - stW - px(70)

        local lh = imgui.GetTextLineHeight()
        dl:AddCircleFilled(vec(p.x + px(16), p.y + px(9) + lh / 2), px(4), u32(stCol), 12)
        local b = pushFont('bold')
        dl:AddText(vec(p.x + px(28), p.y + px(8)), u32(C.text), ellipsize(r.file, textMax))
        popFont(b)

        local meta = {}
        if r.name and r.name ~= '' and r.name:lower() ~= r.file:lower():gsub('%.luac?$', '') then meta[#meta + 1] = r.name end
        if r.version and r.version ~= '' then meta[#meta + 1] = 'v' .. r.version end
        if r.authors and r.authors ~= '' then meta[#meta + 1] = r.authors end
        if #meta == 0 and r.file:lower():find('%.luac$') then meta[1] = 'скомпилирован' end
        sm = pushFont('small')
        if #meta > 0 then
            dl:AddText(vec(p.x + px(28), p.y + px(28)), u32(C.faint), ellipsize(table.concat(meta, '  ·  '), textMax))
        end
        local sh = imgui.GetTextLineHeight()
        dl:AddText(vec(p.x + w - actW - stW - px(26), p.y + (h - sh) / 2), u32(r.self and C.accent or stCol), stText)
        popFont(sm)

        imgui.SetCursorScreenPos(vec(p.x + w - actW - px(10), p.y + (h - btnH) / 2))
        for j, a in ipairs(actions) do
            if j > 1 then imgui.SameLine() end
            if button(a[1] .. '##' .. i .. '_' .. j, buttonWidth(a[1]), nil, btnH) then
                a[2]()
                refreshScripts()
            end
            tooltip(a[3])
        end
        imgui.SetCursorScreenPos(vec(p.x, p.y + h + px(6)))
        imgui.Dummy(vec(w, 0))
    end
    endChild()
end

end

do

local function check(labelText, key, tip)
    local b = ui.bools[key]
    pushVarVec2(imgui.StyleVar.FramePadding, vec(px(4), px(4)))
    if imgui.Checkbox(labelText, b) then
        settings[key] = b[0]
        saveSettings()
    end
    popVar(1)
    tooltip(tip)
end

PAGES.settings = function()
    pageHeader('Настройки')

    beginCard('set_crash')
    label('КОГДА СКРИПТ ПАДАЕТ')
    check('Писать в чат', 'chat', 'Короткая строчка в чате: что упало и как открыть подробности.')
    check('Показывать плашку в углу экрана', 'toast', 'Небольшое уведомление справа внизу. Само исчезает через несколько секунд и не мешает играть.')
    check('Сразу открывать окно с объяснением', 'autoOpen', 'Удобно, если ты автор скриптов. В обычной игре может раздражать: окно вылезет посреди перестрелки.')
    endCard()

    beginCard('set_open')
    label('КАК ОТКРЫВАТЬ')
    if commandName then
        text('Команда: /' .. commandName)
        if commandName ~= 'doctor' then small('/doctor уже занята другим скриптом, поэтому взял эту.', C.faint) end
    else
        text('Команда: нет')
        small('Без SAMPFUNCS команды в чате не работают. Пока открывается на Ctrl + Shift + D или на клавишу ниже.', C.faint)
    end
    imgui.Dummy(vec(0, px(2)))
    imgui.AlignTextToFramePadding()
    text('Клавиша:')
    imgui.SameLine()
    if ui.capturingKey then
        imgui.AlignTextToFramePadding()
        text('нажми любую клавишу (Esc отмена, Backspace убрать)', C.accent)
    else
        imgui.AlignTextToFramePadding()
        text(settings.hotkey ~= 0 and keyName(settings.hotkey) or 'не назначена', settings.hotkey ~= 0 and C.text or C.muted)
        imgui.SameLine()
        if button('Назначить', 0, nil, px(26)) then ui.capturingKey = true end
        if settings.hotkey ~= 0 then
            imgui.SameLine()
            if button('Убрать', 0, 'ghost', px(26)) then
                settings.hotkey = 0
                saveSettings()
            end
        end
    end
    endCard()

    beginCard('set_scan')
    label('ПРОВЕРКИ')
    check('Искать конфликты при запуске игры', 'scanOnStart', 'Через несколько секунд после входа я тихо перечитаю скрипты и, если что-то найду, на вкладке «Конфликты» появится счётчик.')
    endCard()

    beginCard('set_data')
    label('ДАННЫЕ')
    rowBegin()
    if rowButton('Показать пример краша', nil, 'Добавит в список ненастоящий краш, чтобы посмотреть, как выглядит разбор.') then
        openCrash(addDemoCrash())
    end
    if rowButton(flashing('cleared') and 'Очищено###clear' or 'Очистить историю крашей###clear', 'danger') then
        crashes, crashById = {}, {}
        crashesDirty = true
        flash('cleared')
    end
    if rowButton('Открыть папку с отчётами', 'ghost', 'Игра свернётся, откроется проводник.') then
        ensureDir(ML_DIR .. '\\config')
        ensureDir(CFG_DIR)
        ensureDir(REPORTS_DIR)
        shellOpen('explorer.exe', '"' .. REPORTS_DIR .. '"')
    end
    small('Всё хранится в moonloader\\config\\MoonDoctor.', C.faint)
    endCard()
end

end

do

PAGES.help = function()
    pageHeader('Справка', 'Что я умею и чего не умею.')

    beginCard('help_what')
    label('ЧТО УМЕЮ')
    bullet('Ловлю краши всех скриптов и объясняю их нормальным языком: что случилось, почему так бывает и что делать. Краши, которые случились до моего запуска, достаю из moonloader.log.')
    bullet('Собираю отчёт для автора: ошибка, строка, кусок кода, версии MoonLoader и SA-MP, сервер и список остальных скриптов. Одна кнопка, и он в буфере обмена.')
    bullet('Меряю, сколько FPS ест каждый скрипт: по очереди ставлю их на паузу и смотрю на разницу.')
    bullet('Ищу конфликты: одинаковые команды и клавиши, недостающие библиотеки, дубли скриптов, файлы не в той папке.')
    endCard()

    beginCard('help_not')
    label('ЧЕГО НЕ УМЕЮ')
    bullet('Замер FPS приблизительный. Скрипт, у которого вся нагрузка в отдельном потоке рендера, может показать чуть меньше реального.')
    bullet('Не вижу, что внутри скомпилированных .luac: их команды и клавиши не проверяю. Но если такой скрипт упадёт, краш поймаю.')
    bullet('Не вижу клавиши и команды, которые скрипт берёт из своих настроек.')
    bullet('Не чиню скрипты сам. Я показываю, где проблема и кому писать.')
    endCard()

    beginCard('help_report')
    label('КАК ОТПРАВИТЬ ОТЧЁТ АВТОРУ')
    numbered(1, 'Открой вкладку «Краши» и выбери нужный.')
    numbered(2, 'Нажми «Скопировать отчёт для автора».')
    numbered(3, 'Вставь (Ctrl+V) в личку автору, в тему скрипта или в телеграм. Для форума есть кнопка «Для форума», там ошибка в [code].')
    endCard()

    beginCard('help_cmd')
    label('КОМАНДЫ')
    local cmd = '/' .. (commandName or 'doctor')
    text(cmd .. ' - открыть или закрыть окно')
    text(cmd .. ' fps - сразу на вкладку нагрузки')
    text(cmd .. ' scan - проверить конфликты')
    text(cmd .. ' test - показать пример краша')
    endCard()

    small('MoonDoctor ' .. VERSION .. ' by Levushkins', C.faint)
end

end

local function drawMain(player)
    player.LockPlayer = fps.running
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
    imgui.SetNextWindowSize(vec(math.min(px(900), sw - 40), math.min(px(590), sh - 40)), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSizeConstraints(vec(math.min(px(720), sw - 20), math.min(px(460), sh - 20)), vec(sw, sh))
    pushVarVec2(imgui.StyleVar.WindowPadding, vec(0, 0))
    imgui.Begin('MoonDoctor##main', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
    popVar(1)

    local w, h = imgui.GetWindowWidth(), imgui.GetWindowHeight()
    local headerH = drawHeader(w)
    local sideW = px(200)
    drawSidebar(sideW, h - headerH)

    imgui.SetCursorPos(vec(sideW, headerH))
    pushVarVec2(imgui.StyleVar.WindowPadding, vec(px(22), px(18)))
    beginChild('##page', vec(w - sideW, h - headerH), false, imgui.WindowFlags.AlwaysUseWindowPadding)
    popVar(1)
    ui.pageAlpha = math.min(1, ui.pageAlpha + imgui.GetIO().DeltaTime * 7)
    pushVarFloat(imgui.StyleVar.Alpha, 0.3 + 0.7 * ui.pageAlpha)
    ui.wrapDepth = 0
    cardStack = {}
    if ui.pageError then
        beginCard('pageerr', C.red)
        wrapped('Эта страница сломалась, и я её выключил, чтобы не уронить игру. Напиши об этом автору MoonDoctor, вот текст:')
        local m = pushFont('mono')
        wrapped(ui.pageError, C.muted)
        popFont(m)
        if button('Попробовать ещё раз') then ui.pageError = nil end
        endCard()
    else
        local mark = openMark()
        local ok, err = pcall(PAGES[ui.page] or PAGES.crashes)
        if not ok then
            unwindTo(mark)
            cardStack = {}
            ui.wrapDepth = 0
            ui.pageError = tostring(err)
            print('[MoonDoctor] страница ' .. ui.page .. ' сломалась: ' .. ui.pageError)
        end
    end
    popVar(1)
    endChild()
    imgui.End()
end

local TOAST_FLAGS

local function drawMiniProgress()
    local sw = getScreenResolution()
    imgui.SetNextWindowPos(vec(sw / 2, px(24)), imgui.Cond.Always, vec(0.5, 0))
    imgui.SetNextWindowSize(vec(px(340), 0), imgui.Cond.Always)
    pushVarVec2(imgui.StyleVar.WindowPadding, vec(px(14), px(12)))
    imgui.Begin('##fpsmini', nil, TOAST_FLAGS)
    local elapsed = localClock() - fps.startedAt
    local b = pushFont('bold')
    wrapped(fps.phase == 'paused' and ('Проверяю нагрузку: ' .. fps.current) or 'Проверяю нагрузку...')
    popFont(b)
    pushColor(imgui.Col.FrameBg, C.line)
    imgui.ProgressBar(clamp(elapsed / math.max(1, fps.estimate), 0, 0.99), vec(-1, px(5)), '')
    popColor(1)
    small('Открой ' .. openText() .. ', чтобы посмотреть или остановить.', C.faint)
    imgui.End()
    popVar(1)
end

local function drawToasts(player)
    ui.wrapDepth = 0
    player.HideCursor = true
    player.LockPlayer = false
    local sw, sh = getScreenResolution()
    local now = localClock()
    local y = sh - px(28)
    for _, t in ipairs(toasts) do
        local age = now - t.born
        local a = clamp(math.min(age / 0.25, (t.ttl - age) / 0.5), 0, 1)
        if a > 0 then
            imgui.SetNextWindowPos(vec(sw - px(28), y), imgui.Cond.Always, vec(1, 1))
            imgui.SetNextWindowSize(vec(px(340), 0), imgui.Cond.Always)
            pushVarFloat(imgui.StyleVar.Alpha, a)
            pushVarVec2(imgui.StyleVar.WindowPadding, vec(px(24), px(12)))
            imgui.Begin('##toast' .. t.id, nil, TOAST_FLAGS)
            local wp = imgui.GetWindowPos()
            local wh = imgui.GetWindowHeight()
            imgui.GetWindowDrawList():AddRectFilled(vec(wp.x + px(12), wp.y + px(12)), vec(wp.x + px(15), wp.y + wh - px(12)), u32(levelColor(t.color)), px(2))
            local b = pushFont('bold')
            wrapped(t.title)
            popFont(b)
            if t.text then wrapped(t.text, C.muted) end
            small(t.hint or ('Подробнее: ' .. openText()), C.faint)
            local h = imgui.GetWindowHeight()
            imgui.End()
            popVar(2)
            y = y - h - px(10)
        end
    end
    if fps.running and not ui.show[0] then drawMiniProgress() end
end

function toggleWindow()
    if not imgui then return end
    if ui.show[0] then
        ui.show[0] = false
    else
        local fresh, unread = nil, 0
        for _, c in ipairs(crashes) do
            if c.unread then
                unread = unread + 1
                fresh = fresh or c
            end
        end
        if unread == 1 then
            openCrash(fresh)
        elseif unread > 1 then
            ui.crashView = 'list'
            openWindow('crashes')
        else
            openWindow()
        end
    end
end

if imgui then
    ui.show = imgui.new.bool(false)

    imgui.OnInitialize(function()
        imgui.GetIO().IniFilename = nil
        ui.secBuf = imgui.new.int(settings.measureSec)
        ui.bools = {}
        for _, key in ipairs({ 'chat', 'toast', 'autoOpen', 'scanOnStart' }) do
            ui.bools[key] = imgui.new.bool(settings[key])
        end
        local dpi, mode = 1, 0
        pcall(function() dpi = imgui.GetDpiScale() or 1 end)
        pcall(function() mode = imgui.GetDpiScalingMode() or 0 end)
        ui.styleK = (mode == 2 or mode == 3 or mode == 4) and dpi or 1
        ui.fontK = (mode == 1 or mode == 2 or mode == 4) and dpi or 1
        local _, sh = getScreenResolution()
        ui.scale = dpi > 1.01 and dpi or clamp(sh / 1080, 0.9, 1.6)
        initColors()
        TOAST_FLAGS = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
            + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoFocusOnAppearing
            + imgui.WindowFlags.NoInputs + imgui.WindowFlags.NoCollapse
        loadFonts()
        applyTheme()
    end)

    imgui.OnFrame(function() return ui.show[0] end, drawMain)

    local toastFrame = imgui.OnFrame(function()
        return (#toasts > 0 or fps.running) and not ui.show[0] and not isPauseMenuActive()
    end, drawToasts)
    toastFrame.HideCursor = true
end

end

local DLG_LIST, DLG_INFO = 27311, 27312
local fallback = { list = {}, current = nil }

local function wrapForDialog(s, width)
    local out = {}
    for line in (s .. '\n'):gmatch('([^\n]*)\n') do
        local cur, len = '', 0
        for word in line:gmatch('%S+') do
            local visible = #utf8Chars(word:gsub('{%x%x%x%x%x%x}', ''))
            if len > 0 and len + 1 + visible > width then
                out[#out + 1] = cur
                cur, len = word, visible
            else
                cur = len > 0 and (cur .. ' ' .. word) or (cur .. word)
                len = len + (len > 0 and 1 or 0) + visible
            end
        end
        out[#out + 1] = cur
    end
    return table.concat(out, '\n')
end

function fallback.showList()
    if not sampReady() then return end
    fallback.current = nil
    if #crashes == 0 then
        local msg = '{FFFFFF}Пока ни один скрипт не падал.\n\nЕсли что-то упадёт, здесь будет объяснение и готовый отчёт для автора.\n\n'
            .. '{9AA0A6}Для нормального окна поставь библиотеку mimgui в moonloader\\lib.'
        sampShowDialog(DLG_INFO, 'MoonDoctor', fromU8(msg), fromU8('Закрыть'), '', 0)
        return
    end
    local lines = { 'Скрипт\tКогда\tЧто случилось' }
    fallback.list = {}
    for i, c in ipairs(crashes) do
        if i > 40 then break end
        local ex = explain(c)
        lines[#lines + 1] = string.format('%s%s\t%s\t%s', c.unread and '{EF5350}' or '{FFFFFF}', c.file, whenText(c.last), ex.short)
        fallback.list[#fallback.list + 1] = c
    end
    sampShowDialog(DLG_LIST, 'MoonDoctor', fromU8(table.concat(lines, '\n')), fromU8('Открыть'), fromU8('Закрыть'), 5)
end

function fallback.showCrash(c)
    local ex = explain(c)
    c.unread = false
    local t = {
        '{EF5350}' .. ex.title,
        '',
        '{FFFFFF}' .. ex.what,
        '',
        '{9AA0A6}Почему так бывает:',
        '{FFFFFF}' .. ex.why,
        '',
        '{9AA0A6}Что делать:',
    }
    for i, s in ipairs(ex.todo) do t[#t + 1] = string.format('{FFFFFF}%d. %s', i, s) end
    t[#t + 1] = ''
    t[#t + 1] = '{9AA0A6}Ошибка: ' .. firstLine(c.message)
    local body = fromU8(wrapForDialog(table.concat(t, '\n'), 95))
    sampShowDialog(DLG_INFO, 'MoonDoctor', body:sub(1, 3900), fromU8('Копировать'), fromU8('Назад'), 0)
    fallback.current = c
end

function fallback.poll()
    if not sampReady() then return end
    local ok, res, btn, item = pcall(sampHasDialogRespond, DLG_LIST)
    if ok and res and btn == 1 and fallback.list[item + 1] then
        fallback.showCrash(fallback.list[item + 1])
    end
    ok, res, btn = pcall(sampHasDialogRespond, DLG_INFO)
    if ok and res and fallback.current then
        if btn == 1 then
            copyText(buildReport(fallback.current, false))
            chat('Отчёт скопирован. Вставь его автору (Ctrl+V).')
            fallback.showCrash(fallback.current)
        else
            fallback.showList()
        end
    end
end

local function onCommand(arg)
    arg = trim((arg or ''):lower())
    if not imgui then
        if arg == 'test' or arg == 'demo' then addDemoCrash() end
        fallback.showList()
        return
    end
    if arg == 'fps' then
        openWindow('fps')
    elseif arg == 'scan' or arg == 'conflicts' then
        openWindow('conflicts')
        runScan()
    elseif arg == 'test' or arg == 'demo' then
        openCrash(addDemoCrash())
    elseif arg == 'scripts' then
        openWindow('scripts')
    else
        toggleWindow()
    end
end

local function registerCommand()
    for _, name in ipairs({ 'doctor', 'mdoctor', 'moondoctor' }) do
        local ok, taken = pcall(sampIsChatCommandDefined, name)
        if ok and not taken then
            sampRegisterChatCommand(name, onCommand)
            commandName = name
            return
        end
    end
end

local function isTyping()
    if not sampReady() then return false end
    local ok, res = pcall(function()
        return sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
    end)
    return ok and res
end

local WM_KEYDOWN, WM_SYSKEYDOWN = 0x0100, 0x0104

function onWindowMessage(msg, wparam, lparam)
    if not imgui or (msg ~= WM_KEYDOWN and msg ~= WM_SYSKEYDOWN) then return end

    if ui.capturingKey then
        if wparam == 0x1B then
            ui.capturingKey = false
        elseif wparam == 0x08 then
            settings.hotkey = 0
            ui.capturingKey = false
            saveSettings()
        elseif not MODIFIERS[wparam] then
            settings.hotkey = wparam
            ui.capturingKey = false
            saveSettings()
        end
        consumeWindowMessage(true, true)
        return
    end

    if bit.band(lparam, 0x40000000) ~= 0 then return end

    if wparam == 0x1B and ui.show[0] then
        ui.show[0] = false
        consumeWindowMessage(true, false)
        return
    end
    if isTyping() then return end

    if settings.hotkey ~= 0 and wparam == settings.hotkey then
        toggleWindow()
    elseif not commandName and wparam == 0x44 and isKeyDown(0x11) and isKeyDown(0x10) then
        toggleWindow()
    end
end

function onScriptTerminate(s, quitGame)
    if isSelf(s) then
        resumePaused()
        if crashesDirty then pcall(saveCrashes) end
    end
end

ensureDir(ML_DIR .. '\\config')
ensureDir(CFG_DIR)
loadSettings()
loadCrashes()
loadFpsResults()

function main()
    local fromLog = scanStartupLog()
    if fromLog > 0 then
        missedOnStart = missedOnStart + fromLog
        if settings.toast then
            pushToast({
                title = string.format('Пока игра загружалась, %s %d %s', plural(fromLog, 'упал', 'упало', 'упало'), fromLog, plural(fromLog, 'скрипт', 'скрипта', 'скриптов')),
                text = 'Я разобрал, что с ними случилось.',
                color = 'red',
                ttl = 12,
            })
        end
    end

    lua_thread.create(function()
        if not isSampLoaded() or not sfLoaded() then return end
        while not sampReady() do wait(200) end
        registerCommand()
        wait(1500)
        if missedOnStart > 0 and settings.chat then
            chat(string.format('Пока игра загружалась, %s %d %s. Подробности: %s',
                plural(missedOnStart, 'упал', 'упало', 'упало'), missedOnStart,
                plural(missedOnStart, 'скрипт', 'скрипта', 'скриптов'), openText()))
        end
        missedOnStart = 0
    end)

    if settings.scanOnStart then
        lua_thread.create(function()
            wait(8000)
            runScan()
            while scan.running do wait(200) end
            local red = scan.done and scan.counts.red or 0
            if red > 0 and settings.chat then
                local how = commandName and ('/' .. commandName .. ' scan') or openText()
                chat(string.format('Нашёл %d %s со скриптами. Посмотреть: %s', red, plural(red, 'проблему', 'проблемы', 'проблем'), how))
            end
        end)
    end

    local lastSave = localClock()
    while true do
        wait(50)
        local now = localClock()
        for i = #toasts, 1, -1 do
            if now - toasts[i].born > toasts[i].ttl then table.remove(toasts, i) end
        end
        if crashesDirty and now - lastSave > 2 then
            lastSave = now
            saveCrashes()
        end
        if not imgui then fallback.poll() end
    end
end
