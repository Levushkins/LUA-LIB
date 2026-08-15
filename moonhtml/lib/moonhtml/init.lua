-- moonhtml -- write MoonLoader menus in HTML + CSS instead of ImGui calls.
--
--   local moonhtml = require 'moonhtml'
--
--   local menu = moonhtml.new{
--     key = 0x58, -- X
--     html = [[
--       <style> .card { background: #1f2023; border-radius: 8px; padding: 12px } </style>
--       <div class="card">
--         <h3>Меню</h3>
--         <button id="go">Поехали</button>
--       </div>
--     ]],
--   }
--   menu:on('#go', 'click', function() sampAddChatMessage('go!', -1) end)
--
-- The mimgui dependency is loaded lazily: everything except `new()` and
-- `backend()` works in a plain Lua interpreter, which is how the tests run.

local moonhtml = {}

moonhtml._VERSION = '1.0.0'
moonhtml._DESCRIPTION = 'HTML/CSS UI engine for MoonLoader, rendered through mimgui'

moonhtml.util = require 'moonhtml.util'
moonhtml.color = require 'moonhtml.color'
moonhtml.html = require 'moonhtml.html'
moonhtml.css = require 'moonhtml.css'
moonhtml.dom = require 'moonhtml.dom'
moonhtml.style = require 'moonhtml.style'
moonhtml.layout = require 'moonhtml.layout'
moonhtml.paint = require 'moonhtml.paint'
moonhtml.events = require 'moonhtml.events'
moonhtml.widgets = require 'moonhtml.widgets'
moonhtml.document = require 'moonhtml.document'

--- Create a document with no renderer attached (unit tests, tooling).
-- Pass `measure` yourself, or let it fall back to rough metrics.
function moonhtml.newDocument(opts)
  return moonhtml.document.new(opts)
end

--- Create a document backed by the headless text-metrics backend.
function moonhtml.headless(opts)
  opts = opts or {}
  local headless = require 'moonhtml.backends.headless'
  local backend = headless.new { metrics = opts.metrics, scale = opts.scale }
  local docOpts = {}
  for k, v in pairs(opts) do docOpts[k] = v end
  docOpts.measure = backend.measure
  local doc = moonhtml.document.new(docOpts)
  doc.backend = backend
  return doc
end

--- Create a menu window rendered through mimgui. Requires MoonLoader.
function moonhtml.new(opts)
  return require('moonhtml.window').new(opts)
end

--- Low-level access to the mimgui backend (custom render loops).
function moonhtml.backend(opts)
  return require('moonhtml.backends.mimgui').new(opts)
end

--- Parse markup into a detached node tree.
function moonhtml.parse(markup)
  return moonhtml.html.parse(markup)
end

return moonhtml
