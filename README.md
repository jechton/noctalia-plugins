# noctalia-plugins

Personal [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugins.

| Plugin | ID | What it does |
| --- | --- | --- |
| [phone-media](phone-media/) | `jechton/phone-media` | Now-playing bar widget and popup replacing the builtins, to function better with KDE connect. Scrolling over the widget changes phone volume. Also includes lyrics in the popup, and a lyrics bar and popup. |
| [tenpo-ko](tenpo-ko/) | `jechton/tenpo-ko` | Bar widget showing tenpo ko (elemental time): the UTC day split into four six-hour blocks. |

## Using these

Add this repo as a plugin source in Noctalia's settings (Plugins tab), or point
a `kind = "git"` / `kind = "path"` source at it, then enable the plugins by id.

## Development

Each plugin is a directory with a `plugin.toml`, one or more `*.luau` entry
files, and `translations/`. Validate one offline with:

```sh
noctalia plugins lint <plugin-dir>
```

CI runs that on every plugin on push and PR.
