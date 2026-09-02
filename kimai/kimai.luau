--!nonstrict
-- Shared Kimai REST client. Bearer-token auth against a hosted Kimai instance.
-- Every entry (bar widget, panel) requires its own copy of the config, so the
-- getters read noctalia.getConfig() on each call rather than caching.
--
-- `begin` is a Lua keyword, so Kimai's `begin` field is always addressed as
-- row["begin"] / { ["begin"] = ... }.

local M = {}

local function trimTrailingSlash(s)
  return (s or ""):gsub("/+$", "")
end

-- First two non-blank, non-comment lines of the credentials file: URL, token.
local function readCredentialsFile(path)
  local contents = noctalia.readFile(path)
  if contents == nil then
    return nil, nil
  end
  local lines = {}
  for line in (contents .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = noctalia.string.trim(line)
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      lines[#lines + 1] = trimmed
    end
  end
  return lines[1], lines[2]
end

function M.config()
  local base = noctalia.string.trim(noctalia.getConfig("base_url") or "")
  local token = noctalia.string.trim(noctalia.getConfig("api_token") or "")

  local credentialsFile = noctalia.string.trim(noctalia.getConfig("credentials_file") or "")
  if credentialsFile ~= "" then
    local fileUrl, fileToken = readCredentialsFile(credentialsFile)
    base = fileUrl or base
    token = fileToken or token
  end

  return {
    base = trimTrailingSlash(base),
    token = token,
    insecure = noctalia.getConfig("insecure_tls") == true,
  }
end

function M.ready(cfg)
  cfg = cfg or M.config()
  return cfg.base ~= "" and cfg.token ~= ""
end

-- method: "GET" | "POST" | "PATCH". path starts with "/api/...". body is a table
-- or nil. cb(ok, data, status, err): ok is true only on a 2xx response; data is
-- the decoded JSON body (nil for an empty body); err is a human-readable string
-- when ok is false.
function M.request(method, path, body, cb)
  local cfg = M.config()
  if not M.ready(cfg) then
    cb(false, nil, 0, noctalia.tr("errors.not_configured"))
    return
  end

  local headers = {
    "Authorization: Bearer " .. cfg.token,
    "Accept: application/json",
  }
  local payload = nil
  if body ~= nil then
    headers[#headers + 1] = "Content-Type: application/json"
    payload = noctalia.json.encode(body)
  end

  local started = noctalia.http({
    url = cfg.base .. path,
    method = method,
    headers = headers,
    body = payload,
    follow_redirects = true,
    allow_insecure_tls = cfg.insecure,
  }, function(response)
    if not response.ok then
      cb(false, nil, 0, noctalia.tr("errors.network"))
      return
    end

    local data = nil
    if response.body ~= nil and response.body ~= "" then
      data = noctalia.json.decode(response.body)
    end

    local ok = response.status >= 200 and response.status < 300
    local err = nil
    if not ok then
      err = "HTTP " .. tostring(response.status)
      if type(data) == "table" and type(data.message) == "string" then
        err = data.message
      end
    end
    cb(ok, data, response.status, err)
  end)

  if not started then
    cb(false, nil, 0, noctalia.tr("errors.blocked"))
  end
end

-- ── endpoint wrappers ────────────────────────────────────────────────────────

function M.active(cb)
  M.request("GET", "/api/timesheets/active", nil, cb)
end

function M.stop(id, cb)
  M.request("PATCH", "/api/timesheets/" .. tostring(id) .. "/stop", nil, cb)
end

function M.start(fields, cb)
  M.request("POST", "/api/timesheets", fields, cb)
end

function M.patch(id, fields, cb)
  M.request("PATCH", "/api/timesheets/" .. tostring(id), fields, cb)
end

function M.projects(cb)
  M.request("GET", "/api/projects?visible=1&order_by=name", nil, cb)
end

function M.activities(cb)
  M.request("GET", "/api/activities?visible=1&order_by=name", nil, cb)
end

-- Most recent timesheets, newest first, for defaulting the idle form to the
-- last project / activity worked.
function M.recent(cb)
  M.request("GET", "/api/timesheets?size=5&orderBy=begin&order=DESC", nil, cb)
end

-- Every timesheet that began at or after beginIso, following pagination.
-- cb(ok, list, err).
function M.timesheetsSince(beginIso, cb)
  local all = {}
  local function fetchPage(page)
    local path = "/api/timesheets?size=100&page=" .. page .. "&begin=" .. noctalia.string.urlEncode(beginIso)
    M.request("GET", path, nil, function(ok, data, _status, err)
      if not ok then
        -- A page past the last one returns 404; that just means we are done.
        if err == "HTTP 404" and page > 1 then
          cb(true, all)
        else
          cb(false, nil, err)
        end
        return
      end
      if type(data) == "table" then
        for _, entry in ipairs(data) do
          all[#all + 1] = entry
        end
        if #data >= 100 and page < 20 then
          fetchPage(page + 1)
          return
        end
      end
      cb(true, all)
    end)
  end
  fetchPage(1)
end

-- ── time helpers ─────────────────────────────────────────────────────────────
--
-- The plugin runtime's os.time/os.date are UTC (no TZ set), so anything the user
-- sees goes through noctalia.formatTime (timezone-aware), and epoch maths is
-- done directly rather than via os.time's timezone-dependent table form.

-- Days between 1970-01-01 and y-m-d, proleptic Gregorian (Howard Hinnant).
local function daysFromCivil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = math.floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civilFromDays(z)
  z = z + 719468
  local era = math.floor((z >= 0 and z or z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return (m <= 2 and y + 1 or y), m, d
end

-- Unix seconds for an ISO 8601 datetime with a numeric offset or trailing Z
-- (e.g. Kimai's "2026-09-02T02:36:00-0400"). nil when unparseable.
local function iso8601Seconds(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = raw:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if y == nil then
    return nil
  end
  local offset = 0
  local sign, oh, om = raw:match("([%+%-])(%d%d):?(%d%d)%s*$")
  if sign ~= nil then
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  return daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + tonumber(s)
    - offset
end

-- Kimai wants an HTML5 local datetime with no zone suffix; it reads it in the
-- account's configured timezone.
function M.nowDateTime()
  return noctalia.formatTime("%Y-%m-%dT%H:%M:%S")
end

-- Local datetime string for 00:00 on the most recent Sunday.
function M.weekStartDateTime()
  local weekday = tonumber(noctalia.formatTime("%w")) or 0 -- 0 = Sunday
  local y, m, d = noctalia.formatTime("%Y-%m-%d"):match("(%d+)-(%d+)-(%d+)")
  local sy, sm, sd = civilFromDays(daysFromCivil(tonumber(y), tonumber(m), tonumber(d)) - weekday)
  return string.format("%04d-%02d-%02dT00:00:00", sy, sm, sd)
end

-- Unix seconds for a timesheet's begin. nil when missing or unparseable.
function M.beginSeconds(row)
  return iso8601Seconds(row and row["begin"])
end

-- Local calendar date ("YYYY-MM-DD") of a timesheet's begin, for rebuilding a
-- begin string when only the time-of-day is edited.
function M.beginDate(row)
  local secs = M.beginSeconds(row)
  return secs and noctalia.formatTime("%Y-%m-%d", secs) or nil
end

-- "2:47 PM" for a Unix-seconds timestamp, in local time.
function M.formatClock(unixSeconds)
  return (noctalia.formatTime("%I:%M %p", unixSeconds):gsub("^0(%d)", "%1"))
end

-- Parse "2:47 PM", "2:47pm", "14:47" (no suffix means 24-hour) to (hour24,
-- minute). nil when it does not parse or is out of range.
function M.parseClock(text)
  local h, m, suffix = noctalia.string.trim(text or ""):lower():match("^(%d%d?):(%d%d)%s*(%a*)$")
  if h == nil then
    return nil
  end
  h, m = tonumber(h), tonumber(m)
  if m > 59 then
    return nil
  end
  if suffix == "" then
    if h > 23 then
      return nil
    end
  elseif suffix == "am" or suffix == "a" then
    if h < 1 or h > 12 then
      return nil
    end
    if h == 12 then
      h = 0
    end
  elseif suffix == "pm" or suffix == "p" then
    if h < 1 or h > 12 then
      return nil
    end
    if h < 12 then
      h = h + 12
    end
  else
    return nil
  end
  return h, m
end

-- Elapsed seconds for a timesheet. Kimai reports duration = 0 for a running
-- entry (end == nil) until it is stopped, so that case is computed live from
-- begin instead.
function M.elapsedSeconds(row)
  if row["end"] == nil then
    local begun = M.beginSeconds(row)
    return begun and math.max(0, noctalia.nowMs() / 1000 - begun) or 0
  end
  return type(row.duration) == "number" and row.duration or 0
end

function M.hhmm(totalSeconds)
  totalSeconds = math.max(0, math.floor(totalSeconds or 0))
  return string.format("%d:%02d", math.floor(totalSeconds / 3600), math.floor(totalSeconds / 60) % 60)
end

-- A timesheet's project / activity reference. The plain collections return a
-- bare id, but /api/timesheets/active and /api/timesheets/{id} expand it to the
-- full entity object; this yields the id either way. nil stays nil.
function M.entityId(ref)
  if type(ref) == "table" then
    return ref.id
  end
  return ref
end

-- { id = entity } index for a project/activity list response.
function M.indexById(list)
  local byId = {}
  if type(list) == "table" then
    for _, entity in ipairs(list) do
      if type(entity) == "table" and entity.id ~= nil then
        byId[tostring(entity.id)] = entity
      end
    end
  end
  return byId
end

return M
