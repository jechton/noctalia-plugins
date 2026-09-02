# Home Assistant

Bar and desktop widgets that render a Home Assistant Jinja template.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jechton/home-assistant` |
| Entries | Bar widget: `template` &nbsp;·&nbsp; Desktop widget: `template-desktop` |
| Auth | Long-lived access token, sent as `Authorization: Bearer` |

## How it works

Both widgets read the Jinja template at `template_file`, POST it to Home
Assistant's `POST /api/template` endpoint every `poll_seconds`, and render the
returned text. HA renders the template server-side, so `custom_templates`
imports, macros, `states()`, everything works exactly as it does in a phone
widget.

- **Bar widget** flattens the output to a single line (whitespace collapsed).
- **Desktop widget** lays the non-blank output lines out in a grid, larger. A
  Jinja loop that emits one line per item lands as one cell per item; `columns`
  controls items per row (1 = vertical list, item-count = single row).

Tweaking the display means editing the template, not the Lua.

The template is **not bundled**: it's whatever you want, and often holds personal
data. Copy `example.jinja`, adapt it, and keep the result private (an agenix
secret, or any path outside version control).

## Setup

1. In Home Assistant, open your profile → **Security** → create a **long-lived
   access token**.
2. Configure the connection one of two ways:
   - Inline: set **Home Assistant URL** and **Access token**.
   - Secret file: set **Credentials file** to a path holding two lines, the URL
     then the token (blank lines and `#` comments ignored). Wins over the inline
     values.
3. Write your template (see `example.jinja`) and point the widget's
   **template_file** at it. If it imports a `custom_templates` macro file, that
   file must exist in HA's `config/custom_templates/`. Confirm it renders under
   **Developer Tools → Template**.
4. Add the **Home Assistant** widget to a bar section, and/or the desktop widget
   via Noctalia's desktop-widget editor.

## Settings

### Connection (plugin)

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `credentials_file` | `file` | `""` | Secret file: URL line 1, token line 2. Wins over inline. |
| `base_url` | `string` | `""` | Instance URL. |
| `token` | `string` | `""` | Long-lived access token. |
| `insecure_tls` | `bool` | `false` | Skip TLS verification. Trusted private endpoints only. |

### Per widget

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `template_file` | `file` | `""` | Path to the Jinja template to render (required). See `example.jinja`. |
| `poll_seconds` | `int` | `30` | Re-render interval. |
| `dashboard_path` | `string` | `""` | Bar widget only: appended to the URL on click. |
| `font_family` | `string` | `""` | Bar widget only: override the bar font. |
| `title` | `string` | `""` | Desktop widget only: optional heading. |
| `columns` | `int` | `1` | Desktop widget only: items per row (1 = list, item-count = single row). |
| `cell_width` | `int` | `0` | Desktop widget only: fixed px width per cell so columns align on a constant pitch. 0 = natural width. |
| `cell_align` | `select` | `center` | Desktop widget only: text position within a fixed-width cell. |
| `column_gap` / `row_gap` | `int` | `16` / `6` | Desktop widget only: px spacing between cells / rows. |
| `cell_height` | `int` | `0` | Desktop widget only: fixed px height per cell. 0 = text height. |
| `font_size` | `int` | `22` | Desktop widget only: text size. |
