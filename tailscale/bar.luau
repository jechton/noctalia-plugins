--!nonstrict
-- Tailscale bar widget: a globe glyph that is bright while connected and dim
-- otherwise, with the tailnet in the tooltip. Left-click opens the panel
-- (plugin.toml [widget.actions]).

local ts = require("./tailscale.luau")

local POLL_TICKS = math.max(2, tonumber(noctalia.getConfig("poll_seconds")) or 5)

local status = nil -- last parsed status, nil until the first poll succeeds
local polling = false
local tick = 0

local function render()
  local running = status ~= nil and status.state == "Running"
  barWidget.setTooltip(
    status == nil and noctalia.tr("tooltip.unavailable")
      or (noctalia.tr("tooltip.tailnet") .. ": " .. (status.tailnet or "-"))
  )
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ key = "root", align = "center" }, {
    ui.glyph({
      key = "glyph",
      name = running and "world" or "world-off",
      size = 16,
      color = running and "primary" or "on_surface_variant",
    }),
  }))
end

local function refresh()
  if polling then
    return
  end
  polling = true
  ts.status(function(ok, parsed)
    polling = false
    status = ok and parsed or nil
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(1000)
  tick = tick + 1
  if tick % POLL_TICKS == 1 then
    refresh()
  end
end

-- The panel fires this after connecting, disconnecting, or switching.
function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

render()
