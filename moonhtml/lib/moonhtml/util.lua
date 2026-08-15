-- moonhtml/util.lua -- small shared helpers (LuaJIT / Lua 5.1 compatible)

local util = {}

local floor, min, max = math.floor, math.min, math.max

function util.trim(s)
  if not s then return '' end
  local r = s:gsub('^[%s]+', ''):gsub('[%s]+$', '')
  return r
end

function util.startsWith(s, p)
  return s:sub(1, #p) == p
end

function util.endsWith(s, p)
  return p == '' or s:sub(-#p) == p
end

-- split by a plain separator (not a pattern)
function util.split(s, sep)
  local out, pos = {}, 1
  sep = sep or ','
  while true do
    local a, b = s:find(sep, pos, true)
    if not a then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
  return out
end

-- split on whitespace, dropping empty parts
function util.words(s)
  local out = {}
  for w in tostring(s or ''):gmatch('%S+') do out[#out + 1] = w end
  return out
end

--- Split a CSS value list on top-level commas, respecting parentheses.
-- "linear-gradient(a, b), red" -> {"linear-gradient(a, b)", "red"}
function util.splitTopLevel(s, sepChar)
  sepChar = sepChar or ','
  local out, depth, start = {}, 0, 1
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '(' then
      depth = depth + 1
    elseif c == ')' then
      depth = depth - 1
    elseif c == '"' or c == "'" then
      local q = c
      i = i + 1
      while i <= #s and s:sub(i, i) ~= q do
        if s:sub(i, i) == '\\' then i = i + 1 end
        i = i + 1
      end
    elseif c == sepChar and depth == 0 then
      out[#out + 1] = util.trim(s:sub(start, i - 1))
      start = i + 1
    end
    i = i + 1
  end
  out[#out + 1] = util.trim(s:sub(start))
  return out
end

--- Split a value into space separated components, respecting parentheses.
function util.valueParts(s)
  return util.splitTopLevel((s:gsub('%s+', '\1')), '\1')
end

function util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function util.lerp(a, b, t) return a + (b - a) * t end

function util.round(v) return floor(v + 0.5) end

function util.copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

function util.contains(t, v)
  for i = 1, #t do if t[i] == v then return true end end
  return false
end

function util.indexOf(t, v)
  for i = 1, #t do if t[i] == v then return i end end
  return nil
end

-- ---------------------------------------------------------------- utf-8 ----

local UTF8_PATTERN = '[%z\1-\127\194-\244][\128-\191]*'

--- Iterate over utf-8 characters of a string.
function util.chars(s)
  return s:gmatch(UTF8_PATTERN)
end

function util.utf8len(s)
  local n = 0
  for _ in s:gmatch(UTF8_PATTERN) do n = n + 1 end
  return n
end

--- Byte offset of the utf-8 character boundary before `pos` (1-based byte pos).
function util.prevCharStart(s, pos)
  local i = pos - 1
  while i > 1 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return max(1, i)
end

function util.nextCharStart(s, pos)
  local i = pos + 1
  while i <= #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then break end
    i = i + 1
  end
  return min(#s + 1, i)
end

--- Iterate over the unicode codepoints of a utf-8 string.
function util.codepoints(s)
  local i, n = 1, #s
  return function()
    if i > n then return nil end
    local b = s:byte(i)
    local cp, size
    if b < 0x80 then
      cp, size = b, 1
    elseif b < 0xE0 then
      cp, size = (b - 0xC0) * 0x40 + ((s:byte(i + 1) or 0x80) - 0x80), 2
    elseif b < 0xF0 then
      cp = (b - 0xE0) * 0x1000 + ((s:byte(i + 1) or 0x80) - 0x80) * 0x40
          + ((s:byte(i + 2) or 0x80) - 0x80)
      size = 3
    else
      cp = (b - 0xF0) * 0x40000 + ((s:byte(i + 1) or 0x80) - 0x80) * 0x1000
          + ((s:byte(i + 2) or 0x80) - 0x80) * 0x40 + ((s:byte(i + 3) or 0x80) - 0x80)
      size = 4
    end
    i = i + size
    return cp
  end
end

--- Encode a unicode codepoint as utf-8.
function util.utf8char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(0xE0 + floor(cp / 0x1000),
      0x80 + (floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
  end
  return string.char(0xF0 + floor(cp / 0x40000),
    0x80 + (floor(cp / 0x1000) % 0x40),
    0x80 + (floor(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
end

-- ------------------------------------------------------------------ oop ----

--- Minimal single-inheritance class helper.
function util.class(base)
  local c = {}
  c.__index = c
  if base then setmetatable(c, { __index = base }) end
  c.new = function(...)
    local o = setmetatable({}, c)
    if o.init then o:init(...) end
    return o
  end
  return c
end

-- ------------------------------------------------------------ debugging ----

function util.dump(v, indent, seen)
  indent, seen = indent or '', seen or {}
  if type(v) ~= 'table' then
    if type(v) == 'string' then return string.format('%q', v) end
    return tostring(v)
  end
  if seen[v] then return '<cycle>' end
  seen[v] = true
  local parts, inner = {}, indent .. '  '
  for k, val in pairs(v) do
    parts[#parts + 1] = inner .. tostring(k) .. ' = ' .. util.dump(val, inner, seen)
  end
  table.sort(parts)
  if #parts == 0 then return '{}' end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

return util
