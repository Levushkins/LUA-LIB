-- Render a document headlessly and dump its display list as JSON, so that
-- tools/render_png.py can rasterise it and the layout can be eyeballed.
--
--   lua5.1 tests/snapshot.lua examples/menu/index.html out.json [w] [h] [hoverX hoverY]

package.path = 'lib/?.lua;lib/?/init.lua;tests/?.lua;' .. package.path

local moonhtml = require 'moonhtml'
local metrics = require 'metrics_dejavu'

local file = arg[1] or 'examples/menu/index.html'
local out = arg[2] or 'snapshot.json'
local width = tonumber(arg[3]) or 720
local height = tonumber(arg[4]) or 520
local hoverX = tonumber(arg[5]) or -1000
local hoverY = tonumber(arg[6]) or -1000

local f = assert(io.open(file, 'rb'), 'cannot open ' .. file)
local source = f:read('*a')
f:close()

local doc = moonhtml.headless {
  html = source,
  metrics = metrics,
  width = width,
  height = height,
  basePath = file:match('^(.*[/\\])') or '',
}

doc.state.nick = 'Ivan_Petrov'
doc.state.id = 42
doc.state.ping = 38
doc.state.fps = 60
doc.state.radius = 18
doc.state.delay = 250
doc.state.hp = 78
doc.state.armour = 42

local input = {
  x = hoverX, y = hoverY, down = false, pressed = false, released = false,
  wheel = 0, chars = {}, keys = {}, inside = true,
}
doc:update(input, 0)
doc:update(input, 10) -- settle transitions

-- ------------------------------------------------------------ json out ----

local buf = {}
local function put(s) buf[#buf + 1] = s end

local function esc(s)
  return (tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    return string.format('\\u%04x', c:byte())
  end))
end

local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then return '0' end
  return string.format('%.3f', v)
end

local function writeValue(v)
  local t = type(v)
  if t == 'number' then
    put(num(v))
  elseif t == 'boolean' then
    put(tostring(v))
  elseif t == 'string' then
    put('"' .. esc(v) .. '"')
  elseif t == 'table' then
    if #v > 0 or next(v) == nil then
      put('[')
      for i, item in ipairs(v) do
        if i > 1 then put(',') end
        writeValue(item)
      end
      put(']')
    else
      put('{')
      local first = true
      local keys = {}
      for k in pairs(v) do
        if type(k) == 'string' then keys[#keys + 1] = k end
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        if not first then put(',') end
        first = false
        put('"' .. esc(k) .. '":')
        writeValue(v[k])
      end
      put('}')
    end
  else
    put('null')
  end
end

local commands = {}
for _, cmd in ipairs(doc.displayList) do
  local c = {}
  for k, v in pairs(cmd) do
    if k == 'style' then
      c.fontSize = v.fontSize
      c.fontWeight = tostring(v.fontWeight)
      c.fontFamily = v.fontFamily
    elseif k == 'node' then
      c.tag = v.tag
    elseif k == 'stops' then
      local stops = {}
      for i, s in ipairs(v) do stops[i] = { pos = s.pos, color = s.color } end
      c.stops = stops
    elseif type(v) ~= 'function' then
      c[k] = v
    end
  end
  commands[#commands + 1] = c
end

writeValue({ width = width, height = height, commands = commands })

local fh = assert(io.open(out, 'wb'))
fh:write(table.concat(buf))
fh:close()

print(string.format('%s: %d commands -> %s', file, #commands, out))
if #doc.errors > 0 then
  print('errors:')
  for _, e in ipairs(doc.errors) do print('  ' .. e) end
end
