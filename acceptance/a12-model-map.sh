#!/bin/sh
# A12 — DEC-10: a leg that names a model sends that id, and only that leg does.
#
# The three providers kori chains (opencode-go, commandcode, sinarcloud) do not
# share model ids, so the caller's `model` cannot be forwarded verbatim to all of
# them. A leg with `model` in its config gets that id in the body it receives; a
# leg without one still forwards whatever the caller asked for, unchanged.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"
caller_model=$(jq -r '.model' "$RUN/req-basic.json")

# a12a: leg-a is dead, so leg-b answers, and each leg must have seen its own id.
gw_stop
stub_kill leg-a 18081
stub_kill leg-b 18082
stub leg-a 18081 401
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a||||stub-model-a" \
             "leg-b|http://127.0.0.1:18082/v1|key-leg-b||||stub-model-b"
gw_start
before=$(log_count)
req a12a "$RUN/req-basic.json"
assert_eq "a12a http 200 from the fallback" "$(http_code a12a)" "200"
assert_eq "a12a route is the leg that answered" "$(lg '.route')" "leg-b"
assert_one_line "a12a" "$before"
capture_body "$RUN/leg-a.req" "$RUN/a12a.leg-a.json"
capture_body "$RUN/leg-b.req" "$RUN/a12a.leg-b.json"
assert_eq "a12a the failed leg was sent its own model id" \
  "$(jq -r '.model' "$RUN/a12a.leg-a.json")" "stub-model-a"
assert_eq "a12a the answering leg was sent its own model id" \
  "$(jq -r '.model' "$RUN/a12a.leg-b.json")" "stub-model-b"
assert_absent "a12a the caller model never reached either leg" \
  "$RUN/a12a.leg-a.json" "$caller_model"
assert_absent "a12a the caller model never reached the answering leg" \
  "$RUN/a12a.leg-b.json" "$caller_model"
assert_eq "a12a the prompt reached the leg unchanged" \
  "$(jq -r '.messages[0].content' "$RUN/a12a.leg-b.json")" "$SENTINEL_PROMPT"
assert_eq "a12a nothing else in the body moved" \
  "$(jq -S -c 'del(.model)' "$RUN/a12a.leg-b.json")" \
  "$(jq -S -c 'del(.model)' "$RUN/req-basic.json")"

# a12b: a leg with no `model` key keeps forwarding the caller's id.
gw_stop
stub_kill leg-a 18081
stub_kill leg-b 18082
stub leg-a 18081 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|"
gw_start
req a12b "$RUN/req-basic.json"
assert_eq "a12b http 200" "$(http_code a12b)" "200"
capture_body "$RUN/leg-a.req" "$RUN/a12b.leg-a.json"
assert_eq "a12b a leg without a model forwards the caller's" \
  "$(jq -r '.model' "$RUN/a12b.leg-a.json")" "$caller_model"
assert_eq "a12b the request is byte-identical to the caller's" \
  "$(cat "$RUN/a12b.leg-a.json")" "$(cat "$RUN/req-basic.json")"

# a12c: four bypass shapes (F-1) must be rewritten to the leg model
gw_stop
stub_kill leg-a 18081
stub leg-a 18081 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a||||stub-model-c"
gw_start

# Shape 1: value string named model before the key
printf "%s" '{"foo":"model","messages":[{"role":"user","content":"hi"}],"model":"caller-id-1"}' >"$RUN/f1-val.json"
req a12c_val "$RUN/f1-val.json"
assert_eq "a12c_val http 200" "$(http_code a12c_val)" "200"
capture_body "$RUN/leg-a.req" "$RUN/a12c_val.json"
assert_eq "a12c_val leg saw its configured model" "$(jq -r '.model' "$RUN/a12c_val.json")" "stub-model-c"
assert_absent "a12c_val caller id never reached leg" "$RUN/a12c_val.json" "caller-id-1"

# Shape 2: array element named model before the key
printf "%s" '{"stop":["model"],"messages":[{"role":"user","content":"hi"}],"model":"caller-id-2"}' >"$RUN/f1-stop.json"
req a12c_stop "$RUN/f1-stop.json"
assert_eq "a12c_stop http 200" "$(http_code a12c_stop)" "200"
capture_body "$RUN/leg-a.req" "$RUN/a12c_stop.json"
assert_eq "a12c_stop leg saw its configured model" "$(jq -r '.model' "$RUN/a12c_stop.json")" "stub-model-c"
assert_absent "a12c_stop caller id never reached leg" "$RUN/a12c_stop.json" "caller-id-2"

# Shape 3: escaped key \u006dodel
printf "%s" '{"\u006dodel":"caller-id-3","messages":[{"role":"user","content":"hi"}]}' >"$RUN/f1-esc.json"
req a12c_esc "$RUN/f1-esc.json"
assert_eq "a12c_esc http 200" "$(http_code a12c_esc)" "200"
capture_body "$RUN/leg-a.req" "$RUN/a12c_esc.json"
assert_eq "a12c_esc leg saw its configured model" "$(jq -r '.model' "$RUN/a12c_esc.json")" "stub-model-c"
assert_absent "a12c_esc caller id never reached leg" "$RUN/a12c_esc.json" "caller-id-3"

# Shape 4: duplicate top-level model keys
printf "%s" '{"model":"caller-id-4a","messages":[{"role":"user","content":"hi"}],"model":"caller-id-4b"}' >"$RUN/f1-dup.json"
req a12c_dup "$RUN/f1-dup.json"
assert_eq "a12c_dup http 200" "$(http_code a12c_dup)" "200"
capture_body "$RUN/leg-a.req" "$RUN/a12c_dup.json"
assert_eq "a12c_dup leg saw its configured model" "$(jq -r '.model' "$RUN/a12c_dup.json")" "stub-model-c"
assert_absent "a12c_dup caller id 4a never reached leg" "$RUN/a12c_dup.json" "caller-id-4a"
assert_absent "a12c_dup caller id 4b never reached leg" "$RUN/a12c_dup.json" "caller-id-4b"

gw_stop
kill_stubs
finish
