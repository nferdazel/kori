#!/bin/sh
# A9 — all three legs dead is one 502, and the log keeps both ends of the chain.
# leg-a 401, leg-b 503, leg-c a closed port, so the first reason and the last
# reason are different tokens.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082; stub_kill leg-c 18083
stub leg-a 18081 401
stub leg-b 18082 503
expect_closed 18083 && pass "A9 preflight: leg-c's port refuses connections" \
  || fail "A9 preflight" "something listens on 18083"
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-leg-c|"
gw_start
admin_json "$RUN/a9-before.json" >/dev/null
before=$(log_count)

req a9 "$RUN/req-basic.json"
assert_eq      "A9 the caller gets 502, whatever the legs returned" "$(http_code a9)" "502"
assert_eq      "A9 the body type is all_legs_failed"      "$(jq -r '.error.type' "$RUN/a9.body")" "all_legs_failed"
assert_eq      "A9 the body carries the last reason token" \
               "$(jq -r '.error.message' "$RUN/a9.body")" "conn_refused"
assert_eq      "A9 the body carries no choices, it is not a fake answer" \
               "$(jq -r 'has("choices")' "$RUN/a9.body")" "false"

assert_one_line "A9" "$before"
assert_log_keys "A9"
assert_ts      "A9"
assert_log     "A9 route is the last leg tried"           '.route' 'leg-c'
assert_log     "A9 status is 502"                         '.status' '502'
assert_log     "A9 failover_from is the first leg abandoned" '.failover_from' 'leg-a'
assert_log     "A9 failover_reason is the first reason"   '.failover_reason' 'auth_401'
assert_log     "A9 stream"                                '.stream' 'false'
assert_log_null "A9 tokens_in is null"                    '.tokens_in'
assert_log_null "A9 tokens_out is null"                   '.tokens_out'

admin_json "$RUN/a9-after.json" >/dev/null
assert_eq      "A9 availability counter moved by one"     "$(window_delta "$RUN/a9-before.json" "$RUN/a9-after.json" avail)" "1"
assert_eq      "A9 capacity counter did not move"         "$(window_delta "$RUN/a9-before.json" "$RUN/a9-after.json" capac)" "0"
assert_between "A9 one request makes one to three window events, never twenty" \
               "$(window_events "$RUN/a9-after.json" | jq 'length')" 1 3
assert_eq      "A9 the first reason appears once in the window list" \
               "$(window_event_hits "$RUN/a9-after.json" auth_401)" "1"
assert_eq      "A9 all three legs are cooling afterwards" "$(admin_count "$RUN/a9-after.json" cooling)" "3"

gw_stop
kill_stubs
finish
