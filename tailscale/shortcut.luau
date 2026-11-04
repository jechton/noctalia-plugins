--!nonstrict
-- Control Center tile: shows the active account and cycles to the next one on
-- click. Right-click opens the panel.

local ts = require("./tailscale.luau")

local TAILNET_FIRST = noctalia.getConfig("account_label") == "tailnet"
local POLL_TICKS = math.max(2, tonumber(noctalia.getConfig("poll_seconds")) or 5)

local connected = false
local accounts = {}
local busy = false
local tick = 0

local function render()
  local active = nil
  for _, account in ipairs(accounts) do
    if account.active then
      active = account
    end
  end
  local label = noctalia.tr("title")
  if active ~= nil then
    label = TAILNET_FIRST and active.tailnet or active.account
  end
  shortcut.setLabel(label)
  shortcut.setIcon("world", "world-off")
  shortcut.setActive(connected)
  shortcut.setEnabled(not busy and ts.nextAccount(accounts) ~= nil)
end

local function refresh()
  ts.status(function(ok, parsed)
    connected = ok and parsed.state == "Running"
    render()
  end)
  ts.accounts(function(ok, parsed)
    accounts = ok and parsed or {}
    render()
  end)
end

function onClick()
  local target = ts.nextAccount(accounts)
  if busy or target == nil then
    return
  end
  busy = true
  render()
  ts.switchTo(target.id, function(ok, result)
    busy = false
    if not ok then
      noctalia.notifyError(noctalia.tr("title"), ts.errorMessage(result))
    end
    noctalia.runAsync({ "noctalia", "msg", "plugin", "jechton/tailscale:bar", "all", "refresh" })
    refresh()
  end)
end

function onRightClick()
  noctalia.togglePanel("jechton/tailscale:panel")
end

function update()
  noctalia.setUpdateInterval(1000)
  tick = tick + 1
  if tick % POLL_TICKS == 1 then
    refresh()
  end
end

render()
