#!/bin/sh
# A25 — DEC-27: the rollback the runbook promises, rehearsed.
#
# A dashboard write leaves config.json.bak holding the exact bytes the file had
# before the write. Putting those bytes back and sending SIGHUP returns the
# gateway to the file's own switches with no restart: the listener and the
# started_at stamp stay, only the reload counter moves.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

jq -c --arg p "$SENTINEL_PROMPT" '.messages[0].content = $p' \
   "$ACC_DIR/fixtures/request-basic.json" >"$RUN/req-basic.json"

put_overrides() { # put_overrides <outfile> <json>
  curl -sS -o "$1" -w '%{http_code}' --max-time 5 -X PUT \
    -H 'Content-Type: application/json' -H "$(admin_write_header)" \
    --data-binary "$2" "$GW_URL/admin/overrides"
}

gw_stop; stub_kill leg-a 18086; stub_kill leg-b 18085
stub leg-a 18086 ok
stub leg-b 18085 ok
write_config "leg-a|http://127.0.0.1:18086/v1|key-leg-a|" \
             "leg-b|http://127.0.0.1:18085/v1|key-leg-b|"
gw_start
started_before=$(curl -sS --max-time 5 -H "$(admin_token_header)" \
  "$GW_URL/admin/state" | jq -r '.gateway.started_at')
cp "$GW_CFG" "$RUN/before-write.json"
before_mode=$(file_mode "$GW_CFG")

echo "=== A25: switch a provider off, then roll the file back and reload"
assert_eq "A25 the config starts at $before_mode" "$before_mode" "600"
assert_eq "A25 switching leg-b off is 200" \
  "$(put_overrides "$RUN/a25-off.json" '{"legs":{"leg-b":false}}')" "200"
admin_get "$RUN/a25-after-write.json" /admin/config >/dev/null
assert_eq "A25 the write is live" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .serving' "$RUN/a25-after-write.json")" "false"

# The backup is the pre-write file, byte for byte, and it is 0600 like the file.
assert_eq "A25 a .bak was written beside the config" \
  "$(test -f "$GW_CFG.bak" && echo yes)" "yes"
assert_eq "A25 the .bak is the pre-write bytes" \
  "$(cmp -s "$GW_CFG.bak" "$RUN/before-write.json" && echo same)" "same"
assert_eq "A25 the .bak is 0600" "$(file_mode "$GW_CFG.bak")" "600"

# The operator's rollback: put the bytes back, keep the mode, reload.
cp "$GW_CFG.bak" "$GW_CFG"
chmod 600 "$GW_CFG"
reloads_before=$(curl -sS --max-time 5 -H "$(admin_token_header)" \
  "$GW_URL/admin/config" | jq -r '.reload.count')
gw_hup

n=0
while [ "$n" -lt 100 ]; do
  admin_get "$RUN/a25-after-hup.json" /admin/config >/dev/null
  if [ "$(jq -r '.reload.count' "$RUN/a25-after-hup.json")" -gt "$reloads_before" ]; then break; fi
  n=$((n + 1)); sleep 0.05
done
assert_eq "A25 the reload counter moved" \
  "$(jq -r --argjson b "$reloads_before" '.reload.count > $b' "$RUN/a25-after-hup.json")" "true"
assert_eq "A25 the reload reported no error" \
  "$(jq -r '.reload.error // ""' "$RUN/a25-after-hup.json")" ""
assert_eq "A25 the gateway did not restart" \
  "$(curl -sS --max-time 5 -H "$(admin_token_header)" "$GW_URL/admin/state" | jq -r '.gateway.started_at')" \
  "$started_before"
assert_eq "A25 leg-b serves again after the rollback" \
  "$(jq -r '.legs[] | select(.name=="leg-b") | .serving' "$RUN/a25-after-hup.json")" "true"
assert_eq "A25 the override block is gone from the running config" \
  "$(jq -r '.overrides.legs | length' "$RUN/a25-after-hup.json")" "0"
assert_eq "A25 the override block is gone from the file" \
  "$(jq -r 'has("overrides")' "$GW_CFG")" "false"
assert_eq "A25 the file is still 0600" "$(file_mode "$GW_CFG")" "600"

gw_stop
kill_stubs
finish
