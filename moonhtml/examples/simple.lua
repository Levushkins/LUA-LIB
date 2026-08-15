-- Минимальный пример moonhtml: всё меню -- одна строка HTML внутри скрипта.
-- Открыть/закрыть: клавиша X.

script_name('moonhtml simple')

local moonhtml = require 'moonhtml'
local vkeys = require 'vkeys'

local menu = moonhtml.new {
  key = vkeys.VK_X,
  size = { 380, 260 },
  html = [[
    <style>
      body { font-size: 14px; }
      .card {
        padding: 14px;
        background-color: #1d2026;
        border: 1px solid #2e323b;
        border-radius: 10px;
        height: 100%;
        box-sizing: border-box;
      }
      h3 { margin: 0 0 10px 0; font-size: 16px; color: #8ab4f8; }
      .row { display: flex; align-items: center; margin-bottom: 8px; }
      .row span { margin-right: auto; }
      button {
        width: 100%;
        padding: 9px;
        border-radius: 8px;
        background-color: #5b8cff;
        color: #fff;
        font-weight: bold;
        transition: background-color 0.15s;
      }
      button:hover { background-color: #7aa2ff; }
      .value { color: #8ab4f8; font-weight: bold; }
    </style>

    <div class="card">
      <h3>Пример меню</h3>

      <div class="row">
        <span>Бесконечное здоровье</span>
        <input type="checkbox" id="godmode">
      </div>

      <div class="row">
        <span>Скорость</span>
        <span class="value">{{ state.speed }}</span>
      </div>
      <input type="range" id="speed" min="1" max="10" value="5" style="width: 100%">

      <button id="tp">Телепорт на маркер</button>
    </div>
  ]],
}

menu.doc.state.speed = 5

menu:on('#godmode', 'change', function(event, node)
  if sampAddChatMessage then
    sampAddChatMessage('godmode: ' .. tostring(node:isChecked()), -1)
  end
end)

menu:on('#speed', 'input', function(event, node)
  menu.doc.state.speed = math.floor(tonumber(node:getValue()) or 0)
end)

menu:on('#tp', 'click', function()
  local x, y, z = getTargetBlipCoordinates()
  if x then
    setCharCoordinates(PLAYER_PED, x, y, z + 1)
  end
end)

function main()
  wait(-1)
end
