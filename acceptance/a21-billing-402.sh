#!/bin/sh
# A21 — a 402 from a leg is a dead route, not the caller's error.
# A provider that has run out of credit answers 402 with its own billing body.
# That leg must be cooled, the failover must be recorded, and when no leg can
# serve, the caller gets kori's 502 — never the provider's billing text.
# Regression for the sinarcloud incident, 2026-11-22.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

printf '{"error":{"message":"insufficient balance","type":"billing_error","code":"InsufficientBalance"}}\n' \
  >"$RUN/body-402.json"

echo "=== A21a: a 402 leg is abandoned, cooled, and the next leg serves"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a 18081 raw --status 402 --body-file "$RUN/body-402.json"
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
stub_touch leg-b
before=$(log_count)
admin_json "$RUN/a21a-before.json" >/dev/null

req a21a "$RUN/req-basic.json"
assert_eq      "A21a the healthy leg answers"            "$(http_code a21a)" "200"
assert_absent  "A21a the provider's billing text never reaches the caller" \
               "$RUN/a21a.body" "insufficient balance"
assert_eq      "A21a the dead leg was dialled first"     "$(dials leg-a)" "1"
assert_eq      "A21a and the live leg answered"          "$(dials leg-b)" "1"

assert_one_line "A21a" "$before"
assert_log_keys "A21a"
assert_ts      "A21a"
assert_log     "A21a route is the leg that answered"     '.route' 'leg-b'
assert_log     "A21a status is the served 200"           '.status' '200'
assert_log     "A21a failover_from is the dead leg"      '.failover_from' 'leg-a'
assert_log     "A21a failover_reason is billing_402"     '.failover_reason' 'billing_402'

admin_json "$RUN/a21a-after.json" >/dev/null
assert_eq      "A21a the 402 leg is cooling"             "$(admin_count "$RUN/a21a-after.json" cooling)" "1"
assert_eq      "A21a a billing failure moves the capacity counter" \
               "$(window_delta "$RUN/a21a-before.json" "$RUN/a21a-after.json" capac)" "1"
assert_eq      "A21a availability counter did not move" \
               "$(window_delta "$RUN/a21a-before.json" "$RUN/a21a-after.json" avail)" "0"

echo
echo "=== A21b: a second request inside the cooldown never dials the 402 leg"
stub_touch leg-a
before=$(log_count)
req a21b "$RUN/req-basic.json"
assert_eq      "A21b the healthy leg answers"            "$(http_code a21b)" "200"
assert_eq      "A21b the dead leg was not dialled again" "$(dials leg-a)" "0"
assert_one_line "A21b" "$before"
assert_log     "A21b route is the leg that answered"     '.route' 'leg-b'
assert_log     "A21b failover_reason is empty"           '.failover_reason' ''

echo
echo "=== A21c: every leg on 402 is one 502, and no billing text leaks"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 raw --status 402 --body-file "$RUN/body-402.json"
stub leg-a 18081 raw --status 402 --body-file "$RUN/body-402.json"
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a21c "$RUN/req-basic.json"
assert_eq      "A21c the caller gets 502 from kori, not a provider 402" \
               "$(http_code a21c)" "502"
assert_eq      "A21c the body type is all_legs_failed" \
               "$(jq -r '.error.type' "$RUN/a21c.body")" "all_legs_failed"
assert_eq      "A21c the body names the terminal reason" \
               "$(jq -r '.error.message' "$RUN/a21c.body")" "billing_402"
assert_eq      "A21c it carries no choices, it is not a fake answer" \
               "$(jq -r 'has("choices")' "$RUN/a21c.body")" "false"
assert_absent  "A21c the provider's billing text never reaches the caller" \
               "$RUN/a21c.body" "insufficient balance"
assert_one_line "A21c" "$before"
assert_log     "A21c status is 502"                      '.status' '502'
assert_log     "A21c failover_from is the first leg"     '.failover_from' 'leg-a'
assert_log     "A21c failover_reason is billing_402"     '.failover_reason' 'billing_402'
admin_json "$RUN/a21c-after.json" >/dev/null
assert_eq      "A21c both legs are cooling"              "$(admin_count "$RUN/a21c-after.json" cooling)" "2"

echo
echo "=== A21d: a quota 429 still cools as capacity, unchanged by this fix"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a 18081 429-quota
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a21d "$RUN/req-basic.json"
assert_eq      "A21d the healthy leg answers"            "$(http_code a21d)" "200"
assert_one_line "A21d" "$before"
assert_log     "A21d failover_reason is quota_429"       '.failover_reason' 'quota_429'

gw_stop
kill_stubs
finish
