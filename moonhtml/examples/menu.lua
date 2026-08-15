-- moonhtml demo -- полноценное меню, написанное на HTML + CSS.
--
-- Установка:
--   moonloader/lib/moonhtml/*        <- библиотека
--   moonloader/menu.lua              <- этот файл
--   moonloader/menu/index.html       <- разметка
--   moonloader/menu/style.css        <- стили
--
-- Открыть/закрыть: Alt+X

script_name('moonhtml demo')
script_author('moonhtml')

local moonhtml = require 'moonhtml'
local vkeys = require 'vkeys'

-- каталог, рядом с которым лежат index.html и style.css
local baseDir = (thisScript().path:match('^(.*[/\\])') or '') .. 'menu' ..
    (package.config:sub(1, 1) == '\\' and '\\' or '/')

-- ---------------------------------------------------------------------------
-- Состояние скрипта. Всё, что попадает в menu.doc.state, доступно в разметке
-- через {{ state.имя }} и обновляется на экране автоматически.
-- ---------------------------------------------------------------------------

local settings = {
  autoHeal = true,
  fastEnter = false,
  radius = 18,
  delay = 250,
}

local menu = moonhtml.new {
  file = baseDir .. 'index.html',
  title = 'moonhtml demo',
  size = { 720, 520 },
  key = vkeys.VK_X,   -- Alt не обязателен, достаточно X
  -- env -- то, что видно из onclick="..." и <script> внутри разметки
  env = {
    chat = function(text)
      if sampAddChatMessage then sampAddChatMessage(text, 0x7AA2FF) end
    end,
  },
}

-- ---------------------------------------------------------------------------
-- Обработчики. Селекторы такие же, как в CSS.
-- ---------------------------------------------------------------------------

menu:on('#auto-heal', 'change', function(event, node)
  settings.autoHeal = node:isChecked()
  print('автолечение: ' .. tostring(settings.autoHeal))
end)

menu:on('#fast-enter', 'change', function(event, node)
  settings.fastEnter = node:isChecked()
end)

menu:on('#radius', 'input', function(event, node)
  settings.radius = tonumber(node:getValue()) or 0
  menu.doc.state.radius = math.floor(settings.radius)
end)

menu:on('#delay', 'input', function(event, node)
  settings.delay = tonumber(node:getValue()) or 0
  menu.doc.state.delay = math.floor(settings.delay)
end)

menu:on('.nav-item', 'click', function(event, node)
  for _, item in ipairs(menu:querySelectorAll('.nav-item')) do
    item:removeClass('active')
  end
  node:addClass('active')
end)

menu:on('#send', 'click', function()
  local field = menu:getElementById('cmd')
  local text = field:getValue()
  if text ~= '' and sampAddChatMessage then
    if text:sub(1, 1) == '/' then
      sampSendChat(text)
    else
      sampSendChat(text)
    end
    field:setValue('')
  end
end)

menu:on('.btn', 'click', function(event, node)
  local label = node:getText()
  if sampAddChatMessage then
    sampAddChatMessage('[moonhtml] ' .. label, 0x7AA2FF)
  end
end)

-- ---------------------------------------------------------------------------

function main()
  while not isSampAvailable() do wait(100) end

  local nick = sampGetPlayerNickname and sampGetPlayerNickname(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED))) or 'player'
  menu.doc.state.nick = nick
  menu.doc.state.id = select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)) or 0
  menu.doc.state.radius = settings.radius
  menu.doc.state.delay = settings.delay

  sampAddChatMessage('[moonhtml] загружено, открыть меню: X', 0x7AA2FF)

  while true do
    wait(250)

    -- state -> разметка: значения сами подставятся в {{ }}
    local state = menu.doc.state
    state.fps = math.floor(1000 / math.max(1, (os.clock() * 1000) % 33 + 16))
    state.ping = sampGetPlayerPing and sampGetPlayerPing(state.id) or 0
    state.hp = math.floor(getCharHealth(PLAYER_PED))
    state.armour = math.floor(getCharArmour(PLAYER_PED))

    -- ширина полосок задаётся обычным CSS
    local hp = menu:querySelector('.fill.hp')
    if hp then hp.style.width = state.hp .. '%' end
    local armour = menu:querySelector('.fill.armour')
    if armour then armour.style.width = state.armour .. '%' end

    if settings.autoHeal and getCharHealth(PLAYER_PED) < 20 then
      -- здесь была бы ваша логика
    end
  end
end
