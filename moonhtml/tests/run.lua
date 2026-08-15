-- moonhtml test suite -- run with:  lua5.1 tests/run.lua   (from moonhtml/)
package.path = 'lib/?.lua;lib/?/init.lua;tests/?.lua;' .. package.path

local moonhtml = require 'moonhtml'
local util = require 'moonhtml.util'

local metrics = require 'metrics_dejavu'

-- ------------------------------------------------------------ harness ----

local passed, failed, current = 0, 0, nil
local failures = {}

local function test(name, fn)
  current = name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write('.')
  else
    failed = failed + 1
    failures[#failures + 1] = name .. '\n    ' .. tostring(err)
    io.write('F')
  end
  io.flush()
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format('%s: expected %s, got %s',
      msg or 'value', tostring(expected), tostring(actual)), 2)
  end
end

local function near(actual, expected, tol, msg)
  tol = tol or 0.75
  if type(actual) ~= 'number' or math.abs(actual - expected) > tol then
    error(string.format('%s: expected ~%s (+-%s), got %s',
      msg or 'value', tostring(expected), tostring(tol), tostring(actual)), 2)
  end
end

local function truthy(v, msg)
  if not v then error((msg or 'expected truthy') .. ', got ' .. tostring(v), 2) end
end

local function doc(html, css, opts)
  opts = opts or {}
  return moonhtml.headless {
    html = html, css = css, metrics = metrics,
    width = opts.width or 400, height = opts.height or 300,
    env = opts.env,
  }
end

local NO_INPUT = { x = -1000, y = -1000, down = false, pressed = false,
  released = false, wheel = 0, chars = {}, keys = {}, inside = true }

local function frame(d, input, now)
  local i = {}
  for k, v in pairs(NO_INPUT) do i[k] = v end
  for k, v in pairs(input or {}) do i[k] = v end
  d:update(i, now or 0)
  return d
end

-- ------------------------------------------------------------- parsing ----

test('parses elements, attributes and nesting', function()
  local root = moonhtml.parse(
    '<div id="a" class="x y"><span>hi</span><br/><input type="text" disabled></div>')
  local div = root.children[1]
  eq(div.tag, 'div')
  eq(div.id, 'a')
  eq(#div.classes, 2)
  truthy(div.classSet.y)
  eq(#div.children, 3)
  eq(div.children[1].tag, 'span')
  eq(div.children[1]:getText(), 'hi')
  eq(div.children[2].tag, 'br')
  eq(div.children[3]:getAttribute('type'), 'text')
  truthy(div.children[3].state.disabled)
end)

test('handles comments, doctype, entities and unclosed tags', function()
  local root = moonhtml.parse(
    '<!DOCTYPE html><!-- note --><p>a &amp; b &lt;c&gt; &#65;<p>second')
  local ps = root:getElementsByTagName('p')
  eq(#ps, 2)
  eq(ps[1]:getText(), 'a & b <c> A')
  eq(ps[2]:getText(), 'second')
end)

test('keeps <script> and <style> bodies verbatim', function()
  local root = moonhtml.parse('<style>a > b { color: red }</style><script>x = 1 < 2</script>')
  eq(root:querySelector('style'):getText(), 'a > b { color: red }')
  eq(root:querySelector('script'):getText(), 'x = 1 < 2')
end)

test('auto-closes list items and options', function()
  local root = moonhtml.parse('<ul><li>one<li>two<li>three</ul>')
  eq(#root:querySelector('ul'):elementChildren(), 3)
end)

-- ---------------------------------------------------------------- css ----

test('parses declarations and expands shorthands', function()
  local css = require 'moonhtml.css'
  local d = css.parseDeclarations('margin: 4px 8px; border: 2px solid #f00; flex: 1')
  eq(d['margin-top'], '4px')
  eq(d['margin-right'], '8px')
  eq(d['margin-bottom'], '4px')
  eq(d['margin-left'], '8px')
  eq(d['border-top-width'], '2px')
  eq(d['border-left-color'], '#f00')
  eq(d['border-right-style'], 'solid')
  eq(d['flex-grow'], '1')
  eq(d['flex-basis'], '0')
end)

test('selector matching: descendant, child, class, id, attribute, nth', function()
  local css = require 'moonhtml.css'
  local root = moonhtml.parse(
    '<div id="root"><ul><li class="a">1</li><li class="a b">2</li></ul></div>')
  local second = root:querySelectorAll('li')[2]
  local function match(sel)
    return css.matches(css.parseSelectorList(sel)[1], second)
  end
  truthy(match('li'))
  truthy(match('.a.b'))
  truthy(match('#root li'))
  truthy(match('ul > li'))
  truthy(match('li:nth-child(2)'))
  truthy(match('li:last-child'))
  truthy(match('.a + .a'))
  truthy(not match('li:first-child'))
  truthy(not match('#nope li'))
  truthy(match('li:not(:first-child)'))
end)

test('specificity decides the winner', function()
  local d = doc('<body><p id="t" class="c">x</p></body>', [[
    p { color: #ff0000 }
    .c { color: #00ff00 }
    #t { color: #0000ff }
  ]])
  frame(d)
  local p = d:querySelector('p')
  eq(math.floor(p.computed.color[3]), 255, 'blue wins')
end)

test('!important beats specificity, inline beats both', function()
  local d = doc('<body><p id="t" style="color: #00ff00">x</p></body>', [[
    p { color: #ff0000 !important }
    #t { color: #0000ff }
  ]])
  frame(d)
  eq(math.floor(d:querySelector('p').computed.color[1]), 255, 'important red wins')
end)

test('css variables resolve through inheritance', function()
  local d = doc('<body><div class="box"><span>x</span></div></body>', [[
    body { --accent: #12ab34; --pad: 7px }
    .box { padding: var(--pad); background-color: var(--accent) }
    span { color: var(--missing, #ffffff) }
  ]])
  frame(d)
  local box = d:querySelector('.box')
  eq(math.floor(box.computed.backgroundColor[2]), 171)
  eq(box.computed.padding[1].n, 7)
  eq(math.floor(d:querySelector('span').computed.color[1]), 255)
end)

test('media queries follow the viewport', function()
  local d = doc('<body><p>x</p></body>', [[
    p { color: #ff0000 }
    @media (max-width: 300px) { p { color: #00ff00 } }
  ]], { width = 400 })
  frame(d)
  eq(math.floor(d:querySelector('p').computed.color[1]), 255)
  d:setViewport(280, 300)
  frame(d)
  eq(math.floor(d:querySelector('p').computed.color[2]), 255)
end)

-- ------------------------------------------------------------- layout ----

test('block boxes stack and fill the width', function()
  local d = doc([[<body><div id="a"></div><div id="b"></div></body>]], [[
    body { padding: 10px }
    div { height: 20px; margin-bottom: 5px }
  ]], { width = 200 })
  frame(d)
  local a, b = d:getElementById('a').box, d:getElementById('b').box
  eq(a.w, 180)
  eq(a.ax, 10)
  eq(a.ay, 10)
  eq(b.ay, 35)
end)

test('border-box is the default sizing model', function()
  local d = doc('<body><div id="a"></div></body>', [[
    #a { width: 100px; height: 40px; padding: 10px; border: 2px solid red }
  ]])
  frame(d)
  local box = d:getElementById('a').box
  eq(box.w, 100)
  eq(box.h, 40)
  eq(box.contentW, 76)
end)

test('content-box sizing when asked for', function()
  local d = doc('<body><div id="a"></div></body>', [[
    #a { box-sizing: content-box; width: 100px; height: 40px; padding: 10px }
  ]])
  frame(d)
  eq(d:getElementById('a').box.w, 120)
end)

test('text wraps onto multiple lines', function()
  local d = doc('<body><p id="p">one two three four five six seven eight nine</p></body>', [[
    body { padding: 0 } p { margin: 0; width: 120px; font-size: 14px }
  ]])
  frame(d)
  local box = d:getElementById('p').box
  truthy(#box.lines > 2, 'expected wrapping, got ' .. #box.lines .. ' line(s)')
  for _, ln in ipairs(box.lines) do
    truthy(ln.w <= 120.5, 'line overflows: ' .. ln.w)
  end
  near(box.h, #box.lines * 14 * 1.35, 1)
end)

test('white-space: nowrap keeps one line', function()
  local d = doc('<body><p id="p" style="white-space: nowrap; width: 60px">' ..
    'one two three four</p></body>')
  frame(d)
  eq(#d:getElementById('p').box.lines, 1)
end)

test('inline elements share a line and inherit styles', function()
  local d = doc('<body><p id="p">a <b>bold</b> <span style="font-size:20px">big</span></p></body>',
    'body { padding: 0 } p { margin: 0 }')
  frame(d)
  local box = d:getElementById('p').box
  eq(#box.lines, 1)
  local line = box.lines[1]
  truthy(line.h >= 20, 'tallest inline drives line height: ' .. line.h)
end)

test('text-align centers and right-aligns', function()
  local d = doc('<body><p id="c">hi</p><p id="r">hi</p></body>', [[
    body { padding: 0 } p { margin: 0; width: 100px }
    #c { text-align: center } #r { text-align: right }
  ]])
  frame(d)
  local c = d:getElementById('c').box.lines[1]
  local r = d:getElementById('r').box.lines[1]
  near(c.x, (100 - c.w) / 2, 0.6)
  near(r.x, 100 - r.w, 0.6)
end)

test('flex row distributes free space with grow', function()
  local d = doc([[<body><div class="row">
      <div id="a"></div><div id="b"></div></div></body>]], [[
    body { padding: 0 }
    .row { display: flex; width: 300px; gap: 20px }
    #a { flex-grow: 1; height: 10px } #b { flex-grow: 2; height: 10px }
  ]])
  frame(d)
  local a, b = d:getElementById('a').box, d:getElementById('b').box
  near(a.w, (300 - 20) / 3, 0.5)
  near(b.w, (300 - 20) / 3 * 2, 0.5)
  near(b.ax, a.w + 20, 0.5)
end)

test('flex justify-content: space-between and center', function()
  local d = doc([[<body><div class="row"><i id="a"></i><i id="b"></i></div></body>]], [[
    body { padding: 0 }
    .row { display: flex; width: 200px; justify-content: space-between }
    i { display: block; width: 40px; height: 10px }
  ]])
  frame(d)
  eq(d:getElementById('a').box.ax, 0)
  eq(d:getElementById('b').box.ax, 160)
end)

test('flex column with align-items: center', function()
  local d = doc([[<body><div class="col"><i id="a"></i></div></body>]], [[
    body { padding: 0 }
    .col { display: flex; flex-direction: column; align-items: center; width: 200px }
    i { display: block; width: 40px; height: 10px }
  ]])
  frame(d)
  eq(d:getElementById('a').box.ax, 80)
end)

test('flex stretches items across the cross axis by default', function()
  local d = doc([[<body><div class="col"><i id="a"></i></div></body>]], [[
    body { padding: 0 }
    .col { display: flex; flex-direction: column; width: 200px }
    i { display: block; height: 10px }
  ]])
  frame(d)
  eq(d:getElementById('a').box.w, 200)
end)

test('grid lays out fr columns with gaps', function()
  local d = doc([[<body><div class="g">
    <i id="a"></i><i id="b"></i><i id="c"></i></div></body>]], [[
    body { padding: 0 }
    .g { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; width: 210px }
    i { display: block; height: 12px }
  ]])
  frame(d)
  local a, b, c = d:getElementById('a').box, d:getElementById('b').box,
      d:getElementById('c').box
  eq(a.w, 100)
  eq(b.ax, 110)
  eq(c.ay, 22) -- second row
end)

test('absolute positioning uses the nearest positioned ancestor', function()
  local d = doc([[<body><div class="host"><div id="a"></div></div></body>]], [[
    body { padding: 0 }
    .host { position: relative; margin: 20px; width: 100px; height: 100px }
    #a { position: absolute; right: 10px; bottom: 5px; width: 30px; height: 15px }
  ]])
  frame(d)
  local a = d:getElementById('a').box
  eq(a.ax, 20 + 100 - 10 - 30)
  eq(a.ay, 20 + 100 - 5 - 15)
end)

test('overflow: auto clamps scrolling and reports a scrollbar', function()
  local d = doc([[<body><div id="s"><div class="tall"></div></div></body>]], [[
    body { padding: 0 }
    #s { height: 50px; overflow-y: auto }
    .tall { height: 500px }
  ]])
  frame(d)
  local s = d:getElementById('s')
  truthy(s.box.scrollable)
  near(s.box.maxScrollY, 450, 1)
  frame(d, { x = 10, y = 10, wheel = -3 })
  truthy(s.state.scrollY > 0, 'wheel scrolled')
  for _ = 1, 40 do frame(d, { x = 10, y = 10, wheel = -3 }) end
  near(s.state.scrollY, s.box.maxScrollY, 0.5)
end)

test('percentage and calc widths resolve against the container', function()
  local d = doc('<body><div id="a"></div><div id="b"></div></body>', [[
    body { padding: 0; width: 400px }
    #a { width: 50%; height: 5px }
    #b { width: calc(100% - 40px); height: 5px }
  ]], { width = 400 })
  frame(d)
  eq(d:getElementById('a').box.w, 200)
  eq(d:getElementById('b').box.w, 360)
end)

test('em, rem and viewport units', function()
  local d = doc('<body><div id="a"><span id="b">x</span></div></body>', [[
    body { font-size: 16px }
    #a { font-size: 2em; width: 10rem; height: 10vh }
    #b { font-size: 0.5em }
  ]], { width = 400, height = 300 })
  frame(d)
  local a = d:getElementById('a')
  eq(a.computed.fontSize, 32)
  eq(a.box.w, 160)
  eq(a.box.h, 30)
  eq(d:getElementById('b').computed.fontSize, 16)
end)

-- ------------------------------------------------------------- events ----

test('click fires on the deepest element and bubbles', function()
  local d = doc('<body><div id="outer"><button id="btn">Go</button></div></body>', [[
    body { padding: 0 } #btn { width: 80px; height: 30px }
  ]])
  frame(d)
  local order = {}
  d:getElementById('btn'):on('click', function() order[#order + 1] = 'btn' end)
  d:getElementById('outer'):on('click', function() order[#order + 1] = 'outer' end)
  local box = d:getElementById('btn').box
  local cx, cy = box.ax + box.w / 2, box.ay + box.h / 2
  frame(d, { x = cx, y = cy, pressed = true, down = true })
  frame(d, { x = cx, y = cy, released = true })
  eq(#order, 2)
  eq(order[1], 'btn')
  eq(order[2], 'outer')
end)

test('stopPropagation halts bubbling', function()
  local d = doc('<body><div id="outer"><button id="btn">Go</button></div></body>',
    '#btn { width: 80px; height: 30px }')
  frame(d)
  local hits = 0
  d:getElementById('btn'):on('click', function(e) e:stopPropagation() end)
  d:getElementById('outer'):on('click', function() hits = hits + 1 end)
  local box = d:getElementById('btn').box
  frame(d, { x = box.ax + 5, y = box.ay + 5, pressed = true, down = true })
  frame(d, { x = box.ax + 5, y = box.ay + 5, released = true })
  eq(hits, 0)
end)

test(':hover applies while the pointer is over an element', function()
  local d = doc('<body><div id="a"></div></body>', [[
    body { padding: 0 }
    #a { width: 50px; height: 50px; background-color: #111111 }
    #a:hover { background-color: #ff0000 }
  ]])
  frame(d)
  eq(math.floor(d:getElementById('a').computed.backgroundColor[1]), 17)
  frame(d, { x = 10, y = 10 })
  eq(math.floor(d:getElementById('a').computed.backgroundColor[1]), 255)
  frame(d, { x = 500, y = 500 })
  eq(math.floor(d:getElementById('a').computed.backgroundColor[1]), 17)
end)

test('checkbox toggles and fires change', function()
  local d = doc('<body><input type="checkbox" id="c"></body>')
  frame(d)
  local changes = 0
  local c = d:getElementById('c')
  c:on('change', function() changes = changes + 1 end)
  local box = c.box
  local x, y = box.ax + 4, box.ay + 4
  frame(d, { x = x, y = y, pressed = true, down = true })
  frame(d, { x = x, y = y, released = true })
  truthy(c.state.checked, 'checked after click')
  eq(changes, 1)
  frame(d, { x = x, y = y, pressed = true, down = true })
  frame(d, { x = x, y = y, released = true })
  truthy(not c.state.checked, 'unchecked after second click')
end)

test('range slider updates its value on drag', function()
  local d = doc('<body><input type="range" id="r" min="0" max="100" value="0"></body>',
    'body { padding: 0 } #r { width: 200px }')
  frame(d)
  local r = d:getElementById('r')
  local inputs = 0
  r:on('input', function() inputs = inputs + 1 end)
  local box = r.box
  frame(d, { x = box.ax + box.w * 0.5, y = box.ay + 5, pressed = true, down = true })
  local v = tonumber(r:getValue())
  near(v, 50, 6)
  truthy(inputs > 0)
end)

test('select opens, picks an option and reports the value', function()
  local d = doc([[<body><select id="s">
      <option value="a">Alpha</option><option value="b">Beta</option>
    </select></body>]], 'body { padding: 0 }')
  frame(d)
  local s = d:getElementById('s')
  local box = s.box
  frame(d, { x = box.ax + 5, y = box.ay + 5, pressed = true, down = true })
  frame(d, { x = box.ax + 5, y = box.ay + 5, released = true })
  truthy(d.openSelect == s, 'dropdown open')
  frame(d, { x = box.ax + 5, y = box.ay + 5 })
  local popup = s.state.popupRect
  truthy(popup, 'popup painted')
  local optY = popup.y + 2 + popup.itemH * 1.5 -- second option
  local picked
  s:on('change', function(e) picked = e.value end)
  frame(d, { x = popup.x + 5, y = optY, pressed = true, down = true })
  eq(picked, 'b')
  eq(s:getValue(), 'b')
  truthy(d.openSelect == nil, 'dropdown closed')
end)

test('inline onclick handlers run in the document env', function()
  local calls = 0
  local d = doc('<body><button id="b" onclick="hit()">x</button></body>',
    '#b { width: 60px; height: 24px }', { env = { hit = function() calls = calls + 1 end } })
  frame(d)
  local box = d:getElementById('b').box
  frame(d, { x = box.ax + 3, y = box.ay + 3, pressed = true, down = true })
  frame(d, { x = box.ax + 3, y = box.ay + 3, released = true })
  eq(calls, 1)
end)

test('delegated doc:on works for elements added later', function()
  local d = doc('<body><div id="list"></div></body>', '.row { height: 20px }')
  frame(d)
  local clicked
  d:on('.row', 'click', function(e, node) clicked = node:getAttribute('data-id') end)
  d:getElementById('list'):append('<div class="row" data-id="42">row</div>')
  frame(d)
  local box = d:querySelector('.row').box
  frame(d, { x = box.ax + 3, y = box.ay + 3, pressed = true, down = true })
  frame(d, { x = box.ax + 3, y = box.ay + 3, released = true })
  eq(clicked, '42')
end)

test('<script> blocks run as Lua with document access', function()
  local d = doc([[<body>
    <div id="target"></div>
    <script>
      document:getElementById('target'):setText('from script')
    </script>
  </body>]])
  frame(d)
  eq(d:getElementById('target'):getText(), 'from script')
end)

test('{{ }} templates re-render when state changes', function()
  local d = doc('<body><span id="s">Money: {{ state.money }}$</span></body>')
  d.state.money = 500
  frame(d)
  eq(d:getElementById('s'):getText(), 'Money: 500$')
  d.state.money = 700
  frame(d)
  eq(d:getElementById('s'):getText(), 'Money: 700$')
end)

test('attribute templates drive classes', function()
  local d = doc('<body><div id="d" class="chip {{ state.mode }}">x</div></body>')
  d.state.mode = 'on'
  frame(d)
  truthy(d:getElementById('d'):hasClass('on'))
  d.state.mode = 'off'
  frame(d)
  truthy(d:getElementById('d'):hasClass('off'))
  truthy(not d:getElementById('d'):hasClass('on'))
end)

test('transitions interpolate over time', function()
  local d = doc('<body><div id="a"></div></body>', [[
    body { padding: 0 }
    #a { width: 50px; height: 50px; background-color: #000000; transition: background-color 1s }
    #a:hover { background-color: #ffffff }
  ]])
  frame(d, nil, 0)
  frame(d, { x = 10, y = 10 }, 0)
  frame(d, { x = 10, y = 10 }, 0.5)
  local mid = d:getElementById('a').computed.backgroundColor[1]
  truthy(mid > 60 and mid < 200, 'mid-transition value: ' .. tostring(mid))
  frame(d, { x = 10, y = 10 }, 1.5)
  eq(math.floor(d:getElementById('a').computed.backgroundColor[1]), 255)
end)

test('dom mutation invalidates layout', function()
  local d = doc('<body><div id="a">x</div></body>', 'body { padding: 0 }')
  frame(d)
  local h1 = d:getElementById('a').box.h
  d:getElementById('a'):setHTML('<p>one</p><p>two</p><p>three</p>')
  frame(d)
  truthy(d:getElementById('a').box.h > h1 * 2, 'box grew after setHTML')
end)

test('display:none removes a box entirely', function()
  local d = doc('<body><div id="a">x</div><div id="b">y</div></body>', 'body { padding: 0 }')
  frame(d)
  local yBefore = d:getElementById('b').box.ay
  d:getElementById('a'):hide()
  frame(d)
  eq(d:getElementById('b').box.ay, 0)
  truthy(yBefore > 0)
end)

test('paint emits a display list with backgrounds, borders and text', function()
  local d = doc('<body><div id="a">hello</div></body>', [[
    #a { background-color: #202124; border: 1px solid #ff0000; border-radius: 4px;
         width: 100px; height: 40px }
  ]])
  frame(d)
  local kinds = {}
  for _, cmd in ipairs(d.displayList) do kinds[cmd.op] = (kinds[cmd.op] or 0) + 1 end
  truthy(kinds.rect and kinds.rect >= 1, 'has a filled rect')
  truthy(kinds.border == 1, 'has one border')
  truthy(kinds.text and kinds.text >= 1, 'has text')
end)

test('nothing paints for a hidden subtree', function()
  local d = doc('<body><div style="display:none"><p>invisible</p></div></body>')
  frame(d)
  for _, cmd in ipairs(d.displayList) do
    truthy(cmd.op ~= 'text' or cmd.text ~= 'invisible', 'hidden text must not paint')
  end
end)

test('margin: auto pushes flex items apart', function()
  local d = doc('<body><div class="bar"><i id="a"></i><i id="b"></i></div></body>', [[
    body { padding: 0 }
    .bar { display: flex; width: 300px }
    i { display: block; width: 40px; height: 10px }
    #b { margin-left: auto }
  ]])
  frame(d)
  eq(d:getElementById('a').box.ax, 0)
  eq(d:getElementById('b').box.ax, 260)
end)

test('a full-height column keeps its header and footer', function()
  local d = doc([[<body><div class="win">
      <div class="head"></div>
      <div class="mid"><div class="tall"></div></div>
      <div class="foot"></div>
    </div></body>]], [[
    body { padding: 0 }
    .win { display: flex; flex-direction: column; height: 300px }
    .head { height: 40px }
    .mid { flex-grow: 1; overflow-y: auto }
    .tall { height: 2000px }
    .foot { height: 30px }
  ]], { height = 300 })
  frame(d)
  local head = d:querySelector('.head').box
  local mid = d:querySelector('.mid').box
  local foot = d:querySelector('.foot').box
  eq(head.h, 40, 'header keeps its height')
  eq(foot.h, 30, 'footer keeps its height')
  eq(mid.h, 230, 'the scrollable middle absorbs the rest')
  eq(foot.ay + foot.h, 300, 'footer sits on the bottom edge')
end)

test('flex items do not shrink below their content', function()
  local d = doc([[<body><div class="row">
      <div class="fixed">Очень длинный текст в первой ячейке</div>
      <div class="grow"></div></div></body>]], [[
    body { padding: 0 }
    .row { display: flex; width: 200px }
    .grow { flex-grow: 1; height: 10px }
    .fixed { white-space: nowrap }
  ]])
  frame(d)
  local fixed = d:querySelector('.fixed').box
  truthy(fixed.w > 40, 'kept its min-content width, got ' .. fixed.w)
end)

test('inline elements get a background box and are clickable', function()
  local d = doc('<body><p>text <a id="link" href="#">клик</a> more text</p></body>', [[
    body { padding: 0 } p { margin: 0 }
    #link { background-color: #ff0000; padding: 2px 6px }
  ]])
  frame(d)
  local link = d:getElementById('link')
  local x, y, w, h = link:rect()
  truthy(w and w > 10, 'inline fragment has a rect')
  local found = false
  for _, cmd in ipairs(d.displayList) do
    if cmd.op == 'rect' and cmd.color and math.floor(cmd.color[1]) == 255
        and math.abs(cmd.x - x) < 0.5 then
      found = true
    end
  end
  truthy(found, 'inline background painted')
  local clicked = false
  link:on('click', function() clicked = true end)
  frame(d, { x = x + w / 2, y = y + h / 2, pressed = true, down = true })
  frame(d, { x = x + w / 2, y = y + h / 2, released = true })
  truthy(clicked, 'inline element received the click')
end)

test('<label for> forwards clicks to its control', function()
  local d = doc([[<body>
    <label for="cb" style="display:block; width:120px; height:20px">Включить</label>
    <input type="checkbox" id="cb">
  </body>]], 'body { padding: 0 }')
  frame(d)
  local label = d:querySelector('label')
  local x, y = label.box.ax + 5, label.box.ay + 5
  frame(d, { x = x, y = y, pressed = true, down = true })
  frame(d, { x = x, y = y, released = true })
  truthy(d:getElementById('cb').state.checked, 'checkbox toggled through the label')
end)

test('radio groups keep a single selection', function()
  local d = doc([[<body>
    <input type="radio" name="g" id="r1"><input type="radio" name="g" id="r2">
  </body>]], 'body { padding: 0 }')
  frame(d)
  local function click(node)
    local b = node.box
    frame(d, { x = b.ax + 3, y = b.ay + 3, pressed = true, down = true })
    frame(d, { x = b.ax + 3, y = b.ay + 3, released = true })
  end
  click(d:getElementById('r1'))
  truthy(d:getElementById('r1').state.checked)
  click(d:getElementById('r2'))
  truthy(d:getElementById('r2').state.checked)
  truthy(not d:getElementById('r1').state.checked, 'first radio cleared')
end)

test('survives malformed markup and css without erroring', function()
  local d = doc([[<div class="a><p>unclosed <b>bold<div></p>
    <span style="color:">x</span><input <>&notanentity;]], [[
    .a { color: ; background }
    @media { p { color: red } }
    } stray brace {
    .b { width: calc(100% -); border-radius: }
  ]])
  frame(d)
  frame(d, { x = 10, y = 10, pressed = true, down = true })
  truthy(d.rootBox ~= nil, 'still produced a layout')
end)

test('empty document lays out cleanly', function()
  local d = doc('')
  frame(d)
  truthy(d.rootBox ~= nil)
  eq(#d.displayList, 0)
end)

test('deep nesting does not blow the stack', function()
  local parts = {}
  for i = 1, 60 do parts[#parts + 1] = '<div class="l">' end
  parts[#parts + 1] = 'deep'
  for i = 1, 60 do parts[#parts + 1] = '</div>' end
  local d = doc('<body>' .. table.concat(parts) .. '</body>', '.l { padding-left: 1px }')
  frame(d)
  truthy(d.rootBox.h > 0)
end)

test('colors: hex, rgb, rgba, hsl and names', function()
  local color = require 'moonhtml.color'
  local function hex(s) return color.toHex(color.parse(s)) end
  eq(hex('#f00'), '#ff0000')
  eq(hex('#00ff00'), '#00ff00')
  eq(hex('rgb(0, 0, 255)'), '#0000ff')
  eq(hex('rgba(255, 255, 0, 0.5)'), '#ffff00')
  eq(color.parse('rgba(0,0,0,0.5)')[4], 0.5)
  eq(hex('hsl(120, 100%, 50%)'), '#00ff00')
  eq(hex('crimson'), '#dc143c')
  eq(color.parse('transparent')[4], 0)
  eq(color.toU32({ 255, 0, 0, 1 }), 255 + 255 * 16777216)
end)

-- ------------------------------------------------------------- report ----

io.write('\n\n')
for _, f in ipairs(failures) do print('FAIL  ' .. f) end
print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
