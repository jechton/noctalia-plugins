# noctalia-plugins

Personal [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugins.

| Plugin | ID | What it does |
| --- | --- | --- |
| [home-assistant](home-assistant/) | `jechton/home-assistant` | Bar and desktop widgets that render a Home Assistant Jinja template via the `/api/template` endpoint. |
| [kimai](kimai/) | `jechton/kimai` | Bar widget and panel for a self-hosted Kimai instance: track the running time entry, and start/stop/edit it. |
| [phone-media](phone-media/) | `jechton/phone-media` | Now-playing bar widget and popup replacing the builtins, to function better with KDE connect. Scrolling over the widget changes phone volume. Also includes lyrics in the popup, and a lyrics bar and popup. |
| [tenpo-ko](tenpo-ko/) | `jechton/tenpo-ko` | Bar widget showing tenpo ko (elemental time): the UTC day split into four six-hour blocks. |

## Using these

Add this repo as a plugin source in Noctalia's settings (Plugins tab), or point
a `kind = "git"` / `kind = "path"` source at it, then enable the plugins by id.

## Development

Each plugin is a directory with a `plugin.toml`, one or more `*.luau` entry
files, and `translations/`.

This repo is a flake. `nix develop` (or direnv) gives you `noctalia`,
`luau-lsp`, `stylua`, and `taplo`, installs the pre-commit hook, and drops
gitignored `noctalia.d.luau` type stubs into each plugin dir for editor
completion.

- `nix flake check` lints every plugin (`noctalia plugins lint`) and checks
  formatting. CI runs exactly this.
- `nix fmt` formats (stylua, taplo, nixfmt, keep-sorted).
- Lint one plugin directly: `noctalia plugins lint <plugin-dir>`.

### Consuming from a NixOS flake

```nix
inputs.noctalia-plugins.url = "github:jechton/noctalia-plugins";
```

then point a `kind = "path"` Noctalia plugin source at
`toString inputs.noctalia-plugins`. Iterate against the working tree without
committing using `--override-input noctalia-plugins /path/to/this/repo`.
