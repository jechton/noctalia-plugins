--!nonstrict
-- Phone Media: a now-playing bar widget that replaces noctalia's builtin
-- `media` widget. It mirrors that widget's look and settings, and additionally
-- routes wheel/touchpad scroll to a volume control (the phone's volume when the
-- active player is KDE Connect, otherwise the laptop's own volume).
--
-- A thin consumer of the service (see service.luau): it watches pm.now and
-- renders the snapshot, interpolating the progress bar between the service's
-- position publishes. Scroll and right-click send pm.cmd. Left opens this
-- plugin's panel; back/forward run playerctl directly (see plugin.toml
-- [widget.actions]).

-- ── settings ─────────────────────────────────────────────────────────────────

local HIDE_ARTIST = noctalia.getConfig("hide_artist") == true
local ARTIST_FIRST = noctalia.getConfig("artist_first") == true
local ALBUM_ART_ONLY = noctalia.getConfig("album_art_only") == true
local HIDE_ALBUM_ART = noctalia.getConfig("hide_album_art") == true
local SHOW_PROGRESS = noctalia.getConfig("show_progress") == true
local PROGRESS_ABOVE = noctalia.getConfig("progress_above") == true
local HIDE_WHEN_NO_MEDIA = noctalia.getConfig("hide_when_no_media") ~= false
local TITLE_SCROLL = noctalia.getConfig("title_scroll") or "on_hover"
local MAX_LENGTH = tonumber(noctalia.getConfig("max_length")) or 300
local ART_SIZE = tonumber(noctalia.getConfig("art_size")) or 16
-- Clamped to a circle; the default is intentionally huge so the art is round
-- unless the user dials it down.
local ART_RADIUS = math.min(tonumber(noctalia.getConfig("art_radius")) or 999, ART_SIZE / 2)

local PROGRESS_HEIGHT = 2
local ART_SLOT = (ALBUM_ART_ONLY or HIDE_ALBUM_ART) and 0 or (ART_SIZE + 6)
local TITLE_WIDTH = math.max(40, MAX_LENGTH - ART_SLOT)
local TITLE_CHARS = math.max(6, math.floor(TITLE_WIDTH / 7))

local MARQUEE_TICKS = 2

local dataDir = noctalia.pluginDataDir()
-- Per-VM token so two of this widget (one bar per monitor) writing into the
-- shared plugin data dir don't clobber each other's cover cache files.
local COVER_TAG = (tostring({}):match("0x0*(%x+)") or "0") .. ""

-- ── state (snapshot from the service) ────────────────────────────────────────

local function emptyNow()
  return {
    hasPlayer = false,
    name = "",
    status = "",
    title = "",
    artist = "",
    artUrl = "",
    lengthUs = 0,
    positionUs = 0,
    positionAtMs = 0,
  }
end

local snap = emptyNow()
local hovered = false

local marqueeOffset = 1
local tick = 0
local lastText = ""

local artUrl = ""
local artPath = nil
local coverRevision = 0

-- ── helpers ──────────────────────────────────────────────────────────────────

local function displayText()
  if not snap.hasPlayer then
    return ""
  end
  if HIDE_ARTIST or snap.artist == "" then
    return snap.title
  end
  if ARTIST_FIRST then
    return snap.artist .. " - " .. snap.title
  end
  return snap.title .. " - " .. snap.artist
end

local function utf8Chars(value)
  local chars = {}
  for _, cp in utf8.codes(value) do
    table.insert(chars, utf8.char(cp))
  end
  return chars
end

-- Rotates `value` through the visible window one character at a time.
--   none      -> head, truncated with an ellipsis
--   always    -> always scrolling
--   on_hover  -> scrolls only while the pointer is over the widget
local function marquee(value)
  local chars = utf8Chars(value)
  if #chars <= TITLE_CHARS then
    return value
  end
  local scrolling = TITLE_SCROLL == "always" or (TITLE_SCROLL == "on_hover" and hovered)
  if not scrolling then
    return table.concat(chars, "", 1, TITLE_CHARS - 1) .. "\u{2026}"
  end
  local padded = utf8Chars(value .. "   ")
  local n = #padded
  local out = {}
  for i = 0, TITLE_CHARS - 1 do
    out[#out + 1] = padded[((marqueeOffset + i - 1) % n) + 1]
  end
  return table.concat(out)
end

local function progressFraction()
  local length = snap.lengthUs or 0
  if length <= 0 then
    return 0
  end
  local pos = snap.positionUs or 0
  if snap.status == "Playing" and (snap.positionAtMs or 0) > 0 then
    pos = pos + math.max(0, noctalia.nowMs() - snap.positionAtMs) * 1000
  end
  return math.max(0, math.min(1, pos / length))
end

-- ── artwork ──────────────────────────────────────────────────────────────────

local function updateArtwork(url)
  if url == nil or url == "" then
    artUrl, artPath = "", nil
    return
  end
  if url == artUrl then
    return
  end
  artUrl = url

  if string.sub(url, 1, 7) == "file://" then
    artPath = noctalia.string.urlDecode(string.sub(url, 8))
    return
  end
  if not string.match(url, "^https?://") or dataDir == nil then
    artPath = nil
    return
  end

  coverRevision = coverRevision + 1
  local revision = coverRevision
  local destination = dataDir .. "/cover-" .. COVER_TAG .. "-" .. tostring(revision % 2) .. ".jpg"
  noctalia.download(url, destination, function(ok)
    if ok and revision == coverRevision then
      artPath = destination
      render()
    end
  end)
end

-- ── rendering ────────────────────────────────────────────────────────────────

-- Builtin bar widgets carry a small horizontal inset; plugin widgets render
-- flush unless they add their own.
local WIDGET_PAD_H = 6

local function emit(node, stretch)
  local props = { key = "pad", align = stretch and "stretch" or "center" }
  if barWidget.isVertical() then
    props.paddingV = WIDGET_PAD_H
    barWidget.render(ui.column(props, { node }))
  else
    props.paddingH = WIDGET_PAD_H
    barWidget.render(ui.row(props, { node }))
  end
end

-- Nothing here registers an onClick, so left/back/forward fall through to
-- plugin.toml [widget.actions]; right-click and scroll are handled below.
function render()
  if not snap.hasPlayer then
    barWidget.setVisible(not HIDE_WHEN_NO_MEDIA)
    if not HIDE_WHEN_NO_MEDIA then
      emit(ui.glyph({ key = "idle", name = "disc-filled", size = 16, color = "on_surface_variant" }))
    end
    return
  end

  barWidget.setVisible(true)
  local playing = snap.status == "Playing"
  local vertical = barWidget.isVertical()

  local cover
  if not HIDE_ALBUM_ART then
    if artPath ~= nil and artPath ~= "" then
      cover = ui.image({
        key = "cover",
        path = artPath,
        width = ART_SIZE,
        height = ART_SIZE,
        radius = ART_RADIUS,
        fit = "cover",
      })
    else
      cover = ui.glyph({
        key = "cover-glyph",
        name = playing and "disc-filled" or "music-off",
        size = math.min(ART_SIZE, 18),
        color = "on_surface_variant",
      })
    end
  end

  if ALBUM_ART_ONLY or vertical then
    emit(cover or ui.glyph({ key = "cover-glyph", name = "disc-filled", size = 16, color = "on_surface_variant" }))
    return
  end

  local children = {}
  if cover ~= nil then
    children[#children + 1] = cover
  end
  children[#children + 1] = ui.label({
    key = "title",
    text = marquee(displayText()),
    maxLines = 1,
    maxWidth = TITLE_WIDTH,
    color = playing and "on_surface" or "on_surface_variant",
  })

  local row = ui.row({ key = "content", gap = 6, align = "center" }, children)

  if SHOW_PROGRESS and (snap.lengthUs or 0) > 0 then
    -- width = 0: bare nodes measure at their last laid-out size, so zeroing the
    -- progress/spacer width lets the title row alone set the column width;
    -- align = "stretch" still paints the bar across it.
    local progress = ui.progress({
      key = "progress",
      progress = progressFraction(),
      width = 0,
      height = PROGRESS_HEIGHT,
      radius = 1,
      fill = "primary",
    })
    local balance = ui.spacer({ key = "progress-balance", width = 0, height = PROGRESS_HEIGHT })
    local stack = PROGRESS_ABOVE and { progress, row, balance } or { balance, row, progress }
    emit(ui.column({ key = "root", gap = 0, align = "stretch" }, stack), true)
  else
    emit(row)
  end
end

-- ── wiring ───────────────────────────────────────────────────────────────────

noctalia.state.watch("pm.now", function(value)
  snap = value or emptyNow()
  updateArtwork(snap.artUrl)
  render()
end)

function update()
  noctalia.setUpdateInterval(250)
  tick = tick + 1

  local text = displayText()
  if text ~= lastText then
    lastText, marqueeOffset, tick = text, 1, 0
    render()
  elseif (TITLE_SCROLL == "always" or (TITLE_SCROLL == "on_hover" and hovered)) and tick % MARQUEE_TICKS == 0 then
    marqueeOffset = marqueeOffset + 1
    render()
  elseif SHOW_PROGRESS and snap.status == "Playing" then
    render() -- advance the interpolated progress bar
  end
end

function onHover(entered)
  hovered = entered == true
  if not hovered then
    marqueeOffset = 1
  end
  render()
end

-- BTN_RIGHT stays with this widget (plugin.toml binds only left/back/forward),
-- so play-pause targets the exact player the service is showing.
function onRightClick()
  noctalia.state.set("pm.cmd", { action = "toggle", nonce = noctalia.nowMs() })
end

function onScroll(axis, steps)
  if axis ~= "vertical" or steps == 0 then
    return
  end
  noctalia.state.set("pm.cmd", { action = "volume", dir = steps > 0 and "down" or "up", nonce = noctalia.nowMs() })
end

snap = noctalia.state.get("pm.now") or emptyNow()
updateArtwork(snap.artUrl)
render()
