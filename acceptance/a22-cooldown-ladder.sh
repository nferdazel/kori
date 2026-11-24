#!/bin/sh
# A22 — DEC-23: a header timeout is a blink, not a death, and a probe never costs
# more than the cooldown it waited out.
#
# A22a one 15 s streaming header timeout cools the leg for about 15 s, not 60, and
#      the walk still serves the caller from the fallback.
# A22b once that cooldown is really over the leg is dialled again and serves, so
#      the second request never walks. That is the fact the old flat 60 s skip
#      broke: on qouver1 90 of 99 instant 502s fell inside a cooldown a single
#      timeout started.
# A22c the first rung is never shorter than the header window it just paid: the
#      non-stream door waits 90 s, so its rung is the 60 s cap, not 15 s. A rung
#      under the window would schedule a probe dearer than the cooldown it ends,
#      which is the regression a3c and the System One door would have paid.
#
# Runtime about 130 s, and 105 of them are the two header deadlines themselves.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

# Laras R-2: waiting on the server's own clock instead of a fixed sleep. The sleep
# was never flaky, but it asserts the wrong thing: what matters is that the leg is
# eligible again, not that six seconds passed. Polls /admin/state until the named
# leg stops reporting `cooling`, or gives up and lets the assertion below say so.
wait_not_cooling() { # wait_not_cooling <leg-name> [tries]
  _n=0
  while [ "$_n" -lt "${2:-40}" ]; do
    admin_json "$RUN/wait.admin.json" >/dev/null 2>&1 || true
    if [ "$(admin_count "$RUN/wait.admin.json" cooling)" = "0" ]; then
      return 0
    fi
    _n=$((_n + 1))
    sleep 0.5
  done
  return 1
}

echo "=== A22a: one header timeout, then the first rung instead of 60 s"
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
# The streaming door's window is 15 s, so that is the first rung: above the floor,
# below the cap, and never shorter than the wait the probe would have to pay.
assert_between "A22a the first rung is the 15 s window, not 60 and not 5" \
               "$(cooling_delta_s "$(admin_field "$RUN/a22a.admin.json" leg-a cooling_until)")" 13 17

echo
echo "=== A22b: once that rung is over the leg is dialled again, not skipped"
# The slow stub is replaced by a healthy one on the same port, so a second
# request that still walks would prove the leg was skipped, not that it was slow.
stub_kill leg-a-hdr 18088
stub leg-a-hdr 18088 stream-ok
stub_touch leg-a-hdr
wait_not_cooling leg-a || fail "A22b wait" "leg-a still cooling after 20 s"
mid=$(log_count)
req a22b "$RUN/req-stream.json"
assert_eq      "A22b the caller is served by the recovered leg" "$(http_code a22b)" "200"
assert_one_line "A22b" "$mid"
assert_log     "A22b the route is leg-a again"          '.route' 'leg-a'
assert_log     "A22b no failover on the second request"  '.failover_reason' ''
assert_eq      "A22b the leg was dialled once, not zero times" "$(dials leg-a-hdr)" "1"

echo
echo "=== A22c: the non-stream door keeps the 60 s rung, because its window is 90 s"
# This is the case Laras R-1 asked for. A 5 s or 15 s rung on a door whose header
# window is 90 s would send a probe every few seconds and charge a caller 90 s of
# stall each time. The rung must therefore be the old 60 s cap.
gw_stop; stub_kill leg-a-hdr 18087; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a-hdr 18087 never --ttl 300
write_config "leg-a|http://127.0.0.1:18087/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a22c "$RUN/req-basic.json"
assert_eq      "A22c the fallback answers after the 90 s window" "$(http_code a22c)" "200"
assert_one_line "A22c" "$before"
assert_log     "A22c the reason is the header timeout"  '.failover_reason' 'header_timeout'
admin_json "$RUN/a22c.admin.json" >/dev/null
assert_eq      "A22c the non-stream leg is cooling"     "$(admin_count "$RUN/a22c.admin.json" cooling)" "1"
assert_between "A22c its rung is the 60 s cap, never shorter than the 90 s window" \
               "$(cooling_delta_s "$(admin_field "$RUN/a22c.admin.json" leg-a cooling_until)")" 58 60

gw_stop
kill_stubs
finish
