--!nonstrict
-- Tenpo ko: a bar clock for "elemental time", which splits the UTC day into
-- four fixed six-hour blocks (invented by marzka and Joop Kiefte, clock at
-- https://tilde.town/~dozens/tenpoko/):
--   fire  / tenpo seli  00-06 UTC
--   air   / tenpo kon   06-12 UTC
--   water / tenpo telo  12-18 UTC
--   earth / tenpo ma    18-24 UTC
--
-- Block index is floor(UTChour / 6); the time shown after the name counts
-- from the start of the block, i.e. (UTChour % 6):MM[:SS], matching dozens'
-- clock exactly. os.date("!*t") is UTC regardless of the machine's timezone.

local NAME_STYLE = noctalia.getConfig("name_style") or "english"
local DROP_TENPO_PREFIX = noctalia.getConfig("drop_tenpo_prefix") == true
local SHOW_EMOJI = noctalia.getConfig("show_emoji") ~= false
local SHOW_SECONDS = noctalia.getConfig("show_seconds") == true

local BLOCKS = {
  { emoji = "🔥", english = "fire", toki_pona = "tenpo seli", color = "error" },
  { emoji = "☁️", english = "air", toki_pona = "tenpo kon", color = "on_surface_variant" },
  { emoji = "💧", english = "water", toki_pona = "tenpo telo", color = "primary" },
  { emoji = "🌱", english = "earth", toki_pona = "tenpo ma", color = "secondary" },
}

local WIDGET_PAD_H = 6

local function emit(node)
  local props = { key = "pad", align = "center" }
  if barWidget.isVertical() then
    props.paddingV = WIDGET_PAD_H
    barWidget.render(ui.column(props, { node }))
  else
    props.paddingH = WIDGET_PAD_H
    barWidget.render(ui.row(props, { node }))
  end
end

local function render()
  local t = os.date("!*t")
  local block = BLOCKS[math.floor(t.hour / 6) + 1]

  local time = SHOW_SECONDS
      and string.format("%d:%02d:%02d", t.hour % 6, t.min, t.sec)
    or string.format("%d:%02d", t.hour % 6, t.min)

  local parts = {}
  if SHOW_EMOJI then
    parts[#parts + 1] = block.emoji
  end
  if NAME_STYLE ~= "none" then
    local name = block[NAME_STYLE] or block.english
    if NAME_STYLE == "toki_pona" and DROP_TENPO_PREFIX then
      name = name:gsub("^tenpo ", "")
    end
    parts[#parts + 1] = name
  end
  parts[#parts + 1] = time

  emit(ui.label({
    key = "tenpoko",
    text = table.concat(parts, " "),
    maxLines = 1,
    color = block.color,
  }))
end

function update()
  noctalia.setUpdateInterval(SHOW_SECONDS and 1000 or 10000)
  render()
end

render()
