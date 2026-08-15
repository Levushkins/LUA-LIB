-- moonhtml/events.lua -- hit testing, hover/active/focus tracking, dispatch.

local util = require 'moonhtml.util'
local widgets = require 'moonhtml.widgets'
local layout = require 'moonhtml.layout'

local events = {}

local max, min = math.max, math.min

-- ---------------------------------------------------------- hit testing ----

local function orderedChildren(box)
  local normal, positioned = {}, {}
  for _, child in ipairs(box.children) do
    if child.style and child.style.position ~= 'static' then
      positioned[#positioned + 1] = child
    else
      normal[#normal + 1] = child
    end
  end
  for i, child in ipairs(positioned) do child._hitOrder = i end
  table.sort(positioned, function(a, b)
    local az, bz = a.style.zIndex or 0, b.style.zIndex or 0
    if az ~= bz then return az < bz end
    return a._hitOrder < b._hitOrder
  end)
  local out = normal
  for _, child in ipairs(positioned) do out[#out + 1] = child end
  return out
end
events.orderedChildren = orderedChildren

local function boxContains(box, x, y)
  return x >= box.ax and x < box.ax + box.w and y >= box.ay and y < box.ay + box.h
end

local function hitTestBox(box, x, y, best)
  local st = box.style
  if not st or st.visibility == 'hidden' then return best end
  local inside = boxContains(box, x, y)
  local clips = st.overflowX ~= 'visible' or st.overflowY ~= 'visible'
  if clips and not inside then return best end
  if inside and st.pointerEvents ~= 'none' and box.node and box.node.type == 'element' then
    best = box
  end
  -- inline fragments (<a>, <span>) sit between the block and its child boxes
  if inside then
    for _, d in ipairs(box.inlineDecorations or {}) do
      if d.ax and x >= d.ax and x < d.ax + d.w and y >= d.ay and y < d.ay + d.h
          and d.style and d.style.pointerEvents ~= 'none' then
        best = d.node.box or best
      end
    end
  end
  for _, child in ipairs(orderedChildren(box)) do
    best = hitTestBox(child, x, y, best)
  end
  return best
end

--- Topmost element box under the point, or nil.
function events.hitTest(rootBox, x, y)
  if not rootBox then return nil end
  return hitTestBox(rootBox, x, y, nil)
end

-- ------------------------------------------------------------- dispatch ----

local Event = {}
Event.__index = Event

function events.newEvent(etype, props)
  local e = setmetatable(props or {}, Event)
  e.type = etype
  e.propagationStopped = false
  e.defaultPrevented = false
  return e
end

function Event:stopPropagation() self.propagationStopped = true end
function Event:preventDefault() self.defaultPrevented = true end

--- Dispatch `event` at `node`, bubbling towards the root.
function events.dispatch(doc, node, event)
  if not node then return event end
  event.target = event.target or node
  local path = {}
  local n = node
  while n do
    path[#path + 1] = n
    n = n.parent
  end
  for _, current in ipairs(path) do
    event.currentTarget = current
    local list = current.listeners and current.listeners[event.type]
    if list then
      for i = 1, #list do
        local ok, err = pcall(list[i].fn, event, current)
        if not ok then doc:reportError(err) end
      end
    end
    local attr = current.attrs and current.attrs['on' .. event.type]
    if attr then doc:runInlineHandler(current, attr, event) end
    if event.propagationStopped then break end
  end
  return event
end

-- ------------------------------------------------------- state tracking ----

local function ancestorChain(node)
  local chain, n = {}, node
  while n do
    if n.type == 'element' then chain[#chain + 1] = n end
    n = n.parent
  end
  return chain
end

local function setChainState(chain, key, value)
  for _, n in ipairs(chain) do n.state[key] = value end
end

local function isFocusable(node)
  if not node or node.type ~= 'element' then return false end
  if node.state.disabled then return false end
  if widgets.isInteractive(node) then return true end
  return node:hasAttribute('tabindex')
end

local function scrollableAncestor(node)
  local n = node
  while n do
    local box = n.box
    if box and box.scrollable and (box.maxScrollY or 0) > 0 then return n end
    n = n.parent
  end
end

-- ------------------------------------------------------------- widgets ----

local function commitValue(doc, node, value, etype)
  node:setValue(value)
  events.dispatch(doc, node, events.newEvent(etype or 'input', { value = value }))
end

local function rangeValueAt(node, x)
  local box = node.box
  local st = node.computed
  local cx = box.ax + box.border[4] + box.padding[4]
  local cw = max(1, box.w - box.frameW)
  local chh = max(0, box.h - box.frameH)
  local knobR = max(5, chh * 0.42)
  local usable = max(1, cw - knobR * 2)
  local mn, mx, step = widgets.rangeParams(node)
  local t = util.clamp((x - cx - knobR) / usable, 0, 1)
  local v = mn + (mx - mn) * t
  if step and step > 0 then
    v = mn + math.floor((v - mn) / step + 0.5) * step
  end
  return util.clamp(v, mn, mx)
end

local function activateNode(doc, node, event)
  local kind = widgets.kind(node)
  if kind == 'checkbox' then
    node:setChecked(not node.state.checked)
    events.dispatch(doc, node, events.newEvent('change', { checked = node.state.checked }))
  elseif kind == 'radio' then
    local group = node:getAttribute('name', '')
    if group ~= '' then
      local form = node:closest(function(n) return n.parent == nil end)
      for _, other in ipairs(form:getElementsByTagName('input')) do
        if other:getAttribute('name', '') == group and widgets.kind(other) == 'radio' then
          other:setChecked(false)
        end
      end
    end
    node:setChecked(true)
    events.dispatch(doc, node, events.newEvent('change', { checked = true }))
  elseif kind == 'select' then
    if doc.openSelect == node then
      doc.openSelect = nil
    else
      doc.openSelect = node
      node.state.hoverOption = nil
    end
  end
  -- <label for="id"> forwards activation
  if node.tag == 'label' then
    local target = node:getAttribute('for', '')
    if target ~= '' then
      local el = doc.root:getElementById(target)
      if el then
        activateNode(doc, el, event)
        events.dispatch(doc, el, events.newEvent('click', { x = event.x, y = event.y }))
      end
    end
  end
end

-- --------------------------------------------------------------- update ----

--- Process one frame of input. `input` fields:
--   x, y            mouse position in document coordinates
--   down            left button held
--   pressed         left button went down this frame
--   released        left button went up this frame
--   rightPressed    right button went down this frame
--   wheel           scroll delta (positive = up)
--   chars           array of typed utf-8 characters
--   keys            map of pressed key names ('backspace', 'enter', ...)
--   inside          mouse is inside the host window
function events.update(doc, input)
  local rootBox = doc.rootBox
  if not rootBox then return end

  local hitBox = input.inside ~= false and events.hitTest(rootBox, input.x, input.y) or nil
  local hitNode = hitBox and hitBox.node or nil
  doc.hitNode = hitNode

  -- a click inside an open dropdown is handled by the dropdown, not the page
  local popup = doc.openSelect and doc.openSelect.state.popupRect
  local overPopup = false
  if popup then
    overPopup = input.x >= popup.x and input.x <= popup.x + popup.w
        and input.y >= popup.y and input.y <= popup.y + popup.h
    if overPopup then
      local idx = math.floor((input.y - popup.y - 2) / popup.itemH) + 1
      doc.openSelect.state.hoverOption = idx
      doc.cursor = 'pointer'
    else
      doc.openSelect.state.hoverOption = nil
    end
  end

  -- hover -----------------------------------------------------------------
  local chain = hitNode and ancestorChain(hitNode) or {}
  local newHover = {}
  for _, n in ipairs(chain) do newHover[n] = true end
  local oldHover = doc.hoverSet or {}
  for n in pairs(oldHover) do
    if not newHover[n] then
      n.state.hover = nil
      doc.needsStyle = true
      events.dispatch(doc, n, events.newEvent('mouseleave', { x = input.x, y = input.y }))
    end
  end
  for n in pairs(newHover) do
    if not oldHover[n] then
      n.state.hover = true
      doc.needsStyle = true
      events.dispatch(doc, n, events.newEvent('mouseenter', { x = input.x, y = input.y }))
    end
  end
  doc.hoverSet = newHover

  doc.cursor = doc.cursor or 'default'
  if hitNode and hitNode.computed then doc.cursor = hitNode.computed.cursor end

  -- scrollbar hover
  local scrollNode = scrollableAncestor(hitNode)
  if doc.scrollHoverNode and doc.scrollHoverNode ~= scrollNode then
    doc.scrollHoverNode.state.scrollHover = nil
  end
  if scrollNode then scrollNode.state.scrollHover = true end
  doc.scrollHoverNode = scrollNode

  -- press -----------------------------------------------------------------
  if input.pressed then
    if overPopup then
      local sel = doc.openSelect
      local idx = math.floor((input.y - popup.y - 2) / popup.itemH) + 1
      local opts = widgets.selectOptions(sel)
      if opts[idx] then
        sel:setValue(opts[idx].value)
        sel.state.selectedIndex = idx
        events.dispatch(doc, sel, events.newEvent('change',
          { value = opts[idx].value, index = idx, label = opts[idx].label }))
      end
      doc.openSelect = nil
    else
      if doc.openSelect and doc.openSelect ~= hitNode then doc.openSelect = nil end

      -- focus
      local focusTarget = nil
      for _, n in ipairs(chain) do
        if isFocusable(n) then
          focusTarget = n
          break
        end
      end
      if doc.focusNode ~= focusTarget then
        if doc.focusNode then
          doc.focusNode.state.focus = nil
          events.dispatch(doc, doc.focusNode, events.newEvent('blur'))
        end
        doc.focusNode = focusTarget
        if focusTarget then
          focusTarget.state.focus = true
          focusTarget.state.caret = nil
          events.dispatch(doc, focusTarget, events.newEvent('focus'))
        end
        doc.needsStyle = true
      end

      if hitNode then
        setChainState(chain, 'active', true)
        doc.activeChain = chain
        doc.pressNode = hitNode
        doc.needsStyle = true
        events.dispatch(doc, hitNode, events.newEvent('mousedown',
          { x = input.x, y = input.y, button = 1 }))

        -- drag interactions
        local kind = widgets.kind(hitNode)
        if kind == 'range' and not hitNode.state.disabled then
          doc.dragNode = hitNode
          commitValue(doc, hitNode, rangeValueAt(hitNode, input.x), 'input')
        end
      end

      -- scrollbar grab
      local sb = scrollNode and scrollNode.box and scrollNode.box.scrollbarRect
      if sb and input.x >= sb.x and input.x <= sb.x + sb.w then
        doc.scrollDrag = {
          node = scrollNode,
          grabOffset = input.y - sb.thumbY,
          rect = sb,
        }
      end
    end
  end

  -- drag ------------------------------------------------------------------
  if input.down then
    if doc.dragNode and doc.dragNode.box then
      commitValue(doc, doc.dragNode, rangeValueAt(doc.dragNode, input.x), 'input')
    end
    local sd = doc.scrollDrag
    if sd and sd.node.box then
      local box = sd.node.box
      local travel = max(1, sd.rect.h - sd.rect.thumbH)
      local t = util.clamp((input.y - sd.grabOffset - sd.rect.y) / travel, 0, 1)
      sd.node.state.scrollY = t * (box.maxScrollY or 0)
      doc.needsLayout = true
    end
  else
    doc.dragNode = nil
    doc.scrollDrag = nil
  end

  -- release ---------------------------------------------------------------
  if input.released then
    if doc.activeChain then
      setChainState(doc.activeChain, 'active', nil)
      doc.activeChain = nil
      doc.needsStyle = true
    end
    if hitNode then
      events.dispatch(doc, hitNode, events.newEvent('mouseup',
        { x = input.x, y = input.y, button = 1 }))
    end
    if hitNode and doc.pressNode == hitNode and not overPopup then
      if not hitNode.state.disabled then
        local ev = events.newEvent('click', { x = input.x, y = input.y, button = 1 })
        activateNode(doc, hitNode, ev)
        events.dispatch(doc, hitNode, ev)
      end
    end
    doc.pressNode = nil
  end

  if input.rightPressed and hitNode then
    events.dispatch(doc, hitNode, events.newEvent('contextmenu',
      { x = input.x, y = input.y, button = 2 }))
  end

  -- wheel -----------------------------------------------------------------
  if input.wheel and input.wheel ~= 0 and hitNode then
    local target = scrollableAncestor(hitNode)
    if target then
      local box = target.box
      local step = 42 * input.wheel
      target.state.scrollY = util.clamp((target.state.scrollY or 0) - step,
        0, box.maxScrollY or 0)
      doc.needsLayout = true
      events.dispatch(doc, target, events.newEvent('scroll',
        { scrollY = target.state.scrollY }))
    end
    if hitNode then
      events.dispatch(doc, hitNode, events.newEvent('wheel', { delta = input.wheel }))
    end
  end

  -- keyboard --------------------------------------------------------------
  local focus = doc.focusNode
  if focus then
    local keys = input.keys or {}
    if keys.escape then
      if doc.openSelect then
        doc.openSelect = nil
      else
        focus.state.focus = nil
        doc.focusNode = nil
        doc.needsStyle = true
      end
    end
    local kind = widgets.kind(focus)
    if (kind == 'text' or kind == 'number' or kind == 'textarea') and not doc.nativeText then
      local value = tostring(focus:getValue() or '')
      local changed = false
      if keys.backspace and #value > 0 then
        value = value:sub(1, util.prevCharStart(value, #value + 1) - 1)
        changed = true
      end
      for _, ch in ipairs(input.chars or {}) do
        if ch ~= '\n' and ch ~= '\r' then
          value = value .. ch
          changed = true
        end
      end
      if changed then commitValue(doc, focus, value, 'input') end
    end
    if keys.enter then
      events.dispatch(doc, focus, events.newEvent('change', { value = focus:getValue() }))
      events.dispatch(doc, focus, events.newEvent('submit', { value = focus:getValue() }))
    end
  elseif input.keys and input.keys.escape and doc.openSelect then
    doc.openSelect = nil
  end
end

events.isFocusable = isFocusable
events.scrollableAncestor = scrollableAncestor
events.commitValue = commitValue

return events
