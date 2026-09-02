--!nonstrict
-- Shared synced-lyrics logic for jechton/phone-media: LRC parsing (metadata
-- filtering, `[offset:]`, the odd `[mm:ss:xx]` / `[mm:ss-xx]` timestamp forms,
-- partly-synced files), active-line lookup, and fetching from lrclib.net (free,
-- no API key, matches by title/artist/album/duration). Used by lyrics_bar.luau,
-- lyrics_panel.luau, and the lyrics section embedded in panel.luau, so all three
-- agree on what counts as a match and how a timestamp maps to a line. Needs
-- plugin_api >= 22, where require() arrived. The parser has a runnable check at
-- tests/lyrics_selftest.luau.

local M = {}

local BASE_URL = "https://lrclib.net/api"
local HEADERS = { "User-Agent: noctalia-phone-media-plugin (https://github.com/jechton/nixos)" }

-- Per-VM result cache, keyed by trackKey. Each consumer (bar widget, popup,
-- lyrics panel) runs its own Luau VM so they cannot share this, but it still
-- spares a network round trip every time playback returns to a recent track,
-- including the empty result for a track with no lyrics on file.
local CACHE_MAX = 24
local cache = {} -- key -> { lines = <array|false>, source = <string|false> }
local cacheOrder = {} -- keys, oldest first

local function cacheGet(key)
  local hit = cache[key]
  if hit == nil then
    return nil
  end
  return {
    lines = hit.lines or nil,
    source = hit.source or nil,
  }
end

local function cachePut(key, lines, source)
  if key == "" then
    return
  end
  if cache[key] == nil then
    cacheOrder[#cacheOrder + 1] = key
    if #cacheOrder > CACHE_MAX then
      local evicted = table.remove(cacheOrder, 1)
      cache[evicted] = nil
    end
  end
  cache[key] = { lines = lines or false, source = source or false }
end

-- ID tags that carry no lyric text ([ar:], [ti:], [offset:], …). Without this
-- filter they leak into the rendered lines as if they were lyrics, since a
-- plain-text lyric line and `[ti:Song Name]` both lack a timestamp.
local METADATA_IDS = {
  ar = true,
  ti = true,
  al = true,
  au = true,
  by = true,
  re = true,
  ve = true,
  offset = true,
  length = true,
  lang = true,
  encoding = true,
  tool = true,
}

local function isMetadataLine(trimmed)
  local id = trimmed:match("^%[(%a+)%s*:")
  return id ~= nil and METADATA_IDS[id:lower()] == true
end

-- Strips the leading `[mm:ss(.xx)]` timestamp tags off a line, returning the
-- times (ms) and the remaining text. Accepts the common `[mm:ss.xx]` plus the
-- rarer `[mm:ss]`, `[mm:ss:xx]` and `[mm:ss-xx]` forms; the fractional part is
-- read by digit count (1 -> tenths, 2 -> hundredths, 3 -> ms) so `[00:12.5]`
-- and `[00:12.500]` both mean 12.5s.
local function stripTimestamps(rawLine)
  local times = {}
  local rest = rawLine
  while true do
    local mm, ss, frac, endPos = rest:match("^%s*%[(%d+):(%d%d?)[%.:%-](%d+)%]()")
    if mm == nil then
      mm, ss, endPos = rest:match("^%s*%[(%d+):(%d%d?)%]()")
      frac = nil
    end
    if mm == nil then
      break
    end
    local fracMs = 0
    if frac ~= nil then
      local v = tonumber(frac) or 0
      local n = #frac
      fracMs = (n == 1 and v * 100) or (n == 2 and v * 10) or v
    end
    times[#times + 1] = tonumber(mm) * 60000 + tonumber(ss) * 1000 + fracMs
    rest = rest:sub(endPos)
  end
  return times, rest
end

-- Parses an LRC (or plain-text) lyric into a list of { timeMs, text }, synced
-- lines first in time order, then any unsynced lines (timeMs -1) in file order
-- so a partly-timestamped file still shows every line. A line may carry several
-- timestamps (a repeated chorus), expanding to one entry per timestamp. Honours
-- an `[offset:±ms]` tag by shifting every timestamp (positive = later, matching
-- the noctalia-official media-lyrics plugin). Returns nil if nothing parsed.
function M.parseLRC(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end

  local offsetMs = tonumber(text:match("%[offset%s*:%s*([%+%-]?%d+)%]")) or 0

  local synced, unsynced = {}, {}
  for rawLine in text:gmatch("[^\r\n]+") do
    local times, rest = stripTimestamps(rawLine)
    local lyricText = rest:match("^%s*(.-)%s*$")
    if #times > 0 then
      if lyricText ~= "" then
        for _, timeMs in ipairs(times) do
          synced[#synced + 1] = { timeMs = math.floor(timeMs + offsetMs + 0.5), text = lyricText }
        end
      end
    else
      local trimmed = rawLine:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not isMetadataLine(trimmed) then
        unsynced[#unsynced + 1] = { timeMs = -1, text = trimmed }
      end
    end
  end

  if #synced == 0 and #unsynced == 0 then
    return nil
  end
  table.sort(synced, function(a, b)
    return a.timeMs < b.timeMs
  end)
  for _, line in ipairs(unsynced) do
    synced[#synced + 1] = line
  end
  return synced
end

-- Index of the last line whose timestamp has passed, or nil if lines is nil,
-- empty, or unsynced (every timeMs is -1).
function M.activeLineIndex(lines, positionMs)
  if lines == nil then
    return nil
  end
  local index = nil
  for i, line in ipairs(lines) do
    if line.timeMs >= 0 and line.timeMs <= positionMs then
      index = i
    elseif line.timeMs >= 0 then
      break
    end
  end
  return index
end

-- Stable key for "is this still the same track", so consumers can skip
-- refetching when playerctl reports the same metadata again.
function M.trackKey(track)
  if track == nil then
    return ""
  end
  local durationSeconds = math.floor((track.lengthUs or 0) / 1000000)
  return (track.title or "") .. "\30" .. (track.artist or "") .. "\30" .. (track.album or "") .. "\30" .. tostring(
    durationSeconds
  )
end

-- "synced" only when a real timestamp survived parsing; an LRC body that turned
-- out to be all metadata / plain text falls through to the plainLyrics field.
local function hasTimestamp(lines)
  for _, line in ipairs(lines) do
    if line.timeMs >= 0 then
      return true
    end
  end
  return false
end

local function extractLines(entry)
  if type(entry) ~= "table" then
    return nil, nil
  end
  local synced = M.parseLRC(entry.syncedLyrics)
  if synced ~= nil and hasTimestamp(synced) then
    return synced, "synced"
  end
  local plain = M.parseLRC(entry.plainLyrics)
  if plain ~= nil then
    return plain, "plain"
  end
  if synced ~= nil then
    return synced, "plain"
  end
  return nil, nil
end

local function statusOk(res)
  return res ~= nil and res.ok == true and res.status ~= nil and res.status >= 200 and res.status < 300
end

-- Of the search hits, prefer the one whose duration is closest to the playing
-- track (within 5s), so a "live" or extended cut whose timestamps wouldn't line
-- up doesn't win just for being first. Falls back to the first hit.
local function bestByDuration(hits, durationSeconds)
  if durationSeconds <= 0 then
    return hits[1]
  end
  local best, bestDelta = nil, nil
  for _, hit in ipairs(hits) do
    local d = tonumber(hit.duration)
    if d ~= nil then
      local delta = math.abs(d - durationSeconds)
      if bestDelta == nil or delta < bestDelta then
        best, bestDelta = hit, delta
      end
    end
  end
  if best ~= nil and bestDelta <= 5 then
    return best
  end
  return hits[1]
end

local function searchFallback(track, callback)
  local query = "track_name=" .. noctalia.string.urlEncode(track.title) .. "&artist_name=" .. noctalia.string.urlEncode(
    track.artist or ""
  )
  local durationSeconds = math.floor((track.lengthUs or 0) / 1000000)
  local started = noctalia.http({ url = BASE_URL .. "/search?" .. query, headers = HEADERS }, function(res)
    if not statusOk(res) or res.body == nil or res.body == "" then
      callback(nil, nil)
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" or data[1] == nil then
      callback(nil, nil)
      return
    end
    local lines, source = extractLines(bestByDuration(data, durationSeconds))
    callback(lines, source)
  end)
  if not started then
    callback(nil, nil)
  end
end

-- track = { title, artist, album, lengthUs }. callback(lines_or_nil, source)
-- where source is "synced", "plain", or nil when nothing was found.
function M.fetchLyrics(track, callback)
  if track == nil or track.title == nil or track.title == "" then
    callback(nil, nil)
    return
  end

  local cacheKey = M.trackKey(track)
  local cached = cacheGet(cacheKey)
  if cached ~= nil then
    callback(cached.lines, cached.source)
    return
  end

  local function finish(lines, source)
    cachePut(cacheKey, lines, source)
    callback(lines, source)
  end

  local query = "track_name=" .. noctalia.string.urlEncode(track.title) .. "&artist_name=" .. noctalia.string.urlEncode(
    track.artist or ""
  )
  if track.album ~= nil and track.album ~= "" then
    query = query .. "&album_name=" .. noctalia.string.urlEncode(track.album)
  end
  local durationSeconds = math.floor((track.lengthUs or 0) / 1000000)
  if durationSeconds > 0 then
    query = query .. "&duration=" .. tostring(durationSeconds)
  end

  local started = noctalia.http({ url = BASE_URL .. "/get?" .. query, headers = HEADERS }, function(res)
    if statusOk(res) and res.body ~= nil and res.body ~= "" then
      local data = noctalia.json.decode(res.body)
      local lines, source = extractLines(data)
      if lines ~= nil then
        finish(lines, source)
        return
      end
    end
    -- No exact match (404) or an exact match with no lyrics on file: a fuzzy
    -- search still turns up the right song often enough to be worth trying.
    searchFallback(track, finish)
  end)
  if not started then
    finish(nil, nil)
  end
end

return M
