-- moonhtml/layout.lua -- box generation + block / inline / flex / grid layout.
--
-- Coordinates: every box gets `x`,`y` relative to its containing block's
-- content origin during layout; a final pass fills in absolute `ax`,`ay`
-- (scroll offsets and transforms applied) for painting and hit-testing.

local util = require 'moonhtml.util'
local style = require 'moonhtml.style'

local layout = {}

local max, min, floor = math.max, math.min, math.floor
local resolve, isAuto = style.resolve, style.isAuto

local SCROLLBAR = 10

local BLOCK_DISPLAYS = {
  block = true, flex = true, grid = true, ['list-item'] = true, table = true,
}
local INLINE_DISPLAYS = {
  inline = true, ['inline-block'] = true, ['inline-flex'] = true,
}

--- Widgets that are atomic: they never contain flow content of their own.
local REPLACED = {
  input = true, img = true, progress = true, select = true, textarea = true,
  canvas = true, svg = true,
}

local function isReplaced(node)
  return node.type == 'element' and REPLACED[node.tag] == true
end

local function isPositioned(st)
  return st.position == 'absolute' or st.position == 'fixed'
end

-- --------------------------------------------------------------- boxes ----

local function newBox(node, st, kind)
  return {
    node = node, style = st, kind = kind, children = {},
    x = 0, y = 0, w = 0, h = 0,
    padding = { 0, 0, 0, 0 }, border = { 0, 0, 0, 0 }, margin = { 0, 0, 0, 0 },
  }
end

local function metrics(box, cbWidth)
  local st = box.style
  local m, p, b = {}, {}, {}
  for i = 1, 4 do
    m[i] = resolve(st.margin[i], cbWidth) or 0
    p[i] = resolve(st.padding[i], cbWidth) or 0
    b[i] = st.border[i] or 0
  end
  box.margin, box.padding, box.border = m, p, b
  box.frameW = p[2] + p[4] + b[2] + b[4]
  box.frameH = p[1] + p[3] + b[1] + b[3]
end

local function clampWidth(st, w, cbWidth)
  local mn = resolve(st.minWidth, cbWidth)
  local mx = resolve(st.maxWidth, cbWidth)
  if mx and w > mx then w = mx end
  if mn and w < mn then w = mn end
  return max(0, w)
end

local function clampHeight(st, h, cbHeight)
  local mn = resolve(st.minHeight, cbHeight)
  local mx = resolve(st.maxHeight, cbHeight)
  if mx and h > mx then h = mx end
  if mn and h < mn then h = mn end
  return max(0, h)
end

-- --------------------------------------------------------------- text -----

local function transformText(text, st)
  local tt = st.textTransform
  if tt == 'uppercase' then return text:upper() end
  if tt == 'lowercase' then return text:lower() end
  if tt == 'capitalize' then
    return (text:gsub('(%S+)', function(w) return w:sub(1, 1):upper() .. w:sub(2) end))
  end
  return text
end

local function measure(ctx, text, st)
  if text == '' then return 0 end
  local key = st.fontFamily .. '\1' .. st.fontSize .. '\1' ..
      tostring(st.fontWeight) .. '\1' .. tostring(st.letterSpacing) .. '\1' .. text
  local cached = ctx.cache[key]
  if cached then return cached end
  local w = ctx.measure(text, st)
  if st.letterSpacing and st.letterSpacing ~= 0 then
    w = w + st.letterSpacing * util.utf8len(text)
  end
  ctx.cache[key] = w
  return w
end
layout.measure = measure

--- Break a text node into inline items according to white-space.
local function textItems(node, st, ctx, out)
  local text = transformText(node.text or '', st)
  if text == '' then return end
  local ws = st.whiteSpace
  local pre = (ws == 'pre' or ws == 'pre-wrap')
  if not pre then
    text = text:gsub('[\n\r\t]', ' ')
    if not text:find('%S') then
      -- pure whitespace between inline content collapses to one space
      if #out > 0 and out[#out].type ~= 'space' then
        out[#out + 1] = { type = 'space', style = st, node = node,
          w = measure(ctx, ' ', st), h = st.lineHeight }
      end
      return
    end
    local leading = text:sub(1, 1) == ' '
    local trailing = text:sub(-1) == ' '
    if leading and #out > 0 and out[#out].type ~= 'space' then
      out[#out + 1] = { type = 'space', style = st, node = node,
        w = measure(ctx, ' ', st), h = st.lineHeight }
    end
    for word in text:gmatch('%S+') do
      out[#out + 1] = { type = 'word', text = word, style = st, node = node,
        w = measure(ctx, word, st), h = st.lineHeight }
      out[#out + 1] = { type = 'space', style = st, node = node,
        w = measure(ctx, ' ', st), h = st.lineHeight }
    end
    if not trailing and out[#out] and out[#out].type == 'space' then
      table.remove(out) -- drop the trailing separator we just added
    end
  else
    local first = true
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
      if not first then out[#out + 1] = { type = 'break', style = st, node = node } end
      first = false
      if ws == 'pre-wrap' then
        for chunk in line:gmatch('%S+ *') do
          out[#out + 1] = { type = 'word', text = chunk, style = st, node = node,
            w = measure(ctx, chunk, st), h = st.lineHeight }
        end
      elseif line ~= '' then
        out[#out + 1] = { type = 'word', text = line, style = st, node = node,
          w = measure(ctx, line, st), h = st.lineHeight }
      end
    end
    if out[#out] and out[#out].type == 'break' then table.remove(out) end
  end
end

-- ------------------------------------------------------ intrinsic sizes ----

local layoutBox -- forward declaration

local function intrinsicWidth(node, st, ctx, mode)
  if not st then return 0 end
  if node.type == 'text' then
    local text = transformText(node.text or '', st)
    if not st.whiteSpace or st.whiteSpace == 'normal' or st.whiteSpace == 'nowrap' then
      text = text:gsub('%s+', ' ')
    end
    if mode == 'min' then
      local w = 0
      for word in text:gmatch('%S+') do w = max(w, measure(ctx, word, st)) end
      return w
    end
    return measure(ctx, text, st)
  end
  if node.type ~= 'element' or node.hidden then return 0 end

  local key = tostring(node) .. mode
  local cached = ctx.intrinsic[key]
  if cached then return cached end

  local result
  local w = resolve(st.width, nil)
  if w then
    result = w + (st.boxSizing == 'border-box' and 0
      or ((resolve(st.padding[2], 0) or 0) + (resolve(st.padding[4], 0) or 0)
        + st.border[2] + st.border[4]))
  else
    local inner = 0
    if isReplaced(node) then
      inner = ctx.replacedWidth and ctx.replacedWidth(node, st) or 0
    elseif st.display == 'flex' or st.display == 'inline-flex' then
      local row = st.flexDirection:sub(1, 3) == 'row'
      local n = 0
      for _, child in ipairs(node.children) do
        if child.computed and not child.hidden and not isPositioned(child.computed) then
          local cw = intrinsicWidth(child, child.computed, ctx, mode)
              + (resolve(child.computed.margin[2], 0) or 0)
              + (resolve(child.computed.margin[4], 0) or 0)
          if row then inner = inner + cw else inner = max(inner, cw) end
          n = n + 1
        end
      end
      if row and n > 1 then inner = inner + st.columnGap * (n - 1) end
    else
      -- block-ish: inline children accumulate on a line, blocks stack
      local lineW = 0
      for _, child in ipairs(node.children) do
        local cst = child.computed
        -- text nodes borrow their parent's computed style, so the "is this
        -- out of flow?" test only makes sense for elements
        if cst and not child.hidden
            and (child.type ~= 'element' or not isPositioned(cst)) then
          local cw = intrinsicWidth(child, cst, ctx, mode)
          if child.type == 'element' then
            cw = cw + (resolve(cst.margin[2], 0) or 0) + (resolve(cst.margin[4], 0) or 0)
          end
          if child.type == 'text' or INLINE_DISPLAYS[cst.display] then
            if mode == 'min' then
              inner = max(inner, cw)
            else
              lineW = lineW + cw
            end
          else
            inner = max(inner, lineW, cw)
            lineW = 0
          end
        end
      end
      inner = max(inner, lineW)
    end
    result = inner + (resolve(st.padding[2], 0) or 0) + (resolve(st.padding[4], 0) or 0)
        + st.border[2] + st.border[4]
  end

  local mn = resolve(st.minWidth, nil)
  local mx = resolve(st.maxWidth, nil)
  if mx and result > mx then result = mx end
  if mn and result < mn then result = mn end
  ctx.intrinsic[key] = result
  return result
end
layout.intrinsicWidth = intrinsicWidth

-- ------------------------------------------------------- inline layout ----

--- Collect inline items from `node`'s children (flattening inline elements).
-- `stack` carries the chain of inline ancestors so that backgrounds, borders
-- and hit-testing can be reconstructed per line afterwards.
local function collectInline(node, ctx, out, avail, stack)
  for _, child in ipairs(node.children) do
    local st = child.computed
    if child.type == 'text' and st then
      local before = #out
      textItems(child, st, ctx, out)
      if stack then
        for i = before + 1, #out do out[i].inlines = stack end
      end
    elseif child.type == 'element' and st and not child.hidden then
      if isPositioned(st) then
        ctx.pending[#ctx.pending + 1] = child
      elseif child.tag == 'br' then
        out[#out + 1] = { type = 'break', style = st, node = child, inlines = stack }
      elseif st.display == 'inline' and not isReplaced(child) then
        local inner = {}
        for i = 1, (stack and #stack or 0) do inner[i] = stack[i] end
        inner[#inner + 1] = child
        local padL = resolve(st.padding[4], avail) or 0
        local padR = resolve(st.padding[2], avail) or 0
        local startIdx = #out + 1
        if padL > 0 then
          out[#out + 1] = { type = 'pad', w = padL, h = 0, style = st,
            node = child, inlines = inner }
        end
        collectInline(child, ctx, out, avail, inner)
        if padR > 0 then
          out[#out + 1] = { type = 'pad', w = padR, h = 0, style = st,
            node = child, inlines = inner }
        end
        out[#out + 1] = { type = 'inline-end', node = child, startIdx = startIdx }
      else
        -- atomic inline: inline-block, replaced element, or a stray block
        local box = layoutBox(child, st, ctx, { avail = avail, shrink = true })
        out[#out + 1] = {
          type = 'atomic', box = box, style = st, node = child, inlines = stack,
          w = box.w + box.margin[2] + box.margin[4],
          h = box.h + box.margin[1] + box.margin[3],
        }
      end
    end
  end
end

local function itemBaseline(item)
  if item.type == 'pad' then return 0 end
  if item.type == 'atomic' then
    local va = item.style.verticalAlign
    if va == 'middle' then return item.h * 0.5 + item.style.fontSize * 0.32 end
    if va == 'top' then return 0 end
    return item.h -- baseline sits on the bottom margin edge
  end
  local st = item.style
  local leading = (st.lineHeight - st.fontSize) * 0.5
  return leading + st.fontSize * 0.8
end

--- Lay out inline items into line boxes inside `width`. Returns lines, height.
local function layoutLines(items, width, st, ctx)
  local lines, line = {}, { items = {}, w = 0, h = 0, baseline = 0 }
  local wrap = st.whiteSpace ~= 'nowrap' and st.whiteSpace ~= 'pre'
  local pendingSpace = nil

  local function pushLine(forced)
    line.forced = forced
    lines[#lines + 1] = line
    line = { items = {}, w = 0, h = 0, baseline = 0 }
    pendingSpace = nil
  end

  local function place(item)
    local bl = itemBaseline(item)
    item.baseline = bl
    line.items[#line.items + 1] = item
    item.lineX = line.w
    line.w = line.w + item.w
    line.baseline = max(line.baseline, bl)
    line.descent = max(line.descent or 0, (item.h or 0) - bl)
  end

  for _, item in ipairs(items) do
    if item.type == 'break' then
      if pendingSpace then pendingSpace = nil end
      pushLine(true)
    elseif item.type == 'inline-end' then
      line.items[#line.items + 1] = item -- marker, zero size
    elseif item.type == 'space' then
      if #line.items > 0 then pendingSpace = item end
    else
      local needed = item.w + (pendingSpace and pendingSpace.w or 0)
      if wrap and #line.items > 0 and line.w + needed > width + 0.01 then
        pushLine(false)
      elseif pendingSpace then
        place(pendingSpace)
        pendingSpace = nil
      end
      place(item)
    end
  end
  if #line.items > 0 then pushLine(true) end

  -- vertical placement: centre the content of each line inside its height
  local y, minLine = 0, st.lineHeight
  for _, ln in ipairs(lines) do
    local content = ln.baseline + (ln.descent or 0)
    local h = max(content, minLine)
    if #ln.items == 0 then
      h = minLine
      ln.baseline = minLine * 0.8
    elseif h > content then
      ln.baseline = ln.baseline + (h - content) * 0.5
    end
    ln.y = y
    ln.h = h
    y = y + h
  end
  return lines, y
end

local function alignLines(lines, width, align)
  for _, ln in ipairs(lines) do
    local dx = 0
    if align == 'center' then
      dx = (width - ln.w) * 0.5
    elseif align == 'right' or align == 'end' then
      dx = width - ln.w
    end
    if dx < 0 then dx = 0 end
    ln.x = dx
    for _, item in ipairs(ln.items) do
      if item.lineX then -- markers (inline-end) carry no geometry
        item.x = dx + item.lineX
        if item.type == 'atomic' then
          item.box.x = item.x + item.box.margin[4]
        end
      end
    end
  end
end

-- --------------------------------------------------------- flex layout ----

local function flexItems(node)
  local items = {}
  for _, child in ipairs(node.children) do
    local st = child.computed
    if child.type == 'element' and st and not child.hidden and not isPositioned(st) then
      items[#items + 1] = child
    elseif child.type == 'text' and st and (child.text or ''):find('%S') then
      items[#items + 1] = child -- anonymous flex item
    end
  end
  -- stable sort by `order`: table.sort is not stable, and equal keys would
  -- otherwise shuffle document order (every item defaults to order 0)
  for i, item in ipairs(items) do item._flexIndex = i end
  table.sort(items, function(a, b)
    local ao = a.computed and a.computed.order or 0
    local bo = b.computed and b.computed.order or 0
    if ao ~= bo then return ao < bo end
    return a._flexIndex < b._flexIndex
  end)
  return items
end

local function layoutFlex(box, ctx, cw, ch)
  local st = box.style
  local row = st.flexDirection == 'row' or st.flexDirection == 'row-reverse'
  local reverse = st.flexDirection:find('reverse') ~= nil
  local mainSize = row and cw or (ch or 0)
  local gapMain = row and st.columnGap or st.rowGap
  local gapCross = row and st.rowGap or st.columnGap
  local items = flexItems(box.node)

  -- 1. base sizes
  local entries = {}
  for _, child in ipairs(items) do
    local cst = child.computed
    local e = { node = child, style = cst }
    if child.type == 'text' then
      e.text = true
      e.base = measure(ctx, transformText(child.text, cst), cst)
      e.grow, e.shrink = 0, 1
      e.crossAuto = true
    else
      local basis = cst.flexBasis
      local mainLen = row and cst.width or cst.height
      local basisLen = (basis and basis.u ~= 'auto') and basis or mainLen
      local resolved = resolve(basisLen, row and cw or ch)
      if resolved then
        e.base = resolved
      elseif row then
        e.base = intrinsicWidth(child, cst, ctx, 'max')
      else
        local probe = layoutBox(child, cst, ctx, { avail = cw, forceWidth = nil })
        e.base = probe.h
        e.probe = probe
      end
      e.grow = cst.flexGrow or 0
      e.shrink = cst.flexShrink == nil and 1 or cst.flexShrink
      -- automatic minimum size: a flex item does not shrink below its own
      -- content unless it scrolls/clips (min-*: auto in the spec)
      local overflowMain = row and cst.overflowX or cst.overflowY
      if overflowMain ~= 'visible' then
        e.minMain = 0
      elseif row then
        e.minMain = min(e.base, intrinsicWidth(child, cst, ctx, 'min'))
      else
        e.minMain = e.base
      end
      e.marginMain = row and ((resolve(cst.margin[4], cw) or 0) + (resolve(cst.margin[2], cw) or 0))
          or ((resolve(cst.margin[1], cw) or 0) + (resolve(cst.margin[3], cw) or 0))
      e.marginCross = row and ((resolve(cst.margin[1], cw) or 0) + (resolve(cst.margin[3], cw) or 0))
          or ((resolve(cst.margin[4], cw) or 0) + (resolve(cst.margin[2], cw) or 0))
      -- `margin-left: auto` in a flex row is the idiomatic "push me right"
      e.autoStart = (row and cst.margin[4] or cst.margin[1]).u == 'auto'
      e.autoEnd = (row and cst.margin[2] or cst.margin[3]).u == 'auto'
    end
    e.marginMain = e.marginMain or 0
    e.marginCross = e.marginCross or 0
    e.outer = e.base + e.marginMain
    entries[#entries + 1] = e
  end

  -- 2. split into lines
  local lines = {}
  if st.flexWrap == 'wrap' or st.flexWrap == 'wrap-reverse' then
    local cur, curW = {}, 0
    for _, e in ipairs(entries) do
      local add = e.outer + (#cur > 0 and gapMain or 0)
      if #cur > 0 and curW + add > mainSize + 0.01 then
        lines[#lines + 1] = { entries = cur, width = curW }
        cur, curW = {}, 0
        add = e.outer
      end
      cur[#cur + 1] = e
      curW = curW + add
    end
    if #cur > 0 then lines[#lines + 1] = { entries = cur, width = curW } end
  else
    local total = 0
    for i, e in ipairs(entries) do total = total + e.outer + (i > 1 and gapMain or 0) end
    lines[1] = { entries = entries, width = total }
  end

  -- 3. resolve flexible lengths per line
  --
  -- Distribute, clamp, freeze whatever hit a limit, repeat. A single pass is
  -- not enough: clamping one item hands its leftover space back to the others,
  -- which is what keeps a footer from being pushed out of a full-height column.
  for _, ln in ipairs(lines) do
    local n = #ln.entries
    local totalGap = gapMain * max(0, n - 1)
    for _, e in ipairs(ln.entries) do
      e.main = e.base
      e.frozen = false
      local mn = e.style and resolve(row and e.style.minWidth or e.style.minHeight, mainSize)
      local mx = e.style and resolve(row and e.style.maxWidth or e.style.maxHeight, mainSize)
      e.lowerMain = mn or e.minMain or 0
      e.upperMain = mx or math.huge
      if e.lowerMain > e.upperMain then e.lowerMain = e.upperMain end
      e.main = util.clamp(e.main, e.lowerMain, e.upperMain)
    end

    for _ = 1, n + 1 do
      local total = totalGap
      for _, e in ipairs(ln.entries) do total = total + e.main + e.marginMain end
      local free = mainSize - total
      if math.abs(free) < 0.01 then break end

      local pool, weight = {}, 0
      for _, e in ipairs(ln.entries) do
        if not e.frozen then
          local w = (free > 0) and (e.grow or 0) or ((e.shrink or 1) * e.base)
          if w > 0 then
            pool[#pool + 1] = { e = e, w = w }
            weight = weight + w
          end
        end
      end
      if weight <= 0 then break end

      local violated = false
      for _, item in ipairs(pool) do
        local e = item.e
        local want = e.main + free * (item.w / weight)
        local clamped = util.clamp(want, e.lowerMain, e.upperMain)
        if math.abs(clamped - want) > 0.01 then
          e.frozen = true
          violated = true
        end
        e.main = clamped
      end
      if not violated then break end
    end
  end

  -- 4. lay out items with their resolved main size, measure cross sizes
  local crossTotal = 0
  for li, ln in ipairs(lines) do
    local lineCross = 0
    for _, e in ipairs(ln.entries) do
      if e.text then
        e.cross = e.style.lineHeight
        e.box = nil
      else
        local opts = { avail = cw }
        if row then
          opts.forceWidth = e.main
          local alignSelf = e.style.alignSelf
          if alignSelf == 'auto' then alignSelf = st.alignItems end
          if alignSelf == 'stretch' and ch and isAuto(e.style.height)
              and st.flexWrap == 'nowrap' then
            opts.forceHeight = max(0, ch - e.marginCross)
          end
        else
          opts.forceHeight = e.main
          local alignSelf = e.style.alignSelf
          if alignSelf == 'auto' then alignSelf = st.alignItems end
          if alignSelf == 'stretch' and isAuto(e.style.width) then
            opts.forceWidth = max(0, cw - e.marginCross)
          end
        end
        e.box = layoutBox(e.node, e.style, ctx, opts)
        e.main = row and e.box.w or e.box.h
      end
      e.cross = e.cross or (row and (e.box.h + e.marginCross) or (e.box.w + e.marginCross))
      lineCross = max(lineCross, e.cross)
    end
    ln.cross = lineCross
    crossTotal = crossTotal + lineCross + (li > 1 and gapCross or 0)
  end

  -- 5. position
  local containerCross = row and (ch or crossTotal) or cw
  -- a single flex line always spans the container's cross size, which is what
  -- makes align-items work in a column container
  if #lines == 1 and containerCross > lines[1].cross then
    lines[1].cross = containerCross
  end
  local crossPos = 0
  if #lines > 1 and containerCross > crossTotal then
    local extra = containerCross - crossTotal
    if st.alignContent == 'center' then
      crossPos = extra * 0.5
    elseif st.alignContent == 'flex-end' then
      crossPos = extra
    elseif st.alignContent == 'stretch' then
      for _, ln in ipairs(lines) do ln.cross = ln.cross + extra / #lines end
    end
  end

  for _, ln in ipairs(lines) do
    local used = 0
    for i, e in ipairs(ln.entries) do
      used = used + (row and (e.box and e.box.w or e.main) or (e.box and e.box.h or e.cross))
          + e.marginMain + (e.autoStartSize or 0) + (e.autoEndSize or 0)
          + (i > 1 and gapMain or 0)
    end
    local free = max(0, mainSize - used)
    local pos, spacing = 0, 0
    local justify = st.justifyContent
    local n = #ln.entries

    -- auto margins take what is left before justify-content sees it
    local autoCount = 0
    for _, e in ipairs(ln.entries) do
      if e.autoStart then autoCount = autoCount + 1 end
      if e.autoEnd then autoCount = autoCount + 1 end
    end
    if autoCount > 0 and free > 0 then
      local share = free / autoCount
      for _, e in ipairs(ln.entries) do
        e.autoStartSize = e.autoStart and share or 0
        e.autoEndSize = e.autoEnd and share or 0
      end
      free = 0
    end
    if justify == 'center' then
      pos = free * 0.5
    elseif justify == 'flex-end' then
      pos = free
    elseif justify == 'space-between' and n > 1 then
      spacing = free / (n - 1)
    elseif justify == 'space-around' and n > 0 then
      spacing = free / n
      pos = spacing * 0.5
    elseif justify == 'space-evenly' and n > 0 then
      spacing = free / (n + 1)
      pos = spacing
    end

    local order = {}
    for i = 1, n do order[i] = ln.entries[reverse and (n - i + 1) or i] end

    for i, e in ipairs(order) do
      local mainLen = row and (e.box and e.box.w or e.main) or (e.box and e.box.h or e.cross)
      local alignSelf = e.style and e.style.alignSelf or 'auto'
      if alignSelf == 'auto' then alignSelf = st.alignItems end
      local crossLen = row and (e.box and e.box.h or e.cross) or (e.box and e.box.w or 0)
      local crossOff = 0
      if alignSelf == 'center' then
        crossOff = (ln.cross - crossLen - e.marginCross) * 0.5
      elseif alignSelf == 'flex-end' then
        crossOff = ln.cross - crossLen - e.marginCross
      end
      if crossOff < 0 then crossOff = 0 end

      local mMainStart = row and (resolve(e.style and e.style.margin[4], cw) or 0)
          or (resolve(e.style and e.style.margin[1], cw) or 0)
      local mCrossStart = row and (resolve(e.style and e.style.margin[1], cw) or 0)
          or (resolve(e.style and e.style.margin[4], cw) or 0)

      local mainPos = pos + mMainStart + (e.autoStartSize or 0)
      local crossAbs = crossPos + crossOff + mCrossStart
      if e.box then
        if row then
          e.box.x, e.box.y = mainPos, crossAbs
        else
          e.box.x, e.box.y = crossAbs, mainPos
        end
        box.children[#box.children + 1] = e.box
      else
        -- anonymous text flex item
        local tbox = newBox(e.node, e.style, 'text-run')
        tbox.w, tbox.h = e.main, e.style.lineHeight
        tbox.text = transformText(e.node.text, e.style)
        if row then tbox.x, tbox.y = mainPos, crossAbs else tbox.x, tbox.y = crossAbs, mainPos end
        box.children[#box.children + 1] = tbox
      end
      pos = pos + mainLen + e.marginMain + (e.autoStartSize or 0) + (e.autoEndSize or 0)
          + spacing + (i < n and gapMain or 0)
    end
    crossPos = crossPos + ln.cross + gapCross
  end

  local contentMain, contentCross = 0, max(0, crossPos - gapCross)
  for _, ln in ipairs(lines) do contentMain = max(contentMain, ln.width) end
  if row then
    return max(contentMain, 0), contentCross
  end
  return contentCross, max(contentMain, 0)
end

-- --------------------------------------------------------- grid layout ----

local function layoutGrid(box, ctx, cw)
  local st = box.style
  local cols = st.gridTemplateColumns or { { n = 1, u = 'fr' } }
  local gapX, gapY = st.columnGap, st.rowGap
  local n = #cols
  local fixed, frTotal = 0, 0
  local widths = {}
  for i, spec in ipairs(cols) do
    if spec.u == 'fr' then
      frTotal = frTotal + spec.n
      widths[i] = false
    else
      widths[i] = resolve(spec, cw) or 0
      fixed = fixed + widths[i]
    end
  end
  local free = max(0, cw - fixed - gapX * (n - 1))
  for i, spec in ipairs(cols) do
    if widths[i] == false then
      widths[i] = frTotal > 0 and (free * spec.n / frTotal) or 0
    end
  end

  local items = flexItems(box.node)
  local y, col, rowH, rowBoxes = 0, 1, 0, {}
  local function flushRow()
    for _, b in ipairs(rowBoxes) do
      local as = b.style.alignSelf
      if as == 'auto' then as = st.alignItems end
      if as == 'stretch' and isAuto(b.style.height) then
        b.h = rowH - (b.margin[1] + b.margin[3])
      elseif as == 'center' then
        b.y = b.y + (rowH - b.h - b.margin[1] - b.margin[3]) * 0.5
      elseif as == 'flex-end' then
        b.y = b.y + (rowH - b.h - b.margin[1] - b.margin[3])
      end
    end
    y = y + rowH + gapY
    rowH, rowBoxes, col = 0, {}, 1
  end

  local x = 0
  for _, child in ipairs(items) do
    if child.type == 'element' then
      local cst = child.computed
      local span = tonumber(child:getAttribute('colspan', '')) or 1
      span = min(max(1, span), n)
      local w = 0
      for k = col, min(n, col + span - 1) do w = w + widths[k] end
      w = w + gapX * (span - 1)
      local cbox = layoutBox(child, cst, ctx, { avail = w, forceWidth = w - (
        (resolve(cst.margin[2], cw) or 0) + (resolve(cst.margin[4], cw) or 0)) })
      cbox.x = x + (resolve(cst.margin[4], cw) or 0)
      cbox.y = y + (resolve(cst.margin[1], cw) or 0)
      box.children[#box.children + 1] = cbox
      rowBoxes[#rowBoxes + 1] = cbox
      rowH = max(rowH, cbox.h + cbox.margin[1] + cbox.margin[3])
      x = x + w + gapX
      col = col + span
      if col > n then
        flushRow()
        x = 0
      end
    end
  end
  if #rowBoxes > 0 then flushRow() end
  return cw, max(0, y - gapY)
end

-- ------------------------------------------------------- block container ----

local function layoutChildren(box, ctx, cw, ch)
  local st = box.style
  local node = box.node
  local display = st.display

  if display == 'flex' or display == 'inline-flex' then
    return layoutFlex(box, ctx, cw, ch)
  elseif display == 'grid' then
    return layoutGrid(box, ctx, cw)
  end

  -- block formatting context with inline runs
  local y, contentW = 0, 0
  local inline = {}

  local function flushInline()
    if #inline == 0 then return end
    local lines, height = layoutLines(inline, cw, st, ctx)
    alignLines(lines, cw, st.textAlign)
    for _, ln in ipairs(lines) do
      ln.y = ln.y + y
      local seen = nil
      for _, item in ipairs(ln.items) do
        if item.type == 'atomic' then
          item.box.y = ln.y + ln.baseline - item.baseline + item.box.margin[1]
          box.children[#box.children + 1] = item.box
        end
        contentW = max(contentW, (item.x or 0) + (item.w or 0))
        -- remember the horizontal span each inline ancestor covers on this
        -- line, so <a>/<code>/<span> can paint a background and be clicked
        if item.inlines and item.x then
          seen = seen or {}
          for _, el in ipairs(item.inlines) do
            local d = seen[el]
            if not d then
              d = { node = el, style = el.computed, ln = ln,
                x0 = item.x, x1 = item.x + (item.w or 0) }
              seen[el] = d
              box.inlineDecorations[#box.inlineDecorations + 1] = d
            else
              d.x0 = min(d.x0, item.x)
              d.x1 = max(d.x1, item.x + (item.w or 0))
            end
          end
        end
      end
      box.lines[#box.lines + 1] = ln
    end
    for i = #box.inlineDecorations, 1, -1 do
      local d = box.inlineDecorations[i]
      if d.w == nil then
        local est = d.style
        local padT = resolve(est.padding[1], cw) or 0
        local padB = resolve(est.padding[3], cw) or 0
        d.x, d.w = d.x0, d.x1 - d.x0
        d.y = d.ln.baseline - est.fontSize * 0.98 - padT
        d.h = est.fontSize * 1.28 + padT + padB
      end
    end
    y = y + height
    inline = {}
  end

  for _, child in ipairs(node.children) do
    local cst = child.computed
    if child.type == 'comment' or not cst or child.hidden then
      -- skipped
    elseif child.type == 'text' then
      if (child.text or ''):find('%S') or #inline > 0 then
        textItems(child, cst, ctx, inline)
      end
    elseif isPositioned(cst) then
      ctx.pending[#ctx.pending + 1] = { node = child, box = box }
    elseif INLINE_DISPLAYS[cst.display] or child.tag == 'br' then
      collectInline({ children = { child } }, ctx, inline, cw)
    else
      flushInline()
      local mt = resolve(cst.margin[1], cw) or 0
      local mb = resolve(cst.margin[3], cw) or 0
      local ml = resolve(cst.margin[4], cw) or 0
      local mr = resolve(cst.margin[2], cw) or 0
      local avail = max(0, cw - ml - mr)
      local cbox = layoutBox(child, cst, ctx, { avail = avail })
      cbox.x = ml
      cbox.y = y + mt
      if isAuto(cst.width) == false and (cst.margin[4].u == 'auto' or cst.margin[2].u == 'auto') then
        cbox.x = ml + max(0, (avail - cbox.w) * 0.5) -- margin:auto centring
      end
      box.children[#box.children + 1] = cbox
      y = cbox.y + cbox.h + mb
      contentW = max(contentW, cbox.x + cbox.w + mr)
    end
  end
  flushInline()
  return contentW, y
end

-- ------------------------------------------------------------ main box ----

--- Lay out one element into a box.
-- opts: { avail = containing block content width,
--         forceWidth / forceHeight = definite border-box size,
--         shrink = shrink-to-fit width }
layoutBox = function(node, st, ctx, opts)
  opts = opts or {}
  local avail = opts.avail or ctx.vw
  local kind = st.display
  local box = newBox(node, st, kind)
  box.lines = {}
  box.inlineDecorations = {}
  node.box = box
  metrics(box, avail)

  -- ---- width -----------------------------------------------------------
  local w
  if opts.forceWidth then
    w = opts.forceWidth
  else
    local specified = resolve(st.width, avail)
    if specified then
      w = specified
      if st.boxSizing ~= 'border-box' then w = w + box.frameW end
    elseif opts.shrink or INLINE_DISPLAYS[st.display] or isReplaced(node) then
      local pref = intrinsicWidth(node, st, ctx, 'max')
      w = min(pref, max(0, avail))
      if isReplaced(node) then w = pref end
    else
      w = max(0, avail - box.margin[2] - box.margin[4])
    end
  end
  w = clampWidth(st, w, avail)
  local cw = max(0, w - box.frameW)

  -- ---- height ----------------------------------------------------------
  local specifiedH = resolve(st.height, opts.cbHeight or ctx.parentHeight)
  local ch = nil
  if opts.forceHeight then
    ch = max(0, opts.forceHeight - box.frameH)
  elseif specifiedH then
    ch = max(0, (st.boxSizing == 'border-box') and (specifiedH - box.frameH) or specifiedH)
  end

  box.w = w
  box.contentW = cw

  -- ---- content ---------------------------------------------------------
  local contentW, contentH = 0, 0
  if isReplaced(node) then
    contentH = ctx.replacedHeight and ctx.replacedHeight(node, st, cw) or st.lineHeight
    contentW = cw
  else
    local reserve = 0
    local scrollable = (st.overflowY == 'auto' or st.overflowY == 'scroll')
    if st.overflowY == 'scroll' then reserve = SCROLLBAR end
    contentW, contentH = layoutChildren(box, ctx, cw - reserve, ch)
    if scrollable and reserve == 0 and ch and contentH > ch + 0.5 then
      -- re-run once with room for the scrollbar
      box.children, box.lines = {}, {}
      reserve = SCROLLBAR
      contentW, contentH = layoutChildren(box, ctx, cw - reserve, ch)
    end
    box.scrollbarW = reserve
  end

  local usedCH = ch or contentH
  usedCH = clampHeight(st, usedCH + box.frameH, opts.cbHeight or ctx.vh) - box.frameH
  box.h = usedCH + box.frameH
  box.contentH = usedCH
  box.scrollH = contentH
  box.scrollW = contentW

  -- scroll clamping
  local overflowY = st.overflowY
  if overflowY == 'auto' or overflowY == 'scroll' then
    box.scrollable = contentH > usedCH + 0.5
    local maxScroll = max(0, contentH - usedCH)
    node.state.scrollY = util.clamp(node.state.scrollY or 0, 0, maxScroll)
    box.scrollY = node.state.scrollY
    box.maxScrollY = maxScroll
  else
    box.scrollY = 0
  end

  return box
end
layout.layoutBox = layoutBox

-- --------------------------------------------------- absolute placement ----

local function layoutAbsolute(node, st, ctx, cb)
  local cbW, cbH = cb.w, cb.h
  local box
  local left = resolve(st.left, cbW)
  local right = resolve(st.right, cbW)
  local top = resolve(st.top, cbH)
  local bottom = resolve(st.bottom, cbH)
  local wSpec = resolve(st.width, cbW)

  local forceWidth = nil
  if not wSpec and left and right then
    forceWidth = max(0, cbW - left - right)
  end
  box = layoutBox(node, st, ctx, {
    avail = cbW, forceWidth = forceWidth, shrink = not wSpec and not forceWidth,
    cbHeight = cbH,
  })

  local ml = resolve(st.margin[4], cbW) or 0
  local mt = resolve(st.margin[1], cbW) or 0
  if left then
    box.x = left + ml
  elseif right then
    box.x = cbW - right - box.w - (resolve(st.margin[2], cbW) or 0)
  else
    box.x = ml
  end
  if top then
    box.y = top + mt
  elseif bottom then
    box.y = cbH - bottom - box.h - (resolve(st.margin[3], cbW) or 0)
  else
    box.y = mt
  end
  return box
end

-- ------------------------------------------------------------ entry pt ----

--- Run a full layout pass.
-- opts: { measure = fn(text, style) -> width, width, height,
--         replacedWidth / replacedHeight = fn(node, style[, cw]) }
function layout.run(root, opts)
  local ctx = {
    measure = opts.measure,
    replacedWidth = opts.replacedWidth,
    replacedHeight = opts.replacedHeight,
    vw = opts.width, vh = opts.height,
    cache = opts.cache or {},
    intrinsic = {},
    pending = {},
  }
  ctx.parentHeight = opts.height

  local body = root
  local st = body.computed
  if not st then return nil, ctx end

  local box = layoutBox(body, st, ctx, {
    avail = opts.width,
    forceWidth = resolve(st.width, opts.width) and nil or opts.width,
    forceHeight = isAuto(st.height) and (opts.stretch and opts.height or nil) or nil,
  })

  -- absolutely positioned descendants, in document order
  local guard = 0
  while #ctx.pending > 0 and guard < 16 do
    guard = guard + 1
    local pending = ctx.pending
    ctx.pending = {}
    for _, entry in ipairs(pending) do
      local child = entry.node or entry
      local parentBox = entry.box
      local cst = child.computed
      if cst then
        local cb
        if cst.position == 'fixed' then
          cb = { w = opts.width, h = opts.height, box = box, root = true }
        else
          local anc = parentBox
          local n = child.parent
          while n do
            local ast = n.computed
            if ast and (ast.position ~= 'static') and n.box then
              anc = n.box
              break
            end
            n = n.parent
          end
          anc = anc or box
          cb = { w = anc.contentW or opts.width, h = anc.contentH or opts.height, box = anc }
        end
        local abox = layoutAbsolute(child, cst, ctx, cb)
        abox.absoluteIn = cb.box
        abox.isFixed = (cst.position == 'fixed')
        local host = cb.box or box
        host.children[#host.children + 1] = abox
        abox.positioned = true
      end
    end
  end

  -- absolute coordinates
  local function place(b, ox, oy)
    local st2 = b.style
    local tx, ty = 0, 0
    if st2 and st2.transform then tx, ty = st2.transform.tx, st2.transform.ty end
    if st2 and st2.position == 'relative' then
      local left, right = resolve(st2.left, 0), resolve(st2.right, 0)
      local top, bottom = resolve(st2.top, 0), resolve(st2.bottom, 0)
      tx = tx + (left or (right and -right) or 0)
      ty = ty + (top or (bottom and -bottom) or 0)
    end
    b.ax = ox + b.x + tx
    b.ay = oy + b.y + ty
    local cox = b.ax + b.border[4] + b.padding[4]
    local coy = b.ay + b.border[1] + b.padding[1] - (b.scrollY or 0)
    for _, child in ipairs(b.children) do
      if child.isFixed then
        place(child, 0, 0)
      else
        place(child, cox, coy)
      end
    end
    for _, ln in ipairs(b.lines or {}) do
      ln.ax = cox
      ln.ay = coy + ln.y
    end
    for _, d in ipairs(b.inlineDecorations or {}) do
      d.ax = d.ln.ax + d.x
      d.ay = d.ln.ay + d.y
      -- a stand-in box so node:rect(), :hover and clicks work on inline tags
      d.node.box = {
        node = d.node, style = d.style, kind = 'inline', inline = true,
        ax = d.ax, ay = d.ay, x = d.x, y = d.y, w = d.w, h = d.h,
        children = {}, lines = {}, inlineDecorations = {},
        margin = { 0, 0, 0, 0 }, padding = { 0, 0, 0, 0 }, border = { 0, 0, 0, 0 },
        frameW = 0, frameH = 0, contentW = d.w, contentH = d.h,
      }
    end
  end
  place(box, 0, 0)

  return box, ctx
end

layout.SCROLLBAR = SCROLLBAR
layout.isPositioned = isPositioned
layout.isReplaced = isReplaced
layout.INLINE_DISPLAYS = INLINE_DISPLAYS
layout.BLOCK_DISPLAYS = BLOCK_DISPLAYS
layout.transformText = transformText

return layout
