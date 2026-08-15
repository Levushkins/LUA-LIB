-- moonhtml/backends/mimgui.lua -- replay a display list into an ImDrawList.
--
-- Everything ImGui-specific lives here. The rest of the library never touches
-- mimgui, which is why the same document renders in the headless test harness.
--
-- Defensive by design: cimgui bindings differ slightly between mimgui builds,
-- so overloaded calls (font-aware AddText in particular) are probed once at
-- runtime and the working variant is cached.

local util = require 'moonhtml.util'
local color = require 'moonhtml.color'

local backend = {}

local imgui = require 'mimgui'
local ffi = require 'ffi'

local floor, max, min = math.floor, math.max, math.min

local CORNER_TL, CORNER_TR, CORNER_BR, CORNER_BL = 1, 2, 4, 8
local CORNER_ALL = 15

local FLT_MAX = 3.402823466e+38

local function vec2(x, y) return imgui.ImVec2(x, y) end

-- ------------------------------------------------------------- fonts ----

local function fileExists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end

local function windowsFont(name)
  local dir = os.getenv('WINDIR')
  if not dir then return nil end
  local path = dir .. '\\Fonts\\' .. name
  if fileExists(path) then return path end
  return nil
end

--- Reasonable defaults: a real TTF with Cyrillic coverage when we can find one.
local function defaultFontSpecs()
  local regular = windowsFont('trebuc.ttf') or windowsFont('arial.ttf')
      or windowsFont('segoeui.ttf')
  local bold = windowsFont('trebucbd.ttf') or windowsFont('arialbd.ttf')
      or windowsFont('segoeuib.ttf')
  local mono = windowsFont('consola.ttf') or windowsFont('cour.ttf')
  local specs = {}
  if regular then
    specs[#specs + 1] = { family = 'default', weight = 'normal', file = regular,
      sizes = { 12, 14, 16, 18, 22, 28, 36 } }
  end
  if bold then
    specs[#specs + 1] = { family = 'default', weight = 'bold', file = bold,
      sizes = { 12, 14, 16, 18, 22, 28, 36 } }
  end
  if mono then
    specs[#specs + 1] = { family = 'mono', weight = 'normal', file = mono,
      sizes = { 12, 14, 16 } }
  end
  return specs
end

-- ------------------------------------------------------------ backend ----

function backend.new(opts)
  opts = opts or {}
  local self = {}
  self.fonts = {}          -- "family|weight|size" -> ImFont*
  self.fontList = {}       -- family|weight -> sorted { size, font }
  self.loaded = false
  self.specs = opts.fonts
  self.textures = {}
  -- keyed by node so replacing the document lets the buffers be collected
  self.buffers = setmetatable({}, { __mode = 'k' })
  self.opts = opts
  self.scale = opts.scale or 1

  -- ---- font loading (must run inside imgui.OnInitialize) --------------
  function self.loadFonts()
    if self.loaded then return end
    self.loaded = true
    local io_ = imgui.GetIO()
    local specs = self.specs
    if specs == nil then specs = defaultFontSpecs() end
    local ranges = nil
    pcall(function() ranges = io_.Fonts:GetGlyphRangesCyrillic() end)
    for _, spec in ipairs(specs) do
      if fileExists(spec.file) then
        for _, size in ipairs(spec.sizes or { 14 }) do
          local ok, font = pcall(function()
            return io_.Fonts:AddFontFromFileTTF(spec.file, size, nil, ranges)
          end)
          if ok and font ~= nil then
            local key = (spec.family or 'default') .. '|' .. (spec.weight or 'normal')
            local list = self.fontList[key]
            if not list then list = {}; self.fontList[key] = list end
            list[#list + 1] = { size = size, font = font }
          end
        end
      end
    end
    for _, list in pairs(self.fontList) do
      table.sort(list, function(a, b) return a.size < b.size end)
    end
    if opts.onFontsLoaded then opts.onFontsLoaded(self) end
  end

  local function isBold(st)
    local w = st and st.fontWeight
    if w == 'bold' or w == 'bolder' then return true end
    local n = tonumber(w)
    return n ~= nil and n >= 600
  end

  --- Best loaded font for a computed style, plus the size to draw it at.
  function self.pickFont(st)
    local size = (st and st.fontSize or 14) * self.scale
    local family = (st and st.fontFamily or 'default'):lower()
    if family ~= 'mono' then family = 'default' end
    local key = family .. '|' .. (isBold(st) and 'bold' or 'normal')
    local list = self.fontList[key] or self.fontList[family .. '|normal']
    if not list or #list == 0 then return nil, size end
    local best = list[#list].font
    for _, entry in ipairs(list) do
      if entry.size >= size - 0.5 then
        best = entry.font
        break
      end
    end
    return best, size
  end

  -- ---- text measurement ----------------------------------------------
  local measureMode = nil

  function self.measure(text, st)
    if text == nil or text == '' then return 0 end
    local font, size = self.pickFont(st)
    if font and measureMode ~= 'fallback' then
      if measureMode == nil then
        local ok, res = pcall(function()
          return font:CalcTextSizeA(size, FLT_MAX, 0, text)
        end)
        if ok and res and res.x then
          measureMode = 'font'
          return res.x
        end
        measureMode = 'fallback'
      else
        local ok, res = pcall(function()
          return font:CalcTextSizeA(size, FLT_MAX, 0, text)
        end)
        if ok and res and res.x then return res.x end
        measureMode = 'fallback'
      end
    end
    -- fallback: measure with the current font and scale the result
    local sz = imgui.CalcTextSize(text)
    local base = imgui.GetFontSize()
    if base and base > 0 then return sz.x * (size / base) end
    return sz.x
  end

  -- ---- draw list helpers ---------------------------------------------
  local textMode = nil

  local function drawText(dl, x, y, text, col, st)
    local font, size = self.pickFont(st)
    if font then
      if textMode == nil or textMode == 'fontptr' then
        local ok = pcall(function()
          dl:AddTextFontPtr(font, size, vec2(x, y), col, text)
        end)
        if ok then
          textMode = 'fontptr'
          return
        end
        textMode = 'overload'
      end
      if textMode == 'overload' then
        local ok = pcall(function()
          dl:AddText(font, size, vec2(x, y), col, text)
        end)
        if ok then return end
        textMode = 'pushfont'
      end
      if textMode == 'pushfont' then
        imgui.PushFont(font)
        dl:AddText(vec2(x, y), col, text)
        imgui.PopFont()
        return
      end
    end
    dl:AddText(vec2(x, y), col, text)
  end

  --- ImGui carries a single rounding value plus corner flags, so per-corner
  -- radii collapse to "largest radius, only on the corners that ask for one".
  local function corners(radius)
    if not radius then return false, false, false, false, 0 end
    local tl, tr, br, bl = (radius[1] or 0) > 0, (radius[2] or 0) > 0,
        (radius[3] or 0) > 0, (radius[4] or 0) > 0
    local r = max(radius[1] or 0, radius[2] or 0, radius[3] or 0, radius[4] or 0)
    return tl, tr, br, bl, r
  end

  local function cornerFlags(radius)
    local tl, tr, br, bl, r = corners(radius)
    local flags = (tl and CORNER_TL or 0) + (tr and CORNER_TR or 0)
        + (br and CORNER_BR or 0) + (bl and CORNER_BL or 0)
    if flags == 0 then return CORNER_ALL, 0 end
    return flags, r
  end

  local function fillRect(dl, x, y, w, h, col, radius)
    local flags, r = cornerFlags(radius)
    r = min(r, min(w, h) * 0.5)
    dl:AddRectFilled(vec2(x, y), vec2(x + w, y + h), col, r, flags)
  end

  --- Painted as a strip of bands. The first and last band keep the rounded
  -- corners of the box, so gradient buttons still look rounded.
  local function gradient(dl, cmd, alpha)
    local stops = cmd.stops
    local angle = cmd.angle % 360
    -- 0deg = to top, 90 = to right, 180 = to bottom, 270 = to left
    local horizontal = (angle >= 45 and angle < 135) or (angle >= 225 and angle < 315)
    local flip = (angle < 45 or angle >= 315) or (angle >= 225 and angle < 315)
    local BANDS = 24
    local tl, tr, br, bl, r = corners(cmd.radius)
    r = min(r, min(cmd.w, cmd.h) * 0.5)
    local startFlags, endFlags
    if horizontal then
      startFlags = (tl and CORNER_TL or 0) + (bl and CORNER_BL or 0)
      endFlags = (tr and CORNER_TR or 0) + (br and CORNER_BR or 0)
    else
      startFlags = (tl and CORNER_TL or 0) + (tr and CORNER_TR or 0)
      endFlags = (bl and CORNER_BL or 0) + (br and CORNER_BR or 0)
    end

    local function colorAt(t)
      if flip then t = 1 - t end
      local prev = stops[1]
      for i = 2, #stops do
        local s = stops[i]
        if t <= s.pos or i == #stops then
          local span = s.pos - prev.pos
          local k = span > 0 and util.clamp((t - prev.pos) / span, 0, 1) or 0
          return color.toU32(color.mix(prev.color, s.color, k), alpha)
        end
        prev = s
      end
      return color.toU32(stops[#stops].color, alpha)
    end

    for i = 0, BANDS - 1 do
      local t0 = i / BANDS
      local bandFlags = 0
      if i == 0 then bandFlags = startFlags end
      if i == BANDS - 1 then bandFlags = endFlags end
      local x, y, w, h
      if horizontal then
        x, w = cmd.x + cmd.w * t0, cmd.w / BANDS + 0.5
        y, h = cmd.y, cmd.h
      else
        y, h = cmd.y + cmd.h * t0, cmd.h / BANDS + 0.5
        x, w = cmd.x, cmd.w
      end
      dl:AddRectFilled(vec2(x, y), vec2(x + w, y + h),
        colorAt(t0 + 0.5 / BANDS),
        bandFlags ~= 0 and r or 0,
        bandFlags ~= 0 and bandFlags or CORNER_ALL)
    end
  end

  local function drawBorder(dl, cmd, alpha)
    local w4 = cmd.widths
    local c4 = cmd.colors
    local uniform = w4[1] == w4[2] and w4[2] == w4[3] and w4[3] == w4[4]
        and color.equals(c4[1], c4[2]) and color.equals(c4[2], c4[3])
        and color.equals(c4[3], c4[4])
    if uniform then
      if w4[1] <= 0 then return end
      local flags, r = cornerFlags(cmd.radius)
      r = min(r, min(cmd.w, cmd.h) * 0.5)
      local inset = w4[1] * 0.5
      dl:AddRect(vec2(cmd.x + inset, cmd.y + inset),
        vec2(cmd.x + cmd.w - inset, cmd.y + cmd.h - inset),
        color.toU32(c4[1], alpha), r, flags, w4[1])
      return
    end
    local x, y, w, h = cmd.x, cmd.y, cmd.w, cmd.h
    if w4[1] > 0 then
      dl:AddRectFilled(vec2(x, y), vec2(x + w, y + w4[1]), color.toU32(c4[1], alpha), 0, 0)
    end
    if w4[3] > 0 then
      dl:AddRectFilled(vec2(x, y + h - w4[3]), vec2(x + w, y + h), color.toU32(c4[3], alpha), 0, 0)
    end
    if w4[4] > 0 then
      dl:AddRectFilled(vec2(x, y), vec2(x + w4[4], y + h), color.toU32(c4[4], alpha), 0, 0)
    end
    if w4[2] > 0 then
      dl:AddRectFilled(vec2(x + w - w4[2], y), vec2(x + w, y + h), color.toU32(c4[2], alpha), 0, 0)
    end
  end

  -- ---- textures --------------------------------------------------------
  function self.texture(src)
    if src == nil or src == '' then return nil end
    local cached = self.textures[src]
    if cached ~= nil then
      if cached == false then return nil end
      return cached
    end
    local tex = nil
    if opts.loadTexture then
      local ok, res = pcall(opts.loadTexture, src)
      if ok then tex = res end
    end
    if tex == nil and imgui.CreateTextureFromFile then
      local ok, res = pcall(imgui.CreateTextureFromFile, src)
      if ok then tex = res end
    end
    self.textures[src] = tex or false
    return tex
  end

  -- ---- native ImGui widgets -------------------------------------------
  local function nativeInput(cmd, originX, originY)
    local node = cmd.node
    local id = tostring(node):gsub('%W', '')
    local buf = self.buffers[node]
    local capacity = tonumber(node:getAttribute('maxlength', '')) or 128
    if not buf then
      buf = imgui.new.char[capacity + 1]()
      self.buffers[node] = buf
      imgui.StrCopy(buf, tostring(node:getValue() or ''))
      node.state._nativeValue = tostring(node:getValue() or '')
    elseif node.state._nativeValue ~= tostring(node:getValue() or '') then
      imgui.StrCopy(buf, tostring(node:getValue() or ''))
      node.state._nativeValue = tostring(node:getValue() or '')
    end

    local st = cmd.style
    imgui.SetCursorScreenPos(vec2(cmd.x - 4, cmd.y - 2))
    imgui.PushItemWidth(cmd.w + 8)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(
      st.color[1] / 255, st.color[2] / 255, st.color[3] / 255, (st.color[4] or 1) * cmd.alpha))
    local font = self.pickFont(st)
    if font then imgui.PushFont(font) end
    local label = '##moonhtml_' .. id
    local changed
    if cmd.kind == 'textarea' then
      changed = imgui.InputTextMultiline(label, buf, capacity + 1, vec2(cmd.w + 8, cmd.h + 4))
    elseif node:getAttribute('type', '') == 'password' then
      changed = imgui.InputText(label, buf, capacity + 1, imgui.InputTextFlags.Password)
    else
      changed = imgui.InputText(label, buf, capacity + 1)
    end
    if font then imgui.PopFont() end
    imgui.PopStyleColor(4)
    imgui.PopItemWidth()
    if changed then
      local value = ffi.string(buf)
      node.state._nativeValue = value
      node:setValue(value)
      if self.onInput then self.onInput(node, value) end
    end
    if imgui.IsItemActive() then
      node.state.focus = true
    end
  end

  -- ---- main entry ------------------------------------------------------
  --- Replay `list` into the current window's draw list, offset by origin.
  function self.draw(list, originX, originY)
    local dl = imgui.GetWindowDrawList()
    originX, originY = originX or 0, originY or 0
    local clipDepth = 0
    for i = 1, #list do
      local cmd = list[i]
      local op = cmd.op
      local alpha = cmd.alpha or 1
      if op == 'rect' then
        fillRect(dl, cmd.x + originX, cmd.y + originY, cmd.w, cmd.h,
          color.toU32(cmd.color, alpha), cmd.radius)
      elseif op == 'text' then
        drawText(dl, cmd.x + originX, cmd.y + originY, cmd.text,
          color.toU32(cmd.color, alpha), cmd.style)
      elseif op == 'border' then
        drawBorder(dl, {
          x = cmd.x + originX, y = cmd.y + originY, w = cmd.w, h = cmd.h,
          widths = cmd.widths, colors = cmd.colors, radius = cmd.radius,
        }, alpha)
      elseif op == 'gradient' then
        gradient(dl, {
          x = cmd.x + originX, y = cmd.y + originY, w = cmd.w, h = cmd.h,
          angle = cmd.angle, stops = cmd.stops, radius = cmd.radius,
        }, alpha)
      elseif op == 'line' then
        dl:AddLine(vec2(cmd.x1 + originX, cmd.y1 + originY),
          vec2(cmd.x2 + originX, cmd.y2 + originY),
          color.toU32(cmd.color, alpha), cmd.thickness or 1)
      elseif op == 'circle' then
        if cmd.filled ~= false then
          dl:AddCircleFilled(vec2(cmd.cx + originX, cmd.cy + originY), cmd.r,
            color.toU32(cmd.color, alpha), 20)
        else
          dl:AddCircle(vec2(cmd.cx + originX, cmd.cy + originY), cmd.r,
            color.toU32(cmd.color, alpha), 20, cmd.thickness or 1)
        end
      elseif op == 'triangle' then
        local p = cmd.points
        dl:AddTriangleFilled(
          vec2(p[1] + originX, p[2] + originY),
          vec2(p[3] + originX, p[4] + originY),
          vec2(p[5] + originX, p[6] + originY),
          color.toU32(cmd.color, alpha))
      elseif op == 'clip' then
        dl:PushClipRect(vec2(cmd.x + originX, cmd.y + originY),
          vec2(cmd.x + cmd.w + originX, cmd.y + cmd.h + originY), true)
        clipDepth = clipDepth + 1
      elseif op == 'unclip' then
        if clipDepth > 0 then
          dl:PopClipRect()
          clipDepth = clipDepth - 1
        end
      elseif op == 'image' then
        local tex = self.texture(cmd.src)
        if tex then
          dl:AddImage(tex, vec2(cmd.x + originX, cmd.y + originY),
            vec2(cmd.x + cmd.w + originX, cmd.y + cmd.h + originY))
        else
          fillRect(dl, cmd.x + originX, cmd.y + originY, cmd.w, cmd.h,
            color.toU32(color.rgba(90, 90, 90, 0.35), alpha), cmd.radius)
        end
      elseif op == 'native' then
        if not self.nativeBroken then
          local ok, err = pcall(nativeInput, {
            node = cmd.node, style = cmd.style, kind = cmd.kind, alpha = alpha,
            x = cmd.x + originX, y = cmd.y + originY, w = cmd.w, h = cmd.h,
          }, originX, originY)
          if not ok then
            -- an ImGui build we cannot drive: stop trying and draw the text
            -- ourselves (moonhtml then handles typing on its own)
            self.nativeBroken = true
            if self.onError then
              self.onError('moonhtml: native InputText unavailable (' ..
                tostring(err) .. '), falling back to built-in text editing')
            end
          end
        end
        if self.nativeBroken then
          local st = cmd.style
          drawText(dl, cmd.x + originX,
            cmd.y + originY + (cmd.h - st.fontSize) * 0.5,
            cmd.text or '', color.toU32(cmd.color, alpha), st)
          if cmd.focused then
            local caretX = cmd.x + originX + self.measure(cmd.text or '', st) + 1
            dl:AddLine(vec2(caretX, cmd.y + originY + 2),
              vec2(caretX, cmd.y + originY + cmd.h - 2),
              color.toU32(cmd.color, alpha), 1)
          end
        end
      end
    end
    while clipDepth > 0 do
      dl:PopClipRect()
      clipDepth = clipDepth - 1
    end
  end

  -- ---- input -----------------------------------------------------------
  local prevKeys = {}
  local KEYMAP = {
    escape = 27, enter = 13, backspace = 8, tab = 9, delete = 46,
    left = 37, up = 38, right = 39, down = 40, space = 32,
  }

  --- Gather this frame's input in document coordinates.
  function self.input(originX, originY)
    local io_ = imgui.GetIO()
    local keys, chars = {}, {}

    -- typed characters, only needed when ImGui's own InputText is unavailable
    if self.nativeBroken then
      pcall(function()
        for i = 0, 15 do
          local c = io_.InputCharacters[i]
          if c == nil or tonumber(c) == 0 then break end
          chars[#chars + 1] = util.utf8char(tonumber(c))
        end
      end)
      if #chars == 0 then
        pcall(function()
          local queue = io_.InputQueueCharacters
          for i = 0, queue.Size - 1 do
            chars[#chars + 1] = util.utf8char(tonumber(queue.Data[i]))
          end
        end)
      end
    end

    for name, vk in pairs(KEYMAP) do
      local down = false
      pcall(function() down = io_.KeysDown[vk] end)
      if down and not prevKeys[name] then keys[name] = true end
      keys[name .. 'Down'] = down or nil
      prevKeys[name] = down
    end
    local wheel = io_.MouseWheel
    return {
      x = io_.MousePos.x - (originX or 0),
      y = io_.MousePos.y - (originY or 0),
      down = io_.MouseDown[0],
      pressed = imgui.IsMouseClicked(0),
      released = imgui.IsMouseReleased(0),
      rightPressed = imgui.IsMouseClicked(1),
      wheel = wheel,
      chars = chars,
      keys = keys,
      inside = true,
      shift = io_.KeyShift,
      ctrl = io_.KeyCtrl,
    }
  end

  local CURSORS = {
    pointer = 'Hand', text = 'TextInput', move = 'ResizeAll',
    ['ew-resize'] = 'ResizeEW', ['ns-resize'] = 'ResizeNS',
    ['not-allowed'] = 'NotAllowed',
  }

  function self.applyCursor(cursor)
    local name = CURSORS[cursor or 'default']
    if not name then return end
    local enum = imgui.MouseCursor and imgui.MouseCursor[name]
    if enum then pcall(imgui.SetMouseCursor, enum) end
  end

  return self
end

backend.defaultFontSpecs = defaultFontSpecs

return backend
