--!nonstrict
-- Kimai bar widget: a clock glyph plus the running entry's elapsed time (and
-- optionally its project), or a dim clock when nothing is running. Left-click
-- opens the panel (plugin.toml [widget.actions]).
--
-- The elapsed label advances locally every second; the running entry itself is
-- re-fetched every poll_seconds, and the project/activity name maps every ten
-- minutes.

local kimai = require("./kimai.luau")

local SHOW_PROJECT = noctalia.getConfig("show_project") ~= false
local HIDE_WHEN_IDLE = noctalia.getConfig("hide_when_idle") == true
local POLL_TICKS = math.max(5, tonumber(noctalia.getConfig("poll_seconds")) or 15)

local META_INTERVAL_MS = 600000

local running = nil
local projects = {}
local activities = {}
local activeInFlight = false
local metaAtMs = 0
local tick = 0

-- Noctalia adds the standard widget-capsule inset around a rendered tree, so
-- this only picks the stacking direction, matching the builtin widgets it sits
-- next to (no extra manual padding).
local function emit(node)
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ key = "root", align = "center" }, { node }))
end

local function nameOf(byId, id)
  local entity = byId[tostring(id)]
  return entity and entity.name or nil
end

local function idleGlyph(tooltipKey)
  if HIDE_WHEN_IDLE then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  barWidget.setTooltip(noctalia.tr(tooltipKey))
  emit(ui.glyph({ key = "idle", name = "clock", size = 16, color = "on_surface_variant" }))
end

local function render()
  if not kimai.ready() then
    idleGlyph("tooltip.not_configured")
    return
  end
  if running == nil then
    idleGlyph("tooltip.idle")
    return
  end

  barWidget.setVisible(true)
  local elapsed = kimai.hhmm(kimai.elapsedSeconds(running))
  local project = nameOf(projects, running.project)
  local activity = nameOf(activities, running.activity)

  local text = elapsed
  if SHOW_PROJECT and project ~= nil then
    text = project .. "  " .. elapsed
  end

  emit(ui.row({ key = "content", gap = 6, align = "center" }, {
    ui.glyph({ key = "glyph", name = "clock", size = 14, color = "primary" }),
    ui.label({ key = "text", text = text, maxLines = 1, color = "on_surface" }),
  }))

  local rows = {}
  if project ~= nil then
    rows[#rows + 1] = { key = noctalia.tr("tooltip.project"), value = project }
  end
  if activity ~= nil then
    rows[#rows + 1] = { key = noctalia.tr("tooltip.activity"), value = activity }
  end
  if type(running.description) == "string" and running.description ~= "" then
    rows[#rows + 1] = { key = noctalia.tr("tooltip.description"), value = running.description }
  end
  rows[#rows + 1] = { key = noctalia.tr("tooltip.elapsed"), value = elapsed }
  barWidget.setTooltip(rows)
end

local function refreshMeta()
  metaAtMs = noctalia.nowMs()
  kimai.projects(function(ok, data)
    if ok then
      projects = kimai.indexById(data)
      render()
    end
  end)
  kimai.activities(function(ok, data)
    if ok then
      activities = kimai.indexById(data)
      render()
    end
  end)
end

local function refreshActive()
  if activeInFlight then
    return
  end
  activeInFlight = true
  kimai.active(function(ok, data)
    activeInFlight = false
    if not ok then
      return
    end
    running = (type(data) == "table") and data[1] or nil
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(1000)
  tick = tick + 1

  if running ~= nil then
    render() -- keep the elapsed label ticking between polls
  end
  if tick % POLL_TICKS == 0 then
    refreshActive()
  end
  if noctalia.nowMs() - metaAtMs > META_INTERVAL_MS then
    refreshMeta()
  end
end

-- The panel fires this after it starts, stops, or edits an entry so the bar
-- reflects the change without waiting for the next poll.
function onIpc(event)
  if event == "refresh" then
    refreshActive()
  end
end

refreshMeta()
refreshActive()
