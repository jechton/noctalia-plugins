# Kimai

Bar widget and panel for a self-hosted [Kimai](https://www.kimai.org/) instance.
Track the running time entry from the bar, and start, stop, or edit it from the
panel.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jechton/kimai` |
| Entries | Bar widget: `bar` &nbsp;·&nbsp; Panel: `panel` |
| Auth | Kimai API token, sent as `Authorization: Bearer` |

## Requirements

A reachable Kimai instance and an API token (sent as `Authorization: Bearer`).
The bar widget polls the REST API over the network every `poll_seconds`; the
panel calls it on open and on each action. No external commands are spawned. No
bundled dependencies.

## Usage

1. In Kimai, open **Users → (your user) → API access** and create a token.
2. Configure the plugin one of two ways:
   - Inline: set **Kimai URL** (instance root, no trailing `/api`, e.g.
     `https://kimai.example.com`) and **API token**.
   - Secret file: set **Credentials file** to a path holding two lines, the URL
     then the token (blank lines and `#` comments ignored). An agenix secret
     path works, and it wins over the inline values.
3. Add the **Kimai** widget to a bar section. Left-click opens the panel.

Open the panel manually with:

```sh
noctalia msg panel-toggle jechton/kimai:panel
```

## Bar widget

- Running: a clock glyph, the elapsed time (`H:MM`), and optionally the project
  name. The label advances every second and the entry is re-fetched every
  `poll_seconds`.
- Idle / unconfigured: a dim clock glyph with an explanatory tooltip, or nothing
  when **Hide when idle** is on.

## Panel

- **Running**: elapsed time, editable project / activity / description / start
  time, **Save** (PATCH) and **Stop**.
- **Idle**: project, activity, and description pickers, then **Start**.

Both modes show a **This week** total: the sum of every entry begun since the
most recent Sunday 00:00 (local), including the running timer, which Kimai's own
totals leave out. It ticks up live while a timer runs.

Activities offered are the selected project's own plus any global activities.
The start-time field edits only the time of day; the date stays as recorded.

The idle form defaults to the project / activity / description of your most
recent timesheet on the server, falling back to the first project.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `credentials_file` | `file` | `""` | Secret file: URL on line 1, token on line 2. Wins over the inline values. |
| `base_url` | `string` | `""` | Instance root URL, without `/api`. |
| `api_token` | `string` | `""` | API token. |
| `poll_seconds` | `int` | `15` | Bar widget re-check interval. |
| `insecure_tls` | `bool` | `false` | Skip TLS verification. Trusted private endpoints only. |
| `show_project` | `bool` | `true` | Prefix the elapsed time with the project name (widget). |
| `hide_when_idle` | `bool` | `false` | Hide the widget when no timer runs. |

## Notes

- Talks only to the configured Kimai instance, sending the API token as a bearer
  header. Panel actions issue `POST` (start), `PATCH` (stop/edit) requests.
- `insecure_tls` disables certificate verification for that instance.
- The "This week" total is computed client-side from timesheets since the most
  recent Sunday 00:00 local, including the running timer.
