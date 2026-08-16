-- encoding: CP1251
local SCRIPT_VERSION = '3.0.0'

script_name('SMI Helper')
script_description('Автоматизация работы редактора объявлений СМИ')
script_author('e11evated')
script_version(SCRIPT_VERSION)
script_version_number(300)
script_properties('work-in-pause')

function logLine(level, text)
   print(('[SMI Helper][%s] %s'):format(level, text))
end

logLine('BOOT', 'Инициализация SMI Helper v' .. SCRIPT_VERSION)

local ok_raklua, RakLua = pcall(require, 'RakLua')
if ok_raklua and RakLua then
   local ok_compat = pcall(function()
      RakLua.defineSampLuaCompatibility()
   end)
   if ok_compat then
      logLine('OK', 'RakLua: совместимость с SAMP.Lua включена')
   else
      logLine('WARN', 'RakLua: не удалось включить совместимость')
   end
end

local ok_samp, samp = pcall(require, 'lib.samp.events')
if not ok_samp then
   logLine('FATAL', 'Библиотека samp.events не найдена')
   thisScript():unload()
   return
end

local ok_mimgui, mimgui = pcall(require, 'mimgui')
if not ok_mimgui then
   logLine('FATAL', 'Библиотека mimgui не найдена')
   thisScript():unload()
   return
end

local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi then
   logLine('FATAL', 'FFI недоступен, нужен LuaJIT')
   thisScript():unload()
   return
end

pcall(function()
   ffi.cdef[[
      int ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
      void* GetForegroundWindow();
   ]]
end)
local shell32, user32 = nil, nil
pcall(function() shell32 = ffi.load('shell32') end)
pcall(function() user32 = ffi.load('user32') end)

local ok_moonmonet, MoonMonet = pcall(require, 'MoonMonet')
if not ok_moonmonet then
   logLine('WARN', 'MoonMonet не найден, палитра будет базовой')
   MoonMonet = nil
end

local ok_blur, mimgui_blur = pcall(require, 'mimgui_blur')
if not ok_blur then
   logLine('WARN', 'mimgui_blur не найден, размытие отключено')
   mimgui_blur = nil
end

local ok_emoji, emoji = pcall(require, 'chat_emoji')
if not ok_emoji then
   logLine('WARN', 'chat_emoji не найден, иконки Arizona в меню отключены')
   emoji = nil
end

local ok_encoding, encoding = pcall(require, 'encoding')
if not ok_encoding then
   logLine('FATAL', 'Библиотека encoding не найдена')
   thisScript():unload()
   return
end

local ok_inicfg, inicfg = pcall(require, 'inicfg')
if not ok_inicfg then
   logLine('FATAL', 'Библиотека inicfg не найдена')
   thisScript():unload()
   return
end

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local new = mimgui.new
local vkeys = require 'vkeys'
local wm = require 'windows.message'

local hotkeyAssigning = nil
local hotkeyDebounce = false
local lastAssignTime = 0

local ok_ti, ti = pcall(require, 'tabler_icons')
if not ok_ti then
   logLine('WARN', 'tabler_icons не найден, иконки отключены')
   ti = nil
end

local ICON_MISS = {}
local iconCache = {}
function getIcon(name, fallback)
   if not ti then return fallback or "" end
   local cached = iconCache[name]
   if cached == ICON_MISS then return fallback or "" end
   if cached ~= nil then return cached end
   local ok, res = pcall(ti, name)
   if ok and type(res) == 'string' and res ~= "" then
      iconCache[name] = res
      return res
   end
   iconCache[name] = ICON_MISS
   return fallback or ""
end

local scriptDir = getWorkingDirectory() .. '\\resource\\SMI Helper'
local configFile = 'smi_helper.ini'
local templatesFile = scriptDir .. '\\approved_ads.json'
local blacklist_file = scriptDir .. '\\blacklist.json'
local dataFile = scriptDir .. '\\smi_data.json'
local senderIndexFile = scriptDir .. '\\senders_index.txt'
local notificationSoundFile = scriptDir .. '\\smi_notify.wav'
local blacklist = {}
local blacklistCache = {}

function updateBlacklistCache()
   blacklistCache = {}
   for k in pairs(blacklist) do
      table.insert(blacklistCache, k)
   end
   table.sort(blacklistCache)
end

local bl_input_buf = new.char[256]()
local bl_reason_buf = new.char[256]()
local bl_search_buf = new.char[256]()

local quickPicker = {
   active = nil,
   buffer = new.char[64]()
}

function quickPicker.open(key)
   quickPicker.active = key
   ffi.fill(quickPicker.buffer, 64, 0)
end

function quickPicker.close()
   quickPicker.active = nil
end

local sessionStartTimestamp = os.time()

local forceCenterMain = false
local forceCenterSettings = false
local needThemeUpdate = false
local anim = { main = 0, settings = 0 }

function lower1251(s)
   if not s then return "" end
   local res = s:lower():gsub('\168', '\184'):gsub('[\192-\223]', function(c) return string.char(c:byte() + 32) end)
   return res
end

function upper1251(s)
   if not s then return "" end
   local res = s:upper():gsub('\184', '\168'):gsub('[\224-\255]', function(c) return string.char(c:byte() - 32) end)
   return res
end

local ALPHA = "%a\168\184\192-\255"

local CAT_MARKERS = {
   transport = {'а/м','т/с','в/т','м/т','л/д','в/с','с/м','д/т','н/з'},
   realty    = {'д/м','б/з','г/ф','п/п'},
   accs      = {'а/с','о/п','п/м','п/т','р/с'},
}

local CAT_NAMES = {
   transport = "Транспорт",
   realty    = "Недвижимость",
   accs      = "Аксессуары",
   other     = "Прочее"
}

function hasAnyMarker(text, list)
   for i = 1, #list do
      if text:find(list[i], 1, true) then return true end
   end
   return false
end

function detectCategory(text)
   local low = lower1251(text or "")
   if hasAnyMarker(low, CAT_MARKERS.transport) then return 'transport' end
   if hasAnyMarker(low, CAT_MARKERS.realty) then return 'realty' end
   if hasAnyMarker(low, CAT_MARKERS.accs) then return 'accs' end
   return 'other'
end

function getBlacklistData(key)
   local item = blacklist[key]
   if not item then return key or "Неизвестно", "Без причины", "" end
   if type(item) == 'table' then
      return item.nick or key, item.reason or "Без причины", item.date or ""
   end
   return tostring(item), "Без причины", ""
end

function ensureDirectoryExists()
   if not doesDirectoryExist(scriptDir) then
      createDirectory(scriptDir)
   end
end

local CrashHandler = {
   version = 2,
   path = getWorkingDirectory() .. '\\.SMI Helper Handler.lua'
}

function CrashHandler.source()
   return '-- SMI Helper crash handler, version ' .. CrashHandler.version .. '\n' .. [==[
script_name('SMI Helper Handler')
script_description('Показывает причину падения SMI Helper')
script_author('e11evated')

local OWNER      = 'SMI Helper'
local SELF_NAME  = 'SMI Helper Handler'
local MARKER     = 'Инициализация SMI Helper'
local DIALOG_ID  = 31337
local MAX_ERROR  = 900
local MAX_LOG    = 1800

function readLogTail()
   local path = getWorkingDirectory():gsub('\\', '/') .. '/moonloader.log'
   local file = io.open(path, 'r')
   if not file then return 'Файл лога не найден:\n' .. path end

   local lines = {}
   for line in file:lines() do lines[#lines + 1] = line end
   file:close()

   local from = 1
   for i = #lines, 1, -1 do
      if lines[i]:find(MARKER, 1, true) then from = i break end
   end

   local out = {}
   for i = from, #lines do
      local line = lines[i]
      if line:find(OWNER, 1, true) and not line:find('Loaded successfully', 1, true) then
         out[#out + 1] = line:match(OWNER .. '%: (.+)') or line
      end
   end
   if #out == 0 then return 'Строк SMI Helper в логе не найдено.' end

   local text = table.concat(out, '\n')
   if #text > MAX_LOG then text = '...\n' .. text:sub(#text - MAX_LOG) end
   return text
end

function onSystemMessage(msg, msgType, script)
   if type(msg) ~= 'string' then return end

   local owned
   if script and script.name then
      owned = (script.name == OWNER)
   else
      owned = msg:find(OWNER, 1, true) ~= nil and msg:find(SELF_NAME, 1, true) == nil
   end
   if not owned then return end

   local isTrace = msg:find('stack traceback', 1, true) ~= nil
   local isError = (msgType == 3) and msg:find('Script died due to an error', 1, true) == nil
   if not (isTrace or isError) then return end

   local shortMsg = msg
   if #shortMsg > MAX_ERROR then shortMsg = shortMsg:sub(1, MAX_ERROR) .. '...' end

   local okLog, logText = pcall(readLogTail)
   if not okLog or type(logText) ~= 'string' then logText = 'Не удалось прочитать лог.' end

   local body = '{D8DEE9}SMI Helper аварийно завершил работу.\n\n' ..
      'Сделайте скриншот этого окна и отправьте разработчику.\n\n' ..
      '{ECEFF4}Текст ошибки:\n{BF616A}' .. shortMsg .. '\n\n' ..
      '{ECEFF4}Лог текущей сессии:\n{A3BE8C}' .. logText

   pcall(sampShowDialog, DIALOG_ID, '{88C0D0}SMI Helper - сбой скрипта', body, 'Закрыть', '', 0)
end

function main()
   while true do wait(1000) end
end
]==]
end

function CrashHandler.install()
   local existing = io.open(CrashHandler.path, 'r')
   if existing then
      local head = existing:read(120) or ''
      existing:close()
      if head:find('version ' .. CrashHandler.version, 1, true) then return end
   end

   local file, err = io.open(CrashHandler.path, 'w')
   if not file then
      logLine('WARN', 'Не удалось создать обработчик крашей: ' .. tostring(err))
      return
   end

   local ok = pcall(function()
      file:write(CrashHandler.source())
   end)
   file:close()

   if ok then
      logLine('OK', 'Обработчик крашей установлен, заработает после перезапуска игры')
   else
      logLine('WARN', 'Не удалось записать обработчик крашей')
   end
end

local C = {
   CSIDL_FONTS             = 0x14,
   MAX_SAMP_PLAYER_ID      = 1000,
   NO_RECORD_SPEED_SEC     = 999,
   MAX_VALID_EDIT_TIME_SEC = 120,
   CATCH_COOLDOWN          = 3,
   SEND_RESULT_GRACE_MS    = 2500,
   SKIP_RETRY_COOLDOWN     = 300,
   QUEUE_CONTINUE_DELAY_SEC= 0.35,
   MAX_QUEUE_RETRIES       = 5,
   QUEUE_PREVIEW_TTL       = 150,
   QUEUE_WIDGET_W          = 288,
   FUZZY_MIN_TOKENS        = 3,
   EDITOR_WAIT_TIMEOUT     = 5.0,
   VIP_FLAG_TTL            = 900,
   SKIP_PRUNE_INTERVAL     = 30,
   HOVER_GC_SEC            = 6,
   CONFIG_FLUSH_SEC        = 5,
   BLOCK_LOG_MAX           = 120,
   DONE_WINDOW_SEC         = 3600
}

local CHANGELOG = {
   "Исправлены 17 багов: парсинг многострочных объявлений, ключи шаблонов, подмена цены нечётким шаблоном",
   "Автокоррекция текста: заглавная буква, точка в конце, пробелы, капс, валюта, повторы знаков, дубли слов",
   "Проверки перед отправкой: длина, смена категории, блокировка авто-отправки при нарушении",
   "Новое в статистике: заработано за всё время, сравнение с вчера, стрик целей, топ отправителей",
   "Хоткеи: пауза очереди, автокоррекция, пропуск, Ctrl+Enter и Ctrl+Backspace в редакторе",
   "Тихий режим, лог блокировок, единый экспорт данных, окно изменений"
}

local Ease = { fn = {} }

Ease.fn.linear     = function(t) return t end
Ease.fn.inQuad     = function(t) return t * t end
Ease.fn.outQuad    = function(t) return t * (2 - t) end
Ease.fn.inQuart    = function(t) return t * t * t * t end
Ease.fn.outQuart   = function(t) local f = t - 1 return 1 - f * f * f * f end
Ease.fn.inQuint    = function(t) return t * t * t * t * t end
Ease.fn.outQuint   = function(t) local f = t - 1 return 1 + f * f * f * f * f end
Ease.fn.inSine     = function(t) return 1 - math.cos(t * math.pi / 2) end
Ease.fn.outSine    = function(t) return math.sin(t * math.pi / 2) end
Ease.fn.outExpo    = function(t) return (t >= 1) and 1 or (1 - 2 ^ (-10 * t)) end
Ease.fn.inBack     = function(t) return t * t * (2.70158 * t - 1.70158) end
Ease.fn.outBack    = function(t) local f = t - 1 return f * f * (2.70158 * f + 1.70158) + 1 end
Ease.fn.outElastic = function(t)
   if t <= 0 then return 0 end
   if t >= 1 then return 1 end
   return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * (2 * math.pi / 3)) + 1
end

function Ease.get(from, to, startTime, duration, kind)
   if not startTime then return from, 0 end
   local t = (os.clock() - startTime) / (duration or 1)
   if t <= 0 then return from, 0 end
   if t >= 1 then return to, 2 end
   return from + (to - from) * (Ease.fn[kind or 'linear'] or Ease.fn.linear)(t), 1
end

local defaultConfig = {
   settings = {
      configVersion = SCRIPT_VERSION,
      lastSeenVersion = "",
      active = false, windowPosX = -1, windowPosY = -1, settingsPosX = -1, settingsPosY = -1,
      soundEnabled = false, soundVolume = 50,
      autoApprove = false, autoCatchByCommand = false,
      quickEditButtons = true, newsredakHotkeyToggle = true, interceptCommand = true,
      moonmonetBaseColor = 0xFF00BABE,
      blurEnabled = true, blurBackgroundRadius = 20.0, blurListRadius = 5.0,
      dailyGoal = 50,
      queueWidget = true, queueWidgetX = -1, queueWidgetY = -1,
      queueWidgetRows = 6, queueAlertCount = 10,
      templateTtlDays = 10,
      chatEmoji = true,
      chatEmojiLevel = 2,
      uiEmoji = true,
      fxAnimations = true,
      silentMode = false,
      requireWindowFocus = true,
      autoApproveDelay = 5,
      autoSkipInactivity = false,
      autoSkipDelay = 20,
      autoFixEnabled = true,
      autoFixOnOpen = false,
      validateEnabled = true,
      minAdLength = 8,
      maxAdLength = 180,
      fuzzyThreshold = 70
   },
   autofix = {
      capitalize = true,
      trailingDot = true,
      spaces = true,
      caps = true,
      currency = true,
      repeats = true,
      dupWords = true
   },
   hotkeys = {
      scriptActive_key = 0,
      autoCatch_key = 0,
      cmdNewsredak_key = 0,
      queuePause_key = 0,
      autoFix_key = 0,
      skipAd_key = 0
   },
   stats = {
      totalApproved = 0, totalRejected = 0, sessionApproved = 0, sessionRejected = 0,
      dailyApproved = 0, dailyEarnings = 0, totalEarnings = 0, sessionEarnings = 0,
      catTransport = 0, catRealty = 0, catAccs = 0, catOther = 0,
      totalEditTime = 0, timedEdits = 0, autoApprovedCount = 0, autoSkippedCount = 0,
      fastestEdit = C.NO_RECORD_SPEED_SEC,
      tplApproved = 0, tplSavedSec = 0,
      goalStreak = 0, goalStreakDate = "",
      totalBlockedBL = 0, sessionBlockedBL = 0, history = "[]", lastDate = ""
   }
}

local inputCursorState = {
   selectionStart = 0,
   selectionEnd = 0,
   userMovedCursor = false
}

function textEditCallback(data)
   inputCursorState.selectionStart = data.SelectionStart
   inputCursorState.selectionEnd = data.SelectionEnd
   inputCursorState.userMovedCursor = true
   return 0
end

local cbTextEdit = ffi.cast('int (*)(ImGuiInputTextCallbackData* data)', textEditCallback)

local cfg = inicfg.load(defaultConfig, configFile)

do
   local function coerceToDefault(value, default)
      local wantType = type(default)
      if type(value) == wantType then return value, false end

      if wantType == 'number' then
         local n = tonumber(value)
         if n then return n, true end
      elseif wantType == 'boolean' then
         if value == 'true'  or value == 1 then return true,  true end
         if value == 'false' or value == 0 then return false, true end
      elseif wantType == 'string' then
         local vt = type(value)
         if vt == 'number' or vt == 'boolean' then return tostring(value), true end
      end

      return default, true
   end

   local function mergeDefaults(defaults, target, prefix, added, fixed)
      for key, default in pairs(defaults) do
         if type(default) == 'table' then
            if type(target[key]) ~= 'table' then
               target[key] = {}
               added[#added + 1] = prefix .. key
            end
            mergeDefaults(default, target[key], prefix .. key .. '.', added, fixed)
         elseif target[key] == nil then
            target[key] = default
            added[#added + 1] = prefix .. key
         else
            local corrected, changed = coerceToDefault(target[key], default)
            if changed then
               target[key] = corrected
               fixed[#fixed + 1] = prefix .. key
            end
         end
      end
   end

   if type(cfg) ~= 'table' then
      logLine('WARN', 'Конфиг повреждён, беру значения по умолчанию')
      cfg = {}
   end

   local added, fixed = {}, {}
   mergeDefaults(defaultConfig, cfg, '', added, fixed)

   local storedVersion = tostring(cfg.settings.configVersion or '')
   local versionChanged = (storedVersion ~= SCRIPT_VERSION)

   if #added > 0 then
      logLine('INFO', ('В конфиг добавлено параметров: %d (%s)')
         :format(#added, table.concat(added, ', ')))
   end
   if #fixed > 0 then
      logLine('WARN', ('Исправлен тип значений: %s'):format(table.concat(fixed, ', ')))
   end
   if versionChanged then
      logLine('INFO', ('Конфиг переведён: %s -> %s')
         :format(storedVersion == '' and 'без версии' or storedVersion, SCRIPT_VERSION))
   end

   if not cfg.stats.lastDate or cfg.stats.lastDate == "" then
      cfg.stats.lastDate = os.date('%d.%m.%Y')
   end

   cfg.settings.configVersion = SCRIPT_VERSION

   if versionChanged or #added > 0 or #fixed > 0 then
      inicfg.save(cfg, configFile)
   end
end

local cfgDirty = false
local cfgLastSave = 0

function saveConfig(immediate)
   if immediate then
      cfgDirty = false
      cfgLastSave = os.clock()
      inicfg.save(cfg, configFile)
      return
   end
   cfgDirty = true
end

function flushConfig()
   if cfgDirty and (os.clock() - cfgLastSave) >= C.CONFIG_FLUSH_SEC then
      cfgDirty = false
      cfgLastSave = os.clock()
      inicfg.save(cfg, configFile)
   end
end

function atomicWriteFile(filepath, data)
   local tmpPath = filepath .. '.tmp'
   local file, err = io.open(tmpPath, 'w')
   if not file then
      return false, "Не удалось открыть файл на запись: " .. tostring(err)
   end
   local okWrite, writeErr = file:write(data)
   file:flush()
   file:close()

   if not okWrite then
      os.remove(tmpPath)
      return false, "Ошибка записи на диск: " .. tostring(writeErr)
   end

   local bakPath = filepath .. '.bak'
   os.remove(bakPath)
   os.rename(filepath, bakPath)
   local okRename, renErr = os.rename(tmpPath, filepath)
   if not okRename then
      os.rename(bakPath, filepath)
      os.remove(tmpPath)
      return false, "Не удалось переименовать файл: " .. tostring(renErr)
   end
   return true
end

local Data = {
   rejectReasons = {},
   senders = {},
   blockLog = {},
   dirty = false
}

function Data.load()
   local file = io.open(dataFile, 'r')
   if not file then return end
   local content = file:read('*a')
   file:close()
   if not content or content == '' then return end
   local ok, parsed = pcall(decodeJson, content)
   if ok and type(parsed) == 'table' then
      Data.rejectReasons = type(parsed.rejectReasons) == 'table' and parsed.rejectReasons or {}
      Data.senders = type(parsed.senders) == 'table' and parsed.senders or {}
      Data.blockLog = type(parsed.blockLog) == 'table' and parsed.blockLog or {}
   end
end

function Data.save()
   Data.dirty = false
   local ok, json = pcall(encodeJson, {
      rejectReasons = Data.rejectReasons,
      senders = Data.senders,
      blockLog = Data.blockLog
   })
   if not ok then
      logLine('ERROR', 'Данные -> JSON: ' .. tostring(json))
      return false
   end
   local written, err = atomicWriteFile(dataFile, json)
   if not written then
      logLine('ERROR', 'Запись smi_data.json: ' .. tostring(err))
      return false
   end
   return true
end

function Data.addReject(reason)
   local key = (reason or ""):gsub('^%s+', ''):gsub('%s+$', '')
   if key == "" then key = "Без причины" end
   if #key > 64 then key = key:sub(1, 64) end
   Data.rejectReasons[key] = (Data.rejectReasons[key] or 0) + 1
   Data.dirty = true
end

function Data.addSender(nick, key, approved)
   if not key or key == "" then return end
   local rec = Data.senders[key]
   if not rec then
      rec = { nick = nick or key, ok = 0, bad = 0 }
      Data.senders[key] = rec
   end
   rec.nick = nick or rec.nick
   if approved then rec.ok = (rec.ok or 0) + 1 else rec.bad = (rec.bad or 0) + 1 end
   Data.dirty = true
end

function Data.addBlock(nick, reason)
   table.insert(Data.blockLog, {
      nick = nick or "?",
      reason = reason or "Без причины",
      at = os.date('%d.%m %H:%M')
   })
   while #Data.blockLog > C.BLOCK_LOG_MAX do table.remove(Data.blockLog, 1) end
   Data.dirty = true
end

function Data.topSenders(limit)
   local list = {}
   for key, rec in pairs(Data.senders) do
      list[#list + 1] = {
         nick = rec.nick or key,
         ok = rec.ok or 0,
         bad = rec.bad or 0,
         total = (rec.ok or 0) + (rec.bad or 0)
      }
   end
   table.sort(list, function(a, b)
      if a.total == b.total then return a.nick < b.nick end
      return a.total > b.total
   end)
   while #list > (limit or 5) do table.remove(list) end
   return list
end

function Data.topReasons(limit)
   local list = {}
   for reason, count in pairs(Data.rejectReasons) do
      list[#list + 1] = { reason = reason, count = count }
   end
   table.sort(list, function(a, b)
      if a.count == b.count then return a.reason < b.reason end
      return a.count > b.count
   end)
   while #list > (limit or 5) do table.remove(list) end
   return list
end

local moonmonetColors = nil

function argb_to_rgba(color_int)
   local a = bit.band(bit.rshift(color_int, 24), 0xFF) / 255.0
   local r = bit.band(bit.rshift(color_int, 16), 0xFF) / 255.0
   local g = bit.band(bit.rshift(color_int, 8), 0xFF) / 255.0
   local b = bit.band(color_int, 0xFF) / 255.0
   return r, g, b, a
end

function argb_to_vec4(color_int)
   local r, g, b, a = argb_to_rgba(color_int)
   return mimgui.ImVec4(r, g, b, a)
end

local MAIN_TITLES = {
   editor = u8"Редактирование",
   list   = u8"Список объявлений",
   menu   = u8"Категории"
}

local MAIN_EMO = {
   editor = ":u1f4dd:",
   list   = ":u1f4cb:",
   menu   = ":u1f5c2:"
}

local SETTINGS_TITLES = {
   settings  = u8"Основное",
   stats     = u8"Статистика",
   templates = u8"Шаблоны",
   blacklist = u8"Чёрный список",
   info      = u8"Информация"
}

local SETTINGS_EMO = {
   settings  = ":u2699:",
   stats     = ":u1f4ca:",
   templates = ":u1f4c4:",
   blacklist = ":u1f6ab:",
   info      = ":u1fc27:"
}

local LIST_HINT = u8"Стрелки - выбор     Enter - открыть     Esc - закрыть"

local SETTINGS_TABS = {
   { "settings",  "Основное",      "settings",    ":u2699:"  },
   { "stats",     "Статистика",    "chart-bar",   ":u1f4ca:" },
   { "templates", "Шаблоны",       "file-text",   ":u1f4dd:" },
   { "blacklist", "Чёрный список", "ban",         ":u1f6ab:" },
   { "info",      "Информация",    "info-circle", ":u1fc27:" }
}

function updateMoonMonetColors()
   if MoonMonet then
      local baseColor = tonumber(cfg.settings.moonmonetBaseColor) or 0xFF00BABE
      local ok, res = pcall(MoonMonet.buildColors, baseColor, 1.0, true)
      moonmonetColors = ok and res or nil
      if not ok then
         logLine('WARN', 'Ошибка палитры MoonMonet: ' .. tostring(res))
      end
   else
      moonmonetColors = nil
   end
end

local iconRanges = nil
local FONT_SIZE = { small = 15.0, main = 19.0, big = 31.0, huge = 46.0 }
local fonts = { small = nil, main = nil, big = nil, huge = nil }

local state = {
   active = cfg.settings.active or false,
   expectedSender = nil,
   templates = {},
   soundEnabled = cfg.settings.soundEnabled or false,
   soundVolume = cfg.settings.soundVolume or 50,
   autoApprove = cfg.settings.autoApprove or false,
   autoCatchByCommand = cfg.settings.autoCatchByCommand or false,
   quickEditButtons = cfg.settings.quickEditButtons ~= false,
   chatEmoji = cfg.settings.chatEmoji ~= false,
   chatEmojiLevel = tonumber(cfg.settings.chatEmojiLevel) or 2,
   silent = cfg.settings.silentMode == true,
   isProcessing = false,
   newsredakMode = false,
   isVipAd = false,
   prioritySearching = false,
   senderIndex = {},
   awaitingSendResult = false,
   cooldownUntil = 0,
   sendAttemptToken = 0,
   sendMode = nil,
   pendingSentText = nil,
   pendingSentFor = nil,
   queueAutomationActive = false,
   queuePaused = false,
   queueContinueAt = 0,
   autoApproveAt = 0,
   autoSkipAt = 0,
   recentSkips = {},
   lastSkipPrune = 0,
   sendRetryCount = 0,
   releaseEditorUntil = 0,
   waitingEditorUntil = 0,
   doneTimes = {},
   usedTemplate = false,
   templateMatch = nil,
   validation = nil,
   autoFixApplied = nil,
   alertedQueueCount = 0
}

local suppressNextMenu = false
local lastCatchTime = 0

local windowState = {
   mainWindow = new.bool(false),
   settingsWindow = new.bool(false),
   currentView = "idle",
   activeSettingsTab = "settings"
}

local menuData = {
   items = {},
   dialogId = 0
}

local listData = {
   headers = {},
   entries = {},
   selectedIndex = -1,
   dialogId = 0,
   highlightIndices = {}
}

local editorData = {
   sender = "",
   time = "",
   message = "",
   inputBuffer = new.char[4096](),
   rejectBuffer = new.char[1024](),
   dialogId = 0,
   openTime = 0
}

local templateEditorData = {
   selectedIndex = -1,
   searchBuffer = new.char[256](),
   list = {},
   originalBuffer = new.char[4096](),
   editedBuffer = new.char[4096](),
   currentKey = nil,
   filter = ""
}

local DIALOG_ID = {
   EMPTY_QUEUE = 0,
   MAIN_MENU = 25900,
   AD_LIST = 556,
   AD_EDITOR = 557
}

local QUICK_EDIT_BUTTON_SECTIONS = {
   {
      title = "Действия",
      buttonsPerRow = 3,
      buttons = {
         { label = "Куплю",   value = "Куплю ",   emo = ":u1fc1a:" },
         { label = "Продам",  value = "Продам ",  emo = ":u1fc1b:" },
         { label = "Обменяю", value = "Обменяю ", emo = ":u1fc1d:" },
         { label = "Сдам",    value = "Сдам ",    emo = ":u1fc1c:" },
         { label = "Арендую", value = "Арендую ", emo = ":u1fc1c:" },
         { label = "Сниму",   value = "Сниму ",   emo = ":u1fc1c:" }
      }
   },
   {
      title = "Справочники",
      buttonsPerRow = 3,
      picker = true,
      buttons = {
         { label = "Марки т/с", value = "vehicles",  emo = ":u1f697:" },
         { label = "Локации",   value = "locations", emo = ":u1f4cd:" },
         { label = "Бизнесы",   value = "business",  emo = ":u1f3ea:" },
         { label = "Жильё",     value = "houses",    emo = ":u1f3e0:" },
         { label = "Наборы",    value = "presets",   emo = ":u1f4c4:" }
      }
   },
   {
      title = "Сокращения",
      buttonsPerRow = 4,
      buttons = {
         { label = "а/м", value = "а/м " },
         { label = "т/с", value = "т/с " },
         { label = "л/д", value = "л/д " },
         { label = "г/ф", value = "г/ф " },
         { label = "в/т", value = "в/т " },
         { label = "м/т", value = "м/т " },
         { label = "с/м", value = "с/м " },
         { label = "в/с", value = "в/с " },
         { label = "д/т", value = "д/т " },
         { label = "р/с", value = "р/с " },
         { label = "о/п", value = "о/п " },
         { label = "п/м", value = "п/м " },
         { label = "а/с", value = "а/с " },
         { label = "п/т", value = "п/т " },
         { label = "б/з", value = "б/з " },
         { label = "н/з", value = "н/з " },
         { label = "л/о", value = "л/о " },
         { label = "м/ф", value = "м/ф " },
         { label = "ч/д", value = "ч/д " },
         { label = "в/о", value = "в/о " }
      }
   },
   {
      title = "Цена и условия",
      buttonsPerRow = 3,
      buttons = {
         { label = "Цена:",       value = "Цена: ",       emo = ":u1fc22:" },
         { label = "Цена за шт:", value = "Цена за шт: ", emo = ":u1fc22:" },
         { label = "Бюджет:",     value = "Бюджет: ",     emo = ":u1f4b0:" },
         { label = "Договорная",  value = "Договорная",   emo = ":u1f4b1:" },
         { label = "Свободный",   value = "Свободный",    emo = ":u1f4b5:" },
         { label = "Торг",        value = "Торг",         emo = ":u1f91d:" }
      }
   },
   {
      title = "Числа",
      buttonsPerRow = 6,
      buttons = {
         { label = "1", value = "1", raw = true },
         { label = "2", value = "2", raw = true },
         { label = "3", value = "3", raw = true },
         { label = "4", value = "4", raw = true },
         { label = "5", value = "5", raw = true },
         { label = "6", value = "6", raw = true },
         { label = "7", value = "7", raw = true },
         { label = "8", value = "8", raw = true },
         { label = "9", value = "9", raw = true },
         { label = "0", value = "0", raw = true },
         { label = ".", value = ".", raw = true },
         { label = ",", value = ",", raw = true }
      }
   },
   {
      title = "Символы",
      buttonsPerRow = 5,
      buttons = {
         { label = "$", value = "$", raw = true },
         { label = "\"", value = "\"", raw = true },
         { label = "тыс.", value = "тыс. " },
         { label = "млн", value = "млн " },
         { label = "млрд", value = "млрд " }
      }
   }
}

local QUICK_PICKERS = {
   vehicles = {
      title = "Марки транспорта",
      hint = "Название модели...",
      search = true,
      wrap = true,
      items = {
         'Admiral', 'Alpha', 'Ambulance', 'Andromada', 'AT-400', 'Bandito', 'Banshee',
         'Barracks', 'Beagle', 'Benson', 'Berkley\'s RC Van', 'BF Injection', 'BF-400',
         'Bike', 'Blade', 'Blista Compact', 'Bloodring Banger', 'BMX', 'Bobcat', 'Boxville',
         'Bravura', 'Broadway', 'Buccaneer', 'Buffalo', 'Bullet', 'Burrito', 'Bus', 'Cabbie',
         'Caddy', 'Cadrona', 'Camper', 'Cargobob', 'Cement Truck', 'Cheetah', 'Cloverleaf',
         'Club', 'Coach', 'Coastguard', 'Comet', 'Cropduster', 'DFT-30', 'Dinghy', 'Dodo',
         'Dozer', 'Dumper', 'Elegant', 'Elegy', 'Emperor', 'Enforcer', 'Esperanto', 'Euros',
         'Faggio', 'FBI Rancher', 'FBI Truck', 'FCR-900', 'Feltzer', 'Firetruck', 'Flash',
         'Flatbed', 'Forklift', 'Fortune', 'Freeway', 'Glendale', 'Greenwood', 'Hermes',
         'Hotdog', 'Hotknife', 'Hotring Racer', 'HPV1000', 'Hunter', 'Huntley', 'Hustler',
         'Hydra', 'Infernus', 'Intruder', 'Jester', 'Jetmax', 'Journey', 'Kart', 'Landstalker',
         'Launch', 'Leviathan', 'Linerunner', 'Majestic', 'Manana', 'Marquis', 'Maverick',
         'Merit', 'Mesa', 'Monster', 'Moonbeam', 'Mountain Bike', 'Mower', 'Mr Whoopee',
         'Mule', 'Nebula', 'Nevada', 'News Chopper', 'News Van', 'NRG-500', 'Oceanic',
         'Packer', 'Patriot', 'PCJ-600', 'Perennial', 'Petrol Tanker', 'Phoenix', 'Picador',
         'Pizzaboy', 'Police LS', 'Police LV', 'Police SF', 'Police Ranger', 'Pony',
         'Predator', 'Premier', 'Previon', 'Primo', 'Quad', 'Raindance', 'Rancher', 'Reefer',
         'Regina', 'Remington', 'Rhino', 'Roadtrain', 'Romero', 'Rumpo', 'Rustler', 'Sabre',
         'Sadler', 'Sanchez', 'Sandking', 'Savanna', 'Seasparrow', 'Securicar', 'Sentinel',
         'Shamal', 'Skimmer', 'Slamvan', 'Solair', 'Sparrow', 'Speeder', 'Squalo', 'Stafford',
         'Stallion', 'Stratum', 'Stretch', 'Sultan', 'Sunrise', 'Super GT', 'S.W.A.T.',
         'Tahoma', 'Tampa', 'Taxi', 'Tornado', 'Towtruck', 'Tractor', 'Trashmaster', 'Tropic',
         'Turismo', 'Uranus', 'Utility Van', 'Vincent', 'Virgo', 'Voodoo', 'Vortex', 'Walton',
         'Washington', 'Wayfarer', 'Willard', 'Windsor', 'Yankee', 'Yosemite', 'ZR-350'
      }
   },
   locations = {
      title = "Локации",
      hint = "Город, район, организация...",
      search = true,
      items = {
         'г. Лос-Сантос', 'г. Сан-Фиерро', 'г. Лас-Вентурас', 'г. Вайс-Сити',
         'д. Паломино Крик', 'д. Ред Каунти', 'д. Монтгомери', 'д. Лас Барранкас',
         'д. Эйнджел Пайн', 'д. Эль Кебрадос', 'д. Лас Пайсадас', 'д. Тьерра Робада',
         'д. Блуберри', 'д. Диллимор', 'д. Форт Карсон', 'д. Байсайд',
         'в любой точке штата', 'в опасном районе', 'в интерьере',
         'Полиция ЛС', 'Полиция СФ', 'Полиция ЛВ', 'Полиция ВС', 'Областная полиция',
         'ФБР', 'Армия ЛС', 'Армия СФ', 'Тюрьма строгого режима',
         'СМИ ЛС', 'СМИ СФ', 'СМИ ЛВ', 'СМИ ВС',
         'Больница ЛС', 'Больница СФ', 'Больница ЛВ', 'Больница ВС', 'Больница Джефферсон',
         'Правительство', 'Суд', 'Центр лицензирования', 'Пожарный департамент',
         'Страховая компания', 'Автошкола', 'Банк', 'Мэрия', 'Автосалон', 'Аэропорт',
         'Вокзал', 'Пляж', 'Спортзал',
         'Grove Street', 'Los Santos Vagos', 'East Side Ballas', 'Varrios Los Aztecas',
         'The Rifa', 'Night Wolves', 'Russian Mafia', 'Yakuza', 'La Cosa Nostra',
         'Warlock MC', 'Tierra Robada Bikers'
      }
   },
   business = {
      title = "Бизнесы",
      hint = "Название бизнеса...",
      search = true,
      wrap = true,
      items = {
         'АЗС', 'Водная АЗС', 'Бар', 'Отель', 'Закусочная', 'Ларёк с уличной едой',
         'Магазин 24/7', 'Амуниция', 'Автомастерская', 'СТО', 'Магазин тюнинга',
         'Аренда транспорта', 'Магазин аксессуаров', 'Магазин одежды', 'Ферма', 'Авторынок',
         'Автомойка', 'Салон трейлеров', 'Телефонная компания', 'Рекламные баннеры',
         'Телефонные будки', 'Школа танцев', 'Спортзал', 'Магазин рыбалки', 'Ломбард',
         'Шахта', 'Наземная нефтевышка', 'Водная нефтевышка', 'Эликсир Мастер',
         'Секонд Хенд', 'Мастерская одежды', 'Магазин видеокарт'
      }
   },
   houses = {
      title = "Жильё",
      items = {
         'дом в', 'дом с гаражом в', 'дом с подвалом в', 'дом с гаражом и подвалом в',
         'квартиру в', 'дом на колёсах', 'трейлер в', 'участок в'
      }
   },
   presets = {
      title = "Готовые объявления",
      preset = true,
      items = {
         'Проходит собеседование в организацию "". Ждём в холле',
         'Идёт набор в семью "". Пишите в ЛС',
         'Развитая семья "" ищет дальних родственников. Пишите в ЛС',
         'Ищу дальних родственников. Пишите в ЛС',
         'Продам дом с гаражом в г. Лос-Сантос. Цена: договорная',
         'Куплю а/м "" в хорошем состоянии. Бюджет: '
      }
   }
}

local VEHICLE_SET = {}
for _, name in ipairs(QUICK_PICKERS.vehicles.items) do
   VEHICLE_SET[lower1251(name)] = true
end

local CHAT = {
   TAG   = "{88C0D0}",
   SEP   = "{4C566A}",
   TEXT  = "{D8DEE9}",
   HI    = "{ECEFF4}",
   OK    = "{A3BE8C}",
   WARN  = "{EBCB8B}",
   ERR   = "{BF616A}",
   INFO  = "{81A1C1}",
   MUTED = "{7B88A1}",
   ARROW = "\187"
}

local EMO = {
   OK       = ":u2705:",
   ERR      = ":u274c:",
   WARN     = ":u26a0:",
   INFO     = ":u1f4ac:",
   VIP      = ":u1f48e:",
   BAN      = ":u1f6ab:",
   TPL      = ":u1f4dd:",
   ROCKET   = ":u1f680:",
   OK2      = ":u2714:",
   ERR2     = ":u2716:",
   FAIL     = ":u1f6b7:",
   STOP     = ":u26d4:",
   SOS      = ":u1f198:",
   NEW      = ":u1f195:",
   TOP      = ":u1f51d:",
   SOON     = ":u1f51c:",
   COOL     = ":u1f192:",
   NG       = ":u1f196:",
   VS       = ":u1f19a:",
   BANG     = ":u2757:",
   ASK      = ":u2753:",
   BANG2    = ":u203c:",
   WAT      = ":u2049:",
   MIC      = ":u1f3a4:",
   MIC2     = ":u1f399:",
   RADIO    = ":u1f4fb:",
   LIVE     = ":u1f534:",
   REC      = ":u23fa:",
   OFFAIR   = ":u26ab:",
   NEWS     = ":u1f4f0:",
   NEWS2    = ":u1f5de:",
   MEGA     = ":u1f4e3:",
   SPEAKER  = ":u1f4e2:",
   ANTENNA  = ":u1f4e1:",
   TV       = ":u1f4fa:",
   HEADPH   = ":u1f3a7:",
   TALK     = ":u1f5e3:",
   QUOTE    = ":u1f5e8:",
   THINK    = ":u1f4ad:",
   MIXER    = ":u1f39a:",
   MONEY    = ":u1f4b0:",
   CASH     = ":u1f4b5:",
   SPEND    = ":u1f4b8:",
   CARD     = ":u1f4b3:",
   COIN     = ":u1fa99:",
   RECEIPT  = ":u1f9fe:",
   CALC     = ":u1f9ee:",
   BANK     = ":u1f3e6:",
   CHART    = ":u1f4ca:",
   UP       = ":u1f4c8:",
   DOWN     = ":u1f4c9:",
   CASE     = ":u1f4bc:",
   EXCH     = ":u1f4b1:",
   QUEUE    = ":u1f4e5:",
   SENT     = ":u1f4e4:",
   MAIL     = ":u1f4e7:",
   INBOX    = ":u1f4e8:",
   BOX      = ":u1f4e6:",
   WAIT     = ":u231b:",
   WAIT2    = ":u23f3:",
   TIMER    = ":u23f1:",
   ALARM    = ":u23f0:",
   CD       = ":u1f552:",
   DATE     = ":u1f4c5:",
   CAL      = ":u1f4c6:",
   BOT      = ":u1f916:",
   PLAY     = ":u23ef:",
   PAUSE    = ":u23f8:",
   HALT     = ":u23f9:",
   NEXT     = ":u23ed:",
   LOOP     = ":u1f501:",
   RETRY    = ":u1f504:",
   SYNC     = ":u1f503:",
   GEAR     = ":u2699:",
   WRENCH   = ":u1f527:",
   TOOLS    = ":u1f6e0:",
   TOOLBOX  = ":u1f9f0:",
   BULB     = ":u1f4a1:",
   SEARCH   = ":u1f50d:",
   PIN      = ":u1f4cc:",
   LABEL    = ":u1f3f7:",
   LINK     = ":u1f517:",
   CLIP     = ":u1f4ce:",
   CLEAN    = ":u1f9f9:",
   TRASH    = ":u1f5d1:",
   SAVE     = ":u1f4be:",
   FOLDER   = ":u1f4c1:",
   FILE     = ":u1f4c4:",
   LIST     = ":u1f4cb:",
   BOOK     = ":u1f4d6:",
   PRINT    = ":u1f5a8:",
   BELL     = ":u1f514:",
   NOBELL   = ":u1f515:",
   SOUND    = ":u1f50a:",
   MUTE     = ":u1f507:",
   LOCK     = ":u1f512:",
   UNLOCK   = ":u1f513:",
   KEY      = ":u1f511:",
   SHIELD   = ":u1f6e1:",
   COP      = ":u1f46e:",
   DETECT   = ":u1f575:",
   GUARD    = ":u1f482:",
   SCALES   = ":u2696:",
   EYES     = ":u1f440:",
   SIREN    = ":u1f6a8:",
   ANGER    = ":u1f4a2:",
   BOOM     = ":u1f4a5:",
   BOMB     = ":u1f4a3:",
   SKULL    = ":u1f480:",
   GHOST    = ":u1f47b:",
   CLOWN    = ":u1f921:",
   AFK      = ":u1f4a4:",
   CUP      = ":u1f3c6:",
   GOLD     = ":u1f947:",
   SILVER   = ":u1f948:",
   BRONZE   = ":u1f949:",
   MEDAL    = ":u1f3c5:",
   STAR     = ":u1f31f:",
   FIRE     = ":u1f525:",
   ZAP      = ":u26a1:",
   TADA     = ":u1f389:",
   GIFT     = ":u1f381:",
   DART     = ":u1f3af:",
   CROWN    = ":u1f451:",
   THUMB    = ":u1f44d:",
   THUMBD   = ":u1f44e:",
   CLAP     = ":u1f44f:",
   SHRUG    = ":u1f937:",
   FACEPALM = ":u1f926:",
   HAND     = ":u1f91d:",
   MUSCLE   = ":u1f4aa:",
   ARZ      = ":u1fc08:",
   AZ       = ":u1fc09:",
   AG       = ":u1fc0a:",
   RODINA   = ":u1fc0b:",
   AR_CASH  = ":u1fc22:",
   AR_CASHV = ":u1fc23:",
   BTC      = ":u1fc25:",
   EURO     = ":u1fc26:",
   AR_INFO  = ":u1fc27:",
   YT       = ":u1fc34:",
   TG       = ":u1fc39:",
   VKA      = ":u1fc3a:",
   BUY      = ":u1fc1a:",
   SELL     = ":u1fc1b:",
   RENT     = ":u1fc1c:",
   TRADE    = ":u1fc1d:",
   REDCODE  = ":u1fc00:",
   VC       = ":uf264:",
   SUF_K    = ":uf265:",
   SUF_KK   = ":uf266:",
   SUF_M    = ":uf267:"
}

local EMO_BY_COLOR = {
   [CHAT.OK]    = EMO.OK,
   [CHAT.ERR]   = EMO.ERR,
   [CHAT.WARN]  = EMO.WARN,
   [CHAT.INFO]  = EMO.INFO,
   [CHAT.TEXT]  = "",
   [CHAT.MUTED] = ""
}

function chat(body, emo, force)
   if state.silent and not force then
      local head = body:sub(1, 8)
      if head ~= CHAT.ERR and head ~= CHAT.WARN then return end
   end
   local e = ""
   if state.chatEmoji and (state.chatEmojiLevel or 2) > 0 then
      local token
      if emo and (state.chatEmojiLevel or 2) >= 2 then
         token = EMO[emo] or (emo:sub(1, 1) == ":" and emo or nil)
      end
      token = token or EMO_BY_COLOR[body:sub(1, 8)]
      if token and token ~= "" then e = token .. " " end
   end
   sampAddChatMessage(CHAT.TAG .. "SMI " .. CHAT.SEP .. CHAT.ARROW .. " " .. e .. body, -1)
end

local AutoFix = {}

local KEEP_UPPER = {
   ["vip"] = true, ["сми"] = true, ["фбр"] = true, ["лс"] = true, ["сф"] = true,
   ["лв"] = true, ["вс"] = true, ["сша"] = true, ["ооо"] = true, ["ип"] = true,
   ["азс"] = true, ["сто"] = true, ["мвд"] = true, ["ск"] = true, ["гибдд"] = true
}

local MONEY_WORDS = {
   ["долларов"] = true, ["доллара"] = true, ["доллар"] = true,
   ["баксов"] = true, ["бакса"] = true, ["бакс"] = true,
   ["usd"] = true, ["у.е."] = true, ["уе"] = true
}

function ruleCapitalize(text)
   local pre, first, rest = text:match("^([^" .. ALPHA .. "]*)([" .. ALPHA .. "])(.*)$")
   if not first then return text end
   return pre .. upper1251(first) .. rest
end

AutoFix.rules = {
   {
      id = 'spaces',
      name = "Пробелы и знаки",
      fn = function(text)
         local t = text:gsub("%s+", " ")
         t = t:gsub("%s+([,%.:;!%?])", "%1")
         t = t:gsub("([,;:])([" .. ALPHA .. "])", "%1 %2")
         t = t:gsub("([" .. ALPHA .. "])%s*/%s*([" .. ALPHA .. "])", "%1/%2")
         t = t:gsub("^%s+", ""):gsub("%s+$", "")
         return t
      end
   },
   {
      id = 'repeats',
      name = "Повторы знаков",
      fn = function(text)
         local t = text:gsub("%.%.%.%.+", "...")
         for _, ch in ipairs({ "!", "?", ")", "(", ",", ";", ":", "-" }) do
            t = t:gsub("%" .. ch .. "%" .. ch .. "+", ch)
         end
         return t
      end
   },
   {
      id = 'dupWords',
      name = "Дубли слов",
      fn = function(text)
         local t = text
         for _ = 1, 2 do
            t = t:gsub("([" .. ALPHA .. "]+)(%s+)([" .. ALPHA .. "]+)", function(a, sp, b)
               if lower1251(a) == lower1251(b) then return a end
               return a .. sp .. b
            end)
         end
         return t
      end
   },
   {
      id = 'caps',
      name = "Снятие капса",
      fn = function(text)
         local up, low = 0, 0
         for i = 1, #text do
            local b = text:byte(i)
            if (b >= 65 and b <= 90) or (b >= 192 and b <= 223) or b == 168 then
               up = up + 1
            elseif (b >= 97 and b <= 122) or (b >= 224 and b <= 255) or b == 184 then
               low = low + 1
            end
         end
         if (up + low) < 6 or up <= low then return text end
         local out = text:gsub("[" .. ALPHA .. "%d/%-]+", function(word)
            local lw = lower1251(word)
            if KEEP_UPPER[lw] then return upper1251(word) end
            if VEHICLE_SET[lw] then return word end
            if word:find("%d") then return word end
            return lw
         end)
         return ruleCapitalize(out)
      end
   },
   {
      id = 'currency',
      name = "Формат валюты",
      fn = function(text)
         local t = text:gsub("([%d%.,]+)(%s*)([" .. ALPHA .. "%.]+)", function(num, sp, word)
            local core = word:gsub("%.+$", "")
            if MONEY_WORDS[lower1251(word)] then return "$" .. num end
            if MONEY_WORDS[lower1251(core)] then return "$" .. num .. word:sub(#core + 1) end
            return num .. sp .. word
         end)
         t = t:gsub("([%d%.,]+)%s*%$", "$%1")
         t = t:gsub("%$%s+([%d])", "$%1")
         return t
      end
   },
   {
      id = 'trailingDot',
      name = "Точка в конце",
      fn = function(text)
         if text:sub(-3) == "..." then return text end
         return (text:gsub("%s*%.+%s*$", ""))
      end
   },
   {
      id = 'capitalize',
      name = "Заглавная буква",
      fn = ruleCapitalize
   }
}

function AutoFix.enabled(id)
   local v = cfg.autofix[id]
   return v ~= false
end

function AutoFix.apply(text)
   if not text or text == "" then return text, {} end
   local out, applied = text, {}
   for _, rule in ipairs(AutoFix.rules) do
      if AutoFix.enabled(rule.id) then
         local ok, res = pcall(rule.fn, out)
         if ok and type(res) == 'string' and res ~= out then
            out = res
            applied[#applied + 1] = rule.name
         end
      end
   end
   return out, applied
end

local Validate = {}

function Validate.numbers(text)
   local set = {}
   for num in (text or ""):gmatch("%d[%d%.,]*") do
      local clean = num:gsub("[%.,]", "")
      clean = clean:gsub("^0+", "")
      if clean ~= "" then set[clean] = (set[clean] or 0) + 1 end
   end
   return set
end

function Validate.run(text, original)
   local issues, level = {}, 'ok'

   local function add(severity, message)
      issues[#issues + 1] = { severity = severity, message = message }
      if severity == 'bad' then
         level = 'bad'
      elseif level ~= 'bad' then
         level = 'warn'
      end
   end

   local trimmed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if trimmed == "" then
      add('bad', "Пустой текст")
      return { level = 'bad', issues = issues }
   end

   if cfg.settings.validateEnabled == false then
      return { level = 'ok', issues = issues }
   end

   local minLen = tonumber(cfg.settings.minAdLength) or 8
   local maxLen = tonumber(cfg.settings.maxAdLength) or 180
   local len = #trimmed

   if len < minLen then
      add('bad', ("Слишком короткое: %d символов из %d"):format(len, minLen))
   end
   if len > maxLen then
      add('bad', ("Превышен лимит: %d символов из %d"):format(len, maxLen))
   end

   if original and original ~= "" then
      local co, ce = detectCategory(original), detectCategory(trimmed)
      if co ~= ce then
         add('warn', ("Категория изменилась: %s -> %s"):format(CAT_NAMES[co], CAT_NAMES[ce]))
      end

      local origNums = Validate.numbers(original)
      local editNums = Validate.numbers(trimmed)
      for num in pairs(origNums) do
         if not editNums[num] then
            add('warn', "Из текста пропало число: " .. num)
            break
         end
      end
   end

   return { level = level, issues = issues }
end

function getAccentVec4()
   if moonmonetColors then
      return argb_to_vec4(moonmonetColors.accent1.color_500)
   else
      return mimgui.ImVec4(0.28, 0.65, 0.40, 1.0)
   end
end

function withFont(key, func)
   local f = fonts[key]
   if f then mimgui.PushFont(f) end
   func()
   if f then mimgui.PopFont() end
end

local UI = { _sub = {}, alpha = 1.0, fx = (cfg.settings.fxAnimations ~= false) }

function UI.u32(c)
   if UI.alpha >= 0.999 then return mimgui.ColorConvertFloat4ToU32(c) end
   return mimgui.ColorConvertFloat4ToU32(mimgui.ImVec4(c.x, c.y, c.z, c.w * UI.alpha))
end

function UI.v2(x, y) return mimgui.ImVec2(x, y) end
function UI.a(c, al) return mimgui.ImVec4(c.x, c.y, c.z, al) end

function UI.lerpC(a, b, t)
   return mimgui.ImVec4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t,
                        a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
end

UI._hv, UI._hvGc = {}, 0
function UI.hover(id, on, speed)
   local now = os.clock()
   local rec = UI._hv[id]
   if rec == nil then
      rec = { v = on and 1 or 0, t = now }
      UI._hv[id] = rec
   end
   rec.t = now
   local target = on and 1 or 0
   rec.v = rec.v + (target - rec.v) * math.min(1, mimgui.GetIO().DeltaTime * (speed or 14))
   if math.abs(target - rec.v) < 0.004 then rec.v = target end

   if now - UI._hvGc > C.HOVER_GC_SEC then
      UI._hvGc = now
      for key, item in pairs(UI._hv) do
         if now - item.t > C.HOVER_GC_SEC then UI._hv[key] = nil end
      end
   end
   return rec.v
end

UI._sp = {}
function UI.spring(id, target, stiff)
   local s = UI._sp[id]
   if not s then s = { v = target }; UI._sp[id] = s end
   s.v = s.v + (target - s.v) * math.min(1, mimgui.GetIO().DeltaTime * (stiff or 16))
   if math.abs(target - s.v) < 0.25 then s.v = target end
   return s.v
end

UI._num = {}
function UI.num(id, target, dur)
   local c = UI._num[id]
   if not c then
      c = { from = 0, to = target, at = os.clock(), cur = 0 }
      UI._num[id] = c
   elseif c.to ~= target then
      c.from, c.to, c.at = c.cur, target, os.clock()
   end
   c.cur = Ease.get(c.from, c.to, c.at, dur or 0.75, 'outQuint')
   return c.cur
end

function UI.resetNums() UI._num = {} end

UI._rp, UI._rpN = {}, 0
function UI.rippleHit(id, pos)
   local mp = mimgui.GetIO().MousePos
   if UI._rp[id] == nil then
      UI._rpN = UI._rpN + 1
      if UI._rpN > 64 then UI._rp, UI._rpN = {}, 0 end
   end
   UI._rp[id] = { x = mp.x - pos.x, y = mp.y - pos.y, at = os.clock() }
end

function UI.rippleDraw(DL, id, pos, w, h, col, round)
   local r = UI._rp[id]
   if not r then return end
   local k = (os.clock() - r.at) / 0.55
   if k >= 1 then UI._rp[id] = nil; UI._rpN = math.max(0, UI._rpN - 1) return end
   local maxR = math.sqrt(w * w + h * h)
   local f = 1 - (1 - k) ^ 3
   DL:PushClipRect(pos, UI.v2(pos.x + w, pos.y + h), true)
   DL:AddCircleFilled(UI.v2(pos.x + r.x, pos.y + r.y), maxR * f,
      UI.u32(UI.a(col or UI.C.ACCENT, 0.22 * (1 - k))), 32)
   DL:PopClipRect()
end

UI._path, UI._pathN = {}, 0
function UI.roundPath(w, h, r, N)
   local key = ("%d_%d_%d_%d"):format(w, h, r, N)
   local cached = UI._path[key]
   if cached then return cached end
   if UI._pathN > 24 then UI._path, UI._pathN = {}, 0 end

   local raw, seg = {}, 10
   local function arc(cx, cy, a0, a1)
      for i = 0, seg do
         local a = a0 + (a1 - a0) * i / seg
         raw[#raw + 1] = { cx + math.cos(a) * r, cy + math.sin(a) * r }
      end
   end
   arc(w - r, r,     -math.pi / 2, 0)
   arc(w - r, h - r, 0, math.pi / 2)
   arc(r,     h - r, math.pi / 2, math.pi)
   arc(r,     r,     math.pi, math.pi * 1.5)
   raw[#raw + 1] = { raw[1][1], raw[1][2] }

   local acc, total = { [1] = 0 }, 0
   for i = 2, #raw do
      local dx, dy = raw[i][1] - raw[i - 1][1], raw[i][2] - raw[i - 1][2]
      total = total + math.sqrt(dx * dx + dy * dy)
      acc[i] = total
   end
   if total <= 0 then return {} end

   local out, j = {}, 2
   for i = 0, N - 1 do
      local d = total * i / N
      while j < #raw and acc[j] < d do j = j + 1 end
      local span = acc[j] - acc[j - 1]
      local t = (span > 0) and ((d - acc[j - 1]) / span) or 0
      out[i + 1] = {
         raw[j - 1][1] + (raw[j][1] - raw[j - 1][1]) * t,
         raw[j - 1][2] + (raw[j][2] - raw[j - 1][2]) * t
      }
   end
   UI._path[key] = out
   UI._pathN = UI._pathN + 1
   return out
end

UI.previewC, UI.previewAt = nil, 0
function UI.glow()
   if UI.previewC and (os.clock() - UI.previewAt) < 0.15 then return UI.previewC end
   return UI.C.ACCENT
end

UI._blobs = {
   { 0.20, 0.12, 0.24, 0.060, 0.29 },
   { 0.83, 0.20, 0.19, 0.050, 0.21 },
   { 0.55, 0.94, 0.30, 0.042, 0.13 }
}

function UI.Ambient(o, w, h)
   if not UI.fx then return end
   local DL = mimgui.GetWindowDrawList()
   local t  = os.clock()
   local AC = UI.glow()
   DL:PushClipRect(o, UI.v2(o.x + w, o.y + h), true)

   local B = UI._blobs
   for i = 1, 3 do
      local b  = B[i]
      local cx = o.x + w * (b[1] + 0.055 * math.sin(t * b[5] + i * 1.7))
      local cy = o.y + h * (b[2] + 0.070 * math.cos(t * b[5] * 1.31 + i * 2.3))
      local R  = math.max(w, h) * b[3]
      for s = 6, 1, -1 do
         DL:AddCircleFilled(UI.v2(cx, cy), R * s / 6,
            UI.u32(UI.a(AC, b[4] * (1 - s / 7))), 32)
      end
   end

   local mp = mimgui.GetIO().MousePos
   if mp.x > o.x and mp.x < o.x + w and mp.y > o.y and mp.y < o.y + h then
      for s = 5, 1, -1 do
         DL:AddCircleFilled(UI.v2(mp.x, mp.y), 30 * s,
            UI.u32(UI.a(AC, 0.028 * (1 - s / 6))), 28)
      end
   end
   DL:PopClipRect()
end

function UI.NeonBorder(o, w, h, r)
   if not UI.fx then return end
   local DL  = mimgui.GetWindowDrawList()
   local N   = 132
   local ins = 2
   local p   = UI.roundPath(math.floor(w - ins * 2), math.floor(h - ins * 2),
                            math.max(2, r - ins), N)
   if #p < N then return end

   local AC   = UI.glow()
   local head = (os.clock() * 0.115) % 1
   for tail = 0, 1 do
      local hp = (head + tail * 0.5) % 1
      for i = 1, N do
         local d = math.abs((i - 1) / N - hp)
         if d > 0.5 then d = 1 - d end
         local k = 1 - d / 0.105
         if k > 0.02 then
            local a, b = p[i], p[i % N + 1]
            DL:AddLine(
               UI.v2(o.x + ins + a[1], o.y + ins + a[2]),
               UI.v2(o.x + ins + b[1], o.y + ins + b[2]),
               UI.u32(UI.a(AC, 0.85 * k * k)), 2.2)
         end
      end
   end
end

function UI.contrast(c)
   local lum = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
   return (lum > 0.55) and mimgui.ImVec4(0.05, 0.05, 0.05, 1.0)
                        or mimgui.ImVec4(1.00, 1.00, 1.00, 1.0)
end

function UI.shade(c, k)
   local function m(v) return math.max(0, math.min(1, v + k)) end
   return mimgui.ImVec4(m(c.x), m(c.y), m(c.z), c.w)
end

function UI.mm(colorInt, alpha)
   local c = argb_to_vec4(colorInt)
   return mimgui.ImVec4(c.x, c.y, c.z, alpha or c.w)
end

UI.C = {
   BG_MAIN = mimgui.ImVec4(0.06, 0.06, 0.05, 0.97),
   BG_SIDE = mimgui.ImVec4(0.09, 0.09, 0.07, 0.99),
   SURFACE = mimgui.ImVec4(1.00, 1.00, 1.00, 0.045),
   HOVER   = mimgui.ImVec4(1.00, 1.00, 1.00, 0.085),
   ACTIVE  = mimgui.ImVec4(1.00, 1.00, 1.00, 0.120),
   LINE    = mimgui.ImVec4(1.00, 1.00, 1.00, 0.100),
   TEXT    = mimgui.ImVec4(0.93, 0.94, 0.92, 1.00),
   DIM     = mimgui.ImVec4(0.66, 0.67, 0.64, 1.00),
   MUTE    = mimgui.ImVec4(0.43, 0.44, 0.42, 1.00),
   DANGER  = mimgui.ImVec4(0.85, 0.32, 0.32, 1.00),
   SUCCESS = mimgui.ImVec4(0.45, 0.80, 0.45, 1.00),
   GOLD    = mimgui.ImVec4(1.00, 0.85, 0.55, 1.00),
   WARNC   = mimgui.ImVec4(0.95, 0.72, 0.35, 1.00),
   ACCENT  = mimgui.ImVec4(0.65, 0.72, 0.16, 1.00),
   ON_ACC  = mimgui.ImVec4(0.07, 0.07, 0.05, 1.00)
}

function UI.refresh()
   local ac = getAccentVec4()
   UI.C.ACCENT = mimgui.ImVec4(ac.x, ac.y, ac.z, 1.0)
   UI.C.ON_ACC = UI.contrast(UI.C.ACCENT)

   if moonmonetColors then
      local M = moonmonetColors
      UI.C.BG_MAIN = UI.mm(M.neutral1.color_1000, 0.97)
      UI.C.BG_SIDE = UI.mm(M.neutral1.color_900,  0.99)
      UI.C.TEXT    = UI.mm(M.neutral1.color_50,   1.00)
      UI.C.DIM     = UI.mm(M.neutral2.color_200,  0.88)
      UI.C.MUTE    = UI.mm(M.neutral2.color_400,  0.80)
   else
      UI.C.BG_MAIN = mimgui.ImVec4(0.048 + ac.x * 0.035, 0.048 + ac.y * 0.035, 0.048 + ac.z * 0.035, 0.97)
      UI.C.BG_SIDE = mimgui.ImVec4(0.048 + ac.x * 0.090, 0.048 + ac.y * 0.090, 0.048 + ac.z * 0.090, 0.99)
      UI.C.TEXT    = mimgui.ImVec4(0.93, 0.94, 0.92, 1.00)
      UI.C.DIM     = mimgui.ImVec4(0.66, 0.67, 0.64, 1.00)
      UI.C.MUTE    = mimgui.ImVec4(0.43, 0.44, 0.42, 1.00)
   end
end

UI.emojiReady = false
UI._emoCache  = {}

local EMO_WHITE = mimgui.ImVec4(1, 1, 1, 1)

function emoRec(key)
   if not UI.emojiReady or not key then return nil end
   local e = UI._emoCache[key]
   if e == nil then
      e = emoji.get(key) or false
      UI._emoCache[key] = e
   end
   return e or nil
end

function UI.emo(DL, key, x, y, size, alpha)
   local e = emoRec(key)
   if not e then return 0 end
   local w = size * e.cells
   local col = (alpha and alpha < 0.999)
      and UI.u32(mimgui.ImVec4(1, 1, 1, alpha)) or UI.u32(EMO_WHITE)
   DL:AddImage(emoji.texture, UI.v2(x, y), UI.v2(x + w, y + size), e.uv0, e.uv1, col)
   return w
end

function UI.emoW(key, size)
   local e = emoRec(key)
   return e and size * e.cells or 0
end

function UI.emoMid(DL, key, x, cy, size, alpha)
   return UI.emo(DL, key, x, cy - size / 2, size, alpha)
end

function UI.applyStyle()
   UI.refresh()
   local s, K = mimgui.GetStyle(), mimgui.Col
   local c = s.Colors

   s.WindowRounding    = 14.0
   s.ChildRounding     = 10.0
   s.FrameRounding     = 8.0
   s.PopupRounding     = 10.0
   s.GrabRounding      = 6.0
   s.TabRounding       = 8.0
   s.ScrollbarRounding = 9.0
   s.ScrollbarSize     = 18.0
   s.GrabMinSize       = 12.0
   s.AntiAliasedLines  = true
   s.AntiAliasedFill   = true
   s.WindowTitleAlign  = UI.v2(0.5, 0.5)
   s.ButtonTextAlign   = UI.v2(0.5, 0.5)

   s.WindowBorderSize  = 0.0
   s.ChildBorderSize   = 0.0
   s.FrameBorderSize   = 0.0
   s.PopupBorderSize   = 0.0
   s.WindowPadding     = UI.v2(18, 18)
   s.FramePadding      = UI.v2(12, 9)
   s.ItemSpacing       = UI.v2(9, 7)
   s.ItemInnerSpacing  = UI.v2(7, 5)

   c[K.Text]                 = UI.C.TEXT
   c[K.TextDisabled]         = UI.C.MUTE
   c[K.WindowBg]             = UI.C.BG_MAIN
   c[K.ChildBg]              = mimgui.ImVec4(0, 0, 0, 0)
   c[K.PopupBg]              = UI.C.BG_SIDE
   c[K.Border]               = mimgui.ImVec4(0, 0, 0, 0)
   c[K.BorderShadow]         = mimgui.ImVec4(0, 0, 0, 0)
   c[K.FrameBg]              = UI.C.SURFACE
   c[K.FrameBgHovered]       = UI.C.HOVER
   c[K.FrameBgActive]        = UI.C.ACTIVE
   c[K.Button]               = UI.C.SURFACE
   c[K.ButtonHovered]        = UI.C.HOVER
   c[K.ButtonActive]         = UI.C.ACTIVE
   c[K.Header]               = UI.C.SURFACE
   c[K.HeaderHovered]        = UI.C.HOVER
   c[K.HeaderActive]         = UI.C.ACTIVE
   c[K.Separator]            = UI.C.LINE
   c[K.SeparatorHovered]     = UI.a(UI.C.ACCENT, 0.5)
   c[K.SeparatorActive]      = UI.C.ACCENT
   c[K.CheckMark]            = UI.C.ACCENT
   c[K.SliderGrab]           = UI.C.ACCENT
   c[K.SliderGrabActive]     = UI.C.ACCENT
   c[K.ScrollbarBg]          = mimgui.ImVec4(0, 0, 0, 0)
   c[K.ScrollbarGrab]        = UI.a(UI.C.ACCENT, 0.50)
   c[K.ScrollbarGrabHovered] = UI.a(UI.C.ACCENT, 0.75)
   c[K.ScrollbarGrabActive]  = UI.a(UI.C.ACCENT, 0.95)
   c[K.ResizeGrip]           = mimgui.ImVec4(0, 0, 0, 0)
   c[K.ResizeGripHovered]    = UI.a(UI.C.ACCENT, 0.35)
   c[K.ResizeGripActive]     = UI.a(UI.C.ACCENT, 0.60)
   c[K.Tab]                  = UI.C.SURFACE
   c[K.TabHovered]           = UI.C.HOVER
   c[K.TabActive]            = UI.C.ACTIVE
   c[K.TitleBg]              = UI.C.BG_MAIN
   c[K.TitleBgActive]        = UI.C.BG_MAIN
   c[K.TitleBgCollapsed]     = UI.C.BG_MAIN
end

function UI.SectionTitle(text, first)
   if not first then mimgui.Dummy(UI.v2(0, 14)) end
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local lh = mimgui.GetTextLineHeight()
   DL:AddRectFilled(UI.v2(pos.x, pos.y + 2), UI.v2(pos.x + 3, pos.y + lh - 2),
      UI.u32(UI.C.ACCENT), 1.5)
   DL:AddText(UI.v2(pos.x + 12, pos.y), UI.u32(UI.C.ACCENT), u8(text))
   mimgui.Dummy(UI.v2(0, lh + 4))
end

function UI.ToggleRow(label, ref, hint)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local w, H = mimgui.GetContentRegionAvail().x, 34

   mimgui.InvisibleButton("##tg_" .. label, UI.v2(w, H))
   local hov, changed = mimgui.IsItemHovered(), false
   if mimgui.IsItemClicked() then ref[0] = not ref[0]; changed = true end

   local hv = UI.hover("tg" .. label, hov)
   if hv > 0.002 then
      DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + H),
         UI.u32(UI.a(UI.C.HOVER, UI.C.HOVER.w * hv)), 7.0)
   end

   local on = ref[0]
   local p  = UI.hover("tg" .. label .. "_on", on, 17)
   local tx, ty = pos.x + 9, pos.y + (H - 19) / 2
   DL:AddRectFilled(UI.v2(tx, ty), UI.v2(tx + 40, ty + 19),
      UI.u32(UI.lerpC(mimgui.ImVec4(1, 1, 1, 0.10), UI.C.ACCENT, p)), 9.5)
   DL:AddCircleFilled(UI.v2(tx + 9.5 + 21 * p, ty + 9.5), 7.0,
      UI.u32(mimgui.ImVec4(0.97, 0.97, 0.95, 0.55 + 0.45 * p)), 20)

   local lbl, lx = u8(label), tx + 53
   local lsz = mimgui.CalcTextSize(lbl)
   DL:AddText(UI.v2(lx, pos.y + (H - lsz.y) / 2),
      UI.u32(UI.lerpC(UI.C.DIM, UI.C.ACCENT, p)), lbl)

   if hint then
      local hx, hy = lx + lsz.x + 11, pos.y + H / 2
      DL:AddCircle(UI.v2(hx, hy), 7.5, UI.u32(UI.C.MUTE), 16, 1.0)
      local q = mimgui.CalcTextSize("?")
      DL:AddText(UI.v2(hx - q.x / 2, hy - q.y / 2), UI.u32(UI.C.MUTE), "?")
      if hov then
         local mp = mimgui.GetIO().MousePos
         if mp.x >= hx - 9 and mp.x <= hx + 9 then mimgui.SetTooltip("%s", u8(hint)) end
      end
   end
   return changed
end

function UI.HotkeyRow(prefix, desc)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local H, BW = 36, 176

   mimgui.InvisibleButton("##hk_" .. prefix, UI.v2(BW, H - 4))
   local hov = mimgui.IsItemHovered()
   if mimgui.IsItemClicked() then hotkeyAssigning = prefix; hotkeyDebounce = true end

   local key = tonumber(cfg.hotkeys[prefix .. "_key"]) or 0
   local txt, col
   if hotkeyAssigning == prefix then
      txt, col = u8"Нажмите клавишу", UI.C.ACCENT
   elseif key ~= 0 then
      local kn = vkeys.id_to_name(key)
      txt, col = (kn and kn:gsub("^VK_", "") or "??"), UI.C.TEXT
   else
      txt, col = u8"Не назначено", UI.C.MUTE
   end

   local hv = UI.hover("hk" .. prefix, hov)
   local bg
   if hotkeyAssigning == prefix then
      bg = UI.a(UI.C.ACCENT, 0.18 + 0.16 * (0.5 + 0.5 * math.sin(os.clock() * 6.5)))
   else
      bg = UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)
   end
   DL:AddRectFilled(pos, UI.v2(pos.x + BW, pos.y + H - 4), UI.u32(bg), 7.0)

   local ts = mimgui.CalcTextSize(txt)
   DL:AddText(UI.v2(pos.x + (BW - ts.x) / 2, pos.y + (H - 4 - ts.y) / 2), UI.u32(col), txt)

   local d = u8(desc)
   DL:AddText(UI.v2(pos.x + BW + 14, pos.y + (H - 4 - mimgui.CalcTextSize(d).y) / 2),
      UI.u32(UI.C.DIM), d)

   mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y + H))
end

function UI.SubBegin()
   local p = mimgui.GetCursorScreenPos()
   UI._sub[#UI._sub + 1] = { x = p.x + 17, y = p.y }
   mimgui.Indent(34)
end

function UI.SubEnd()
   mimgui.Unindent(34)
   local st = table.remove(UI._sub)
   if not st then return end
   local e = mimgui.GetCursorScreenPos()
   mimgui.GetWindowDrawList():AddLine(UI.v2(st.x, st.y - 2), UI.v2(st.x, e.y - 17),
      UI.u32(UI.C.LINE), 1.0)
end

function UI.SubRow(text, labelW, draw)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local st = UI._sub[#UI._sub]
   if st then
      DL:AddLine(UI.v2(st.x, pos.y + 17), UI.v2(pos.x - 9, pos.y + 17), UI.u32(UI.C.LINE), 1.0)
   end
   local t = u8(text)
   DL:AddText(UI.v2(pos.x, pos.y + 17 - mimgui.CalcTextSize(t).y / 2), UI.u32(UI.C.DIM), t)
   mimgui.SetCursorScreenPos(UI.v2(pos.x + (labelW or 118), pos.y + 2))
   draw()
   mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y + 35))
end

function UI.Button(label, w, h, kind, progress, emoKey)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   h = h or 36
   if w <= 0 then w = mimgui.GetContentRegionAvail().x + w end

   mimgui.InvisibleButton("##b_" .. label, UI.v2(w, h))
   local hov, act = mimgui.IsItemHovered(), mimgui.IsItemActive()
   local clicked = mimgui.IsItemClicked()
   if clicked then UI.rippleHit("b" .. label, pos) end
   local hv = UI.hover("b" .. label, hov)
   local dy = act and 1 or 0

   local bg, fg
   if kind == 'accent' then
      DL:AddRectFilled(UI.v2(pos.x + 3, pos.y + 4), UI.v2(pos.x + w - 3, pos.y + h + 4),
         UI.u32(UI.a(UI.C.ACCENT, 0.10 + 0.14 * hv)), 10.0)
      bg = UI.a(UI.C.ACCENT, act and 1.0 or (0.82 + 0.14 * hv))
      fg = UI.C.ON_ACC
   elseif kind == 'danger' then
      bg = UI.a(UI.C.DANGER, act and 0.50 or (0.14 + 0.18 * hv))
      fg = UI.lerpC(UI.C.DANGER, mimgui.ImVec4(1, 0.90, 0.90, 1), hv)
   else
      bg = act and UI.C.ACTIVE or UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)
      fg = UI.lerpC(UI.C.DIM, UI.C.TEXT, hv)
   end
   DL:AddRectFilled(UI.v2(pos.x, pos.y + dy), UI.v2(pos.x + w, pos.y + h + dy), UI.u32(bg), 9.0)

   if progress and progress > 0.001 then
      DL:PushClipRect(UI.v2(pos.x, pos.y + dy), UI.v2(pos.x + w, pos.y + h + dy), true)
      DL:AddRectFilled(UI.v2(pos.x, pos.y + dy),
         UI.v2(pos.x + w * math.min(1, progress), pos.y + h + dy),
         UI.u32(mimgui.ImVec4(1, 1, 1, 0.20)), 9.0)
      DL:PopClipRect()
   end

   UI.rippleDraw(DL, "b" .. label, UI.v2(pos.x, pos.y + dy), w, h,
      (kind == 'accent') and UI.C.ON_ACC or UI.C.ACCENT)

   local t   = u8((label:gsub("##.*", "")))
   local ts  = mimgui.CalcTextSize(t)
   local es  = h * 0.52
   local ew  = UI.emoW(emoKey, es)
   local gap = (ew > 0) and 8 or 0
   local tx  = pos.x + (w - ts.x - ew - gap) / 2

   UI.emoMid(DL, emoKey, tx, pos.y + dy + h / 2, es)
   DL:AddText(UI.v2(tx + ew + gap, pos.y + dy + (h - ts.y) / 2), UI.u32(fg), t)
   return clicked
end

function UI.NumberBox(id, ref, minV, maxV, suffix)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local BW, H, changed = 62, 31, false

   DL:AddRectFilled(pos, UI.v2(pos.x + BW, pos.y + H), UI.u32(UI.C.SURFACE), 7.0)
   local t = tostring(ref[0]) .. (suffix or "")
   local ts = mimgui.CalcTextSize(t)
   DL:AddText(UI.v2(pos.x + (BW - ts.x) / 2, pos.y + (H - ts.y) / 2), UI.u32(UI.C.TEXT), t)

   for i = 1, 2 do
      local sign = (i == 1) and -1 or 1
      local bx = pos.x + BW + 6 + (i - 1) * 31
      mimgui.SetCursorScreenPos(UI.v2(bx, pos.y))
      mimgui.InvisibleButton(id .. "_n" .. i, UI.v2(27, H))
      local hv = UI.hover(id .. "_h" .. i, mimgui.IsItemHovered())
      DL:AddRectFilled(UI.v2(bx, pos.y), UI.v2(bx + 27, pos.y + H),
         UI.u32(UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)), 7.0)
      local s = (sign < 0) and "-" or "+"
      local ss = mimgui.CalcTextSize(s)
      DL:AddText(UI.v2(bx + (27 - ss.x) / 2, pos.y + (H - ss.y) / 2),
         UI.u32(UI.lerpC(UI.C.DIM, UI.C.ACCENT, hv)), s)
      if mimgui.IsItemClicked() then
         ref[0] = math.max(minV, math.min(maxV, ref[0] + sign))
         changed = true
      end
   end
   mimgui.SetCursorScreenPos(UI.v2(pos.x + BW + 68, pos.y))
   return changed
end

function UI.Slider(id, ref, minV, maxV, w, fmt)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local H = 28
   mimgui.InvisibleButton(id, UI.v2(w, H))
   local act, hov = mimgui.IsItemActive(), mimgui.IsItemHovered()
   if act then
      local t = (mimgui.GetIO().MousePos.x - pos.x) / w
      ref[0] = minV + math.max(0, math.min(1, t)) * (maxV - minV)
   end
   local t = math.max(0, math.min(1, (ref[0] - minV) / (maxV - minV)))
   local cy = pos.y + H / 2

   local hv = UI.hover(id .. "_h", act or hov)
   DL:AddRectFilled(UI.v2(pos.x, cy - 2.5), UI.v2(pos.x + w, cy + 2.5),
      UI.u32(mimgui.ImVec4(1, 1, 1, 0.10)), 2.5)
   DL:AddRectFilled(UI.v2(pos.x, cy - 2.5), UI.v2(pos.x + w * t, cy + 2.5), UI.u32(UI.C.ACCENT), 2.5)
   if hv > 0.01 then
      DL:AddCircleFilled(UI.v2(pos.x + w * t, cy), 13.0,
         UI.u32(UI.a(UI.C.ACCENT, 0.22 * hv)), 24)
   end
   DL:AddCircleFilled(UI.v2(pos.x + w * t, cy), 6.5 + 1.5 * hv, UI.u32(UI.C.ACCENT), 20)

   if fmt then
      local s = u8(fmt:format(ref[0]))
      DL:AddText(UI.v2(pos.x + w + 12, cy - mimgui.CalcTextSize(s).y / 2), UI.u32(UI.C.DIM), s)
   end
   mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y))
   return act
end

UI._slAct = {}
function UI.SliderSave(id, ref, minV, maxV, w, fmt, apply)
   local act = UI.Slider(id, ref, minV, maxV, w, fmt)
   if apply then apply() end
   if UI._slAct[id] and not act then saveConfig(true) end
   UI._slAct[id] = act
   return act
end

function UI.ColorDot(id, colorInt, isActive)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local S = 34
   mimgui.InvisibleButton(id, UI.v2(S, S))
   local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()
   local hv  = UI.hover("cd" .. id, hov)
   local ctr = UI.v2(pos.x + S / 2, pos.y + S / 2)
   local sw  = argb_to_vec4(colorInt)

   if hov then
      UI.previewC, UI.previewAt = mimgui.ImVec4(sw.x, sw.y, sw.z, 1.0), os.clock()
   end

   if hv > 0.01 then
      DL:AddCircleFilled(ctr, 16.0 + 3.0 * hv, UI.u32(UI.a(sw, 0.28 * hv)), 28)
   end
   DL:AddCircleFilled(ctr, 11.0 + 1.5 * hv + (isActive and 1.5 or 0), UI.u32(sw), 28)

   if isActive then
      local rot = os.clock() * 1.1
      for i = 0, 15 do
         local a  = rot + i * math.pi / 8
         local a2 = a + math.pi / 11
         DL:AddLine(UI.v2(ctr.x + math.cos(a) * 16.0,  ctr.y + math.sin(a) * 16.0),
                    UI.v2(ctr.x + math.cos(a2) * 16.0, ctr.y + math.sin(a2) * 16.0),
                    UI.u32(UI.a(sw, 0.85)), 1.8)
      end
   end
   return cl
end

function UI.SideTabs(list, activeKey, introAt)
   local DL   = mimgui.GetWindowDrawList()
   local base = mimgui.GetCursorScreenPos()
   local w    = mimgui.GetContentRegionAvail().x
   local H, GAP, PAD = 50, 4, 11
   local step = H + GAP
   local y0   = base.y + PAD

   local activeIdx = 1
   for i = 1, #list do
      if list[i][1] == activeKey then activeIdx = i end
   end

   local goal = (activeIdx - 1) * step
   local by   = UI.spring("sidetabs", goal, 15)
   local vel  = math.abs(by - goal)
   local strt = math.min(2 * PAD, vel * 0.5)
   local top, bot = y0 + by - strt * 0.5, y0 + by + H + strt * 0.5

   DL:AddRectFilled(UI.v2(base.x + 4, top + 5), UI.v2(base.x + w - 4, bot + 5), UI.u32(UI.a(UI.C.ACCENT, 0.24)), 11.0)
   DL:AddRectFilled(UI.v2(base.x, top), UI.v2(base.x + w, bot), UI.u32(UI.C.ACCENT), 11.0)

   local clicked = nil
   for i = 1, #list do
      local y = y0 + (i - 1) * step
      mimgui.SetCursorScreenPos(UI.v2(base.x, y))
      mimgui.InvisibleButton("##st_" .. list[i][1], UI.v2(w, H))
      local hov = mimgui.IsItemHovered()
      if mimgui.IsItemClicked() then clicked = list[i][1] end
      local hv = UI.hover("st" .. list[i][1], hov)

      local cov = (math.min(bot, y + H) - math.max(top, y)) / H
      cov = math.max(0, math.min(1, cov))

      if hv > 0.002 and cov < 0.98 then
         DL:AddRectFilled(UI.v2(base.x, y), UI.v2(base.x + w, y + H),
            UI.u32(UI.a(UI.C.HOVER, UI.C.HOVER.w * hv * (1 - cov))), 11.0)
         DL:AddRectFilled(UI.v2(base.x, y + 14), UI.v2(base.x + 3, y + H - 14),
            UI.u32(UI.a(UI.C.ACCENT, 0.85 * hv * (1 - cov))), 2.0)
      end

      local dx = introAt and Ease.get(-26, 0, introAt + (i - 1) * 0.045, 0.42, 'outQuint') or 0
      local col = UI.lerpC(UI.lerpC(UI.C.DIM, UI.C.TEXT, hv), UI.C.ON_ACC, cov)
      local tx  = base.x + 18 + dx

      local ew = UI.emoMid(DL, list[i][4], tx, y + H / 2, 21)
      if ew > 0 then
         tx = tx + ew + 13
      else
         local ic = getIcon(list[i][3])
         if ic ~= "" then
            local isz = mimgui.CalcTextSize(ic)
            DL:AddText(UI.v2(tx, y + (H - isz.y) / 2), UI.u32(col), ic)
            tx = tx + isz.x + 13
         end
      end
      local t = u8(list[i][2])
      DL:AddText(UI.v2(tx, y + (H - mimgui.CalcTextSize(t).y) / 2), UI.u32(col), t)
   end

   mimgui.SetCursorScreenPos(UI.v2(base.x, y0 + #list * step))
   return clicked
end

function UI.IconButton(id, iconName, tip, lit)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local S = 32
   mimgui.InvisibleButton(id, UI.v2(S, S))
   local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()
   if cl then UI.rippleHit("ib" .. id, pos) end
   local hv  = UI.hover("ib" .. id, hov)
   local col = lit or UI.C.ACCENT

   if lit then
      local pl = 0.5 + 0.5 * math.sin(os.clock() * 2.4)
      DL:AddCircleFilled(UI.v2(pos.x + S / 2, pos.y + S / 2), S * 0.47,
         UI.u32(UI.a(lit, 0.11 + 0.08 * pl)), 22)
   end
   if hv > 0.002 then
      DL:AddRectFilled(pos, UI.v2(pos.x + S, pos.y + S),
         UI.u32(UI.a(col, 0.18 * hv)), 8.0)
   end
   UI.rippleDraw(DL, "ib" .. id, pos, S, S, col)
   if hov and tip then mimgui.SetTooltip("%s", u8(tip)) end

   local ic = getIcon(iconName, "*")
   local isz = mimgui.CalcTextSize(ic)
   DL:AddText(UI.v2(pos.x + (S - isz.x) / 2, pos.y + (S - isz.y) / 2),
      UI.u32(lit and UI.lerpC(lit, UI.C.TEXT, hv * 0.5)
                 or UI.lerpC(UI.C.MUTE, UI.C.ACCENT, hv)), ic)
   return cl
end

function UI.Tile(id, title, line1, line2, iconName, w, h, emoKey)
   h = h or 90
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   mimgui.InvisibleButton(id, UI.v2(w, h))
   local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()

   local hv = UI.hover("tl" .. id, hov)
   DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + h), UI.u32(UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)), 12.0)
   DL:AddRectFilled(UI.v2(pos.x, pos.y + 14), UI.v2(pos.x + 3, pos.y + h - 14), UI.u32(UI.a(UI.C.ACCENT, 0.35 + 0.5 * hv)), 2.0)
   DL:PushClipRect(pos, UI.v2(pos.x + w, pos.y + h), true)

   local drew = false
   if emoKey then
      local s  = 46
      local ew = UI.emoW(emoKey, s)
      drew = UI.emo(DL, emoKey, pos.x + w - ew - 4, pos.y + h - s - 4, s, 0.25 + 0.20 * hv) > 0
   end
   if not drew then
      local ic = getIcon(iconName)
      if ic ~= "" then
         local f = fonts.huge or fonts.big
         if f then mimgui.PushFont(f) end
         local isz = mimgui.CalcTextSize(ic)
         DL:AddText(UI.v2(pos.x + w - isz.x + 4, pos.y + h - isz.y + 6), UI.u32(UI.a(UI.C.ACCENT, 0.13 + 0.11 * hv)), ic)
         if f then mimgui.PopFont() end
      end
   end

   DL:AddText(UI.v2(pos.x + 16, pos.y + 12), UI.u32(UI.C.TEXT), u8(title))
   if fonts.small then mimgui.PushFont(fonts.small) end
   if line1 then DL:AddText(UI.v2(pos.x + 16, pos.y + 40), UI.u32(UI.C.MUTE), u8(line1)) end
   if line2 then DL:AddText(UI.v2(pos.x + 16, pos.y + 60), UI.u32(UI.C.MUTE), u8(line2)) end
   if fonts.small then mimgui.PopFont() end

   DL:PopClipRect()
   return cl
end

function UI.Search(id, buf, bufSize, hint, w)
   mimgui.PushStyleVarVec2(mimgui.StyleVar.FramePadding, UI.v2(40, 10))
   mimgui.SetNextItemWidth(w)
   local changed = mimgui.InputTextWithHint(id, u8(hint), buf, bufSize)
   mimgui.PopStyleVar()
   local mn, mx = mimgui.GetItemRectMin(), mimgui.GetItemRectMax()
   local ic = getIcon('search', 'Q')
   mimgui.GetWindowDrawList():AddText(
      UI.v2(mn.x + 14, mn.y + ((mx.y - mn.y) - mimgui.CalcTextSize(ic).y) / 2),
      UI.u32(UI.C.MUTE), ic)
   return changed, (mx.y - mn.y)
end

function UI.WindowChrome(title, sideW, dayProgress, emoKey)
   local DL = mimgui.GetWindowDrawList()
   local o  = mimgui.GetWindowPos()
   local w, h = mimgui.GetWindowWidth(), mimgui.GetWindowHeight()

   if sideW > 0 then
      DL:AddRectFilled(o, UI.v2(o.x + sideW, o.y + h), UI.u32(UI.C.BG_SIDE), 14.0, 5)
      local g0 = UI.u32(UI.a(UI.C.ACCENT, 0.12))
      local g1 = UI.u32(UI.a(UI.C.ACCENT, 0.00))
      DL:AddRectFilledMultiColor(UI.v2(o.x, o.y + 14), UI.v2(o.x + sideW, o.y + h - 14), g0, g1, g1, g0)
      DL:AddRectFilled(UI.v2(o.x + sideW - 1, o.y + 14), UI.v2(o.x + sideW, o.y + h - 14), UI.u32(UI.a(UI.C.ACCENT, 0.22)))
   end

   UI.Ambient(o, w, h)
   DL:AddRect(o, UI.v2(o.x + w, o.y + h), UI.u32(UI.a(UI.glow(), 0.16)), 14.0, 0xF, 1.5)
   UI.NeonBorder(o, w, h, 14)

   local hl0, hl1 = UI.u32(UI.a(UI.C.TEXT, 0.00)), UI.u32(UI.a(UI.C.TEXT, 0.26))
   local mid = o.x + w / 2
   DL:AddRectFilledMultiColor(UI.v2(o.x + 18, o.y + 1), UI.v2(mid, o.y + 3), hl0, hl1, hl1, hl0)
   DL:AddRectFilledMultiColor(UI.v2(mid, o.y + 1), UI.v2(o.x + w - 18, o.y + 3), hl1, hl0, hl0, hl1)

   mimgui.SetCursorPos(UI.v2(sideW, 0))
   mimgui.InvisibleButton("##chrome_drag", UI.v2(math.max(1, w - sideW - 66), 60))
   if mimgui.IsItemActive() and mimgui.IsMouseDragging(0) then
      local d = mimgui.GetIO().MouseDelta
      mimgui.SetWindowPosVec2(UI.v2(o.x + d.x, o.y + d.y), mimgui.Cond.Always)
   end

   local t   = title
   local ts  = mimgui.CalcTextSize(t)
   local ew  = UI.emoW(emoKey, 22)
   local gap = (ew > 0) and 10 or 0
   local tx  = o.x + sideW + (w - sideW - ts.x - ew - gap) / 2
   UI.emoMid(DL, emoKey, tx, o.y + 30, 22)
   DL:AddText(UI.v2(tx + ew + gap, o.y + (60 - ts.y) / 2), UI.u32(UI.C.TEXT), t)

   local lx0, lx1 = o.x + sideW + 18, o.x + w - 18
   DL:AddLine(UI.v2(lx0, o.y + 60), UI.v2(lx1, o.y + 60), UI.u32(UI.C.LINE), 1.0)
   if dayProgress and dayProgress > 0.001 then
      local px = lx0 + (lx1 - lx0) * math.min(1, dayProgress)
      DL:AddLine(UI.v2(lx0, o.y + 60), UI.v2(px, o.y + 60), UI.u32(UI.C.ACCENT), 2.0)
      DL:AddCircleFilled(UI.v2(px, o.y + 60), 3.0, UI.u32(UI.C.ACCENT), 12)
      DL:AddCircleFilled(UI.v2(px, o.y + 60), 7.0, UI.u32(UI.a(UI.C.ACCENT, 0.22)), 16)
   end

   local S = 34
   mimgui.SetCursorPos(UI.v2(w - S - 16, 13))
   mimgui.InvisibleButton("##chrome_close", UI.v2(S, S))
   local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()
   local hv = UI.hover("chrome_close", hov)
   local cp = UI.v2(o.x + w - S - 16, o.y + 13)
   DL:AddRectFilled(cp, UI.v2(cp.x + S, cp.y + S),
      UI.u32(UI.lerpC(UI.a(UI.C.ACCENT, 0.16), UI.a(UI.C.DANGER, 0.88), hv)), 9.0)
   local x = getIcon('x', 'X')
   local xs = mimgui.CalcTextSize(x)
   DL:AddText(UI.v2(cp.x + (S - xs.x) / 2, cp.y + (S - xs.y) / 2),
      UI.u32(UI.lerpC(UI.C.ACCENT, mimgui.ImVec4(1, 0.94, 0.94, 1.0), hv)), x)
   return cl
end

function UI.SidebarHeader(sideW, isActive)
   local DL, o = mimgui.GetWindowDrawList(), mimgui.GetWindowPos()
   local tm = os.clock()

   local box = 48
   local bx  = o.x + (sideW - box) / 2
   local cx, cy = o.x + sideW / 2, o.y + 16 + box / 2

   local orbR = box * 0.72
   local head = tm * (isActive and 0.85 or 0.35)
   local segN = UI.fx and 30 or 0
   for i = 0, segN - 1 do
      local f  = i / segN
      local a  = head - f * math.pi * 1.15
      local a2 = head - (f + 1 / segN) * math.pi * 1.15
      DL:AddLine(
         UI.v2(cx + math.cos(a) * orbR,  cy + math.sin(a) * orbR),
         UI.v2(cx + math.cos(a2) * orbR, cy + math.sin(a2) * orbR),
         UI.u32(UI.a(UI.C.ACCENT, (isActive and 0.60 or 0.28) * (1 - f) * (1 - f))), 2.2)
   end
   if UI.fx then
      DL:AddCircleFilled(UI.v2(cx + math.cos(head) * orbR, cy + math.sin(head) * orbR), 3.0, UI.u32(UI.C.ACCENT), 12)
   end

   local breath = isActive and (0.14 + 0.06 * (0.5 + 0.5 * math.sin(tm * 2.2))) or 0.10
   DL:AddRectFilled(UI.v2(bx, o.y + 16), UI.v2(bx + box, o.y + 16 + box), UI.u32(UI.a(UI.C.ACCENT, breath)), 15.0)
   DL:AddRect(UI.v2(bx, o.y + 16), UI.v2(bx + box, o.y + 16 + box), UI.u32(UI.a(UI.C.ACCENT, 0.34)), 15.0, 0xF, 1.0)

   local logoS = box * 0.60
   local logoW = UI.emoW(":u1fc08:", logoS)
   if logoW == 0 or UI.emo(DL, ":u1fc08:", cx - logoW / 2, cy - logoS / 2, logoS) == 0 then
      local ic = getIcon('news', '')
      if ic ~= "" then
         local f = fonts.big
         if f then mimgui.PushFont(f) end
         local isz = mimgui.CalcTextSize(ic)
         DL:AddText(UI.v2(cx - isz.x / 2, cy - isz.y / 2), UI.u32(UI.C.ACCENT), ic)
         if f then mimgui.PopFont() end
      end
   end

   local t  = u8"SMI Helper"
   local ts = mimgui.CalcTextSize(t)
   local tx, ty = o.x + (sideW - ts.x) / 2, o.y + 80
   DL:AddText(UI.v2(tx, ty), UI.u32(UI.C.TEXT), t)

   local sh = ((tm * 0.42) % 3.0) - 0.15
   if sh >= 0 and sh <= 1 then
      local px = tx + ts.x * sh
      DL:PushClipRect(UI.v2(px - 16, ty - 2), UI.v2(px + 16, ty + ts.y + 2), true)
      DL:AddText(UI.v2(tx, ty), UI.u32(UI.C.ACCENT), t)
      DL:PopClipRect()
   end

   if fonts.small then mimgui.PushFont(fonts.small) end
   local v = "v" .. SCRIPT_VERSION
   DL:AddText(UI.v2(o.x + (sideW - mimgui.CalcTextSize(v).x) / 2, o.y + 106), UI.u32(UI.C.MUTE), v)
   if fonts.small then mimgui.PopFont() end
end

function UI.fitFont(text, maxW)
   for _, k in ipairs({ 'big', 'main', 'small' }) do
      if fonts[k] then
         mimgui.PushFont(fonts[k])
         local w = mimgui.CalcTextSize(text).x
         mimgui.PopFont()
         if w <= maxW then return k end
      end
   end
   return 'small'
end

function UI.PaneBegin(id, size)
   mimgui.PushStyleVarVec2(mimgui.StyleVar.WindowPadding, UI.v2(0, 0))
   mimgui.BeginChild(id, size, false)
   mimgui.PopStyleVar()
end

function UI.PaneEnd()
   mimgui.EndChild()
end

function UI.CardTitle(text, iconName)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local x = pos.x
   local ic = iconName and getIcon(iconName) or ""
   if ic ~= "" then
      local isz = mimgui.CalcTextSize(ic)
      DL:AddText(UI.v2(x, pos.y), UI.u32(UI.C.ACCENT), ic)
      x = x + isz.x + 9
   end
   DL:AddText(UI.v2(x, pos.y), UI.u32(UI.C.TEXT), u8(text))
   local lh = mimgui.GetTextLineHeight()
   DL:AddLine(UI.v2(pos.x, pos.y + lh + 7),
      UI.v2(pos.x + mimgui.GetContentRegionAvail().x, pos.y + lh + 7),
      UI.u32(UI.C.LINE), 1.0)
   mimgui.Dummy(UI.v2(0, lh + 15))
end

function UI.CardBegin(id, size, title, iconName)
   mimgui.PushStyleVarFloat(mimgui.StyleVar.ChildRounding, 10.0)
   mimgui.PushStyleVarVec2(mimgui.StyleVar.WindowPadding, UI.v2(18, 16))
   mimgui.PushStyleColor(mimgui.Col.ChildBg, UI.C.SURFACE)
   mimgui.BeginChild(id, size, false,
      mimgui.WindowFlags.NoScrollbar + mimgui.WindowFlags.AlwaysUseWindowPadding)
   mimgui.PopStyleColor(1)
   mimgui.PopStyleVar(2)
   if title then UI.CardTitle(title, iconName) end
end

function UI.CardEnd()
   mimgui.EndChild()
end

function UI.StatTile(caption, value, valueColor, w, h, emoKey)
   h = h or 88
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   mimgui.InvisibleButton("##stt_" .. caption, UI.v2(w, h))
   local hv = UI.hover("stt" .. caption, mimgui.IsItemHovered())
   DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + h), UI.u32(UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)), 12.0)

   local ac = valueColor or UI.C.ACCENT
   DL:AddRectFilled(UI.v2(pos.x, pos.y + 13), UI.v2(pos.x + 3, pos.y + h - 13), UI.u32(UI.a(ac, 0.50 + 0.45 * hv)), 2.0)

   if emoKey then
      local s = 22
      UI.emo(DL, emoKey, pos.x + w - UI.emoW(emoKey, s) - 14, pos.y + 12, s, 0.55 + 0.35 * hv)
   end

   if fonts.small then mimgui.PushFont(fonts.small) end
   DL:AddText(UI.v2(pos.x + 18, pos.y + 13), UI.u32(UI.C.MUTE), u8(caption))
   if fonts.small then mimgui.PopFont() end

   local v = u8(value)
   local f = fonts[UI.fitFont(v, w - 34)]
   if f then mimgui.PushFont(f) end
   local vsz = mimgui.CalcTextSize(v)
   DL:PushClipRect(pos, UI.v2(pos.x + w - 8, pos.y + h), true)
   DL:AddText(UI.v2(pos.x + 18, pos.y + h - 14 - vsz.y), UI.u32(valueColor or UI.C.TEXT), v)
   DL:PopClipRect()
   if f then mimgui.PopFont() end
end

function UI.Bar(label, pct, valueText, dotColor, emoKey)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local w = mimgui.GetContentRegionAvail().x
   local lh = mimgui.GetTextLineHeight()
   local col = dotColor or UI.C.ACCENT

   local ew = UI.emoMid(DL, emoKey, pos.x, pos.y + lh / 2, lh)
   local tx = pos.x + 17
   if ew > 0 then
      tx = pos.x + ew + 8
   else
      DL:AddCircleFilled(UI.v2(pos.x + 4.5, pos.y + lh / 2), 4.5, UI.u32(col), 14)
   end

   DL:AddText(UI.v2(tx, pos.y), UI.u32(UI.C.DIM), u8(label))
   if valueText then
      local vt = u8(valueText)
      DL:AddText(UI.v2(pos.x + w - mimgui.CalcTextSize(vt).x, pos.y), UI.u32(UI.C.TEXT), vt)
   end

   local by = pos.y + lh + 6
   DL:AddRectFilled(UI.v2(pos.x, by), UI.v2(pos.x + w, by + 5), UI.u32(mimgui.ImVec4(1, 1, 1, 0.07)), 2.5)
   local p = math.max(0, math.min(1, (pct or 0) / 100))
   if p > 0.001 then
      DL:AddRectFilled(UI.v2(pos.x, by), UI.v2(pos.x + w * p, by + 5), UI.u32(col), 2.5)
   end
   mimgui.Dummy(UI.v2(w, lh + 20))
end

function UI.Ring(id, pct, radius, thickness, cap1, cap2, w)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local blockW = w or (radius * 2 + 20)
   local H = radius * 2 + 10 + (cap1 and 18 or 0) + (cap2 and 18 or 0)
   local cx, cy = pos.x + blockW / 2, pos.y + radius + 2

   pct = UI.num("rg" .. id, pct or 0, 0.95)

   DL:AddCircle(UI.v2(cx, cy), radius, UI.u32(mimgui.ImVec4(1, 1, 1, 0.08)), 48, thickness)

   local p = math.max(0, math.min(1, (pct or 0) / 100))
   if p > 0.002 then
      local segs = math.max(2, math.floor(48 * p))
      local a0 = -math.pi / 2
      local a1 = a0 + math.pi * 2 * p
      local px, py = cx + math.cos(a0) * radius, cy + math.sin(a0) * radius
      for i = 1, segs do
         local a = a0 + (a1 - a0) * (i / segs)
         local nx, ny = cx + math.cos(a) * radius, cy + math.sin(a) * radius
         DL:AddLine(UI.v2(px, py), UI.v2(nx, ny), UI.u32(UI.C.ACCENT), thickness)
         px, py = nx, ny
      end
      DL:AddCircleFilled(UI.v2(px, py), thickness * 0.75, UI.u32(UI.C.ACCENT), 12)
      DL:AddCircleFilled(UI.v2(px, py), thickness * 1.9, UI.u32(UI.a(UI.C.ACCENT, 0.22)), 16)
   end

   local vt = ("%d%%"):format(math.floor((pct or 0) + 0.5))
   local vs = mimgui.CalcTextSize(vt)
   DL:AddText(UI.v2(cx - vs.x / 2, cy - vs.y / 2), UI.u32(UI.C.TEXT), vt)

   if fonts.small then mimgui.PushFont(fonts.small) end
   local ty = cy + radius + 8
   if cap1 then
      local t = u8(cap1)
      DL:AddText(UI.v2(cx - mimgui.CalcTextSize(t).x / 2, ty), UI.u32(UI.C.DIM), t)
      ty = ty + 18
   end
   if cap2 then
      local t = u8(cap2)
      DL:AddText(UI.v2(cx - mimgui.CalcTextSize(t).x / 2, ty), UI.u32(UI.C.MUTE), t)
   end
   if fonts.small then mimgui.PopFont() end

   mimgui.Dummy(UI.v2(blockW, H))
end

function UI.KV(key, value, valueColor)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local w, lh = mimgui.GetContentRegionAvail().x, mimgui.GetTextLineHeight()
   DL:AddText(UI.v2(pos.x, pos.y + 4), UI.u32(UI.C.DIM), u8(key))
   local vt = u8(tostring(value))
   DL:AddText(UI.v2(pos.x + w - mimgui.CalcTextSize(vt).x, pos.y + 4),
      UI.u32(valueColor or UI.C.TEXT), vt)
   mimgui.Dummy(UI.v2(w, lh + 12))
end

function UI.Chip(text, color, bgAlpha, emoKey)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local t = u8(text)
   local ts = mimgui.CalcTextSize(t)
   local es = ts.y
   local ew = UI.emoW(emoKey, es)
   local w, h = ts.x + 22 + (ew > 0 and (ew + 6) or 0), ts.y + 10
   local col = color or UI.C.ACCENT

   DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + h), UI.u32(UI.a(col, bgAlpha or 0.16)), h / 2)
   DL:AddRect(pos, UI.v2(pos.x + w, pos.y + h), UI.u32(UI.a(col, 0.30)), h / 2, 0xF, 1.0)

   local tx = pos.x + 11
   if ew > 0 then
      UI.emoMid(DL, emoKey, tx, pos.y + h / 2, es)
      tx = tx + ew + 6
   end
   DL:AddText(UI.v2(tx, pos.y + 5), UI.u32(col), t)
   mimgui.Dummy(UI.v2(w, h))
end

function UI.Empty(iconName, title, subtitle, emoKey)
   local DL = mimgui.GetWindowDrawList()
   local avail = mimgui.GetContentRegionAvail()
   local pos = mimgui.GetCursorScreenPos()
   local cx = pos.x + avail.x / 2
   local cy = pos.y + math.max(70, avail.y / 2 - 30)

   local drew = false
   if emoKey then
      local s  = 76
      local ew = UI.emoW(emoKey, s)
      local br = 0.32 + 0.14 * (0.5 + 0.5 * math.sin(os.clock() * 1.8))
      for k = 3, 1, -1 do
         DL:AddCircleFilled(UI.v2(cx, cy), s * 0.55 * k, UI.u32(UI.a(UI.C.ACCENT, 0.030 * (1 - k / 4))), 28)
      end
      drew = UI.emo(DL, emoKey, cx - ew / 2, cy - s / 2, s, br) > 0
   end

   if not drew then
      local ic = getIcon(iconName)
      if ic ~= "" then
         local f = fonts.huge or fonts.big
         if f then mimgui.PushFont(f) end
         local isz = mimgui.CalcTextSize(ic)
         local br  = 0.18 + 0.10 * (0.5 + 0.5 * math.sin(os.clock() * 1.8))
         for s = 3, 1, -1 do
            DL:AddCircleFilled(UI.v2(cx, cy), isz.x * 0.55 * s, UI.u32(UI.a(UI.C.ACCENT, 0.030 * (1 - s / 4))), 28)
         end
         DL:AddText(UI.v2(cx - isz.x / 2, cy - isz.y / 2), UI.u32(UI.a(UI.C.ACCENT, br)), ic)
         if f then mimgui.PopFont() end
      end
   end

   local t = u8(title)
   DL:AddText(UI.v2(cx - mimgui.CalcTextSize(t).x / 2, cy + 40), UI.u32(UI.C.DIM), t)
   if subtitle then
      if fonts.small then mimgui.PushFont(fonts.small) end
      local s = u8(subtitle)
      DL:AddText(UI.v2(cx - mimgui.CalcTextSize(s).x / 2, cy + 68), UI.u32(UI.C.MUTE), s)
      if fonts.small then mimgui.PopFont() end
   end
   mimgui.Dummy(UI.v2(avail.x, math.max(140, avail.y - 4)))
end

function UI.PickRow(id, text, width)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local H = 30
   width = math.max(1, width)

   mimgui.InvisibleButton(id, UI.v2(width, H))
   local hov = mimgui.IsItemHovered()

   if hov then
      DL:AddRectFilled(pos, UI.v2(pos.x + width, pos.y + H), UI.u32(UI.C.HOVER), 7.0)
      DL:AddRectFilled(UI.v2(pos.x, pos.y + 7), UI.v2(pos.x + 3, pos.y + H - 7),
         UI.u32(UI.C.ACCENT), 1.5)
   end

   local t = u8(text)
   DL:AddText(UI.v2(pos.x + 12, pos.y + (H - mimgui.CalcTextSize(t).y) / 2),
      UI.u32(hov and UI.C.TEXT or UI.C.DIM), t)

   return mimgui.IsItemClicked()
end

function UI.IconBtnSmall(id, iconName, danger, size)
   size = size or 30
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   mimgui.InvisibleButton(id, UI.v2(size, size))
   local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()
   local col = danger and UI.C.DANGER or UI.C.ACCENT
   local hv = UI.hover("ibs" .. id, hov)
   if hv > 0.002 then
      DL:AddRectFilled(pos, UI.v2(pos.x + size, pos.y + size),
         UI.u32(UI.a(col, 0.20 * hv)), 8.0)
   end
   local ic = getIcon(iconName, danger and "X" or "E")
   local isz = mimgui.CalcTextSize(ic)
   DL:AddText(UI.v2(pos.x + (size - isz.x) / 2, pos.y + (size - isz.y) / 2),
      UI.u32(UI.lerpC(UI.C.MUTE, col, hv)), ic)
   return cl
end

function UI.TextHighlight(DL, x, y, text, filter, baseCol, maxX)
   local shown = u8(text)
   if not filter or filter == "" then
      DL:AddText(UI.v2(x, y), UI.u32(baseCol), shown)
      return
   end
   local from = lower1251(text):find(filter, 1, true)
   if not from then
      DL:AddText(UI.v2(x, y), UI.u32(baseCol), shown)
      return
   end
   local prefix = u8(text:sub(1, from - 1))
   local match  = u8(text:sub(from, from + #filter - 1))
   local px = x + mimgui.CalcTextSize(prefix).x
   local mw = mimgui.CalcTextSize(match).x
   local lh = mimgui.GetTextLineHeight()
   if not maxX or px + mw <= maxX then
      DL:AddRectFilled(UI.v2(px - 2, y), UI.v2(px + mw + 2, y + lh),
         UI.u32(UI.a(UI.C.ACCENT, 0.28)), 3.0)
   end
   DL:AddText(UI.v2(x, y), UI.u32(baseCol), shown)
end

function UI.MiniChart(items, chartH)
   chartH = chartH or 72
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local w, n = mimgui.GetContentRegionAvail().x, #items
   if n == 0 then mimgui.Dummy(UI.v2(w, chartH)) return end

   local maxV = 1
   for i = 1, n do maxV = math.max(maxV, items[i].approved or 0) end

   local gap = 8
   local bw = math.min(46, (w - gap * (n - 1)) / n)

   if fonts.small then mimgui.PushFont(fonts.small) end
   for i = 1, n do
      local it = items[i]
      local val = it.approved or 0
      local x = pos.x + (i - 1) * (bw + gap)
      val = UI.num("mc" .. i, val, 0.8)
      local hgt = math.max(3, (chartH - 22) * (val / maxV))
      local top = pos.y + 22 + (chartH - 22 - hgt)

      DL:AddRectFilled(UI.v2(x, top), UI.v2(x + bw, pos.y + chartH),
         UI.u32(UI.a(UI.C.ACCENT, 0.70)), 4.0)

      local vt = tostring(math.floor(val + 0.5))
      DL:AddText(UI.v2(x + (bw - mimgui.CalcTextSize(vt).x) / 2, top - 19), UI.u32(UI.C.DIM), vt)

      local dt = u8(tostring(it.date or "?"))
      DL:AddText(UI.v2(x + (bw - mimgui.CalcTextSize(dt).x) / 2, pos.y + chartH + 5),
         UI.u32(UI.C.MUTE), dt)
   end
   if fonts.small then mimgui.PopFont() end

   mimgui.Dummy(UI.v2(w, chartH + 28))
end

function UI.RowBegin(id, h, alt)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local w = mimgui.GetContentRegionAvail().x
   local mp = mimgui.GetIO().MousePos
   local hov = mimgui.IsWindowHovered()
      and mp.x >= pos.x and mp.x <= pos.x + w
      and mp.y >= pos.y and mp.y <= pos.y + h
   local hv = UI.hover("rw" .. id, hov)
   local base = alt and mimgui.ImVec4(1, 1, 1, 0.075) or UI.C.SURFACE
   DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + h),
      UI.u32(UI.lerpC(base, UI.C.HOVER, hv)), 9.0)
   if hov and mimgui.IsMouseClicked(0) then UI.rippleHit("rw" .. id, pos) end
   UI.rippleDraw(DL, "rw" .. id, pos, w, h, UI.C.ACCENT)
   if hv > 0.01 then
      DL:AddRectFilled(UI.v2(pos.x, pos.y + 8), UI.v2(pos.x + 3, pos.y + h - 8),
         UI.u32(UI.a(UI.C.ACCENT, 0.75 * hv)), 2.0)
   end
   return pos, w, hov
end

function UI.listColumns(width)
   local n = #listData.headers
   local xs = { 0 }
   if n <= 0 then xs[2] = width return xs, 0 end

   local numW  = 44
   local timeW = 98
   local nickW = math.max(150, math.min(260, width * 0.24))

   if n == 3 then
      xs[2] = numW
      xs[3] = numW + nickW
      xs[4] = width - timeW
   else
      local step = (width - numW) / n
      for i = 1, n do xs[i + 1] = numW + step * (i - 1) end
   end
   xs[n + 2] = width
   return xs, n
end

local Toast = { items = {}, W = 360 }

function Toast.push(kind, title, text, life)
   Toast.items[#Toast.items + 1] = {
      kind = kind or 'info', title = title, text = text,
      born = os.clock(), life = life or 4.0
   }
   while #Toast.items > 5 do table.remove(Toast.items, 1) end
end

function Toast.style(kind)
   if kind == 'ok'   then return UI.C.SUCCESS, getIcon('circle-check', '+'), EMO.OK end
   if kind == 'warn' then return UI.C.WARNC, getIcon('alert-triangle', '!'), EMO.WARN end
   if kind == 'err'  then return UI.C.DANGER, getIcon('circle-x', 'x'), EMO.ERR end
   return UI.C.ACCENT, getIcon('info-circle', 'i'), EMO.INFO
end

local imguiVars = {
   active = new.bool(false),
   autoApprove = new.bool(false),
   soundEnabled = new.bool(false),
   autoCatchByCommand = new.bool(false),
   quickEditButtons = new.bool(true),
   newsredakHotkeyToggle = new.bool(true),
   interceptCommand = new.bool(true),
   queueWidget = new.bool(true),
   chatEmoji = new.bool(true),
   chatEmojiLevel = new.int(2),
   uiEmoji = new.bool(true),
   fxAnimations = new.bool(true),
   silentMode = new.bool(false),
   requireWindowFocus = new.bool(true),
   autoFixEnabled = new.bool(true),
   autoFixOnOpen = new.bool(false),
   validateEnabled = new.bool(true),

   volume = new.float(50),
   dailyGoal = new.int(50),
   blurEnabled = new.bool(false),
   bgBlurRadius = new.float(20.0),
   listBlurRadius = new.float(5.0),
   autoApproveDelay = new.int(5),
   autoSkipInactivity = new.bool(false),
   autoSkipDelay = new.int(20),
   templateTtlDays = new.int(10),
   fuzzyThreshold = new.int(70),
   minAdLength = new.int(8),
   maxAdLength = new.int(180),
   queueWidgetRows = new.int(6),
   queueAlertCount = new.int(10)
}

local autofixVars = {}
for _, rule in ipairs(AutoFix.rules) do
   autofixVars[rule.id] = new.bool(true)
end

local notificationAudio = nil

function playNotificationSound()
   if not state.soundEnabled then return end
   if doesFileExist(notificationSoundFile) then
      if not notificationAudio then
         notificationAudio = loadAudioStream(notificationSoundFile)
      end
      if notificationAudio then
         setAudioStreamVolume(notificationAudio, state.soundVolume / 100)
         setAudioStreamState(notificationAudio, 1)
      else
         chat(CHAT.WARN .. "Не удалось загрузить звук уведомления")
      end
   else
      chat(CHAT.WARN .. "Звук не найден: " .. CHAT.HI .. "smi_notify.wav")
   end
end

function isGameFocused()
   if cfg.settings.requireWindowFocus == false then return true end
   if not user32 then return true end
   local ok, focused = pcall(function()
      local hwnd = readMemory(0x00C8CF88, 4, false)
      local fg = user32.GetForegroundWindow()
      return tonumber(ffi.cast('intptr_t', fg)) == hwnd
   end)
   if not ok then return true end
   return focused
end

function resetProcessingState()
   quickPicker.close()
   state.isProcessing = false
   state.expectedSender = nil
   state.templateMatch = nil
   state.validation = nil
   state.autoFixApplied = nil
   state.usedTemplate = false
   editorData.openTime = 0
   state.newsredakMode = false
   state.isVipAd = false
   state.prioritySearching = false
   state.awaitingSendResult = false
   state.cooldownUntil = 0
   state.sendAttemptToken = state.sendAttemptToken + 1
   state.sendMode = nil
   state.pendingSentText = nil
   state.pendingSentFor = nil
   windowState.mainWindow[0] = false
   windowState.currentView = "idle"
   listData.highlightIndices = {}
   state.autoApproveAt = 0
   state.autoSkipAt = 0
   state.queueContinueAt = 0
   state.releaseEditorUntil = 0
   state.waitingEditorUntil = 0
end

function stopQueueAutomation()
   state.queueAutomationActive = false
   state.queueContinueAt = 0
end

function scheduleQueueContinue(delaySeconds)
   if not state.queueAutomationActive or not state.active or state.queuePaused then
      return
   end
   state.queueContinueAt = os.clock() + (delaySeconds or C.QUEUE_CONTINUE_DELAY_SEC)
end

local sendNewsredakCommand
local lastNewsredakSendTime = 0
local queueRetryCount = 0

function startQueueProcessing(chatText, emo)
   if not state.active or state.queuePaused then
      return false
   end

   state.newsredakMode = true
   state.prioritySearching = true
   state.expectedSender = nil
   state.queueContinueAt = 0

   if not sendNewsredakCommand() then
      queueRetryCount = queueRetryCount + 1
      resetProcessingState()

      if queueRetryCount >= C.MAX_QUEUE_RETRIES then
         queueRetryCount = 0
         stopQueueAutomation()
         chat(CHAT.ERR .. "Очередь не отвечает (" .. CHAT.HI .. C.MAX_QUEUE_RETRIES ..
            CHAT.ERR .. " попыток). Автоматика остановлена", 'FAIL')
         return false
      end

      scheduleQueueContinue(1.1 * (2 ^ (queueRetryCount - 1)))
      return false
   end

   queueRetryCount = 0
   if chatText then
      chat(chatText, emo)
   end

   return true
end

function openNewsredakQueue(fromHotkey)
   if fromHotkey and cfg.settings.newsredakHotkeyToggle == false then
      return false
   end
   if not state.active then
      sampSendChat('/newsredak')
      return true
   end
   if state.isProcessing then
      chat(CHAT.WARN .. "Уже обрабатываю объявление, дождись завершения")
      return false
   end
   state.queuePaused = false
   state.queueAutomationActive = true
   startQueueProcessing(CHAT.INFO .. "Открываю очередь...", 'INBOX')
   return true
end

sendNewsredakCommand = function()
   local now = os.clock()
   if now - lastNewsredakSendTime < 1.0 then
      return false
   end
   lastNewsredakSendTime = now
   sampSendChat('/newsredak')
   return true
end

local normSenderCache = {}
local normSenderCount = 0

function normalizeSender(name)
   if not name then return '' end
   if normSenderCache[name] then
      return normSenderCache[name]
   end

   if normSenderCount > 500 then
      normSenderCache = {}
      normSenderCount = 0
   end

   local res = name:gsub('{%x%x%x%x%x%x}', ''):gsub('^%[%d+%]%s*', ''):gsub('%s+$', ''):gsub('%([^%)]*%)$', ''):gsub('%s+$', ''):lower()
   normSenderCache[name] = res
   normSenderCount = normSenderCount + 1
   return res
end

function updateListHighlights()
   listData.highlightIndices = {}
   if state.expectedSender then
      for i, entry in ipairs(listData.entries) do
         local senderFound = false
         for _, cellText in ipairs(entry.columns) do
            local cleanName = cellText:gsub('^%[%d+%]%s*', ''):gsub('%s+$', ''):gsub('%([^%)]*%)$', '')
            local expectedClean = state.expectedSender:gsub('%([^%)]*%)$', ''):gsub('%s+$', '')
            if cleanName:lower() == expectedClean:lower() then
               senderFound = true
               break
            end
         end
         if senderFound then
            table.insert(listData.highlightIndices, i)
         end
      end
   end
end

function isRecentlySkipped(nick)
   local key = normalizeSender(nick or '')
   local expireAt = state.recentSkips[key]
   if not expireAt then return false end
   if os.clock() >= expireAt then
      state.recentSkips[key] = nil
      return false
   end
   return true
end

function pruneRecentSkips()
   local now = os.clock()
   if now - state.lastSkipPrune < C.SKIP_PRUNE_INTERVAL then return end
   state.lastSkipPrune = now
   for key, expireAt in pairs(state.recentSkips) do
      if now >= expireAt then state.recentSkips[key] = nil end
   end
end

local Queue = { items = {}, editing = false, vipFlags = {} }

function Queue.find(nick)
   local key = normalizeSender(nick or '')
   if key == '' then return nil end
   for i, it in ipairs(Queue.items) do
      if normalizeSender(it.nick) == key then return i, it end
   end
   return nil
end

function Queue.markVip(nick, isVip)
   if not isVip then return end
   local key = normalizeSender(nick or '')
   if key ~= '' then Queue.vipFlags[key] = os.time() end
end

function Queue.isVipKey(key)
   local at = Queue.vipFlags[key]
   if not at then return false end
   if os.time() - at > C.VIP_FLAG_TTL then
      Queue.vipFlags[key] = nil
      return false
   end
   return true
end

function Queue.add(nick, isVip)
   nick = (tostring(nick or ''):gsub('{%x%x%x%x%x%x}', ''))
   nick = (nick:gsub('^%s+', ''):gsub('%s+$', ''))
   if nick == '' then return end
   Queue.markVip(nick, isVip)
   local i, it = Queue.find(nick)
   if it then
      it.at = os.time()
      it.vip = it.vip or isVip or false
      return
   end
   Queue.items[#Queue.items + 1] = {
      nick = nick, at = os.time(), vip = isVip or false, inEdit = false
   }
   Queue.pulseAt = os.clock()
end

function Queue.remove(nick)
   local i = Queue.find(nick)
   if i then table.remove(Queue.items, i) end
   local key = normalizeSender(nick or '')
   if key ~= '' then Queue.vipFlags[key] = nil end
end

function Queue.syncFromList(entries)
   local known = {}
   for _, it in ipairs(Queue.items) do
      known[normalizeSender(it.nick)] = it
   end

   local fresh = {}
   for _, e in ipairs(entries) do
      local nick = e.columns[1]
      if nick and nick ~= '' and not e.inEdit then
         local key = normalizeSender(nick)
         local prev = known[key]
         local vip = ((e.raw or ''):find('VIP', 1, true) ~= nil)
            or (prev and prev.vip) or Queue.isVipKey(key)
         if vip then Queue.markVip(nick, true) end
         fresh[#fresh + 1] = {
            nick   = nick,
            at     = prev and prev.at or os.time(),
            vip    = vip,
            inEdit = false
         }
      end
   end
   Queue.items = fresh
end

function Queue.prune()
   local now = os.time()
   local i = 1
   while i <= #Queue.items do
      if now - Queue.items[i].at > C.QUEUE_PREVIEW_TTL then
         table.remove(Queue.items, i)
      else
         i = i + 1
      end
   end
   for key, at in pairs(Queue.vipFlags) do
      if now - at > C.VIP_FLAG_TTL then Queue.vipFlags[key] = nil end
   end
end

function Queue.isVip(entry)
   if (entry.raw or ''):find('VIP', 1, true) then return true end
   local _, it = Queue.find(entry.columns[1])
   if it and it.vip then return true end
   return Queue.isVipKey(normalizeSender(entry.columns[1] or ''))
end

function loadSenderIndex()
   state.senderIndex = {}
   local file = io.open(senderIndexFile, 'r')
   if file then
      for line in file:lines() do
         local name = line:match('^(.-)%s*$')
         if name and name ~= '' then
            state.senderIndex[name] = true
         end
      end
      file:close()
   end
end

function saveSenderIndex()
   pcall(function()
      local file = io.open(senderIndexFile, 'w')
      if file then
         for name in pairs(state.senderIndex) do
            file:write(name .. '\n')
         end
         file:close()
      end
   end)
end

function addSenderToIndex(sender)
   if not sender or sender == '' then return end
   local key = normalizeSender(sender)
   if key ~= '' and not state.senderIndex[key] then
      state.senderIndex[key] = true
      saveSenderIndex()
   end
end

function normalizeTemplateText(text)
   if not text then return '' end
   return (text:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' '))
end

function templateKey(text)
   local norm = lower1251(normalizeTemplateText(text))
   norm = norm:gsub("[%.!%?,;:%s]+$", "")
   return norm
end

local Tpl = {}

function Tpl.tokenize(text)
   local set, count = {}, 0
   for word in lower1251(text or ''):gmatch('%S+') do
      word = word:gsub('^%p+', ''):gsub('%p+$', '')
      if #word >= 2 and not set[word] then
         set[word] = true
         count = count + 1
      end
   end
   return set, count
end

function Tpl.invalidate()
   Tpl.index = nil
end

function Tpl.rebuild()
   Tpl.index = {}
   for key, data in pairs(state.templates) do
      local edited = data.edited or ""
      if edited ~= "" then
         local set, count = Tpl.tokenize(key)
         if count > 0 then
            Tpl.index[#Tpl.index + 1] = {
               key = key,
               orig = data.orig or key,
               edited = edited,
               set = set,
               count = count,
               nums = Validate.numbers(data.orig or key)
            }
         end
      end
   end
end

function loadTemplates()
   state.templates = {}
   local file = io.open(templatesFile, 'r')
   if file then
      local content = file:read('*a')
      file:close()
      if content and content ~= '' then
         local ok, parsed = pcall(decodeJson, content)
         if ok and type(parsed) == 'table' then
            for rawKey, v in pairs(parsed) do
               local orig, edited, uses, lastUsed
               if type(v) == 'table' then
                  orig = normalizeTemplateText(tostring(v.orig or rawKey))
                  edited = normalizeTemplateText(tostring(v.edited or ""))
                  uses = tonumber(v.uses) or 0
                  lastUsed = tonumber(v.lastUsed) or os.time()
               else
                  orig = normalizeTemplateText(rawKey)
                  edited = normalizeTemplateText(tostring(v))
                  uses = 0
                  lastUsed = os.time()
               end

               if edited ~= "" then
                  local key = templateKey(orig)
                  if key ~= "" then
                     local prev = state.templates[key]
                     if not prev or uses >= (prev.uses or 0) then
                        state.templates[key] = {
                           orig = orig,
                           edited = edited,
                           uses = math.max(uses, prev and prev.uses or 0),
                           lastUsed = math.max(lastUsed, prev and prev.lastUsed or 0)
                        }
                     end
                  end
               end
            end
         else
            local bak_file = io.open(templatesFile .. '.bak', 'w')
            if bak_file then
               bak_file:write(content)
               bak_file:close()
            end
            logLine('WARN', 'approved_ads.json повреждён, копия сохранена в .bak')
         end
      end
   end
   Tpl.invalidate()
end

function load_blacklist()
   local file = io.open(blacklist_file, 'r')
   if file then
      local content = file:read('*a')
      file:close()
      if content and content ~= '' then
         local ok, parsed = pcall(decodeJson, content)
         if ok and type(parsed) == 'table' then
            blacklist = parsed
         end
      end
   end
   updateBlacklistCache()
end

function save_blacklist()
   local ok, json_data = pcall(encodeJson, blacklist)
   if not ok then
      logLine('ERROR', 'ЧС -> JSON: ' .. tostring(json_data))
      return false
   end
   local written, err = atomicWriteFile(blacklist_file, json_data)
   if not written then
      logLine('ERROR', 'Запись blacklist.json: ' .. tostring(err))
      return false
   end
   return true
end

function saveTemplates()
   Tpl.invalidate()
   local ok, json_data = pcall(encodeJson, state.templates)
   if not ok then
      logLine('ERROR', 'Шаблоны -> JSON: ' .. tostring(json_data))
      return false
   end
   local written, err = atomicWriteFile(templatesFile, json_data)
   if not written then
      logLine('ERROR', 'Запись approved_ads.json: ' .. tostring(err))
      return false
   end
   return true
end

function Tpl.cleanup(silent)
   local days = tonumber(cfg.settings.templateTtlDays) or 10
   if days <= 0 then return 0 end

   local now, ttl, removed = os.time(), days * 86400, 0
   for key, data in pairs(state.templates) do
      local last = tonumber(data.lastUsed) or 0
      if last > 0 and (now - last) > ttl then
         state.templates[key] = nil
         removed = removed + 1
      end
   end

   if removed > 0 then
      saveTemplates()
      if not silent then
         chat(CHAT.TEXT .. "Автоочистка: удалено " .. CHAT.HI .. removed ..
            CHAT.TEXT .. " шаблонов старше " .. CHAT.HI .. days .. CHAT.TEXT .. " дн.")
      end
   end
   return removed
end

function numbersEqual(a, b)
   for num, count in pairs(a) do
      if b[num] ~= count then return false end
   end
   for num, count in pairs(b) do
      if a[num] ~= count then return false end
   end
   return true
end

function Tpl.find(text)
   local key = templateKey(text)
   if key == "" then return nil end

   local entry = state.templates[key]
   if entry and entry.edited ~= "" then
      entry.lastUsed = os.time()
      return entry.edited, false, 100
   end

   if not Tpl.index then Tpl.rebuild() end

   local threshold = (tonumber(cfg.settings.fuzzyThreshold) or 70) / 100
   local set, count = Tpl.tokenize(key)
   if count < C.FUZZY_MIN_TOKENS then return nil end

   local sourceNums = Validate.numbers(text)
   local best, bestScore = nil, 0

   for i = 1, #Tpl.index do
      local t = Tpl.index[i]
      if t.count >= count * threshold and count >= t.count * threshold
         and numbersEqual(sourceNums, t.nums) then
         local common = 0
         for word in pairs(set) do
            if t.set[word] then common = common + 1 end
         end
         local score = common / math.max(count, t.count)
         if score > bestScore then
            bestScore, best = score, t
         end
      end
   end

   if best and bestScore >= threshold then
      local data = state.templates[best.key]
      if data then data.lastUsed = os.time() end
      return best.edited, true, math.floor(bestScore * 100 + 0.5)
   end
   return nil
end

function addApprovedStat()
   cfg.stats.totalApproved = (cfg.stats.totalApproved or 0) + 1
   cfg.stats.sessionApproved = (cfg.stats.sessionApproved or 0) + 1
   cfg.stats.dailyApproved = (cfg.stats.dailyApproved or 0) + 1
   state.doneTimes[#state.doneTimes + 1] = os.clock()
end

function addRejectedStat(reason)
   cfg.stats.totalRejected = cfg.stats.totalRejected + 1
   cfg.stats.sessionRejected = cfg.stats.sessionRejected + 1
   Data.addReject(reason)
   Data.addSender(editorData.sender, normalizeSender(editorData.sender or ''), false)
   saveConfig()
end

function adsPerHour()
   local now = os.clock()
   local i = 1
   while i <= #state.doneTimes do
      if now - state.doneTimes[i] > C.DONE_WINDOW_SEC then
         table.remove(state.doneTimes, i)
      else
         i = i + 1
      end
   end
   if #state.doneTimes == 0 then return 0 end
   local span = math.max(60, now - state.doneTimes[1])
   return math.floor(#state.doneTimes / (span / 3600) + 0.5)
end

function avgEditSeconds()
   local timed = cfg.stats.timedEdits or 0
   if timed <= 0 then return 0 end
   return (cfg.stats.totalEditTime or 0) / timed
end

function getEditorInputText()
   return u8:decode(ffi.string(editorData.inputBuffer))
end

function markEditorActivity()
   state.autoApproveAt = 0
   if cfg.settings.autoSkipInactivity and cfg.settings.autoSkipDelay > 0 then
      state.autoSkipAt = os.clock() + cfg.settings.autoSkipDelay
   end
end

function setEditorInputText(text)
   markEditorActivity()
   inputCursorState.userMovedCursor = false
   local normalizedText = (text or ""):gsub('[\r\n]+', ' ')
   local utf8Text = u8(normalizedText)
   ffi.fill(editorData.inputBuffer, 4096, 0)
   ffi.copy(editorData.inputBuffer, utf8Text, math.min(#utf8Text, 4095))
end

function insertTextAtCursor(chunk, noAutoSpace)
   if not chunk or chunk == "" then return end
   markEditorActivity()

   local raw = ffi.string(editorData.inputBuffer)
   local rawChunk = u8(chunk)
   local textLen = #raw
   local startPos, endPos

   if inputCursorState.userMovedCursor then
      startPos = math.min(inputCursorState.selectionStart, textLen)
      endPos = math.min(inputCursorState.selectionEnd, textLen)
      if endPos < startPos then startPos, endPos = endPos, startPos end
   else
      startPos, endPos = textLen, textLen
   end

   if startPos > 0 and not noAutoSpace then
      local prevChar = raw:sub(startPos, startPos)
      if prevChar ~= " " and not rawChunk:match("^%s") then
         rawChunk = u8(" " .. chunk)
      end
   end

   local newRaw = raw:sub(1, startPos) .. rawChunk .. raw:sub(endPos + 1)
   setEditorInputText(u8:decode(newRaw))

   local newCursor = startPos + #rawChunk
   inputCursorState.selectionStart = newCursor
   inputCursorState.selectionEnd = newCursor
   inputCursorState.userMovedCursor = true
end

function clearEditorInputText()
   setEditorInputText("")
end

function removeLastEditorCharacter()
   local currentText = getEditorInputText()
   if currentText == "" then return end
   setEditorInputText(currentText:sub(1, -2))
end

function removeLastEditorWord()
   local currentText = getEditorInputText()
   if currentText == "" then return end
   local trimmed = currentText:gsub("%s+$", "")
   local cut = trimmed:match("^(.-)[" .. ALPHA .. "%d%p]+$")
   setEditorInputText(cut or "")
end

function runValidation()
   state.validation = Validate.run(getEditorInputText(), editorData.message)
   return state.validation
end

function applyAutoFix(fromHotkey)
   if cfg.settings.autoFixEnabled == false then
      if fromHotkey then chat(CHAT.MUTED .. "Автокоррекция выключена в настройках") end
      return false
   end
   local before = getEditorInputText()
   local after, applied = AutoFix.apply(before)
   if after == before then
      state.autoFixApplied = {}
      if fromHotkey then Toast.push('info', 'Править нечего', nil, 1.6) end
      return false
   end
   setEditorInputText(after)
   state.autoFixApplied = applied
   runValidation()
   Toast.push('ok', 'Автокоррекция', table.concat(applied, ", "), 3.0)
   return true
end

function saveCurrentAsTemplate()
   local orig = normalizeTemplateText(editorData.message)
   local edited = normalizeTemplateText(getEditorInputText())
   if orig == "" or edited == "" then
      Toast.push('warn', 'Нечего сохранять', nil, 2.0)
      return
   end
   local key = templateKey(orig)
   if key == "" then return end
   local prev = state.templates[key]
   state.templates[key] = {
      orig = orig,
      edited = edited,
      uses = (prev and prev.uses or 0),
      lastUsed = os.time()
   }
   saveTemplates()
   Toast.push('ok', 'Шаблон сохранён', nil, 2.0)
   chat(CHAT.OK .. "Шаблон сохранён вручную", 'TPL')
end

function renderQuickEditButtonSection(section, sIndex)
   UI.SectionTitle(section.title)
   local availableWidth = mimgui.GetContentRegionAvail().x
   local perRow = section.buttonsPerRow
   local spacing = 6
   local bw = (availableWidth - spacing * (perRow - 1)) / perRow

   for index, button in ipairs(section.buttons) do
      if UI.Button(button.label .. ("##qe%d_%d"):format(sIndex or 1, index), bw, 34, nil, nil, button.emo) then
         if section.picker then
            quickPicker.open(button.value)
         else
            insertTextAtCursor(button.value, button.raw)
         end
      end
      if index % perRow ~= 0 and index < #section.buttons then
         mimgui.SameLine(0, spacing)
      end
   end
end

function renderQuickPicker()
   local picker = QUICK_PICKERS[quickPicker.active]
   if not picker then
      quickPicker.close()
      return
   end

   local width = mimgui.GetContentRegionAvail().x

   if UI.Button("Назад##qp_back", 112, 30) then
      quickPicker.close()
      return
   end

   mimgui.SameLine(0, 12)
   local DL, hp = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local lh = mimgui.GetTextLineHeight()
   DL:AddRectFilled(UI.v2(hp.x, hp.y + 8), UI.v2(hp.x + 3, hp.y + 22), UI.u32(UI.C.ACCENT), 1.5)
   DL:AddText(UI.v2(hp.x + 12, hp.y + (30 - lh) / 2), UI.u32(UI.C.ACCENT), u8(picker.title))
   mimgui.Dummy(UI.v2(math.max(1, width - 124), 30))

   if not picker.lowerCache then
      picker.lowerCache = {}
      for i = 1, #picker.items do
         picker.lowerCache[i] = lower1251(picker.items[i])
      end
   end

   local filter = ""
   if picker.search then
      mimgui.Dummy(UI.v2(0, 2))
      UI.Search("##qp_search", quickPicker.buffer, 64, picker.hint or "Поиск...", width)
      filter = lower1251(u8:decode(ffi.string(quickPicker.buffer)))
      mimgui.Dummy(UI.v2(0, 2))
   end

   local shown = 0
   for index, item in ipairs(picker.items) do
      if filter == "" or picker.lowerCache[index]:find(filter, 1, true) then
         shown = shown + 1
         if UI.PickRow(("##qp_it%d"):format(index), item, width) then
            if picker.preset and getEditorInputText() == "" then
               setEditorInputText(item)
               markEditorActivity()
            elseif picker.wrap then
               insertTextAtCursor('"' .. item .. '" ')
            else
               insertTextAtCursor(item .. " ")
            end
            quickPicker.close()
            return
         end
      end
   end

   if shown == 0 then
      mimgui.Dummy(UI.v2(0, 16))
      local t = u8("Ничего не найдено")
      mimgui.SetCursorPosX(math.max(0, (width - mimgui.CalcTextSize(t).x) / 2))
      mimgui.TextColored(UI.C.MUTE, "%s", t)
   end
end

function storeApprovedTemplate(sentText)
   local originalText = editorData.message
   local editedText = sentText

   if originalText ~= "" and editedText ~= "" then
      local orig = normalizeTemplateText(originalText)
      local edited = normalizeTemplateText(editedText)
      local key = templateKey(orig)

      if key ~= "" then
         local existing = state.templates[key]
         local currentUses = existing and ((existing.uses or 0) + 1) or 1

         state.templates[key] = {
            orig = orig,
            edited = edited,
            uses = currentUses,
            lastUsed = os.time()
         }
         saveTemplates()

         if templateKey(edited) ~= key then
            chat(CHAT.MUTED .. "Шаблон запомнен", 'TPL')
         end
      end
   end

   addSenderToIndex(editorData.sender)
   Data.addSender(editorData.sender, normalizeSender(editorData.sender or ''), true)
end

function recordAdCategoryAndSpeed(sentText)
   local cat = detectCategory(sentText)
   if cat == 'transport' then
      cfg.stats.catTransport = (cfg.stats.catTransport or 0) + 1
   elseif cat == 'realty' then
      cfg.stats.catRealty = (cfg.stats.catRealty or 0) + 1
   elseif cat == 'accs' then
      cfg.stats.catAccs = (cfg.stats.catAccs or 0) + 1
   else
      cfg.stats.catOther = (cfg.stats.catOther or 0) + 1
   end

   if editorData.openTime and editorData.openTime > 0 then
      local editSec = os.clock() - editorData.openTime
      if editSec > 0 and editSec < C.MAX_VALID_EDIT_TIME_SEC then
         cfg.stats.totalEditTime = (cfg.stats.totalEditTime or 0) + editSec
         cfg.stats.timedEdits = (cfg.stats.timedEdits or 0) + 1
         if editSec < (cfg.stats.fastestEdit or C.NO_RECORD_SPEED_SEC) then
            cfg.stats.fastestEdit = editSec
         end
      end
   end

   if state.usedTemplate then
      cfg.stats.tplApproved = (cfg.stats.tplApproved or 0) + 1
      local avg = avgEditSeconds()
      if avg > 0 then
         cfg.stats.tplSavedSec = (cfg.stats.tplSavedSec or 0) + avg
      end
   end
end

function finalizeApprovedSend(sentText)
   state.sendRetryCount = 0
   Queue.remove(editorData.sender)
   recordAdCategoryAndSpeed(sentText)
   storeApprovedTemplate(sentText)
   addApprovedStat()

   if state.sendMode == 'auto' then
      cfg.stats.autoApprovedCount = (cfg.stats.autoApprovedCount or 0) + 1
      chat(CHAT.OK .. "Отправлено автоматически " .. CHAT.MUTED .. "(совпал шаблон)", 'BOT')
      Toast.push('ok', 'Отправлено автопилотом', nil, 2.0)
   else
      chat(CHAT.OK .. "Объявление отправлено", 'MEGA')
      Toast.push('ok', 'Объявление отправлено', nil, 2.0)
   end

   windowState.mainWindow[0] = false
   saveConfig()
   Data.save()
   resetProcessingState()
   scheduleQueueContinue()
end

function closeActiveView()
   if state.awaitingSendResult then
      stopQueueAutomation()
      finalizeApprovedSend(state.pendingSentText or getEditorInputText())
   else
      if windowState.currentView == "editor" then
         stopQueueAutomation()
         suppressNextMenu = true
         sampSendDialogResponse(editorData.dialogId, 0, 0, "")
      elseif windowState.currentView == "list" then
         stopQueueAutomation()
         sampSendDialogResponse(listData.dialogId, 0, 0, "")
      elseif windowState.currentView == "menu" then
         stopQueueAutomation()
         suppressNextMenu = true
         sampSendDialogResponse(menuData.dialogId, 0, 0, "")
      end
      windowState.mainWindow[0] = false
      resetProcessingState()
   end
end

function startEditorSendAttempt(sendMode)
   if state.awaitingSendResult then
      return false
   end

   if state.cooldownUntil > 0 and os.clock() < state.cooldownUntil then
      return false
   end

   if not editorData.dialogId or editorData.dialogId <= 0 then
      chat(CHAT.ERR .. "Внутренняя ошибка: диалог не определён")
      return false
   end

   local inputText = getEditorInputText()
   if inputText:gsub("%s+", "") == "" then
      chat(CHAT.ERR .. "Пустой текст, отправка отменена")
      Toast.push('err', 'Пустой текст', 'Отправка отменена', 3.0)
      return false
   end

   local check = Validate.run(inputText, editorData.message)
   state.validation = check
   if check.level == 'bad' then
      local first = check.issues[1] and check.issues[1].message or "нарушение"
      if sendMode == 'auto' then
         chat(CHAT.WARN .. "Авто-отправка отменена: " .. CHAT.HI .. first, 'STOP')
         Toast.push('warn', 'Автопилот остановлен', first, 5.0)
         return false
      end
      chat(CHAT.ERR .. "Проверка не пройдена: " .. CHAT.HI .. first)
      Toast.push('err', 'Проверка не пройдена', first, 4.0)
      return false
   end

   if sendMode == 'auto' and not isGameFocused() then
      state.autoApproveAt = os.clock() + 1
      return false
   end

   state.awaitingSendResult = true
   state.cooldownUntil = 0
   state.sendMode = sendMode or 'manual'
   state.pendingSentText = inputText
   state.sendAttemptToken = state.sendAttemptToken + 1
   local attemptToken = state.sendAttemptToken

   sampSendDialogResponse(editorData.dialogId, 1, 0, inputText)

   lua_thread.create(function()
      wait(C.SEND_RESULT_GRACE_MS)
      if state.awaitingSendResult and state.sendAttemptToken == attemptToken
         and state.cooldownUntil == 0 and windowState.currentView == "editor" then
         state.awaitingSendResult = false
         chat(CHAT.WARN .. "Сервер не ответил. Переоткрываю, текст сохранён")
         local savedSender = editorData.sender
         resetProcessingState()
         state.releaseEditorUntil = os.clock() + 2
         state.expectedSender = savedSender
         state.pendingSentText = inputText
         state.pendingSentFor = savedSender
         state.newsredakMode = true
         if not sendNewsredakCommand() then
            wait(1100)
            sendNewsredakCommand()
         end
      end
   end)

   return true
end

function triggerVipRecatch(secondsLeft)
   local targetSender = editorData.sender
   local savedInput = getEditorInputText()
   secondsLeft = math.max(1, tonumber(secondsLeft) or 1)

   resetProcessingState()
   state.releaseEditorUntil = os.clock() + 2
   state.cooldownUntil = os.clock() + secondsLeft
   state.expectedSender = targetSender
   state.pendingSentText = savedInput
   state.pendingSentFor = targetSender

   chat(CHAT.WARN .. "Кулдаун VIP " .. CHAT.HI .. secondsLeft .. " сек" ..
      CHAT.WARN .. ". Забираю объявление сейчас", 'CD')
   Toast.push('warn', 'Кулдаун VIP', secondsLeft .. ' сек', 4.0)

   lua_thread.create(function()
      state.newsredakMode = true
      if not sendNewsredakCommand() then
         wait(1100)
         state.newsredakMode = true
         sendNewsredakCommand()
      end
   end)
end

function skipCurrentAd(reasonText)
   if windowState.currentView ~= "editor" or not windowState.mainWindow[0] then return false end
   if state.awaitingSendResult then return false end
   state.recentSkips[normalizeSender(editorData.sender or '')] = os.clock() + C.SKIP_RETRY_COOLDOWN
   chat(CHAT.MUTED .. (reasonText or "Объявление пропущено, вернулось в очередь"), 'NEXT')
   suppressNextMenu = true
   sampSendDialogResponse(editorData.dialogId, 0, 0, "")
   windowState.mainWindow[0] = false
   resetProcessingState()
   scheduleQueueContinue()
   return true
end

function processPendingSendState()
   pruneRecentSkips()

   if windowState.currentView == "waiting_for_editor" then
      if state.waitingEditorUntil == 0 then
         state.waitingEditorUntil = os.clock() + C.EDITOR_WAIT_TIMEOUT
      elseif os.clock() >= state.waitingEditorUntil then
         state.waitingEditorUntil = 0
         chat(CHAT.WARN .. "Объявление успел забрать другой редактор")
         Toast.push('warn', 'Объявление уже забрали', 'Возвращаюсь к очереди', 3.0)
         resetProcessingState()
         scheduleQueueContinue(0.6)
         return
      end
   elseif state.waitingEditorUntil ~= 0 then
      state.waitingEditorUntil = 0
   end

   if state.autoApproveAt > 0 and os.clock() >= state.autoApproveAt then
      if state.cooldownUntil > 0 and os.clock() < state.cooldownUntil then
         state.autoApproveAt = os.clock() + 1
         return
      end
      state.autoApproveAt = 0
      if windowState.currentView == "editor" and windowState.mainWindow[0] and not state.awaitingSendResult then
         startEditorSendAttempt('auto')
      end
      return
   end

   if state.autoSkipAt > 0 and os.clock() >= state.autoSkipAt then
      if state.cooldownUntil > 0 and os.clock() < state.cooldownUntil then
         state.autoSkipAt = os.clock() + 1
         return
      end
      state.autoSkipAt = 0
      if windowState.currentView == "editor" and windowState.mainWindow[0] and not state.awaitingSendResult then
         cfg.stats.autoSkippedCount = (cfg.stats.autoSkippedCount or 0) + 1
         saveConfig()
         skipCurrentAd("Пропущено по бездействию, объявление вернулось в очередь")
      end
      return
   end

   if state.queueContinueAt > 0 and os.clock() >= state.queueContinueAt then
      if state.active and not state.queuePaused and not state.isProcessing
         and not windowState.mainWindow[0] and windowState.currentView == "idle" then
         state.queueContinueAt = 0
         startQueueProcessing(CHAT.INFO .. 'Перехожу к следующему объявлению...')
      end
   end
end

function updateTemplateCache()
   templateEditorData.list = {}
   local search = lower1251(u8:decode(ffi.string(templateEditorData.searchBuffer)))
   templateEditorData.filter = search

   for key, data in pairs(state.templates) do
      local orig = data.orig or key
      local edited = data.edited or ""
      local uses = data.uses or 0

      local matchesSearch = search == "" or
         lower1251(orig):find(search, 1, true) or
         lower1251(edited):find(search, 1, true)

      if matchesSearch then
         table.insert(templateEditorData.list, {
            key = key,
            original = orig,
            edited = edited,
            uses = uses
         })
      end
   end

   table.sort(templateEditorData.list, function(a, b)
      if a.uses == b.uses then
         return lower1251(a.original) < lower1251(b.original)
      end
      return a.uses > b.uses
   end)
end

function getHistoryTable()
   if type(cfg.stats.history) == 'string' then
      local ok, decoded = pcall(decodeJson, cfg.stats.history)
      if ok and type(decoded) == 'table' then
         return decoded
      end
      return {}
   elseif type(cfg.stats.history) == 'table' then
      return cfg.stats.history
   end
   return {}
end

local lastDailyCheck = 0

function check_daily_reset()
   local now = os.time()
   if now - lastDailyCheck < 60 then return end
   lastDailyCheck = now

   if not cfg or not cfg.stats then return end
   local current_date = os.date('%d.%m.%Y')
   if cfg.stats.lastDate ~= current_date then
      if cfg.stats.lastDate and cfg.stats.lastDate ~= "" then
         local hist = getHistoryTable()
         table.insert(hist, {
            date = cfg.stats.lastDate:sub(1, 5),
            approved = cfg.stats.dailyApproved or 0,
            earnings = cfg.stats.dailyEarnings or 0
         })
         while #hist > 7 do
            table.remove(hist, 1)
         end
         cfg.stats.history = encodeJson(hist)

         local goal = math.max(1, cfg.settings.dailyGoal or 50)
         if (cfg.stats.dailyApproved or 0) >= goal then
            cfg.stats.goalStreak = (cfg.stats.goalStreak or 0) + 1
         else
            cfg.stats.goalStreak = 0
         end
         cfg.stats.goalStreakDate = cfg.stats.lastDate
      end

      cfg.stats.dailyApproved = 0
      cfg.stats.dailyEarnings = 0
      cfg.stats.lastDate = current_date
      saveConfig(true)
   end
end

function yesterdayApproved()
   local hist = getHistoryTable()
   if #hist == 0 then return nil end
   return hist[#hist].approved or 0
end

function format_money(num)
   local formatted = tostring(math.floor(tonumber(num) or 0))
   local k
   while true do
      formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1.%2')
      if (k == 0) then break end
   end
   return formatted
end

function syncImguiVars()
   imguiVars.active[0] = state.active
   imguiVars.autoApprove[0] = state.autoApprove
   imguiVars.soundEnabled[0] = state.soundEnabled
   imguiVars.autoCatchByCommand[0] = state.autoCatchByCommand
   imguiVars.quickEditButtons[0] = state.quickEditButtons
   imguiVars.volume[0] = state.soundVolume or 50
   imguiVars.dailyGoal[0] = cfg.settings.dailyGoal or 50
   imguiVars.blurEnabled[0] = cfg.settings.blurEnabled == true
   imguiVars.bgBlurRadius[0] = cfg.settings.blurBackgroundRadius or 20.0
   imguiVars.listBlurRadius[0] = cfg.settings.blurListRadius or 5.0
   imguiVars.autoApproveDelay[0] = cfg.settings.autoApproveDelay or 5
   imguiVars.autoSkipInactivity[0] = cfg.settings.autoSkipInactivity == true
   imguiVars.autoSkipDelay[0] = cfg.settings.autoSkipDelay or 20
   imguiVars.newsredakHotkeyToggle[0] = (cfg.settings.newsredakHotkeyToggle ~= false)
   imguiVars.interceptCommand[0] = (cfg.settings.interceptCommand ~= false)
   imguiVars.queueWidget[0] = (cfg.settings.queueWidget ~= false)
   imguiVars.chatEmoji[0] = (cfg.settings.chatEmoji ~= false)
   imguiVars.chatEmojiLevel[0] = tonumber(cfg.settings.chatEmojiLevel) or 2
   imguiVars.uiEmoji[0] = (cfg.settings.uiEmoji ~= false)
   imguiVars.fxAnimations[0] = (cfg.settings.fxAnimations ~= false)
   imguiVars.silentMode[0] = (cfg.settings.silentMode == true)
   imguiVars.requireWindowFocus[0] = (cfg.settings.requireWindowFocus ~= false)
   imguiVars.autoFixEnabled[0] = (cfg.settings.autoFixEnabled ~= false)
   imguiVars.autoFixOnOpen[0] = (cfg.settings.autoFixOnOpen == true)
   imguiVars.validateEnabled[0] = (cfg.settings.validateEnabled ~= false)
   imguiVars.templateTtlDays[0] = tonumber(cfg.settings.templateTtlDays) or 10
   imguiVars.fuzzyThreshold[0] = tonumber(cfg.settings.fuzzyThreshold) or 70
   imguiVars.minAdLength[0] = tonumber(cfg.settings.minAdLength) or 8
   imguiVars.maxAdLength[0] = tonumber(cfg.settings.maxAdLength) or 180
   imguiVars.queueWidgetRows[0] = tonumber(cfg.settings.queueWidgetRows) or 6
   imguiVars.queueAlertCount[0] = tonumber(cfg.settings.queueAlertCount) or 10
   for _, rule in ipairs(AutoFix.rules) do
      autofixVars[rule.id][0] = (cfg.autofix[rule.id] ~= false)
   end
end

function syncStateFromImgui()
   state.active = imguiVars.active[0]
   state.autoApprove = imguiVars.autoApprove[0]
   state.soundEnabled = imguiVars.soundEnabled[0]
   state.autoCatchByCommand = imguiVars.autoCatchByCommand[0]
   state.quickEditButtons = imguiVars.quickEditButtons[0]

   if not state.active or not state.autoCatchByCommand then
      stopQueueAutomation()
   end

   if not state.active then
      resetProcessingState()
      Queue.items = {}
   end

   cfg.settings.active = state.active
   cfg.settings.autoApprove = state.autoApprove
   cfg.settings.soundEnabled = state.soundEnabled
   cfg.settings.autoCatchByCommand = state.autoCatchByCommand
   cfg.settings.quickEditButtons = state.quickEditButtons

   cfg.settings.autoApproveDelay = imguiVars.autoApproveDelay[0]
   cfg.settings.autoSkipInactivity = imguiVars.autoSkipInactivity[0]
   cfg.settings.autoSkipDelay = imguiVars.autoSkipDelay[0]
   cfg.settings.blurEnabled = imguiVars.blurEnabled[0]

   state.chatEmoji = imguiVars.chatEmoji[0]
   state.chatEmojiLevel = imguiVars.chatEmojiLevel[0]
   state.silent = imguiVars.silentMode[0]

   cfg.settings.chatEmoji = state.chatEmoji
   cfg.settings.chatEmojiLevel = state.chatEmojiLevel
   cfg.settings.silentMode = state.silent
   cfg.settings.requireWindowFocus = imguiVars.requireWindowFocus[0]
   cfg.settings.newsredakHotkeyToggle = imguiVars.newsredakHotkeyToggle[0]
   cfg.settings.interceptCommand = imguiVars.interceptCommand[0]
   cfg.settings.queueWidget = imguiVars.queueWidget[0]
   cfg.settings.autoFixEnabled = imguiVars.autoFixEnabled[0]
   cfg.settings.autoFixOnOpen = imguiVars.autoFixOnOpen[0]
   cfg.settings.validateEnabled = imguiVars.validateEnabled[0]

   for _, rule in ipairs(AutoFix.rules) do
      cfg.autofix[rule.id] = autofixVars[rule.id][0]
   end

   cfg.settings.uiEmoji = imguiVars.uiEmoji[0]
   UI.emojiReady = (emoji ~= nil) and emoji.loaded and cfg.settings.uiEmoji
   UI._emoCache = {}

   UI.fx = imguiVars.fxAnimations[0]
   cfg.settings.fxAnimations = UI.fx

   saveConfig(true)
end

function removeColorCodes(text)
   if not text then return "" end
   return text:gsub('{%x%x%x%x%x%x}', '')
end

function splitLines(text)
   local lines = {}
   for line in (tostring(text) .. '\n'):gmatch('(.-)\n') do
      lines[#lines + 1] = (line:gsub('\r$', ''))
   end
   if lines[#lines] == '' then lines[#lines] = nil end
   return lines
end

function splitTabs(line)
   local cols, pos = {}, 1
   while true do
      local a, b = line:find('\t', pos, true)
      if not a then
         cols[#cols + 1] = line:sub(pos)
         break
      end
      cols[#cols + 1] = line:sub(pos, a - 1)
      pos = b + 1
   end
   return cols
end

function parseMenuList(text)
   local items = {}
   for i, line in ipairs(splitLines(text)) do
      local cleanLine = removeColorCodes(line):gsub('^%s+', ''):gsub('%s+$', '')
      if cleanLine ~= "" then
         items[#items + 1] = {
            index = i - 1,
            label = (cleanLine:gsub('^%[%d+%]%s*', '')),
            raw = line
         }
      end
   end
   return items
end

function parseTabList(text)
   local entries = {}
   local lines = splitLines(text)
   if #lines == 0 then return {}, entries end

   local headers = {}
   for _, col in ipairs(splitTabs(lines[1])) do
      headers[#headers + 1] = removeColorCodes(col)
   end

   for i = 2, #lines do
      local row = {
         columns = {},
         inEdit = lines[i]:find('%[В редакции%]') ~= nil,
         listIndex = i - 2,
         raw = lines[i],
         row_text = ""
      }

      local parts = { tostring(i - 1) }
      for j, col in ipairs(splitTabs(lines[i])) do
         row.columns[j] = removeColorCodes(col)
         parts[#parts + 1] = row.columns[j]
      end
      row.row_text = table.concat(parts, "   ")

      entries[#entries + 1] = row
   end

   return headers, entries
end

function parseAdDialog(text)
   local data = {
      sender = "Неизвестно",
      time = "?",
      message = ""
   }

   local sender = text:match('Объявление от {%x%x%x%x%x%x}([^,]+),')
   if sender then
      data.sender = sender
   else
      sender = text:match('Объявление от ([^,]+),')
      if sender then data.sender = removeColorCodes(sender) end
   end

   local time = text:match('спустя (%d+)c')
   if time then data.time = time end

   local body = text:match('Сообщение:%s*(.+)')
   local message = nil
   if body then
      message = body:match('^(.-)\r?\n%s*\r?\n') or body
      message = message:gsub('[\r\n]+', ' ')
   end

   if message and message:gsub('%s+', '') ~= "" then
      data.message = removeColorCodes(message):gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
   end
   return data
end

function loadIconicFont(fontSize)
   if not ti then return end
   local config = mimgui.ImFontConfig()
   config.MergeMode = true
   config.PixelSnapH = true
   if not iconRanges then
      iconRanges = mimgui.new.ImWchar[3](ti.min_range, ti.max_range, 0)
   end
   mimgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(ti.get_font_data_base85(), fontSize, config, iconRanges)
end

function exportEverything()
   local payload = {
      version = SCRIPT_VERSION,
      exportedAt = os.date('%d.%m.%Y %H:%M'),
      settings = cfg.settings,
      autofix = cfg.autofix,
      hotkeys = cfg.hotkeys,
      stats = cfg.stats,
      templates = state.templates,
      blacklist = blacklist,
      data = {
         rejectReasons = Data.rejectReasons,
         senders = Data.senders,
         blockLog = Data.blockLog
      }
   }
   local ok, json = pcall(encodeJson, payload)
   if not ok then
      chat(CHAT.ERR .. "Не удалось собрать экспорт")
      return false
   end
   local path = scriptDir .. '\\smi_export_' .. os.date('%Y%m%d_%H%M') .. '.json'
   local file = io.open(path, 'w')
   if not file then
      chat(CHAT.ERR .. "Не удалось создать файл экспорта")
      return false
   end
   file:write(json)
   file:close()
   chat(CHAT.OK .. "Экспорт сохранён: " .. CHAT.HI .. path, 'SAVE')
   Toast.push('ok', 'Экспорт готов', 'Папка resource/SMI Helper', 5.0)
   return true
end

function importEverything()
   local path = scriptDir .. '\\smi_import.json'
   local file = io.open(path, 'r')
   if not file then
      chat(CHAT.WARN .. "Положи файл " .. CHAT.HI .. "smi_import.json" ..
         CHAT.WARN .. " в папку resource/SMI Helper")
      return false
   end
   local content = file:read('*a')
   file:close()

   local ok, parsed = pcall(decodeJson, content)
   if not ok or type(parsed) ~= 'table' then
      chat(CHAT.ERR .. "Файл импорта повреждён")
      return false
   end

   local added = 0
   if type(parsed.templates) == 'table' then
      for key, data in pairs(parsed.templates) do
         if type(data) == 'table' and data.edited and data.edited ~= "" then
            local realKey = templateKey(data.orig or key)
            if realKey ~= "" and not state.templates[realKey] then
               state.templates[realKey] = {
                  orig = data.orig or key,
                  edited = data.edited,
                  uses = tonumber(data.uses) or 0,
                  lastUsed = tonumber(data.lastUsed) or os.time()
               }
               added = added + 1
            end
         end
      end
      saveTemplates()
   end

   local blAdded = 0
   if type(parsed.blacklist) == 'table' then
      for key, item in pairs(parsed.blacklist) do
         if not blacklist[key] then
            blacklist[key] = item
            blAdded = blAdded + 1
         end
      end
      save_blacklist()
      updateBlacklistCache()
   end

   chat(CHAT.OK .. "Импорт: шаблонов " .. CHAT.HI .. added ..
      CHAT.OK .. ", в ЧС " .. CHAT.HI .. blAdded, 'SAVE')
   Toast.push('ok', 'Импорт завершён', ("Шаблонов: %d, ЧС: %d"):format(added, blAdded), 4.0)
   return true
end

function render_blacklist_tab()
   local availW = mimgui.GetContentRegionAvail().x
   local gap = 12
   local tw = (availW - gap * 2) / 3

   UI.StatTile("Игроков в ЧС", tostring(#blacklistCache), UI.C.TEXT, tw, 84, ":u1f464:")
   mimgui.SameLine(0, gap)
   UI.StatTile("Блокировок всего", tostring(cfg.stats.totalBlockedBL or 0), UI.C.DANGER, tw, 84, ":u1f6ab:")
   mimgui.SameLine(0, gap)
   UI.StatTile("За сессию", tostring(cfg.stats.sessionBlockedBL or 0), UI.C.WARNC, tw, 84, ":u1f6e1:")

   mimgui.Dummy(UI.v2(0, 14))
   UI.SectionTitle("Добавить нарушителя", true)

   local formY = mimgui.GetCursorPosY()
   mimgui.PushStyleVarVec2(mimgui.StyleVar.FramePadding, UI.v2(13, 10))
   mimgui.SetNextItemWidth(220)
   mimgui.InputTextWithHint("##bl_nick", u8"Ник или ID", bl_input_buf, 256)
   local formH = mimgui.GetItemRectMax().y - mimgui.GetItemRectMin().y
   mimgui.SameLine(0, 10)
   mimgui.SetNextItemWidth(availW - 220 - 170 - 20)
   mimgui.InputTextWithHint("##bl_reason", u8"Причина (необязательно)", bl_reason_buf, 256)
   mimgui.PopStyleVar()

   mimgui.SameLine(0, 10)
   mimgui.SetCursorPosY(formY)
   if UI.Button("Добавить в ЧС##bl_add", 170, formH, 'accent') then
      local input = u8:decode(ffi.string(bl_input_buf)):gsub("%s+", "")
      local reason = u8:decode(ffi.string(bl_reason_buf)):gsub("^%s+", ""):gsub("%s+$", "")
      if reason == "" then reason = "Причина не указана" end

      local nick, ok = input, true
      if input:match("^%d+$") then
         local id = tonumber(input)
         if id and id >= 0 and id <= C.MAX_SAMP_PLAYER_ID then
            if sampIsPlayerConnected(id) then
               nick = sampGetPlayerNickname(id)
            else
               chat(CHAT.ERR .. "Игрок с ID " .. CHAT.HI .. id .. CHAT.ERR .. " не в сети")
               ok = false
            end
         else
            chat(CHAT.ERR .. "Некорректный ID. Допустимо " .. CHAT.HI .. "0-" .. C.MAX_SAMP_PLAYER_ID)
            ok = false
         end
      end

      if ok and nick ~= "" then
         local key = normalizeSender(nick)
         if key ~= "" then
            blacklist[key] = { nick = nick, reason = reason, date = os.date('%d.%m.%Y') }
            save_blacklist()
            updateBlacklistCache()
            ffi.fill(bl_input_buf, 256, 0)
            ffi.fill(bl_reason_buf, 256, 0)
            chat(CHAT.WARN .. "В чёрный список: " .. CHAT.HI .. nick, 'BAN')
         end
      end
   end

   mimgui.Dummy(UI.v2(0, 14))
   UI.Search("##bl_search", bl_search_buf, 256, "Поиск по нику или причине...", availW)
   mimgui.Dummy(UI.v2(0, 10))

   local logH = math.min(190, math.max(120, mimgui.GetContentRegionAvail().y * 0.32))
   UI.PaneBegin("##bl_list", UI.v2(-1, -(52 + logH + 20)))

   local filter = lower1251(u8:decode(ffi.string(bl_search_buf)))
   local shown, removed = 0, false
   for i, key in ipairs(blacklistCache) do
      local nick, reason, date = getBlacklistData(key)
      if filter == "" or lower1251(nick):find(filter, 1, true)
         or lower1251(reason):find(filter, 1, true) then
         shown = shown + 1

         local pos, w = UI.RowBegin("##bl_row_" .. i, 56, shown % 2 == 0)
         local DL = mimgui.GetWindowDrawList()

         DL:AddCircleFilled(UI.v2(pos.x + 26, pos.y + 28), 14, UI.u32(UI.a(UI.C.DANGER, 0.18)), 24)
         local ic = getIcon('user-off', getIcon('user', "@"))
         local isz = mimgui.CalcTextSize(ic)
         DL:AddText(UI.v2(pos.x + 26 - isz.x / 2, pos.y + 28 - isz.y / 2),
            UI.u32(UI.a(UI.C.DANGER, 0.85)), ic)

         local nu = u8(nick)
         DL:AddText(UI.v2(pos.x + 52, pos.y + 9), UI.u32(UI.C.TEXT), nu)
         local nickW = mimgui.CalcTextSize(nu).x

         if fonts.small then mimgui.PushFont(fonts.small) end
         if date ~= "" then
            DL:AddText(UI.v2(pos.x + 60 + nickW, pos.y + 13), UI.u32(UI.C.MUTE), u8(date))
         end
         DL:PushClipRect(UI.v2(pos.x + 52, pos.y), UI.v2(pos.x + w - 44, pos.y + 56), true)
         DL:AddText(UI.v2(pos.x + 52, pos.y + 31), UI.u32(UI.C.MUTE), u8(reason))
         DL:PopClipRect()
         if fonts.small then mimgui.PopFont() end

         mimgui.SetCursorScreenPos(UI.v2(pos.x + w - 36, pos.y + 15))
         if UI.IconBtnSmall("##bl_del_" .. i, 'x', true) then
            blacklist[key] = nil
            save_blacklist()
            updateBlacklistCache()
            chat(CHAT.OK .. "Из чёрного списка: " .. CHAT.HI .. nick)
            removed = true
         end

         mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y + 62))
         if removed then break end
      end
   end

   if shown == 0 then
      if filter ~= "" then
         UI.Empty('search', "Ничего не найдено", "Попробуй изменить запрос")
      else
         UI.Empty('shield-check', "Чёрный список пуст",
            "Объявления от добавленных игроков будут пропускаться автоматически")
      end
   end

   UI.PaneEnd()

   mimgui.Dummy(UI.v2(0, 8))
   UI.CardBegin("##bl_log", UI.v2(-1, logH), "Лог блокировок", 'history')
   if #Data.blockLog == 0 then
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8"Пока никого не пропускали по чёрному списку")
      if fonts.small then mimgui.PopFont() end
   else
      UI.PaneBegin("##bl_log_scroll", UI.v2(-1, -1))
      if fonts.small then mimgui.PushFont(fonts.small) end
      for i = #Data.blockLog, 1, -1 do
         local rec = Data.blockLog[i]
         UI.KV(rec.at .. "  " .. rec.nick, rec.reason, UI.C.MUTE)
      end
      if fonts.small then mimgui.PopFont() end
      UI.PaneEnd()
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 8))
   if UI.Button("Очистить весь чёрный список##bl_wipe", 0, 38, 'danger') then
      blacklist = {}
      save_blacklist()
      updateBlacklistCache()
      chat(CHAT.WARN .. "Чёрный список очищен")
   end
end

mimgui.OnInitialize(function()
   local io = mimgui.GetIO()
   io.IniFilename = nil
   local glyph_ranges = io.Fonts:GetGlyphRangesCyrillic()

   local fontsDir = getFolderPath(C.CSIDL_FONTS)
   local fontCandidates = {
      getWorkingDirectory() .. '\\resource\\fonts\\EagleSans-Regular.ttf',
      fontsDir .. '\\arialbd.ttf',
      fontsDir .. '\\arial.ttf',
      fontsDir .. '\\tahomabd.ttf',
      fontsDir .. '\\tahoma.ttf'
   }

   local fontPath = nil
   for _, path in ipairs(fontCandidates) do
      if doesFileExist(path) then
         fontPath = path
         break
      end
   end

   if fontPath then
      for _, key in ipairs({ 'small', 'main', 'big', 'huge' }) do
         local size = FONT_SIZE[key]
         local ok, loaded = pcall(function()
            return io.Fonts:AddFontFromFileTTF(fontPath, size, nil, glyph_ranges)
         end)
         if ok and loaded then
            fonts[key] = loaded
            loadIconicFont(size)
         end
      end
   end

   if emoji then
      local okLoad, errLoad = emoji.load()
      UI.emojiReady = okLoad and (cfg.settings.uiEmoji ~= false) or false
      if not okLoad then
         logLine('WARN', 'Атлас эмодзи не загрузился: ' .. tostring(errLoad))
      end
   end

   updateMoonMonetColors()
   UI.applyStyle()
end)

function renderSidePanel()
   UI.CardBegin("##ed_info", UI.v2(302, -1), "Информация", 'info-circle')
   local DL = mimgui.GetWindowDrawList()

   if fonts.small then mimgui.PushFont(fonts.small) end
   mimgui.TextColored(UI.C.MUTE, "%s", u8"ОТПРАВИТЕЛЬ")
   if fonts.small then mimgui.PopFont() end
   mimgui.Dummy(UI.v2(0, 2))
   mimgui.PushTextWrapPos(0)
   mimgui.TextColored(UI.C.TEXT, "%s", u8(editorData.sender))
   mimgui.PopTextWrapPos()

   local rep = Data.senders[normalizeSender(editorData.sender or '')]
   if rep and (rep.ok or 0) + (rep.bad or 0) > 0 then
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s",
         u8(("Ранее: %d одобрено, %d отклонено"):format(rep.ok or 0, rep.bad or 0)))
      if fonts.small then mimgui.PopFont() end
   end

   mimgui.Dummy(UI.v2(0, 8))
   if UI.Button("Занести в ЧС##quick_bl", 0, 36, 'danger') then
      if editorData.sender and editorData.sender ~= "" and editorData.sender ~= "Неизвестно" then
         local key = normalizeSender(editorData.sender)
         blacklist[key] = {
            nick = editorData.sender,
            reason = "Добавлен из редактора",
            date = os.date('%d.%m.%Y')
         }
         save_blacklist()
         updateBlacklistCache()
         chat(CHAT.WARN .. "В чёрный список: " .. CHAT.HI .. editorData.sender, 'BAN')

         suppressNextMenu = true
         Queue.remove(editorData.sender)
         sampSendDialogResponse(editorData.dialogId, 0, 0, "Отклонено (Отправитель в ЧС)")
         addRejectedStat("Отправитель в ЧС")
         windowState.mainWindow[0] = false
         resetProcessingState()
         scheduleQueueContinue()
      end
   end

   mimgui.Dummy(UI.v2(0, 12))
   if fonts.small then mimgui.PushFont(fonts.small) end
   mimgui.TextColored(UI.C.MUTE, "%s", u8"ПОЛУЧЕНО")
   if fonts.small then mimgui.PopFont() end
   mimgui.Dummy(UI.v2(0, 2))

   local editSec = 0
   if editorData.openTime and editorData.openTime > 0 then
      editSec = os.clock() - editorData.openTime
   end
   mimgui.TextColored(UI.C.TEXT, "%s",
      u8(("%s сек. назад     в работе %.0f с"):format(editorData.time, editSec)))

   mimgui.Dummy(UI.v2(0, 12))
   if state.isVipAd then
      UI.Chip("VIP", UI.C.GOLD, 0.22, ":u1f451:")
   else
      UI.Chip("Обычное", UI.C.MUTE, 0.14)
   end
   if state.templateMatch then
      mimgui.SameLine(0, 6)
      if state.templateMatch.fuzzy then
         UI.Chip(("Похоже %d%%"):format(state.templateMatch.score), UI.C.WARNC, 0.18, ":u1f50d:")
      else
         UI.Chip("Шаблон", UI.C.SUCCESS, 0.18, ":u1f4dd:")
      end
   end

   mimgui.Dummy(UI.v2(0, 10))
   if UI.Button("Сохранить как шаблон##save_tpl", 0, 32) then
      saveCurrentAsTemplate()
   end

   mimgui.Dummy(UI.v2(0, 12))
   local lp = mimgui.GetCursorScreenPos()
   DL:AddLine(lp, UI.v2(lp.x + mimgui.GetContentRegionAvail().x, lp.y), UI.u32(UI.C.LINE), 1.0)
   mimgui.Dummy(UI.v2(0, 12))

   if fonts.small then mimgui.PushFont(fonts.small) end
   mimgui.TextColored(UI.C.MUTE, "%s", u8"ИСХОДНЫЙ ТЕКСТ")
   if fonts.small then mimgui.PopFont() end
   mimgui.Dummy(UI.v2(0, 4))

   mimgui.PushTextWrapPos(0)
   local msg = editorData.message
   if msg == "" then msg = "Не удалось получить текст" end
   mimgui.TextColored(UI.C.DIM, "%s", u8(msg))
   mimgui.PopTextWrapPos()

   UI.CardEnd()
end

function renderMenuView()
   local highlightIndex = nil
   if state.expectedSender then
      for i, item in ipairs(menuData.items) do
         if item.label:find(state.expectedSender, 1, true) then highlightIndex = i break end
      end
   end

   UI.CardTitle("Выберите категорию", 'list')

   UI.PaneBegin("##menu_scroll", UI.v2(-1, -58))
   for i, item in ipairs(menuData.items) do
      local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
      local w, H = mimgui.GetContentRegionAvail().x, 46
      mimgui.InvisibleButton("##menu_" .. i, UI.v2(w, H))
      local hov, cl = mimgui.IsItemHovered(), mimgui.IsItemClicked()
      local hl = (highlightIndex == i)
      if cl then UI.rippleHit("mn" .. i, pos) end

      local hv = UI.hover("mn" .. i, hov)
      local bg = hl and UI.a(UI.C.ACCENT, 0.20 + 0.10 * hv)
         or UI.lerpC(UI.C.SURFACE, UI.C.HOVER, hv)
      DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + H), UI.u32(bg), 9.0)
      UI.rippleDraw(DL, "mn" .. i, pos, w, H, UI.C.ACCENT)
      if hl or hv > 0.01 then
         DL:AddRectFilled(UI.v2(pos.x, pos.y + 9), UI.v2(pos.x + 3, pos.y + H - 9),
            UI.u32(UI.a(UI.C.ACCENT, hl and 1.0 or (0.75 * hv))), 2.0)
      end

      if fonts.small then mimgui.PushFont(fonts.small) end
      DL:AddText(UI.v2(pos.x + 18, pos.y + (H - mimgui.GetTextLineHeight()) / 2),
         UI.u32(UI.C.MUTE), tostring(i))
      if fonts.small then mimgui.PopFont() end

      local lt = u8(item.label)
      DL:AddText(UI.v2(pos.x + 46, pos.y + (H - mimgui.CalcTextSize(lt).y) / 2),
         UI.u32(hl and UI.C.ACCENT or UI.C.TEXT), lt)

      mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y + H + 6))

      if cl then
         sampSendDialogResponse(menuData.dialogId, 1, item.index, "")
         windowState.mainWindow[0] = false
         windowState.currentView = "waiting_for_editor"
         state.expectedSender = nil
         listData.highlightIndices = {}
         break
      end
   end
   UI.PaneEnd()

   if UI.Button("Отмена##menu_cancel", 0, 42, 'danger') then
      stopQueueAutomation()
      suppressNextMenu = true
      sampSendDialogResponse(menuData.dialogId, 0, 0, "")
      windowState.mainWindow[0] = false
      resetProcessingState()
   end
end

function isImguiKeyPressed(key, repeatPress)
   local keyIndex = mimgui.GetKeyIndex(key)
   if keyIndex < 0 then
      return false
   end
   return mimgui.IsKeyPressed(keyIndex, repeatPress ~= false)
end

function isListEntrySelectable(index)
   local entry = listData.entries[index]
   return entry ~= nil and not entry.inEdit and (entry.columns[1] or '') ~= ''
end

function moveListSelection(direction)
   local total = #listData.entries
   if total == 0 then
      listData.selectedIndex = -1
      return
   end

   local index = listData.selectedIndex
   if index == -1 or not isListEntrySelectable(index) then
      index = direction > 0 and 0 or (total + 1)
   end

   for _ = 1, total do
      index = index + direction
      if index < 1 then index = total end
      if index > total then index = 1 end
      if isListEntrySelectable(index) then
         listData.selectedIndex = index
         return
      end
   end

   listData.selectedIndex = -1
end

function activateListEntry(index, force)
   local entry = listData.entries[index]
   if not entry or (entry.inEdit and not force) then
      return false
   end

   state.releaseEditorUntil = 0
   listData.selectedIndex = index
   sampSendDialogResponse(listData.dialogId, 1, entry.listIndex, "")
   windowState.mainWindow[0] = false
   windowState.currentView = "waiting_for_editor"
   state.expectedSender = nil

   if state.newsredakMode then
      chat(CHAT.TEXT .. "Объявление взято в работу")
      state.newsredakMode = false
   end

   return true
end

function refreshAdList()
   sampSendDialogResponse(listData.dialogId, 0, 0, "")
   windowState.mainWindow[0] = false
   local wasAuto = state.queueAutomationActive
   resetProcessingState()
   state.queueAutomationActive = wasAuto
   state.newsredakMode = true
   lua_thread.create(function()
      wait(150)
      if not sendNewsredakCommand() then
         wait(1000)
         sendNewsredakCommand()
      end
   end)
end

function renderListHeader(width, xs, n)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   width = width or mimgui.GetContentRegionAvail().x
   local H = 36
   if not xs then xs, n = UI.listColumns(width) end

   DL:AddRectFilled(pos, UI.v2(pos.x + width, pos.y + H), UI.u32(UI.C.SURFACE), 8.0)

   if fonts.small then mimgui.PushFont(fonts.small) end
   local ty = pos.y + (H - mimgui.GetTextLineHeight()) / 2
   for c = 1, n + 1 do
      local title = (c == 1) and "#" or (listData.headers[c - 1] or "")
      if title ~= "" then
         local x = pos.x + xs[c] + 12
         local limit = pos.x + (xs[c + 1] or width) - 6
         if limit > x then
            DL:PushClipRect(UI.v2(x, pos.y), UI.v2(limit, pos.y + H), true)
            DL:AddText(UI.v2(x, ty), UI.u32(UI.C.MUTE), u8(title))
            DL:PopClipRect()
         end
      end
   end
   if fonts.small then mimgui.PopFont() end

   mimgui.Dummy(UI.v2(width, H + 6))
end

function renderListRow(index, entry, isDisabled, isSelected, isHighlighted, xs, n)
   local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
   local width = (xs and xs[#xs]) or mimgui.GetContentRegionAvail().x
   local H = 42
   if not xs then xs, n = UI.listColumns(width) end

   mimgui.InvisibleButton("##ad_row_" .. index, UI.v2(width, H))
   local hovered = mimgui.IsItemHovered()
   local clicked = mimgui.IsItemClicked()
   if clicked and not isDisabled then UI.rippleHit("lr" .. index, pos) end

   local hv = UI.hover("lr" .. index, hovered)
   local bg
   if isDisabled then
      bg = mimgui.ImVec4(1, 1, 1, 0.015)
   elseif isSelected then
      bg = UI.a(UI.C.ACCENT, 0.20 + 0.10 * hv)
   elseif isHighlighted then
      bg = UI.a(UI.C.ACCENT, 0.12 + 0.08 * hv)
   else
      bg = UI.lerpC(
         (index % 2 == 0) and mimgui.ImVec4(1, 1, 1, 0.075) or UI.C.SURFACE,
         UI.C.HOVER, hv)
   end
   DL:AddRectFilled(pos, UI.v2(pos.x + width, pos.y + H), UI.u32(bg), 9.0)
   UI.rippleDraw(DL, "lr" .. index, pos, width, H, UI.C.ACCENT)

   if isSelected and not isDisabled then
      DL:AddRectFilled(UI.v2(pos.x, pos.y + 7), UI.v2(pos.x + 3, pos.y + H - 7),
         UI.u32(UI.C.ACCENT), 2.0)
   end

   local textCol = UI.u32(isDisabled and UI.C.MUTE or UI.C.TEXT)
   local ty = pos.y + (H - mimgui.GetTextLineHeight()) / 2

   local rightPad = 0
   if isDisabled then
      local lock = getIcon('lock', '#')
      local ls = mimgui.CalcTextSize(lock)
      rightPad = ls.x + 20
      DL:AddText(UI.v2(pos.x + width - ls.x - 12, ty), UI.u32(UI.C.MUTE), lock)
   elseif Queue.isVip(entry) then
      local tag = "VIP"
      local ts = mimgui.CalcTextSize(tag)
      local bw = ts.x + 14
      local bx = pos.x + width - bw - 10
      rightPad = bw + 20
      local pl = 0.5 + 0.5 * math.sin(os.clock() * 2.6 + index)
      DL:AddRectFilled(UI.v2(bx - 7, pos.y + 4), UI.v2(bx + bw + 7, pos.y + H - 4),
         UI.u32(UI.a(UI.C.GOLD, 0.07 + 0.09 * pl)), (H - 8) / 2)
      DL:AddRectFilled(UI.v2(bx, pos.y + 8), UI.v2(bx + bw, pos.y + H - 8),
         UI.u32(UI.a(UI.C.GOLD, 0.22 + 0.10 * pl)), (H - 16) / 2)
      DL:AddText(UI.v2(bx + 7, ty), UI.u32(UI.C.GOLD), tag)
   end

   for c = 1, n + 1 do
      local cell = (c == 1) and tostring(index) or (entry.columns[c - 1] or "")
      if cell ~= "" then
         local x = pos.x + xs[c] + 12
         local limit = pos.x + (xs[c + 1] or width) - 6
         if c == n + 1 then limit = limit - rightPad end
         if limit > x then
            DL:PushClipRect(UI.v2(x, pos.y), UI.v2(limit, pos.y + H), true)
            DL:AddText(UI.v2(x, ty), textCol, u8(cell))
            DL:PopClipRect()
         end
      end
   end

   if hovered and entry.row_text ~= "" then
      mimgui.SetTooltip("%s", u8(entry.row_text))
   end

   if clicked and not isDisabled then
      return activateListEntry(index)
   end
   return false
end

function renderListView()
   if state.expectedSender then
      local fallbackEntry = nil

      for i, entry in ipairs(listData.entries) do
         if not entry.inEdit and not isRecentlySkipped(entry.columns[1]) then
            if not fallbackEntry then fallbackEntry = entry end

            local senderFound = false
            for _, cellText in ipairs(entry.columns) do
               local cleanCell = cellText:gsub('^%[%d+%]%s*', ''):gsub('%s+$', '')
               local expectedClean = state.expectedSender:gsub('%s+$', '')
               if cleanCell:lower() == expectedClean:lower() then
                  senderFound = true
                  break
               end
               local cellNoParens = cleanCell:gsub('%([^%)]*%)$', '')
               local expectedNoParens = expectedClean:gsub('%([^%)]*%)$', '')
               if cellNoParens:lower() == expectedNoParens:lower() then
                  senderFound = true
                  break
               end
               if cleanCell:lower():find(expectedClean:lower(), 1, true) or
                  expectedClean:lower():find(cleanCell:lower(), 1, true) then
                  senderFound = true
                  break
               end
            end

            if senderFound then
               sampSendDialogResponse(listData.dialogId, 1, entry.listIndex, "")
               chat(CHAT.TEXT .. "Беру объявление от " .. CHAT.HI .. state.expectedSender)
               windowState.currentView = "waiting_for_editor"
               windowState.mainWindow[0] = false
               return
            end
         end
      end

      if fallbackEntry then
         local who = fallbackEntry.columns[1] or '?'
         sampSendDialogResponse(listData.dialogId, 1, fallbackEntry.listIndex, "")
         chat(CHAT.HI .. state.expectedSender .. CHAT.TEXT .. " уже занято, беру " .. CHAT.HI .. who)
         windowState.currentView = "waiting_for_editor"
         windowState.mainWindow[0] = false
         state.expectedSender = nil
         listData.highlightIndices = {}
         return
      end

      chat(CHAT.WARN .. "Свободных объявлений нет")
      state.expectedSender = nil
      listData.highlightIndices = {}
   end

   if state.prioritySearching then
      state.prioritySearching = false

      local chosen, chosenRank, chosenLabel = nil, 0, nil

      for _, entry in ipairs(listData.entries) do
         local nick = entry.columns[1] or ''
         if not entry.inEdit and nick ~= '' and not isRecentlySkipped(nick) then
            local vip         = Queue.isVip(entry)
            local hasTemplate = state.senderIndex[normalizeSender(nick)] and true or false
            local rank = 1 + (vip and 2 or 0) + (hasTemplate and 1 or 0)

            if rank > chosenRank then
               chosenRank = rank
               chosen = entry
               if vip and hasTemplate then
                  chosenLabel = CHAT.WARN .. "[VIP + шаблон] " .. CHAT.TEXT .. "беру "
               elseif vip then
                  chosenLabel = CHAT.WARN .. "[VIP] " .. CHAT.TEXT .. "беру "
               elseif hasTemplate then
                  chosenLabel = CHAT.OK .. "[шаблон] " .. CHAT.TEXT .. "беру "
               else
                  chosenLabel = CHAT.TEXT .. "Беру "
               end
               if rank == 4 then break end
            end
         end
      end

      if chosen then
         local who = chosen.columns[1] or '?'
         sampSendDialogResponse(listData.dialogId, 1, chosen.listIndex, "")
         chat(chosenLabel .. CHAT.HI .. who)
         windowState.currentView = "waiting_for_editor"
         windowState.mainWindow[0] = false
         return
      else
         if state.queueAutomationActive then
            chat(CHAT.MUTED .. "Все объявления заняты или пропущены. Жду новые")
            sampSendDialogResponse(listData.dialogId, 0, 0, "")
            windowState.mainWindow[0] = false
            resetProcessingState()
            return
         end
         chat(CHAT.MUTED .. "Все объявления в работе у других. Выбери вручную")
         state.expectedSender = nil
         listData.highlightIndices = {}
      end
   end

   if listData.selectedIndex == -1 or not isListEntrySelectable(listData.selectedIndex) then
      moveListSelection(1)
   end

   if isImguiKeyPressed(mimgui.Key.UpArrow) then
      moveListSelection(-1)
   elseif isImguiKeyPressed(mimgui.Key.DownArrow) then
      moveListSelection(1)
   elseif isImguiKeyPressed(mimgui.Key.Enter, false) or isImguiKeyPressed(mimgui.Key.KeyPadEnter, false) then
      if activateListEntry(listData.selectedIndex) then
         return
      end
   end

   UI.CardTitle(state.newsredakMode and "Выберите объявление для редактора"
      or "Список объявлений", state.newsredakMode and 'news' or 'list-details')

   local availW = mimgui.GetContentRegionAvail().x
   local xs, n = UI.listColumns(availW)
   renderListHeader(availW, xs, n)

   UI.PaneBegin("##list_scroll", UI.v2(-1, -82))

   if #listData.entries == 0 then
      UI.Empty('inbox', "Список пуст", "Новые объявления появятся здесь автоматически")
   end

   local activated = false
   for i, entry in ipairs(listData.entries) do
      local isDisabled = entry.inEdit
      local isSelected = (listData.selectedIndex == i)

      local isHighlighted = false
      for _, idx in ipairs(listData.highlightIndices) do
         if idx == i then isHighlighted = true break end
      end

      if renderListRow(i, entry, isDisabled, isSelected, isHighlighted, xs, n) then
         activated = true
         break
      end
      mimgui.Dummy(UI.v2(0, 4))
   end

   UI.PaneEnd()

   if activated then return end

   if fonts.small then mimgui.PushFont(fonts.small) end
   mimgui.TextColored(UI.C.MUTE, "%s", LIST_HINT)
   if fonts.small then mimgui.PopFont() end
   mimgui.Dummy(UI.v2(0, 4))

   local bw = (mimgui.GetContentRegionAvail().x - 10) / 2
   if UI.Button("Обновить список##list_refresh", bw, 42) then
      refreshAdList()
      return
   end
   mimgui.SameLine(0, 10)
   if UI.Button("Закрыть##list_close", bw, 42, 'danger') then
      stopQueueAutomation()
      sampSendDialogResponse(listData.dialogId, 0, 0, "")
      windowState.mainWindow[0] = false
      local wasNewsredak = state.newsredakMode
      resetProcessingState()
      if wasNewsredak then
         chat(CHAT.MUTED .. "Выбор отменён")
      end
   end
end

function renderTemplatesTab()
   local availW = mimgui.GetContentRegionAvail().x
   local ttlDays = tonumber(cfg.settings.templateTtlDays) or 10
   local cleanupLabel = ("Убрать неиспользуемые (> %d дн.)"):format(ttlDays)
   local cleanupW = mimgui.CalcTextSize(u8(cleanupLabel)).x + 30

   local rowY = mimgui.GetCursorPosY()
   local changed, searchH = UI.Search("##tpl_search", templateEditorData.searchBuffer, 256,
      "Поиск по оригиналу или исправленному тексту...", availW - cleanupW - 12)
   if changed then
      updateTemplateCache()
      templateEditorData.selectedIndex = -1
      templateEditorData.currentKey = nil
      ffi.fill(templateEditorData.originalBuffer, 4096, 0)
      ffi.fill(templateEditorData.editedBuffer, 4096, 0)
   end

   mimgui.SameLine(0, 12)
   mimgui.SetCursorPosY(rowY)
   if UI.Button(cleanupLabel .. "##tpl_cleanup", cleanupW, searchH) then
      local n = Tpl.cleanup(true)
      updateTemplateCache()
      templateEditorData.selectedIndex = -1
      templateEditorData.currentKey = nil
      chat(CHAT.TEXT .. "Удалено шаблонов: " .. CHAT.HI .. n)
   end

   mimgui.Dummy(UI.v2(0, 10))

   local totalUses = 0
   for i = 1, #templateEditorData.list do
      totalUses = totalUses + (templateEditorData.list[i].uses or 0)
   end
   local savedMin = math.floor((cfg.stats.tplSavedSec or 0) / 60)

   UI.Chip("Всего: " .. #templateEditorData.list, UI.C.ACCENT)
   mimgui.SameLine(0, 8)
   UI.Chip("Срабатываний: " .. totalUses, UI.C.SUCCESS)
   mimgui.SameLine(0, 8)
   UI.Chip("Сэкономлено ~" .. savedMin .. " мин", UI.C.GOLD)
   mimgui.SameLine(0, 16)

   local dgp = mimgui.GetCursorScreenPos()
   mimgui.GetWindowDrawList():AddText(UI.v2(dgp.x, dgp.y + 6), UI.u32(UI.C.DIM), u8"Срок хранения")
   mimgui.SetCursorScreenPos(UI.v2(dgp.x + 130, dgp.y))
   if UI.NumberBox("##tpl_ttl", imguiVars.templateTtlDays, 0, 180, u8" дн") then
      cfg.settings.templateTtlDays = imguiVars.templateTtlDays[0]
      saveConfig(true)
   end
   mimgui.SetCursorScreenPos(UI.v2(dgp.x, dgp.y + 34))

   mimgui.Dummy(UI.v2(0, 4))

   UI.PaneBegin("##tpl_list", UI.v2(-1, -52))

   if #templateEditorData.list == 0 then
      UI.Empty('file-text', "Шаблонов пока нет",
         "Они появятся сами после первых отредактированных объявлений")
   end

   local filter = templateEditorData.filter or ""

   for i, tmpl in ipairs(templateEditorData.list) do
      local expanded = (templateEditorData.selectedIndex == i)
      local rowH = expanded and 292 or 46
      local pos, w = UI.RowBegin("##tpl_row_" .. i, rowH, i % 2 == 0)
      local DL = mimgui.GetWindowDrawList()

      DL:PushClipRect(UI.v2(pos.x + 14, pos.y), UI.v2(pos.x + w - 150, pos.y + 46), true)
      UI.TextHighlight(DL, pos.x + 14, pos.y + 13, tmpl.original, filter, UI.C.TEXT, pos.x + w - 150)
      DL:PopClipRect()

      if (tmpl.uses or 0) > 0 then
         if fonts.small then mimgui.PushFont(fonts.small) end
         local ut = u8(("%d сраб."):format(tmpl.uses))
         DL:AddText(UI.v2(pos.x + w - 76 - mimgui.CalcTextSize(ut).x, pos.y + 16),
            UI.u32(UI.a(UI.C.SUCCESS, 0.85)), ut)
         if fonts.small then mimgui.PopFont() end
      end

      mimgui.SetCursorScreenPos(UI.v2(pos.x + w - 66, pos.y + 10))
      if UI.IconBtnSmall("##tpl_ed_" .. i, 'edit', false) then
         if expanded then
            templateEditorData.selectedIndex = -1
            templateEditorData.currentKey = nil
         else
            templateEditorData.selectedIndex = i
            templateEditorData.currentKey = tmpl.key
            ffi.fill(templateEditorData.originalBuffer, 4096, 0)
            ffi.fill(templateEditorData.editedBuffer, 4096, 0)
            local o, e = u8(tmpl.original), u8(tmpl.edited)
            ffi.copy(templateEditorData.originalBuffer, o, math.min(#o, 4095))
            ffi.copy(templateEditorData.editedBuffer, e, math.min(#e, 4095))
         end
      end

      mimgui.SetCursorScreenPos(UI.v2(pos.x + w - 34, pos.y + 10))
      local killed = UI.IconBtnSmall("##tpl_del_" .. i, 'x', true)
      if killed then
         state.templates[tmpl.key] = nil
         saveTemplates()
         updateTemplateCache()
         templateEditorData.selectedIndex = -1
         templateEditorData.currentKey = nil
      end

      if not killed and expanded then
         mimgui.SetCursorScreenPos(UI.v2(pos.x + 14, pos.y + 46))
         mimgui.BeginGroup()

         mimgui.TextColored(UI.C.MUTE, "%s", u8"Оригинал")
         local oc = mimgui.InputTextMultiline("##tpl_o_" .. i,
            templateEditorData.originalBuffer, 4096, UI.v2(w - 28, 56))
         mimgui.TextColored(UI.C.MUTE, "%s", u8"Исправлено")
         local ec = mimgui.InputTextMultiline("##tpl_e_" .. i,
            templateEditorData.editedBuffer, 4096, UI.v2(w - 28, 56))

         if (oc or ec) and templateEditorData.currentKey then
            local nO = normalizeTemplateText(u8:decode(ffi.string(templateEditorData.originalBuffer)))
            local nE = normalizeTemplateText(u8:decode(ffi.string(templateEditorData.editedBuffer)))
            if nO ~= "" and nE ~= "" then
               local newKey = templateKey(nO)
               if newKey ~= "" then
                  local old = state.templates[templateEditorData.currentKey]
                  local uses = old and (old.uses or 0) or 0
                  local last = old and old.lastUsed or os.time()
                  if templateEditorData.currentKey ~= newKey then
                     state.templates[templateEditorData.currentKey] = nil
                  end
                  state.templates[newKey] = {
                     orig = nO, edited = nE, uses = uses, lastUsed = last
                  }
                  templateEditorData.currentKey = newKey
                  tmpl.key, tmpl.original, tmpl.edited = newKey, nO, nE
                  Tpl.invalidate()
               end
            end
         end

         mimgui.Dummy(UI.v2(0, 4))
         if UI.Button("Сохранить##tpl_save_" .. i, 170, 32, 'accent') then
            saveTemplates()
            updateTemplateCache()
            templateEditorData.selectedIndex = -1
            templateEditorData.currentKey = nil
            chat(CHAT.OK .. "Шаблон сохранён", 'TPL')
         end
         mimgui.EndGroup()
      end

      mimgui.SetCursorScreenPos(UI.v2(pos.x, pos.y + rowH + 6))
      if killed then break end
   end

   UI.PaneEnd()

   if UI.Button("Удалить все шаблоны##tpl_wipe", 0, 38, 'danger') then
      state.templates = {}
      saveTemplates()
      updateTemplateCache()
      templateEditorData.selectedIndex = -1
      templateEditorData.currentKey = nil
      ffi.fill(templateEditorData.originalBuffer, 4096, 0)
      ffi.fill(templateEditorData.editedBuffer, 4096, 0)
   end
end

function renderEditorView()
   renderSidePanel()
   mimgui.SameLine(0, 16)

   UI.PaneBegin("##ed_work", UI.v2(-1, -1))

   UI.CardTitle("Редактирование объявления", 'edit')

   UI.SectionTitle("Текст для одобрения", true)
   mimgui.PushStyleVarVec2(mimgui.StyleVar.FramePadding, UI.v2(12, 10))
   local flags = mimgui.InputTextFlags.EnterReturnsTrue + mimgui.InputTextFlags.CallbackAlways
   mimgui.PushItemWidth(-1)
   local submitted = mimgui.InputText("##ad_input", editorData.inputBuffer, 4096, flags, cbTextEdit)
   local edited = mimgui.IsItemEdited()
   if edited or mimgui.IsItemActive() then markEditorActivity() end
   mimgui.PopItemWidth()
   mimgui.PopStyleVar()

   if edited then
      runValidation()
      state.autoFixApplied = nil
   end
   if not state.validation then runValidation() end

   local DL = mimgui.GetWindowDrawList()
   local curText = getEditorInputText()
   local limit = tonumber(cfg.settings.maxAdLength) or 180
   local used = #curText

   mimgui.Dummy(UI.v2(0, 2))
   if fonts.small then mimgui.PushFont(fonts.small) end
   local cp = mimgui.GetCursorScreenPos()
   local counter = u8(("%d / %d"):format(used, limit))
   local ccol = UI.C.MUTE
   if used > limit then
      ccol = UI.C.DANGER
   elseif used > limit * 0.9 then
      ccol = UI.C.WARNC
   end
   DL:AddText(UI.v2(cp.x + mimgui.GetContentRegionAvail().x - mimgui.CalcTextSize(counter).x, cp.y),
      UI.u32(ccol), counter)

   local statusText, statusCol = nil, UI.C.MUTE
   if state.validation and #state.validation.issues > 0 then
      statusText = state.validation.issues[1].message
      statusCol = (state.validation.level == 'bad') and UI.C.DANGER or UI.C.WARNC
   elseif state.autoFixApplied and #state.autoFixApplied > 0 then
      statusText = "Исправлено: " .. table.concat(state.autoFixApplied, ", ")
      statusCol = UI.C.SUCCESS
   end
   if statusText then
      DL:AddText(UI.v2(cp.x, cp.y), UI.u32(statusCol), u8(statusText))
   end
   mimgui.Dummy(UI.v2(0, mimgui.GetTextLineHeight() + 2))
   if fonts.small then mimgui.PopFont() end

   local fixW = (mimgui.GetContentRegionAvail().x - 12) / 2
   if UI.Button("Исправить текст##qe_fix", fixW, 32, nil, nil, ":u1f527:") then
      applyAutoFix(false)
   end
   mimgui.SameLine(0, 12)
   if UI.Button("Пропустить##qe_skip", fixW, 32) then
      skipCurrentAd()
      UI.PaneEnd()
      return
   end

   if state.quickEditButtons then
      local RESERVE_BELOW = 285
      local areaH = math.max(120, math.min(430,
         mimgui.GetContentRegionAvail().y - RESERVE_BELOW))

      mimgui.Dummy(UI.v2(0, 2))
      mimgui.BeginChild("##qe_area", UI.v2(-1, areaH), false)
      if quickPicker.active then
         renderQuickPicker()
      else
         for i, section in ipairs(QUICK_EDIT_BUTTON_SECTIONS) do
            renderQuickEditButtonSection(section, i)
         end
      end
      mimgui.EndChild()

      mimgui.Dummy(UI.v2(0, 6))
      local uw = (mimgui.GetContentRegionAvail().x - 6) / 2
      if UI.Button("Стереть символ##qe_bs", uw, 34) then removeLastEditorCharacter() end
      mimgui.SameLine(0, 6)
      if UI.Button("Очистить поле##qe_cl", uw, 34) then clearEditorInputText() end
   end

   UI.SectionTitle("Причина отклонения")
   mimgui.PushStyleVarVec2(mimgui.StyleVar.FramePadding, UI.v2(12, 10))
   mimgui.PushItemWidth(-1)
   mimgui.InputText("##reject_reason", editorData.rejectBuffer, 1024)
   if mimgui.IsItemEdited() or mimgui.IsItemActive() then markEditorActivity() end
   mimgui.PopItemWidth()
   mimgui.PopStyleVar()

   mimgui.Dummy(UI.v2(0, 10))

   if state.autoSkipAt > 0 then
      local left = math.ceil(state.autoSkipAt - os.clock())
      if left <= 5 then
         mimgui.TextColored(UI.C.DANGER, "%s",
            u8(("Авто-пропуск через %d сек - начни печатать!"):format(left)))
      end
   elseif state.autoApproveAt > 0 then
      local left = math.ceil(state.autoApproveAt - os.clock())
      mimgui.TextColored(UI.C.WARNC, "%s",
         u8(("Авто-отправка через %d сек - начни печатать для отмены"):format(left)))
   end

   mimgui.Dummy(UI.v2(0, 4))

   local bw = (mimgui.GetContentRegionAvail().x - 12) / 2
   local cd = math.max(0, math.ceil(state.cooldownUntil - os.clock()))

   local gio = mimgui.GetIO()
   local ctrlEnter = gio.KeyCtrl and isImguiKeyPressed(mimgui.Key.Enter, false)

   if state.awaitingSendResult then
      UI.Button("Отправка...##send_wait", bw, 50)
   elseif cd > 0 then
      UI.Button(("Кулдаун: %d сек##send_cd"):format(cd), bw, 50)
   else
      local prog = nil
      if state.autoApproveAt > 0 then
         local total = math.max(0.5, tonumber(cfg.settings.autoApproveDelay) or 5)
         prog = 1 - math.max(0, math.min(1, (state.autoApproveAt - os.clock()) / total))
      end
      local kind = 'accent'
      if state.validation and state.validation.level == 'bad' then kind = 'danger' end
      if submitted or ctrlEnter or UI.Button("Отправить##send_btn", bw, 50, kind, prog) then
         startEditorSendAttempt('manual')
      end
   end

   mimgui.SameLine(0, 12)

   if state.awaitingSendResult then
      UI.Button("Отклонить##reject_dis", bw, 50)
   elseif UI.Button("Отклонить##reject_btn", bw, 50, 'danger') then
      local reason = u8:decode(ffi.string(editorData.rejectBuffer))
      if reason == "" then reason = "Объявление отклонено без указания причины" end
      suppressNextMenu = true
      Queue.remove(editorData.sender)
      sampSendDialogResponse(editorData.dialogId, 0, 0, reason)
      addRejectedStat(reason)
      Data.save()
      windowState.mainWindow[0] = false
      resetProcessingState()
      scheduleQueueContinue()
      chat(CHAT.ERR .. "Объявление отклонено", 'FAIL')
   end

   mimgui.Dummy(UI.v2(0, 6))
   UI.PaneEnd()
end

mimgui.OnFrame(
   function() return windowState.mainWindow[0] end,
   function()
      if not windowState.mainWindow[0] then return end
      if windowState.currentView == "idle" then
         windowState.mainWindow[0] = false
         return
      end

      UI.alpha = Ease.get(0, 1, anim.main, 0.20, 'outSine')
      mimgui.PushStyleVarFloat(mimgui.StyleVar.Alpha, UI.alpha)

      if mimgui_blur and imguiVars.blurEnabled[0] then
         local radius = imguiVars.bgBlurRadius[0]
         if windowState.currentView == "list" or windowState.currentView == "menu" then
            radius = imguiVars.listBlurRadius[0]
         end
         mimgui_blur.apply(mimgui.GetBackgroundDrawList(), radius)
      end

      local screenW, screenH = getScreenResolution()

      if forceCenterMain then
         mimgui.SetNextWindowPos(mimgui.ImVec2(screenW / 2, screenH / 2), mimgui.Cond.Always, mimgui.ImVec2(0.5, 0.5))
         forceCenterMain = false
      elseif cfg.settings.windowPosX >= 0 and cfg.settings.windowPosY >= 0 then
         mimgui.SetNextWindowPos(
            mimgui.ImVec2(cfg.settings.windowPosX, cfg.settings.windowPosY),
            mimgui.Cond.FirstUseEver
         )
      else
         mimgui.SetNextWindowPos(
            mimgui.ImVec2(screenW / 2, screenH / 2),
            mimgui.Cond.FirstUseEver,
            mimgui.ImVec2(0.5, 0.5)
         )
      end

      local winWidth, winHeight = 470, 190
      if windowState.currentView == "editor" then
         winWidth  = 1090
         winHeight = state.quickEditButtons and 900 or 540
      elseif windowState.currentView == "list" then
         winWidth, winHeight = 980, 620
      elseif windowState.currentView == "menu" then
         winWidth  = 580
         winHeight = math.min(620, 165 + #menuData.items * 52)
      end
      winWidth  = math.min(winWidth,  screenW - 40)
      winHeight = math.min(winHeight, screenH - 50)
      mimgui.SetNextWindowSize(UI.v2(winWidth, winHeight), mimgui.Cond.Always)

      if fonts.main then mimgui.PushFont(fonts.main) end

      local flags = mimgui.WindowFlags.NoCollapse
         + mimgui.WindowFlags.NoTitleBar
         + mimgui.WindowFlags.NoResize
         + mimgui.WindowFlags.NoScrollbar

      local title = MAIN_TITLES[windowState.currentView] or u8("SMI Helper v" .. SCRIPT_VERSION)

      mimgui.PushStyleVarVec2(mimgui.StyleVar.WindowPadding, UI.v2(0, 0))
      mimgui.Begin("##main_window", windowState.mainWindow, flags)
      mimgui.PopStyleVar()

      local pos = mimgui.GetWindowPos()
      cfg.settings.windowPosX = pos.x
      cfg.settings.windowPosY = pos.y

      if UI.WindowChrome(title, 0, nil, MAIN_EMO[windowState.currentView]) then
         closeActiveView()
      end
      mimgui.SetCursorPos(UI.v2(20, 68))
      mimgui.BeginChild("##main_body", UI.v2(-20, -20), false)

      if windowState.currentView == "editor" then
         renderEditorView()
      elseif windowState.currentView == "list" then
         renderListView()
      elseif windowState.currentView == "menu" then
         renderMenuView()
      elseif windowState.currentView == "waiting_for_editor" then
         UI.Empty('loader', "Открываем редактор", "Ждём ответ сервера...")
      else
         UI.Empty('hourglass', "Ожидание диалога", nil)
      end

      mimgui.EndChild()
      mimgui.End()

      if fonts.main then mimgui.PopFont() end
      mimgui.PopStyleVar()
      UI.alpha = 1.0
   end
)

function renderStatsTab()
   check_daily_reset()

   local availW = mimgui.GetContentRegionAvail().x
   local gap = 12

   local avgPay = (cfg.stats.dailyApproved or 0) > 0
      and math.floor((cfg.stats.dailyEarnings or 0) / cfg.stats.dailyApproved) or 0
   local sessionSec = math.max(600, os.time() - (sessionStartTimestamp or os.time()))
   local hourly = math.floor((cfg.stats.sessionEarnings or 0) / (sessionSec / 3600))

   local function anim_i(id, v) return math.floor(UI.num(id, v or 0) + 0.5) end

   local tw = (availW - gap * 4) / 5
   local tiles = {
      { "За день",         tostring(anim_i("t1", cfg.stats.dailyApproved)),             UI.C.TEXT,    ":u1f4c5:" },
      { "Заработано",      "$" .. format_money(anim_i("t2", cfg.stats.dailyEarnings)),  UI.C.SUCCESS, ":u1fc22:" },
      { "Средняя оплата",  "~$" .. format_money(anim_i("t3", avgPay)),                  UI.C.TEXT,    ":u1f4b5:" },
      { "Доход в час",     "$" .. format_money(anim_i("t4", hourly)),                   UI.C.ACCENT,  ":u26a1:"  },
      { "За всё время",    "$" .. format_money(anim_i("t5", cfg.stats.totalEarnings)),  UI.C.GOLD,    ":u1f4b0:" }
   }
   for i = 1, 5 do
      UI.StatTile(tiles[i][1], tiles[i][2], tiles[i][3], tw, 90, tiles[i][4])
      if i < 5 then mimgui.SameLine(0, gap) end
   end

   mimgui.Dummy(UI.v2(0, gap))

   local colW = (availW - gap) / 2
   local bx, by = mimgui.GetCursorPosX(), mimgui.GetCursorPosY()

   UI.PaneBegin("##st_left", UI.v2(colW, -1))

   UI.CardBegin("##st_cat", UI.v2(-1, 264), "Категории объявлений", 'category')
   local tot = math.max(1, (cfg.stats.catTransport or 0) + (cfg.stats.catRealty or 0)
      + (cfg.stats.catAccs or 0) + (cfg.stats.catOther or 0))
   local cats = {
      { "Транспорт",    cfg.stats.catTransport or 0, UI.C.ACCENT,  ":u1f697:" },
      { "Недвижимость", cfg.stats.catRealty or 0,    UI.C.SUCCESS, ":u1f3e0:" },
      { "Аксессуары",   cfg.stats.catAccs or 0,      UI.C.WARNC,   ":u1f455:" },
      { "Прочее",       cfg.stats.catOther or 0,     UI.C.MUTE,    ":u1f4e6:" }
   }
   for i = 1, 4 do
      local v   = UI.num("cat" .. i, cats[i][2], 0.85)
      local pct = v / tot * 100
      UI.Bar(cats[i][1], pct, ("%d  (%.0f%%)"):format(math.floor(v + 0.5), pct), cats[i][3], cats[i][4])
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##st_cnt", UI.v2(-1, 380), "Счётчики и скорость", 'list-numbers')
   UI.KV("Сессия - одобрено",  anim_i("k1", cfg.stats.sessionApproved),  UI.C.SUCCESS)
   UI.KV("Сессия - отклонено", anim_i("k2", cfg.stats.sessionRejected),  UI.C.DANGER)
   UI.KV("Всего одобрено",     anim_i("k3", cfg.stats.totalApproved))
   UI.KV("Всего отклонено",    anim_i("k4", cfg.stats.totalRejected))
   UI.KV("Авто-пропусков",     anim_i("k5", cfg.stats.autoSkippedCount),  UI.C.MUTE)
   UI.KV("Объявлений в час",   adsPerHour(), UI.C.ACCENT)

   local avgSpeed = avgEditSeconds()
   local fastest = (cfg.stats.fastestEdit and cfg.stats.fastestEdit < C.NO_RECORD_SPEED_SEC)
      and cfg.stats.fastestEdit or 0
   UI.KV("Средняя скорость", ("%.1f сек"):format(avgSpeed))
   UI.KV("Рекорд",           ("%.1f сек"):format(fastest), UI.C.ACCENT)

   local yesterday = yesterdayApproved()
   if yesterday then
      local today = cfg.stats.dailyApproved or 0
      local diff = today - yesterday
      local col = (diff >= 0) and UI.C.SUCCESS or UI.C.DANGER
      local sign = (diff >= 0) and "+" or ""
      UI.KV("Вчера за день", ("%d  (%s%d)"):format(yesterday, sign, diff), col)
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##st_hist", UI.v2(-1, 176), "История за последние дни", 'calendar')
   local hist = getHistoryTable()
   if #hist > 0 then
      UI.MiniChart(hist, 62)
   else
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8"История начнёт заполняться со следующего дня")
      if fonts.small then mimgui.PopFont() end
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##st_top", UI.v2(-1, 240), "Топ отправителей", 'users')
   local top = Data.topSenders(5)
   if #top == 0 then
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8"Пока нет данных")
      if fonts.small then mimgui.PopFont() end
   else
      for _, rec in ipairs(top) do
         UI.KV(rec.nick, ("%d  (%d / %d)"):format(rec.total, rec.ok, rec.bad),
            rec.bad > rec.ok and UI.C.DANGER or UI.C.TEXT)
      end
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 8))
   UI.PaneEnd()

   mimgui.SetCursorPos(UI.v2(bx + colW + gap, by))
   UI.PaneBegin("##st_right", UI.v2(colW, -1))

   local sTot = (cfg.stats.sessionApproved or 0) + (cfg.stats.sessionRejected or 0)
   local sEff = sTot > 0 and ((cfg.stats.sessionApproved or 0) / sTot) * 100 or 0
   local aTot = (cfg.stats.totalApproved or 0) + (cfg.stats.totalRejected or 0)
   local tEff = aTot > 0 and ((cfg.stats.totalApproved or 0) / aTot) * 100 or 0
   local goal = math.max(1, cfg.settings.dailyGoal or 50)
   local dPrg = math.min(((cfg.stats.dailyApproved or 0) / goal) * 100, 100)
   local autoP = (cfg.stats.totalApproved or 0) > 0
      and math.min(100, (cfg.stats.autoApprovedCount or 0) / cfg.stats.totalApproved * 100) or 0
   local tplP = (cfg.stats.totalApproved or 0) > 0
      and math.min(100, (cfg.stats.tplApproved or 0) / cfg.stats.totalApproved * 100) or 0

   UI.CardBegin("##st_eff", UI.v2(-1, 452), "Эффективность", 'target')
   local ringW = (mimgui.GetContentRegionAvail().x - 8) / 2
   UI.Ring("##r1", sEff, 36, 6, "Эффективность", "сессии", ringW)
   mimgui.SameLine(0, 8)
   UI.Ring("##r2", tEff, 36, 6, "Общая", "эффективность", ringW)
   mimgui.Dummy(UI.v2(0, 6))
   UI.Ring("##r3", dPrg, 36, 6, "Цель дня", "(" .. goal .. ")", ringW)
   mimgui.SameLine(0, 8)
   UI.Ring("##r4", autoP, 36, 6, "Доля", "автопилота", ringW)
   mimgui.Dummy(UI.v2(0, 6))
   UI.Ring("##r5", tplP, 36, 6, "Закрыто", "шаблоном", ringW)
   mimgui.SameLine(0, 8)
   local streakW = ringW
   local sp = mimgui.GetCursorScreenPos()
   local DLs = mimgui.GetWindowDrawList()
   local st = tostring(cfg.stats.goalStreak or 0)
   local f = fonts.big
   if f then mimgui.PushFont(f) end
   local stsz = mimgui.CalcTextSize(st)
   DLs:AddText(UI.v2(sp.x + (streakW - stsz.x) / 2, sp.y + 20), UI.u32(UI.C.GOLD), st)
   if f then mimgui.PopFont() end
   if fonts.small then mimgui.PushFont(fonts.small) end
   local c1 = u8"Дней подряд"
   local c2 = u8"с выполненной целью"
   DLs:AddText(UI.v2(sp.x + (streakW - mimgui.CalcTextSize(c1).x) / 2, sp.y + 82), UI.u32(UI.C.DIM), c1)
   DLs:AddText(UI.v2(sp.x + (streakW - mimgui.CalcTextSize(c2).x) / 2, sp.y + 100), UI.u32(UI.C.MUTE), c2)
   if fonts.small then mimgui.PopFont() end
   mimgui.Dummy(UI.v2(streakW, 120))
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##st_rej", UI.v2(-1, 220), "Причины отклонений", 'file-x')
   local reasons = Data.topReasons(5)
   if #reasons == 0 then
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8"Отклонений пока не было")
      if fonts.small then mimgui.PopFont() end
   else
      for _, rec in ipairs(reasons) do
         UI.KV(rec.reason, rec.count, UI.C.DANGER)
      end
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##st_ach", UI.v2(-1, 396), "Достижения СМИ", 'trophy')

   local function compact(num)
      if num >= 1000000 then
         return (("%.1fM"):format(num / 1000000):gsub("%.0M", "M"))
      elseif num >= 1000 then
         return ("%.0fk"):format(num / 1000)
      end
      return tostring(num)
   end

   local nextAch = nil

   local function ach(title, desc, cur, target, unlocked, kind, emoKey)
      if not unlocked and not nextAch then nextAch = title end
      local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
      local w, H = mimgui.GetContentRegionAvail().x, 42
      mimgui.InvisibleButton("##ach_" .. title, UI.v2(w, H))
      local hv = UI.hover("ach" .. title, mimgui.IsItemHovered())
      if hv > 0.002 then
         DL:AddRectFilled(pos, UI.v2(pos.x + w, pos.y + H),
            UI.u32(UI.a(UI.C.HOVER, UI.C.HOVER.w * hv)), 7.0)
      end
      if mimgui.IsItemHovered() then mimgui.SetTooltip("%s", u8(desc)) end

      local progress
      if kind == "money" then
         progress = ("$%s / $%s"):format(compact(math.min(target, cur)), compact(target))
      elseif kind == "speed" then
         progress = (cur < C.NO_RECORD_SPEED_SEC) and ("%.1fс / 1.5с"):format(cur) or u8"нет данных"
      else
         progress = ("%d / %d"):format(math.min(target, cur), target)
      end

      local col = unlocked and UI.C.ACCENT or UI.C.DIM
      local ew = UI.emo(DL, emoKey, pos.x + 4, pos.y + 4, 18, unlocked and 1.0 or 0.30)
      local tx = pos.x + 4
      if ew > 0 then
         tx = tx + ew + 8
      else
         local ic = getIcon(unlocked and 'circle-check' or 'circle-dashed', unlocked and "+" or "-")
         local isz = mimgui.CalcTextSize(ic)
         DL:AddText(UI.v2(pos.x + 4, pos.y + 3), UI.u32(unlocked and UI.C.ACCENT or UI.C.MUTE), ic)
         tx = tx + isz.x + 9
      end
      DL:AddText(UI.v2(tx, pos.y + 2), UI.u32(col), u8(title))

      local pt = (kind == "speed" and cur >= C.NO_RECORD_SPEED_SEC) and progress or u8(progress)
      DL:AddText(UI.v2(pos.x + w - mimgui.CalcTextSize(pt).x - 2, pos.y + 2),
         UI.u32(unlocked and UI.C.ACCENT or UI.C.MUTE), pt)

      local frac = (kind == "speed") and (unlocked and 1 or 0)
         or math.max(0, math.min(1, cur / target))
      local by2 = pos.y + H - 12
      DL:AddRectFilled(UI.v2(pos.x + 2, by2), UI.v2(pos.x + w - 2, by2 + 3),
         UI.u32(mimgui.ImVec4(1, 1, 1, 0.07)), 1.5)
      if frac > 0.001 then
         DL:AddRectFilled(UI.v2(pos.x + 2, by2), UI.v2(pos.x + 2 + (w - 4) * frac, by2 + 3),
            UI.u32(UI.a(UI.C.ACCENT, unlocked and 1.0 or 0.55)), 1.5)
      end
   end

   local fastEdit = cfg.stats.fastestEdit or C.NO_RECORD_SPEED_SEC
   local tplCount = 0
   for _ in pairs(state.templates) do tplCount = tplCount + 1 end

   ach("Первая сотня", "Отредактировать 100 объявлений",
      cfg.stats.totalApproved or 0, 100, (cfg.stats.totalApproved or 0) >= 100, nil, ":u1f4af:")
   ach("Тысячник", "Отредактировать 1000 объявлений",
      cfg.stats.totalApproved or 0, 1000, (cfg.stats.totalApproved or 0) >= 1000, nil, ":u1f3c6:")
   ach("Скорострел", "Отредактировать объявление быстрее 1.5 секунды",
      fastEdit, 1.5, fastEdit <= 1.5 and (cfg.stats.totalApproved or 0) > 0, "speed", ":u26a1:")
   ach("Миллионер", "Заработать $50.000.000 за всё время",
      cfg.stats.totalEarnings or 0, 50000000, (cfg.stats.totalEarnings or 0) >= 50000000, "money", ":u1f4b0:")
   ach("На автопилоте", "50 объявлений через авто-одобрение",
      cfg.stats.autoApprovedCount or 0, 50, (cfg.stats.autoApprovedCount or 0) >= 50, nil, ":u1f916:")
   ach("Страж порядка", "20 заблокированных объявлений через ЧС",
      cfg.stats.totalBlockedBL or 0, 20, (cfg.stats.totalBlockedBL or 0) >= 20, nil, ":u1f6e1:")
   ach("Библиотекарь", "Накопить 100 шаблонов",
      tplCount, 100, tplCount >= 100, nil, ":u1f4da:")
   ach("Постоянство", "7 дней подряд с выполненной целью",
      cfg.stats.goalStreak or 0, 7, (cfg.stats.goalStreak or 0) >= 7, nil, ":u1f525:")

   if nextAch then
      mimgui.Dummy(UI.v2(0, 4))
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8("Ближайшее: " .. nextAch))
      if fonts.small then mimgui.PopFont() end
   end
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))
   if UI.Button("Сбросить всю статистику##reset_stats", 0, 38, 'danger') then
      cfg.stats = {
         totalApproved = 0, totalRejected = 0, sessionApproved = 0, sessionRejected = 0,
         dailyApproved = 0, dailyEarnings = 0, totalEarnings = 0, sessionEarnings = 0,
         catTransport = 0, catRealty = 0, catAccs = 0, catOther = 0,
         totalEditTime = 0, timedEdits = 0, autoApprovedCount = 0, autoSkippedCount = 0,
         fastestEdit = C.NO_RECORD_SPEED_SEC,
         tplApproved = 0, tplSavedSec = 0, goalStreak = 0, goalStreakDate = "",
         totalBlockedBL = 0, sessionBlockedBL = 0, history = "[]", lastDate = os.date('%d.%m.%Y')
      }
      Data.rejectReasons = {}
      Data.senders = {}
      Data.save()
      sessionStartTimestamp = os.time()
      state.doneTimes = {}
      saveConfig(true)
      chat(CHAT.WARN .. "Статистика сброшена")
   end

   mimgui.Dummy(UI.v2(0, 8))
   UI.PaneEnd()
end

function renderInfoTab()
   local availW = mimgui.GetContentRegionAvail().x
   local gap = 12

   UI.SectionTitle("Быстрые ссылки", true)
   local tw = (availW - gap * 3) / 4
   if UI.Tile("##tile_tg", "Telegram", "Связь с автором", "и новости", 'send', tw, 96, ":u1fc39:") then
      if shell32 then
         pcall(function() shell32.ShellExecuteA(nil, "open", "https://t.me/e11evated", nil, nil, 1) end)
      end
   end
   mimgui.SameLine(0, gap)
   if UI.Tile("##tile_vk", "ВКонтакте", "Страница", "разработчика", 'world', tw, 96, ":u1fc3a:") then
      if shell32 then
         pcall(function() shell32.ShellExecuteA(nil, "open", "https://vk.com/e11evated", nil, nil, 1) end)
      end
   end
   mimgui.SameLine(0, gap)
   if UI.Tile("##tile_dn", "Поддержать", "Донат через", "ЮMoney", 'heart', tw, 96, ":u1f381:") then
      if shell32 then
         pcall(function()
            shell32.ShellExecuteA(nil, "open", "https://yoomoney.ru/fundraise/1I83IUSVP6B.260606", nil, nil, 1)
         end)
      end
   end
   mimgui.SameLine(0, gap)
   UI.Tile("##tile_ver", "SMI Helper", "Версия " .. SCRIPT_VERSION, "автор e11evated", 'news', tw, 96, ":u1fc08:")

   mimgui.Dummy(UI.v2(0, 6))

   local colW = (availW - gap) / 2
   local bx, by = mimgui.GetCursorPosX(), mimgui.GetCursorPosY()

   UI.PaneBegin("##inf_left", UI.v2(colW, -1))

   UI.CardBegin("##inf_cmd", UI.v2(-1, 176), "Команды управления", 'terminal-2')
   UI.KV("/smi", "меню настроек", UI.C.ACCENT)
   UI.KV("/newsredak", "очередь объявлений", UI.C.ACCENT)
   UI.KV("/smipause", "пауза автоматики", UI.C.ACCENT)
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##inf_dep", UI.v2(-1, 222), "Состояние компонентов", 'cpu')
   local function dep(name, okFlag)
      local DL, pos = mimgui.GetWindowDrawList(), mimgui.GetCursorScreenPos()
      local w, lh = mimgui.GetContentRegionAvail().x, mimgui.GetTextLineHeight()
      local col = okFlag and UI.C.SUCCESS or UI.C.DANGER
      DL:AddCircleFilled(UI.v2(pos.x + 4, pos.y + lh / 2), 4.0, UI.u32(col), 12)
      DL:AddText(UI.v2(pos.x + 15, pos.y), UI.u32(UI.C.DIM), u8(name))
      local t = u8(okFlag and "загружен" or "не найден")
      DL:AddText(UI.v2(pos.x + w - mimgui.CalcTextSize(t).x, pos.y), UI.u32(col), t)
      mimgui.Dummy(UI.v2(w, lh + 10))
   end
   dep("RakLua (RPC)", ok_raklua)
   dep("MoonMonet (палитра)", ok_moonmonet)
   dep("mimgui_blur (размытие)", ok_blur)
   dep("Tabler Icons (иконки)", ok_ti)
   dep("chat_emoji (иконки Arizona)", ok_emoji and UI.emojiReady)
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##inf_data", UI.v2(-1, 176), "Данные скрипта", 'database')
   local ew = (mimgui.GetContentRegionAvail().x - 10) / 2
   if UI.Button("Экспорт всего##exp_all", ew, 34) then exportEverything() end
   mimgui.SameLine(0, 10)
   if UI.Button("Импорт##imp_all", ew, 34) then importEverything() end
   mimgui.Dummy(UI.v2(0, 6))
   if fonts.small then mimgui.PushFont(fonts.small) end
   mimgui.PushTextWrapPos(0)
   mimgui.TextColored(UI.C.MUTE, "%s",
      u8"Экспорт кладёт файл в resource/SMI Helper. Для импорта переименуй файл в smi_import.json и положи туда же.")
   mimgui.PopTextWrapPos()
   if fonts.small then mimgui.PopFont() end
   UI.CardEnd()

   UI.PaneEnd()

   mimgui.SetCursorPos(UI.v2(bx + colW + gap, by))
   UI.PaneBegin("##inf_right", UI.v2(colW, -1))

   UI.CardBegin("##inf_warn", UI.v2(-1, 240), "Об автоматике", 'alert-triangle')
   mimgui.PushTextWrapPos(0)
   mimgui.TextColored(UI.C.WARNC, "%s",
      u8"Авто-одобрение, авто-ловля и авто-пропуск действуют от имени твоего персонажа. Скрипт отправляет ровно то, что видно в поле ввода, но ответственность за опубликованный текст остаётся на редакторе.")
   mimgui.Dummy(UI.v2(0, 8))
   mimgui.TextColored(UI.C.DIM, "%s",
      u8"Если не уверен - держи авто-одобрение выключенным и оставь только подсказки: шаблоны, автокоррекцию и проверки. Красная проверка всегда останавливает автопилот.")
   mimgui.PopTextWrapPos()
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##inf_about", UI.v2(-1, 156), "Об авторе", 'user')
   mimgui.PushTextWrapPos(0)
   mimgui.TextColored(UI.C.DIM, "%s",
      u8"Если скрипт экономит тебе время и бережёт нервы при редактировании объявлений - значит, я старался не зря.")
   mimgui.PopTextWrapPos()
   UI.CardEnd()

   mimgui.Dummy(UI.v2(0, 10))

   UI.CardBegin("##inf_faq", UI.v2(-1, 222), "Частые вопросы", 'help-circle')
   local function qa(q, a)
      mimgui.TextColored(UI.C.TEXT, "%s", u8(q))
      if fonts.small then mimgui.PushFont(fonts.small) end
      mimgui.TextColored(UI.C.MUTE, "%s", u8(a))
      if fonts.small then mimgui.PopFont() end
      mimgui.Dummy(UI.v2(0, 6))
   end
   qa("Не играет звук уведомления?", "Проверь resource/SMI Helper/smi_notify.wav")
   qa("Не сохраняются настройки?", "Запусти GTA SA от имени администратора")
   qa("Текст обрезается при отправке?", "Уменьши лимит длины в настройках проверок")
   UI.CardEnd()

   UI.PaneEnd()
end

mimgui.OnFrame(
   function() return windowState.settingsWindow[0] end,
   function()
      if needThemeUpdate then
         updateMoonMonetColors()
         UI.applyStyle()
         needThemeUpdate = false
      end

      UI.alpha = Ease.get(0, 1, anim.settings, 0.20, 'outSine')
      mimgui.PushStyleVarFloat(mimgui.StyleVar.Alpha, UI.alpha)

      if mimgui_blur and imguiVars.blurEnabled[0] then
         mimgui_blur.apply(mimgui.GetBackgroundDrawList(), imguiVars.bgBlurRadius[0])
      end

      local sw, sh = getScreenResolution()
      local SETTINGS_H = {
         settings = 880, stats = 880, templates = 880, blacklist = 880, info = 820
      }
      local setW = math.min(1120, sw - 40)
      local setH = math.min(SETTINGS_H[windowState.activeSettingsTab] or 880, sh - 50)
      mimgui.SetNextWindowSize(UI.v2(setW, setH), mimgui.Cond.Always)

      if forceCenterSettings then
         mimgui.SetNextWindowPos(UI.v2(sw / 2, sh / 2), mimgui.Cond.Always, UI.v2(0.5, 0.5))
         forceCenterSettings = false
      elseif (cfg.settings.settingsPosX or -1) >= 0 and (cfg.settings.settingsPosY or -1) >= 0 then
         mimgui.SetNextWindowPos(UI.v2(cfg.settings.settingsPosX, cfg.settings.settingsPosY),
            mimgui.Cond.FirstUseEver)
      else
         mimgui.SetNextWindowPos(UI.v2(sw / 2, sh / 2), mimgui.Cond.FirstUseEver, UI.v2(0.5, 0.5))
      end

      if fonts.main then mimgui.PushFont(fonts.main) end

      mimgui.PushStyleVarVec2(mimgui.StyleVar.WindowPadding, UI.v2(0, 0))
      mimgui.Begin("##settings_window", windowState.settingsWindow,
         mimgui.WindowFlags.NoCollapse + mimgui.WindowFlags.NoTitleBar
         + mimgui.WindowFlags.NoResize + mimgui.WindowFlags.NoScrollbar)
      mimgui.PopStyleVar()

      local setPos = mimgui.GetWindowPos()
      cfg.settings.settingsPosX = setPos.x
      cfg.settings.settingsPosY = setPos.y

      local SIDE = 224
      local dayP = (cfg.stats.dailyApproved or 0) / math.max(1, cfg.settings.dailyGoal or 50)
      if UI.WindowChrome(SETTINGS_TITLES[windowState.activeSettingsTab] or u8"Настройки",
         SIDE, math.min(1, dayP), SETTINGS_EMO[windowState.activeSettingsTab]) then
         windowState.settingsWindow[0] = false
      end

      UI.SidebarHeader(SIDE, state.active)

      mimgui.SetCursorPos(UI.v2((SIDE - (5 * 32 + 4 * 8)) / 2, 134))
      mimgui.BeginChild("##side_icons", UI.v2(SIDE - 24, 34), false)
      if UI.IconButton("##ic_pw", 'power',
         state.active and "Выключить скрипт" or "Включить скрипт",
         state.active and UI.C.SUCCESS or UI.C.DANGER) then
         imguiVars.active[0] = not imguiVars.active[0]
         syncStateFromImgui()
      end
      mimgui.SameLine(0, 8)
      if UI.IconButton("##ic_qu", 'inbox', "Открыть очередь") then openNewsredakQueue() end
      mimgui.SameLine(0, 8)
      if UI.IconButton("##ic_ps", state.queuePaused and 'player-play' or 'player-pause',
         state.queuePaused and "Возобновить автоматику" or "Пауза автоматики",
         state.queuePaused and UI.C.WARNC or nil) then
         state.queuePaused = not state.queuePaused
         if state.queuePaused then state.queueContinueAt = 0 end
      end
      mimgui.SameLine(0, 8)
      if UI.IconButton("##ic_bl", 'bell', "Тест звука") then playNotificationSound() end
      mimgui.SameLine(0, 8)
      if UI.IconButton("##ic_hp", 'help-circle', "Информация") then
         windowState.activeSettingsTab = "info"
      end
      mimgui.EndChild()

      mimgui.SetCursorPos(UI.v2(12, 173))
      mimgui.BeginChild("##side_tabs", UI.v2(SIDE - 24, -18), false)
      local picked = UI.SideTabs(SETTINGS_TABS, windowState.activeSettingsTab, anim.settings)
      if picked and picked ~= windowState.activeSettingsTab then
         windowState.activeSettingsTab = picked
         UI.resetNums()
      end
      mimgui.EndChild()

      local cdx = Ease.get(30, 0, anim.settings, 0.40, 'outQuint')
      mimgui.SetCursorPos(UI.v2(SIDE + 26 + cdx, 68))
      UI.PaneBegin("##content", UI.v2(-26 - cdx, -22))

      if windowState.activeSettingsTab == "settings" then
         local colW  = (mimgui.GetContentRegionAvail().x - 36) / 2
         local bx, by = mimgui.GetCursorPosX(), mimgui.GetCursorPosY()

         UI.PaneBegin("##col_left", UI.v2(colW, -1))

         UI.SectionTitle("Основные функции", true)
         if UI.ToggleRow("Скрипт активен", imguiVars.active,
            "Полностью включает и выключает всю автоматику") then syncStateFromImgui() end
         if UI.ToggleRow("Перехват команды /newsredak", imguiVars.interceptCommand,
            "Скрипт сам обрабатывает команду. Выключи, чтобы команда уходила на сервер как обычно") then
            syncStateFromImgui()
         end
         if UI.ToggleRow("Хоткей открывает очередь", imguiVars.newsredakHotkeyToggle,
            "Разрешить назначенной клавише открывать очередь") then syncStateFromImgui() end
         if UI.ToggleRow("Авто-ловля по команде", imguiVars.autoCatchByCommand,
            "Сам открывает список, как только пришло объявление") then syncStateFromImgui() end
         if UI.ToggleRow("Быстрые кнопки редактора", imguiVars.quickEditButtons,
            "Панель с сокращениями под полем ввода") then syncStateFromImgui() end
         if UI.ToggleRow("Виджет очереди на экране", imguiVars.queueWidget,
            "Список ожидающих объявлений поверх игры") then syncStateFromImgui() end
         if imguiVars.queueWidget[0] then
            UI.SubBegin()
            UI.SubRow("Строк", 108, function()
               if UI.NumberBox("##w_rows", imguiVars.queueWidgetRows, 3, 15, "") then
                  cfg.settings.queueWidgetRows = imguiVars.queueWidgetRows[0]
                  saveConfig(true)
               end
            end)
            UI.SubRow("Сигнал при", 108, function()
               if UI.NumberBox("##w_alert", imguiVars.queueAlertCount, 3, 60, "") then
                  cfg.settings.queueAlertCount = imguiVars.queueAlertCount[0]
                  saveConfig(true)
               end
            end)
            UI.SubEnd()
         end

         UI.SectionTitle("Автоматика")
         if UI.ToggleRow("Авто-одобрение по шаблону", imguiVars.autoApprove,
            "Точное совпадение отправляется само. Похожие - только вручную") then
            syncStateFromImgui()
         end
         if imguiVars.autoApprove[0] then
            UI.SubBegin()
            UI.SubRow("Задержка", 108, function()
               if UI.NumberBox("##d_app", imguiVars.autoApproveDelay, 0, 30, u8" с") then
                  cfg.settings.autoApproveDelay = imguiVars.autoApproveDelay[0]
                  saveConfig(true)
               end
            end)
            UI.SubEnd()
         end

         if UI.ToggleRow("Авто-пропуск при бездействии", imguiVars.autoSkipInactivity,
            "Если не печатать - объявление вернётся в очередь") then syncStateFromImgui() end
         if imguiVars.autoSkipInactivity[0] then
            UI.SubBegin()
            UI.SubRow("Таймаут", 108, function()
               if UI.NumberBox("##d_skip", imguiVars.autoSkipDelay, 5, 120, u8" с") then
                  cfg.settings.autoSkipDelay = imguiVars.autoSkipDelay[0]
                  saveConfig(true)
               end
            end)
            UI.SubEnd()
         end

         if UI.ToggleRow("Отправлять только в фокусе игры", imguiVars.requireWindowFocus,
            "Автопилот не отправит объявление, пока окно игры свёрнуто") then syncStateFromImgui() end

         UI.SectionTitle("Автокоррекция текста")
         if UI.ToggleRow("Автокоррекция включена", imguiVars.autoFixEnabled,
            "Кнопка Исправить в редакторе и хоткей") then syncStateFromImgui() end
         if imguiVars.autoFixEnabled[0] then
            if UI.ToggleRow("Применять при открытии", imguiVars.autoFixOnOpen,
               "Править текст сразу, как только открылся редактор") then syncStateFromImgui() end
            UI.SubBegin()
            for _, rule in ipairs(AutoFix.rules) do
               UI.SubRow(rule.name, 168, function()
                  local label = autofixVars[rule.id][0] and "Вкл" or "Выкл"
                  if UI.Button(label .. "##af_" .. rule.id, 84, 28,
                     autofixVars[rule.id][0] and 'accent' or nil) then
                     autofixVars[rule.id][0] = not autofixVars[rule.id][0]
                     syncStateFromImgui()
                  end
               end)
            end
            UI.SubEnd()
         end

         UI.SectionTitle("Звук")
         if UI.ToggleRow("Звук уведомлений", imguiVars.soundEnabled, nil) then syncStateFromImgui() end
         if imguiVars.soundEnabled[0] then
            UI.SubBegin()
            UI.SubRow("Громкость", 108, function()
               UI.SliderSave("##vol", imguiVars.volume, 0, 100, 130, "%.0f%%", function()
                  state.soundVolume = math.floor(imguiVars.volume[0])
                  cfg.settings.soundVolume = state.soundVolume
               end)
            end)
            UI.SubRow("Проверка", 108, function()
               if UI.Button("Прослушать##snd_test", 138, 28) then playNotificationSound() end
            end)
            UI.SubEnd()
         end

         mimgui.Dummy(UI.v2(0, 12))
         UI.PaneEnd()

         mimgui.SetCursorPos(UI.v2(bx + colW + 32, by))
         UI.PaneBegin("##col_right", UI.v2(colW, -1))

         UI.SectionTitle("Горячие клавиши", true)
         UI.HotkeyRow("scriptActive",  "Вкл/выкл скрипта")
         UI.HotkeyRow("cmdNewsredak",  "Открыть очередь")
         UI.HotkeyRow("autoCatch",     "Вкл/выкл авто-ловли")
         UI.HotkeyRow("queuePause",    "Пауза автоматики")
         UI.HotkeyRow("autoFix",       "Исправить текст")
         UI.HotkeyRow("skipAd",        "Пропустить объявление")

         UI.SectionTitle("Проверки перед отправкой")
         if UI.ToggleRow("Проверять текст", imguiVars.validateEnabled,
            "Длина, смена категории, потерянные числа. Красная проверка блокирует отправку") then
            syncStateFromImgui()
         end
         if imguiVars.validateEnabled[0] then
            UI.SubBegin()
            UI.SubRow("Минимум", 108, function()
               if UI.NumberBox("##v_min", imguiVars.minAdLength, 1, 60, "") then
                  cfg.settings.minAdLength = imguiVars.minAdLength[0]
                  saveConfig(true)
               end
            end)
            UI.SubRow("Максимум", 108, function()
               if UI.NumberBox("##v_max", imguiVars.maxAdLength, 40, 500, "") then
                  cfg.settings.maxAdLength = imguiVars.maxAdLength[0]
                  saveConfig(true)
               end
            end)
            UI.SubEnd()
         end

         UI.SectionTitle("Шаблоны")
         local fz = mimgui.GetCursorScreenPos()
         mimgui.GetWindowDrawList():AddText(UI.v2(fz.x + 8, fz.y + 5),
            UI.u32(UI.C.DIM), u8"Порог схожести")
         mimgui.SetCursorScreenPos(UI.v2(fz.x + 150, fz.y))
         if UI.NumberBox("##fz_thr", imguiVars.fuzzyThreshold, 50, 95, "%") then
            cfg.settings.fuzzyThreshold = imguiVars.fuzzyThreshold[0]
            Tpl.invalidate()
            saveConfig(true)
         end
         mimgui.SetCursorScreenPos(UI.v2(fz.x, fz.y + 34))

         UI.SectionTitle("Оформление")
         local activeColor = tonumber(cfg.settings.moonmonetBaseColor) or 0xFF00BABE
         for i, p in ipairs({ 0xFF00BABE, 0xFF8A2BE2, 0xFF007ACC,
                              0xFF2ECC71, 0xFFFFD700, 0xFFDC143C }) do
            if UI.ColorDot("##dot" .. i, p, p == activeColor) then
               cfg.settings.moonmonetBaseColor = p
               needThemeUpdate = true
               saveConfig(true)
            end
            if i < 6 then mimgui.SameLine(0, 6) end
         end
         mimgui.Dummy(UI.v2(0, 8))

         if UI.ToggleRow("Размытие фона", imguiVars.blurEnabled, nil) then syncStateFromImgui() end
         if imguiVars.blurEnabled[0] then
            UI.SubBegin()
            UI.SubRow("В редакторе", 118, function()
               UI.SliderSave("##bl_bg", imguiVars.bgBlurRadius, 5, 50, 120, "%.0f", function()
                  cfg.settings.blurBackgroundRadius = imguiVars.bgBlurRadius[0]
               end)
            end)
            UI.SubRow("В списке", 118, function()
               UI.SliderSave("##bl_ls", imguiVars.listBlurRadius, 1, 50, 120, "%.0f", function()
                  cfg.settings.blurListRadius = imguiVars.listBlurRadius[0]
               end)
            end)
            UI.SubEnd()
         end

         UI.SectionTitle("Прочее")
         if UI.ToggleRow("Тихий режим", imguiVars.silentMode,
            "Скрипт молчит в чате, оставляя только ошибки и всплывающие уведомления") then
            syncStateFromImgui()
         end
         if UI.ToggleRow("Живой фон и подсветка", imguiVars.fxAnimations,
            "Свечение, бегущий огонёк по краю и орбита логотипа. На слабых ПК можно выключить") then
            syncStateFromImgui()
         end
         if UI.ToggleRow("Эмодзи в сообщениях чата", imguiVars.chatEmoji,
            "Если сервер не поддерживает кастомные значки - можно отключить") then
            syncStateFromImgui()
         end
         if UI.ToggleRow("Эмодзи в интерфейсе", imguiVars.uiEmoji,
            "Иконки Arizona вместо шрифтовых глифов в меню") then syncStateFromImgui() end
         if imguiVars.chatEmoji[0] then
            UI.SubBegin()
            UI.SubRow("Детализация", 108, function()
               local lv = imguiVars.chatEmojiLevel[0]
               local label = (lv == 1) and "Базовые (цвета)" or "Полные (все иконки)"
               if UI.Button(label .. "##em_lvl", 170, 28) then
                  imguiVars.chatEmojiLevel[0] = (lv == 1) and 2 or 1
                  syncStateFromImgui()
               end
            end)
            UI.SubEnd()
         end

         mimgui.Dummy(UI.v2(0, 2))
         local dgp = mimgui.GetCursorScreenPos()
         mimgui.GetWindowDrawList():AddText(UI.v2(dgp.x + 8, dgp.y + 5),
            UI.u32(UI.C.DIM), u8"Дневная цель")
         mimgui.SetCursorScreenPos(UI.v2(dgp.x + 150, dgp.y))
         if UI.NumberBox("##goal", imguiVars.dailyGoal, 1, 500, "") then
            cfg.settings.dailyGoal = imguiVars.dailyGoal[0]
            saveConfig(true)
         end
         mimgui.SetCursorScreenPos(UI.v2(dgp.x, dgp.y + 34))

         if UI.Button("Сбросить позиции окон##rst", 0, 36) then
            forceCenterMain, forceCenterSettings = true, true
            cfg.settings.windowPosX,   cfg.settings.windowPosY   = -1, -1
            cfg.settings.settingsPosX, cfg.settings.settingsPosY = -1, -1
            cfg.settings.queueWidgetX, cfg.settings.queueWidgetY = -1, -1
            saveConfig(true)
         end
         mimgui.Dummy(UI.v2(0, 6))
         if Queue.editing then
            if UI.Button("Готово, зафиксировать виджет##qpos", 0, 36, 'accent') then
               Queue.editing = false
               saveConfig(true)
            end
         else
            if UI.Button("Настроить позицию виджета##qpos", 0, 36) then
               Queue.editing = true
               chat(CHAT.TEXT .. "Перетащи виджет мышкой, затем нажми " .. CHAT.HI .. "Готово")
            end
         end

         mimgui.Dummy(UI.v2(0, 12))
         UI.PaneEnd()

      elseif windowState.activeSettingsTab == "templates" then
         renderTemplatesTab()
      elseif windowState.activeSettingsTab == "blacklist" then
         render_blacklist_tab()
      elseif windowState.activeSettingsTab == "stats" then
         renderStatsTab()
      elseif windowState.activeSettingsTab == "info" then
         renderInfoTab()
      end

      UI.PaneEnd()
      mimgui.End()
      if fonts.main then mimgui.PopFont() end
      mimgui.PopStyleVar()
      UI.alpha = 1.0
   end
)

mimgui.OnFrame(
   function()
      if cfg.settings.queueWidget == false then return false end
      return Queue.editing or #Queue.items > 0
   end,
   function(player)
      if not Queue.editing
         and not windowState.mainWindow[0]
         and not windowState.settingsWindow[0] then
         player.HideCursor = true
      end

      Queue.prune()

      local sw, sh = getScreenResolution()
      local px = tonumber(cfg.settings.queueWidgetX) or -1
      local py = tonumber(cfg.settings.queueWidgetY) or -1
      if px < 0 or py < 0 then
         px, py = sw - C.QUEUE_WIDGET_W - 24, math.floor(sh * 0.28)
      end
      px = math.max(0, math.min(px, sw - C.QUEUE_WIDGET_W))
      py = math.max(0, math.min(py, sh - 80))

      local maxRows = math.max(3, tonumber(cfg.settings.queueWidgetRows) or 6)
      local total   = #Queue.items
      local shown   = math.min(total, maxRows)
      local rowH    = 28
      local headerH = 42
      local footerH = 22
      local winH    = headerH + math.max(shown, 1) * rowH + 14 + footerH
      if total > shown then winH = winH + 22 end

      mimgui.SetNextWindowPos(
         mimgui.ImVec2(px, py),
         Queue.editing and mimgui.Cond.FirstUseEver or mimgui.Cond.Always
      )
      mimgui.SetNextWindowSize(mimgui.ImVec2(C.QUEUE_WIDGET_W, winH), mimgui.Cond.Always)

      local flags = mimgui.WindowFlags.NoTitleBar
         + mimgui.WindowFlags.NoResize
         + mimgui.WindowFlags.NoScrollbar
         + mimgui.WindowFlags.NoCollapse
         + mimgui.WindowFlags.NoFocusOnAppearing
         + mimgui.WindowFlags.NoBringToFrontOnFocus
         + mimgui.WindowFlags.NoBackground
      if not Queue.editing then
         flags = flags + mimgui.WindowFlags.NoInputs + mimgui.WindowFlags.NoMove
      end

      if fonts.main then mimgui.PushFont(fonts.main) end
      mimgui.Begin("##queue_widget", nil, flags)

      if Queue.editing then
         local wp = mimgui.GetWindowPos()
         cfg.settings.queueWidgetX = math.floor(wp.x)
         cfg.settings.queueWidgetY = math.floor(wp.y)
      end

      local DL     = mimgui.GetWindowDrawList()
      local origin = mimgui.GetWindowPos()
      local accent = getAccentVec4()
      local W      = C.QUEUE_WIDGET_W

      DL:AddRectFilled(UI.v2(origin.x, origin.y + 3), UI.v2(origin.x + W, origin.y + winH + 3),
         UI.u32(mimgui.ImVec4(0, 0, 0, 0.30)), 12.0)
      DL:AddRectFilled(origin, UI.v2(origin.x + W, origin.y + winH),
         UI.u32(UI.a(UI.C.BG_SIDE, 0.94)), 12.0)
      DL:AddRectFilled(origin, UI.v2(origin.x + 3, origin.y + winH),
         UI.u32(state.queuePaused and UI.C.WARNC or UI.C.ACCENT), 12.0, 5)
      DL:AddRect(origin, UI.v2(origin.x + W, origin.y + winH),
         UI.u32(UI.a(UI.C.ACCENT, 0.20)), 12.0, 0xF, 1.0)
      if Queue.editing then
         DL:AddRect(origin, UI.v2(origin.x + W, origin.y + winH),
            UI.u32(UI.a(UI.C.ACCENT, 0.85)), 12.0, 0xF, 2.0)
      end

      local hdrCY   = origin.y + headerH / 2 - 3
      local title   = state.queuePaused and u8"Очередь (пауза)" or u8"Очередь"
      local titleSz = mimgui.CalcTextSize(title)

      local cnt    = tostring(total)
      local cntSz  = mimgui.CalcTextSize(cnt)
      local badgeH = titleSz.y + 6
      local badgeW = math.max(badgeH, cntSz.x + 16)
      local badgeX = origin.x + W - badgeW - 14

      local hx = origin.x + 18
      local ew = UI.emoMid(DL, ":u1f4e5:", hx, hdrCY, 18)
      if ew > 0 then
         hx = hx + ew + 8
      else
         local icon = getIcon('inbox', '')
         if icon ~= "" then
            local isz = mimgui.CalcTextSize(icon)
            DL:AddText(UI.v2(hx, hdrCY - isz.y / 2), UI.u32(UI.C.ACCENT), icon)
            hx = hx + isz.x + 8
         end
      end

      DL:PushClipRect(UI.v2(hx, origin.y), UI.v2(badgeX - 6, origin.y + headerH), true)
      DL:AddText(UI.v2(hx, hdrCY - titleSz.y / 2),
         UI.u32(state.queuePaused and UI.C.WARNC or UI.C.TEXT), title)
      DL:PopClipRect()

      if Queue.pulseAt then
         local k = (os.clock() - Queue.pulseAt) / 1.1
         if k >= 1 then
            Queue.pulseAt = nil
         else
            DL:AddRect(
               UI.v2(badgeX - 14 * k, hdrCY - badgeH / 2 - 12 * k),
               UI.v2(badgeX + badgeW + 14 * k, hdrCY + badgeH / 2 + 12 * k),
               UI.u32(UI.a(UI.C.ACCENT, 0.75 * (1 - k))),
               badgeH / 2 + 12 * k, 0xF, 2.0)
         end
      end
      DL:AddRectFilled(UI.v2(badgeX, hdrCY - badgeH / 2),
         UI.v2(badgeX + badgeW, hdrCY + badgeH / 2),
         UI.u32(UI.a(UI.C.ACCENT, 0.35)), badgeH / 2)
      DL:AddText(UI.v2(badgeX + (badgeW - cntSz.x) / 2, hdrCY - cntSz.y / 2),
         UI.u32(UI.C.TEXT), cnt)

      DL:AddLine(UI.v2(origin.x + 14, origin.y + headerH - 3),
         UI.v2(origin.x + W - 12, origin.y + headerH - 3), UI.u32(UI.C.LINE), 1.0)

      local now = os.time()
      if total == 0 then
         withFont('small', function()
            DL:AddText(mimgui.ImVec2(origin.x + 18, origin.y + headerH + 5),
               mimgui.ColorConvertFloat4ToU32(UI.C.MUTE), u8"Пусто")
         end)
      end

      for i = 1, shown do
         local it = Queue.items[i]
         local ry = origin.y + headerH + (i - 1) * rowH

         local dot = it.vip and UI.C.GOLD or UI.C.ACCENT
         local vipDrawn = false
         if it.vip then
            local pl = 0.5 + 0.5 * math.sin(os.clock() * 3.0 + i)
            DL:AddCircleFilled(mimgui.ImVec2(origin.x + 20, ry + rowH / 2), 9.0 + 2.0 * pl,
               mimgui.ColorConvertFloat4ToU32(UI.a(UI.C.GOLD, 0.10 + 0.10 * pl)), 18)
            vipDrawn = UI.emoMid(DL, ":u1f451:", origin.x + 13, ry + rowH / 2, 15) > 0
         end
         if not vipDrawn then
            DL:AddCircleFilled(mimgui.ImVec2(origin.x + 20, ry + rowH / 2),
               it.vip and 5.0 or 4.0, mimgui.ColorConvertFloat4ToU32(dot), 14)
         end

         local nameSz = mimgui.CalcTextSize(u8(it.nick))
         DL:PushClipRect(mimgui.ImVec2(origin.x + 34, ry),
            mimgui.ImVec2(origin.x + W - 56, ry + rowH), true)
         DL:AddText(mimgui.ImVec2(origin.x + 34, ry + (rowH - nameSz.y) / 2),
            mimgui.ColorConvertFloat4ToU32(UI.C.TEXT), u8(it.nick))
         DL:PopClipRect()

         local age  = now - it.at
         local ageT = (age < 60) and (age .. u8"с") or (math.floor(age / 60) .. u8"м")
         local ageC = (age > 120) and UI.C.DANGER
            or ((age > 60) and UI.C.WARNC or UI.C.MUTE)
         withFont('small', function()
            local asz = mimgui.CalcTextSize(ageT)
            DL:AddText(mimgui.ImVec2(origin.x + W - asz.x - 14, ry + (rowH - asz.y) / 2),
               mimgui.ColorConvertFloat4ToU32(ageC), ageT)
         end)
      end

      local footY = origin.y + headerH + math.max(shown, 1) * rowH + 4
      if total > shown then
         withFont('small', function()
            DL:AddText(mimgui.ImVec2(origin.x + 34, footY),
               mimgui.ColorConvertFloat4ToU32(UI.C.MUTE),
               u8(("... ещё %d"):format(total - shown)))
         end)
         footY = footY + 22
      end

      withFont('small', function()
         local avg = avgEditSeconds()
         local eta = (avg > 0) and math.ceil(total * avg / 60) or 0
         local left = (eta > 0) and ("~" .. eta .. " мин") or "нет данных"
         local info = u8(("%s   %d/час"):format(left, adsPerHour()))
         DL:AddText(mimgui.ImVec2(origin.x + 18, footY),
            mimgui.ColorConvertFloat4ToU32(UI.C.MUTE), info)
      end)

      if Queue.editing then
         withFont('small', function()
            DL:AddText(mimgui.ImVec2(origin.x + 14, origin.y + winH + 6),
               mimgui.ColorConvertFloat4ToU32(accent),
               u8"Тащи мышкой. Готово - кнопка в настройках.")
         end)
      end

      mimgui.End()
      if fonts.main then mimgui.PopFont() end
   end
)

mimgui.OnFrame(
   function() return #Toast.items > 0 end,
   function(player)
      if not windowState.mainWindow[0] and not windowState.settingsWindow[0] then
         player.HideCursor = true
      end
      UI.alpha = 1.0

      local sw, sh = getScreenResolution()
      local BOX_H, BOX_PAD = 480, 40
      mimgui.SetNextWindowPos(UI.v2(sw - 520, sh - BOX_H - BOX_PAD), mimgui.Cond.Always)
      mimgui.SetNextWindowSize(UI.v2(520, BOX_H), mimgui.Cond.Always)
      mimgui.Begin("##toasts", nil,
         mimgui.WindowFlags.NoTitleBar + mimgui.WindowFlags.NoResize
         + mimgui.WindowFlags.NoScrollbar + mimgui.WindowFlags.NoCollapse
         + mimgui.WindowFlags.NoInputs + mimgui.WindowFlags.NoMove
         + mimgui.WindowFlags.NoFocusOnAppearing
         + mimgui.WindowFlags.NoBringToFrontOnFocus
         + mimgui.WindowFlags.NoBackground)

      if fonts.main then mimgui.PushFont(fonts.main) end

      local DL  = mimgui.GetWindowDrawList()
      local o   = mimgui.GetWindowPos()
      local dt  = mimgui.GetIO().DeltaTime
      local now = os.clock()
      local W   = Toast.W

      local i, stackY = 1, 0
      while i <= #Toast.items do
         local t = Toast.items[i]
         if now - t.born > t.life then
            table.remove(Toast.items, i)
         else
            local h = t.text and 76 or 54

            local dx = Ease.get(90, 0, t.born, 0.40, 'outQuint')
            local a  = Ease.get(0, 1, t.born, 0.22, 'outQuad')
            local outAt = t.born + t.life - 0.35
            if now >= outAt then
               dx = Ease.get(0, 90, outAt, 0.35, 'inQuart')
               a  = Ease.get(1, 0,  outAt, 0.35, 'inQuart')
            end

            t.y = t.y or stackY
            t.y = t.y + (stackY - t.y) * math.min(dt * 14, 1)

            local x   = (sw - 24 - W) + dx
            local y   = (o.y + BOX_H) - t.y - h
            local col, ic, emk = Toast.style(t.kind)

            DL:AddRectFilled(UI.v2(x + 2, y + 3), UI.v2(x + W + 2, y + h + 3),
               UI.u32(mimgui.ImVec4(0, 0, 0, 0.30 * a)), 10.0)
            DL:AddRectFilled(UI.v2(x, y), UI.v2(x + W, y + h),
               UI.u32(UI.a(UI.C.BG_SIDE, 0.95 * a)), 10.0)
            DL:AddRectFilled(UI.v2(x, y), UI.v2(x + 4, y + h),
               UI.u32(UI.a(col, a)), 10.0, 5)
            DL:AddRect(UI.v2(x, y), UI.v2(x + W, y + h),
               UI.u32(UI.a(col, 0.30 * a)), 10.0, 0xF, 1.0)

            local iy = t.text and (y + 16) or (y + (h - 20) / 2)
            if UI.emo(DL, emk, x + 20, iy, 20, a) == 0 then
               local isz = mimgui.CalcTextSize(ic)
               DL:AddText(UI.v2(x + 20, t.text and (y + 16) or (y + (h - isz.y) / 2)),
                  UI.u32(UI.a(col, a)), ic)
            end

            DL:PushClipRect(UI.v2(x + 52, y), UI.v2(x + W - 14, y + h), true)
            local tt = u8(t.title)
            DL:AddText(UI.v2(x + 52, t.text and (y + 14) or (y + (h - mimgui.CalcTextSize(tt).y) / 2)),
               UI.u32(UI.a(UI.C.TEXT, a)), tt)
            if t.text then
               if fonts.small then mimgui.PushFont(fonts.small) end
               DL:AddText(UI.v2(x + 52, y + 43), UI.u32(UI.a(UI.C.MUTE, a)), u8(t.text))
               if fonts.small then mimgui.PopFont() end
            end
            DL:PopClipRect()

            local left = math.max(0, 1 - (now - t.born) / t.life)
            DL:AddRectFilled(UI.v2(x + 6, y + h - 4), UI.v2(x + W - 6, y + h - 2),
               UI.u32(mimgui.ImVec4(1, 1, 1, 0.07 * a)), 1.0)
            DL:AddRectFilled(UI.v2(x + 6, y + h - 4),
               UI.v2(x + 6 + (W - 12) * left, y + h - 2), UI.u32(UI.a(col, 0.75 * a)), 1.0)

            stackY = stackY + h + 8
            i = i + 1
         end
      end

      if fonts.main then mimgui.PopFont() end
      mimgui.End()
   end
)

function checkNotificationSound()
   if not doesFileExist(notificationSoundFile) then
      chat(CHAT.MUTED .. "Звук уведомления не найден: " .. CHAT.HI .. "smi_notify.wav")
   end
end

function showChangelog()
   if cfg.settings.lastSeenVersion == SCRIPT_VERSION then return end
   cfg.settings.lastSeenVersion = SCRIPT_VERSION
   saveConfig(true)
   chat(CHAT.OK .. "Обновление до " .. CHAT.HI .. "v" .. SCRIPT_VERSION, 'NEW', true)
   for _, line in ipairs(CHANGELOG) do
      chat(CHAT.MUTED .. CHAT.ARROW .. " " .. line, nil, true)
   end
   Toast.push('ok', 'SMI Helper обновлён', 'v' .. SCRIPT_VERSION .. ' - список изменений в чате', 6.0)
end

function toggleQueuePause()
   state.queuePaused = not state.queuePaused
   if state.queuePaused then
      state.queueContinueAt = 0
      chat(CHAT.WARN .. "Автоматика на паузе", 'PAUSE')
      Toast.push('warn', 'Пауза', 'Автоматика остановлена', 2.5)
   else
      chat(CHAT.OK .. "Автоматика возобновлена", 'PLAY')
      Toast.push('ok', 'Работаем дальше', nil, 2.0)
      if state.queueAutomationActive then scheduleQueueContinue(0.5) end
   end
end

function hotkeyConflict(prefix, key)
   for name, value in pairs(cfg.hotkeys) do
      local other = name:match('^(.+)_key$')
      if other and other ~= prefix and tonumber(value) == key then
         return other
      end
   end
   return nil
end

local HOTKEY_NAMES = {
   scriptActive = "Вкл/выкл скрипта",
   cmdNewsredak = "Открыть очередь",
   autoCatch    = "Вкл/выкл авто-ловли",
   queuePause   = "Пауза автоматики",
   autoFix      = "Исправить текст",
   skipAd       = "Пропустить объявление"
}

function main()
   if not isSampLoaded() then
      thisScript():unload()
      return
   end
   while not isSampAvailable() do wait(0) end

   if not ok_raklua and not isSampfuncsLoaded() then
      logLine('FATAL', 'Нужен SAMPFUNCS или RakLua для работы samp.events')
      thisScript():unload()
      return
   end

   ensureDirectoryExists()
   CrashHandler.install()
   checkNotificationSound()

   cfg.stats.sessionApproved = 0
   cfg.stats.sessionRejected = 0
   cfg.stats.sessionEarnings = 0
   cfg.stats.sessionBlockedBL = 0
   saveConfig(true)

   local okTmpl, errTmpl = pcall(loadTemplates)
   if not okTmpl then
      logLine('WARN', 'Ошибка загрузки шаблонов: ' .. tostring(errTmpl))
   else
      pcall(Tpl.cleanup)
   end

   pcall(load_blacklist)
   pcall(Data.load)
   syncImguiVars()

   local ok_idx = pcall(loadSenderIndex)
   if not ok_idx then
      logLine('WARN', 'Ошибка загрузки индекса ников.')
   end

   local function handleServerMessage(color, text)
      if state.awaitingSendResult and windowState.currentView == "editor"
         and text:find('Недавно было опубликовано VIP объявление')
         and text:find('отправка будет доступна через') then
         local secondsLeft = tonumber(text:match('через%s+(%d+)')) or 0
         triggerVipRecatch(secondsLeft)
         return
      end

      local clean_text = text:gsub('{.-}', '')

      if clean_text:find('Вы получили .- за отредактированое вами объявление') then
         check_daily_reset()
         local sum_str = clean_text:match('Вы получили .-([%d%.]+) за отредактированое вами объявление')
         if sum_str then
            local amount = tonumber((sum_str:gsub('%.', ''))) or 0
            cfg.stats.dailyEarnings = cfg.stats.dailyEarnings + amount
            cfg.stats.totalEarnings = (cfg.stats.totalEarnings or 0) + amount
            cfg.stats.sessionEarnings = (cfg.stats.sessionEarnings or 0) + amount
            saveConfig()
         end
      end

      if clean_text:find('Так же Вы получаете доплату за ранг') then
         check_daily_reset()
         local sum_str = clean_text:match('Так же Вы получаете доплату за ранг .-([%d%.]+)')
         if sum_str then
            local amount = tonumber((sum_str:gsub('%.', ''))) or 0
            cfg.stats.dailyEarnings = cfg.stats.dailyEarnings + amount
            cfg.stats.totalEarnings = (cfg.stats.totalEarnings or 0) + amount
            cfg.stats.sessionEarnings = (cfg.stats.sessionEarnings or 0) + amount
            saveConfig()
         end
      end

      if not state.active then return end

      if state.isProcessing and not windowState.mainWindow[0] and windowState.currentView == "idle" then
         resetProcessingState()
      end

      if clean_text:find('На обработку объявлений пришло') and clean_text:find('сообщение от:') then
         local now = os.clock()
         if now - lastCatchTime < C.CATCH_COOLDOWN then return end

         if windowState.mainWindow[0]
            and (windowState.currentView == "list" or windowState.currentView == "menu")
            and not state.awaitingSendResult then
            local dlgId = (windowState.currentView == "menu") and menuData.dialogId or listData.dialogId
            sampSendDialogResponse(dlgId, 0, 0, "")
            windowState.mainWindow[0] = false
            resetProcessingState()
         end

         if state.isProcessing then return end
         if windowState.mainWindow[0] then return end
         if windowState.currentView ~= "idle" then return end

         lastCatchTime = now
         state.isVipAd = clean_text:find('VIP') ~= nil

         local sender = clean_text:match('сообщение от:%s*(.+)')
         if sender then
            sender = sender:gsub('^%s+', ''):gsub('%s+$', '')
            if sender == '' then sender = nil end
         end

         if sender then
            local clean_key = normalizeSender(sender)
            state.recentSkips[clean_key] = nil
            if blacklist[clean_key] then
               local _, blReason = getBlacklistData(clean_key)
               cfg.stats.totalBlockedBL = (cfg.stats.totalBlockedBL or 0) + 1
               cfg.stats.sessionBlockedBL = (cfg.stats.sessionBlockedBL or 0) + 1
               Data.addBlock(sender, blReason)
               Data.save()
               saveConfig()
               chat(CHAT.MUTED .. "Пропущено: " .. CHAT.HI .. sender .. CHAT.MUTED .. " в чёрном списке")
               return
            end
         end

         state.expectedSender = sender
         Queue.add(sender, state.isVipAd)

         local alertAt = tonumber(cfg.settings.queueAlertCount) or 10
         if #Queue.items >= alertAt and state.alertedQueueCount < #Queue.items then
            state.alertedQueueCount = #Queue.items
            Toast.push('warn', 'Очередь растёт', ("В очереди %d объявлений"):format(#Queue.items), 5.0)
            chat(CHAT.WARN .. "В очереди уже " .. CHAT.HI .. #Queue.items .. CHAT.WARN .. " объявлений", 'BOX')
         elseif #Queue.items < alertAt then
            state.alertedQueueCount = 0
         end

         if sender then
            chat(CHAT.TEXT .. "Новое объявление от " .. CHAT.HI .. sender ..
               (state.isVipAd and (" " .. CHAT.WARN .. "[VIP]") or ""),
               state.isVipAd and 'VIP' or nil)
         else
            chat(CHAT.TEXT .. "Новое объявление в очереди")
         end
         playNotificationSound()
         Toast.push(state.isVipAd and 'warn' or 'info', 'Новое объявление', sender or 'В очереди', 3.5)

         if state.autoCatchByCommand and not state.queuePaused then
            state.queueAutomationActive = true
            lua_thread.create(function()
               wait(0)
               startQueueProcessing(CHAT.MUTED .. "Открываю очередь автоматически...")
            end)
         elseif state.queuePaused then
            chat(CHAT.MUTED .. "Автоматика на паузе")
         else
            chat(CHAT.MUTED .. "Нажми хоткей, чтобы открыть очередь")
         end
      end
   end

   local function handleShowDialog(dialogId, style, title, button1, button2, text)
      if state.awaitingSendResult then
         if dialogId == DIALOG_ID.AD_EDITOR then
            local parsedIncoming = parseAdDialog(text)
            editorData.openTime = os.clock()
            if parsedIncoming.message == editorData.message and parsedIncoming.sender == editorData.sender then
               state.awaitingSendResult = false
               chat(CHAT.ERR .. "Сервер отклонил отправку, редактор открыт заново")
               state.isProcessing = true
               windowState.currentView = "editor"
               anim.main = os.clock()
               windowState.mainWindow[0] = true
               return false
            else
               state.awaitingSendResult = false
               finalizeApprovedSend(state.pendingSentText or getEditorInputText())
            end
         else
            state.awaitingSendResult = false

            local stillInList = false
            if dialogId == DIALOG_ID.AD_LIST and editorData.sender and editorData.sender ~= "" then
               local _, entries = parseTabList(text)
               local sentKey = normalizeSender(editorData.sender)
               for _, e in ipairs(entries) do
                  if not e.inEdit and normalizeSender(e.columns[1] or '') == sentKey then
                     stillInList = true
                     break
                  end
               end
            end

            if stillInList then
               state.sendRetryCount = (state.sendRetryCount or 0) + 1
               local savedText = state.pendingSentText
               local savedFor = editorData.sender
               local retries = state.sendRetryCount
               resetProcessingState()
               state.sendRetryCount = retries
               state.isProcessing = true

               if state.sendRetryCount <= 2 then
                  chat(CHAT.WARN .. "Отправка не прошла, повтор " .. CHAT.HI ..
                     state.sendRetryCount .. "/2", 'RETRY')
                  state.pendingSentText = savedText
                  state.pendingSentFor = savedFor
                  state.expectedSender = savedFor
               else
                  state.sendRetryCount = 0
                  state.recentSkips[normalizeSender(savedFor or '')] = os.clock() + C.SKIP_RETRY_COOLDOWN
                  chat(CHAT.ERR .. "Два раза не прошло. Пропускаю, беру следующее", 'NEXT')
                  state.newsredakMode = true
                  state.prioritySearching = true
               end
            else
               state.sendRetryCount = 0
               finalizeApprovedSend(state.pendingSentText or getEditorInputText())
               if dialogId == DIALOG_ID.MAIN_MENU or dialogId == DIALOG_ID.AD_LIST then
                  state.isProcessing = true
                  state.newsredakMode = true
                  state.prioritySearching = true
               end
            end
         end
      end

      if windowState.currentView == "editor" and windowState.mainWindow[0] and not state.awaitingSendResult then
         if dialogId == DIALOG_ID.MAIN_MENU or dialogId == DIALOG_ID.AD_LIST or dialogId == DIALOG_ID.AD_EDITOR then
            return false
         end
      end

      if dialogId == DIALOG_ID.EMPTY_QUEUE and text:find('На данный момент сообщений нет') and state.active then
         chat(CHAT.MUTED .. "Очередь пуста", 'BOX')
         Queue.items = {}
         state.alertedQueueCount = 0
         stopQueueAutomation()
         resetProcessingState()
         return false
      end

      if dialogId == DIALOG_ID.MAIN_MENU and state.active then
         if suppressNextMenu then
            suppressNextMenu = false
            sampSendDialogResponse(dialogId, 0, 0, "")
            resetProcessingState()
            return false
         end

         state.isProcessing = true
         menuData.items = parseMenuList(text)
         menuData.dialogId = dialogId

         if state.expectedSender or state.newsredakMode then
            sampSendDialogResponse(dialogId, 1, 0, "")
            return false
         end

         windowState.currentView = "menu"
         anim.main = os.clock()
         windowState.mainWindow[0] = true
         return false
      end

      if dialogId == DIALOG_ID.AD_LIST and state.active then
         state.releaseEditorUntil = 0
         state.isProcessing = true
         local headers, entries = parseTabList(text)
         listData.headers = headers
         listData.entries = entries
         listData.selectedIndex = -1
         listData.dialogId = dialogId
         Queue.syncFromList(entries)

         if state.newsredakMode then
            listData.highlightIndices = {}
         else
            updateListHighlights()
         end

         windowState.currentView = "list"
         anim.main = os.clock()
         windowState.mainWindow[0] = true
         return false
      end

      if dialogId == DIALOG_ID.AD_EDITOR and state.active then
         if os.clock() < (state.releaseEditorUntil or 0) then
            state.releaseEditorUntil = 0
            if not state.expectedSender then
               suppressNextMenu = true
            end
            sampSendDialogResponse(dialogId, 0, 0, "")
            return false
         end

         state.isProcessing = true

         local parsed = parseAdDialog(text)
         editorData.sender = parsed.sender
         editorData.time = parsed.time
         editorData.message = parsed.message
         local template, isFuzzy, fuzzyScore = Tpl.find(parsed.message)
         editorData.dialogId = dialogId
         editorData.openTime = os.clock()
         state.templateMatch = template and { fuzzy = isFuzzy, score = fuzzyScore } or nil
         state.usedTemplate = (template ~= nil)
         state.autoFixApplied = nil

         state.expectedSender = nil

         if windowState.currentView == "waiting_for_editor" then
            windowState.mainWindow[0] = false
         end

         ffi.fill(editorData.inputBuffer, 4096, 0)
         ffi.fill(editorData.rejectBuffer, 1024, 0)

         local textToInsert
         local restored = false
         if state.pendingSentText and state.pendingSentText ~= ""
            and (not state.pendingSentFor
                 or normalizeSender(parsed.sender or '') == normalizeSender(state.pendingSentFor)) then
            textToInsert = state.pendingSentText
            state.pendingSentText = nil
            state.pendingSentFor = nil
            restored = true
            chat(CHAT.OK .. "Текст восстановлен")
         elseif template then
            textToInsert = template
            if isFuzzy then
               chat(CHAT.WARN .. "Похожий шаблон " .. CHAT.HI .. fuzzyScore .. "%" ..
                  CHAT.WARN .. " - проверь текст перед отправкой")
               Toast.push('warn', ('Похожий шаблон %d%%'):format(fuzzyScore),
                  'Проверь текст перед отправкой', 5.0)
            else
               chat(CHAT.OK .. "Подставлен сохранённый шаблон", 'TPL')
               Toast.push('ok', 'Шаблон подставлен', nil, 2.5)
            end
         else
            textToInsert = parsed.message
         end

         setEditorInputText(textToInsert)

         if cfg.settings.autoFixOnOpen and cfg.settings.autoFixEnabled ~= false
            and not restored and not template then
            applyAutoFix(false)
         end
         runValidation()

         windowState.currentView = "editor"
         anim.main = os.clock()
         windowState.mainWindow[0] = true

         local safeForAuto = (state.validation == nil) or (state.validation.level ~= 'bad')

         if state.autoApprove and template and not isFuzzy and safeForAuto then
            local delay = cfg.settings.autoApproveDelay or 0
            if delay > 0 then
               state.autoApproveAt = os.clock() + delay
               chat(CHAT.TEXT .. "Авто-отправка через " .. CHAT.HI .. delay .. CHAT.TEXT ..
                  " сек " .. CHAT.MUTED .. "(начни печатать, чтобы отменить)")
            else
               startEditorSendAttempt('auto')
            end
         else
            state.autoApproveAt = 0
            if state.autoApprove and template and not isFuzzy and not safeForAuto then
               chat(CHAT.WARN .. "Автопилот пропущен: текст не прошёл проверку", 'STOP')
            end
         end

         if state.autoApproveAt == 0 and cfg.settings.autoSkipInactivity and cfg.settings.autoSkipDelay > 0 then
            state.autoSkipAt = os.clock() + cfg.settings.autoSkipDelay
         else
            state.autoSkipAt = 0
         end

         return false
      end
   end

   samp.onServerMessage = function(color, text)
      local ok, err = pcall(handleServerMessage, color, text)
      if not ok then
         logLine('ERROR', 'onServerMessage: ' .. tostring(err))
      end
   end

   samp.onShowDialog = function(dialogId, style, title, button1, button2, text)
      local ok, res = pcall(handleShowDialog, dialogId, style, title, button1, button2, text)
      if not ok then
         logLine('ERROR', 'onShowDialog: ' .. tostring(res))
         chat(CHAT.ERR .. "Ошибка обработки диалога, отдаю управление серверу")
         resetProcessingState()
         return
      end
      return res
   end

   sampRegisterChatCommand('smi', function()
      windowState.settingsWindow[0] = not windowState.settingsWindow[0]
      if windowState.settingsWindow[0] then
         anim.settings = os.clock()
         UI.resetNums()
         syncImguiVars()
         updateTemplateCache()
      end
   end)

   sampRegisterChatCommand('newsredak', function()
      if cfg.settings.interceptCommand == false then
         sampSendChat('/newsredak')
         return
      end
      openNewsredakQueue()
   end)

   sampRegisterChatCommand('smipause', function()
      toggleQueuePause()
   end)

   chat(CHAT.OK .. "SMI Helper " .. CHAT.HI .. "v" .. SCRIPT_VERSION .. CHAT.OK .. " загружен", 'ARZ', true)
   chat(CHAT.MUTED .. "Настройки " .. CHAT.HI .. "/smi" .. CHAT.MUTED ..
      "     Очередь " .. CHAT.HI .. "/newsredak" .. CHAT.MUTED ..
      "     Пауза " .. CHAT.HI .. "/smipause", 'GEAR', true)
   showChangelog()

   while true do
      wait(0)
      if not isSampAvailable() then
         if windowState.mainWindow[0] then resetProcessingState() end
         stopQueueAutomation()
      end
      processPendingSendState()
      check_daily_reset()
      flushConfig()

      if Data.dirty then Data.save() end

      if hotkeyAssigning then
         if hotkeyDebounce then
            if not isKeyDown(vkeys.VK_LBUTTON) then
               hotkeyDebounce = false
            end
         else
            for i = 1, 255 do
               if wasKeyPressed(i) then
                  if vkeys.id_to_name(i) then
                     if i == vkeys.VK_ESCAPE then
                        cfg.hotkeys[hotkeyAssigning .. "_key"] = 0
                        hotkeyAssigning = nil
                        lastAssignTime = os.clock()
                        saveConfig(true)
                     else
                        local busy = hotkeyConflict(hotkeyAssigning, i)
                        if busy then
                           chat(CHAT.WARN .. "Клавиша уже занята: " .. CHAT.HI ..
                              (HOTKEY_NAMES[busy] or busy))
                           Toast.push('warn', 'Клавиша занята', HOTKEY_NAMES[busy] or busy, 3.0)
                           hotkeyAssigning = nil
                           lastAssignTime = os.clock()
                        else
                           cfg.hotkeys[hotkeyAssigning .. "_key"] = i
                           hotkeyAssigning = nil
                           lastAssignTime = os.clock()
                           saveConfig(true)
                        end
                     end
                     break
                  end
               end
            end
         end
      else
         if not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive() then

            if cfg.hotkeys.scriptActive_key and cfg.hotkeys.scriptActive_key ~= 0
               and wasKeyPressed(cfg.hotkeys.scriptActive_key) then
               state.active = not state.active
               imguiVars.active[0] = state.active
               syncStateFromImgui()
               chat(state.active and (CHAT.OK .. "Скрипт включён") or (CHAT.MUTED .. "Скрипт выключен"),
                  state.active and 'PLAY' or 'PAUSE')
            end

            if cfg.hotkeys.autoCatch_key and cfg.hotkeys.autoCatch_key ~= 0
               and wasKeyPressed(cfg.hotkeys.autoCatch_key) then
               state.autoCatchByCommand = not state.autoCatchByCommand
               imguiVars.autoCatchByCommand[0] = state.autoCatchByCommand
               syncStateFromImgui()
               chat(state.autoCatchByCommand and (CHAT.OK .. "Авто-ловля включена")
                  or (CHAT.MUTED .. "Авто-ловля выключена"),
                  state.autoCatchByCommand and 'BOT' or 'PAUSE')
            end

            if cfg.hotkeys.cmdNewsredak_key and cfg.hotkeys.cmdNewsredak_key ~= 0
               and wasKeyPressed(cfg.hotkeys.cmdNewsredak_key) then
               openNewsredakQueue(true)
            end

            if cfg.hotkeys.queuePause_key and cfg.hotkeys.queuePause_key ~= 0
               and wasKeyPressed(cfg.hotkeys.queuePause_key) then
               toggleQueuePause()
            end
         end

         if windowState.mainWindow[0] and windowState.currentView == "editor" then
            if cfg.hotkeys.autoFix_key and cfg.hotkeys.autoFix_key ~= 0
               and wasKeyPressed(cfg.hotkeys.autoFix_key) then
               applyAutoFix(true)
            end
            if cfg.hotkeys.skipAd_key and cfg.hotkeys.skipAd_key ~= 0
               and wasKeyPressed(cfg.hotkeys.skipAd_key) then
               skipCurrentAd()
            end
            if isKeyDown(vkeys.VK_CONTROL) and wasKeyPressed(vkeys.VK_BACK) then
               removeLastEditorWord()
            end
         end
      end
   end
end

addEventHandler('onWindowMessage', function(msg, wparam, lparam)
   if msg == wm.WM_KEYDOWN or msg == wm.WM_KEYUP then
      if wparam == vkeys.VK_ESCAPE then
         if hotkeyAssigning or (os.clock() - lastAssignTime < 0.15) then
            consumeWindowMessage(true, false)
            return
         end

         if windowState.settingsWindow[0] then
            if msg == wm.WM_KEYDOWN then consumeWindowMessage(true, false) end
            if msg == wm.WM_KEYUP then windowState.settingsWindow[0] = false end
            return
         end

         if windowState.mainWindow[0] then
            if msg == wm.WM_KEYDOWN then consumeWindowMessage(true, false) end
            if msg == wm.WM_KEYUP then
               closeActiveView()
            end
         end
      end
   end
end)

function onScriptTerminate(scr, quitGame)
   if scr == thisScript() then
      if notificationAudio then
         releaseAudioStream(notificationAudio)
         notificationAudio = nil
      end
      if cbTextEdit then
         cbTextEdit:free()
         cbTextEdit = nil
      end
      if emoji and UI.emojiReady then pcall(emoji.unload) end
      saveConfig(true)
      pcall(saveTemplates)
      pcall(save_blacklist)
      pcall(saveSenderIndex)
      pcall(Data.save)
   end
end
