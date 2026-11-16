#!/bin/sh
# A1 — an availability failure falls over, and the log says which leg died.
#
# Assertions are ACCEPTANCE-v1.md A1 verbatim, with two changes, both reported:
#  1. each sub-case starts on a fresh gateway. A1's block shares one gateway
#     across a1a/a1b/a1c, but SPEC §3.1 cools the failed leg for 60 s, so a1b
#     would skip leg-a and could never log `failover_from = leg-a`.
#  2. local variables are prefixed because lib.sh's own helpers assign `label`,
#     `name` and `mode` in the caller's scope.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

for spec in "a1a 401 auth_401" "a1b missing-session missing_session_id" "a1c 502 upstream_5xx"; do
  set -- $spec
  case_label=$1 case_mode=$2 case_reason=$3
  gw_stop
  stub_kill leg-a 18081
  stub_kill leg-b 18082
  stub_kill leg-c 18083
  stub leg-a 18081 "$case_mode"
  stub leg-b 18082 ok
  stub leg-c 18083 ok
  write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|x-opencode-session:$SENTINEL_LEG" \
               "leg-b|http://127.0.0.1:18082/v1|key-leg-b|" \
               "leg-c|http://127.0.0.1:18083/v1|key-leg-c|"
  gw_start
  before=$(log_count)
  req "$case_label" "$RUN/req-basic.json"
  assert_eq      "$case_label http 200 from the fallback"        "$(http_code "$case_label")" "200"
  assert_between "$case_label answered inside the failover window" "$(http_time "$case_label")" 0 2
  assert_one_line "$case_label" "$before"
  assert_log_keys "$case_label"
  assert_ts      "$case_label"
  assert_log     "$case_label route is the leg that answered"     '.route' 'leg-b'
  assert_log     "$case_label failover_from is the leg abandoned" '.failover_from' 'leg-a'
  assert_log     "$case_label failover_reason"                    '.failover_reason' "$case_reason"
  assert_log     "$case_label status"                             '.status' '200'
  assert_log     "$case_label tokens_in read from the provider"   '.tokens_in' '11'
  assert_log     "$case_label tokens_out read from the provider"  '.tokens_out' '7'
  assert_log     "$case_label stream"                             '.stream' 'false'
  assert_eq      "$case_label body is the fallback answer" \
                 "$(jq -r '.choices[0].message.content' "$RUN/$case_label.body")" 'STUB-OK'
done

assert_present "the per-leg header reached the leg" "$RUN/leg-a.req" "x-opencode-session: $SENTINEL_LEG"
assert_absent  "client key never in the log"        "$GW_LOG" "$SENTINEL_CLIENT"
assert_absent  "leg session never in the log"       "$GW_LOG" "$SENTINEL_LEG"
assert_absent  "prompt body never in the log"       "$GW_LOG" "$SENTINEL_PROMPT"
assert_absent  "header name Authorization never in the log"      "$GW_LOG" 'Authorization'
assert_absent  "header name x-opencode-session never in the log" "$GW_LOG" 'x-opencode-session'

gw_stop
stub leg-a 18081 ok
gw_start
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
  "$GW_URL/v1/chat/completions" -H 'Content-Type: application/json' \
  --data-binary "@$RUN/req-basic.json")
assert_eq "a request with no key at all is served (D5)" "$code" "200"

gw_stop
kill_stubs
finish
