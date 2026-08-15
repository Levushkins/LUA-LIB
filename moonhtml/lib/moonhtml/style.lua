-- moonhtml/style.lua -- cascade, computed values, CSS variables, transitions.

local util = require 'moonhtml.util'
local color = require 'moonhtml.color'
local css = require 'moonhtml.css'

local style = {}

local floor, max, min = math.floor, math.max, math.min

-- ---------------------------------------------------------------- units ----

local AUTO = { u = 'auto' }
local NONE = { u = 'none' }
style.AUTO, style.NONE = AUTO, NONE

local function px(n) return { n = n, u = 'px' } end
style.px = px

local FONT_SIZE_KEYWORDS = {
  ['xx-small'] = 9, ['x-small'] = 10, small = 12, medium = 14,
  large = 17, ['x-large'] = 21, ['xx-large'] = 26,
}

local function unitToPx(n, unit, ctx)
  if unit == '' or unit == 'px' then return n end
  if unit == 'em' then return n * (ctx.fontSize or 14) end
  if unit == 'rem' then return n * (ctx.rootFontSize or 14) end
  if unit == 'pt' then return n * 1.3333 end
  if unit == 'vw' then return n / 100 * (ctx.vw or 0) end
  if unit == 'vh' then return n / 100 * (ctx.vh or 0) end
  if unit == 'vmin' then return n / 100 * min(ctx.vw or 0, ctx.vh or 0) end
  if unit == 'vmax' then return n / 100 * max(ctx.vw or 0, ctx.vh or 0) end
  return nil
end

--- Parse a CSS length into a spec table understood by the layout engine.
-- Absolute units collapse to px right away; %, fr, auto and calc() survive.
function style.parseLength(value, ctx)
  if value == nil then return nil end
  if type(value) == 'table' then return value end
  local v = util.trim(tostring(value)):lower()
  if v == '' then return nil end
  if v == 'auto' then return AUTO end
  if v == 'none' then return NONE end
  if v == 'min-content' or v == 'max-content' or v == 'fit-content' then
    return { u = 'content', mode = v }
  end
  if v:sub(1, 5) == 'calc(' then
    -- limited calc: sum of px-ish and % terms with + / -
    local body = v:sub(6, -2)
    local pxSum, pctSum, sign = 0, 0, 1
    local ok = true
    for token in body:gmatch('%S+') do
      if token == '+' then sign = 1
      elseif token == '-' then sign = -1
      elseif token == '*' or token == '/' then ok = false
      else
        local n, unit = token:match('^([%-%+]?%d*%.?%d+)(%a*%%?)$')
        if not n then
          ok = false
        elseif unit == '%' then
          pctSum = pctSum + sign * tonumber(n)
        else
          local conv = unitToPx(tonumber(n), unit, ctx)
          if conv then pxSum = pxSum + sign * conv else ok = false end
        end
        sign = 1
      end
    end
    if ok then return { u = 'calc', px = pxSum, pct = pctSum } end
    return nil
  end
  local n, unit = v:match('^([%-%+]?%d*%.?%d+)(%a*%%?)$')
  if not n then return nil end
  n = tonumber(n)
  if unit == '%' then return { n = n, u = '%' } end
  if unit == 'fr' then return { n = n, u = 'fr' } end
  local conv = unitToPx(n, unit, ctx)
  if conv then return px(conv) end
  return nil
end

--- Resolve a length spec against a percentage base. Returns nil for auto/none.
function style.resolve(spec, base)
  if not spec then return nil end
  local u = spec.u
  if u == 'px' then return spec.n end
  if u == '%' then
    if not base then return nil end
    return spec.n / 100 * base
  end
  if u == 'calc' then
    return spec.px + (base and (spec.pct / 100 * base) or 0)
  end
  return nil -- auto / none / fr / content
end

function style.isAuto(spec) return not spec or spec.u == 'auto' end

-- ------------------------------------------------------------ gradients ----

local function parseGradient(value, ctx)
  local fn, args = value:match('^([%w%-]+)%((.*)%)$')
  if not fn then return nil end
  fn = fn:lower()
  if fn ~= 'linear-gradient' then return nil end
  local parts = util.splitTopLevel(args, ',')
  local angle = 180 -- default: top -> bottom
  local first = util.trim(parts[1] or ''):lower()
  local startIdx = 1
  local deg = first:match('^([%-%d%.]+)deg$')
  if deg then
    angle = tonumber(deg)
    startIdx = 2
  elseif first:sub(1, 3) == 'to ' then
    local dir = first:sub(4)
    local map = {
      top = 0, right = 90, bottom = 180, left = 270,
      ['top right'] = 45, ['right top'] = 45,
      ['bottom right'] = 135, ['right bottom'] = 135,
      ['bottom left'] = 225, ['left bottom'] = 225,
      ['top left'] = 315, ['left top'] = 315,
    }
    angle = map[util.trim(dir)] or 180
    startIdx = 2
  end
  local stops = {}
  for i = startIdx, #parts do
    local p = util.trim(parts[i])
    local cstr, pos = p:match('^(.-)%s+([%d%.]+%%)$')
    local c = color.parse(cstr or p)
    if c then
      stops[#stops + 1] = { color = c, pos = pos and tonumber(pos:sub(1, -2)) / 100 or nil }
    end
  end
  if #stops < 2 then return nil end
  for i, s in ipairs(stops) do
    if not s.pos then s.pos = (i - 1) / (#stops - 1) end
  end
  return { type = 'linear', angle = angle % 360, stops = stops }
end

-- ---------------------------------------------------------- shadow/etc. ----

local function parseShadow(value, ctx)
  local v = util.trim(value):lower()
  if v == '' or v == 'none' then return nil end
  local inset = false
  v = v:gsub('inset', function() inset = true; return '' end)
  local nums, col = {}, nil
  for _, tok in ipairs(util.valueParts(v)) do
    local len = style.parseLength(tok, ctx)
    if len and len.u == 'px' then
      nums[#nums + 1] = len.n
    else
      col = color.parse(tok) or col
    end
  end
  if #nums < 2 then return nil end
  return {
    x = nums[1], y = nums[2], blur = nums[3] or 0, spread = nums[4] or 0,
    color = col or color.rgba(0, 0, 0, 0.45), inset = inset,
  }
end

local function parseTransform(value, ctx)
  local t = { tx = 0, ty = 0, sx = 1, sy = 1 }
  if not value or value == 'none' then return t end
  for fn, args in value:gmatch('([%w]+)%(([^%)]*)%)') do
    local parts = util.splitTopLevel(args, ',')
    local a = style.parseLength(parts[1] or '0', ctx)
    local b = style.parseLength(parts[2] or parts[1] or '0', ctx)
    fn = fn:lower()
    if fn == 'translate' then
      t.tx = t.tx + (a and a.n or 0)
      t.ty = t.ty + (b and b.n or 0)
    elseif fn == 'translatex' then
      t.tx = t.tx + (a and a.n or 0)
    elseif fn == 'translatey' then
      t.ty = t.ty + (a and a.n or 0)
    elseif fn == 'scale' then
      t.sx = t.sx * (tonumber(parts[1]) or 1)
      t.sy = t.sy * (tonumber(parts[2] or parts[1]) or 1)
    elseif fn == 'scalex' then
      t.sx = t.sx * (tonumber(parts[1]) or 1)
    elseif fn == 'scaley' then
      t.sy = t.sy * (tonumber(parts[1]) or 1)
    end
  end
  return t
end

-- ---------------------------------------------------------- transitions ----

local EASINGS = {
  linear = function(t) return t end,
  ease = function(t) return t * t * (3 - 2 * t) end,
  ['ease-in'] = function(t) return t * t end,
  ['ease-out'] = function(t) return 1 - (1 - t) * (1 - t) end,
  ['ease-in-out'] = function(t)
    if t < 0.5 then return 2 * t * t end
    return 1 - 2 * (1 - t) * (1 - t)
  end,
}

local function accessor(field)
  return function(c) return c[field] end, function(c, v) c[field] = v end
end

local function subAccessor(field, idx)
  return function(c) return c[field] and c[field][idx] end,
      function(c, v) if c[field] then c[field][idx] = v end end
end

local ANIM = {}
local function anim(prop, kind, getter, setter)
  local g, s = getter, setter
  if not g then g, s = accessor(prop) end
  ANIM[prop] = { kind = kind, get = g, set = s }
end

anim('color', 'color', accessor('color'))
anim('background-color', 'color', accessor('backgroundColor'))
anim('opacity', 'number', accessor('opacity'))
anim('font-size', 'number', accessor('fontSize'))
anim('letter-spacing', 'number', accessor('letterSpacing'))
anim('width', 'length', accessor('width'))
anim('height', 'length', accessor('height'))
anim('top', 'length', accessor('top'))
anim('right', 'length', accessor('right'))
anim('bottom', 'length', accessor('bottom'))
anim('left', 'length', accessor('left'))
anim('transform', 'transform', accessor('transform'))
for i, side in ipairs({ 'top', 'right', 'bottom', 'left' }) do
  anim('margin-' .. side, 'length', subAccessor('margin', i))
  anim('padding-' .. side, 'length', subAccessor('padding', i))
  anim('border-' .. side .. '-color', 'color', subAccessor('borderColor', i))
  anim('border-' .. side .. '-width', 'number', subAccessor('border', i))
end
for i, corner in ipairs({ 'top-left', 'top-right', 'bottom-right', 'bottom-left' }) do
  anim('border-' .. corner .. '-radius', 'number', subAccessor('radius', i))
end

local function sameValue(kind, a, b)
  if a == nil or b == nil then return a == b end
  if kind == 'color' then return color.equals(a, b) end
  if kind == 'number' then return math.abs(a - b) < 0.001 end
  if kind == 'length' then
    return a.u == b.u and math.abs((a.n or 0) - (b.n or 0)) < 0.001
  end
  if kind == 'transform' then
    return a.tx == b.tx and a.ty == b.ty and a.sx == b.sx and a.sy == b.sy
  end
  return a == b
end

local function mixValue(kind, a, b, t)
  if kind == 'color' then return color.mix(a, b, t) end
  if kind == 'number' then return util.lerp(a, b, t) end
  if kind == 'length' then
    if a.u == b.u and (a.u == 'px' or a.u == '%') then
      return { n = util.lerp(a.n, b.n, t), u = a.u }
    end
    return t < 1 and a or b
  end
  if kind == 'transform' then
    return {
      tx = util.lerp(a.tx, b.tx, t), ty = util.lerp(a.ty, b.ty, t),
      sx = util.lerp(a.sx, b.sx, t), sy = util.lerp(a.sy, b.sy, t),
    }
  end
  return b
end

local function parseTransition(value, ctx)
  if not value or value == '' or value == 'none' then return nil end
  local out = {}
  for _, part in ipairs(util.splitTopLevel(value, ',')) do
    local prop, dur, delay, ease = nil, 0.2, 0, 'ease'
    local seen = 0
    for _, tok in ipairs(util.valueParts(part)) do
      local t = tok:lower()
      local secs = t:match('^([%d%.]+)s$')
      local msecs = t:match('^([%d%.]+)ms$')
      if secs or msecs then
        local v = secs and tonumber(secs) or tonumber(msecs) / 1000
        seen = seen + 1
        if seen == 1 then dur = v else delay = v end
      elseif EASINGS[t] or t:sub(1, 12) == 'cubic-bezier' then
        ease = EASINGS[t] and t or 'ease'
      elseif t ~= '' then
        prop = t
      end
    end
    if prop then
      out[#out + 1] = { prop = prop, dur = dur, delay = delay, ease = ease }
    end
  end
  if #out == 0 then return nil end
  return out
end

-- --------------------------------------------------------------- engine ----

local Engine = {}
Engine.__index = Engine
style.Engine = Engine

function style.newEngine(opts)
  opts = opts or {}
  local self = setmetatable({}, Engine)
  self.viewport = { w = opts.width or 800, h = opts.height or 600 }
  self.rootFontSize = opts.fontSize or 14
  self.rules = {}
  self.index = { id = {}, class = {}, tag = {}, universal = {} }
  self.animating = false
  return self
end

function Engine:setViewport(w, h)
  self.viewport.w, self.viewport.h = w, h
end

--- @param sheets array of { source = <css text>, origin = 0 (ua) | 1 (author) }
function Engine:setStylesheets(sheets)
  self.rules = {}
  self.index = { id = {}, class = {}, tag = {}, universal = {} }
  for _, sheet in ipairs(sheets) do
    local parsed = css.parse(sheet.source)
    for _, rule in ipairs(parsed) do
      rule.origin = sheet.origin or 1
      self.rules[#self.rules + 1] = rule
      local bucket
      if rule.keyKind == 'id' then
        bucket = self.index.id[rule.keyValue]
        if not bucket then bucket = {}; self.index.id[rule.keyValue] = bucket end
      elseif rule.keyKind == 'class' then
        bucket = self.index.class[rule.keyValue]
        if not bucket then bucket = {}; self.index.class[rule.keyValue] = bucket end
      elseif rule.keyKind == 'tag' then
        bucket = self.index.tag[rule.keyValue]
        if not bucket then bucket = {}; self.index.tag[rule.keyValue] = bucket end
      else
        bucket = self.index.universal
      end
      bucket[#bucket + 1] = rule
    end
  end
end

function Engine:mediaMatches(m)
  if not m then return true end
  local w, h = self.viewport.w, self.viewport.h
  if m['min-width'] and w < m['min-width'] then return false end
  if m['max-width'] and w > m['max-width'] then return false end
  if m['min-height'] and h < m['min-height'] then return false end
  if m['max-height'] and h > m['max-height'] then return false end
  return true
end

local function ruleLess(a, b)
  if a.origin ~= b.origin then return a.origin < b.origin end
  local sa, sb = a.selector.spec, b.selector.spec
  if sa[1] ~= sb[1] then return sa[1] < sb[1] end
  if sa[2] ~= sb[2] then return sa[2] < sb[2] end
  if sa[3] ~= sb[3] then return sa[3] < sb[3] end
  return a.order < b.order
end

function Engine:collectRules(node, out)
  local function tryBucket(bucket)
    if not bucket then return end
    for i = 1, #bucket do
      local rule = bucket[i]
      if self:mediaMatches(rule.media) and css.matches(rule.selector, node) then
        out[#out + 1] = rule
      end
    end
  end
  tryBucket(self.index.universal)
  tryBucket(self.index.tag[node.tag])
  if node.id then tryBucket(self.index.id[node.id]) end
  for _, cl in ipairs(node.classes) do tryBucket(self.index.class[cl]) end
  table.sort(out, ruleLess)
  return out
end

local VAR_DEPTH = 4

local function resolveVars(value, vars)
  if not value or not value:find('var(', 1, true) then return value end
  for _ = 1, VAR_DEPTH do
    local changed = false
    value = value:gsub('var%(%s*(%-%-[%w_%-]+)%s*%)', function(name)
      changed = true
      return vars[name] or ''
    end)
    value = value:gsub('var%(%s*(%-%-[%w_%-]+)%s*,%s*([^%)]*)%)', function(name, fallback)
      changed = true
      return vars[name] or fallback
    end)
    if not changed then break end
  end
  return value
end

--- Build the winning declaration map for one element.
function Engine:cascade(node)
  local matched = self:collectRules(node, {})
  local props = {}
  for _, rule in ipairs(matched) do
    for k, v in pairs(rule.decls) do
      if not rule.important[k] then props[k] = v end
    end
  end
  for k, v in pairs(node.inlineDecls) do props[k] = v end
  for _, rule in ipairs(matched) do
    for k, v in pairs(rule.decls) do
      if rule.important[k] then props[k] = v end
    end
  end
  return props
end

local INHERITED_DEFAULTS = {
  color = { 232, 234, 237, 1 },
  fontFamily = 'default',
  fontSize = 14,
  fontWeight = 'normal',
  fontStyle = 'normal',
  lineHeightRaw = 1.35,
  textAlign = 'left',
  whiteSpace = 'normal',
  letterSpacing = 0,
  cursor = 'default',
  visibility = 'visible',
  textTransform = 'none',
  listStyle = 'disc',
  pointerEvents = 'auto',
}

local ALIGN_ALIAS = {
  start = 'flex-start', ['flex-start'] = 'flex-start', left = 'flex-start',
  ['end'] = 'flex-end', ['flex-end'] = 'flex-end', right = 'flex-end',
  center = 'center', stretch = 'stretch', baseline = 'baseline',
  ['space-between'] = 'space-between', ['space-around'] = 'space-around',
  ['space-evenly'] = 'space-evenly',
}

function Engine:compute(node, parent, props)
  local c = {}
  local vp = self.viewport
  local vars = {}
  if parent and parent.vars then
    for k, v in pairs(parent.vars) do vars[k] = v end
  end
  for k, v in pairs(props) do
    if k:sub(1, 2) == '--' then vars[k] = v end
  end
  c.vars = vars

  local function raw(name)
    local v = props[name]
    if v == nil then return nil end
    v = resolveVars(v, vars)
    v = util.trim(v)
    if v == '' then return nil end
    return v
  end

  local ctx = {
    fontSize = parent and parent.fontSize or self.rootFontSize,
    rootFontSize = self.rootFontSize,
    vw = vp.w, vh = vp.h,
  }

  -- font-size first: everything em-relative depends on it
  local fsRaw = raw('font-size')
  local fs = parent and parent.fontSize or self.rootFontSize
  if fsRaw then
    if fsRaw == 'inherit' then
      fs = parent and parent.fontSize or fs
    elseif FONT_SIZE_KEYWORDS[fsRaw:lower()] then
      fs = FONT_SIZE_KEYWORDS[fsRaw:lower()]
    else
      local spec = style.parseLength(fsRaw, ctx)
      if spec then
        if spec.u == 'px' then
          fs = spec.n
        elseif spec.u == '%' then
          fs = (parent and parent.fontSize or fs) * spec.n / 100
        end
      end
    end
  end
  c.fontSize = fs
  ctx.fontSize = fs

  local function len(name, default)
    local v = raw(name)
    if not v then return default end
    if v == 'inherit' and parent then return parent[name] or default end
    return style.parseLength(v, ctx) or default
  end

  local function num(name, default)
    local v = raw(name)
    if not v then return default end
    return tonumber(v) or default
  end

  local function keyword(name, default, inheritValue)
    local v = raw(name)
    if not v then return default end
    v = v:lower()
    if v == 'inherit' then return inheritValue ~= nil and inheritValue or default end
    if v == 'initial' or v == 'unset' then return default end
    return v
  end

  local function col(name, default)
    local v = raw(name)
    if not v then return default end
    if v:lower() == 'currentcolor' then return c.color or default end
    if v:lower() == 'inherit' then return default end
    return color.parse(v) or default
  end

  -- inherited text properties -------------------------------------------
  local pInh = parent or INHERITED_DEFAULTS
  c.color = col('color', parent and parent.color or INHERITED_DEFAULTS.color)
  c.fontFamily = keyword('font-family', parent and parent.fontFamily or 'default')
  c.fontWeight = keyword('font-weight', parent and parent.fontWeight or 'normal')
  c.fontStyle = keyword('font-style', parent and parent.fontStyle or 'normal')
  c.textAlign = keyword('text-align', parent and parent.textAlign or 'left')
  c.whiteSpace = keyword('white-space', parent and parent.whiteSpace or 'normal')
  c.textTransform = keyword('text-transform', parent and parent.textTransform or 'none')
  c.cursor = keyword('cursor', parent and parent.cursor or 'default')
  c.visibility = keyword('visibility', parent and parent.visibility or 'visible')
  c.listStyle = keyword('list-style-type',
    keyword('list-style', parent and parent.listStyle or 'disc'))
  c.pointerEvents = keyword('pointer-events', parent and parent.pointerEvents or 'auto')
  do
    local ls = len('letter-spacing', nil)
    c.letterSpacing = ls and (ls.u == 'px' and ls.n or 0)
        or (parent and parent.letterSpacing or 0)
  end

  local lhRaw = raw('line-height')
  local lhFactor = parent and parent.lineHeightRaw or INHERITED_DEFAULTS.lineHeightRaw
  if lhRaw and lhRaw ~= 'inherit' then
    if lhRaw == 'normal' then
      lhFactor = 1.35
    elseif tonumber(lhRaw) then
      lhFactor = tonumber(lhRaw)
    else
      local spec = style.parseLength(lhRaw, ctx)
      if spec and spec.u == 'px' then
        lhFactor = spec.n / fs
      elseif spec and spec.u == '%' then
        lhFactor = spec.n / 100
      end
    end
  end
  c.lineHeightRaw = lhFactor
  c.lineHeight = lhFactor * fs
  c.textDecoration = keyword('text-decoration-line', keyword('text-decoration', 'none'))
  c.textOverflow = keyword('text-overflow', 'clip')
  c.verticalAlign = keyword('vertical-align', 'baseline')

  -- box ------------------------------------------------------------------
  c.display = keyword('display', 'inline')
  c.position = keyword('position', 'static')
  c.boxSizing = keyword('box-sizing', 'border-box')
  c.overflowX = keyword('overflow-x', 'visible')
  c.overflowY = keyword('overflow-y', 'visible')
  c.zIndex = tonumber(raw('z-index') or '') or 0
  c.opacity = num('opacity', 1)
  c.float = keyword('float', 'none')

  c.width = len('width', AUTO)
  c.height = len('height', AUTO)
  c.minWidth = len('min-width', nil)
  c.maxWidth = len('max-width', nil)
  c.minHeight = len('min-height', nil)
  c.maxHeight = len('max-height', nil)

  c.top = len('top', AUTO)
  c.right = len('right', AUTO)
  c.bottom = len('bottom', AUTO)
  c.left = len('left', AUTO)

  local zero = px(0)
  c.margin = {
    len('margin-top', zero), len('margin-right', zero),
    len('margin-bottom', zero), len('margin-left', zero),
  }
  c.padding = {
    len('padding-top', zero), len('padding-right', zero),
    len('padding-bottom', zero), len('padding-left', zero),
  }

  c.border, c.borderColor, c.borderStyle = {}, {}, {}
  for i, side in ipairs({ 'top', 'right', 'bottom', 'left' }) do
    local bs = keyword('border-' .. side .. '-style', 'none')
    local bw = len('border-' .. side .. '-width', px(0))
    local w = (bw.u == 'px') and bw.n or 0
    if bs == 'none' or bs == 'hidden' then w = 0 end
    c.borderStyle[i] = bs
    c.border[i] = w
    c.borderColor[i] = col('border-' .. side .. '-color', c.color)
  end

  c.radius = {}
  for i, corner in ipairs({ 'top-left', 'top-right', 'bottom-right', 'bottom-left' }) do
    local r = len('border-' .. corner .. '-radius', px(0))
    c.radius[i] = (r.u == 'px') and r.n or 0
  end

  c.backgroundColor = col('background-color', nil)
  local bgImage = raw('background-image')
  c.backgroundImage = bgImage and parseGradient(bgImage, ctx) or nil
  if bgImage and not c.backgroundImage then
    local url = bgImage:match('^url%(%s*["\']?(.-)["\']?%s*%)$')
    if url then c.backgroundImage = { type = 'image', src = url } end
  end
  c.backgroundSize = keyword('background-size', 'auto')

  c.boxShadow = parseShadow(raw('box-shadow') or '', ctx)
  c.transform = parseTransform(raw('transform'), ctx)
  c.transition = parseTransition(raw('transition'), ctx)

  -- flex / grid ----------------------------------------------------------
  c.flexDirection = keyword('flex-direction', 'row')
  c.flexWrap = keyword('flex-wrap', 'nowrap')
  c.justifyContent = ALIGN_ALIAS[keyword('justify-content', 'flex-start')] or 'flex-start'
  c.alignItems = ALIGN_ALIAS[keyword('align-items', 'stretch')] or 'stretch'
  c.alignContent = ALIGN_ALIAS[keyword('align-content', 'flex-start')] or 'flex-start'
  c.alignSelf = keyword('align-self', 'auto')
  c.flexGrow = num('flex-grow', 0)
  c.flexShrink = num('flex-shrink', 1)
  c.flexBasis = len('flex-basis', AUTO)
  c.order = num('order', 0)
  do
    local rg = len('row-gap', px(0))
    local cg = len('column-gap', px(0))
    c.rowGap = (rg.u == 'px') and rg.n or 0
    c.columnGap = (cg.u == 'px') and cg.n or 0
  end
  local gtc = raw('grid-template-columns')
  if gtc then
    local list = {}
    local rep, body = gtc:match('^repeat%(%s*(%d+)%s*,%s*(.-)%s*%)$')
    if rep then
      for _ = 1, tonumber(rep) do
        for _, t in ipairs(util.words(body)) do
          list[#list + 1] = style.parseLength(t, ctx) or { n = 1, u = 'fr' }
        end
      end
    else
      for _, t in ipairs(util.words(gtc)) do
        list[#list + 1] = style.parseLength(t, ctx) or { n = 1, u = 'fr' }
      end
    end
    c.gridTemplateColumns = list
  end

  c.node = node
  return c
end

-- --------------------------------------------------------- transitions ----

function Engine:applyTransitions(node, c)
  local list = c.transition
  local store = node._transitions
  if not list and not store then return end
  local now = self.now or 0

  if list then
    store = store or {}
    node._transitions = store
    local expanded = {}
    for _, t in ipairs(list) do
      if t.prop == 'all' then
        for name in pairs(ANIM) do
          expanded[name] = t
        end
      elseif ANIM[t.prop] then
        expanded[t.prop] = t
      end
    end
    for prop, t in pairs(expanded) do
      local def = ANIM[prop]
      local target = def.get(c)
      local slot = store[prop]
      if target ~= nil then
        if not slot then
          store[prop] = { current = target, target = target, from = target, t0 = now, def = def }
        else
          if not sameValue(def.kind, slot.target, target) then
            slot.from = slot.current
            slot.target = target
            slot.t0 = now + (t.delay or 0)
            slot.dur = t.dur
            slot.ease = t.ease
          end
          local dur = slot.dur or t.dur or 0
          if dur > 0 and slot.from ~= nil then
            local p = (now - slot.t0) / dur
            if p < 0 then p = 0 end
            if p >= 1 then
              slot.current = slot.target
            else
              local ease = EASINGS[slot.ease or 'ease'] or EASINGS.ease
              slot.current = mixValue(def.kind, slot.from, slot.target, ease(p))
              self.animating = true
            end
          else
            slot.current = slot.target
          end
          def.set(c, slot.current)
        end
      end
    end
  end
end

-- ------------------------------------------------------------- restyle ----

--- Recompute styles for the whole tree. Cheap enough to run when dirty,
-- and every frame while a transition is in flight.
function Engine:restyle(root, now)
  self.now = now or 0
  self.animating = false
  local function visit(node, parentComputed)
    if node.type == 'text' then
      node.computed = parentComputed
      return
    end
    if node.type == 'comment' then return end
    local computed
    if node.type == 'document' then
      computed = parentComputed
    else
      local props = self:cascade(node)
      if parentComputed == nil then
        -- the topmost element defines what `rem` means, like <html> does
        local fs = props['font-size']
        if fs then
          local spec = style.parseLength(fs, {
            fontSize = self.rootFontSize, rootFontSize = self.rootFontSize,
            vw = self.viewport.w, vh = self.viewport.h,
          })
          if spec and spec.u == 'px' then self.rootFontSize = spec.n end
        end
      end
      computed = self:compute(node, parentComputed, props)
      self:applyTransitions(node, computed)
      node.computed = computed
    end
    if computed and computed.display == 'none' then
      node.hidden = true
      return
    end
    node.hidden = false
    for _, child in ipairs(node.children) do visit(child, computed) end
  end
  visit(root, nil)
  return self.animating
end

style.parseGradient = parseGradient
style.EASINGS = EASINGS

return style
