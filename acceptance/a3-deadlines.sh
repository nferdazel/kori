#!/bin/sh
# A3 — the three D2 deadlines fire at their own numbers.
# A3a TLS 3 s, A3b streaming headers 15 s, A3c non-streaming headers 90 s.
# Runtime about 110 s: this one is wall clock, not a claim.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-stream.json" >"$RUN/req-stream.json"

echo "=== A3a: TLS handshake deadline, 3 s"
gw_stop; stub_kill leg-a-tls 18086; stub_kill leg-b 18082
stub leg-b 18082 ok
stub leg-a-tls 18086 never --ttl 60
write_config "leg-a|https://127.0.0.1:18086/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a3a "$RUN/req-basic.json"
assert_eq      "A3a fallback answers"                     "$(http_code a3a)" "200"
assert_one_line "A3a" "$before"
assert_log     "A3a failover_reason"                      '.failover_reason' 'dial_timeout'
assert_log     "A3a route"                                '.route' 'leg-b'
assert_log_keys "A3a"
assert_ts      "A3a"
lo=$(( D2_TLS_MS - TOL_TLS_UNDER_MS ))
hi=$(( D2_TLS_MS + TOL_TLS_OVER_MS ))
assert_between "A3a decided at the 3 s TLS deadline, not the 2 s connect one" \
               "$(lg '.latency_ms')" "$lo" "$hi"

echo
echo "=== A3b: streaming header deadline, 15 s"
gw_stop; stub_kill leg-b 18082; stub_kill leg-a-hdr 18087
stub leg-b 18082 stream-ok
stub leg-a-hdr 18087 never --ttl 300
write_config "leg-a|http://127.0.0.1:18087/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a3b "$RUN/req-stream.json"
assert_eq      "A3b fallback answers"                     "$(http_code a3b)" "200"
assert_eq      "A3b the client still gets a stream"       "$(sse_done_count "$RUN/a3b.body")" "1"
assert_one_line "A3b" "$before"
assert_log     "A3b failover_reason"                      '.failover_reason' 'header_timeout'
assert_log     "A3b stream"                               '.stream' 'true'
lo=$(( D2_HDR_STREAM_MS - TOL_HDR_STREAM_UNDER_MS ))
hi=$(( D2_HDR_STREAM_MS + TOL_HDR_STREAM_OVER_MS ))
assert_between "A3b decided at the 15 s streaming header deadline" "$(lg '.latency_ms')" "$lo" "$hi"

echo
echo "=== A3c: non-streaming header deadline, 90 s"
# gw_stop kills every pid the harness started, stubs included, so both are
# restarted here; leg-a keeps the same never-answering stub and a fresh ttl.
gw_stop; stub_kill leg-b 18082; stub_kill leg-a-hdr 18087
stub leg-b 18082 ok
stub leg-a-hdr 18087 never --ttl 300
write_config "leg-a|http://127.0.0.1:18087/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a3c "$RUN/req-basic.json"
assert_eq      "A3c fallback answers"                     "$(http_code a3c)" "200"
assert_one_line "A3c" "$before"
assert_log     "A3c failover_reason"                      '.failover_reason' 'header_timeout'
assert_log     "A3c stream"                               '.stream' 'false'
lo=$(( D2_HDR_NONSTREAM_MS - TOL_HDR_NONSTREAM_UNDER_MS ))
hi=$(( D2_HDR_NONSTREAM_MS + TOL_HDR_NONSTREAM_OVER_MS ))
assert_between "A3c decided at the 90 s non-streaming header deadline" "$(lg '.latency_ms')" "$lo" "$hi"

gw_stop
kill_stubs
finish
