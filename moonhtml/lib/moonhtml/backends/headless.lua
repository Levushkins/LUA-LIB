-- moonhtml/backends/headless.lua -- text metrics without a GPU.
--
-- Used by the test suite (and by anyone who wants to unit-test a menu layout
-- outside the game). Feed it a metrics table of advance widths per codepoint
-- normalised to font size 1.

local util = require 'moonhtml.util'

local headless = {}

-- Rough DejaVu-ish fallback so the backend is usable with no metrics table.
local DEFAULT_ADVANCE = 0.55
local NARROW = {
  [32] = 0.318, [105] = 0.278, [108] = 0.278, [106] = 0.278, [116] = 0.392,
  [102] = 0.348, [114] = 0.411, [46] = 0.318, [44] = 0.318, [58] = 0.337,
  [59] = 0.337, [33] = 0.401, [39] = 0.275, [40] = 0.390, [41] = 0.390,
}
local WIDE = {
  [109] = 0.974, [119] = 0.727, [77] = 0.863, [87] = 0.989, [64] = 1.0,
}

function headless.new(opts)
  opts = opts or {}
  local metrics = opts.metrics
  local scale = opts.scale or 1

  local function advance(cp, weight)
    if metrics then
      local table_ = metrics.regular
      if weight == 'bold' or (tonumber(weight) or 0) >= 600 then
        table_ = metrics.bold or table_
      end
      local w = table_ and table_[cp]
      if w then return w end
      if metrics.regular and metrics.regular[cp] then return metrics.regular[cp] end
    end
    return NARROW[cp] or WIDE[cp] or DEFAULT_ADVANCE
  end

  local self = {}

  function self.measure(text, st)
    if text == nil or text == '' then return 0 end
    local size = st and st.fontSize or 14
    local weight = st and st.fontWeight or 'normal'
    local mono = st and st.fontFamily == 'mono'
    local total = 0
    for cp in util.codepoints(text) do
      if mono and metrics and metrics.mono then
        total = total + (metrics.mono[cp] or 0.602)
      else
        total = total + advance(cp, weight)
      end
    end
    return total * size * scale
  end

  return self
end

return headless
