#!/bin/sh
# A7 — tool calls survive the proxy byte for byte (ACCEPTANCE-v1.md A7).
#
# Assertions are the acceptance block verbatim, plus one added sub-case:
#   A7b-stream repeats A7b from the jq-derived copy of the same request.
#
# A7b's stub answers with SSE and its log assertions ask for stream:true and
# usage tokens, so the request it sends declares the stream: it comes from
# toolcall-request-stream.json, which is toolcall-request.json with
# ".stream = true". A7a keeps the non-streaming body. Nothing in the binary is
# changed to make either pass.
#
# Each sub-case stops the gateway before it swaps the stub: gw_stop kills every
# pid in $RUN/pids, and a stub started before gw_stop would be killed with it.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[1].content = $p' \
   "$ACC_DIR/fixtures/toolcall-request.json" >"$RUN/req-tool.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[1].content = $p' \
   "$ACC_DIR/fixtures/toolcall-request-stream.json" >"$RUN/req-tool-stream.json"
jq -c '.stream = true' "$RUN/req-tool.json" >"$RUN/req-tool-stream-jq.json"

echo "=== A7a: non-streaming tool call, byte-identical response"
gw_stop; stub_kill leg-a 18091
stub leg-a 18091 raw-toolcall --body-file "$ACC_DIR/fixtures/toolcall-response.json"
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18092/v1|key-leg-b|"
gw_start
before=$(log_count)
req a7a "$RUN/req-tool.json"
assert_eq      "A7a status"                               "$(http_code a7a)" "200"
assert_cmp     "A7a body is byte-identical to the leg's"  "$RUN/a7a.body" "$ACC_DIR/fixtures/toolcall-response.json"
assert_eq      "A7a the tool call survives in the body" \
               "$(jq -r '.choices[0].message.tool_calls[0].function.arguments | fromjson | .city' "$RUN/a7a.body")" 'Jakarta'
assert_one_line "A7a" "$before"
assert_log_keys "A7a"
assert_ts      "A7a"
assert_log     "A7a tokens_in"                            '.tokens_in' '64'
assert_log     "A7a tokens_out"                           '.tokens_out' '21'
assert_log     "A7a stream"                               '.stream' 'false'

echo
echo "=== A7b: streamed tool-call deltas, byte-identical (request says stream:true)"
gw_stop; stub_kill leg-a 18091
stub leg-a 18091 raw-toolcall-stream --body-file "$ACC_DIR/fixtures/toolcall-stream.sse"
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18092/v1|key-leg-b|"
gw_start
before=$(log_count)
req a7b "$RUN/req-tool-stream.json"
assert_eq      "A7b status"                               "$(http_code a7b)" "200"
assert_cmp     "A7b every SSE byte matches the leg's"     "$RUN/a7b.body" "$ACC_DIR/fixtures/toolcall-stream.sse"
assert_eq      "A7b [DONE] survived"                      "$(sse_done_count "$RUN/a7b.body")" "1"
assert_eq      "A7b six data lines, five chunks and one [DONE]" "$(sse_data_count "$RUN/a7b.body")" "6"
assert_one_line "A7b" "$before"
assert_log     "A7b stream"                               '.stream' 'true'
assert_log     "A7b tokens_in"                            '.tokens_in' '64'
assert_log     "A7b tokens_out"                           '.tokens_out' '21'

echo
echo "=== A7b-stream: the same request derived with jq instead of the fixture file"
before=$(log_count)
req a7bs "$RUN/req-tool-stream-jq.json"
assert_eq      "A7b-stream status"                        "$(http_code a7bs)" "200"
assert_cmp     "A7b-stream every SSE byte matches the leg's" "$RUN/a7bs.body" "$ACC_DIR/fixtures/toolcall-stream.sse"
assert_eq      "A7b-stream [DONE] survived"               "$(sse_done_count "$RUN/a7bs.body")" "1"
assert_eq      "A7b-stream six data lines"                "$(sse_data_count "$RUN/a7bs.body")" "6"
assert_one_line "A7b-stream" "$before"
assert_log     "A7b-stream stream"                        '.stream' 'true'
assert_log     "A7b-stream tokens_in"                     '.tokens_in' '64'
assert_log     "A7b-stream tokens_out"                    '.tokens_out' '21'

echo
echo "=== A7c: no usage in the provider response"
gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok-nousage
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18092/v1|key-leg-b|"
gw_start
before=$(log_count)
req a7c "$RUN/req-basic.json"
assert_eq      "A7c status"                               "$(http_code a7c)" "200"
assert_log_null "A7c tokens_in is null, not 0"            '.tokens_in'
assert_log_null "A7c tokens_out is null, not 0"           '.tokens_out'
assert_ne      "A7c tokens_out is not a zero"             "$(lg '.tokens_out')" '0'

echo
echo "=== A7d: the response model is the leg's, the caller's is not reflected"
gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18092/v1|key-leg-b|"
gw_start
req a7d "$RUN/req-basic.json"
assert_eq      "A7d status"                               "$(http_code a7d)" "200"
assert_eq      "A7d the caller sent flash" \
               "$(jq -r '.model' "$RUN/req-basic.json")" "flash"
assert_eq      "A7d the response carries the leg's model, not the caller's" \
               "$(jq -r '.model' "$RUN/a7d.body")" "stub-model"
capture_body "$RUN/leg-a.req" "$RUN/a7d.req.json"
assert_eq      "A7d the caller's model reached the leg unchanged" \
               "$(jq -r '.model' "$RUN/a7d.req.json")" "flash"
assert_log     "A7d the line reports the leg that answered" '.route' 'leg-a'
assert_log     "A7d no failover on a single live leg"      '.failover_from' ''
assert_log     "A7d tokens_in"                            '.tokens_in' '11'
assert_log     "A7d tokens_out"                           '.tokens_out' '7'

kill_stubs
finish
