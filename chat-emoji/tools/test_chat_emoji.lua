-- test_chat_emoji.lua — проверка логики chat_emoji.lua без игры.
-- Подменяет mimgui и API MoonLoader, поэтому запускается где угодно:
--
--     cd chat-emoji && luajit tools/test_chat_emoji.lua

package.path = 'moonloader/lib/?.lua;' .. package.path

-- минимальная заглушка mimgui: модулю на этом этапе нужен только ImVec2
local fakeImgui = {
    ImVec2 = function(x, y) return { x = x, y = y } end,
}
fakeImgui.new = setmetatable({}, {
    __index = function() return setmetatable({}, {
        __index = function() return function() return {} end end,
        __call = function() return {} end,
    }) end,
})
package.loaded['mimgui'] = fakeImgui

_G.getWorkingDirectory = function() return 'moonloader' end
_G.getD3DDevicePtr = function() return 0 end
_G.u8 = function(s) return s end

local emoji = require 'chat_emoji'

local failed = 0
local function check(cond, msg)
    if cond then return end
    failed = failed + 1
    io.write('  ПРОВАЛ: ', msg, '\n')
end

-- --------------------------------------------------------------------------
-- заглушка mimgui почти пустая, поэтому load() обязан внятно сообщить,
-- каких функций ImGui не хватает, а не падать посреди отрисовки
local okLoad, loadErr = emoji.load()
check(okLoad == false, 'load() на пустой заглушке mimgui должен вернуть false')
check(type(loadErr) == 'string' and loadErr:find('mimgui'),
      'load() должен объяснить, чего не хватает, получено: ' .. tostring(loadErr))
print('проверка API: ' .. tostring(loadErr))

-- --------------------------------------------------------------------------
local atlas = dofile('moonloader/resource/chat_emoji/chat_emoji_atlas.lua')
print(('атлас %dx%d, ячейка %d, колонок %d, записей %d')
    :format(atlas.width, atlas.height, atlas.cell, atlas.cols, #atlas.emoji))

check(#atlas.emoji == atlas.count, 'count не совпадает с длиной списка')
check(atlas.cols == math.floor(atlas.width / atlas.cell), 'cols посчитан неверно')
local rows = math.ceil(#atlas.emoji / atlas.cols)
check(rows * atlas.cell <= atlas.height,
      'атлас ниже, чем нужно: ' .. rows * atlas.cell .. ' > ' .. atlas.height)

-- строим таблицы тем же кодом, что и в игре
emoji.build(atlas)
emoji.texture = 'FAKE'

print('категорий:', #emoji.categories)
for _, c in ipairs(emoji.categories) do
    io.write(('  %-22s %d\n'):format(c.name, #c.items))
end

-- --------------------------------------------------------------------------
-- UV не выходят за текстуру и не пересекают соседние ячейки
for _, e in ipairs(emoji.list) do
    check(e.uv0.x >= 0 and e.uv1.x <= 1 and e.uv0.y >= 0 and e.uv1.y <= 1,
          'UV вне диапазона у ' .. e.name)
    check(e.uv1.x > e.uv0.x and e.uv1.y > e.uv0.y, 'вырожденный UV у ' .. e.name)
end

-- поиск по имени, коду и токену
local s = emoji.get('smiley')
check(s ~= nil and s.cp == 0x1F603, 'get по имени')
check(emoji.get(0x1F603) == s, 'get по кодовой точке')
check(emoji.get(':u1f603:') == s, 'get по токену')
check(emoji.encode('smiley') == ':u1f603:', 'encode -> ' .. emoji.encode('smiley'))
check(emoji.get('нет такого') == nil, 'get несуществующего')

-- серверные иконки Arizona должны были попасть в атлас из icons.ttf
for _, n in ipairs({ 'arz', 'redcode', 'buy', 'sell', 'cash', 'btc', 'yt', 'vc' }) do
    check(emoji.get(n) ~= nil, 'нет серверной иконки ' .. n)
end

-- синонимы из таблицы шорткатов тоже должны находиться
check(emoji.get(':)') ~= nil and emoji.get(':)').cp == 0x1F642, 'синоним :)')
check(emoji.get('<3') ~= nil and emoji.get('<3').cp == 0x2764, 'синоним <3')

-- порядок обязан совпадать с панелью чата: первые шесть — как в Arizona
local head = { 0x1F600, 0x1F601, 0x1F602, 0x1F923, 0x1F603, 0x1F604 }
for i, cp in ipairs(head) do
    check(emoji.list[i] and emoji.list[i].cp == cp,
          ('порядок: #%d ожидался U+%05X, получен %s')
              :format(i, cp, emoji.list[i] and ('U+%05X'):format(emoji.list[i].cp) or 'nil'))
end

-- смайлы, которых не было в старой выборке из таблицы имён
for _, cp in ipairs({ 0x1F60E, 0x1F494, 0x1F49B, 0x1F648, 0x1F649, 0x1F64A, 0x1FAC1 }) do
    check(emoji.get(cp) ~= nil, ('нет U+%05X'):format(cp))
end

-- --------------------------------------------------------------------------
-- разбор строки
local function render(str)
    local acc = {}
    for _, p in ipairs(emoji.parse(str)) do
        acc[#acc + 1] = p.emoji and ('<' .. p.emoji.name .. '>') or p.text
    end
    return table.concat(acc)
end

check(render('просто текст') == 'просто текст', 'текст без смайлов')
check(render(':u1f603:') == '<smiley>', 'строка из одного смайла')
check(render('a :u1f603: b') == 'a <smiley> b', 'смайл в середине')
check(render(':u1f603::u1fc08:') == '<smiley><arz>', 'два смайла подряд')
-- нераспознанный токен остаётся текстом и не съедает то, что было до него
check(render('a :u9ffffff: b :u1f603: c') == 'a :u9ffffff: b <smiley> c',
      'потерян текст перед нераспознанным токеном')
check(render('двоеточия :: и :u: без кода') == 'двоеточия :: и :u: без кода',
      'ложные срабатывания на двоеточиях')

print(#emoji.list .. ' смайлов, ' .. (failed == 0 and 'ВСЁ ОК' or failed .. ' ОШИБОК'))
os.exit(failed == 0 and 0 or 1)
