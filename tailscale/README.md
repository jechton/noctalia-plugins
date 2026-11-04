# Tailscale

Bar widget and panel for Tailscale. Connect or disconnect, and switch between
accounts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jechton/tailscale` |
| Entries | Bar widget: `bar` &nbsp;·&nbsp; Panel: `panel` |

## Requirements

The `tailscale` CLI, and your user set as the operator so `switch`, `up`, and
`down` work without root:

```sh
sudo tailscale set --operator=$USER
```

On NixOS: `services.tailscale.extraSetFlags = [ "--operator=<user>" ]`.

The operator is stored per Tailscale profile, and `tailscale set` only changes
the active profile. If the panel shows "Run once: sudo tailscale set
--operator=$USER" after switching accounts, run that command once while on the
profile that lacks it. This includes NixOS: `extraSetFlags` is applied only to
whichever profile is active when `tailscaled` starts.

The bar widget runs `tailscale status --json` every `poll_seconds`. The panel
also runs `tailscale switch --list` while open, and `tailscale up`, `down`, or
`switch <id>` on click.
