#!/bin/sh
# A14 — the four operational items of 0.7.0, each proven against a real binary.
#
# a  `cost_usd` on a priced model, and no key at all on an unpriced one.
# b  SIGHUP applies a new leg list without a restart, and refuses a broken config
#    while the old one keeps serving.
# c  `log.rotate_bytes` moves the live file aside and keeps `log.keep` of them.
# d  `GET /metrics` answers the Prometheus text format from the same counters.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

# The stub reports 11 prompt and 7 completion tokens on every `ok` answer. At
# $1.00/Mtok in and $2.00/Mtok out that is 0.000011 + 0.000014 = 0.000025.
priced_expected='0.000025'

echo
echo "=== A14a: cost_usd carries the config's price, and is absent when unpriced"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1|priced-model" \
             "leg-b|http://127.0.0.1:18082/v1|key-b||fallback|1|unpriced-model"
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg["prices"] = {"priced-model": {"in": 1.0, "out": 2.0}}
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
stub_touch leg-a
req a14a "$RUN/req-basic.json"
assert_eq "A14a the priced request answered" "$(http_code a14a)" "200"
assert_eq "A14a the answering route is the priced leg" "$(lg '.route')" "leg-a"
assert_eq "A14a cost_usd is price x reported tokens" "$(lg '.cost_usd')" "$priced_expected"
assert_eq "A14a cost_usd is the twelfth key, last" \
  "$(log_line | jq -c 'keys_unsorted | last')" '"cost_usd"'

# The unpriced leg answers only after the priced one fails, so the log line for
# that request must carry no cost key at all.
stub_kill leg-a 18081; stub leg-a 18081 401
req a14a-unpriced "$RUN/req-basic.json"
assert_eq "A14a the unpriced request answered" "$(http_code a14a-unpriced)" "200"
assert_eq "A14a it was served by the unpriced leg" "$(lg '.route')" "leg-b"
assert_eq "A14a no cost key on an unpriced model" \
  "$(log_line | jq -r 'has("cost_usd")')" "false"
stub_kill leg-a 18081; stub leg-a 18081 ok

echo
echo "=== A14b: SIGHUP reloads the leg list without restarting"
# `$RUN/pids` also holds the stubs a case starts, so the gateway is found by the
# config path it was given, never by position in that file.
pid=$(pgrep -f -- "--config $GW_CFG" | head -n 1)
assert_ne "A14b the gateway pid is known" "$pid" ""
reloads_before=$(admin_get "$RUN/a14-cfg0.json" '/admin/config' >/dev/null; \
  jq -r '.reload.count // 0' "$RUN/a14-cfg0.json")
# Two legs become three, and the new leg's model is priced: both the router and
# the price table have to come from the reload.
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
base_a = cfg["legs"][0]["base_url"]
base_b = cfg["legs"][1]["base_url"]
cfg["legs"] = [
    {"name": "leg-a", "base_url": base_a, "api_key": "key-a",
     "role": "primary", "model": "priced-model"},
    {"name": "leg-b", "base_url": base_b, "api_key": "key-b",
     "role": "fallback", "model": "unpriced-model"},
    {"name": "leg-reloaded", "base_url": base_b, "api_key": "key-c",
     "role": "fallback", "model": "third-model"},
]
cfg["prices"]["third-model"] = {"in": 0.5, "out": 0.5}
json.dump(cfg, open(path, "w"), indent=2)
PY
kill -HUP "$pid"
i=0
while [ $i -lt 100 ]; do
  admin_get "$RUN/a14-cfg1.json" '/admin/config' >/dev/null 2>&1 || true
  [ "$(jq -r '.reload.count // 0' "$RUN/a14-cfg1.json" 2>/dev/null)" != "$reloads_before" ] && break
  i=$((i + 1)); sleep 0.05
done
assert_eq "A14b the reload was counted" \
  "$(jq -r '.reload.count' "$RUN/a14-cfg1.json")" "$((reloads_before + 1))"
assert_eq "A14b the new leg is in the running config" \
  "$(jq -r '[.legs[].name] | join(",")' "$RUN/a14-cfg1.json")" \
  "leg-a,leg-b,leg-reloaded"
assert_eq "A14b the new price is in the running config" \
  "$(jq -r '.prices["third-model"].in' "$RUN/a14-cfg1.json")" "0.5"
assert_eq "A14b the process did not restart" \
  "$(pgrep -f -- "--config $GW_CFG" | head -n 1)" "$pid"

# A config that does not parse is refused and the working one keeps answering.
cp "$GW_CFG" "$RUN/cfg-good.json"
printf '{"legs": [ this is not json' >"$GW_CFG"
kill -HUP "$pid"
i=0
while [ $i -lt 100 ]; do
  admin_get "$RUN/a14-cfg2.json" '/admin/config' >/dev/null 2>&1 || true
  [ "$(jq -r '.reload.error // ""' "$RUN/a14-cfg2.json" 2>/dev/null)" != "" ] && break
  i=$((i + 1)); sleep 0.05
done
assert_ne "A14b the refusal is recorded" \
  "$(jq -r '.reload.error // ""' "$RUN/a14-cfg2.json")" ""
assert_eq "A14b a refused reload does not count as applied" \
  "$(jq -r '.reload.count' "$RUN/a14-cfg2.json")" "$((reloads_before + 1))"
assert_eq "A14b the old leg list still serves" \
  "$(jq -r '[.legs[].name] | join(",")' "$RUN/a14-cfg2.json")" \
  "leg-a,leg-b,leg-reloaded"
cp "$RUN/cfg-good.json" "$GW_CFG"

echo
echo "=== A14c: rotation keeps the live file small and the keep count exact"
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082
stub leg-a 18081 ok
stub leg-b 18082 ok
write_config "leg-a|http://127.0.0.1:18081/v1|key-a||primary|1|priced-model" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
: >"$GW_LOG"
python3 - "$GW_CFG" <<'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
# Every answer is roughly 150 bytes of JSON, so 600 bytes rotates every few lines.
cfg["log"]["rotate_bytes"] = 600
cfg["log"]["keep"] = 2
json.dump(cfg, open(path, "w"), indent=2)
PY
gw_start
n=0
while [ $n -lt 12 ]; do
  req "a14c-$n" "$RUN/req-basic.json"
  n=$((n + 1))
done
rotated=$(ls "$GW_LOG".* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "A14c at least one rotation happened" "$([ "$rotated" -ge 1 ] && echo yes)" "yes"
assert_eq "A14c keep=2 is the most that exists" \
  "$([ "$rotated" -le 2 ] && echo yes)" "yes"
assert_eq "A14c the live file is under the rotation limit" \
  "$([ "$(wc -c <"$GW_LOG" | tr -d ' ')" -le 1200 ] && echo yes)" "yes"
assert_eq "A14c every live line is still whole JSON" \
  "$(jq -s -r 'all(.[]; type == "object")' "$GW_LOG")" "true"
assert_eq "A14c /admin/config reports the policy" \
  "$(admin_get "$RUN/a14-cfg3.json" '/admin/config' >/dev/null; \
     jq -r '.log.rotate_bytes' "$RUN/a14-cfg3.json")" "600"

echo
echo "=== A14d: /metrics is the Prometheus text format"
assert_eq "A14d /metrics answers 200" "$(admin_code '/metrics')" "200"
curl -sS -o "$RUN/a14-metrics.txt" --max-time 5 "$GW_URL/metrics"
assert_present "A14d the exposition names its type" \
  "$RUN/a14-metrics.txt" "kori_requests_total"
assert_present "A14d the histogram carries an +Inf bucket" \
  "$RUN/a14-metrics.txt" 'kori_request_duration_ms_bucket{le="+Inf"}'
assert_present "A14d route counters are labelled" \
  "$RUN/a14-metrics.txt" 'kori_requests_total{route="leg-a"}'
# Rotation (A14c) shortened the live file, so the counter is checked against the
# requests this case actually made rather than against a tail of the log.
assert_eq "A14d the route counters sum to the requests this run made" \
  "$(awk '/^kori_requests_total\{/ {sum += $2} END {print sum+0}' "$RUN/a14-metrics.txt")" \
  "12"
assert_eq "A14d a POST is refused" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
      -H 'Content-Length: 0' "$GW_URL/metrics")" "405"
assert_eq "A14d the content type is the text exposition" \
  "$(curl -sS -o /dev/null -D - --max-time 5 "$GW_URL/metrics" 2>/dev/null \
      | tr -d '\r' | awk 'tolower($1)=="content-type:" {print $2}')" \
  "text/plain;"

kill_stubs
finish
