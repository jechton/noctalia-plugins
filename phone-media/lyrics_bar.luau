--!nonstrict
-- Phone Media lyrics bar widget: a small "open the lyrics panel" icon, optionally
-- previewing the current synced line. A thin consumer of the service (see
-- service.luau): it watches pm.now / pm.lyrics and, while it wants a line to
-- show, pings pm.want so the service keeps lyrics fetched. Independent of the
-- "bar" widget - add both, either, or neither.

local lyrics = require("./lyrics.luau")

-- ── settings ─────────────────────────────────────────────────────────────────

local SHOW_CURRENT_LINE = noctalia.getConfig("show_current_line") ~= false
local MAX_LENGTH = tonumber(noctalia.getConfig("max_length")) or 220
local HIDE_WHEN_NO_LYRICS = noctalia.getConfig("hide_when_no_lyrics") ~= false
local LYRICS_OFFSET_MS = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0

-- ── state (snapshots from the service) ───────────────────────────────────────

local function emptyNow()
  return { hasPlayer = false, status = "", positionUs = 0, positionAtMs = 0 }
end

local snap = emptyNow()
local lyr = { status = "idle", source = nil, lines = nil }

-- ── helpers ──────────────────────────────────────────────────────────────────

local function livePositionMs()
  local base = snap.positionUs or 0
  if snap.status == "Playing" and (snap.positionAtMs or 0) > 0 then
    base = base + math.max(0, noctalia.nowMs() - snap.positionAtMs) * 1000 * (snap.rate or 1)
  end
  return math.floor(base / 1000)
end

local function glyph()
  return ui.glyph({ key = "glyph", name = "microphone-2", size = 16, color = "on_surface_variant" })
end

-- Builtin bar widgets carry a small inset; plugin widgets render flush unless
-- they add their own. Wrap every emit so this widget keeps a gap from its
-- neighbours without widening the bar-wide widget_spacing.
local WIDGET_PAD = 6

local function emit(node)
  local props = { key = "pad", align = "center" }
  if barWidget.isVertical() then
    props.paddingV = WIDGET_PAD
    barWidget.render(ui.column(props, { node }))
  else
    props.paddingH = WIDGET_PAD
    barWidget.render(ui.row(props, { node }))
  end
end

local function hideOrIdle()
  barWidget.setVisible(not HIDE_WHEN_NO_LYRICS)
  if not HIDE_WHEN_NO_LYRICS then
    emit(ui.glyph({ key = "idle", name = "music-off", size = 16, color = "on_surface_variant" }))
  end
end

-- ── rendering ────────────────────────────────────────────────────────────────

function render()
  if not SHOW_CURRENT_LINE then
    barWidget.setVisible(true)
    emit(glyph())
    return
  end

  local loading = lyr.status == "loading" or lyr.status == "idle"

  -- Nothing playing, or the track genuinely has no lyrics on file: hide.
  if not snap.hasPlayer or (not loading and lyr.lines == nil) then
    hideOrIdle()
    return
  end

  -- Still looking, or lyrics exist but aren't synced: icon only, still opens
  -- the full lyrics panel.
  if loading or lyr.source ~= "synced" then
    barWidget.setVisible(true)
    emit(glyph())
    return
  end

  local activeIndex = lyrics.activeLineIndex(lyr.lines, livePositionMs() + LYRICS_OFFSET_MS)
  local line = activeIndex ~= nil and lyr.lines[activeIndex] or nil

  barWidget.setVisible(true)
  emit(ui.row({ key = "content", gap = 6, align = "center" }, {
    glyph(),
    ui.label({
      key = "line",
      text = (line ~= nil and line.text ~= "") and line.text or noctalia.tr("ui.lyrics_waiting"),
      maxLines = 1,
      maxWidth = MAX_LENGTH,
      color = "on_surface",
    }),
  }))
end

-- ── wiring ───────────────────────────────────────────────────────────────────

noctalia.state.watch("pm.now", function(value)
  snap = value or emptyNow()
  render()
end)

noctalia.state.watch("pm.lyrics", function(value)
  lyr = value or { status = "idle", source = nil, lines = nil }
  render()
end)

function update()
  -- Redraw ~4x a second so the extrapolated line keeps up with fast lyrics.
  noctalia.setUpdateInterval(250)
  if SHOW_CURRENT_LINE then
    noctalia.state.set("pm.want", noctalia.nowMs())
  end
  render()
end

function onClick()
  noctalia.togglePanel("jechton/phone-media:lyrics")
end

snap = noctalia.state.get("pm.now") or emptyNow()
lyr = noctalia.state.get("pm.lyrics") or { status = "idle", source = nil, lines = nil }
render()
