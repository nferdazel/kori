#!/bin/sh
# A3 — the D2 deadlines fire at their own numbers, and the streaming one is a rule.
# A3a TLS 3 s, A3b streaming headers 15 s at the floor, A3c non-streaming 90 s,
# A3d the floor fails a mid-sized prompt that the slope then serves.
# Runtime about 150 s: this one is wall clock, not a claim.
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
echo "=== A3b: streaming header deadline, 15 s floor for a short body"
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
echo "=== A3d: the streaming window grows with the body (D-2)"
# Two body sizes, one stub, one delay: 17 s is past the 15 s floor and short of
# the ~35 s a 200 KiB prompt buys. The small body must time out and walk on; the
# big one must be served by the same slow leg. This is the shape of the nine false
# failovers a day Arif measured, and pinning a single number would not catch it.
gw_stop; stub_kill leg-b 18082; stub_kill leg-a-hdr 18088
stub leg-b 18082 stream-ok
stub leg-a-hdr 18088 stream-ok --delay-headers 17
write_config "leg-a|http://127.0.0.1:18088/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
gw_start
before=$(log_count)
req a3d "$RUN/req-stream.json"
assert_eq      "A3d the caller is served by the fallback" \
               "$(http_code a3d)" "200"
assert_log     "A3d a short prompt still times out at the 15 s floor" \
               '.failover_reason' 'header_timeout'
lo=$(( D2_HDR_STREAM_MS - TOL_HDR_STREAM_UNDER_MS ))
hi=$(( D2_HDR_STREAM_MS + TOL_HDR_STREAM_OVER_MS ))
assert_between "A3d the short prompt kept the floor" "$(lg '.latency_ms')" "$lo" "$hi"

# A prompt of ~200 KiB, the 50k-token shape that p90'd at 20.8 s. One long line
# keeps the fixture small on disk and the JSON valid.
python3 - "$RUN/req-big.json" "$ACC_DIR/fixtures/request-stream.json" <<'PY'
import json, sys
out, src = sys.argv[1], sys.argv[2]
body = json.load(open(src))
body["messages"][0]["content"] = "x" * (200 * 1024)
json.dump(body, open(out, "w"))
PY
body_bytes=$(wc -c <"$RUN/req-big.json" | tr -d ' ')
want_ms=$(( D2_HDR_STREAM_MS + (body_bytes / 1024) * D2_HDR_STREAM_SLOPE_MS_PER_KIB ))
if [ "$want_ms" -gt "$D2_HDR_STREAM_MAX_MS" ]; then want_ms=$D2_HDR_STREAM_MAX_MS; fi
echo "note  A3e body ${body_bytes} bytes -> expected window ${want_ms} ms"
# The same 17 s delay that just failed on the small body. Only the body changed,
# so a pass here cannot be the stub being faster.
gw_stop; stub_kill leg-a-hdr 18088
stub leg-a-hdr 18088 stream-ok --delay-headers 17
write_config "leg-a|http://127.0.0.1:18088/v1|key-leg-a|"
gw_start
before=$(log_count)
req a3e "$RUN/req-big.json"
assert_eq      "A3e the big prompt is served" "$(http_code a3e)" "200"
assert_one_line "A3e" "$before"
assert_log     "A3e the big prompt stayed on its leg, no failover" '.route' 'leg-a'
assert_log     "A3e and it carries no failover_reason" '.failover_reason' ''
# The delay is 17 s and the old floor was 15 s: being served at all is the proof
# that the window grew. The upper bound is the window itself.
assert_between "A3e it waited past the old 15 s floor and inside its own window" \
               "$(lg '.latency_ms')" "$(( 17 * 1000 ))" "$want_ms"

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
