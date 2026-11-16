#!/bin/sh
# A4 — a quota 429 is a different failure, with a longer cooldown.
# A4a quota_429 fails over with a 900 s cooldown and the capacity counter;
# A4b a 429 without a quota body is the caller's problem and never fails over.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

echo "=== A4a: 429 with a quota body"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082; stub_kill leg-c 18083
stub leg-a 18081 429-quota
stub leg-b 18082 ok
stub leg-c 18083 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-leg-c|"
gw_start
admin_json "$RUN/a4-before.json" >/dev/null
before=$(log_count)
req a4a "$RUN/req-basic.json"
assert_eq      "A4a fallback answers"                     "$(http_code a4a)" "200"
assert_one_line "A4a" "$before"
assert_log_keys "A4a"
assert_log     "A4a route"                                '.route' 'leg-b'
assert_log     "A4a failover_from"                        '.failover_from' 'leg-a'
assert_log     "A4a failover_reason is the capacity one"  '.failover_reason' 'quota_429'
assert_log     "A4a status"                               '.status' '200'
assert_eq      "A4a body is the fallback answer" \
               "$(jq -r '.choices[0].message.content' "$RUN/a4a.body")" 'STUB-OK'

code=$(admin_json "$RUN/a4.admin.json")
assert_eq      "A4a admin answers 200"                    "$code" "200"
assert_eq      "A4a the cooling leg is leg-a"             "$(admin_cooling_keys "$RUN/a4.admin.json")" '"leg-a"'
assert_between "A4a quota cooldown is 900 s, not 60" \
               "$(cooling_delta_s "$(admin_field "$RUN/a4.admin.json" leg-a cooling_until)")" 895 905
assert_eq      "A4a the capacity counter moved by one" \
               "$(window_delta "$RUN/a4-before.json" "$RUN/a4.admin.json" capac)" "1"
assert_eq      "A4a the availability counter did not move" \
               "$(window_delta "$RUN/a4-before.json" "$RUN/a4.admin.json" avail)" "0"
assert_eq      "A4a one event in the window list" \
               "$(window_events "$RUN/a4.admin.json" | jq 'length')" "1"
assert_eq      "A4a that event names the reason and the leg" \
               "$(window_events "$RUN/a4.admin.json" | jq -r '.[0] | "\(.from_route) \(.reason)"')" \
               "leg-a quota_429"
assert_eq      "A4a last_failure_class is the capacity token" \
               "$(admin_field "$RUN/a4.admin.json" leg-a last_failure_class)" 'quota_429'

echo
echo "=== A4b: 429 without a quota body is a client error"
gw_stop; stub_kill leg-a 18081
stub leg-a 18081 raw --status 429 --body-file "$ACC_DIR/fixtures/error-429-no-quota-body.json"
stub_touch leg-b
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-leg-c|"
gw_start
before=$(log_count)
req a4b "$RUN/req-basic.json"
assert_eq      "A4b the caller sees the leg's 429"        "$(http_code a4b)" "429"
assert_cmp     "A4b the 429 body is passed through unchanged" \
               "$RUN/a4b.body" "$ACC_DIR/fixtures/error-429-no-quota-body.json"
assert_eq      "A4b the fallback was never dialled"       "$(dials leg-b)" "0"
assert_one_line "A4b" "$before"
assert_log     "A4b route is the leg that answered"       '.route' 'leg-a'
assert_log     "A4b status"                               '.status' '429'
assert_log     "A4b failover_from"                        '.failover_from' ''
assert_log     "A4b failover_reason"                      '.failover_reason' ''
admin_json "$RUN/a4b.admin.json" >/dev/null
assert_eq      "A4b no leg is cooling afterwards"         "$(admin_count "$RUN/a4b.admin.json" cooling)" "0"

gw_stop
kill_stubs
finish
