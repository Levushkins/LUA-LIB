-- moonhtml/color.lua -- CSS colour parsing and ImU32 packing.
-- Colours are stored as { r, g, b, a } with r/g/b in 0..255 and a in 0..1.

local util = require 'moonhtml.util'

local color = {}
local floor, min, max = math.floor, math.min, math.max

local NAMED = {
  transparent = { 0, 0, 0, 0 },
  black = { 0, 0, 0 }, white = { 255, 255, 255 },
  red = { 255, 0, 0 }, lime = { 0, 255, 0 }, blue = { 0, 0, 255 },
  green = { 0, 128, 0 }, yellow = { 255, 255, 0 }, cyan = { 0, 255, 255 },
  aqua = { 0, 255, 255 }, magenta = { 255, 0, 255 }, fuchsia = { 255, 0, 255 },
  silver = { 192, 192, 192 }, gray = { 128, 128, 128 }, grey = { 128, 128, 128 },
  maroon = { 128, 0, 0 }, olive = { 128, 128, 0 }, purple = { 128, 0, 128 },
  teal = { 0, 128, 128 }, navy = { 0, 0, 128 }, orange = { 255, 165, 0 },
  gold = { 255, 215, 0 }, pink = { 255, 192, 203 }, brown = { 165, 42, 42 },
  coral = { 255, 127, 80 }, crimson = { 220, 20, 60 }, indigo = { 75, 0, 130 },
  ivory = { 255, 255, 240 }, khaki = { 240, 230, 140 }, lavender = { 230, 230, 250 },
  orchid = { 218, 112, 214 }, salmon = { 250, 128, 114 }, tan = { 210, 180, 140 },
  tomato = { 255, 99, 71 }, violet = { 238, 130, 238 }, wheat = { 245, 222, 179 },
  beige = { 245, 245, 220 }, bisque = { 255, 228, 196 }, plum = { 221, 160, 221 },
  turquoise = { 64, 224, 208 }, skyblue = { 135, 206, 235 },
  steelblue = { 70, 130, 180 }, slategray = { 112, 128, 144 },
  slategrey = { 112, 128, 144 }, seagreen = { 46, 139, 87 },
  royalblue = { 65, 105, 225 }, dodgerblue = { 30, 144, 255 },
  deepskyblue = { 0, 191, 255 }, springgreen = { 0, 255, 127 },
  limegreen = { 50, 205, 50 }, forestgreen = { 34, 139, 34 },
  darkgreen = { 0, 100, 0 }, darkblue = { 0, 0, 139 }, darkred = { 139, 0, 0 },
  darkcyan = { 0, 139, 139 }, darkorange = { 255, 140, 0 },
  darkgray = { 169, 169, 169 }, darkgrey = { 169, 169, 169 },
  lightgray = { 211, 211, 211 }, lightgrey = { 211, 211, 211 },
  lightblue = { 173, 216, 230 }, lightgreen = { 144, 238, 144 },
  whitesmoke = { 245, 245, 245 }, gainsboro = { 220, 220, 220 },
  dimgray = { 105, 105, 105 }, dimgrey = { 105, 105, 105 },
  midnightblue = { 25, 25, 112 }, mediumpurple = { 147, 112, 219 },
  hotpink = { 255, 105, 180 }, greenyellow = { 173, 255, 47 },
  chartreuse = { 127, 255, 0 }, aquamarine = { 127, 255, 212 },
}

function color.rgba(r, g, b, a)
  return { r, g, b, a == nil and 1 or a }
end

local function hex2(s) return tonumber(s, 16) end

local function parseHex(s)
  local n = #s
  if n == 3 or n == 4 then
    local r, g, b = hex2(s:sub(1, 1)), hex2(s:sub(2, 2)), hex2(s:sub(3, 3))
    if not (r and g and b) then return nil end
    local a = 1
    if n == 4 then
      local av = hex2(s:sub(4, 4))
      if not av then return nil end
      a = (av * 17) / 255
    end
    return { r * 17, g * 17, b * 17, a }
  elseif n == 6 or n == 8 then
    local r, g, b = hex2(s:sub(1, 2)), hex2(s:sub(3, 4)), hex2(s:sub(5, 6))
    if not (r and g and b) then return nil end
    local a = 1
    if n == 8 then
      local av = hex2(s:sub(7, 8))
      if not av then return nil end
      a = av / 255
    end
    return { r, g, b, a }
  end
  return nil
end

local function hueToRgb(p, q, t)
  if t < 0 then t = t + 1 end
  if t > 1 then t = t - 1 end
  if t < 1 / 6 then return p + (q - p) * 6 * t end
  if t < 1 / 2 then return q end
  if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
  return p
end

--- h in 0..360, s/l in 0..1
function color.fromHsl(h, s, l, a)
  h = (h % 360) / 360
  local r, g, b
  if s == 0 then
    r, g, b = l, l, l
  else
    local q = l < 0.5 and l * (1 + s) or (l + s - l * s)
    local p = 2 * l - q
    r = hueToRgb(p, q, h + 1 / 3)
    g = hueToRgb(p, q, h)
    b = hueToRgb(p, q, h - 1 / 3)
  end
  return { r * 255, g * 255, b * 255, a or 1 }
end

local function numberOrPercent(s, base)
  s = util.trim(s)
  if s:sub(-1) == '%' then
    local v = tonumber(s:sub(1, -2))
    if not v then return nil end
    return v / 100 * base
  end
  return tonumber(s)
end

--- Parse any supported CSS colour string. Returns nil when unparseable.
function color.parse(s)
  if type(s) == 'table' then return s end
  if type(s) ~= 'string' then return nil end
  s = util.trim(s)
  local lower = s:lower()
  if lower == '' then return nil end
  if lower:sub(1, 1) == '#' then return parseHex(lower:sub(2)) end

  local fn, args = lower:match('^(%a+)%s*%((.*)%)$')
  if fn then
    local parts = util.splitTopLevel(args:gsub('/', ','), ',')
    if #parts == 1 then parts = util.words(args) end
    if fn == 'rgb' or fn == 'rgba' then
      local r = numberOrPercent(parts[1] or '', 255)
      local g = numberOrPercent(parts[2] or '', 255)
      local b = numberOrPercent(parts[3] or '', 255)
      if not (r and g and b) then return nil end
      local a = 1
      if parts[4] then a = numberOrPercent(parts[4], 1) or 1 end
      return { r, g, b, a }
    elseif fn == 'hsl' or fn == 'hsla' then
      local h = tonumber(((parts[1] or ''):gsub('deg', '')))
      local s2 = numberOrPercent(parts[2] or '', 1)
      local l = numberOrPercent(parts[3] or '', 1)
      if not (h and s2 and l) then return nil end
      local a = 1
      if parts[4] then a = numberOrPercent(parts[4], 1) or 1 end
      return color.fromHsl(h, s2, l, a)
    end
    return nil
  end

  local named = NAMED[lower]
  if named then return { named[1], named[2], named[3], named[4] or 1 } end
  return nil
end

function color.withAlpha(c, a)
  return { c[1], c[2], c[3], (c[4] or 1) * a }
end

function color.mix(a, b, t)
  return {
    util.lerp(a[1], b[1], t),
    util.lerp(a[2], b[2], t),
    util.lerp(a[3], b[3], t),
    util.lerp(a[4] or 1, b[4] or 1, t),
  }
end

function color.equals(a, b)
  if a == b then return true end
  if not a or not b then return false end
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and (a[4] or 1) == (b[4] or 1)
end

function color.isTransparent(c)
  return not c or (c[4] or 1) <= 0.0001
end

--- Pack into an ImU32 (0xAABBGGRR as used by Dear ImGui).
function color.toU32(c, alphaMul)
  if not c then return 0 end
  local a = (c[4] or 1) * (alphaMul or 1)
  local r = floor(util.clamp(c[1], 0, 255) + 0.5)
  local g = floor(util.clamp(c[2], 0, 255) + 0.5)
  local b = floor(util.clamp(c[3], 0, 255) + 0.5)
  local av = floor(util.clamp(a * 255, 0, 255) + 0.5)
  return r + g * 256 + b * 65536 + av * 16777216
end

function color.toHex(c)
  return string.format('#%02x%02x%02x',
    floor(util.clamp(c[1], 0, 255)), floor(util.clamp(c[2], 0, 255)),
    floor(util.clamp(c[3], 0, 255)))
end

--- Lighten/darken by `amount` (-1..1), used by :hover helpers.
function color.shade(c, amount)
  local t = amount
  if t >= 0 then
    return { util.lerp(c[1], 255, t), util.lerp(c[2], 255, t), util.lerp(c[3], 255, t), c[4] or 1 }
  end
  t = -t
  return { util.lerp(c[1], 0, t), util.lerp(c[2], 0, t), util.lerp(c[3], 0, t), c[4] or 1 }
end

color.named = NAMED

return color
