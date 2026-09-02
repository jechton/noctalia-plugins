--!nonstrict
-- Desktop widget: renders a Home Assistant Jinja template as a grid of its
-- non-blank output lines, larger than the bar widget. `columns` sets how many
-- items per row: 1 is a vertical list, N-equal-to-item-count is a single row,
-- anything between is a grid.
--
-- A Jinja loop that emits one line per item (with `{% %}` blocks leaving blank
-- lines between) lands as one grid cell per item for free; see example.jinja.

local common = require("./common.luau")

local JUSTIFY = { left = "start", center = "center", right = "end" }

local template = nil
local lines = {}
local status = "loading" -- "loading" | "ok" | "error" | "no_template"
local message = ""
local inFlight = false
local tick = 0

local function num(key, default)
  return tonumber(noctalia.getConfig(key)) or default
end

local function fontSize()
  return math.max(8, num("font_size", 22))
end

local function columns()
  return math.max(1, math.floor(num("columns", 1)))
end

-- Wrap a cell label so the grid stays on a fixed pitch: with cell_width set,
-- every column lines up regardless of content length (and with a matching
-- window gap, the numbers read as one grid peeking between windows). 0 keeps
-- the label at its natural size.
local function cell(key, line)
  local label = ui.label({
    key = key,
    text = line,
    fontSize = fontSize(),
    color = "on_surface",
    maxLines = 1,
  })
  local width = math.max(0, math.floor(num("cell_width", 0)))
  local height = math.max(0, math.floor(num("cell_height", 0)))
  if width == 0 and height == 0 then
    return label
  end
  local props = {
    key = key .. "-box",
    align = "center",
    justify = JUSTIFY[noctalia.getConfig("cell_align")] or "center",
  }
  if width > 0 then
    props.width = width
  end
  if height > 0 then
    props.height = height
  end
  return ui.row(props, { label })
end

local function render()
  local children = {}
  local rowGap = math.max(0, math.floor(num("row_gap", 6)))
  local colGap = math.max(0, math.floor(num("column_gap", 16)))

  local title = noctalia.string.trim(noctalia.getConfig("title") or "")
  if title ~= "" then
    children[#children + 1] = ui.label({
      key = "title",
      text = title,
      fontSize = math.floor(fontSize() * 0.7),
      fontWeight = "bold",
      color = "on_surface_variant",
    })
  end

  if status == "ok" and #lines > 0 then
    local cols = columns()
    local rowItems = {}
    local function flushRow()
      children[#children + 1] = ui.row({
        key = "grid" .. tostring(#children),
        gap = colGap,
        align = "center",
      }, rowItems)
      rowItems = {}
    end
    for i, line in ipairs(lines) do
      rowItems[#rowItems + 1] = cell("cell" .. tostring(i), line)
      if #rowItems == cols then
        flushRow()
      end
    end
    if #rowItems > 0 then
      flushRow()
    end
  else
    local text = message
    if status == "loading" then
      text = noctalia.tr("state.loading")
    elseif status == "no_template" then
      text = noctalia.tr("widget.no_template_tip")
    elseif status == "ok" then
      text = noctalia.tr("widget.empty")
    end
    children[#children + 1] = ui.label({
      key = "status",
      text = text,
      fontSize = math.floor(fontSize() * 0.7),
      color = status == "error" and "error" or "on_surface_variant",
      maxLines = 3,
    })
  end

  desktopWidget.render(ui.column({ gap = rowGap, align = "start" }, children))
end

local function refresh()
  if inFlight or template == nil then
    return
  end
  inFlight = true
  common.fetch(template, function(ok, raw, err)
    inFlight = false
    if not ok then
      status, message = "error", err or noctalia.tr("errors.network")
      render()
      return
    end
    lines = common.lines(raw)
    status = "ok"
    render()
  end)
end

function update()
  noctalia.setUpdateInterval(1000)
  tick = tick + 1
  if tick % common.pollTicks() == 0 then
    refresh()
  end
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

template = common.loadTemplate()
if template == nil then
  status = "no_template"
end
render()
refresh()
