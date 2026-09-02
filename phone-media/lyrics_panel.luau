--!nonstrict
-- Phone Media lyrics panel: a standalone, full-size synced-lyrics view and a
-- thin consumer of the service (see service.luau). It watches pm.now / pm.lyrics
-- for the player and lyrics the service already tracks, pings pm.want so lyrics
-- stay fetched while it's open, and sends pm.cmd { seek } when a line is clicked.
--
-- Synced lyrics render as a fixed window centred on the current line, so the
-- view follows playback on its own, and clicking a line seeks playback to it;
-- unsynced lyrics show every line in a hand-scrolled list.

local lyrics = require("./lyrics.luau")

-- ── settings ─────────────────────────────────────────────────────────────────

local SHOW_TRACK_INFO = noctalia.getConfig("show_track_info") ~= false
local TEXT_ALIGN = noctalia.getConfig("text_align") or "center"
local LYRICS_OFFSET_MS = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0
local VISIBLE_LINES = math.max(3, math.floor(tonumber(noctalia.getConfig("visible_lines")) or 9))

local CURRENT_LINE_FONT_SIZE = 18
local OTHER_LINE_FONT_SIZE = 15

-- ── state (snapshots from the service) ───────────────────────────────────────

local function emptyNow()
  return { hasPlayer = false, status = "", positionUs = 0, positionAtMs = 0, title = "", artist = "" }
end

local isOpen = false
local frameAccumMs = 0
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

-- Click a synced line to jump playback to it. The line is highlighted once
-- position >= timeMs - offset (see activeLineIndex callers), so seek there.
local function seekToLineMs(timeMs)
  if not snap.hasPlayer or timeMs < 0 then
    return
  end
  noctalia.state.set("pm.cmd", {
    action = "seek",
    sec = math.max(0, (timeMs - LYRICS_OFFSET_MS) / 1000),
    nonce = noctalia.nowMs(),
  })
end

-- ── rendering ────────────────────────────────────────────────────────────────

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({
      text = noctalia.tr("ui.lyrics"),
      fontSize = 16,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefetch" }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  })
end

local function emptyState(glyph, text)
  return ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = glyph, size = 32, color = "on_surface_variant" }),
    ui.label({ text = text, color = "on_surface_variant", textAlign = "center" }),
  })
end

function render()
  if not isOpen then
    return
  end

  if not snap.hasPlayer then
    panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, {
      header(),
      emptyState("music-off", noctalia.tr("ui.nothing_playing")),
    }))
    return
  end

  local body = {}

  if SHOW_TRACK_INFO then
    local label = snap.artist ~= "" and (snap.title .. " - " .. snap.artist) or snap.title
    body[#body + 1] = ui.label({ text = label, fontSize = 12, color = "on_surface_variant", textAlign = "center" })
  end

  if lyr.status == "loading" or lyr.status == "idle" then
    body[#body + 1] = emptyState("clock", noctalia.tr("ui.lyrics_loading"))
  elseif lyr.lines == nil then
    local key = lyr.status == "unreachable" and "ui.lyrics_unreachable" or "ui.lyrics_not_found"
    body[#body + 1] = emptyState("music-off", noctalia.tr(key))
  elseif lyr.source == "synced" then
    -- Karaoke window: VISIBLE_LINES lines centred on the current one, kept full
    -- near the start and end of the song so the view height doesn't jump.
    local activeIndex = lyrics.activeLineIndex(lyr.lines, livePositionMs() + LYRICS_OFFSET_MS) or 0
    local total = #lyr.lines
    local first = math.max(1, activeIndex - math.floor(VISIBLE_LINES / 2))
    first = math.min(first, math.max(1, total - VISIBLE_LINES + 1))
    local last = math.min(total, first + VISIBLE_LINES - 1)

    local rendered = {}
    for i = first, last do
      local isCurrent = i == activeIndex
      local timeMs = lyr.lines[i].timeMs
      -- ui.row as the click target (matching the community media-lyrics
      -- plugin, tranzem/media-lyrics): ui.box is a childless fill node and
      -- would hide the label. onClick only when the line has a real timestamp.
      rendered[#rendered + 1] = ui.row({
        align = "stretch",
        onClick = timeMs >= 0 and function()
          seekToLineMs(timeMs)
        end or nil,
      }, {
        ui.label({
          text = lyr.lines[i].text,
          flexGrow = 1,
          fontSize = isCurrent and CURRENT_LINE_FONT_SIZE or OTHER_LINE_FONT_SIZE,
          fontWeight = isCurrent and "bold" or "normal",
          color = isCurrent and "primary" or "on_surface_variant",
          textAlign = TEXT_ALIGN,
        }),
      })
    end
    body[#body + 1] = ui.column({ flexGrow = 1, justify = "center", gap = 8, align = "stretch" }, rendered)
  else
    -- Unsynced: no current line, so show every line in a hand-scrolled list.
    local rendered = {}
    for _, line in ipairs(lyr.lines) do
      rendered[#rendered + 1] = ui.label({
        text = line.text,
        fontSize = OTHER_LINE_FONT_SIZE,
        color = "on_surface_variant",
        textAlign = TEXT_ALIGN,
      })
    end
    body[#body + 1] = ui.scroll({ key = "lyrics", flexGrow = 1, gap = 8, align = "stretch" }, rendered)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    header(),
    ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, body),
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

function onOpen(_context)
  isOpen = true
  snap = noctalia.state.get("pm.now") or emptyNow()
  lyr = noctalia.state.get("pm.lyrics") or { status = "idle", source = nil, lines = nil }
  panel.setWantsSecondTicks(true)
  -- Frame ticks redraw the highlight between the service's position publishes;
  -- render() is throttled in onFrameTick.
  panel.setNeedsFrameTick(true)
  noctalia.state.set("pm.want", noctalia.nowMs())
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
end

function update()
  noctalia.state.set("pm.want", noctalia.nowMs())
end

function onFrameTick(deltaMs)
  frameAccumMs = frameAccumMs + (tonumber(deltaMs) or 16)
  if frameAccumMs >= 100 then
    frameAccumMs = 0
    render()
  end
end

function onCloseClicked()
  panel.close()
end

function onRefetch()
  noctalia.state.set("pm.cmd", { action = "refetchLyrics", nonce = noctalia.nowMs() })
end
