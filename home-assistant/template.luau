--!nonstrict
-- Bar widget: renders a Home Assistant Jinja template as a single label.
--
-- The template lives at template_file (never bundled, it often holds personal
-- data). Every poll it is POSTed to HA's /api/template endpoint, which renders
-- it server-side (custom_templates imports, macros, states(), all of it), and
-- the returned text is flattened to one line and shown. See example.jinja.

local common = require("./common.luau")
local ha = require("./ha.luau")

local FONT = noctalia.string.trim(noctalia.getConfig("font_family") or "")
local DASHBOARD_PATH = noctalia.string.trim(noctalia.getConfig("dashboard_path") or "")

local template = nil
local lastText = ""
local inFlight = false
local tick = 0

local function emit(node)
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ key = "root", align = "center" }, { node }))
end

local function render(text, isError)
  emit(ui.label({
    key = "text",
    text = text,
    maxLines = 1,
    color = isError and "error" or "on_surface",
  }))
end

local function refresh()
  if inFlight or template == nil then
    return
  end
  inFlight = true
  common.fetch(template, function(ok, raw, err)
    inFlight = false
    if not ok then
      if lastText == "" then
        render(noctalia.tr("widget.error"), true)
      end
      barWidget.setTooltip(err or noctalia.tr("errors.network"))
      return
    end
    local text = common.oneLine(raw)
    lastText = text
    render(text ~= "" and text or noctalia.tr("widget.empty"), false)
    barWidget.setTooltip({
      { key = noctalia.tr("tooltip.updated"), value = noctalia.formatTime("%H:%M:%S") },
    })
  end)
end

function update()
  noctalia.setUpdateInterval(1000)
  tick = tick + 1
  if tick % common.pollTicks() == 0 then
    refresh()
  end
end

function onClick()
  local cfg = ha.config()
  if cfg.base ~= "" then
    noctalia.runAsync({ "xdg-open", cfg.base .. DASHBOARD_PATH })
  end
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

if FONT ~= "" then
  barWidget.setFont(FONT)
end

template = common.loadTemplate()
if template == nil then
  render(noctalia.tr("widget.no_template"), true)
  barWidget.setTooltip(noctalia.tr("widget.no_template_tip"))
else
  refresh()
end
