-- moonhtml/window.lua -- glue between a Document and a mimgui frame.
--
-- Creates a chrome-less ImGui window and lets the HTML paint all of it,
-- including its own title bar (mark it `data-drag` to make it draggable).

local util = require 'moonhtml.util'
local document = require 'moonhtml.document'

local window = {}

local Window = {}
Window.__index = Window
window.Window = Window

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

--- opts (everything optional except the markup):
--   html / file        markup, or a path to an .html file
--   css                extra stylesheet text
--   env                table visible to inline handlers and <script>
--   title              ImGui window id (must be unique per window)
--   size               { width, height } in pixels, default { 640, 460 }
--   pos                { x, y } or 'center' (default)
--   visible            initial visibility, default false
--   key                virtual key code that toggles the window
--   lockPlayer         freeze player controls while the menu is open
--   fonts              font specs for the backend (see backends/mimgui.lua)
--   autoHeight         shrink the window to the content height
--   onError            error reporter
function window.new(opts)
  opts = opts or {}
  local ok, imgui = pcall(require, 'mimgui')
  if not ok then
    error('moonhtml: нужен mimgui в moonloader/lib/mimgui (' .. tostring(imgui) .. ')', 2)
  end
  local backendModule = require 'moonhtml.backends.mimgui'

  local self = setmetatable({}, Window)
  self.imgui = imgui
  self.backend = backendModule.new {
    fonts = opts.fonts,
    loadTexture = opts.loadTexture,
    scale = opts.scale,
  }
  self.title = opts.title or ('moonhtml##' .. tostring(self):gsub('%W', ''))
  self.size = opts.size or { 640, 460 }
  self.pos = opts.pos or 'center'
  self.visible = opts.visible or false
  self.autoHeight = opts.autoHeight or false
  self.lockPlayer = opts.lockPlayer

  local basePath = opts.basePath
  local htmlSource = opts.html
  if not htmlSource and opts.file then
    if not basePath then basePath = opts.file:match('^(.*[/\\])') or '' end
    local f = io.open(opts.file, 'rb')
    if not f then error('moonhtml: cannot open ' .. tostring(opts.file), 2) end
    htmlSource = f:read('*a')
    f:close()
  end

  self.doc = document.new {
    html = htmlSource or '<body></body>',
    css = opts.css,
    env = opts.env,
    basePath = basePath,
    width = self.size[1],
    height = self.size[2],
    fontSize = opts.fontSize,
    onError = opts.onError,
    measure = function(text, st) return self.backend.measure(text, st) end,
  }
  self.doc.nativeText = true -- ImGui owns text editing
  self.backend.onError = function(err) self.doc:reportError(err) end

  -- `data-close` closes the window, `data-drag` moves it
  self.doc:on('[data-close]', 'click', function() self:hide() end)

  -- ---- imgui wiring ----------------------------------------------------
  self.initHandle = imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    self.backend.loadFonts()
    if opts.onInitialize then opts.onInitialize(self) end
  end)

  self.frameHandle = imgui.OnFrame(
    function() return self.visible end,
    function(player) self:render(player) end
  )

  if opts.key then
    local wm = tryRequire 'windows.message'
    if wm and addEventHandler then
      addEventHandler('onWindowMessage', function(msg, wparam)
        if (msg == wm.WM_KEYDOWN or msg == wm.WM_SYSKEYDOWN) and wparam == opts.key then
          self:toggle()
        end
      end)
    end
  end

  return self
end

function Window:show(v)
  self.visible = (v == nil) and true or (v and true or false)
  return self
end

function Window:hide() return self:show(false) end
function Window:toggle() return self:show(not self.visible) end

function Window:setHTML(markup)
  self.doc:setHTML(markup)
  return self
end

function Window:addCSS(source)
  self.doc:addCSS(source)
  return self
end

function Window:on(...) self.doc:on(...) return self end
function Window:getElementById(id) return self.doc:getElementById(id) end
function Window:querySelector(sel) return self.doc:querySelector(sel) end
function Window:querySelectorAll(sel) return self.doc:querySelectorAll(sel) end
--- menu:setState('hp', 90) or menu:setState{ hp = 90, armour = 30 }
function Window:setState(k, v)
  if type(k) == 'table' then
    self.doc:setState(k)
  else
    self.doc.state[k] = v
  end
  return self
end

local function screenSize()
  if getScreenResolution then return getScreenResolution() end
  return 1280, 720
end

function Window:render(player)
  local imgui = self.imgui
  local w, h = self.size[1], self.size[2]

  if self.pos == 'center' then
    local sw, sh = screenSize()
    imgui.SetNextWindowPos(imgui.ImVec2(sw * 0.5, sh * 0.5),
      imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
  elseif type(self.pos) == 'table' then
    imgui.SetNextWindowPos(imgui.ImVec2(self.pos[1], self.pos[2]),
      imgui.Cond.FirstUseEver)
  end
  if self.pendingPos then
    imgui.SetNextWindowPos(imgui.ImVec2(self.pendingPos[1], self.pendingPos[2]),
      imgui.Cond.Always)
  end
  imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)

  -- the HTML paints all the chrome, so ImGui contributes nothing but a
  -- transparent, unmanaged surface to draw on
  local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
      + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
      + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoSavedSettings

  imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
  imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 0)
  imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0))
  imgui.Begin(self.title, nil, flags)

  local origin = imgui.GetWindowPos()
  local ox, oy = origin.x, origin.y

  local input = self.backend.input(ox, oy)
  -- if the backend could not drive ImGui's InputText, take typing back
  self.doc.nativeText = not self.backend.nativeBroken
  self.doc:setViewport(w, h)
  self.doc:update(input, os.clock())

  -- window dragging from any element marked `data-drag`
  if input.pressed and self.doc.hitNode then
    local dragger = self.doc.hitNode:closest(function(n)
      return n.type == 'element' and n:hasAttribute('data-drag')
    end)
    if dragger then
      self.dragOffset = { input.x, input.y }
    end
  end
  if not input.down then self.dragOffset = nil end
  if self.dragOffset and input.down then
    local io_ = imgui.GetIO()
    self.pendingPos = {
      io_.MousePos.x - self.dragOffset[1],
      io_.MousePos.y - self.dragOffset[2],
    }
  end

  if self.autoHeight then
    local _, contentH = self.doc:contentSize()
    local _, screenH = screenSize()
    self.size[2] = math.max(1, math.min(screenH, math.floor(contentH + 0.5)))
  end

  self.backend.draw(self.doc.displayList, ox, oy)
  self.backend.applyCursor(self.doc.cursor)

  imgui.End()
  imgui.PopStyleColor()
  imgui.PopStyleVar(2)

  if player and self.lockPlayer then player.LockPlayer = true end
end

return window
