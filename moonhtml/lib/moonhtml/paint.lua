-- moonhtml/paint.lua -- turns the laid out box tree into a flat display list.
--
-- The display list is backend agnostic: the mimgui backend replays it into an
-- ImDrawList, the test backends replay it into SVG/PNG. Same pixels, no
-- rendering logic duplicated per backend.

local util = require 'moonhtml.util'
local color = require 'moonhtml.color'
local widgets = require 'moonhtml.widgets'
local layout = require 'moonhtml.layout'

local paint = {}

local max, min, floor = math.max, math.min, math.floor

local function pushRect(out, x, y, w, h, col, radius, alpha)
  if w <= 0 or h <= 0 or color.isTransparent(col) then return end
  out[#out + 1] = {
    op = 'rect', x = x, y = y, w = w, h = h,
    color = col, radius = radius, alpha = alpha,
  }
end

local function anyBorder(st)
  return (st.border[1] + st.border[2] + st.border[3] + st.border[4]) > 0
end

local function paintShadow(out, box, st, alpha)
  local sh = st.boxShadow
  if not sh or sh.inset then return end
  local steps = util.clamp(floor((sh.blur or 0) / 2), 1, 6)
  local baseAlpha = (sh.color[4] or 1)
  for i = steps, 1, -1 do
    local t = i / steps
    local grow = (sh.spread or 0) + (sh.blur or 0) * t
    local r = {}
    for k = 1, 4 do r[k] = (st.radius[k] or 0) + grow end
    pushRect(out,
      box.ax + sh.x - grow, box.ay + sh.y - grow,
      box.w + grow * 2, box.h + grow * 2,
      color.withAlpha(sh.color, (0.55 / steps) / (baseAlpha > 0 and 1 or 1)),
      r, alpha * baseAlpha)
  end
end

local function paintBackground(out, box, st, alpha)
  local r = st.radius
  if st.backgroundColor then
    pushRect(out, box.ax, box.ay, box.w, box.h, st.backgroundColor, r, alpha)
  end
  local bg = st.backgroundImage
  if bg then
    if bg.type == 'linear' then
      out[#out + 1] = {
        op = 'gradient', x = box.ax, y = box.ay, w = box.w, h = box.h,
        angle = bg.angle, stops = bg.stops, radius = r, alpha = alpha,
      }
    elseif bg.type == 'image' then
      out[#out + 1] = {
        op = 'image', src = bg.src, x = box.ax, y = box.ay,
        w = box.w, h = box.h, alpha = alpha, radius = r, node = box.node,
      }
    end
  end
end

local function paintBorder(out, box, st, alpha)
  if not anyBorder(st) then return end
  out[#out + 1] = {
    op = 'border', x = box.ax, y = box.ay, w = box.w, h = box.h,
    widths = box.border, colors = st.borderColor, styles = st.borderStyle,
    radius = st.radius, alpha = alpha,
  }
end

local function truncate(text, st, maxW, measure)
  if measure(text, st) <= maxW then return text end
  local ell = '\226\128\166' -- …
  local ellW = measure(ell, st)
  local budget = maxW - ellW
  if budget <= 0 then return ell end
  local best, acc = '', ''
  for ch in util.chars(text) do
    acc = acc .. ch
    if measure(acc, st) > budget then break end
    best = acc
  end
  return best .. ell
end

--- Backgrounds and borders of inline elements (<a>, <code>, styled <span>),
-- one rectangle per line the element occupies.
local function paintInlineDecorations(out, box, alpha)
  for _, d in ipairs(box.inlineDecorations or {}) do
    local st = d.style
    if st and d.w and d.w > 0 then
      if st.backgroundColor then
        pushRect(out, d.ax, d.ay, d.w, d.h, st.backgroundColor, st.radius, alpha * st.opacity)
      end
      if st.backgroundImage and st.backgroundImage.type == 'linear' then
        out[#out + 1] = {
          op = 'gradient', x = d.ax, y = d.ay, w = d.w, h = d.h,
          angle = st.backgroundImage.angle, stops = st.backgroundImage.stops,
          radius = st.radius, alpha = alpha * st.opacity,
        }
      end
      if anyBorder(st) then
        out[#out + 1] = {
          op = 'border', x = d.ax, y = d.ay, w = d.w, h = d.h,
          widths = st.border, colors = st.borderColor, styles = st.borderStyle,
          radius = st.radius, alpha = alpha * st.opacity,
        }
      end
    end
  end
end

local function paintLines(out, box, st, alpha, ctx)
  local ellipsis = st.textOverflow == 'ellipsis'
      and (st.overflowX == 'hidden' or st.overflowX == 'clip')
  for _, ln in ipairs(box.lines or {}) do
    for _, item in ipairs(ln.items) do
      if item.type == 'word' then
        local ist = item.style
        local text = item.text
        local x = ln.ax + (item.x or 0)
        local y = ln.ay + ln.baseline - ist.fontSize * 0.8
        if ellipsis and (item.x or 0) + item.w > box.contentW then
          local room = box.contentW - (item.x or 0)
          if room <= 0 then text = nil else text = truncate(text, ist, room, ctx.measure) end
        end
        if text then
          out[#out + 1] = {
            op = 'text', x = x, y = y, text = text, style = ist,
            color = ist.color, alpha = alpha * (ist.opacity or 1), node = item.node,
          }
          local dec = ist.textDecoration
          if dec == 'underline' or dec == 'line-through' then
            local ly = (dec == 'underline') and (y + ist.fontSize * 1.05)
                or (y + ist.fontSize * 0.6)
            out[#out + 1] = {
              op = 'line', x1 = x, y1 = ly, x2 = x + item.w, y2 = ly,
              color = ist.color, thickness = max(1, ist.fontSize / 14), alpha = alpha,
            }
          end
        end
      end
    end
  end
end

local function paintMarker(out, box, st, alpha)
  if st.display ~= 'list-item' or st.listStyle == 'none' then return end
  local cy = box.ay + box.border[1] + box.padding[1] + st.lineHeight * 0.5
  local cx = box.ax - 8
  if st.listStyle == 'square' then
    pushRect(out, cx - 2.5, cy - 2.5, 5, 5, st.color, nil, alpha)
  elseif st.listStyle == 'decimal' then
    local idx = box.node.index and box.node:index() or 1
    out[#out + 1] = {
      op = 'text', x = cx - 10, y = cy - st.fontSize * 0.55,
      text = tostring(idx) .. '.', style = st, color = st.color, alpha = alpha,
    }
  else
    out[#out + 1] = {
      op = 'circle', cx = cx, cy = cy, r = 2.5,
      color = st.color, filled = true, alpha = alpha,
    }
  end
end

local function paintScrollbar(out, box, st, alpha)
  if not box.scrollable or (box.maxScrollY or 0) <= 0 then return end
  local w = layout.SCROLLBAR
  local trackX = box.ax + box.w - box.border[2] - w
  local trackY = box.ay + box.border[1]
  local trackH = box.h - box.border[1] - box.border[3]
  pushRect(out, trackX + 2, trackY, w - 4, trackH,
    color.rgba(255, 255, 255, 0.06), { 3, 3, 3, 3 }, alpha)
  local visible = box.contentH
  local total = box.scrollH
  local thumbH = max(20, trackH * (visible / total))
  local t = box.scrollY / box.maxScrollY
  local thumbY = trackY + (trackH - thumbH) * t
  pushRect(out, trackX + 2, thumbY, w - 4, thumbH,
    color.rgba(255, 255, 255, box.node.state.scrollHover and 0.34 or 0.22),
    { 3, 3, 3, 3 }, alpha)
  box.scrollbarRect = { x = trackX, y = trackY, w = w, h = trackH,
    thumbY = thumbY, thumbH = thumbH }
end

local paintBox

local function paintChildren(out, box, alpha, ctx)
  local hasPositioned = false
  for i = 1, #box.children do
    local st = box.children[i].style
    if st and st.position ~= 'static' then
      hasPositioned = true
      break
    end
  end
  if not hasPositioned then
    for i = 1, #box.children do paintBox(box.children[i], out, alpha, ctx) end
    return
  end

  local normal, positioned = {}, {}
  for _, child in ipairs(box.children) do
    local cst = child.style
    if cst and cst.position ~= 'static' then
      positioned[#positioned + 1] = child
    else
      normal[#normal + 1] = child
    end
  end
  for _, child in ipairs(normal) do paintBox(child, out, alpha, ctx) end
  if #positioned > 0 then
    for i, child in ipairs(positioned) do child._paintOrder = i end
    table.sort(positioned, function(a, b)
      local az, bz = a.style.zIndex or 0, b.style.zIndex or 0
      if az ~= bz then return az < bz end
      return a._paintOrder < b._paintOrder
    end)
    for _, child in ipairs(positioned) do paintBox(child, out, alpha, ctx) end
  end
end

paintBox = function(box, out, alpha, ctx)
  local st = box.style
  if not st or st.visibility == 'hidden' then return end
  alpha = alpha * (st.opacity or 1)
  if alpha <= 0.003 then return end

  if box.kind == 'text-run' then
    out[#out + 1] = {
      op = 'text', x = box.ax, y = box.ay + (box.h - st.fontSize) * 0.5,
      text = box.text, style = st, color = st.color, alpha = alpha,
    }
    return
  end

  paintShadow(out, box, st, alpha)
  paintBackground(out, box, st, alpha)
  paintBorder(out, box, st, alpha)
  paintMarker(out, box, st, alpha)
  widgets.paint(box.node, box, st, out, alpha, ctx)

  local clipX = st.overflowX ~= 'visible'
  local clipY = st.overflowY ~= 'visible'
  local clipped = clipX or clipY
  if clipped then
    local pad = 0
    out[#out + 1] = {
      op = 'clip',
      x = clipX and (box.ax + box.border[4]) or -100000,
      y = clipY and (box.ay + box.border[1]) or -100000,
      w = clipX and (box.w - box.border[2] - box.border[4]) or 200000,
      h = clipY and (box.h - box.border[1] - box.border[3]) or 200000,
    }
  end

  paintInlineDecorations(out, box, alpha)
  paintLines(out, box, st, alpha, ctx)
  paintChildren(out, box, alpha, ctx)

  if clipped then out[#out + 1] = { op = 'unclip' } end
  paintScrollbar(out, box, st, alpha)
end

--- Build the display list for a laid out tree.
-- opts: { measure = fn(text, style) -> width, document = <Document> }
function paint.run(rootBox, opts)
  local out = {}
  local ctx = { measure = opts.measure, document = opts.document }
  paintBox(rootBox, out, 1, ctx)
  local doc = opts.document
  if doc and doc.openSelect and doc.openSelect.box then
    widgets.paintSelectPopup(doc.openSelect, out, 1, opts.measure)
  end
  return out
end

paint.truncate = truncate

return paint
