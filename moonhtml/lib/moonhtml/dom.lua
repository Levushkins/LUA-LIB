-- moonhtml/dom.lua -- the node tree and the DOM-ish API scripts talk to.

local util = require 'moonhtml.util'
local css = require 'moonhtml.css'

local dom = {}

local parseHTML -- injected by init.lua to avoid a require cycle
function dom.setParser(fn) parseHTML = fn end

-- ----------------------------------------------------------------- Node ----

local Node = {}
Node.__index = Node
dom.Node = Node

local function kebab(name)
  if name:find('%u') then
    return (name:gsub('%u', function(c) return '-' .. c:lower() end))
  end
  return name
end

local styleProxyMt = {
  __index = function(t, k)
    return rawget(t, '__decls')[kebab(k)]
  end,
  __newindex = function(t, k, v)
    local node = rawget(t, '__node')
    local decls = rawget(t, '__decls')
    local prop = kebab(k)
    if v == nil or v == '' then
      decls[prop] = nil
    else
      decls[prop] = tostring(v)
    end
    node:invalidateStyle()
  end,
  __call = function(t, k, v)
    t[k] = v
    return rawget(t, '__node')
  end,
}

function Node.new(ntype, tag)
  local self = setmetatable({}, Node)
  self.type = ntype or 'element'
  self.tag = tag
  self.attrs = {}
  self.children = {}
  self.classes = {}      -- ordered list
  self.classSet = {}     -- lookup
  self.state = {}        -- hover / active / focus / checked / value / ...
  self.listeners = {}
  self.inlineDecls = {}  -- parsed `style="..."`
  if self.type == 'element' then
    self.style = setmetatable(
      { __node = self, __decls = self.inlineDecls }, styleProxyMt)
  end
  return self
end

function Node:isElement() return self.type == 'element' end
function Node:isText() return self.type == 'text' end

-- ------------------------------------------------------------- tree ops ----

function Node:appendChild(child)
  if child.parent then child:remove() end
  child.parent = self
  child.ownerDocument = child.ownerDocument or self.ownerDocument
  self.children[#self.children + 1] = child
  self:invalidateStyle()
  return child
end

function Node:insertBefore(child, ref)
  if not ref then return self:appendChild(child) end
  if child.parent then child:remove() end
  child.parent = self
  child.ownerDocument = child.ownerDocument or self.ownerDocument
  for i = 1, #self.children do
    if self.children[i] == ref then
      table.insert(self.children, i, child)
      self:invalidateStyle()
      return child
    end
  end
  return self:appendChild(child)
end

function Node:removeChild(child)
  for i = 1, #self.children do
    if self.children[i] == child then
      table.remove(self.children, i)
      child.parent = nil
      self:invalidateStyle()
      return child
    end
  end
end

function Node:remove()
  if self.parent then self.parent:removeChild(self) end
  return self
end

function Node:clearChildren()
  for i = 1, #self.children do self.children[i].parent = nil end
  self.children = {}
  self:invalidateStyle()
  return self
end

function Node:index()
  if not self.parent then return 1 end
  local n = 0
  for _, c in ipairs(self.parent.children) do
    if c:isElement() then
      n = n + 1
      if c == self then return n end
    end
  end
  return n
end

function Node:elementChildren()
  local out = {}
  for _, c in ipairs(self.children) do
    if c:isElement() then out[#out + 1] = c end
  end
  return out
end

function Node:siblingCount()
  if not self.parent then return 1 end
  return #self.parent:elementChildren()
end

--- Depth-first walk. `fn` may return false to skip a subtree.
function Node:walk(fn)
  if fn(self) == false then return end
  for _, c in ipairs(self.children) do c:walk(fn) end
end

function Node:closest(pred)
  local n = self
  while n do
    if pred(n) then return n end
    n = n.parent
  end
end

-- ----------------------------------------------------------- attributes ----

function Node:setAttribute(name, value)
  name = name:lower()
  value = value == nil and '' or tostring(value)
  self.attrs[name] = value
  if name == 'id' then
    self.id = value
  elseif name == 'class' then
    self.classes = util.words(value)
    self.classSet = {}
    for _, c in ipairs(self.classes) do self.classSet[c] = true end
  elseif name == 'style' then
    self:setInlineStyle(value)
  elseif name == 'value' then
    self.state.value = value
  elseif name == 'checked' then
    self.state.checked = true
  elseif name == 'disabled' then
    self.state.disabled = true
  end
  self:invalidateStyle()
  return self
end

function Node:getAttribute(name, default)
  local v = self.attrs[name:lower()]
  if v == nil then return default end
  return v
end

function Node:hasAttribute(name) return self.attrs[name:lower()] ~= nil end

function Node:removeAttribute(name)
  name = name:lower()
  self.attrs[name] = nil
  if name == 'class' then
    self.classes, self.classSet = {}, {}
  elseif name == 'id' then
    self.id = nil
  elseif name == 'style' then
    for k in pairs(self.inlineDecls) do self.inlineDecls[k] = nil end
  elseif name == 'disabled' then
    self.state.disabled = nil
  end
  self:invalidateStyle()
  return self
end

function Node:setInlineStyle(text)
  for k in pairs(self.inlineDecls) do self.inlineDecls[k] = nil end
  for prop, value in pairs(css.parseDeclarations(text or '')) do
    self.inlineDecls[prop] = value
  end
  self:invalidateStyle()
  return self
end

-- ------------------------------------------------------------- classes ----

function Node:addClass(...)
  for _, name in ipairs({ ... }) do
    for _, c in ipairs(util.words(name)) do
      if not self.classSet[c] then
        self.classSet[c] = true
        self.classes[#self.classes + 1] = c
      end
    end
  end
  self:invalidateStyle()
  return self
end

function Node:removeClass(...)
  for _, name in ipairs({ ... }) do
    for _, c in ipairs(util.words(name)) do
      if self.classSet[c] then
        self.classSet[c] = nil
        local i = util.indexOf(self.classes, c)
        if i then table.remove(self.classes, i) end
      end
    end
  end
  self:invalidateStyle()
  return self
end

function Node:hasClass(name) return self.classSet[name] == true end

function Node:toggleClass(name, force)
  local want = force
  if want == nil then want = not self:hasClass(name) end
  if want then self:addClass(name) else self:removeClass(name) end
  return self
end

-- ---------------------------------------------------------------- text ----

function Node:getText()
  if self:isText() then return self.text or '' end
  local parts = {}
  for _, c in ipairs(self.children) do
    if c.type ~= 'comment' then parts[#parts + 1] = c:getText() end
  end
  return table.concat(parts)
end

function Node:setText(text)
  self:clearChildren()
  local t = Node.new('text')
  t.text = tostring(text)
  t.ownerDocument = self.ownerDocument
  self:appendChild(t)
  self:invalidateLayout()
  return self
end

function Node:setHTML(markup)
  assert(parseHTML, 'moonhtml: html parser not registered')
  self:clearChildren()
  local frag = parseHTML(markup, { document = self.ownerDocument })
  for _, c in ipairs(util.copy(frag.children)) do self:appendChild(c) end
  self:invalidateStyle()
  return self
end

function Node:append(markup)
  assert(parseHTML, 'moonhtml: html parser not registered')
  local frag = parseHTML(markup, { document = self.ownerDocument })
  for _, c in ipairs(util.copy(frag.children)) do self:appendChild(c) end
  self:invalidateStyle()
  return self
end

-- -------------------------------------------------------------- queries ----

function Node:matches(selector)
  local list = css.parseSelectorList(selector)
  for _, sel in ipairs(list) do
    if css.matches(sel, self) then return true end
  end
  return false
end

function Node:querySelectorAll(selector)
  local list = css.parseSelectorList(selector)
  local out = {}
  self:walk(function(n)
    if n:isElement() and n ~= self then
      for _, sel in ipairs(list) do
        if css.matches(sel, n) then
          out[#out + 1] = n
          break
        end
      end
    end
  end)
  return out
end

function Node:querySelector(selector)
  local list = css.parseSelectorList(selector)
  local found
  self:walk(function(n)
    if found then return false end
    if n:isElement() and n ~= self then
      for _, sel in ipairs(list) do
        if css.matches(sel, n) then
          found = n
          return false
        end
      end
    end
  end)
  return found
end

function Node:getElementById(id)
  local found
  self:walk(function(n)
    if found then return false end
    if n:isElement() and n.id == id then found = n; return false end
  end)
  return found
end

function Node:getElementsByClassName(name)
  local out = {}
  self:walk(function(n)
    if n:isElement() and n.classSet[name] then out[#out + 1] = n end
  end)
  return out
end

function Node:getElementsByTagName(tag)
  tag = tag:lower()
  local out = {}
  self:walk(function(n)
    if n:isElement() and (tag == '*' or n.tag == tag) then out[#out + 1] = n end
  end)
  return out
end

-- --------------------------------------------------------------- events ----

function Node:addEventListener(etype, fn, opts)
  etype = etype:lower():gsub('^on', '')
  local list = self.listeners[etype]
  if not list then
    list = {}
    self.listeners[etype] = list
  end
  list[#list + 1] = { fn = fn, capture = opts and opts.capture or false }
  return self
end

Node.on = Node.addEventListener

function Node:removeEventListener(etype, fn)
  etype = etype:lower():gsub('^on', '')
  local list = self.listeners[etype]
  if not list then return self end
  for i = #list, 1, -1 do
    if list[i].fn == fn then table.remove(list, i) end
  end
  return self
end

-- ------------------------------------------------------- form value api ----

function Node:getValue()
  if self.state.value ~= nil then return self.state.value end
  return self:getAttribute('value', '')
end

function Node:setValue(v)
  self.state.value = v
  self:invalidateLayout()
  return self
end

function Node:isChecked() return self.state.checked == true end

function Node:setChecked(v)
  self.state.checked = v and true or false
  return self
end

function Node:setDisabled(v)
  self.state.disabled = v and true or false
  self:invalidateStyle()
  return self
end

-- --------------------------------------------------------- invalidation ----

function Node:invalidateStyle()
  local doc = self.ownerDocument
  if doc then
    doc.needsStyle = true
    doc.needsLayout = true
  end
end

function Node:invalidateLayout()
  local doc = self.ownerDocument
  if doc then doc.needsLayout = true end
end

--- Convenience: show/hide via inline display.
function Node:show(displayValue)
  self.style.display = displayValue or nil
  if not displayValue then self.inlineDecls.display = nil end
  self:invalidateStyle()
  return self
end

function Node:hide()
  self.style.display = 'none'
  return self
end

function Node:toggle(force)
  local hidden = self.inlineDecls.display == 'none'
  local want = force
  if want == nil then want = hidden end
  if want then self:show() else self:hide() end
  return self
end

--- Absolute layout rectangle from the last frame (nil before first layout).
function Node:rect()
  local b = self.box
  if not b then return nil end
  return b.x, b.y, b.w, b.h
end

function Node:describe()
  if self:isText() then return '#text("' .. (self.text or ''):sub(1, 24) .. '")' end
  local s = '<' .. (self.tag or '?')
  if self.id then s = s .. '#' .. self.id end
  for _, c in ipairs(self.classes) do s = s .. '.' .. c end
  return s .. '>'
end

return dom
