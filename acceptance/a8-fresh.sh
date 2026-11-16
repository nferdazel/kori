#!/bin/sh
# A8 — a fresh start knows nothing about any leg (ACCEPTANCE-v1.md A8).
# Assertions are the acceptance block verbatim.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

stub leg-a 18091 401
stub leg-b 18092 ok
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18092/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18093/v1|key-leg-c|"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
gw_start

echo "=== A8a: fresh start"
code=$(admin_json "$RUN/a8-fresh.json")
assert_eq "A8a admin answers 200"                         "$code" "200"
assert_eq "A8a every configured leg is listed"            "$(admin_legs "$RUN/a8-fresh.json" | jq 'length')" "3"
assert_eq "A8a every leg is unknown"                      "$(admin_count "$RUN/a8-fresh.json" unknown)" "3"
assert_eq "A8a no leg is cooling"                         "$(admin_count "$RUN/a8-fresh.json" cooling)" "0"
assert_eq "A8a cooling_until is null everywhere" \
  "$(admin_legs "$RUN/a8-fresh.json" | jq '[.[].o.cooling_until] | all(. == null)')" "true"
assert_eq "A8a last_failure_class is null everywhere" \
  "$(admin_legs "$RUN/a8-fresh.json" | jq '[.[].o.last_failure_class] | all(. == null)')" "true"

echo
echo "=== A8b: GET only"
assert_eq "A8b a POST is refused"  \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
       -H 'Content-Length: 0' "$GW_URL/admin/state")" "405"
assert_eq "A8b a GET is served"    "$(admin_json "$RUN/a8-get.json")" "200"

echo
echo "=== A8c: one real failover, then the state must say which leg and why"
req a8c "$RUN/req-basic.json"
assert_eq      "A8c the failover answered"               "$(http_code a8c)" "200"
assert_log_keys "A8c"
assert_ts      "A8c"
admin_json "$RUN/a8-cool.json" >/dev/null
assert_eq "A8c one leg is cooling"                        "$(admin_count "$RUN/a8-cool.json" cooling)" "1"
assert_eq "A8c the cooling leg is leg-a"                  "$(admin_cooling_keys "$RUN/a8-cool.json")" '"leg-a"'
assert_eq "A8c last_failure_class names the class"        "$(admin_field "$RUN/a8-cool.json" leg-a last_failure_class)" 'auth_401'
assert_between "A8c cooldown is 60 s from now" \
               "$(cooling_delta_s "$(admin_field "$RUN/a8-cool.json" leg-a cooling_until)")" 55 65

echo
echo "=== A8d: a restart forgets it, because nothing in v1 persists router state"
gw_restart
admin_json "$RUN/a8-restart.json" >/dev/null
assert_eq "A8d after a restart every leg is unknown"      "$(admin_count "$RUN/a8-restart.json" unknown)" "3"
assert_eq "A8d after a restart no leg is cooling"         "$(admin_count "$RUN/a8-restart.json" cooling)" "0"

kill_stubs
finish
