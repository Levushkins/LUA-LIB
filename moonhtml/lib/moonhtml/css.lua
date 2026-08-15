-- moonhtml/css.lua -- stylesheet + selector parsing, shorthand expansion and
-- selector matching. No layout knowledge lives here.

local util = require 'moonhtml.util'

local css = {}

-- ------------------------------------------------------------ shorthands ----

local BOX_SIDES = { 'top', 'right', 'bottom', 'left' }

local function sides(values)
  local t, r, b, l
  local n = #values
  if n == 1 then
    t, r, b, l = values[1], values[1], values[1], values[1]
  elseif n == 2 then
    t, r, b, l = values[1], values[2], values[1], values[2]
  elseif n == 3 then
    t, r, b, l = values[1], values[2], values[3], values[2]
  elseif n >= 4 then
    t, r, b, l = values[1], values[2], values[3], values[4]
  else
    return nil
  end
  return { t, r, b, l }
end

local BORDER_STYLES = {
  none = true, hidden = true, solid = true, dashed = true, dotted = true,
  double = true, groove = true, ridge = true, inset = true, outset = true,
}

local FONT_WEIGHTS = {
  normal = true, bold = true, bolder = true, lighter = true,
  ['100'] = true, ['200'] = true, ['300'] = true, ['400'] = true,
  ['500'] = true, ['600'] = true, ['700'] = true, ['800'] = true, ['900'] = true,
}

local function setBorderSide(out, side, value)
  local parts = util.valueParts(value)
  for _, p in ipairs(parts) do
    local lp = p:lower()
    if BORDER_STYLES[lp] then
      out['border-' .. side .. '-style'] = lp
    elseif p:match('^[%d%.]+') or lp == 'thin' or lp == 'medium' or lp == 'thick' then
      out['border-' .. side .. '-width'] = p
    else
      out['border-' .. side .. '-color'] = p
    end
  end
  if out['border-' .. side .. '-style'] == nil then
    out['border-' .. side .. '-style'] = 'solid'
  end
end

--- Expand a shorthand property into longhands, writing into `out`.
-- Returns true when `prop` was handled as a shorthand.
function css.expandShorthand(prop, value, out)
  local parts = util.valueParts(value)

  if prop == 'margin' or prop == 'padding' then
    local s = sides(parts)
    if not s then return true end
    for i, side in ipairs(BOX_SIDES) do out[prop .. '-' .. side] = s[i] end
    return true
  elseif prop == 'inset' then
    local s = sides(parts)
    if not s then return true end
    for i, side in ipairs(BOX_SIDES) do out[side] = s[i] end
    return true
  elseif prop == 'border' then
    for _, side in ipairs(BOX_SIDES) do setBorderSide(out, side, value) end
    return true
  elseif prop == 'border-top' or prop == 'border-right'
      or prop == 'border-bottom' or prop == 'border-left' then
    setBorderSide(out, prop:sub(8), value)
    return true
  elseif prop == 'border-width' or prop == 'border-style' or prop == 'border-color' then
    local key = prop:sub(8)
    local s = sides(parts)
    if not s then return true end
    for i, side in ipairs(BOX_SIDES) do out['border-' .. side .. '-' .. key] = s[i] end
    return true
  elseif prop == 'border-radius' then
    local s = sides(parts)
    if not s then return true end
    out['border-top-left-radius'] = s[1]
    out['border-top-right-radius'] = s[2]
    out['border-bottom-right-radius'] = s[3]
    out['border-bottom-left-radius'] = s[4]
    return true
  elseif prop == 'background' then
    for _, p in ipairs(util.splitTopLevel(value, ' ')) do
      if p ~= '' then
        if p:lower():match('^linear%-gradient') or p:lower():match('^url') then
          out['background-image'] = p
        elseif p:lower() == 'none' then
          out['background-image'] = 'none'
        else
          out['background-color'] = p
        end
      end
    end
    return true
  elseif prop == 'font' then
    -- font: [style] [weight] size[/line-height] family...
    local i = 1
    while parts[i] do
      local lp = parts[i]:lower()
      if lp == 'italic' or lp == 'oblique' or lp == 'normal' then
        out['font-style'] = lp
      elseif FONT_WEIGHTS[lp] then
        out['font-weight'] = lp
      else
        break
      end
      i = i + 1
    end
    if parts[i] then
      local size, lh = parts[i]:match('^([^/]+)/(.+)$')
      out['font-size'] = size or parts[i]
      if lh then out['line-height'] = lh end
      i = i + 1
    end
    if parts[i] then
      out['font-family'] = table.concat(parts, ' ', i)
    end
    return true
  elseif prop == 'flex' then
    if #parts == 1 and tonumber(parts[1]) then
      out['flex-grow'] = parts[1]
      out['flex-shrink'] = '1'
      out['flex-basis'] = '0'
    elseif parts[1] == 'none' then
      out['flex-grow'] = '0'; out['flex-shrink'] = '0'; out['flex-basis'] = 'auto'
    elseif parts[1] == 'auto' then
      out['flex-grow'] = '1'; out['flex-shrink'] = '1'; out['flex-basis'] = 'auto'
    else
      out['flex-grow'] = parts[1] or '0'
      out['flex-shrink'] = parts[2] or '1'
      out['flex-basis'] = parts[3] or 'auto'
    end
    return true
  elseif prop == 'flex-flow' then
    for _, p in ipairs(parts) do
      if p:find('wrap') then out['flex-wrap'] = p else out['flex-direction'] = p end
    end
    return true
  elseif prop == 'gap' then
    out['row-gap'] = parts[1]
    out['column-gap'] = parts[2] or parts[1]
    return true
  elseif prop == 'overflow' then
    out['overflow-x'] = parts[1]
    out['overflow-y'] = parts[2] or parts[1]
    return true
  elseif prop == 'place-items' then
    out['align-items'] = parts[1]
    out['justify-items'] = parts[2] or parts[1]
    return true
  end
  return false
end

-- ---------------------------------------------------------- declarations ----

--- Parse a declaration block body ("color: red; margin: 4px").
-- Returns { prop = value } with shorthands expanded, plus { prop = true }
-- for !important declarations.
function css.parseDeclarations(text)
  local decls, important = {}, {}
  if not text or text == '' then return decls, important end
  for _, chunk in ipairs(util.splitTopLevel(text, ';')) do
    if chunk ~= '' then
      local prop, value = chunk:match('^([^:]+):(.*)$')
      if prop and value then
        prop = util.trim(prop):lower()
        value = util.trim(value)
        local imp = false
        local stripped = value:gsub('!%s*important%s*$', function() imp = true; return '' end)
        value = util.trim(stripped)
        if prop:sub(1, 2) == '--' then
          decls[prop] = value -- custom property, kept verbatim
          if imp then important[prop] = true end
        elseif not css.expandShorthand(prop, value, decls) then
          decls[prop] = value
          if imp then important[prop] = true end
        elseif imp then
          -- mark every longhand the shorthand produced
          local probe = {}
          css.expandShorthand(prop, value, probe)
          for k in pairs(probe) do important[k] = true end
        end
      end
    end
  end
  return decls, important
end

-- -------------------------------------------------------------- selectors ----

local COMBINATORS = { ['>'] = 'child', ['+'] = 'adjacent', ['~'] = 'sibling' }

local function parseCompound(text)
  local c = { classes = {}, attrs = {}, pseudos = {} }
  local pos = 1
  local n = #text
  local first = text:sub(1, 1)
  if first == '*' then
    c.tag = nil
    pos = 2
  else
    local tag = text:match('^([%a][%w_%-]*)')
    if tag then
      c.tag = tag:lower()
      pos = #tag + 1
    end
  end
  while pos <= n do
    local ch = text:sub(pos, pos)
    if ch == '#' then
      local id = text:match('^#([%w_%-]+)', pos)
      if not id then break end
      c.id = id
      pos = pos + #id + 1
    elseif ch == '.' then
      local cl = text:match('^%.([%w_%-]+)', pos)
      if not cl then break end
      c.classes[#c.classes + 1] = cl
      pos = pos + #cl + 1
    elseif ch == '[' then
      local close = text:find(']', pos, true)
      if not close then break end
      local body = text:sub(pos + 1, close - 1)
      local name, op, value = body:match('^%s*([%w_%-]+)%s*([~^$*|]?=)%s*(.+)%s*$')
      if name then
        value = util.trim(value):gsub('^["\']', ''):gsub('["\']$', '')
        c.attrs[#c.attrs + 1] = { name = name:lower(), op = op, value = value }
      else
        c.attrs[#c.attrs + 1] = { name = util.trim(body):lower() }
      end
      pos = close + 1
    elseif ch == ':' then
      local doubled = text:sub(pos + 1, pos + 1) == ':'
      local start = doubled and pos + 2 or pos + 1
      local name = text:match('^([%w_%-]+)', start)
      if not name then break end
      pos = start + #name
      local arg
      if text:sub(pos, pos) == '(' then
        local depth, i = 0, pos
        while i <= n do
          local cc = text:sub(i, i)
          if cc == '(' then depth = depth + 1
          elseif cc == ')' then
            depth = depth - 1
            if depth == 0 then break end
          end
          i = i + 1
        end
        arg = text:sub(pos + 1, i - 1)
        pos = i + 1
      end
      c.pseudos[#c.pseudos + 1] = {
        name = name:lower(), arg = arg, element = doubled,
      }
    else
      pos = pos + 1 -- unknown character, skip
    end
  end
  return c
end

--- Parse one complex selector ("nav > .item:hover span").
function css.parseSelector(text)
  text = util.trim(text)
  local sel = { parts = {}, spec = { 0, 0, 0 }, source = text }
  local tokens = {}
  local pos, n = 1, #text
  local buf = ''
  local function flush()
    if util.trim(buf) ~= '' then tokens[#tokens + 1] = util.trim(buf) end
    buf = ''
  end
  while pos <= n do
    local ch = text:sub(pos, pos)
    if ch == ' ' or ch == '\t' or ch == '\n' then
      flush()
      tokens[#tokens + 1] = ' '
      while text:sub(pos + 1, pos + 1):match('^%s') do pos = pos + 1 end
    elseif COMBINATORS[ch] then
      flush()
      tokens[#tokens + 1] = ch
    elseif ch == '(' then
      local depth, i = 0, pos
      while i <= n do
        local cc = text:sub(i, i)
        if cc == '(' then depth = depth + 1
        elseif cc == ')' then
          depth = depth - 1
          if depth == 0 then break end
        end
        i = i + 1
      end
      buf = buf .. text:sub(pos, i)
      pos = i
    else
      buf = buf .. ch
    end
    pos = pos + 1
  end
  flush()

  -- collapse "descendant" markers that sit next to explicit combinators
  local cleaned = {}
  for _, t in ipairs(tokens) do
    if t == ' ' and (#cleaned == 0 or COMBINATORS[cleaned[#cleaned]]) then
      -- drop
    elseif COMBINATORS[t] and cleaned[#cleaned] == ' ' then
      cleaned[#cleaned] = t
    else
      cleaned[#cleaned + 1] = t
    end
  end
  if cleaned[#cleaned] == ' ' then table.remove(cleaned) end

  local comb = nil
  for _, t in ipairs(cleaned) do
    if t == ' ' then
      comb = 'descendant'
    elseif COMBINATORS[t] then
      comb = COMBINATORS[t]
    else
      local compound = parseCompound(t)
      compound.combinator = comb
      comb = nil
      sel.parts[#sel.parts + 1] = compound
      if compound.id then sel.spec[1] = sel.spec[1] + 1 end
      sel.spec[2] = sel.spec[2] + #compound.classes + #compound.attrs
      for _, p in ipairs(compound.pseudos) do
        if p.element then sel.spec[3] = sel.spec[3] + 1 else sel.spec[2] = sel.spec[2] + 1 end
      end
      if compound.tag then sel.spec[3] = sel.spec[3] + 1 end
    end
  end
  return sel
end

local selectorListCache = {}

function css.parseSelectorList(text)
  local cached = selectorListCache[text]
  if cached then return cached end
  local out = {}
  for _, part in ipairs(util.splitTopLevel(text, ',')) do
    if util.trim(part) ~= '' then out[#out + 1] = css.parseSelector(part) end
  end
  selectorListCache[text] = out
  return out
end

-- --------------------------------------------------------------- matching ----

local function attrMatches(node, a)
  local v = node.attrs[a.name]
  if v == nil then return false end
  if not a.op then return true end
  if a.op == '=' then return v == a.value end
  if a.op == '^=' then return util.startsWith(v, a.value) end
  if a.op == '$=' then return util.endsWith(v, a.value) end
  if a.op == '*=' then return v:find(a.value, 1, true) ~= nil end
  if a.op == '~=' then return util.contains(util.words(v), a.value) end
  if a.op == '|=' then return v == a.value or util.startsWith(v, a.value .. '-') end
  return false
end

local function nthMatches(arg, index)
  arg = util.trim(arg or ''):lower()
  if arg == 'odd' then return index % 2 == 1 end
  if arg == 'even' then return index % 2 == 0 end
  local num = tonumber(arg)
  if num then return index == num end
  local a, b = arg:match('^([%+%-]?%d*)n%s*([%+%-]%s*%d+)$')
  if a then
    local av = (a == '' or a == '+') and 1 or (a == '-' and -1 or tonumber(a))
    local bv = tonumber((b:gsub('%s', ''))) or 0
    if av == 0 then return index == bv end
    local k = (index - bv) / av
    return k >= 0 and k == math.floor(k)
  end
  local a2 = arg:match('^([%+%-]?%d*)n$')
  if a2 then
    local av = (a2 == '' or a2 == '+') and 1 or (a2 == '-' and -1 or tonumber(a2))
    if av == 0 then return false end
    local k = index / av
    return k >= 0 and k == math.floor(k)
  end
  return false
end

local matchCompound -- forward

local function pseudoMatches(node, p)
  local name = p.name
  if p.element then
    return name == 'before' or name == 'after' -- handled by the style engine
  end
  local st = node.state
  if name == 'hover' then return st.hover == true end
  if name == 'active' then return st.active == true end
  if name == 'focus' or name == 'focus-visible' then return st.focus == true end
  if name == 'focus-within' then
    local found = false
    node:walk(function(n) if n.state and n.state.focus then found = true end end)
    return found
  end
  if name == 'checked' then return st.checked == true end
  if name == 'disabled' then return st.disabled == true end
  if name == 'enabled' then return st.disabled ~= true end
  if name == 'selected' then return st.selected == true end
  if name == 'root' then return node.parent == nil or node.parent.type == 'document' end
  if name == 'empty' then return #node.children == 0 end
  if name == 'first-child' then return node:index() == 1 end
  if name == 'last-child' then return node:index() == node:siblingCount() end
  if name == 'only-child' then return node:siblingCount() == 1 end
  if name == 'nth-child' then return nthMatches(p.arg, node:index()) end
  if name == 'nth-last-child' then
    return nthMatches(p.arg, node:siblingCount() - node:index() + 1)
  end
  if name == 'not' then
    for _, sel in ipairs(css.parseSelectorList(p.arg or '')) do
      if css.matches(sel, node) then return false end
    end
    return true
  end
  if name == 'is' or name == 'where' or name == 'any' then
    for _, sel in ipairs(css.parseSelectorList(p.arg or '')) do
      if css.matches(sel, node) then return true end
    end
    return false
  end
  return false
end

matchCompound = function(c, node)
  if not node or node.type ~= 'element' then return false end
  if c.tag and node.tag ~= c.tag then return false end
  if c.id and node.id ~= c.id then return false end
  for _, cl in ipairs(c.classes) do
    if not node.classSet[cl] then return false end
  end
  for _, a in ipairs(c.attrs) do
    if not attrMatches(node, a) then return false end
  end
  for _, p in ipairs(c.pseudos) do
    if not pseudoMatches(node, p) then return false end
  end
  return true
end

local function prevElementSibling(node)
  local parent = node.parent
  if not parent then return nil end
  local prev
  for _, c in ipairs(parent.children) do
    if c == node then return prev end
    if c.type == 'element' then prev = c end
  end
end

--- Does `sel` (a parsed complex selector) match `node`?
function css.matches(sel, node)
  local parts = sel.parts
  local i = #parts
  if i == 0 then return false end
  if not matchCompound(parts[i], node) then return false end

  local current = node
  i = i - 1
  while i >= 1 do
    local part = parts[i]
    local comb = parts[i + 1].combinator or 'descendant'
    if comb == 'child' then
      current = current.parent
      if not matchCompound(part, current) then return false end
    elseif comb == 'adjacent' then
      current = prevElementSibling(current)
      if not matchCompound(part, current) then return false end
    elseif comb == 'sibling' then
      local found = false
      local n = prevElementSibling(current)
      while n do
        if matchCompound(part, n) then
          current = n
          found = true
          break
        end
        n = prevElementSibling(n)
      end
      if not found then return false end
    else -- descendant
      local n = current.parent
      local found = false
      while n do
        if matchCompound(part, n) then
          current = n
          found = true
          break
        end
        n = n.parent
      end
      if not found then return false end
    end
    i = i - 1
  end
  return true
end

--- Bucket key of the rightmost compound, used to index rules.
function css.rightKey(sel)
  local c = sel.parts[#sel.parts]
  if not c then return '*', '*' end
  if c.id then return 'id', c.id end
  if #c.classes > 0 then return 'class', c.classes[1] end
  if c.tag then return 'tag', c.tag end
  return '*', '*'
end

--- Pseudo-classes used by a selector; lets the engine know a rule is dynamic.
function css.dynamicPseudos(sel)
  local out = nil
  for _, part in ipairs(sel.parts) do
    for _, p in ipairs(part.pseudos) do
      if p.name == 'hover' or p.name == 'active' or p.name == 'focus'
          or p.name == 'checked' or p.name == 'focus-within' then
        out = out or {}
        out[p.name] = true
      end
    end
  end
  return out
end

-- ------------------------------------------------------------ stylesheet ----

local function skipComments(src)
  return (src:gsub('/%*.-%*/', ' '))
end

--- Read a balanced { ... } block starting at `pos` (which must be the brace).
-- Returns body, position after the closing brace.
local function readBlock(src, pos)
  local depth, i, n = 0, pos, #src
  local start = pos + 1
  while i <= n do
    local c = src:sub(i, i)
    if c == '"' or c == "'" then
      local close = src:find(c, i + 1, true)
      i = close or n
    elseif c == '{' then
      depth = depth + 1
    elseif c == '}' then
      depth = depth - 1
      if depth == 0 then return src:sub(start, i - 1), i + 1 end
    end
    i = i + 1
  end
  return src:sub(start), n + 1
end

local function parseMediaCondition(text)
  local cond = { raw = text }
  for prop, value in text:gmatch('%(%s*([%w%-]+)%s*:%s*([^%)]+)%)') do
    local num = tonumber((value:gsub('px', '')))
    if num then cond[prop:lower()] = num end
  end
  if text:lower():find('screen') or text:lower():find('all') then cond.screen = true end
  return cond
end

local function parseRules(src, out, media, orderRef)
  local pos, n = 1, #src
  while pos <= n do
    local brace = src:find('[{;]', pos)
    if not brace then break end
    local ch = src:sub(brace, brace)
    local prelude = util.trim(src:sub(pos, brace - 1))
    if ch == ';' then
      pos = brace + 1 -- at-rule without a block (@import/@charset): ignored
    else
      local body, after = readBlock(src, brace)
      pos = after
      if prelude:sub(1, 1) == '@' then
        local name = prelude:match('^@([%w%-]+)')
        if name == 'media' then
          local cond = parseMediaCondition(prelude:sub(#name + 2))
          parseRules(body, out, cond, orderRef)
        elseif name == 'supports' then
          parseRules(body, out, media, orderRef)
        elseif name == 'keyframes' or name == 'font-face' then
          -- not supported; ignored on purpose
        end
      elseif prelude ~= '' then
        local decls, important = css.parseDeclarations(body)
        local hasAny = false
        for _ in pairs(decls) do hasAny = true; break end
        if hasAny then
          for _, sel in ipairs(css.parseSelectorList(prelude)) do
            orderRef.n = orderRef.n + 1
            local kind, key = css.rightKey(sel)
            out[#out + 1] = {
              selector = sel,
              decls = decls,
              important = important,
              order = orderRef.n,
              media = media,
              keyKind = kind,
              keyValue = key,
              dynamic = css.dynamicPseudos(sel),
            }
          end
        end
      end
    end
  end
end

--- Parse a full stylesheet into a flat list of rules.
function css.parse(source)
  local rules = {}
  parseRules(skipComments(tostring(source or '')), rules, nil, { n = 0 })
  return rules
end

return css
