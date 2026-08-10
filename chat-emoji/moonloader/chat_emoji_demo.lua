-- chat_emoji_demo.lua — пример работы со смайлами из _chat.asi в mimgui.
--
-- Команда /emj открывает панель: сетка смайлов с поиском, предпросмотр
-- сообщения и отправка в чат.
--
-- Установка:
--   moonloader/chat_emoji_demo.lua
--   moonloader/lib/chat_emoji.lua
--   moonloader/resource/chat_emoji/chat_emoji.png
--   moonloader/resource/chat_emoji/chat_emoji_atlas.lua
--
-- ВАЖНО про кодировку: этот файл сохранён в UTF-8, а ImGui как раз ждёт
-- UTF-8, поэтому русские строки передаются в него как есть, без u8().
-- Оборачивать в u8() надо наоборот — файлы в cp1251. А вот SA-MP работает
-- в cp1251, поэтому текст для sampSendChat / sampAddChatMessage переводим
-- обратно через u8:decode().

script_name('Chat Emoji Demo')
script_author('extracted from _chat.asi')

local ffi = require 'ffi'
local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local window = imgui.new.bool(false)
local message = imgui.new.char[144]()
local iconSize = imgui.new.int(24)
local loadError = nil

function main()
    while not isSampAvailable() do wait(0) end

    sampRegisterChatCommand('emj', function()
        window[0] = not window[0]
    end)

    sampAddChatMessage('Chat Emoji: /emj - panel of emojis', 0x8ACC47)
    wait(-1)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil

    local ok, err = emoji.load()
    if not ok then
        loadError = err
        sampAddChatMessage('Chat Emoji: ' .. tostring(err), 0xFF4444)
    end
end)

imgui.OnFrame(
    function() return window[0] end,
    function(self)
        self.HideCursor = false

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2),
                               imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(560, 520), imgui.Cond.FirstUseEver)

        if imgui.Begin('Chat emoji', window) then
            if loadError then
                imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), tostring(loadError))
                imgui.TextWrapped('Check that moonloader/resource/chat_emoji/ contains '
                    .. 'chat_emoji.png and chat_emoji_atlas.lua.')
                imgui.End()
                return
            end

            imgui.Text('Total: ' .. #emoji.list)
            imgui.SameLine()
            imgui.PushItemWidth(120)
            imgui.SliderInt('size', iconSize, 16, 64)
            imgui.PopItemWidth()

            imgui.Separator()

            -- строка сообщения и предпросмотр с подставленными смайлами.
            -- InputText отдаёт UTF-8, поэтому в emoji.text идёт как есть.
            imgui.PushItemWidth(-1)
            imgui.InputTextWithHint('##msg', 'Message text...',
                                    message, ffi.sizeof(message))
            imgui.PopItemWidth()

            local text = ffi.string(message)
            if #text > 0 then
                imgui.TextDisabled('Preview:')
                emoji.text(text, imgui.GetFontSize())
            end

            if imgui.Button('Send to chat') and #text > 0 then
                sampSendChat(u8:decode(text))   -- UTF-8 -> cp1251 для SA-MP
                message[0] = 0
            end
            imgui.SameLine()
            if imgui.Button('Clear') then message[0] = 0 end

            imgui.Separator()

            -- сетка выбора; клик дописывает токен :uXXXX: в конец строки
            local picked = emoji.picker('grid', iconSize[0], 300)
            if picked then
                local cur = ffi.string(message)
                local add = picked.token
                if #cur + #add < ffi.sizeof(message) then
                    ffi.copy(message, cur .. add)
                end
            end
        end
        imgui.End()
    end
)

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() and not quitGame then
        emoji.unload()
    end
end
