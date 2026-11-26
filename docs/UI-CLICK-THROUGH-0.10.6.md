# UI click-through, 0.10.6

Date: 2026-11-26. Machine: this Mac. Binary: `apps/api/src/kori` built from the working tree at
`569f07f`, `VERSION` 0.10.6. Config and log under
`~/.openmausbot/workloop/items/kori/2026-11-25-ui-verification/`.

This closes the gap `docs/UI-CLICK-THROUGH-0.10.5.md` listed under "Not covered here": 360 px
layout, keyboard order, the model switches, and screenshots kept with the harness. It found one
defect, fixed in `569f07f`.

Nothing here touched qouver1 and nothing was pushed.

## How to repeat it

The harness is a plain Node script driving Chrome over the DevTools protocol. No dependencies, no
Playwright install, no browser extension.

```sh
# 1. test config, tokens, and two slow stub providers on 18091 and 18092
W=~/.openmausbot/workloop/items/kori/2026-11-25-ui-verification
cd ~/Projects/kori
python3 acceptance/stub.py --port 18091 --mode ok --delay-headers 0.45 \
  --count-file "$W/leg-a.count" --capture-file "$W/leg-a.req" &
python3 acceptance/stub.py --port 18092 --mode ok --delay-headers 0.45 \
  --count-file "$W/leg-b.count" --capture-file "$W/leg-b.req" &

# 2. the gateway, with the fixture tokens
KORI_ADMIN_TOKEN_FILE="$W/admin.token" \
KORI_ADMIN_WRITE_TOKEN_FILE="$W/admin-write.token" \
  ./apps/api/src/kori --config "$W/config.json" --port 18090 &

# 3. a session cookie, minted the same way the login page mints it
curl -sS -D "$W/login.head" -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d '{"token":"test-write-token-not-a-secret"}' http://127.0.0.1:18090/session/login
grep -i '^set-cookie' "$W/login.head" | sed 's/^[Ss]et-[Cc]ookie: //' | cut -d';' -f1 > "$W/cookie.txt"

# 4. headless Chrome with a debugging port, then the scripts
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --remote-debugging-port=19222 --user-data-dir="$W/chrome-profile" about:blank &
node "$W/cdp.mjs" 19222 "file://$W/steps3.mjs"   # toggles, dialog, banner, keyboard, 360 px
node "$W/cdp.mjs" 19222 "file://$W/steps4.mjs"   # the latency table at both widths
node "$W/cdp.mjs" 19222 "file://$W/steps6.mjs"   # deterministic state-by-state screenshots
node "$W/cdp.mjs" 19222 "file://$W/steps8.mjs"   # the Requests prompt-size filter
```

Each click is an `Input.dispatchMouseEvent` pressed/released pair at the element's centre, after
`scrollIntoView`. Each keystroke is an `Input.dispatchKeyEvent`. A click that lands outside the
viewport is a click the page never sees, which is the one harness bug this run had to fix.

Seed data: ten requests per round at 0, 4, 20, 40, 60, 90, 120, 150, 200 and 300 KiB of prompt, at
0.05 s and 0.45 s stub delay, so every bucket has samples and the percentiles differ from each other.

## What was clicked, and what happened

| Step | Action | Observed |
|---|---|---|
| 1 | sign in with the write token, open `/config.html` | three legs and two model aliases render; footer reads `read + write` |
| 2 | click the `leg-b` provider switch | `leg-b` becomes `OVERRIDE · file on · skipped · override off · switched off from the dashboard`, with a `reset`; status `leg-b: applied, reload queued` |
| 3 | click `leg-b` again | `file on · serving · override on`, status `leg-b: applied, reload queued` |
| 4 | click the `kori/jev` model switch | `override off · not serving`; the switch is global, both legs map it |
| 5 | click `kori/jev` again | `override on · serving` |
| 6 | click `leg-a` off, then `leg-b` off | `PUT /admin/overrides` answers `409`; the page opens **"Turn off the last serving provider?"**, body `This turns off the last serving provider. Requests will answer 503 until one is back on.`, buttons `Cancel` / `Turn it off anyway`, focus on `Cancel` |
| 7 | press Escape | dialog closes, status `leg-b: nothing was saved. The last serving provider is still on.`, focus returns to the `leg-b` switch |
| 8 | reopen, press `Turn it off anyway` | banner `No provider is serving; every request answers 503.`, both switches read `skipped` |
| 9 | click `leg-a` back on | banner disappears, `leg-a` reads `file on · serving · override on` |

`started_at` was `2026-11-26T08:31:30+07:00` before steps 2 and 3 and identical after them: two
writes, no restart. The process log for the session shows one PID and one
`SIGHUP reload applied` line per write.

## What a request sees while nothing serves

```
HTTP/1.1 503
{"error":{"type":"no_leg_enabled","message":"every provider is switched off in the gateway"}}
log row: {"route":"","status":503,"failover_reason":"no_leg_enabled","legs_cooling":0,"retry_after_s":null}
```

`no_leg_enabled` carries no `Retry-After` on purpose: a config state is not a wait. The
`all_legs_cooling` shape, which does carry one, is `a23`'s.

## Restart persistence

Switched `leg-b` off through the UI, then killed and restarted the process with the same config.

```
started_at  before 2026-11-26T08:43:23+07:00   after 2026-11-26T08:44:01+07:00   changed: yes
/admin/config  leg-a enabled:true serving:true override:null
               leg-b enabled:true serving:false override:false
               leg-c enabled:false serving:false override:null
               overrides.legs {"leg-b":false}
```

The page renders the same three states after the restart with no write and no reload. `admin_writes`
reads `no dashboard writes yet` because the counter is process-scoped, which is correct: it counts
writes this process has done.

## 360 px, one column

Measured with the window at 360 x 800 CSS pixels.

| View | `documentElement.scrollWidth` | Horizontal overflow | Layout |
|---|---|---|---|
| `/config.html` | 360 | none | `.cfg` is one column (`328px`); each leg row is `22px 266px`, the ordinal then the rest |
| `/index.html` | 360 | none | `.cols` is one column; the latency table's scroll box is `326` wide with `326` of scroll, so it fits rather than scrolls |
| `/requests.html` | 360 | none | the prompt-size filter sits above the table, table inside its own box |

Switch hit targets are `48 x 44` at every width, above the 44 px target the plan asked for. The
nav collapses to the same four labels in one row; no page needed a sideways scroll.

## Keyboard order

Tab from the top of `/config.html`, no mouse, recording every stop:

```
1  a:Skip to content                8  input[legs:leg-b]
2  a:1Overview                      9  input[legs:leg-c]
3  a:2Requests                     10  input[models:kori/fast]
4  a:3Routes                       11  input[models:kori/jev]
5  a:4Config                       12  (wraps to the skip link)
6  button:log out
7  input[legs:leg-a]
```

Every stop reports `:focus-visible` true with a `2px solid rgb(233, 235, 238)` outline, so the ring
is real and not an artifact of my measurement. A `reset` button appears in the order only while that
name has an override, right after its switch.

Inside the dialog, opened by Space on the `leg-b` switch (no mouse at all): focus lands on `Cancel`
with a visible ring, one Tab moves to `Turn it off anyway` with a visible ring, Escape closes and
returns focus to the switch that opened it.

## The defect this found

The Overview's latency table showed `0.0s` for all five buckets. It shares `secs()`, which rounds to
one decimal of a second, and a local p50 of 61 to 66 ms is 0.0 s at that precision. The table exists
to compare buckets, so the number it was built to show was invisible.

Direct query of the same file, same nearest-rank method:

```
<32      n=18 p50=62ms p90=761ms p99=761ms
32-64    n=12 p50=61ms p90=760ms p99=764ms
64-128   n=12 p50=62ms p90=756ms p99=765ms
128-256  n=12 p50=66ms p90=761ms p99=767ms
>=256    n= 6 p50=62ms p90=764ms p99=764ms
```

After the fix the rendered table reads `62ms | 761ms | 761ms`, `61ms | 760ms | 764ms`, and so on,
matching the query row for row. A second and above still prints as `1.2s`. Fixed in `569f07f`;
`docs/UI-CLICK-THROUGH-0.10.5.md` records the same table showing `0.0s` before it.

## Screenshots

Under `~/.openmausbot/workloop/items/kori/2026-11-25-ui-verification/shots/`:

| File | Shows |
|---|---|
| `40-config-clean.png` | the page at 1280 px before any write |
| `41-config-one-off.png` | one provider off, the `OVERRIDE` badge and `reset` |
| `42-config-banner.png` | `No provider is serving; every request answers 503.` |
| `43-dialog.png` | the last-leg dialog with `Cancel` focused |
| `44-config-360.png`, `45-config-360-legs.png` | the config page at 360 px, one column, 44 px switches |
| `46-overview-360.png`, `47-overview-360-table.png` | the Overview at 360 px with the latency table fitting its box |
| `48-overview-1280-table.png` | the same table at 1280 px after the fix |
| `50-after-restart.png` | the config page after the process restart, override still applied |
| `51-requests-filter.png` | the Requests prompt-size filter on `256 KiB and over` |
| `52-requests-360.png` | Requests at 360 px |

The harness itself is `cdp.mjs` plus `steps3/4/6/8.mjs` in the same folder.

## Not covered

- A real screen reader. The ring, the `aria-label` on each latency cell, `aria-describedby` on each
  switch and the dialog's `aria-labelledby`/`aria-describedby` were read from the DOM, not listened
  to.
- Safari and Firefox. Chrome 158 only.
- The container's viewport. This is a local process, not the podman unit, so a container restart is
  `a24g` plus the manual process restart above.
- Colour contrast at 360 px with a colour-blindness filter. The tokens are the ones reviewed earlier
  and were not changed.
