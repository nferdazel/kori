#!/bin/sh
# A13 — the six parity items of 0.6.2, each proven against a real binary.
#
# P0: `GET /v1/models` derives the caller-visible model list from the config.
# P0: `retries` dials a leg again before failover burns it into a cooldown.
# P1: a key pool rotates on a dead key instead of losing the leg.
# P1: `model_gone` / `caller_fault` are named instead of swallowed.
# P1: `weight > 1` splits the pick by DEC-11.
# P1: `/healthz?deep` reports per-leg state without dialling anything.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"

echo
echo "=== A13a: GET /v1/models is derived from the config and needs no leg"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1|prov-a" \
             "leg-b|http://127.0.0.1:18082/v1|key-b||fallback|1|prov-b"
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["legs"][0]["aliases"] = {"fast": "prov-a-fast"}
cfg["legs"][1]["aliases"] = {"fast": "prov-b-fast", "deep": "prov-b-deep"}
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
stub_touch leg-a; stub_touch leg-b
assert_eq "A13a /v1/models answers 200" "$(admin_code '/v1/models')" "200"
assert_eq "A13a the fallback was never dialled" "$(dials leg-b)" "0"
assert_eq "A13a the primary was never dialled" "$(dials leg-a)" "0"
admin_get "$RUN/a13-models.json" '/v1/models' >/dev/null
assert_eq "A13a the body is an OpenAI list object" \
  "$(jq -r '.object' "$RUN/a13-models.json")" "list"
assert_eq "A13a each alias is listed once, prefixed" \
  "$(jq -r '[.data[].id | select(startswith("kori/"))] | sort | join(",")' \
     "$RUN/a13-models.json")" "kori/deep,kori/fast"
assert_eq "A13a each named leg model is listed" \
  "$(jq -r '[.data[].id | select(startswith("prov-")) | select(startswith("prov-a-") | not) | select(startswith("prov-b-") | not)] | sort | join(",")' \
     "$RUN/a13-models.json")" "prov-a,prov-b"
assert_eq "A13a a POST to /v1/models is refused" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
      -H 'Content-Length: 0' "$GW_URL/v1/models")" "405"
# RFC 9110 §15.5.6: the refusal names the method the surface answers. Before
# 0.10.0 this one carried no Allow header at all. `GET, HEAD` is the spelling
# handleStatic already uses for a surface that answers both.
assert_eq "A13a and it names GET, HEAD" \
  "$(curl -sS -o /dev/null -D - --max-time 5 -X POST \
      -H 'Content-Length: 0' "$GW_URL/v1/models" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="allow:" {$1=""; sub(/^ /,""); print}')" \
  "GET, HEAD"

echo
echo "=== A13b: retries dial the same leg again and never a caller error"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 503-then-ok --after 1
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|||||2" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
gw_start
before=$(log_count)
req a13b "$RUN/req-basic.json"
assert_eq      "A13b the retried leg answered"        "$(http_code a13b)" "200"
assert_eq      "A13b the leg was dialled twice"       "$(dials leg-a)" "2"
assert_eq      "A13b the fallback was never dialled"  "$(dials leg-b)" "0"
assert_one_line "A13b" "$before"
assert_log     "A13b route is the primary"            '.route' 'leg-a'
assert_log     "A13b a retry is not a failover"       '.failover_from' ''
assert_log     "A13b no failover reason"              '.failover_reason' ''

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 401
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|||||3" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
gw_start
before=$(log_count)
req a13b401 "$RUN/req-basic.json"
assert_eq      "A13b a 401 is not retried on the same leg" "$(dials leg-a)" "1"
assert_eq      "A13b it fails over instead"                "$(http_code a13b401)" "200"
assert_eq      "A13b the fallback answered"                "$(lg '.route')" "leg-b"
assert_one_line "A13b401" "$before"

echo
echo "=== A13c: a key pool rotates on a dead key and keeps the leg"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok --expect-bearer good-key
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|||primary|1||1|dead-key,good-key" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
gw_start
before=$(log_count)
req a13c "$RUN/req-basic.json"
assert_eq      "A13c the leg answered on its second key" "$(http_code a13c)" "200"
assert_eq      "A13c the leg was dialled twice"          "$(dials leg-a)" "2"
assert_eq      "A13c the fallback was never dialled"     "$(dials leg-b)" "0"
assert_eq      "A13c the route is the pooled leg"        "$(lg '.route')" "leg-a"
assert_one_line "A13c" "$before"
admin_get "$RUN/a13-keys.json" '/admin/config' >/dev/null
assert_eq      "A13c the pool size is reported"          "$(jq -r '.legs[0].keys' "$RUN/a13-keys.json")" "2"
assert_eq      "A13c one key is cooling"                 "$(jq -r '.legs[0].keys_cooling' "$RUN/a13-keys.json")" "1"
assert_absent  "A13c no key value reaches /admin/config" "$RUN/a13-keys.json" "dead-key"
assert_absent  "A13c no key value reaches the log"       "$GW_LOG" "dead-key"

echo
echo "=== A13d: model_gone names a dead model, a caller id keeps its 404"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 raw --status 404 --body-file "$ACC_DIR/fixtures/error-400-model-not-found.json"
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1|prov-a-gone" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["legs"][0]["aliases"] = {"fast": "prov-a-gone"}
cfg["legs"][1]["aliases"] = {"fast": "stub-model"}
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
printf '%s' '{"model":"kori/fast","messages":[{"role":"user","content":"hi"}]}' >"$RUN/a13-alias.json"
before=$(log_count)
req a13d "$RUN/a13-alias.json"
assert_eq "A13d a mapped alias that lost its model fails over" "$(http_code a13d)" "200"
assert_eq "A13d the fallback answered"                          "$(lg '.route')" "leg-b"
assert_eq "A13d the reason is model_gone"                       "$(lg '.failover_reason')" "model_gone"
assert_one_line "A13d" "$before"

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 raw --status 404 --body-file "$ACC_DIR/fixtures/error-400-model-not-found.json"
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
gw_start
stub_touch leg-b
before=$(log_count)
req a13d-own "$RUN/req-basic.json"
assert_eq "A13d a caller's own id keeps its 404"          "$(http_code a13d-own)" "404"
assert_eq "A13d the fallback was never dialled"           "$(dials leg-b)" "0"
assert_eq "A13d the log names no failover"                "$(lg '.failover_reason')" ""
assert_one_line "A13d-own" "$before"

echo
echo "=== A13e: weight > 1 splits the pick, and equal weights stay even"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok
stub leg-b 18082 ok
GW_BALANCE=true write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|3" \
                             "leg-b|http://127.0.0.1:18082/v1|key-b||primary|1"
gw_start
for n in 1 2 3 4 5 6 7 8; do req "a13e-$n" "$RUN/req-basic.json"; done
served_a=$(route_count 8 leg-a)
served_b=$(route_count 8 leg-b)
assert_eq "A13e eight picks over a 3:1 split serve six on the heavy leg" "$served_a" "6"
assert_eq "A13e eight picks over a 3:1 split serve two on the light leg" "$served_b" "2"

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok
stub leg-b 18082 ok
GW_BALANCE=true write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1" \
                             "leg-b|http://127.0.0.1:18082/v1|key-b||primary|1"
gw_start
for n in 1 2 3 4 5 6; do req "a13e-even-$n" "$RUN/req-basic.json"; done
assert_eq "A13e equal weights split evenly" "$(route_count 6 leg-a)" "3"
assert_eq "A13e equal weights split evenly on the other side" "$(route_count 6 leg-b)" "3"

echo
echo "=== A13f: /healthz?deep reports per-leg state and dials nothing"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 503
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
gw_start
req a13f "$RUN/req-basic.json"
assert_eq "A13f the walk served from the fallback" "$(lg '.route')" "leg-b"
stub_touch leg-a; stub_touch leg-b
admin_get "$RUN/a13-deep.json" '/healthz?deep' >/dev/null
assert_eq "A13f deep health answers ok"          "$(jq -r '.status' "$RUN/a13-deep.json")" "ok"
assert_eq "A13f both legs are reported"          "$(jq -r '.legs | length' "$RUN/a13-deep.json")" "2"
assert_eq "A13f the failed leg reads as cooling" \
  "$(jq -r '.legs[] | select(.name=="leg-a") | .state' "$RUN/a13-deep.json")" "cooling"
assert_eq "A13f the failed leg names its class" \
  "$(jq -r '.legs[] | select(.name=="leg-a") | .last_failure_class' "$RUN/a13-deep.json")" "upstream_5xx"
assert_eq "A13f the serving leg reads as ok" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .state' "$RUN/a13-deep.json")" "ok"
assert_eq "A13f the serving leg has a last success" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | (.last_success_at != null)' "$RUN/a13-deep.json")" "true"
assert_eq "A13f deep health dialled neither leg" "$(dials leg-a)" "0"
assert_eq "A13f deep health dialled no fallback"  "$(dials leg-b)" "0"
assert_eq "A13f shallow health keeps its shape" \
  "$(admin_get "$RUN/a13-shallow.json" '/healthz' >/dev/null; jq -r 'has("legs")' "$RUN/a13-shallow.json")" "false"

gw_stop
kill_stubs
finish
