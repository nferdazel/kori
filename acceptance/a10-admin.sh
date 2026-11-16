#!/bin/sh
# A10 — the dashboard is a read-only surface over three GETs
# (ACCEPTANCE-v1.md A10). Assertions are the acceptance block verbatim.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok
expect_closed 18093 && pass "A10 preflight: leg-c's port refuses connections" \
  || fail "A10 preflight" "something listens on 18093"

# 60 log lines exist before the binary does.
seed_log 60 leg-b 200
write_config "leg-a|http://127.0.0.1:18091/v1|$SENTINEL_CFG_SECRET|x-opencode-session:$SENTINEL_LEG" \
             "leg-b|http://192.0.2.1:9/v1|key-leg-b|" \
             "leg-c|http://127.0.0.1:18093/v1|key-leg-c|"
gw_start
stub_touch leg-a
before=$(log_count)
assert_eq "A10 the file is 60 lines before any request" "$before" "60"

echo
echo "=== A10a: /admin/state, fresh router, non-empty log"
assert_eq "A10a /admin/state answers 200" "$(admin_json "$RUN/a10-state.json")" "200"
assert_eq "A10a three legs are listed" \
  "$(admin_legs "$RUN/a10-state.json" | jq 'length')" "3"
assert_eq "A10a a fresh router is unknown for every leg" \
  "$(admin_count "$RUN/a10-state.json" unknown)" "3"
assert_eq "A10a every leg carries the D7 fields" \
  "$(admin_legs "$RUN/a10-state.json" | jq '[.[].o | has("name") and has("state") and has("cooling_until") and has("last_failure_class") and has("served_in_window") and has("failed_in_window")] | all')" "true"
assert_eq "A10a failed_in_window is a counter that starts at zero on every leg (D11.1)" \
  "$(admin_legs "$RUN/a10-state.json" | jq '[.[].o.failed_in_window] | all(. == 0)')" "true"
assert_eq "A10a served_in_window is a counter that starts at zero on every leg" \
  "$(admin_legs "$RUN/a10-state.json" | jq '[.[].o.served_in_window] | all(. == 0)')" "true"

echo
echo "=== A10b: the log browser answers, obeys its limit, and reports a tail scan"
assert_eq "A10b /admin/log?limit=10&offset=0 answers 200" \
  "$(admin_get "$RUN/a10-log0.json" '/admin/log?limit=10&offset=0')" "200"
assert_eq "A10b ten rows for limit 10" "$(log_row_count "$RUN/a10-log0.json")" "10"
assert_eq "A10b a row is exactly the nine D6 keys" \
  "$(log_rows "$RUN/a10-log0.json" | jq -c '.[0] | keys_unsorted')" "$LOG_KEYS"
assert_eq "A10b the newest row is the newest line in the file" \
  "$(log_row "$RUN/a10-log0.json" 0 ts)" "$(tail -n 1 "$GW_LOG" | jq -r '.ts')"
assert_eq "A10b the page reports the file's line count" \
  "$(jq -r '.file.lines' "$RUN/a10-log0.json")" "60"
assert_log_page_fits "A10b the page fits the limit it reports" "$RUN/a10-log0.json" 10
assert_eq "A10b ten rows cost about ten lines scanned, not sixty" \
  "$([ "$(log_scan "$RUN/a10-log0.json" lines_scanned)" -le 15 ] && echo within || echo over)" "within"
assert_tail_scan "A10b the scan did not cover the whole file" "$RUN/a10-log0.json" 10
assert_eq "A10b there are older lines behind the page" \
  "$(log_meta "$RUN/a10-log0.json" more_older)" "true"

echo
echo "=== A10c: offset counts from the newest"
assert_eq "A10c /admin/log?limit=10&offset=10 answers 200" \
  "$(admin_get "$RUN/a10-log10.json" '/admin/log?limit=10&offset=10')" "200"
assert_eq "A10c offset 10 starts at the eleventh line from the end" \
  "$(log_row "$RUN/a10-log10.json" 0 ts)" "$(tail -n 11 "$GW_LOG" | head -1 | jq -r '.ts')"
assert_eq "A10c the two pages share no row" \
  "$(jq -r --slurpfile first "$RUN/a10-log0.json" \
       '[.rows[].ts] - ($first[0].rows | map(.ts)) | length' "$RUN/a10-log10.json")" "10"

echo
echo "=== A10d: the cap is enforced, not clamped silently (D11 point 3)"
assert_eq "A10d a limit above 200 is refused" \
  "$(admin_get "$RUN/a10-log201.json" '/admin/log?limit=201')" "400"
assert_eq "A10d the refusal names the parameter" \
  "$(jq -r '.error.type' "$RUN/a10-log201.json")" "bad_request"

echo
echo "=== A10e: the config page, and the credential it was given"
assert_eq "A10e /admin/config answers 200" \
  "$(admin_get "$RUN/a10-cfg.json" '/admin/config')" "200"
assert_eq "A10e three legs in config order" \
  "$(jq -r '[.legs[].name] | join(",")' "$RUN/a10-cfg.json")" "leg-a,leg-b,leg-c"
assert_eq "A10e the legs are numbered from one" \
  "$(jq -r '[.legs[].order] | join(",")' "$RUN/a10-cfg.json")" "1,2,3"
assert_eq "A10e the listen address is loopback" \
  "$(jq -r '.listen | startswith("127.0.0.1:")' "$RUN/a10-cfg.json")" "true"
assert_eq "A10e the log path is the one the config names" \
  "$(jq -r '.log.path' "$RUN/a10-cfg.json")" "$GW_LOG"
assert_eq "A10e the planted credential is reported as set" \
  "$(jq -r '.legs[0].credential.state' "$RUN/a10-cfg.json")" "set"
assert_no_credential "A10e no fragment of the planted credential reaches the payload" \
  "$RUN/a10-cfg.json" "$SENTINEL_CFG_SECRET"
n=0
for k in "$SENTINEL_CFG_SECRET" key-leg-b key-leg-c; do
  n=$((n + 1))
  assert_absent "A10e leg $n's credential value is absent from the payload" \
    "$RUN/a10-cfg.json" "$k"
done
assert_absent "A10e no per-leg header value reaches the payload" \
  "$RUN/a10-cfg.json" "$SENTINEL_LEG"

echo
echo "=== A10f: no method but GET, and the refusal says what is allowed (D11 point 4)"
for p in /admin/state "/admin/log?limit=10" /admin/config; do
  assert_eq "A10f POST $p is refused" "$(admin_post_code "$p")" "405"
  assert_eq "A10f POST $p carries Allow: GET" "$(admin_post_allow "$p")" "GET"
done
assert_eq "A10f a GET still works after the refusals" \
  "$(admin_json "$RUN/a10-after.json")" "200"

echo
echo "=== A10g: nothing else lives under /admin/"
for p in /admin/nope /admin/logs /admin/configx; do
  assert_eq "A10g GET $p is 404" "$(admin_code "$p")" "404"
done

echo
echo "=== A10h: read-only, in the two ways that are observable from outside"
assert_eq "A10h no admin call dialled a leg" "$(dials leg-a)" "0"
assert_eq "A10h no admin call wrote a request line" "$(log_count)" "$before"

kill_stubs
finish
