#!/bin/sh
# A23 — DEC-26: when no leg can serve, the answer is honest.
#
# A23a one leg, a header timeout: the first request is a 502 (a leg was dialled and
#      failed), the next one is a 503 all_legs_cooling with Retry-After equal to
#      the remaining rung, no leg name in the body, and a log row with route "".
# A23b two legs cooling for different reasons: Retry-After is the earlier expiry,
#      and a quota 429 with its own Retry-After cools 60 s instead of 900 s.
# A23c a plain 429 is a rate limit: the walk moves to the next leg and serves, and
#      the failed leg cools for the Retry-After it named, not for 900 s.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"

# The deadlines are config now, so the case can make a header timeout happen in
# 300 ms instead of 15 s. Same code path, same arithmetic, shorter clock.
tune_deadlines() { # tune_deadlines <ms>
  python3 - "$GW_CFG" "$1" <<'PY'
import json, sys
path, base = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(path))
cfg["timeouts"] = {
    "header_ms_stream_base": base,
    "header_ms_stream_slope_per_kib": 0,
    "header_ms_stream_max": base,
    "header_ms_non_stream": base,
}
json.dump(cfg, open(path, "w"), indent=2)
PY
}

echo "=== A23a: one leg cooling, then an honest 503 with Retry-After"
gw_stop; stub_kill leg-a 18086; stub_kill leg-b 18082
stub leg-a 18086 never --ttl 10
write_config "leg-a|http://127.0.0.1:18086/v1|key-leg-a|"
tune_deadlines 300
gw_start
before=$(log_count)

req a23a1 "$RUN/req-stream.json"
assert_eq "A23a the first request is a 502: a leg was dialled and failed" \
          "$(http_code a23a1)" "502"
assert_eq "A23a the body names the terminal reason" \
          "$(jq -r '.error.message' "$RUN/a23a1.body")" "header_timeout"
assert_eq "A23a the type is all_legs_failed, not all_legs_cooling" \
          "$(jq -r '.error.type' "$RUN/a23a1.body")" "all_legs_failed"

before=$(log_count)
code=$(curl -sS -o "$RUN/a23a2.body" -D "$RUN/a23a2.head" -w '%{http_code}' \
  --max-time 5 -X POST -H 'Content-Type: application/json' \
  --data-binary @"$RUN/req-stream.json" "$GW_URL/v1/chat/completions")
assert_eq "A23a the second request is a 503, not a 502" "$code" "503"
assert_eq "A23a the type is all_legs_cooling" \
          "$(jq -r '.error.type' "$RUN/a23a2.body")" "all_legs_cooling"
assert_eq "A23a the body carries no leg name" \
          "$(jq -r '.error | has("legs") or has("route")' "$RUN/a23a2.body")" "false"
retry_header=$(gate_header "$RUN/a23a2.head" retry-after)
retry_body=$(jq -r '.error.retry_after_s' "$RUN/a23a2.body")
assert_between "A23a Retry-After is the remaining single-leg rung (5 s)" \
               "$retry_header" 1 6
assert_eq "A23a the header and the body agree" "$retry_body" "$retry_header"
assert_one_line "A23a" "$before"

assert_log "A23a the log names no leg"                '.route' ''
assert_log "A23a the log status is 503"               '.status' '503'
assert_log "A23a the reason is all_legs_cooling"      '.failover_reason' 'all_legs_cooling'
assert_log "A23a legs_cooling is 1"                   '.legs_cooling' '1'
assert_between "A23a retry_after_s is in the log too" \
               "$(lg '.retry_after_s')" 1 6
assert_between "A23a no dial happened: latency stays under 100 ms" \
               "$(lg '.latency_ms')" 0 100

# The single-leg cap is 15 s but the rung here is the 5 s floor; wait it out and
# prove the leg is dialled again rather than skipped for a minute.
sleep 5.5
stub_kill leg-a 18086; stub leg-a 18086 stream-ok
req a23a3 "$RUN/req-stream.json"
assert_eq "A23a after the rung the leg serves again" "$(http_code a23a3)" "200"

echo
echo "=== A23b: two cooling legs, the earlier expiry wins; a quota 429 is believed"
gw_stop; stub_kill leg-a 18086; stub_kill leg-b 18085
stub leg-a 18086 429-quota --retry-after 42
stub leg-b 18085 never --ttl 30
write_config "leg-a|http://127.0.0.1:18086/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18085/v1|key-leg-b|"
tune_deadlines 300
gw_start
req a23b1 "$RUN/req-stream.json"
assert_eq "A23b both legs failed, so the caller gets a 502" "$(http_code a23b1)" "502"
admin_json "$RUN/a23b.admin.json" >/dev/null
assert_between "A23b the quota leg cools 60 s, not the flat 900: Retry-After was read" \
               "$(cooling_delta_s "$(admin_field "$RUN/a23b.admin.json" leg-a cooling_until)")" 58 60
assert_between "A23b the header-timeout leg cools its 5 s rung" \
               "$(cooling_delta_s "$(admin_field "$RUN/a23b.admin.json" leg-b cooling_until)")" 4 6
code=$(curl -sS -o "$RUN/a23b2.body" -D "$RUN/a23b2.head" -w '%{http_code}' \
  --max-time 5 -X POST -H 'Content-Type: application/json' \
  --data-binary @"$RUN/req-stream.json" "$GW_URL/v1/chat/completions")
assert_eq "A23b the next request is a 503" "$code" "503"
assert_between "A23b Retry-After is the earlier expiry, not the later one" \
               "$(gate_header "$RUN/a23b2.head" retry-after)" 1 6

echo
echo "=== A23c: a plain 429 fails over, and cools for its own Retry-After"
gw_stop; stub_kill leg-a 18086; stub_kill leg-b 18085
stub leg-a 18086 429-plain --retry-after 7
stub leg-b 18085 ok
write_config "leg-a|http://127.0.0.1:18086/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18085/v1|key-leg-b|"
tune_deadlines 300
gw_start
before=$(log_count)
req a23c "$RUN/req-stream.json"
assert_eq "A23c the next leg serves" "$(http_code a23c)" "200"
assert_one_line "A23c" "$before"
assert_log "A23c the route is the fallback" '.route' 'leg-b'
assert_log "A23c the reason is the rate-limit class" '.failover_reason' 'rate_limited_429'
admin_json "$RUN/a23c.admin.json" >/dev/null
assert_between "A23c the rate-limited leg cools its 7 s Retry-After" \
               "$(cooling_delta_s "$(admin_field "$RUN/a23c.admin.json" leg-a cooling_until)")" 6 7

gw_stop
kill_stubs
finish
