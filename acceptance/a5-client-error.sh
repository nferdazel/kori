#!/bin/sh
# A5 — a client error is the caller's problem, and nothing fails over.
# 400 (not MissingSessionID), 403 and 404 each reach the caller unchanged with
# the provider's body and the fallback is never dialled.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

printf '{"error":{"message":"forbidden by the provider","type":"invalid_request_error"}}\n' >"$RUN/body-403.json"
printf '{"error":{"message":"no such model on this leg","type":"invalid_request_error"}}\n' >"$RUN/body-404.json"

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-b 18082 ok

for spec in "400 400 $ACC_DIR/fixtures/error-400-model-not-found.json" \
            "403 403 $RUN/body-403.json" \
            "404 404 $RUN/body-404.json"; do
  set -- $spec
  case_label=$1 case_status=$2 case_body=$3
  gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
  stub leg-b 18082 ok
  stub leg-a 18081 raw --status "$case_status" --body-file "$case_body"
  write_config "leg-a|http://127.0.0.1:18081/v1|key-leg-a|" \
               "leg-b|http://127.0.0.1:18082/v1|key-leg-b|"
  gw_start
  stub_touch leg-b
  before=$(log_count)
  req "a5-$case_label" "$RUN/req-basic.json"
  assert_eq      "A5 $case_label the caller sees the leg's status" "$(http_code "a5-$case_label")" "$case_status"
  assert_cmp     "A5 $case_label the body is byte-identical" \
                 "$RUN/a5-$case_label.body" "$case_body"
  assert_eq      "A5 $case_label the fallback was never dialled"   "$(dials leg-b)" "0"
  assert_one_line "A5 $case_label" "$before"
  assert_log_keys "A5 $case_label"
  assert_ts      "A5 $case_label"
  assert_log     "A5 $case_label route is the leg that answered"   '.route' 'leg-a'
  assert_log     "A5 $case_label status"                           '.status' "$case_status"
  assert_log     "A5 $case_label failover_from is empty"           '.failover_from' ''
  assert_log     "A5 $case_label failover_reason is empty"         '.failover_reason' ''
  assert_log_null "A5 $case_label tokens_in are null, not zero"    '.tokens_in'
  assert_log_null "A5 $case_label tokens_out are null, not zero"   '.tokens_out'
  admin_json "$RUN/a5-$case_label.admin.json" >/dev/null
  assert_eq      "A5 $case_label no leg is cooling afterwards" \
                 "$(admin_count "$RUN/a5-$case_label.admin.json" cooling)" "0"
done

gw_stop
kill_stubs
finish
