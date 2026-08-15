-- moonhtml/document.lua -- the object a script actually holds on to.
--
--   local doc = moonhtml.newDocument{ html = ..., css = ... }
--   doc:on('#start', 'click', function() ... end)
--   doc:update(input, os.clock())   -- style -> layout -> events -> paint
--   local list = doc.displayList    -- hand to a backend

local util = require 'moonhtml.util'
local html = require 'moonhtml.html'
local cssmod = require 'moonhtml.css'
local dom = require 'moonhtml.dom'
local style = require 'moonhtml.style'
local layoutmod = require 'moonhtml.layout'
local paint = require 'moonhtml.paint'
local events = require 'moonhtml.events'
local widgets = require 'moonhtml.widgets'
local ua = require 'moonhtml.ua'

dom.setParser(html.parse)

local document = {}

local Document = {}
Document.__index = Document
document.Document = Document

local max = math.max

local function defaultLoader(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

--- opts:
--   html      markup string (or `file` = path)
--   css       extra stylesheet applied after the document's own <style>
--   width/height  viewport size in pixels
--   env       table exposed to inline handlers and <script> blocks
--   measure   function(text, computedStyle) -> width in pixels
--   basePath  directory used to resolve <link>/<script src>
--   onError   function(message)
function document.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Document)
  self.opts = opts
  self.width = opts.width or 640
  self.height = opts.height or 480
  self.basePath = opts.basePath or ''
  self.loader = opts.loader or defaultLoader
  self.onError = opts.onError
  self.measureFn = opts.measure or function(text, st)
    return util.utf8len(text) * st.fontSize * 0.5
  end
  self.engine = style.newEngine {
    width = self.width, height = self.height, fontSize = opts.fontSize or 14,
  }
  self.extraCss = opts.css or ''
  self.needsStyle = true
  self.needsLayout = true
  self.displayList = {}
  self.templates = {}
  self.delegates = {}
  self.measureCache = {}
  self.errors = {}

  -- `state` is a proxy over `_state` so that *every* assignment is seen,
  -- not just the first one for a key (which is all rawset/__newindex gives).
  local docSelf = self
  self._state = {}
  self.state = setmetatable({}, {
    __index = self._state,
    __newindex = function(_, k, v)
      if self._state[k] ~= v then
        self._state[k] = v
        docSelf.stateDirty = true
      end
    end,
    __len = function() return #docSelf._state end,
  })

  self.env = setmetatable({}, { __index = function(t, k)
    if k == 'document' or k == 'doc' then return docSelf end
    if k == 'state' then return docSelf.state end
    local e = opts.env
    if e and e[k] ~= nil then return e[k] end
    return _G[k]
  end })

  self:setHTML(opts.html or (opts.file and self.loader(opts.file)) or '<body></body>')
  return self
end

-- ------------------------------------------------------------- content ----

function Document:setHTML(markup)
  self.root = html.parse(markup, { document = self })
  self.root.ownerDocument = self
  self.root:walk(function(n) n.ownerDocument = self end)

  -- <body> becomes the layout root; synthesise one when missing
  local body = self.root:querySelector('body')
  if not body then
    body = dom.Node.new('element', 'body')
    body.ownerDocument = self
    local children = util.copy(self.root.children)
    for _, c in ipairs(children) do
      if not (c.type == 'element' and (c.tag == 'style' or c.tag == 'script'
            or c.tag == 'link' or c.tag == 'head')) then
        body:appendChild(c)
      end
    end
    self.root:appendChild(body)
  end
  self.body = body

  self:collectStyles()
  self:collectTemplates()
  self:runScripts()
  self.needsStyle = true
  self.needsLayout = true
  return self
end

function Document:collectStyles()
  local sheets = { { source = ua, origin = 0 } }
  for _, link in ipairs(self.root:getElementsByTagName('link')) do
    if link:getAttribute('rel', ''):lower() == 'stylesheet' then
      local href = link:getAttribute('href', '')
      local src = href ~= '' and self.loader(self.basePath .. href) or nil
      if src then
        sheets[#sheets + 1] = { source = src, origin = 1 }
      else
        self:reportError('moonhtml: cannot load stylesheet ' .. href)
      end
    end
  end
  for _, tag in ipairs(self.root:getElementsByTagName('style')) do
    sheets[#sheets + 1] = { source = tag:getText(), origin = 1 }
  end
  if self.extraCss ~= '' then
    sheets[#sheets + 1] = { source = self.extraCss, origin = 1 }
  end
  self.sheets = sheets
  self.engine:setStylesheets(sheets)
  self.needsStyle = true
  return self
end

--- Append a stylesheet at runtime (highest priority).
function Document:addCSS(source)
  self.extraCss = self.extraCss .. '\n' .. source
  self:collectStyles()
  return self
end

-- ------------------------------------------------------------ scripting ----

function Document:reportError(err)
  local msg = tostring(err)
  self.errors[#self.errors + 1] = msg
  if self.onError then
    self.onError(msg)
  else
    print('[moonhtml] ' .. msg)
  end
end

local chunkCache = {}

function Document:compile(code, name)
  local key = code
  local cached = chunkCache[key]
  if cached == false then return nil end
  local chunk, err
  if cached then
    chunk = cached
  else
    chunk, err = loadstring(code, name or 'moonhtml')
    if not chunk then
      chunkCache[key] = false
      self:reportError((err or 'compile error') .. ' in: ' .. code:sub(1, 80))
      return nil
    end
    chunkCache[key] = chunk
  end
  if setfenv then setfenv(chunk, self.env) end
  return chunk
end

function Document:runScripts()
  for _, tag in ipairs(self.root:getElementsByTagName('script')) do
    local src = tag:getAttribute('src', '')
    local code = tag:getText()
    if src ~= '' then
      code = self.loader(self.basePath .. src) or ''
      if code == '' then self:reportError('moonhtml: cannot load script ' .. src) end
    end
    if util.trim(code) ~= '' then
      local chunk = self:compile(code, 'moonhtml:script')
      if chunk then
        local ok, err = pcall(chunk)
        if not ok then self:reportError(err) end
      end
    end
  end
end

--- Run an `onclick="..."` style attribute.
function Document:runInlineHandler(node, code, event)
  local chunk = self:compile(code, 'moonhtml:handler')
  if not chunk then return end
  local prevEvent, prevThis = rawget(self.env, 'event'), rawget(self.env, 'this')
  rawset(self.env, 'event', event)
  rawset(self.env, 'this', node)
  local ok, err = pcall(chunk)
  rawset(self.env, 'event', prevEvent)
  rawset(self.env, 'this', prevThis)
  if not ok then self:reportError(err) end
end

--- Evaluate a `{{ expression }}` in the document environment.
function Document:eval(expr)
  local chunk = self:compile('return (' .. expr .. ')', 'moonhtml:expr')
  if not chunk then return '' end
  local ok, value = pcall(chunk)
  if not ok then
    self:reportError(value)
    return ''
  end
  if value == nil then return '' end
  if type(value) == 'number' then
    if value == math.floor(value) then return string.format('%d', value) end
    return string.format('%.2f', value)
  end
  return tostring(value)
end

-- ------------------------------------------------------------ templates ----

function Document:collectTemplates()
  self.templates = {}
  self.root:walk(function(n)
    if n.type == 'text' and not n.raw and (n.text or ''):find('{{', 1, true) then
      n.template = n.text
      self.templates[#self.templates + 1] = { node = n, kind = 'text' }
    elseif n.type == 'element' then
      for name, value in pairs(n.attrs) do
        if type(value) == 'string' and value:find('{{', 1, true) then
          n.attrTemplates = n.attrTemplates or {}
          n.attrTemplates[name] = value
          self.templates[#self.templates + 1] = { node = n, kind = 'attr', name = name }
        end
      end
    end
  end)
  self.stateDirty = true
end

function Document:applyTemplates()
  if #self.templates == 0 then return end
  for _, t in ipairs(self.templates) do
    if t.kind == 'text' then
      local rendered = t.node.template:gsub('{{(.-)}}', function(expr)
        return self:eval(util.trim(expr))
      end)
      if rendered ~= t.node.text then
        t.node.text = rendered
        self.needsLayout = true
      end
    else
      local source = t.node.attrTemplates[t.name]
      local rendered = source:gsub('{{(.-)}}', function(expr)
        return self:eval(util.trim(expr))
      end)
      if rendered ~= t.node.attrs[t.name] then
        t.node:setAttribute(t.name, rendered)
        t.node.attrTemplates[t.name] = source
        self.needsStyle = true
      end
    end
  end
end

-- ------------------------------------------------------------- queries ----

function Document:getElementById(id) return self.root:getElementById(id) end
function Document:querySelector(sel) return self.root:querySelector(sel) end
function Document:querySelectorAll(sel) return self.root:querySelectorAll(sel) end

function Document:createElement(tag)
  local n = dom.Node.new('element', tag)
  n.ownerDocument = self
  return n
end

--- doc:on('#id', 'click', fn) delegates; doc:on('click', fn) listens globally.
function Document:on(selector, etype, fn)
  if type(etype) == 'function' then
    self.root:addEventListener(selector, etype)
    return self
  end
  local docSelf = self
  self.root:addEventListener(etype, function(event)
    local n = event.target
    while n do
      if n.type == 'element' and n:matches(selector) then
        local ok, err = pcall(fn, event, n)
        if not ok then docSelf:reportError(err) end
        return
      end
      n = n.parent
    end
  end)
  return self
end

--- Merge a table into the document state (or force a re-render with no args).
function Document:setState(values)
  if type(values) == 'table' then
    for k, v in pairs(values) do self.state[k] = v end
  end
  self.stateDirty = true
  return self
end

--- Re-evaluate every {{ template }} on the next frame. Needed after mutating
-- a table held in state, which assignment tracking cannot see.
function Document:refresh()
  self.stateDirty = true
  self.needsStyle = true
  return self
end

function Document:setValue(selector, value)
  local n = self:querySelector(selector)
  if n then n:setValue(value) end
  return self
end

function Document:setText(selector, text)
  local n = self:querySelector(selector)
  if n then n:setText(text) end
  return self
end

-- --------------------------------------------------------------- frame ----

function Document:setViewport(w, h)
  if w == self.width and h == self.height then return self end
  self.width, self.height = w, h
  self.engine:setViewport(w, h)
  self.needsStyle = true
  self.needsLayout = true
  return self
end

function Document:measure(text, st)
  return self.measureFn(text, st)
end

local function replacedWidth(self)
  return function(node, st)
    local w = select(1, widgets.intrinsicSize(node, st, function(t, s)
      return self:measure(t, s)
    end))
    return w
  end
end

local function replacedHeight(self)
  return function(node, st)
    local _, h = widgets.intrinsicSize(node, st, function(t, s)
      return self:measure(t, s)
    end)
    return h
  end
end

function Document:restyle(now)
  self.engine:setViewport(self.width, self.height)
  local animating = self.engine:restyle(self.root, now or 0)
  self.animating = animating
  self.needsStyle = false
  -- only geometry-affecting property changes force a new layout pass
  if self.engine.layoutDirty or not self.rootBox then self.needsLayout = true end
end

function Document:layout()
  -- text metrics are immutable for a (font, size, string) triple, so the cache
  -- survives across layouts; it is only pruned when it grows unreasonable
  self.measureCacheSize = (self.measureCacheSize or 0) + 1
  if self.measureCacheSize > 64 then
    local n = 0
    for _ in pairs(self.measureCache) do n = n + 1 end
    if n > 4000 then self.measureCache = {} end
    self.measureCacheSize = 0
  end
  local rootBox = layoutmod.run(self.body, {
    measure = function(text, st) return self:measure(text, st) end,
    replacedWidth = replacedWidth(self),
    replacedHeight = replacedHeight(self),
    width = self.width,
    height = self.height,
    cache = self.measureCache,
    stretch = true,
  })
  self.rootBox = rootBox
  self.needsLayout = false
end

function Document:repaint()
  self.displayList = paint.run(self.rootBox, {
    measure = function(text, st) return self:measure(text, st) end,
    document = self,
  })
end

--- One full frame. `input` is the table documented in events.update.
function Document:update(input, now)
  now = now or 0
  self.now = now
  self.cursor = nil

  local dirty = false
  if self.stateDirty then
    self.stateDirty = false
    self:applyTemplates()
  end
  if self.needsStyle or self.animating then
    self:restyle(now)
    dirty = true
  end
  if self.needsLayout or not self.rootBox then
    self:layout()
    dirty = true
  end

  if input then
    events.update(self, input)
    -- reflect this frame's interaction immediately: no one-frame lag
    if self.needsStyle then self:restyle(now); dirty = true end
    if self.needsLayout then self:layout(); dirty = true end
    if self.stateDirty then
      self.stateDirty = false
      self:applyTemplates()
      if self.needsStyle then self:restyle(now); dirty = true end
      if self.needsLayout then self:layout(); dirty = true end
    end
  end

  -- an idle frame reuses the display list from the previous one
  if dirty or self.openSelect or self._lastOpenSelect or #self.displayList == 0 then
    self:repaint()
  end
  self._lastOpenSelect = self.openSelect
  return self.displayList
end

--- Natural size of the laid out content, ignoring any stretch to the viewport
-- (this is what an auto-sizing window wants to know).
function Document:contentSize()
  local b = self.rootBox
  if not b then return 0, 0 end
  return b.w, (b.scrollH or b.contentH or 0) + (b.frameH or 0)
end

function Document:dispatch(node, etype, props)
  return events.dispatch(self, node, events.newEvent(etype, props))
end

return document
