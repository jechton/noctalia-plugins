--!nonstrict
-- Tailscale panel: a connect/disconnect button and the account list. Clicking
-- an account runs `tailscale switch <id>`.

local ts = require("./tailscale.luau")

local POLL_TICKS = math.max(2, tonumber(noctalia.getConfig("poll_seconds")) or 5)

local isOpen = false
local status = nil
local accounts = {}
local busy = false
local errorMessage = nil
local tick = 0

local STATE_KEY = {
  Running = "state.running",
  Stopped = "state.stopped",
  NeedsLogin = "state.needs_login",
  Starting = "state.starting",
}

local function render()
  local connected = status ~= nil and status.state == "Running"
  local stateKey = status and STATE_KEY[status.state] or "state.loading"

  local rows = {}
  for _, account in ipairs(accounts) do
    rows[#rows + 1] = ui.button({
      key = account.id,
      text = account.account .. "  " .. account.tailnet,
      glyph = account.active and "check" or nil,
      variant = account.active and "primary" or "ghost",
      enabled = not busy and not account.active,
      onClick = function()
        onSwitch(account.id)
      end,
    })
  end
  if #rows == 0 then
    rows[1] = ui.label({ text = noctalia.tr("accounts.empty"), color = "on_surface_variant" })
  end

  local body = {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.label({ text = noctalia.tr(stateKey), color = connected and "primary" or "on_surface_variant", flexGrow = 1 }),
      ui.button({
        text = noctalia.tr(connected and "action.disconnect" or "action.connect"),
        variant = "primary",
        enabled = not busy and status ~= nil,
        onClick = "onToggle",
      }),
    }),
  }
  if errorMessage ~= nil then
    body[#body + 1] = ui.label({ text = errorMessage, color = "error", maxLines = 3 })
  end
  body[#body + 1] = ui.separator({})
  body[#body + 1] = ui.label({ text = noctalia.tr("accounts.title"), fontWeight = "bold", color = "on_surface" })
  body[#body + 1] = ui.scroll({ flexGrow = 1, gap = 4, align = "stretch" }, rows)

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, body))
end

local function refresh()
  ts.status(function(ok, parsed)
    if ok then
      status = parsed
    else
      status = nil
      errorMessage = ts.errorMessage(parsed)
    end
    render()
  end)
  ts.accounts(function(ok, parsed)
    if ok then
      accounts = parsed
    else
      accounts = {}
      errorMessage = ts.errorMessage(parsed)
    end
    render()
  end)
end

-- Runs a mutating command, then refreshes the panel and the bar.
local function afterAction(ok, result)
  busy = false
  errorMessage = ok and nil or ts.errorMessage(result)
  noctalia.runAsync({ "noctalia", "msg", "plugin", "jechton/tailscale:bar", "all", "refresh" })
  refresh()
end

function onSwitch(id)
  busy = true
  errorMessage = nil
  render()
  ts.switchTo(id, afterAction)
end

function onToggle()
  busy = true
  errorMessage = nil
  render()
  ts.setConnected(not (status ~= nil and status.state == "Running"), afterAction)
end

function onCloseClicked()
  panel.close()
end

function onOpen(_context)
  isOpen = true
  tick = 0
  render()
  refresh()
end

function onClose()
  isOpen = false
end

function update()
  if not isOpen or busy then
    return
  end
  tick = tick + 1
  if tick % POLL_TICKS == 0 then
    refresh()
  end
end
