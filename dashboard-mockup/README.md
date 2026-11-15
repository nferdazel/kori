# kori dashboard mockup, revision 4

Static HTML mockup of the four-page read-only surface designed in `../DASHBOARD-surface.md` revision 4 and
directed by `../DASHBOARD-direction.md`. No binary, no server, no build step, no network.

## Open it

Open `index.html` in a browser (`file://` is fine), or:

```sh
open index.html
```

The two fonts are bundled in `assets/fonts/` and load from the folder; a page that phones a font CDN has
failed the delivery gate.

## Files

| File | What it is |
|---|---|
| `index.html` | Overview: route strip, five readouts, the request tape, served-share split bar, 20 failover events, 10-row preview, the mock-only demo switch |
| `requests.html` | Requests: five filters in the URL, caption, 50 rows per page, row expansion to the nine D6 keys, backward paging, keyboard path, empty state |
| `routes.html` | Routes: per-leg table with `failed_in_window`, both cooling shapes, latency p50/max, last seen |
| `config.html` | Config: listener and balance, legs with role and weight, timeouts and cooldowns, log, credentials (redacted, one `missing`) |
| `assets/app.css` | Tokens, type, components and breakpoints; dark only; reduced-motion rules |
| `assets/app.js` | One renderer for all four pages: shell, countdown ring, tape, split bar, filters, paging, keyboard, demo switch |
| `assets/data.js` | Two fake snapshots, 3 legs each, 96 log rows per snapshot, window counters, config |
| `assets/fonts/inter-latin-var.woff2` | Inter variable, latin subset, WOFF2 |
| `assets/fonts/jetbrains-mono-latin-var.woff2` | JetBrains Mono variable, latin subset, WOFF2 |
| `.shots/` | Screenshots at 1440, 768 and 360, scenario B, and `report.json` from the browser pass |

## Keyboard

| Key | Does |
|---|---|
| `1` `2` `3` `4` | Switch page |
| `j` / `k` | Move the selected log row on Requests (`↓` / `↑` work too) |
| `Enter` | Expand or close the selected row |
| `/` | Focus the Route filter |
| `Esc` | Clear filters, or close the row first |

Every stop has a visible mark: the focus ring on controls, the `--ink` left rule on the selected row and
the active rail item.

## Two demo states

The switch in the Overview header is a mockup affordance, not a product control: the real page has one live
state. It exists so the two facts that matter to D12 can be seen rather than described.

- **One cooling.** The last ten requests split 5/5 between `opencode-go` and `commandcode`, `opencode-go` is
  `◐ cooling` on `auth_401` with `failed_in_window` 2, and `commandcode` keeps serving. `sinarcloud` is the
  fallback and has served nothing.
- **Both cooling.** `opencode-go` is `⊘ quota` for 900 s, `commandcode` is `◐ cooling` on `auth_401`, and
  `sinarcloud` serves everything: 18 / 18 / 60.

## The one chart

The request tape is the only shape that encodes magnitude. Fifty columns from the log tail in log order:
height is `latency_ms` on a linear scale from 0 to the window maximum with a 4 px floor, colour is the leg,
and a request that carried `failover_from` gets a 2 px amber cap. It is built from log rows only. The
served-share bar is a two-tone proportion with the counts and percentages printed beside it.

Leg colours in the tape and the bar are a desaturated scale (`--leg-1` / `--leg-2` / `--leg-3`) so that
saturated colour stays reserved for state. The leg is also printed in the caption, the share list and every
log row, so colour never carries meaning alone.

## What is fake

Everything. The snapshots are frozen at 23:04:31 and 23:06:02 on 2026-11-14, the legs and log rows are
generated in `assets/data.js`, and the config is invented. No request leaves the page: no `fetch`, no
network, no binary behind it.

The fake log carries `auth_401`, `conn_refused`, `header_timeout`, `upstream_5xx`, `quota_429`,
`mid_stream_abort` and the empty reason. `dial_timeout` and `missing_session_id` do not appear, so filtering
them reaches the empty state on purpose; that shows the empty state and says nothing about a real log.

## What this proves

Everything in `DASHBOARD-direction.md` §9 that can be checked without a binary:

- Four pages, one shell, one nav, `GET`-shaped links only; no page mutates anything.
- No console error and no network request on a plain file open (`report.json`).
- No horizontal scrollbar at 360, 768 or 1440 on any page.
- The tape exists, uses log rows, shows the amber failover cap, and degrades to 20 columns at 360 px.
- The served share is a split bar with counts and percentages; 5/5 and 18/18/60 both render.
- `◐` amber and `⊘` violet differ in glyph, word, window and until time, not only in colour.
- Filters live in the URL, paging and expansion work, the empty state is reachable, `j k Enter / Esc` and
  `1`–`4` work with visible focus.
- Config shows role and weight, and shows credential source and state, never a value, prefix, length or hash.

## What it does not prove

No endpoint exists, so nothing here proves `/admin/state`, `/admin/log` or `/admin/config` returns these
shapes; that the binary serves the pages without a build step; that tail scanning, the scan budget,
`more_older`, `400` above `limit=200` or `405` on write methods work; that `served_in_window` and
`failed_in_window` are incremented the way D11.1 and D12 say; that the 5 s refresh keeps filters and the open
row when the endpoint is real; or that a 118 MB log loads. The snapshots also have no `unknown` leg, so that
state is specified but not shown, and a weight other than 1 has no rounding rule yet, so the fake data only
ever shows weight 1.
