-- chat_asi_switch.lua
--
-- Включение/выключение _chat.asi (ImGui-чат Arizona) без удаления файла.
-- Работает так же, как хук анти-афк статуса в vorbisFile.dll: находим в модуле
-- функцию-точку и подменяем её первый байт на ret, а для возврата пишем
-- сохранённые оригинальные байты обратно.
--
-- RVA сняты со сборки _chat.asi с PE TimeDateStamp 0x6A7A4372 (pdb: C:\dev\imgui-chat).
-- После обновления лаунчера смещения нужно снимать заново — скрипт это проверяет
-- по TimeDateStamp и по сигнатуре первых байт и не патчит, если не совпало.

script_name('chat_asi_switch')
script_description('Вкл/выкл окна чата и ников _chat.asi без удаления файла')
script_version('1.0.0')

local ffi      = require 'ffi'
local memory   = require 'memory'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local MODULE = '_chat.asi'
local BUILD  = 0x6A7A4372

local base = 0

-- Все четыре функции ничего не возвращают, поэтому глушатся корректным ret.
local patches = {
  chat = {
    title = 'окно чата + поле ввода',
    rva   = 0x11B20,        -- рисует ImGui-окна "###chat" и "###input"
    sig   = '\x55\x8B\xEC\x83\xEC\x3C',
    stub  = '\xC3',         -- void __cdecl f(void)
  },
  nick = {
    title = 'ники над игроками',
    rva   = 0x35760,        -- проход по пулу неймтегов: ник, хп, иконки
    sig   = '\x55\x8B\xEC\x6A\xFF\x68',
    stub  = '\xC3',         -- void __thiscall f(void)
  },
  cfg = {
    title = 'окно настроек чата',
    rva   = 0x12710,        -- ImGui-окно "###CCFG"
    sig   = '\x55\x8B\xEC\x83\xEC\x0C',
    stub  = '\xC3',
  },
  feed = {
    title = 'приём сообщений в буфер',
    rva   = 0x463E0,        -- детур CChat::AddEntry (samp.dll + 0x666A0)
    sig   = '\x55\x8B\xEC\x6A\xFF\x68',
    stub  = '\xC2\x14\x00', -- ret 0x14 — 5 аргументов чистит вызываемая сторона
  },
}

local order = {'chat', 'nick', 'cfg', 'feed'}

local setCustomNameTag, isCustomNameTag

local function msg(text)
  print(text)
  if isSampAvailable() then
    -- при выключенном окне чата это увидит только консоль (F8 / moonloader.log)
    sampAddChatMessage('{8ABEFF}[chat.asi]{FFFFFF} ' .. u8:decode(text), -1)
  end
end

local function readBytes(addr, len)
  local t = {}
  for i = 1, len do t[i] = memory.getuint8(addr + i - 1, true) end
  return t
end

local function writeBytes(addr, bytes)
  for i = 1, #bytes do memory.setuint8(addr + i - 1, bytes[i], true) end
end

local function sigOk(p)
  for i = 1, #p.sig do
    if memory.getuint8(p.addr + i - 1, true) ~= p.sig:byte(i) then return false end
  end
  return true
end

local function moduleStamp(b)
  local lfanew = memory.getint32(b + 0x3C, true)
  return memory.getuint32(b + lfanew + 8, true)
end

local function setPatch(key, off)
  local p = patches[key]
  if not p or not p.ready then return false end
  if off == p.off then return true end
  if off then
    local stub = {}
    for i = 1, #p.stub do stub[i] = p.stub:byte(i) end
    writeBytes(p.addr, stub)
  else
    writeBytes(p.addr, p.orig)
  end
  p.off = off
  return true
end

local function restoreAll()
  for _, key in ipairs(order) do setPatch(key, false) end
end

local function status()
  msg('состояние:')
  for _, key in ipairs(order) do
    local p = patches[key]
    if p.ready then
      msg(('  %-6s %-26s %s'):format(key, p.title, p.off and 'ВЫКЛ' or 'вкл'))
    else
      msg(('  %-6s %-26s недоступно (сигнатура не совпала)'):format(key, p.title))
    end
  end
  if isCustomNameTag then
    msg('  style  стиль ников                ' .. (isCustomNameTag() and 'кастомный' or 'классический'))
  end
end

function main()
  while not isSampAvailable() do wait(0) end

  base = getModuleHandle(MODULE)
  if base == 0 then
    msg(MODULE .. ' не загружен, скрипт выгружается')
    thisScript():unload()
    return
  end

  local stamp = moduleStamp(base)
  if stamp ~= BUILD then
    msg(('внимание: сборка %s другая (0x%08X вместо 0x%08X), проверяю сигнатуры')
      :format(MODULE, stamp, BUILD))
  end

  for _, key in ipairs(order) do
    local p = patches[key]
    p.addr  = base + p.rva
    p.ready = sigOk(p)
    p.off   = false
    if p.ready then
      p.orig = readBytes(p.addr, #p.stub)
    else
      msg(('точка "%s" (rva 0x%05X) не опознана — пропущена'):format(p.title, p.rva))
    end
  end

  -- штатный API самого мода: переключение стиля ников (кастомный <-> классический)
  local pSet = getModuleProcAddress(MODULE, 'SetCustomNameTagState')
  local pIs  = getModuleProcAddress(MODULE, 'IsCustomNameTagEnabled')
  if pSet ~= 0 and pIs ~= 0 then
    setCustomNameTag = ffi.cast('void (__cdecl*)(bool)', pSet)
    isCustomNameTag  = ffi.cast('bool (__cdecl*)()', pIs)
  end

  sampRegisterChatCommand('casw', function(arg)
    arg = (arg or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')

    if arg == '' or arg == 'help' then
      msg('/casw chat | nick | cfg | feed | style | all | on | status')
      return
    end

    if arg == 'status' then status() return end

    if arg == 'all' then
      local off = not patches.chat.off
      for _, key in ipairs(order) do
        if key ~= 'feed' then setPatch(key, off) end
      end
      msg('чат и ники: ' .. (off and 'ВЫКЛ' or 'вкл'))
      return
    end

    if arg == 'on' then
      restoreAll()
      msg('все патчи сняты, мод работает как обычно')
      return
    end

    if arg == 'style' then
      if not setCustomNameTag then msg('экспорты мода не найдены') return end
      local new = not isCustomNameTag()
      setCustomNameTag(new)
      msg('стиль ников: ' .. (new and 'кастомный' or 'классический'))
      return
    end

    local p = patches[arg]
    if not p then msg('неизвестный аргумент: ' .. arg) return end
    if not p.ready then msg('точка "' .. p.title .. '" недоступна') return end
    setPatch(arg, not p.off)
    msg(p.title .. ': ' .. (p.off and 'ВЫКЛ' or 'вкл'))
  end)

  msg('готов, /casw help')
  wait(-1)
end

function onScriptTerminate(s, quitGame)
  if s == thisScript() and not quitGame then
    restoreAll()
  end
end
