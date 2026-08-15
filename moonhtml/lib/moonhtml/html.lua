-- moonhtml/html.lua -- forgiving HTML tokenizer / tree builder.
--
-- Produces a tree of dom.Node. It is deliberately lenient: unknown tags are
-- kept, unclosed tags are auto-closed, stray end tags are ignored -- the same
-- survival strategy a browser uses, because menu markup is written by hand.

local util = require 'moonhtml.util'
local dom = require 'moonhtml.dom'

local html = {}

local VOID = {
  area = true, base = true, br = true, col = true, embed = true, hr = true,
  img = true, input = true, link = true, meta = true, param = true,
  source = true, track = true, wbr = true,
}

-- elements whose content is taken verbatim until the matching close tag
local RAW_TEXT = { script = true, style = true }

-- start tag -> set of open tags it implicitly closes
local AUTO_CLOSE = {
  li = { li = true },
  p = { p = true },
  option = { option = true },
  optgroup = { optgroup = true, option = true },
  td = { td = true, th = true },
  th = { td = true, th = true },
  tr = { tr = true, td = true, th = true },
  dt = { dt = true, dd = true },
  dd = { dt = true, dd = true },
}

local ENTITIES = {
  amp = '&', lt = '<', gt = '>', quot = '"', apos = "'",
  nbsp = '\194\160', copy = '\194\169', reg = '\194\174', deg = '\194\176',
  laquo = '\194\171', raquo = '\194\187', middot = '\194\183',
  hellip = '\226\128\166', mdash = '\226\128\148', ndash = '\226\128\147',
  lsquo = '\226\128\152', rsquo = '\226\128\153',
  ldquo = '\226\128\156', rdquo = '\226\128\157',
  bull = '\226\128\162', dagger = '\226\128\160', euro = '\226\130\172',
  times = '\195\151', check = '\226\156\147', cross = '\226\156\151',
  larr = '\226\134\144', uarr = '\226\134\145',
  rarr = '\226\134\146', darr = '\226\134\147',
  spades = '\226\153\160', hearts = '\226\153\165',
  diams = '\226\153\166', clubs = '\226\153\163', star = '\226\152\133',
}

--- Decode HTML entities (named + numeric) in a text run.
function html.decodeEntities(s)
  if not s:find('&', 1, true) then return s end
  s = s:gsub('&#[xX](%x+);', function(h)
    return util.utf8char(tonumber(h, 16) or 63)
  end)
  s = s:gsub('&#(%d+);', function(d)
    return util.utf8char(tonumber(d) or 63)
  end)
  s = s:gsub('&(%a+);', function(name)
    return ENTITIES[name] or ENTITIES[name:lower()] or ('&' .. name .. ';')
  end)
  return s
end

local function parseAttributes(src)
  local attrs, order = {}, {}
  local pos = 1
  local n = #src
  while pos <= n do
    local s, e, name = src:find('^%s*([^%s=/>]+)', pos)
    if not s then break end
    pos = e + 1
    local value = ''
    local es, ee = src:find('^%s*=%s*', pos)
    if es then
      pos = ee + 1
      local q = src:sub(pos, pos)
      if q == '"' or q == "'" then
        local close = src:find(q, pos + 1, true) or (n + 1)
        value = src:sub(pos + 1, close - 1)
        pos = close + 1
      else
        local vs, ve, v = src:find('^([^%s>]*)', pos)
        value = v or ''
        pos = ve + 1
      end
      value = html.decodeEntities(value)
    else
      value = name -- boolean attribute: <input disabled>
    end
    name = name:lower()
    if attrs[name] == nil then order[#order + 1] = name end
    attrs[name] = value
  end
  return attrs, order
end

--- Parse an HTML source string into a document node.
-- @param src   markup
-- @param opts  { document = <ownerDocument to attach nodes to> }
function html.parse(src, opts)
  opts = opts or {}
  src = tostring(src or '')
  -- normalise line endings, strip a UTF-8 BOM
  src = src:gsub('\r\n', '\n'):gsub('^\239\187\191', '')

  local root = dom.Node.new('document', '#document')
  root.ownerDocument = opts.document
  local stack = { root }
  local pos, n = 1, #src

  local function top() return stack[#stack] end

  local function addText(text)
    if text == '' then return end
    local node = dom.Node.new('text')
    node.text = html.decodeEntities(text)
    node.ownerDocument = opts.document
    top():appendChild(node)
  end

  local function closeTag(tag)
    for i = #stack, 2, -1 do
      if stack[i].tag == tag then
        for _ = #stack, i, -1 do table.remove(stack) end
        return true
      end
    end
    return false -- stray end tag, ignore
  end

  while pos <= n do
    local lt = src:find('<', pos, true)
    if not lt then
      addText(src:sub(pos))
      break
    end
    if lt > pos then addText(src:sub(pos, lt - 1)) end

    local rest = src:sub(lt)
    if rest:sub(1, 4) == '<!--' then
      local close = src:find('-->', lt + 4, true)
      local stop = close and (close + 2) or n
      local node = dom.Node.new('comment')
      node.text = src:sub(lt + 4, (close or n + 1) - 1)
      node.ownerDocument = opts.document
      top():appendChild(node)
      pos = stop + 1
    elseif rest:sub(1, 2) == '<!' or rest:sub(1, 2) == '<?' then
      local close = src:find('>', lt, true) or n
      pos = close + 1
    elseif rest:sub(1, 2) == '</' then
      local close = src:find('>', lt, true) or n
      local tag = util.trim(src:sub(lt + 2, close - 1)):lower()
      closeTag(tag)
      pos = close + 1
    else
      -- start tag: find the '>' that is not inside a quoted attribute value
      local i, close = lt + 1, nil
      while i <= n do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
          local q = src:find(c, i + 1, true)
          i = q and (q + 1) or (n + 1)
        elseif c == '>' then
          close = i
          break
        else
          i = i + 1
        end
      end
      close = close or n
      local inner = src:sub(lt + 1, close - 1)
      local selfClosing = false
      if inner:sub(-1) == '/' then
        selfClosing = true
        inner = inner:sub(1, -2)
      end
      local tag = inner:match('^([%a][%w:_%-]*)')
      if not tag then
        addText(src:sub(lt, close))
        pos = close + 1
      else
        tag = tag:lower()
        local attrs, order = parseAttributes(inner:sub(#tag + 1))
        local auto = AUTO_CLOSE[tag]
        if auto then
          while #stack > 1 and auto[top().tag] do table.remove(stack) end
        end

        local node = dom.Node.new('element', tag)
        node.ownerDocument = opts.document
        node.attrOrder = order
        for k, v in pairs(attrs) do node:setAttribute(k, v) end
        top():appendChild(node)
        pos = close + 1

        if RAW_TEXT[tag] then
          local sIdx, eIdx = src:find('</%s*' .. tag .. '%s*>', pos)
          local content = src:sub(pos, (sIdx or n + 1) - 1)
          if content ~= '' then
            local t = dom.Node.new('text')
            t.text = content -- verbatim: no entity decoding in raw text
            t.raw = true
            t.ownerDocument = opts.document
            node:appendChild(t)
          end
          pos = (eIdx or n) + 1
        elseif not (selfClosing or VOID[tag]) then
          stack[#stack + 1] = node
        end
      end
    end
  end

  return root
end

html.VOID = VOID
html.RAW_TEXT = RAW_TEXT

return html
