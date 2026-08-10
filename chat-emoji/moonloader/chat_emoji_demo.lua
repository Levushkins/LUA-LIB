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

script_name('Chat Emoji Demo')
script_author('extracted from _chat.asi')

local ffi = require 'ffi'
local imgui = require 'mimgui'
local emoji = require 'chat_emoji'

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

        if imgui.Begin(u8'Смайлы чата', window) then
            if loadError then
                imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), u8(loadError))
                imgui.TextWrapped(u8'Проверьте, что в moonloader/resource/chat_emoji/ '
                    .. u8'лежат chat_emoji.png и chat_emoji_atlas.lua.')
                imgui.End()
                return
            end

            imgui.Text(u8('Всего смайлов: ' .. #emoji.list))
            imgui.SameLine()
            imgui.PushItemWidth(120)
            imgui.SliderInt(u8'размер', iconSize, 16, 64)
            imgui.PopItemWidth()

            imgui.Separator()

            -- строка сообщения и предпросмотр с подставленными смайлами
            imgui.PushItemWidth(-1)
            imgui.InputTextWithHint('##msg', u8'Текст сообщения...',
                                    message, ffi.sizeof(message))
            imgui.PopItemWidth()

            local text = ffi.string(message)
            if #text > 0 then
                imgui.TextDisabled(u8'Предпросмотр:')
                emoji.text(u8(text), imgui.GetFontSize())
            end

            if imgui.Button(u8'Отправить в чат') and #text > 0 then
                sampSendChat(text)
                message[0] = 0
            end
            imgui.SameLine()
            if imgui.Button(u8'Очистить') then message[0] = 0 end

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
