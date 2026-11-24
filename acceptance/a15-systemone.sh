#!/bin/sh
# A15 — the System One door of 0.7.0 (DEC-19), proven against a real binary.
#
# a  a decision is passed through: one field changed (the model id), the rest of
#    the caller's bytes intact, and the provider's answer back untouched.
# b  the same one-line log the chat door writes, with the token counts a System
#    One provider actually reports.
# c  a provider that does not take the model is a bad leg, not a caller error, so
#    the walk moves on and the reason is logged.
# d  a caller's own bad request reaches the caller unchanged, cools nothing and
#    fails over to nothing.
# e  a door nobody configured does not exist, and the door answers POST only.
# f  the cost of a priced decision lands in the same log key and the same total.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

# POST /v1/systemone, the same way `req` posts to the chat door.
req_so() { # req_so <name> <body-file>
  name=$1; body=$2
  curl -sS -D "$RUN/$name.head" -o "$RUN/$name.body" -w '%{http_code} %{time_total}' \
    --max-time 30 -X POST "$GW_URL/v1/systemone" \
    -H 'Content-Type: application/json' \
    -H 'Expect:' \
    -H "Authorization: Bearer $SENTINEL_CLIENT" \
    --data-binary "@$body" >"$RUN/$name.code" 2>"$RUN/$name.err" || true
  note "req_so $name http=$(cut -d' ' -f1 "$RUN/$name.code")"
}

# The MausBot-shaped request: state, model, questions keyed by question id, with
# criteria as a record. The model is a name MausBot might send; the leg's model
# must replace it.
cat >"$RUN/so-req.json" <<'JSON'
{"state":"Fredi asks: who should answer this message?","model":"jev-latest",
 "questions":{"who":{"type":"choice","instructions":"Pick the bot whose job fits.",
   "criteria":{"Bagas":"lead","Fikri":"backend","Wulan":"docs"},
   "question":"who answers"}}}
JSON

# Two System One legs, then patched in: write_config only knows chat legs.
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
patch_systemone() { # patch_systemone <model-a> <model-b>
  python3 - "$GW_CFG" "$1" "$2" <<'PY'
import json, sys
path, model_a, model_b = sys.argv[1:4]
cfg = json.load(open(path))
port_a = cfg["legs"][0]["base_url"].split(":")[2].split("/")[0]
port_b = cfg["legs"][1]["base_url"].split(":")[2].split("/")[0]
cfg["systemone"] = {"legs": [
    {"name": "jev-a", "base_url": "http://127.0.0.1:%s/provider/v1" % port_a,
     "api_key": "jev-key-a", "model": model_a},
    {"name": "jev-b", "base_url": "http://127.0.0.1:%s/provider/v1" % port_b,
     "api_key": "jev-key-b", "model": model_b},
]}
json.dump(cfg, open(path, "w"), indent=2)
PY
}

echo
echo "=== A15a: a decision is passed through with one field changed"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 systemone-ok --model typesafe/jev-1.14.0
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
patch_systemone typesafe/jev-1.14.0 typesafe/jev-1.14.0
gw_start
req_so a15a "$RUN/so-req.json"
assert_eq "A15a the decision answered" "$(http_code a15a)" "200"
assert_eq "A15a the answer came back untouched" \
  "$(jq -r '.answers.who.choice' "$RUN/a15a.body")" "Bagas"
assert_eq "A15a the provider's own usage shape survived" \
  "$(jq -r '.usage.input_tokens' "$RUN/a15a.body")" "322"

# The capture is the request the gateway actually sent: the path this door uses,
# the configured model id, and the caller's other bytes still there. The caller's
# body is forwarded verbatim, so the proof that only `model` changed is a byte
# comparison against the original with that one value swapped.
assert_present "A15a the upstream path is /systemone" \
  "$RUN/leg-a.req" "POST /provider/v1/systemone HTTP/1.1"
assert_present "A15a the leg's model id replaced the caller's" \
  "$RUN/leg-a.req" '"model":"typesafe/jev-1.14.0"'
assert_absent "A15a the caller's model name did not leak upstream" \
  "$RUN/leg-a.req" "jev-latest"
assert_present "A15a the caller's state reached the provider" \
  "$RUN/leg-a.req" '"state":"Fredi asks: who should answer this message?"'
assert_present "A15a the caller's questions reached the provider" \
  "$RUN/leg-a.req" '"criteria":{"Bagas":"lead"'
assert_present "A15a the leg's own credential was the bearer" \
  "$RUN/leg-a.req" "Authorization: Bearer jev-key-a"
assert_eq "A15a the chat walk was never involved" "$(dials leg-b)" "0"

# Byte identity: everything the caller sent, minus the header block and the one
# value kori owns, is what the leg received.
python3 - "$RUN/so-req.json" "$RUN/leg-a.req" <<'PY' >"$RUN/a15a-same"
import sys
caller = open(sys.argv[1], "rb").read()
sent = open(sys.argv[2], "rb").read()
body = sent.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in sent else sent
expected = caller.replace(b'"model":"jev-latest"',
                          b'"model":"typesafe/jev-1.14.0"')
print("same" if body == expected else "different")
PY
assert_eq "A15a every other byte the caller sent reached the leg" \
  "$(cat "$RUN/a15a-same")" "same"

echo
echo "=== A15b: the request log carries the same eleven-key row"
assert_eq "A15b the row names the System One leg" "$(lg '.route')" "jev-a"
assert_eq "A15b the row carries the provider's input tokens" "$(lg '.tokens_in')" "322"
assert_eq "A15b the row carries the provider's output tokens" "$(lg '.tokens_out')" "43"
assert_eq "A15b a decision is never a stream" "$(lg '.stream')" "false"
assert_eq "A15b no failover on a served decision" "$(lg '.failover_from')" ""
assert_eq "A15b a one-line answer keeps the nine keys when unpriced" \
  "$(log_line | jq -c 'keys_unsorted | join(",")')" \
  '"ts,route,status,latency_ms,tokens_in,tokens_out,failover_from,failover_reason,stream"'
assert_eq "A15b the door is counted in /metrics" \
  "$(curl -sS --max-time 5 -H "$(admin_token_header)" "$GW_URL/metrics" \
     | awk '/^kori_requests_total\{route="jev-a"\}/ {print $2}')" \
  "1"

echo
echo "=== A15c: a provider that refuses the model is a bad leg, not a bad caller"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 systemone-unsupported
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
patch_systemone typesafe/jev-1.14.0 typesafe/jev-1.14.0
gw_start
req_so a15c "$RUN/so-req.json"
assert_eq "A15c the second leg served it" "$(http_code a15c)" "200"
assert_eq "A15c the log names the leg that failed" "$(lg '.failover_from')" "jev-a"
assert_eq "A15c the log names it as a dead model" "$(lg '.failover_reason')" "model_gone"
assert_eq "A15c the answering leg is the one that worked" "$(lg '.route')" "jev-b"
assert_eq "A15c the bad leg was dialled once" "$(dials leg-a)" "1"
admin_get "$RUN/a15-state.json" '/admin/state' >/dev/null
assert_eq "A15c the bad leg is cooling, not merely failed" \
  "$(jq -r '[.. | objects | select(.name=="jev-a") | .state] | .[0]' "$RUN/a15-state.json")" \
  "cooling"

echo
echo "=== A15d: a caller's own bad request is returned unchanged"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 systemone-invalid
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
patch_systemone typesafe/jev-1.14.0 typesafe/jev-1.14.0
gw_start
req_so a15d "$RUN/so-req.json"
assert_eq "A15d the caller's 400 is the caller's" "$(http_code a15d)" "400"
assert_eq "A15d the provider's own message reached the caller" \
  "$(jq -r '.error.param' "$RUN/a15d.body")" "questions.q.criteria"
assert_eq "A15d nothing failed over" "$(dials leg-b)" "0"
assert_eq "A15d the row carries no failover reason" "$(lg '.failover_reason')" ""
assert_eq "A15d the caller error cooled no leg" "$(admin_get "$RUN/a15d-cfg.json" '/admin/config' >/dev/null; jq -r '[.systemone[].enabled] | length' "$RUN/a15d-cfg.json")" "2"

echo
echo "=== A15e: the door exists only when the config declares it"
gw_stop
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
del cfg["systemone"]
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
assert_eq "A15e a config without the block answers 404" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
      -H 'Content-Type: application/json' -H 'Content-Length: 2' \
      --data-binary '{}' "$GW_URL/v1/systemone")" "404"
patch_systemone typesafe/jev-1.14.0 typesafe/jev-1.14.0
gw_restart
assert_eq "A15e a GET on the door is refused" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$GW_URL/v1/systemone")" "405"
# RFC 9110 §15.5.6: a 405 names the methods it does answer. This used to assert an
# empty Allow, which pinned the bug the five inlined refusals carried until 0.10.0.
assert_eq "A15e the refusal names POST only" \
  "$(curl -sS -o /dev/null -D - --max-time 5 "$GW_URL/v1/systemone" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="allow:" {print $2}')" "POST"

echo
echo "=== A15f: a priced decision lands in cost_usd and the window total"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 systemone-ok --model typesafe/jev-1.14.0
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
patch_systemone typesafe/jev-1.14.0 typesafe/jev-1.14.0
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
# 322 in at $1.00/Mtok and 43 out at $2.00/Mtok = 0.000322 + 0.000086.
cfg["prices"] = {"typesafe/jev-1.14.0": {"in": 1.0, "out": 2.0}}
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
req_so a15f "$RUN/so-req.json"
assert_eq "A15f the priced decision answered" "$(http_code a15f)" "200"
assert_eq "A15f cost_usd is price x reported tokens" "$(lg '.cost_usd')" "0.000408"
assert_eq "A15f cost_usd is still the last key" \
  "$(log_line | jq -c 'keys_unsorted | last')" '"cost_usd"'
assert_eq "A15f the window total carries it" \
  "$(admin_get "$RUN/a15f-state.json" '/admin/state' >/dev/null; \
     jq -r '.window.cost_usd' "$RUN/a15f-state.json")" "0.000408"

kill_stubs
finish
