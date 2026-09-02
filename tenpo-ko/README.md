# Tenpo Ko

A bar clock for *tenpo ko* ("elemental time"), which splits the 24-hour day
into four fixed six-hour blocks relative to UTC, each named for an element.
Invented by marzka and Joop Kiefte; this widget mirrors
[dozens' clock](https://tilde.town/~dozens/tenpoko/).

| Block | Toki pona | UTC |
| --- | --- | --- |
| 🔥 fire | tenpo seli | 00-06 |
| ☁️ air | tenpo kon | 06-12 |
| 💧 water | tenpo telo | 12-18 |
| 🌱 earth | tenpo ma | 18-24 |

The block is `floor(UTC_hour / 6)`; the time after the name counts from the
start of the block, i.e. `(UTC_hour % 6):MM[:SS]`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jechton/tenpo-ko` |
| Entries | Bar widget: `bar` |

## Usage

Add the **Tenpo Ko** widget to a bar section in Settings. Left-click opens
dozens' clock in a browser.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `name_style` | `select` | `english` | Label the block with its English name, its toki pona name, or nothing. |
| `drop_tenpo_prefix` | `bool` | `false` | With toki pona names, show just `seli` / `kon` / `telo` / `ma` without the leading `tenpo`. |
| `show_emoji` | `bool` | `true` | Prefix the label with the block's element emoji. |
| `show_seconds` | `bool` | `false` | Include seconds in the time. Also raises the redraw rate to 1s. |
