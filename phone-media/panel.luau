--!nonstrict
-- Phone Media panel: replaces noctalia's builtin control-center media tab.
-- That tab pairs now-playing info with a PipeWire spectrum visualizer, which
-- only reflects locally-rendered audio, staying blank for a KDE Connect player
-- since the phone plays through its own speaker. The plugin API exposes no
-- spectrum data either, so this panel is a plain now-playing card: art, title,
-- progress, transport controls, an embedded synced-lyrics section, and a player
-- switcher when more than one MPRIS player is active.
--
-- A thin consumer of the service (see service.luau): it watches pm.now /
-- pm.lyrics and sends pm.cmd for transport, seeking and player pinning.
--
--   panel.render(tree)               replace the panel's UI tree
--   panel.close()                    ask the host to close this panel
--   panel.setWantsSecondTicks(bool)  call update() once a second while open

local lyrics = require("./lyrics.luau")

-- ── settings ─────────────────────────────────────────────────────────────────

local SHOW_ALBUM_ART = noctalia.getConfig("show_album_art") ~= false
local ALBUM_ART_SIZE = tonumber(noctalia.getConfig("album_art_size")) or 160
local ALBUM_ART_RADIUS = math.min(tonumber(noctalia.getConfig("album_art_radius")) or 16, ALBUM_ART_SIZE / 2)
local HIDE_ARTIST = noctalia.getConfig("hide_artist") == true
local SHOW_ALBUM = noctalia.getConfig("show_album") ~= false
local SHOW_PROGRESS = noctalia.getConfig("show_progress") ~= false
local SHOW_TIME_LABELS = noctalia.getConfig("show_time_labels") ~= false
local SHOW_PLAYBACK_CONTROLS = noctalia.getConfig("show_playback_controls") ~= false
local SHOW_PLAYER_SWITCHER = noctalia.getConfig("show_player_switcher") ~= false
local SHOW_SOURCE_LABEL = noctalia.getConfig("show_source_label") ~= false
local SHOW_LYRICS = noctalia.getConfig("show_lyrics") ~= false
local SHOW_FULL_LYRICS_BUTTON = noctalia.getConfig("show_full_lyrics_button") ~= false
local LYRICS_CONTEXT_LINES = math.max(0, math.floor(tonumber(noctalia.getConfig("lyrics_context_lines")) or 1))
local LYRICS_OFFSET_MS = tonumber(noctalia.getConfig("lyrics_offset_ms")) or 0

local dataDir = noctalia.pluginDataDir()

-- ── state ────────────────────────────────────────────────────────────────────

local function emptyNow()
  return {
    hasPlayer = false,
    name = "",
    isKde = false,
    status = "",
    title = "",
    artist = "",
    album = "",
    artUrl = "",
    lengthUs = 0,
    positionUs = 0,
    positionAtMs = 0,
    players = {},
    pinned = nil,
  }
end

local isOpen = false
local snap = emptyNow()
local lyr = { status = "idle", source = nil, lines = nil }
local switcherRows = {} -- subset shown in the switcher, index-aligned with it

local artUrl = ""
local artPath = nil
local coverRevision = 0

local seeking = false
local seekIdleTicks = 0
local pendingSeekUs = nil
local seekCommittedAtMs = 0
local frameAccumMs = 0

-- ── helpers ──────────────────────────────────────────────────────────────────

local function formatTime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function livePositionUs()
  if seeking and pendingSeekUs ~= nil then
    return pendingSeekUs
  end
  local base = snap.positionUs or 0
  if snap.status == "Playing" and (snap.positionAtMs or 0) > 0 then
    base = base + math.max(0, noctalia.nowMs() - snap.positionAtMs) * 1000 * (snap.rate or 1)
  end
  return base
end

local function sendCmd(t)
  t.nonce = noctalia.nowMs()
  noctalia.state.set("pm.cmd", t)
end

-- ── artwork (downloads http art; file:// used directly) ───────────────────────

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
  local destination = dataDir .. "/panel-cover-" .. tostring(revision % 2) .. ".jpg"
  noctalia.download(url, destination, function(ok)
    if ok and revision == coverRevision then
      artPath = destination
      render()
    end
  end)
end

-- ── rendering ────────────────────────────────────────────────────────────────

local function header()
  return ui.row({ align = "center", justify = "space_between", gap = 8 }, {
    ui.label({
      text = noctalia.tr("ui.now_playing"),
      fontSize = 16,
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
  })
end

function render()
  if not isOpen then
    return
  end

  if not snap.hasPlayer then
    panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, {
      header(),
      ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8 }, {
        ui.glyph({ name = "music-off", size = 32, color = "on_surface_variant" }),
        ui.label({ text = noctalia.tr("ui.nothing_playing"), color = "on_surface_variant" }),
      }),
    }))
    return
  end

  local body = {}
  local playing = snap.status == "Playing"

  if SHOW_ALBUM_ART then
    local cover
    if artPath ~= nil and artPath ~= "" then
      cover = ui.image({
        path = artPath,
        width = ALBUM_ART_SIZE,
        height = ALBUM_ART_SIZE,
        radius = ALBUM_ART_RADIUS,
        fit = "cover",
      })
    else
      cover = ui.glyph({
        name = playing and "disc-filled" or "music-off",
        size = math.min(ALBUM_ART_SIZE, 48),
        color = "on_surface_variant",
      })
    end
    body[#body + 1] = ui.row({ justify = "center" }, { cover })
  end

  local textLines = {
    ui.label({
      text = snap.title,
      fontSize = 16,
      fontWeight = "bold",
      color = "on_surface",
      maxLines = 2,
      textAlign = "center",
    }),
  }
  local secondary = {}
  if not HIDE_ARTIST and snap.artist ~= "" then
    secondary[#secondary + 1] = snap.artist
  end
  if SHOW_ALBUM and snap.album ~= "" then
    secondary[#secondary + 1] = snap.album
  end
  if #secondary > 0 then
    textLines[#textLines + 1] = ui.label({
      text = table.concat(secondary, "  \u{2022}  "),
      fontSize = 12,
      color = "on_surface_variant",
      textAlign = "center",
    })
  end
  if SHOW_SOURCE_LABEL then
    textLines[#textLines + 1] = ui.label({
      text = snap.isKde and noctalia.tr("ui.via_phone") or (snap.name or ""),
      fontSize = 11,
      color = "secondary",
      textAlign = "center",
    })
  end
  local nowPlaying = { ui.column({ gap = 4, align = "stretch" }, textLines) }

  if SHOW_PROGRESS and (snap.lengthUs or 0) > 0 then
    local lengthSeconds = snap.lengthUs / 1000000
    local displaySeconds = math.min(livePositionUs() / 1000000, lengthSeconds)
    local progressLines = {
      ui.slider({
        min = 0,
        max = lengthSeconds,
        step = 1,
        value = displaySeconds,
        onChange = "onSeekChange",
        onDragEnd = "onSeekEnd",
      }),
    }
    if SHOW_TIME_LABELS then
      progressLines[#progressLines + 1] = ui.row({ justify = "space_between" }, {
        ui.label({ text = formatTime(displaySeconds), fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = formatTime(lengthSeconds), fontSize = 11, color = "on_surface_variant" }),
      })
    end
    nowPlaying[#nowPlaying + 1] = ui.column({ gap = 2, align = "stretch" }, progressLines)
  end

  if SHOW_PLAYBACK_CONTROLS then
    nowPlaying[#nowPlaying + 1] = ui.row({ justify = "center", gap = 8 }, {
      ui.button({ glyph = "media-prev", variant = "ghost", onClick = "onPrevious" }),
      ui.button({
        glyph = playing and "media-pause" or "media-play",
        variant = "primary",
        onClick = "onPlayPause",
      }),
      ui.button({ glyph = "media-next", variant = "ghost", onClick = "onNext" }),
    })
  end

  body[#body + 1] = ui.column({ gap = 4, align = "stretch" }, nowPlaying)

  if SHOW_LYRICS then
    local lyricsSection = {}
    if lyr.status == "loading" or lyr.status == "idle" then
      lyricsSection[1] = ui.label({
        text = noctalia.tr("ui.lyrics_loading"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      })
    elseif lyr.lines == nil then
      lyricsSection[1] = ui.label({
        text = noctalia.tr(lyr.status == "unreachable" and "ui.lyrics_unreachable" or "ui.lyrics_not_found"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      })
    elseif lyr.source ~= "synced" then
      lyricsSection[1] = ui.label({
        text = noctalia.tr("ui.lyrics_not_synced"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      })
    else
      local displayPositionMs = math.floor(livePositionUs() / 1000) + LYRICS_OFFSET_MS
      local activeIndex = lyrics.activeLineIndex(lyr.lines, displayPositionMs) or 0
      for i = activeIndex - LYRICS_CONTEXT_LINES, activeIndex + LYRICS_CONTEXT_LINES do
        local ln = lyr.lines[i]
        if ln ~= nil then
          local isCurrent = i == activeIndex
          lyricsSection[#lyricsSection + 1] = ui.label({
            text = ln.text,
            fontSize = isCurrent and 13 or 12,
            fontWeight = isCurrent and "bold" or "normal",
            color = isCurrent and "primary" or "on_surface_variant",
            textAlign = "center",
            maxLines = 2,
          })
        end
      end
    end
    if SHOW_FULL_LYRICS_BUTTON then
      lyricsSection[#lyricsSection + 1] = ui.row({ justify = "center" }, {
        ui.button({ text = noctalia.tr("ui.full_lyrics"), variant = "ghost", onClick = "onOpenLyricsPanel" }),
      })
    end
    body[#body + 1] = ui.column({ gap = 6, align = "stretch" }, lyricsSection)
  end

  -- Only offer players that actually have media, plus the current one, so the
  -- phone's idle MPRIS stubs don't each show up as a nameless "phone" entry.
  switcherRows = {}
  local kdeShown = 0
  for _, p in ipairs(snap.players or {}) do
    if p.hasMedia or p.name == snap.name then
      switcherRows[#switcherRows + 1] = p
      if p.isKde then
        kdeShown = kdeShown + 1
      end
    end
  end

  if SHOW_PLAYER_SWITCHER and #switcherRows > 1 then
    -- Index 0 is "Auto" (follow the service's pick); indices 1.. map to
    -- switcherRows. The bullet marks whichever player is currently playing.
    local options = { noctalia.tr("ui.auto") }
    local selectedIndex = 0
    for i, p in ipairs(switcherRows) do
      local label = p.label
      -- Several apps on the phone all report as "phone"; tell them apart by track.
      if p.isKde and kdeShown > 1 and p.title ~= "" and p.title ~= p.name then
        label = label .. " - " .. p.title
      end
      if p.name == snap.name then
        label = "\u{2022} " .. label
        if snap.pinned ~= nil then
          selectedIndex = i
        end
      end
      options[i + 1] = label
    end
    body[#body + 1] = ui.select({ options = options, selectedIndex = selectedIndex, onChange = "onPlayerSelected" })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, {
    header(),
    ui.scroll({ flexGrow = 1, gap = 12, align = "stretch" }, body),
  }))
end

-- ── wiring ───────────────────────────────────────────────────────────────────

noctalia.state.watch("pm.now", function(value)
  snap = value or emptyNow()
  updateArtwork(snap.artUrl)
  -- a fresh snapshot after our seek committed means the service has caught up.
  if seeking and (noctalia.nowMs() - seekCommittedAtMs) > 250 then
    seeking, pendingSeekUs = false, nil
  end
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
  updateArtwork(snap.artUrl)
  panel.setWantsSecondTicks(true)
  panel.setNeedsFrameTick(true)
  if SHOW_LYRICS then
    noctalia.state.set("pm.want", noctalia.nowMs())
  end
  render()
end

function onClose()
  isOpen = false
  panel.setWantsSecondTicks(false)
  panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs)
  frameAccumMs = frameAccumMs + (tonumber(deltaMs) or 16)
  if frameAccumMs >= 100 then
    frameAccumMs = 0
    render()
  end
end

function update()
  if SHOW_LYRICS then
    noctalia.state.set("pm.want", noctalia.nowMs())
  end
  -- Guard against a drag whose end event never arrives (pointer released off the
  -- slider): without this `seeking` would pin the bar and lyrics forever.
  if seeking then
    seekIdleTicks = seekIdleTicks + 1
    if seekIdleTicks >= 8 then
      seeking, pendingSeekUs, seekIdleTicks = false, nil, 0
    end
  end
end

function onCloseClicked()
  panel.close()
end

function onOpenLyricsPanel()
  -- panel-open, not togglePanel: always open, never close if already open.
  noctalia.runAsync({ "noctalia", "msg", "panel-open", "jechton/phone-media:lyrics" })
end

function onSeekChange(value)
  value = tonumber(value) or 0
  local targetUs = math.floor(value * 1000000)
  -- The host pushes our own rendered value back into the slider on every redraw,
  -- which re-fires onChange. Ignore that echo so it neither starts a phantom
  -- seek nor keeps resetting the stuck-drag watchdog.
  if seeking then
    if pendingSeekUs == nil or math.abs(targetUs - pendingSeekUs) < 500000 then
      return
    end
  elseif math.abs(value - livePositionUs() / 1000000) < 1.5 then
    return
  end
  seeking, seekIdleTicks = true, 0
  pendingSeekUs = targetUs
  render()
end

function onSeekEnd()
  if pendingSeekUs ~= nil then
    sendCmd({ action = "seek", sec = pendingSeekUs / 1000000 })
    seekCommittedAtMs = noctalia.nowMs()
    seekIdleTicks = 0
  else
    seeking = false
  end
  render()
end

function onPlayPause()
  sendCmd({ action = "toggle" })
end

function onPrevious()
  sendCmd({ action = "prev" })
end

function onNext()
  sendCmd({ action = "next" })
end

function onPlayerSelected(index)
  local i = tonumber(index) or 0
  if i <= 0 then
    sendCmd({ action = "pin", name = false })
  else
    local chosen = switcherRows[i]
    if chosen ~= nil then
      sendCmd({ action = "pin", name = chosen.name })
    end
  end
end
