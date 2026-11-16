#!/bin/sh
# A2 — a dead socket costs one dial, not two.
#
# A2a conn_refused, A2b the 2 s connect deadline on a black hole, and A2c: the
# stub's own connection count proves a cooling leg is not dialled at all. A2c is
# added because A2a's dead port has no stub to count with.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

echo "=== A2a: connection refused, then the leg is skipped without a dial"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082; stub_kill leg-c 18083
expect_closed 18081 && pass "A2a preflight: leg-a's port refuses connections" \
  || fail "A2a preflight" "something listens on 18081"
stub leg-b 18082 ok
stub leg-c 18083 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-leg-c|"
gw_start
before=$(log_count)
req a2a-1 "$RUN/req-basic.json"
assert_eq      "A2a fallback answers"                     "$(http_code a2a-1)" "200"
assert_between "A2a whole failover inside 2 s"            "$(http_time a2a-1)" 0 2
assert_one_line "A2a" "$before"
assert_log_keys "A2a"
assert_log     "A2a route"                                '.route' 'leg-b'
assert_log     "A2a failover_from"                        '.failover_from' 'leg-a'
assert_log     "A2a failover_reason"                      '.failover_reason' 'conn_refused'
assert_log     "A2a status"                               '.status' '200'
assert_between "A2a latency_ms under the connect deadline" "$(lg '.latency_ms')" 0 2000

code=$(admin_json "$RUN/a2a.admin.json")
assert_eq      "A2a admin answers 200"                    "$code" "200"
assert_eq      "A2a exactly one leg is cooling"           "$(admin_count "$RUN/a2a.admin.json" cooling)" "1"
assert_eq      "A2a the cooling leg is leg-a"             "$(admin_cooling_keys "$RUN/a2a.admin.json")" '"leg-a"'
assert_eq      "A2a last_failure_class"                   "$(admin_field "$RUN/a2a.admin.json" leg-a last_failure_class)" 'conn_refused'
assert_between "A2a cooldown is 60 s from now" \
               "$(cooling_delta_s "$(admin_field "$RUN/a2a.admin.json" leg-a cooling_until)")" 55 65

mid=$(log_count)
req a2a-2 "$RUN/req-basic.json"
assert_eq      "A2a second request still answered"        "$(http_code a2a-2)" "200"
assert_one_line "A2a second request" "$mid"
assert_log     "A2a second request goes straight to leg-b" '.route' 'leg-b'
assert_log     "A2a second request reports no failover"    '.failover_from' ''
assert_log     "A2a second request reports no reason"      '.failover_reason' ''

echo
echo "=== A2b: the 2 s connect deadline on a black-hole address"
gw_stop
stub_kill leg-b 18082
stub leg-b 18082 ok
write_config "leg-a|http://192.0.2.1:9/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a2b "$RUN/req-basic.json"
assert_eq      "A2b fallback answers"                     "$(http_code a2b)" "200"
assert_one_line "A2b" "$before"
assert_log     "A2b failover_reason"                      '.failover_reason' 'dial_timeout'
assert_log     "A2b route"                                '.route' 'leg-b'
lo=$(( D2_CONNECT_MS - TOL_CONNECT_UNDER_MS ))
hi=$(( D2_CONNECT_MS + TOL_CONNECT_OVER_MS ))
assert_between "A2b decided at the 2 s connect deadline" "$(lg '.latency_ms')" "$lo" "$hi"
assert_between "A2b wall clock agrees" "$(awk -v t="$(http_time a2b)" 'BEGIN{printf "%d", t*1000}')" "$lo" "$hi"

echo
echo "=== A2c: a counting stub proves the cooled leg records no connection"
gw_stop; stub_kill leg-a 18085; stub_kill leg-b 18082; stub_kill leg-c 18083
stub leg-a 18085 401
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18085/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a2c-1 "$RUN/req-basic.json"
assert_eq "A2c the dead leg was dialled once"        "$(dials leg-a)" "1"
assert_log "A2c the first line names the failover"   '.failover_from' 'leg-a'
req a2c-2 "$RUN/req-basic.json"
req a2c-3 "$RUN/req-basic.json"
assert_eq "A2c three requests, three lines"          "$(($(log_count) - before))" "3"
assert_eq "A2c the cooling leg took no further dial" "$(dials leg-a)" "1"
assert_eq "A2c the live leg served the next two"     "$(route_count 2 leg-b)" "2"
assert_eq "A2c neither later line reports a failover" \
          "$(tail_jq 2 '[.[] | select(.failover_from != "")] | length')" "0"

gw_stop
kill_stubs
finish
