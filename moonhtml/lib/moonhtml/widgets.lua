-- moonhtml/widgets.lua -- form controls: intrinsic sizing, painting, values.
-- Interaction lives in events.lua; this module owns look and geometry.

local util = require 'moonhtml.util'
local color = require 'moonhtml.color'

local widgets = {}

local max, min, floor = math.max, math.min, math.floor

--- What sort of control is this node, if any?
function widgets.kind(node)
  if node.type ~= 'element' then return nil end
  local tag = node.tag
  if tag == 'input' then
    local t = (node:getAttribute('type', 'text')):lower()
    if t == 'checkbox' then return 'checkbox' end
    if t == 'radio' then return 'radio' end
    if t == 'range' then return 'range' end
    if t == 'color' then return 'color' end
    if t == 'button' or t == 'submit' then return 'button' end
    if t == 'number' then return 'number' end
    return 'text'
  end
  if tag == 'textarea' then return 'textarea' end
  if tag == 'select' then return 'select' end
  if tag == 'progress' then return 'progress' end
  if tag == 'img' then return 'image' end
  if tag == 'button' then return 'button' end
  return nil
end

function widgets.isInteractive(node)
  local k = widgets.kind(node)
  return k ~= nil and k ~= 'image' and k ~= 'progress'
end

-- ------------------------------------------------------------- values ----

function widgets.rangeParams(node)
  local mn = tonumber(node:getAttribute('min', '0')) or 0
  local mx = tonumber(node:getAttribute('max', '100')) or 100
  local step = tonumber(node:getAttribute('step', '1')) or 1
  local v = tonumber(node:getValue()) or mn
  if mx <= mn then mx = mn + 1 end
  return mn, mx, step, util.clamp(v, mn, mx)
end

function widgets.progressValue(node)
  local v = tonumber(node:getValue()) or tonumber(node:getAttribute('value', '0')) or 0
  local mx = tonumber(node:getAttribute('max', '100')) or 100
  if mx <= 0 then mx = 1 end
  return util.clamp(v / mx, 0, 1)
end

function widgets.selectOptions(node)
  local out = {}
  for _, opt in ipairs(node:getElementsByTagName('option')) do
    out[#out + 1] = {
      node = opt,
      label = util.trim(opt:getText()),
      value = opt:getAttribute('value', util.trim(opt:getText())),
    }
  end
  return out
end

function widgets.selectedIndex(node)
  local opts = widgets.selectOptions(node)
  local value = node.state.value
  if value ~= nil then
    for i, o in ipairs(opts) do
      if o.value == value then return i, opts end
    end
  end
  for i, o in ipairs(opts) do
    if o.node:hasAttribute('selected') then return i, opts end
  end
  return (#opts > 0 and 1 or 0), opts
end

function widgets.displayText(node)
  local kind = widgets.kind(node)
  if kind == 'select' then
    local idx, opts = widgets.selectedIndex(node)
    return opts[idx] and opts[idx].label or ''
  end
  local v = node:getValue()
  if (v == nil or v == '') and node:getAttribute('placeholder', '') ~= '' then
    return node:getAttribute('placeholder'), true
  end
  return v or ''
end

-- ---------------------------------------------------------- intrinsics ----

--- Content-box size a replaced element wants.
function widgets.intrinsicSize(node, st, measure)
  local kind = widgets.kind(node)
  if kind == 'checkbox' or kind == 'radio' then
    return 16, 16
  elseif kind == 'range' then
    return 180, max(14, st.fontSize)
  elseif kind == 'color' then
    return 36, max(14, st.fontSize)
  elseif kind == 'progress' then
    return 180, 8
  elseif kind == 'image' then
    local w = tonumber(node:getAttribute('width', '')) or 0
    local h = tonumber(node:getAttribute('height', '')) or 0
    return w, h
  elseif kind == 'select' then
    local widest = 0
    for _, o in ipairs(widgets.selectOptions(node)) do
      widest = max(widest, measure(o.label, st))
    end
    return max(60, widest + 20), st.lineHeight
  elseif kind == 'textarea' then
    return 180, st.lineHeight * 4
  elseif kind then
    local text = widgets.displayText(node)
    return max(80, measure(text or '', st) + 4), st.lineHeight
  end
  return 0, 0
end

-- -------------------------------------------------------------- paint ----

local function rect(out, x, y, w, h, col, r, alpha)
  if color.isTransparent(col) or w <= 0 or h <= 0 then return end
  out[#out + 1] = {
    op = 'rect', x = x, y = y, w = w, h = h,
    color = col, radius = r, alpha = alpha,
  }
end

local function line(out, x1, y1, x2, y2, col, thickness, alpha)
  out[#out + 1] = {
    op = 'line', x1 = x1, y1 = y1, x2 = x2, y2 = y2,
    color = col, thickness = thickness or 1, alpha = alpha,
  }
end

local function circle(out, cx, cy, r, col, filled, alpha)
  out[#out + 1] = {
    op = 'circle', cx = cx, cy = cy, r = r,
    color = col, filled = filled ~= false, alpha = alpha,
  }
end

--- Paint the parts of a control that plain CSS boxes cannot express.
-- The background/border have already been drawn by paint.lua.
function widgets.paint(node, box, st, out, alpha, ctx)
  local kind = widgets.kind(node)
  if not kind then return end
  local x, y, w, h = box.ax, box.ay, box.w, box.h
  local cx = x + box.border[4] + box.padding[4]
  local cy = y + box.border[1] + box.padding[1]
  local cw = max(0, w - box.frameW)
  local chh = max(0, h - box.frameH)

  if kind == 'checkbox' then
    if w > h * 1.4 then
      -- styled as a pill -> render as a toggle switch, which is what the
      -- author clearly meant when they gave a checkbox a 2:1 aspect ratio
      local pad = max(1.5, h * 0.12)
      local r = (h - pad * 2) * 0.5
      local knobX = node.state.checked and (x + w - pad - r) or (x + pad + r)
      circle(out, knobX, y + h * 0.5, r, st.color, true, alpha)
    elseif node.state.checked then
      local pad = max(2, w * 0.22)
      local col = st.color
      line(out, x + pad, y + h * 0.52, x + w * 0.44, y + h - pad, col, max(1.6, w * 0.12), alpha)
      line(out, x + w * 0.44, y + h - pad, x + w - pad, y + pad, col, max(1.6, w * 0.12), alpha)
    end
  elseif kind == 'radio' then
    if node.state.checked then
      circle(out, x + w * 0.5, y + h * 0.5, max(2, w * 0.22), st.color, true, alpha)
    end
  elseif kind == 'range' then
    local mn, mx, _, v = widgets.rangeParams(node)
    local t = (v - mn) / (mx - mn)
    local trackH = max(3, floor(chh * 0.22))
    local ty = cy + (chh - trackH) * 0.5
    local knobR = max(5, chh * 0.42)
    local usable = max(0, cw - knobR * 2)
    local trackCol = st.backgroundColor or color.rgba(32, 33, 36, 1)
    if color.isTransparent(trackCol) then trackCol = color.rgba(60, 64, 67, 1) end
    rect(out, cx, ty, cw, trackH, trackCol, { trackH / 2, trackH / 2, trackH / 2, trackH / 2 }, alpha)
    rect(out, cx, ty, knobR + usable * t, trackH, st.color,
      { trackH / 2, trackH / 2, trackH / 2, trackH / 2 }, alpha)
    circle(out, cx + knobR + usable * t, cy + chh * 0.5, knobR, st.color, true, alpha)
    circle(out, cx + knobR + usable * t, cy + chh * 0.5, knobR - 2,
      color.rgba(255, 255, 255, 1), true, alpha)
  elseif kind == 'progress' then
    local t = widgets.progressValue(node)
    local r = st.radius
    rect(out, cx, cy, cw * t, chh, st.color, r, alpha)
  elseif kind == 'color' then
    local c = color.parse(node:getValue() or '#ffffff') or color.rgba(255, 255, 255, 1)
    rect(out, cx, cy, cw, chh, c, st.radius, alpha)
  elseif kind == 'select' then
    local text = widgets.displayText(node)
    out[#out + 1] = {
      op = 'text', x = cx, y = cy + (chh - st.fontSize) * 0.5,
      text = text, style = st, color = st.color, alpha = alpha,
    }
    local ax = x + w - box.border[2] - box.padding[2] - 10
    local ay = y + h * 0.5 - 1
    out[#out + 1] = {
      op = 'triangle', color = st.color, alpha = alpha,
      points = { ax, ay - 1, ax + 8, ay - 1, ax + 4, ay + 4 },
    }
  elseif kind == 'text' or kind == 'number' or kind == 'textarea' then
    local text, isPlaceholder = widgets.displayText(node)
    if node:getAttribute('type', '') == 'password' and not isPlaceholder then
      text = string.rep('*', util.utf8len(text))
    end
    local col = st.color
    if isPlaceholder then col = color.withAlpha(st.color, 0.45) end
    out[#out + 1] = {
      op = 'native', kind = kind, node = node, style = st,
      x = cx, y = cy, w = cw, h = chh,
      text = text, color = col, alpha = alpha,
      focused = node.state.focus == true,
      caret = node.state.caret,
    }
  elseif kind == 'image' then
    out[#out + 1] = {
      op = 'image', src = node:getAttribute('src', ''), node = node,
      x = cx, y = cy, w = cw, h = chh, alpha = alpha, radius = st.radius,
    }
  end
end

--- Paint an open <select> dropdown in the top layer.
function widgets.paintSelectPopup(node, out, alpha, measure)
  local box = node.box
  if not box then return end
  local st = node.computed
  local idx, opts = widgets.selectedIndex(node)
  local itemH = st.lineHeight + 6
  local h = #opts * itemH + 4
  local x, y, w = box.ax, box.ay + box.h + 2, box.w
  local bg = color.rgba(32, 33, 36, 0.98)
  local border = color.rgba(95, 99, 104, 1)
  local r = { 4, 4, 4, 4 }
  out[#out + 1] = { op = 'rect', x = x, y = y, w = w, h = h, color = bg, radius = r, alpha = alpha }
  out[#out + 1] = {
    op = 'border', x = x, y = y, w = w, h = h, radius = r, alpha = alpha,
    widths = { 1, 1, 1, 1 }, colors = { border, border, border, border },
  }
  node.state.popupRect = { x = x, y = y, w = w, h = h, itemH = itemH }
  for i, o in ipairs(opts) do
    local iy = y + 2 + (i - 1) * itemH
    if i == node.state.hoverOption then
      out[#out + 1] = {
        op = 'rect', x = x + 2, y = iy, w = w - 4, h = itemH,
        color = color.rgba(138, 180, 248, 0.22), radius = { 3, 3, 3, 3 }, alpha = alpha,
      }
    end
    out[#out + 1] = {
      op = 'text', x = x + 8, y = iy + (itemH - st.fontSize) * 0.5 - 1,
      text = o.label, style = st, alpha = alpha,
      color = (i == idx) and color.rgba(138, 180, 248, 1) or st.color,
    }
  end
end

return widgets
