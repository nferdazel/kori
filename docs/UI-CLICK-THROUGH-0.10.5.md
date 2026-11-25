# UI click-through, 0.10.5 candidates

Date: 2026-11-25. Machine: this Mac, local binary `apps/api/src/kori` at `f2a0a06`.
Why: phases 5 and 7 of the plan were signed off on code trace and `pnpm build` alone. The owner asked for local
testing to be maximised, so this closes the click-through gap with a real browser against a real process.

Nothing here touched qouver1 and nothing was pushed.

## Setup

```
/tmp/kori-ui/config.json        two legs, both base_url http://127.0.0.1:9/v1, no traffic intended
/tmp/kori-ui/admin.token        "uitest-read-token"
/tmp/kori-ui/admin-write.token  "uitest-write-token"
KORI_ADMIN_TOKEN_FILE=/tmp/kori-ui/admin.token \
KORI_ADMIN_WRITE_TOKEN_FILE=/tmp/kori-ui/admin-write.token \
./apps/api/src/kori --config /tmp/kori-ui/config.json --port 8788 --log /tmp/kori-ui/requests.jsonl
```

Config starts with `leg-a` enabled and `leg-b` `enabled:false`, so the page has one checkbox on and one off.

## What was clicked, and what happened

| Step | Action | Observed |
|---|---|---|
| 1 | open `/login.html`, sign in with the write token | lands on Overview, sidebar footer reads `read + write` |
| 2 | `/config.html`, click `leg-b` (file says off) | `leg-b` becomes `OVERRIDE · file off · serving · override on · switched on from the dashboard`, with a `reset` button |
| 3 | click `leg-a` off | `leg-a` reads `file on · skipped · override off · switched off from the dashboard`; `leg-b` is the only serving leg |
| 4 | click `leg-b` off | `PUT /admin/overrides` answers **409**, and the page opens **"Turn off the last serving provider?"** with the sentence `This turns off the last serving provider. Requests will answer 503 until one is back on.` and buttons `Cancel` / `Turn it off anyway` |
| 5 | click `Turn it off anyway` | banner appears: `No provider is serving; every request answers 503.` Both checkboxes read `skipped` |
| 6 | `curl -X POST /v1/chat/completions` | `HTTP/1.1 503`, body `{"error":{"type":"no_leg_enabled","message":"every provider is switched off in the gateway"}}`, log row `route:""`, `failover_reason:"no_leg_enabled"`, `prompt_kib:0` |
| 7 | click `leg-a` back on | `file on · serving · override on`; the banner disappears; header write counter reads `4 dashboard writes` |

The apply needs no restart: the process log for that run is four lines of
`kori: admin overrides written, N leg(s), 0 model(s)` each followed by
`kori: SIGHUP reload applied, 2 leg(s), reload #1..#4`, one PID throughout.

## Scope and file effects, checked outside the UI

| Check | Result |
|---|---|
| `PUT /admin/overrides` with the read token | `403 write_scope_required` |
| same with no token | `401 unauthorized` |
| same with an unknown key (`api_key`) | `400 bad_request: overrides.api_key is not a known key` |
| `config.json` after the writes | `overrides` block with `legs`, `models`, `updated_at`; leg bytes untouched |
| `config.json.bak` | written, mode `0600`, previous bytes |
| restart the process, then `/admin/config` | `leg-a` `enabled:true override:true serving:true`, `leg-b` `enabled:false override:false serving:false` |

## Divergence found

`Authorization: Bearer <write token>` is rejected with `401` on `/admin/state`, `/admin/config` and `/admin/log`.
The write token works for reads only through the session cookie it mints at `/login.html`. The plan (§6.5) said
"Read endpoints with a write token: allowed", which holds for the session but not for the bearer form. Either the
plan line or the bearer path should change; this document records the behaviour as built, not a verdict.

## Not covered here

- 360 px single column and screen-reader output: no viewport or screen reader in this pass.
- Keyboard-only traversal past the dialog buttons.
- Model switches: the test config defines no aliases, so the Models block correctly renders
  `this config defines no model aliases`. The alias switch itself is covered by `a24b/c/g` on the server side only.
- Live cooldown path (`all_legs_cooling` with `Retry-After`): needs a dialling leg, covered by `a23`.

Screenshots of steps 2, 4, 5 and 7 are kept outside the repository at
`~/.openmausbot/workloop/items/kori/2026-11-25-perf-and-provider-toggle/screenshots/`.
