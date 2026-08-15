-- Rough performance check:  lua5.1 tests/bench.lua
-- Numbers here are worst case -- MoonLoader runs LuaJIT, which is far faster
-- on this kind of code than the plain Lua 5.1 interpreter used for the suite.

package.path = 'lib/?.lua;lib/?/init.lua;tests/?.lua;' .. package.path

local moonhtml = require 'moonhtml'
local metrics = require 'metrics_dejavu'

local file = arg[1] or 'examples/menu/index.html'
local frames = tonumber(arg[2]) or 600

local fh = assert(io.open(file, 'rb'))
local source = fh:read('*a')
fh:close()

--- Each case gets a fresh document: leftover hover/transition state from a
-- previous case would quietly inflate the next one.
local function newDoc()
  local d = moonhtml.headless {
    html = source, metrics = metrics, width = 720, height = 520,
    basePath = file:match('^(.*[/\\])') or '',
  }
  for _, k in ipairs({ 'nick', 'id', 'ping', 'fps', 'radius', 'delay', 'hp', 'armour' }) do
    d.state[k] = 10
  end
  return d
end

local doc = newDoc()

local nodes = 0
doc.root:walk(function() nodes = nodes + 1 end)

local function input(x, y, extra)
  local i = { x = x, y = y, down = false, pressed = false, released = false,
    wheel = 0, chars = {}, keys = {}, inside = true }
  for k, v in pairs(extra or {}) do i[k] = v end
  return i
end

local function bench(name, fn)
  local d = newDoc()
  d:update(input(-1, -1), 0) -- warm up caches
  local t0 = os.clock()
  fn(d)
  local dt = (os.clock() - t0) / frames * 1000
  print(string.format('%-34s %7.3f ms/frame  (%6.0f fps)', name, dt,
    dt > 0 and 1000 / dt or 0))
end

doc:update(input(-1, -1), 0)
print(string.format('document: %s, %d nodes, %d draw commands, %d boxes\n',
  file, nodes, #doc.displayList, doc.rootBox.boxCount or 0))

bench('idle (nothing changes)', function(d)
  for i = 1, frames do d:update(input(-1, -1), i / 60) end
end)

bench('mouse moving over the menu', function(d)
  for i = 1, frames do
    d:update(input(100 + (i % 300), 80 + (i % 300)), i / 60)
  end
end)

bench('state updated every frame', function(d)
  for i = 1, frames do
    d.state.fps = i % 120
    d.state.hp = i % 100
    d:update(input(-1, -1), i / 60)
  end
end)

bench('full restyle every frame', function(d)
  for i = 1, frames do
    d.needsStyle = true
    d:update(input(-1, -1), i / 60)
  end
end)

bench('restyle + relayout every frame', function(d)
  for i = 1, frames do
    d.needsStyle = true
    d.needsLayout = true
    d:update(input(-1, -1), i / 60)
  end
end)
