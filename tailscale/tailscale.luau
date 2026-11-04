--!nonstrict
-- Shared Tailscale helpers: pure parsers for CLI output, plus thin wrappers
-- that run the CLI through noctalia.runAsync. Needs the user to be the
-- tailscale operator (`sudo tailscale set --operator=$USER`) for switch/up/down.

local M = {}

local TIMEOUT_MS = 15000

-- "tailscale status --json" decoded table -> { state, tailnet }. state is the
-- BackendState ("Running", "Stopped", "NeedsLogin", "Starting", ...).
function M.parseStatus(data)
  local tailnet = data.CurrentTailnet and data.CurrentTailnet.Name or nil
  return { state = data.BackendState or "", tailnet = tailnet }
end

-- "tailscale switch --list" output -> { { id, tailnet, account, active } }.
-- Columns are "ID Tailnet Account"; the active row carries a trailing "*".
function M.parseAccounts(text)
  local accounts = {}
  for line in string.gmatch(text, "[^\r\n]+") do
    local fields = {}
    for field in string.gmatch(line, "%S+") do
      fields[#fields + 1] = field
    end
    if #fields >= 3 and fields[1] ~= "ID" then
      accounts[#accounts + 1] = {
        id = fields[1],
        tailnet = (string.gsub(fields[2], "%*", "")),
        account = (string.gsub(fields[#fields], "%*", "")),
        active = string.find(line, "*", 1, true) ~= nil,
      }
    end
  end
  return accounts
end

-- Maps a failed CommandResult to a translation key, or a raw message.
function M.errorMessage(result)
  local err = result.stderr ~= "" and result.stderr or result.stdout
  if string.find(err, "access denied", 1, true) or string.find(err, "set --operator", 1, true) then
    return noctalia.tr("errors.operator")
  end
  return noctalia.tr("errors.failed", { message = (string.gsub(err, "%s+$", "")) })
end

-- Runs `tailscale <args>`; onDone(ok, result).
local function run(args, onDone)
  local argv = { "tailscale" }
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end
  noctalia.runAsync(argv, function(result)
    onDone(result.exitCode == 0 and not result.timedOut, result)
  end, TIMEOUT_MS)
end

function M.status(onDone)
  run({ "status", "--json" }, function(ok, result)
    if not ok then
      onDone(false, result)
      return
    end
    onDone(true, M.parseStatus(noctalia.json.decode(result.stdout)))
  end)
end

function M.accounts(onDone)
  run({ "switch", "--list" }, function(ok, result)
    onDone(ok, ok and M.parseAccounts(result.stdout) or result)
  end)
end

function M.switchTo(id, onDone)
  run({ "switch", id }, onDone)
end

function M.setConnected(connected, onDone)
  run({ connected and "up" or "down" }, onDone)
end

return M
