# Phone Media

A now-playing bar widget and popup that replace Noctalia's builtin `media`
widget and its control-center media tab. Similar now-playing display and transport
controls, plus:

- wheel/touchpad **scroll over the widget changes volume**: the phone's volume
  when the active player is KDE Connect (via MPRIS `Volume`, which kdeconnect
  proxies to the device), otherwise the laptop's own volume
- synced-lyrics support: an inline preview in the popup, plus a standalone
  lyrics bar widget and full-lyrics popup

The builtin media widget is compiled with no scroll hook and the plugin API
exposes no MPRIS state, so player data comes from polling `playerctl`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jechton/phone-media` |
| Entries | Bar widgets: `bar`, `lyrics_bar`; panels: `panel`, `lyrics` |

## Requirements

Install `playerctl` on `PATH`. Phone volume and phone transport control need a
paired KDE Connect device exposing an MPRIS player. Lyrics are fetched from
lrclib.net over the network.

## Usage

Add the **Phone Media** widget to a bar section. Optionally also add the
**Phone Media Lyrics** widget for a standalone synced-lyrics preview.

- **Bar widget** left-click opens the now-playing popup; right-click is
  play/pause; back/forward are previous/next; scroll is volume.
- **Lyrics bar widget** left-click opens the full-lyrics popup.

Open the popups manually with:

```sh
noctalia msg panel-toggle jechton/phone-media:panel
noctalia msg panel-toggle jechton/phone-media:lyrics
```

## Settings

Plugin-level: `lyrics_offset_ms` shifts synced lyrics earlier (negative) or
later (positive) everywhere they show.

Each widget and panel carries its own knobs, grouped in Settings:

- **`bar`**: whether to show at all when no media is playing (`hide_when_no_media`), what to show (album
  art, artist, progress bar), and how long titles behave (`title_scroll`), plus
  sizing under "advanced".
- **`panel`**: which parts of the now-playing card are visible (album art,
  album name, source label, progress bar, time labels, playback controls,
  lyrics section, player switcher).
- **`lyrics_bar`**: `hide_when_no_lyrics`, `show_current_line`, `max_length`.
- **`lyrics` panel**: `show_track_info`, `text_align`.

## Notes

- Spawns `playerctl` roughly once a second (metadata), plus one `playerctl
  position` a second while a progress bar is shown; the bar advances locally
  between polls.
- KDE Connect leaves an idle MPRIS player on the bus per phone app; player
  selection prefers a *playing* KDE Connect player, then any playing player,
  then any player with real track metadata. Uses `playerInstance` (unique per
  app), not `playerName` (always `kdeconnect`).
- The popup drops the builtin's PipeWire spectrum visualizer: a KDE Connect
  player's audio never touches this machine's PipeWire graph, so it would stay
  blank.
