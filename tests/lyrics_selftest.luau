--!nonstrict
-- Runnable check for phone-media/lyrics.luau's LRC parser (pure string logic,
-- no host API). Run from the repo root:
--
--   nix run nixpkgs#luau -- tests/lyrics_selftest.luau
--
-- Exits non-zero on the first failed assertion.

local lyrics = require("../phone-media/lyrics")

local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

local function times(lines)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l.timeMs
  end
  return out
end

local function eq(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- basic sorted parse + chorus expansion (one entry per timestamp)
do
  local l = lyrics.parseLRC("[00:30.00]second\n[00:10.00][01:00.00]chorus\n")
  check("basic: 3 entries", #l == 3)
  check("basic: time sorted", eq(times(l), { 10000, 30000, 60000 }))
  check("basic: chorus text at 10s and 60s", l[1].text == "chorus" and l[3].text == "chorus")
end

-- metadata tags never become lyric lines
do
  local l = lyrics.parseLRC("[ti:My Song]\n[ar:The Band]\n[00:01.00]real line\n")
  check("metadata: only the real line survives", #l == 1 and l[1].text == "real line")
end

-- alternate fraction separators: [mm:ss:xx] and [mm:ss-xx]
do
  local l = lyrics.parseLRC("[00:12:50]a\n[00:13-5]b\n")
  check("separators: colon fraction", l[1].timeMs == 12500)
  check("separators: dash fraction", l[2].timeMs == 13500)
end

-- fractional part read by digit count
do
  local l = lyrics.parseLRC("[00:01.5]a\n[00:01.50]b\n[00:01.500]c\n[00:02.05]d\n")
  check("fraction: .5 == 1500ms", l[1].timeMs == 1500)
  check("fraction: .50 == 1500ms", l[2].timeMs == 1500)
  check("fraction: .500 == 1500ms", l[3].timeMs == 1500)
  check("fraction: .05 == 2050ms", l[4].timeMs == 2050)
end

-- [offset:] shifts every timestamp (positive = later)
do
  local l = lyrics.parseLRC("[offset:+500]\n[00:10.00]a\n")
  check("offset: +500 -> 10500ms", l[1].timeMs == 10500)
  local n = lyrics.parseLRC("[offset:-250]\n[00:10.00]a\n")
  check("offset: -250 -> 9750ms", n[1].timeMs == 9750)
end

-- partly-synced file keeps unsynced lines, after the synced ones, in file order
do
  local l = lyrics.parseLRC("[00:20.00]synced two\nplain A\n[00:10.00]synced one\nplain B\n")
  check("partial: 4 entries", #l == 4)
  check("partial: synced first in time order", l[1].text == "synced one" and l[2].text == "synced two")
  check("partial: unsynced after, file order", l[3].text == "plain A" and l[4].text == "plain B")
  check("partial: unsynced marked -1", l[3].timeMs == -1 and l[4].timeMs == -1)
end

-- plain lyrics through parseLRC: every line unsynced
do
  local l = lyrics.parseLRC("line one\nline two\n\nline three\n")
  check("plain: 3 non-empty lines", #l == 3)
  check("plain: all -1", l[1].timeMs == -1 and l[3].timeMs == -1)
end

-- empty / junk input
do
  check("empty: nil for empty string", lyrics.parseLRC("") == nil)
  check("empty: nil for metadata-only", lyrics.parseLRC("[ti:x]\n[ar:y]\n") == nil)
end

-- activeLineIndex walks synced lines, ignores trailing unsynced
do
  local l = lyrics.parseLRC("[00:01.00]a\n[00:03.00]b\n[00:05.00]c\ntrailing note\n")
  check("active: before first -> nil", lyrics.activeLineIndex(l, 0) == nil)
  check("active: mid -> 2", lyrics.activeLineIndex(l, 3500) == 2)
  check("active: past end -> 3", lyrics.activeLineIndex(l, 99000) == 3)
end

if failures > 0 then
  error(tostring(failures) .. " failure(s)")
end
print("\nall lyrics parser checks passed")
