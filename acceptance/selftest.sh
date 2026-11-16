#!/bin/sh
# shellcheck disable=SC2034  # GW_BALANCE and GW_URL are read by lib.sh's helpers, not here
# Proves the harness in lib.sh fires both ways: every assertion is checked once
# against input it must accept and once against input it must reject. Needs no
# gateway and no network. Run: sh selftest.sh
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
RUN=$(mktemp -d "${TMPDIR:-/tmp}/kori-selftest-XXXXXX")
. "$ACC_DIR/lib.sh"

GW_CFG="$RUN/cfg.json"
GW_LOG="$RUN/fake.jsonl"

# Runs an assertion in a subshell and reports what it said, so a negative test
# does not add to this run's own totals.
rejects() { # label command...
  label=$1; shift
  out=$("$@" 2>&1)
  case "$out" in
    FAIL*) pass "rejects: $label" ;;
    *) fail "rejects: $label" "assertion did not fail on bad input: $out" ;;
  esac
}

# 1. write_config: ordered legs, per-leg header, mode 0600.
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|x-opencode-session:$SENTINEL_LEG" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-c|"
assert_eq "config leg order" "$(jq -rc '[.legs[].name]' "$GW_CFG")" '["leg-a","leg-b","leg-c"]'
assert_eq "config leg header" "$(jq -r '.legs[0].headers["x-opencode-session"]' "$GW_CFG")" "$SENTINEL_LEG"
assert_eq "config mode 0600" "$(file_mode "$GW_CFG")" "600"
assert_eq "gw log path is what the config says" "$(jq -r '.log.path' "$GW_CFG")" "$GW_LOG"

# 2. expect_closed: no to a listener, yes to a free port.
expect_closed 18099 && pass "expect_closed accepts a free port" || fail "expect_closed accepts a free port" ""
stub t401 18081 401
expect_closed 18081 && fail "expect_closed on a listener" "" || pass "expect_closed rejects a listener"

# 3. stub: answers with the canned status, counts dials only, captures the body.
printf '{"model":"flash","stream":false,"messages":[{"role":"user","content":"%s"}]}' "$SENTINEL_PROMPT" >"$RUN/req.json"
GW_URL=http://127.0.0.1:$(port_of 18081)
stub_touch t401
req self "$RUN/req.json"
assert_eq "req helper sees the stub status" "$(http_code self)" "401"
assert_eq "one request counts one dial" "$(dials t401)" "1"
assert_present "capture holds the request body" "$RUN/t401.req" "$SENTINEL_PROMPT"
assert_present "capture holds the client Authorization header" "$RUN/t401.req" "Authorization: Bearer $SENTINEL_CLIENT"

# 4. assert_cmp both ways.
assert_cmp "identical bytes pass" "$RUN/t401.req" "$RUN/t401.req"
cp "$RUN/t401.req" "$RUN/one-byte-more"
printf 'x' >>"$RUN/one-byte-more"
rejects "one extra byte" assert_cmp "cmp" "$RUN/one-byte-more" "$RUN/t401.req"

# 5. Log assertions: a good line accepted, a reordered line rejected.
good='{"ts":"2026-11-14T17:40:00.512+07:00","route":"leg-b","status":200,"latency_ms":38,"tokens_in":11,"tokens_out":7,"failover_from":"leg-a","failover_reason":"auth_401","stream":false}'
swapped='{"route":"leg-b","ts":"2026-11-14T17:40:00.512+07:00","status":200,"latency_ms":38,"tokens_in":11,"tokens_out":7,"failover_from":"leg-a","failover_reason":"auth_401","stream":false}'
nooffset='{"ts":"2026-11-14T17:40:00.512","route":"leg-b","status":200,"latency_ms":38,"tokens_in":11,"tokens_out":7,"failover_from":"leg-a","failover_reason":"auth_401","stream":false}'
nulltok='{"ts":"2026-11-14T17:40:00.512Z","route":"leg-b","status":200,"latency_ms":38,"tokens_in":null,"tokens_out":null,"failover_from":"","failover_reason":"","stream":true}'

printf '%s\n' "$good" >"$GW_LOG"
assert_log_keys "good line has the nine keys in order"
assert_log "route is the answering leg" '.route' 'leg-b'
assert_log "reason token is reported" '.failover_reason' 'auth_401'
assert_between "latency inside the window" "$(lg '.latency_ms')" 30 45

printf '%s\n' "$swapped" >"$GW_LOG"
rejects "swapped key order" assert_log_keys "swapped line"
rejects "wrong route value" assert_log "route" ".route" "leg-c"

printf '%s\n' "$nooffset" >"$GW_LOG"
rejects "ts without an offset" assert_ts "nooffset"

printf '%s\n' "$nulltok" >"$GW_LOG"
assert_log_null "null tokens accepted" '.tokens_out'
assert_log "empty failover_from on a clean request" '.failover_from' ''
rejects "latency outside the window" assert_between "latency" "$(lg '.latency_ms')" 100 200

# 5b. /admin/state helpers accept a map or an array shape, and read the numbers.
iso=$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=60)).isoformat().replace("+00:00","Z"))')
cat >"$RUN/admin-map.json" <<JSON
{"legs":{"leg-a":{"state":"cooling","cooling_until":"$iso","last_failure_class":"conn_refused"},
         "leg-b":{"state":"ok","cooling_until":null,"last_failure_class":null},
         "leg-c":{"state":"unknown","cooling_until":null,"last_failure_class":null}}}
JSON
cat >"$RUN/admin-array.json" <<JSON
{"legs":[{"name":"leg-a","state":"cooling","cooling_until":"$iso","last_failure_class":"conn_refused"},
         {"name":"leg-b","state":"ok","cooling_until":null,"last_failure_class":null},
         {"name":"leg-c","state":"unknown","cooling_until":null,"last_failure_class":null}]}
JSON
for shape in map array; do
  f="$RUN/admin-$shape.json"
  assert_eq "$shape shape: three legs found" "$(admin_legs "$f" | jq 'length')" "3"
  assert_eq "$shape shape: one leg cooling" "$(admin_count "$f" cooling)" "1"
  assert_eq "$shape shape: the cooling leg is named" "$(admin_cooling_keys "$f")" '"leg-a"'
  assert_eq "$shape shape: failure class" "$(admin_field "$f" leg-a last_failure_class)" "conn_refused"
  assert_between "$shape shape: cooldown reads 60 s" "$(cooling_delta_s "$(admin_field "$f" leg-a cooling_until)")" 55 65
done
assert_eq "unknown state counts on a fresh page" \
  "$(printf '%s' '{"legs":{"leg-a":{"state":"unknown","cooling_until":null,"last_failure_class":null}}}' >"$RUN/fresh.json"; admin_count "$RUN/fresh.json" unknown)" "1"

# 5c. D9 point 5 and 6: two window counters and a last-20 event list, on two shapes.
iso2=$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat())')
cat >"$RUN/w-map.json" <<JSON
{"legs":{"leg-a":{"state":"cooling","cooling_until":"$iso","last_failure_class":"quota_429"}},
 "window":{"availability":3,"capacity":1},
 "events":[{"ts":"$iso2","route":"leg-b","failover_from":"leg-a","failover_reason":"quota_429"}]}
JSON
cat >"$RUN/w-array.json" <<JSON
{"legs":[{"name":"leg-a","state":"ok","cooling_until":null,"last_failure_class":null}],
 "window":{"availability_failovers":0,"capacity_failovers":2},
 "recent":[{"ts":"$iso2","reason":"quota_429"},{"ts":"$iso2","reason":"auth_401"}]}
JSON
cat >"$RUN/w-none.json" <<JSON
{"legs":{"leg-a":{"state":"unknown","cooling_until":null,"last_failure_class":null}}}
JSON
cat >"$RUN/w-zero.json" <<JSON
{"legs":{"leg-a":{"state":"unknown","cooling_until":null,"last_failure_class":null}},
 "window":{"availability":0,"capacity":0},"events":[]}
JSON
assert_eq "map shape: availability counter" "$(window_counter "$RUN/w-map.json" avail)" "3"
assert_eq "map shape: capacity counter" "$(window_counter "$RUN/w-map.json" capac)" "1"
assert_eq "array shape: availability counter" "$(window_counter "$RUN/w-array.json" avail)" "0"
assert_eq "array shape: capacity counter" "$(window_counter "$RUN/w-array.json" capac)" "2"
assert_eq "missing window is absent, not zero" "$(window_counter "$RUN/w-none.json" avail)" "absent"
assert_eq "delta counts one request one time" "$(window_delta "$RUN/w-zero.json" "$RUN/w-map.json" capac)" "1"
assert_eq "delta of a request that did not fail is zero" \
  "$(window_delta "$RUN/w-zero.json" "$RUN/w-zero.json" avail)" "0"
assert_eq "delta against a page with no window" \
  "$(window_delta "$RUN/w-none.json" "$RUN/w-map.json" avail)" "absent"
assert_eq "one event in a one-failover window" "$(window_events "$RUN/w-map.json" | jq 'length')" "1"
assert_eq "two events in a two-event window" "$(window_events "$RUN/w-array.json" | jq 'length')" "2"
assert_eq "an empty window has no events" "$(window_events "$RUN/w-zero.json" | jq 'length')" "0"
assert_eq "the event names the token" "$(window_event_hits "$RUN/w-map.json" quota_429)" "1"
assert_eq "the event list is capped at 20" "$(window_events "$RUN/w-map.json" | jq 'length <= 20')" "true"
rejects "a counter that did not move by one" assert_eq "delta" "$(window_delta "$RUN/w-zero.json" "$RUN/w-map.json" avail)" "1"

# 5d. The truncated-body fixture A6d needs: headers promised, body dies.
stub shortb 18092 short-body
code=$(curl -sS -o "$RUN/sb.body" -w '%{http_code}' --max-time 5 -X POST \
  "http://127.0.0.1:$(port_of 18092)/v1/chat/completions" -d '{}' 2>"$RUN/sb.err"); rc=$?
assert_eq "short-body answers 200" "$code" "200"
[ "$rc" -ne 0 ] && pass "short-body truncates the transfer (curl exit $rc)" \
  || fail "short-body truncates the transfer" "curl reported a clean transfer"
assert_eq "short-body sends far fewer bytes than Content-Length promised" \
  "$([ "$(wc -c <"$RUN/sb.body" | tr -d ' ')" -lt 200 ] && echo short || echo long)" "short"
assert_absent "short-body never sends the fallback answer" "$RUN/sb.body" 'STUB-OK'

# 6. Stub lifecycle: a killed stub frees its port for the next behaviour.
stub life 18088 ok
assert_eq "killed stub frees the port" "$(stub_kill life 18088 && expect_closed 18088 && echo free)" "free"

# 7. Raw-bytes helpers used by A6 and A7.
printf 'POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\n{"a":"b"}\n\n' >"$RUN/cap.req"
capture_body "$RUN/cap.req" "$RUN/cap.body"
assert_eq "capture_body strips the head and keeps the body" "$(cat "$RUN/cap.body")" '{"a":"b"}'

assert_eq "sse_data_count on the tool-call fixture" "$(sse_data_count "$ACC_DIR/fixtures/toolcall-stream.sse")" "6"
assert_eq "sse_done_count on the tool-call fixture" "$(sse_done_count "$ACC_DIR/fixtures/toolcall-stream.sse")" "1"
assert_eq "sse_chunks on the tool-call fixture" "$(sse_chunks "$ACC_DIR/fixtures/toolcall-stream.sse")" "5"
assert_eq "no error event on a clean stream" "$(sse_error_events "$ACC_DIR/fixtures/toolcall-stream.sse")" "0"
printf 'data: {"object":"chat.completion.chunk","choices":[1]}\n\ndata: {"object":"chat.completion.chunk","choices":[2]}\n\nevent: error\ndata: {"error":{"code":"mid_stream_abort"}}\n\n' >"$RUN/dies.sse"
assert_eq "sse_chunks ignores the error payload" "$(sse_chunks "$RUN/dies.sse")" "2"
assert_eq "sse_data_count counts the error payload too" "$(sse_data_count "$RUN/dies.sse")" "3"
assert_eq "sse_done_count on a dying stream" "$(sse_done_count "$RUN/dies.sse")" "0"
assert_eq "one error event on a dying stream" "$(sse_error_events "$RUN/dies.sse")" "1"

# 8. Stream fixtures parse as SSE.
python3 - "$ACC_DIR/fixtures/toolcall-stream.sse" <<'PY'
import json, sys
raw = open(sys.argv[1], 'rb').read().decode()
blocks = [b for b in raw.split('\n\n') if b.strip()]
assert blocks[-1] == 'data: [DONE]', 'stream must end with [DONE]'
for b in blocks[:-1]:
    json.loads(b[len('data: '):])
print('PASS  toolcall-stream.sse is valid SSE with a final [DONE]')
PY
[ $? -eq 0 ] && PASSED=$((PASSED + 1)) || FAILED=$((FAILED + 1))

# 9. /admin/log and /admin/config readers (A10), no gateway needed.
GW_LOG_OLD=$GW_LOG
GW_LOG="$RUN/seed.jsonl"
seed_log 60 leg-b 200
assert_eq "seed_log writes the requested line count" "$(log_count)" "60"
assert_eq "seed_log lines carry the nine keys in order" \
  "$(tail -n 1 "$GW_LOG" | jq -c 'keys_unsorted')" "$LOG_KEYS"
assert_ts "seed_log timestamp" 1
GW_LOG=$GW_LOG_OLD

# A good ten-row page over that 60-line file.
jq -n --slurpfile a "$RUN/seed.jsonl" '{
  generated_at: "2026-11-14T23:22:14+07:00",
  source: "tail",
  file: {path: "/tmp/kori-requests.log", bytes: 4096, lines: ($a | length), exists: true},
  offset: 0, limit: 10,
  rows: ($a | reverse | .[0:10]),
  scan: {lines_scanned: 10, budget: 5000, budget_exhausted: false},
  more_older: true
}' >"$RUN/log-good.json"

assert_eq "page row count"          "$(log_row_count "$RUN/log-good.json")" "10"
assert_eq "page limit is read"      "$(log_meta "$RUN/log-good.json" limit)" "10"
assert_eq "page newest row route"   "$(log_row "$RUN/log-good.json" 0 .route)" "leg-b"
assert_eq "more_older is read"      "$(log_meta "$RUN/log-good.json" more_older)" "true"
assert_eq "scan lines are read"     "$(log_scan "$RUN/log-good.json" lines_scanned)" "10"
assert_log_page_fits "a ten-row page for limit 10" "$RUN/log-good.json" 10
assert_tail_scan "a ten-row page did not read all sixty lines" "$RUN/log-good.json" 10

jq '.rows += [.rows[0]]' "$RUN/log-good.json" >"$RUN/log-wide.json"
rejects "a page with eleven rows for limit ten" \
  assert_log_page_fits "page" "$RUN/log-wide.json" 10
jq '.limit = 50' "$RUN/log-good.json" >"$RUN/log-misreport.json"
rejects "a page whose limit disagrees with the request" \
  assert_log_page_fits "page" "$RUN/log-misreport.json" 10
jq '.scan.lines_scanned = .file.lines' "$RUN/log-good.json" >"$RUN/log-whole.json"
rejects "a page that scanned the whole file for ten rows" \
  assert_tail_scan "page" "$RUN/log-whole.json" 10

printf '{"legs":[{"credential":{"state":"set","ref":"env:KORI_KEY_1"}}]}' >"$RUN/cfg-redacted.json"
assert_no_credential "a redacted config passes" "$RUN/cfg-redacted.json" "$SENTINEL_CFG_SECRET"
printf '{"legs":[{"credential":{"value":"%s"}}]}' "$SENTINEL_CFG_SECRET" >"$RUN/cfg-leak.json"
rejects "a config carrying the value" \
  assert_no_credential "cfg" "$RUN/cfg-leak.json" "$SENTINEL_CFG_SECRET"
printf '{"legs":[{"credential":{"ref":"%s"}}]}' \
  "$(printf '%s' "$SENTINEL_CFG_SECRET" | cut -c1-12)" >"$RUN/cfg-fragment.json"
rejects "a config carrying a twelve-character fragment" \
  assert_no_credential "cfg" "$RUN/cfg-fragment.json" "$SENTINEL_CFG_SECRET"

# 10. D12 fixtures and the A11 readers: balance, role and weight; the tail split; and the
# stub switches that let two healthy legs be told apart and one leg die mid-run.
GW_BALANCE=true
write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1" \
             "leg-b|http://127.0.0.1:18082/v1|key-b||primary|2" \
             "leg-c|http://127.0.0.1:18083/v1|key-c||fallback|1"
GW_BALANCE=
assert_eq "balance is written when asked for" "$(jq -r '.balance' "$GW_CFG")" "true"
assert_eq "role is written per leg"           "$(jq -r '[.legs[].role] | join(",")' "$GW_CFG")" "primary,primary,fallback"
assert_eq "weight is written per leg"         "$(jq -r '[.legs[].weight] | join(",")' "$GW_CFG")" "1,2,1"
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|" \
             "leg-c|http://127.0.0.1:18083/v1|key-c|"
assert_eq "an unset balance leaves the key out" "$(jq 'has("balance")' "$GW_CFG")" "false"
assert_eq "an unset role leaves the key out"    "$(jq '.legs[0] | has("role")' "$GW_CFG")" "false"

GW_LOG_OLD=$GW_LOG
GW_LOG="$RUN/tail.jsonl"
for r in leg-a leg-b leg-a leg-c; do
  printf '%s\n' "$good" | jq -c --arg r "$r" '.route = $r | .failover_from = "" | .failover_reason = ""' >>"$GW_LOG"
done
assert_eq "route_count counts a leg in the tail" "$(route_count 4 leg-a)" "2"
assert_eq "route_count reads only the tail it is given" "$(route_count 2 leg-a)" "1"
assert_eq "route_count reports zero for a leg that did not serve" "$(route_count 4 leg-z)" "0"
assert_eq "tail_jq counts a filtered tail" "$(tail_jq 4 '[.[] | select(.route=="leg-a")] | length')" "2"
assert_eq "tail_jq finds no failover in clean lines" \
  "$(tail_jq 4 '[.[] | select(.failover_from != "")] | length')" "0"
printf '%s\n' "$good" >>"$GW_LOG"
assert_eq "tail_jq finds the one line carrying a failover" \
  "$(tail_jq 5 '[.[] | select(.failover_from != "")] | length')" "1"
GW_LOG=$GW_LOG_OLD

stub model-a 18084 ok --model stub-model-a
GW_URL=http://127.0.0.1:$(port_of 18084)
req self-model "$RUN/req.json"
assert_eq "the stub answers with --model when it is given one" \
  "$(jq -r '.model' "$RUN/self-model.body")" "stub-model-a"
stub_kill model-a 18084
stub after-401 18084 ok-then-401 --after 1
GW_URL=http://127.0.0.1:$(port_of 18084)
req after-1 "$RUN/req.json"
req after-2 "$RUN/req.json"
assert_eq "the stub answers before --after"  "$(http_code after-1)" "200"
assert_eq "the stub fails from --after on"   "$(http_code after-2)" "401"

kill_stubs
finish
