--!nonstrict
-- Runnable check for tailscale/tailscale.luau's pure parsers (no host API).
-- Run from the repo root:
--
--   nix run nixpkgs#luau -- tests/tailscale_selftest.luau
--
-- Exits non-zero on the first failed assertion.

local ts = require("../tailscale/tailscale")

local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

local accounts = ts.parseAccounts([[
ID    Tailnet            Account
7cd6  example.com        me@example.com
c1a0  other.ts.net*      other@x.com*
]])
check("two accounts", #accounts == 2)
check("header skipped", accounts[1].id == "7cd6")
check("inactive row", accounts[1].active == false)
check("active row", accounts[2].active == true)
check("star stripped", accounts[2].tailnet == "other.ts.net" and accounts[2].account == "other@x.com")
check("empty output", #ts.parseAccounts("") == 0)

local status = ts.parseStatus({ BackendState = "Running", CurrentTailnet = { Name = "example.com" } })
check("status state", status.state == "Running")
check("status tailnet", status.tailnet == "example.com")
check("status without tailnet", ts.parseStatus({ BackendState = "NeedsLogin" }).tailnet == nil)

if failures > 0 then
  error(failures .. " check(s) failed")
end
