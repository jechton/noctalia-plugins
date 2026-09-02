--!nonstrict
-- Shared Home Assistant client. Long-lived-token auth against an HA instance.
-- Config getters read noctalia.getConfig() on each call rather than caching, so
-- every entry sees the current settings.

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
  local token = noctalia.string.trim(noctalia.getConfig("token") or "")

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

-- POST /api/template with the given Jinja source. HA renders it server-side
-- (custom_templates imports, macros and all) and returns plain text.
-- cb(ok, text, err): text is the rendered string; err is a human-readable
-- message when ok is false.
function M.renderTemplate(template, cb)
  local cfg = M.config()
  if not M.ready(cfg) then
    cb(false, nil, noctalia.tr("errors.not_configured"))
    return
  end

  local payload = noctalia.json.encode({ template = template })
  local started = noctalia.http({
    url = cfg.base .. "/api/template",
    method = "POST",
    headers = {
      "Authorization: Bearer " .. cfg.token,
      "Content-Type: application/json",
    },
    body = payload,
    follow_redirects = true,
    allow_insecure_tls = cfg.insecure,
  }, function(response)
    if not response.ok then
      cb(false, nil, noctalia.tr("errors.network"))
      return
    end
    if response.status >= 200 and response.status < 300 then
      cb(true, response.body or "", nil)
      return
    end
    -- HA returns the template error (or "401: Unauthorized") as a plain body.
    local message = "HTTP " .. tostring(response.status)
    if response.body ~= nil and response.body ~= "" then
      message = response.body
    end
    cb(false, nil, message)
  end)

  if not started then
    cb(false, nil, noctalia.tr("errors.blocked"))
  end
end

return M
