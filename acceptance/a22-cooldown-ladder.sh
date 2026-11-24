#!/bin/sh
# A22 — DEC-23: a header timeout is a blink, not a death.
#
# A22a one 15 s header timeout cools the leg for about 5 s, not 60, and the walk
#      still serves the caller from the fallback.
# A22b once those 5 s pass the leg is dialled again and serves, so the second
#      request never walks. That is the fact the old flat 60 s skip broke: on
#      qouver1 90 of 99 instant 502s fell inside a cooldown a single timeout
#      started.
#
# Runtime about 30 s, and 15 of them are the header deadline itself.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"

echo "=== A22a: one header timeout, then a 5 s cooldown"
gw_stop; stub_kill leg-a-hdr 18088; stub_kill leg-b 18082
stub leg-b 18082 stream-ok
stub leg-a-hdr 18088 stream-ok --delay-headers 17
write_config "leg-a|http://127.0.0.1:18088/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a22a "$RUN/req-stream.json"
assert_eq      "A22a fallback answers"                  "$(http_code a22a)" "200"
assert_one_line "A22a" "$before"
assert_log     "A22a failover_reason"                   '.failover_reason' 'header_timeout'
assert_log     "A22a route"                             '.route' 'leg-b'

code=$(admin_json "$RUN/a22a.admin.json")
assert_eq      "A22a admin answers 200"                 "$code" "200"
assert_eq      "A22a the timed-out leg is cooling"      "$(admin_cooling_keys "$RUN/a22a.admin.json")" '"leg-a"'
assert_between "A22a the cooldown is the 5 s rung, not 60" \
               "$(cooling_delta_s "$(admin_field "$RUN/a22a.admin.json" leg-a cooling_until)")" 3 8

echo
echo "=== A22b: after that 5 s the leg is dialled again, not skipped for a minute"
sleep 6
# The slow stub is replaced by a healthy one on the same port, so a second
# request that still walks would prove the leg was skipped, not that it was slow.
stub_kill leg-a-hdr 18088
stub leg-a-hdr 18088 stream-ok
stub_touch leg-a-hdr
mid=$(log_count)
req a22b "$RUN/req-stream.json"
assert_eq      "A22b the caller is served by the recovered leg" "$(http_code a22b)" "200"
assert_one_line "A22b" "$mid"
assert_log     "A22b the route is leg-a again"          '.route' 'leg-a'
assert_log     "A22b no failover on the second request"  '.failover_reason' ''
assert_eq      "A22b the leg was dialled once, not zero times" "$(dials leg-a-hdr)" "1"
admin_json "$RUN/a22b.admin.json" >/dev/null
assert_eq      "A22b the cooldown is cleared by the answer" \
               "$(admin_count "$RUN/a22b.admin.json" cooling)" "0"

gw_stop
kill_stubs
finish
