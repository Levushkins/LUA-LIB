-- Магазин на HTML -- пример «как на скриншотах с серверов», но без CEF.
--
-- Установка:
--   moonloader/lib/moonhtml/*     <- библиотека
--   moonloader/shop.lua           <- этот файл
--   moonloader/shop/index.html    <- разметка
--   moonloader/shop/style.css     <- стили
--   moonloader/shop/art/*.png     <- картинки (свои)
--
-- Открыть/закрыть: N

script_name('moonhtml shop')
script_author('moonhtml')

local moonhtml = require 'moonhtml'
local vkeys = require 'vkeys'

local sep = package.config:sub(1, 1)
local baseDir = (thisScript().path:match('^(.*[/\\])') or '') .. 'shop' .. sep

local shop = moonhtml.new {
  file = baseDir .. 'index.html',
  title = 'moonhtml shop',
  size = { 1280, 720 },
  key = vkeys.VK_N,
  lockPlayer = true,

  -- Картинки. mimgui умеет грузить PNG сам; если в вашей сборке такой
  -- функции нет -- подставьте сюда свой загрузчик текстур.
  loadTexture = function(src)
    local imgui = require 'mimgui'
    if imgui.CreateTextureFromFile then
      return imgui.CreateTextureFromFile(baseDir .. src)
    end
  end,
}

-- баланс, который подставляется в {{ state.rub }} и {{ state.az }}
shop.doc.state.rub = 254
shop.doc.state.az = '9 437'

-- ---------------------------------------------------------------------------
-- Категории слева: обычный класс .active, никакой логики отрисовки
-- ---------------------------------------------------------------------------

shop:on('.cat', 'click', function(event, node)
  for _, item in ipairs(shop:querySelectorAll('.cat')) do
    item:removeClass('active')
  end
  node:addClass('active')

  local tab = node:getAttribute('data-tab')
  loadCategory(tab)
end)

--- Карточки строятся из данных: разметка генерируется строкой.
function loadCategory(tab)
  local items = {
    cars = {
      { title = 'INFERNUS', note = 'скорость 240 км/ч', price = '2 500 РУБ', art = 'art/case.png' },
      { title = 'SULTAN', note = 'тюнингованный', price = '900 РУБ', art = 'art/money.png' },
      { title = 'BULLET', note = 'редкий', price = '4 000 РУБ', art = 'art/coins.png' },
    },
    boxes = {
      { title = 'КЕЙС «СТАРТ»', note = '5 предметов', price = '199 РУБ', art = 'art/case.png' },
      { title = 'КЕЙС «ЗОЛОТО»', note = '10 предметов', price = '799 РУБ', art = 'art/coins.png' },
    },
  }

  local list = items[tab]
  if not list then return end

  local html = {}
  for _, item in ipairs(list) do
    html[#html + 1] = string.format([[
      <div class="card">
        <img class="art" src="%s">
        <div class="card-title"><b>%s</b></div>
        <div class="card-note">%s</div>
        <div class="buy gold" data-buy="%s">
          <span class="badge-rub">P</span> %s
        </div>
      </div>]], item.art, item.title, item.note, item.title, item.price)
  end

  shop:getElementById('rail'):setHTML(table.concat(html))
end

-- ---------------------------------------------------------------------------
-- Покупка
-- ---------------------------------------------------------------------------

shop:on('[data-buy]', 'click', function(event, node)
  local id = node:getAttribute('data-buy')
  if sampAddChatMessage then
    sampAddChatMessage('[shop] покупка: ' .. id, 0x4A9EFF)
  end
  -- здесь ваш RPC / диалог сервера
end)

shop:on('#add-rub', 'click', function()
  shop.doc.state.rub = (tonumber(shop.doc.state.rub) or 0) + 100
end)

shop:on('.pass', 'click', function()
  if sampAddChatMessage then sampAddChatMessage('[shop] BattlePass', 0x8B5CF6) end
end)

-- поиск фильтрует карточки прямо по DOM
shop:on('#q', 'input', function(event, node)
  local query = tostring(node:getValue() or ''):lower()
  for _, card in ipairs(shop:querySelectorAll('.card')) do
    local title = card:getText():lower()
    if query == '' or title:find(query, 1, true) then
      card:show()
    else
      card:hide()
    end
  end
end)

function main()
  while not isSampAvailable() do wait(100) end
  sampAddChatMessage('[moonhtml] магазин загружен, открыть: N', 0x4A9EFF)
  wait(-1)
end
