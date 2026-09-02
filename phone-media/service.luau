--!nonstrict
-- Phone Media service: the single headless owner of player state and lyrics.
--
-- Before this existed, the bar widget, lyrics bar widget, now-playing panel and
-- lyrics panel each ran their own `playerctl` poll loop and their own lyrics
-- lookup. Now one [[service]] entry polls once and publishes snapshots through
-- noctalia.state; every UI entry is a thin consumer that renders the snapshot
-- and sends commands back.
--
--   pm.now    -> { hasPlayer, name, isKde, status, title, artist, album,
--                  artUrl, lengthUs, positionUs, positionAtMs, trackKey,
--                  players = { { name, isKde, label, hasMedia } }, pinned, rev }
--   pm.lyrics -> { trackKey, status = idle|loading|ready|empty|unreachable,
--                  source = synced|plain|nil, lines = { { timeMs, text } } }
--   pm.cmd    -> { action, nonce, ... } sent by the UI (see handleCommand)
--   pm.want   -> nowMs() heartbeat: a UI entry showing lyrics pings this so the
--                service only fetches lyrics when something is actually watching
--
-- Player data still comes from `playerctl` (the plugin API exposes no MPRIS):
-- one `playerctl -a metadata` a second, one `playerctl position` twice a second
-- for the selected player. Consumers interpolate position from positionAtMs.

local lyrics = require("./lyrics.luau")

local TICK_MS = 500
local METADATA_EVERY = 2 -- ticks (~1s)
local WANT_WINDOW_MS = 8000 -- fetch lyrics only if a UI pinged pm.want this recently

local SEP = string.char(31)
-- playerInstance, not playerName: KDE Connect reports every phone app as the
-- same playerName ("kdeconnect"), so `playerctl --player=kdeconnect` would hit
-- an arbitrary one. The instance (kdeconnect.mpris_<id>) is unique per app.
local FORMAT = table.concat({
  "{{playerInstance}}",
  "{{status}}",
  "{{title}}",
  "{{artist}}",
  "{{album}}",
  "{{mpris:artUrl}}",
  "{{mpris:length}}",
}, SEP)

local VOLUME_STEP = "0.05"

-- ── state ────────────────────────────────────────────────────────────────────

local tick = 0
local metadataInFlight = false
local positionInFlight = false
local pinnedName = nil

local now = {
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
  trackKey = "",
  players = {},
  pinned = nil,
  rev = 0,
}

local lyricsState = { trackKey = "", status = "idle", source = nil, lines = nil }
local lyricsFetchToken = 0
local lyricsFetchedKey = "" -- trackKey we last kicked a fetch for

-- ── helpers ──────────────────────────────────────────────────────────────────

local function isKde(name)
  return name ~= nil and string.find(name, "kdeconnect", 1, true) ~= nil
end

-- KDE Connect leaves an idle MPRIS player on the bus for every media app on the
-- phone; those report Paused/Stopped with no title, so "has media" needs actual
-- playback or real track metadata.
local function hasMedia(row)
  return row.status == "Playing" or (row.title ~= "" and row.title ~= row.name)
end

local function playerLabel(row)
  if isKde(row.name) then
    return noctalia.tr("ui.via_phone")
  end
  return row.name
end

-- a playing KDE Connect player wins, then any playing player, then a KDE
-- Connect player with metadata, then any player with metadata. A pinned player
-- overrides all of that until it disappears.
local function pick(rows)
  if pinnedName ~= nil then
    for _, r in ipairs(rows) do
      if r.name == pinnedName then
        return r
      end
    end
    pinnedName = nil
  end
  local kdePlaying, playing, kdeMedia, anyMedia
  for _, r in ipairs(rows) do
    if r.status == "Playing" then
      playing = playing or r
      if isKde(r.name) then
        kdePlaying = kdePlaying or r
      end
    end
    if hasMedia(r) then
      anyMedia = anyMedia or r
      if isKde(r.name) then
        kdeMedia = kdeMedia or r
      end
    end
  end
  return kdePlaying or playing or kdeMedia or anyMedia
end

local function publishNow()
  now.rev = now.rev + 1
  now.pinned = pinnedName
  noctalia.state.set("pm.now", now)
end

local function publishLyrics()
  noctalia.state.set("pm.lyrics", {
    trackKey = lyricsState.trackKey,
    status = lyricsState.status,
    source = lyricsState.source,
    lines = lyricsState.lines,
  })
end

local function clearPlayer()
  if not now.hasPlayer and now.title == "" and #now.players == 0 then
    return
  end
  now.hasPlayer = false
  now.name, now.isKde, now.status = "", false, ""
  now.title, now.artist, now.album, now.artUrl = "", "", "", ""
  now.lengthUs, now.positionUs, now.positionAtMs = 0, 0, 0
  now.trackKey, now.players = "", {}
  lyricsState = { trackKey = "", status = "idle", source = nil, lines = nil }
  lyricsFetchedKey = ""
  publishNow()
  publishLyrics()
end

-- ── lyrics ───────────────────────────────────────────────────────────────────

local function wantsLyrics()
  local want = tonumber(noctalia.state.get("pm.want")) or 0
  return (noctalia.nowMs() - want) < WANT_WINDOW_MS
end

local function fetchLyricsFor(track, key)
  lyricsFetchToken = lyricsFetchToken + 1
  local token = lyricsFetchToken
  lyricsFetchedKey = key
  lyricsState = { trackKey = key, status = "loading", source = nil, lines = nil }
  publishLyrics()
  lyrics.fetchLyrics(track, function(lines, source, status)
    if token ~= lyricsFetchToken then
      return
    end
    local resolved = "ready"
    if lines == nil then
      resolved = status == "unreachable" and "unreachable" or "empty"
    end
    lyricsState = { trackKey = key, status = resolved, source = source, lines = lines }
    publishLyrics()
  end)
end

-- Fetch for the current track when a lyrics UI is watching and we haven't
-- already fetched this track.
local function maybeFetchLyrics()
  if not now.hasPlayer or now.trackKey == "" or now.title == "" then
    return
  end
  if lyricsFetchedKey == now.trackKey or not wantsLyrics() then
    return
  end
  fetchLyricsFor({
    title = now.title,
    artist = now.artist,
    album = now.album,
    lengthUs = now.lengthUs,
  }, now.trackKey)
end

-- ── polling ──────────────────────────────────────────────────────────────────

local function refreshPosition()
  if positionInFlight or not now.hasPlayer or now.name == "" then
    return
  end
  positionInFlight = true
  local name = now.name
  noctalia.runAsync({ "playerctl", "--player=" .. name, "position" }, function(result)
    positionInFlight = false
    if result.exitCode ~= 0 or now.name ~= name then
      return
    end
    local seconds = tonumber((result.stdout or ""):match("[%d%.]+"))
    if seconds == nil then
      return
    end
    now.positionUs = math.floor(seconds * 1000000)
    now.positionAtMs = noctalia.nowMs()
    publishNow()
  end)
end

local function refreshMetadata()
  if metadataInFlight then
    return
  end
  metadataInFlight = true
  noctalia.runAsync({ "playerctl", "-a", "metadata", "--format", FORMAT }, function(result)
    metadataInFlight = false
    if result.exitCode ~= 0 then
      clearPlayer()
      return
    end

    local rows = {}
    for line in (result.stdout or ""):gmatch("[^\n]+") do
      local name, status, title, artist, album, art, lengthUs = line:match(
        "^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$"
      )
      if name ~= nil then
        rows[#rows + 1] = {
          name = name,
          status = status,
          title = (title ~= "" and title) or name,
          artist = artist or "",
          album = album or "",
          art = art or "",
          lengthUs = tonumber(lengthUs) or 0,
        }
      end
    end

    local chosen = pick(rows)
    if chosen == nil then
      clearPlayer()
      return
    end

    local players = {}
    for _, r in ipairs(rows) do
      players[#players + 1] = {
        name = r.name,
        isKde = isKde(r.name),
        label = playerLabel(r),
        title = r.title,
        hasMedia = hasMedia(r),
      }
    end

    local trackKey = lyrics.trackKey({
      title = chosen.title,
      artist = chosen.artist,
      album = chosen.album,
      lengthUs = chosen.lengthUs,
    })
    local trackChanged = trackKey ~= now.trackKey or not now.hasPlayer

    now.hasPlayer = true
    now.name = chosen.name
    now.isKde = isKde(chosen.name)
    now.status = chosen.status
    now.title = chosen.title
    now.artist = chosen.artist
    now.album = chosen.album
    now.artUrl = chosen.art
    now.lengthUs = chosen.lengthUs
    now.players = players
    now.trackKey = trackKey
    if trackChanged then
      now.positionUs, now.positionAtMs = 0, noctalia.nowMs()
      lyricsState = { trackKey = trackKey, status = "idle", source = nil, lines = nil }
      lyricsFetchedKey = ""
      publishLyrics()
    end

    publishNow()
    maybeFetchLyrics()
  end)
end

-- ── commands ─────────────────────────────────────────────────────────────────

local function playerctl(...)
  if now.name == "" then
    return
  end
  noctalia.runAsync({ "playerctl", "--player=" .. now.name, ... })
end

local function handleCommand(cmd)
  local a = cmd.action
  if a == "toggle" then
    playerctl("play-pause")
  elseif a == "next" then
    playerctl("next")
  elseif a == "prev" then
    playerctl("previous")
  elseif a == "seek" then
    local sec = tonumber(cmd.sec)
    if sec ~= nil then
      sec = math.max(0, sec)
      playerctl("position", tostring(sec))
      now.positionUs, now.positionAtMs = math.floor(sec * 1000000), noctalia.nowMs()
      publishNow()
    end
  elseif a == "volume" then
    if now.isKde then
      local delta = cmd.dir == "down" and (VOLUME_STEP .. "-") or (VOLUME_STEP .. "+")
      playerctl("volume", delta)
    else
      noctalia.runAsync({ "noctalia", "msg", cmd.dir == "down" and "volume-down" or "volume-up" })
    end
  elseif a == "pin" then
    pinnedName = (type(cmd.name) == "string" and cmd.name ~= "") and cmd.name or nil
    refreshMetadata()
  elseif a == "refetchLyrics" then
    if now.trackKey ~= "" and now.title ~= "" then
      fetchLyricsFor({
        title = now.title,
        artist = now.artist,
        album = now.album,
        lengthUs = now.lengthUs,
      }, now.trackKey)
    end
  end
  -- a command usually changes playback; re-poll promptly so the UI catches up
  if a ~= "pin" and a ~= "refetchLyrics" then
    noctalia.runAsync({ "sleep", "0.3" }, function()
      refreshMetadata()
      refreshPosition()
    end)
  end
end

noctalia.state.watch("pm.cmd", function(cmd)
  if type(cmd) == "table" and cmd.action ~= nil then
    handleCommand(cmd)
  end
end)

-- A lyrics UI just appeared: fetch now instead of waiting for the next track.
noctalia.state.watch("pm.want", function()
  maybeFetchLyrics()
end)

-- ── lifecycle ────────────────────────────────────────────────────────────────

function onConfigChanged()
  -- offset_ms / cache settings changed: rebuild lyrics for the current track.
  lyricsFetchedKey = ""
  if now.trackKey ~= "" and now.title ~= "" and wantsLyrics() then
    fetchLyricsFor({
      title = now.title,
      artist = now.artist,
      album = now.album,
      lengthUs = now.lengthUs,
    }, now.trackKey)
  end
end

function onEnable()
  publishNow()
  publishLyrics()
  refreshMetadata()
end

function update()
  tick = tick + 1
  if tick % METADATA_EVERY == 0 then
    refreshMetadata()
  end
  refreshPosition()
  maybeFetchLyrics()
end

noctalia.setUpdateInterval(TICK_MS)
