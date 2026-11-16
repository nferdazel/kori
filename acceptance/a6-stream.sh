#!/bin/sh
# A6 — an answer that dies after the first byte is aborted, never rerouted.
# A6a streaming death, A6b include_usage injection, A6c a pre-first-byte failure
# still fails over, A6d the non-streaming half of the same shape.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"

echo "=== A6a: two chunks, then the leg dies"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a 18081 stream-2-then-die
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
admin_json "$RUN/a6-before.json" >/dev/null
before=$(log_count)
req a6a "$RUN/req-stream.json"
assert_eq      "A6a the caller's stream opened"           "$(http_code a6a)" "200"
assert_eq      "A6a two chunks reached the caller"        "$(sse_chunks "$RUN/a6a.body")" "2"
assert_eq      "A6a no [DONE] was invented"               "$(sse_done_count "$RUN/a6a.body")" "0"
assert_eq      "A6a exactly one SSE error event"          "$(sse_error_events "$RUN/a6a.body")" "1"
assert_eq      "A6a the second leg was never dialled"     "$(dials leg-b)" "0"
assert_one_line "A6a" "$before"
assert_log_keys "A6a"
assert_log     "A6a status is the opened stream"          '.status' '200'
assert_log     "A6a stream"                               '.stream' 'true'
assert_log     "A6a route stays the first leg"            '.route' 'leg-a'
assert_log     "A6a failover_from is empty"               '.failover_from' ''
assert_log     "A6a failover_reason is the abort token"   '.failover_reason' 'mid_stream_abort'
assert_log_null "A6a tokens_in is null, never 0"          '.tokens_in'
assert_log_null "A6a tokens_out is null, never 0"         '.tokens_out'
admin_json "$RUN/a6-after.json" >/dev/null
assert_eq      "A6a the leg stays ok, it is not cooled"   "$(admin_field "$RUN/a6-after.json" leg-a state)" "ok"
assert_eq      "A6a no leg is cooling"                    "$(admin_count "$RUN/a6-after.json" cooling)" "0"
assert_eq      "A6a cooling_until is null on that leg"    "$(admin_field "$RUN/a6-after.json" leg-a cooling_until)" "null"
assert_eq      "A6a the abort never lands in last_failure_class" \
               "$(admin_field "$RUN/a6-after.json" leg-a last_failure_class)" "null"
assert_eq      "A6a availability counter unmoved" \
               "$(window_delta "$RUN/a6-before.json" "$RUN/a6-after.json" avail)" "0"
assert_eq      "A6a capacity counter unmoved" \
               "$(window_delta "$RUN/a6-before.json" "$RUN/a6-after.json" capac)" "0"

echo
echo "=== A6b: include_usage is injected when the caller omitted it"
capture_body "$RUN/leg-a.req" "$RUN/a6b.req.json"
assert_eq      "A6b include_usage was injected" \
               "$(jq -r '.stream_options.include_usage' "$RUN/a6b.req.json" 2>/dev/null || echo missing)" "true"
assert_eq      "A6b nothing else in the request changed" \
  "$(jq -c -S 'del(.stream_options)' "$RUN/a6b.req.json")" \
  "$(jq -c -S . "$RUN/req-stream.json")"

echo
echo "=== A6c: a failure before the first byte still fails over"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18084
stub leg-a 18081 503
stub leg-b 18084 stream-ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18084/v1|key-leg-b|"
gw_start
before=$(log_count)
req a6c "$RUN/req-stream.json"
assert_eq      "A6c the fallback stream finished"         "$(http_code a6c)" "200"
assert_eq      "A6c [DONE] reached the caller"            "$(sse_done_count "$RUN/a6c.body")" "1"
assert_eq      "A6c no error event on a clean stream"     "$(sse_error_events "$RUN/a6c.body")" "0"
assert_eq      "A6c three chunks reached the caller"      "$(sse_chunks "$RUN/a6c.body")" "3"
assert_eq      "A6c the fallback was dialled once"        "$(dials leg-b)" "1"
assert_one_line "A6c" "$before"
assert_log     "A6c route"                                '.route' 'leg-b'
assert_log     "A6c failover_from"                        '.failover_from' 'leg-a'
assert_log     "A6c failover_reason"                      '.failover_reason' 'upstream_5xx'
assert_log     "A6c stream"                               '.stream' 'true'
assert_log     "A6c tokens_in from the final usage chunk" '.tokens_in' '11'
assert_log     "A6c tokens_out from the final usage chunk" '.tokens_out' '7'

echo
echo "=== A6d: a non-streaming body that dies after the headers"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a 18081 short-body
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a6d "$RUN/req-basic.json"
assert_eq      "A6d the caller's response opened"         "$(http_code a6d)" "200"
assert_eq      "A6d the fallback was never dialled"       "$(dials leg-b)" "0"
assert_eq      "A6d the caller did not get the fallback answer" \
               "$(jq -r '.choices[0].message.content' "$RUN/a6d.body" 2>/dev/null || echo truncated)" "truncated"
assert_one_line "A6d" "$before"
assert_log_keys "A6d"
assert_log     "A6d stream"                               '.stream' 'false'
assert_log     "A6d route stays the first leg"            '.route' 'leg-a'
assert_log     "A6d failover_from is empty"               '.failover_from' ''
assert_log     "A6d failover_reason is the abort token"   '.failover_reason' 'mid_stream_abort'
assert_log_null "A6d tokens_in is null, never 0"          '.tokens_in'
assert_log_null "A6d tokens_out is null, never 0"         '.tokens_out'
assert_eq      "A6d the log reports the status the caller saw" \
               "$(lg '.status')" "$(http_code a6d)"
admin_json "$RUN/a6d-after.json" >/dev/null
assert_eq      "A6d the leg stays ok, it is not cooled" \
               "$(admin_field "$RUN/a6d-after.json" leg-a state)" "ok"

gw_stop
kill_stubs
finish
