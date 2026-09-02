--!nonstrict
-- Shared bits for the template bar widget and desktop widget: load the Jinja
-- template from template_file, render it against HA, and shape the result.
-- Settings are read per-entry, so both entries must declare template_file /
-- poll_seconds.

local ha = require("./ha.luau")

local M = {}

-- The template is user-supplied and never bundled (it often contains personal
-- data). Returns nil when template_file is unset or the file is missing/empty.
function M.loadTemplate()
  local path = noctalia.string.trim(noctalia.getConfig("template_file") or "")
  if path == "" then
    return nil
  end
  local contents = noctalia.readFile(path)
  if contents ~= nil and noctalia.string.trim(contents) ~= "" then
    return contents
  end
  return nil
end

function M.pollTicks()
  return math.max(5, tonumber(noctalia.getConfig("poll_seconds")) or 30)
end

-- cb(ok, rawText, err) with the template output exactly as HA returned it.
function M.fetch(template, cb)
  ha.renderTemplate(template, function(ok, body, err)
    if not ok then
      cb(false, nil, err)
      return
    end
    cb(true, body or "", nil)
  end)
end

-- Everything on one line: collapse each whitespace run to a single space. A
-- U+2060 word-joiner is not whitespace and survives, so glued glyph pairs stay
-- glued.
function M.oneLine(raw)
  return noctalia.string.trim((raw or ""):gsub("%s+", " "))
end

-- Non-blank lines, each trimmed. Jinja `{% %}` control blocks leave blank lines
-- behind; dropping them turns a per-item loop into one entry per line.
function M.lines(raw)
  local out = {}
  for line in ((raw or "") .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = noctalia.string.trim(line)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

return M
