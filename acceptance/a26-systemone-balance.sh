#!/bin/sh
# A26 — DEC-28: `systemone_balance` is the System One door's own opt-in.
#
# a  off (the default): the walk is config order, whatever the chat door's
#    `balance` says.
# b  on: the first pick is weighted; a 3:1 config serves about three of every
#    four decisions on the heavy leg, and the greedy smooth weighted round-robin
#    makes that exact over a whole number of rounds.
# c  a disabled leg is never picked and never dialled. Its weight is the ceiling
#    and it has a live stub port, so both a pick and a dial would show up.
# d  /admin/config publishes the flag and each share, and still no credential,
#    including from a disabled leg's `user:pass@` base URL.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

req_so() { # req_so <name> — one decision request, same shape a15 sends
  name=$1
  curl -sS -o "$RUN/$name.body" -w '%{http_code}' \
    --max-time 30 -X POST "$GW_URL/v1/systemone" \
    -H 'Content-Type: application/json' \
    -H 'Expect:' \
    -H "Authorization: Bearer $SENTINEL_CLIENT" \
    --data-binary "@$RUN/so-req.json" >"$RUN/$name.code" 2>"$RUN/$name.err" || true
}

so_routes() { # so_routes -> the served route of every logged request, as a sorted tally
  jq -r '.route // ""' "$GW_LOG" 2>/dev/null | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'
}

cat >"$RUN/so-req.json" <<'JSON'
{"state":"Fredi asks: who should answer this message?","model":"jev-latest",
 "questions":{"who":{"type":"choice","instructions":"Pick the bot whose job fits.",
   "criteria":{"Bagas":"lead","Fikri":"backend","Wulan":"docs"},
   "question":"who answers"}}}
JSON

# Two live System One legs and one disabled leg whose base URL carries userinfo.
# The disabled leg is never dialled, so its credential can only leak through
# /admin/config, which is exactly what the last assertion reads.
patch_systemone() { # patch_systemone <systemone_balance true|false> <weight-a> <weight-b> <off-port>
  python3 - "$GW_CFG" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, flag, weight_a, weight_b, off_port = sys.argv[1:6]
cfg = json.load(open(path))
port_a = cfg["legs"][0]["base_url"].split(":")[2].split("/")[0]
port_b = cfg["legs"][1]["base_url"].split(":")[2].split("/")[0]
cfg["systemone_balance"] = flag == "true"
# The chat door balances in both phases, so A26a proves the System One walk
# ignores it.
cfg["balance"] = True
# jev-off points at a live stub port that it must never dial, so the "never
# dialled" assertion has a counter behind it instead of a missing file. It also
# carries userinfo, because a disabled leg's credential can only leak through
# /admin/config.
cfg["systemone"] = {"legs": [
    {"name": "jev-a", "base_url": "http://127.0.0.1:%s/provider/v1" % port_a,
     "api_key": "jev-key-a", "model": "typesafe/jev-1.14.0", "weight": int(weight_a)},
    {"name": "jev-b", "base_url": "http://127.0.0.1:%s/provider/v1" % port_b,
     "api_key": "jev-key-b", "model": "typesafe/jev-1.14.0", "weight": int(weight_b)},
    {"name": "jev-off",
     "base_url": "http://user:s3cret@127.0.0.1:%s/provider/v1" % off_port,
     "api_key": "jev-key-off", "model": "typesafe/jev-1.14.0", "enabled": False,
     "weight": 1000},
]}
json.dump(cfg, open(path, "w"), indent=2)
PY
  chmod 600 "$GW_CFG"
}

gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082; stub_kill leg-off 18083
stub leg-a 18081 systemone-ok --model typesafe/jev-1.14.0
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
stub leg-off 18083 systemone-ok --model typesafe/jev-1.14.0
write_config "leg-a|http://127.0.0.1:18081/v1|key-a|" \
             "leg-b|http://127.0.0.1:18082/v1|key-b|"
off_port=$(port_of 18083)

echo
echo "=== A26a: off is DEC-19, even with the chat door balancing"
patch_systemone false 1 1 "$off_port"
gw_start
stub_touch leg-a; stub_touch leg-b; stub_touch leg-off
: >"$GW_LOG"
n=0
while [ "$n" -lt 10 ]; do
  n=$((n + 1))
  req_so "a26a-$n"
  assert_eq "A26a decision $n answered" "$(cat "$RUN/a26a-$n.code")" "200"
done
assert_eq "A26a off keeps every decision on the first leg" "$(so_routes)" "jev-a=10 "
assert_eq "A26a the second leg was never dialled" "$(dials leg-b)" "0"
assert_eq "A26a the disabled leg's live stub was never dialled" "$(dials leg-off)" "0"

echo
echo "=== A26b: on picks weighted, three to one"
# gw_restart kills every pid this run started, stubs included, so they come back
# on the same resolved ports before the gateway does.
gw_stop; stub_kill leg-a 18081; stub_kill leg-b 18082; stub_kill leg-off 18083
stub leg-a 18081 systemone-ok --model typesafe/jev-1.14.0
stub leg-b 18082 systemone-ok --model typesafe/jev-1.14.0
stub leg-off 18083 systemone-ok --model typesafe/jev-1.14.0
patch_systemone true 3 1 "$off_port"
gw_start
stub_touch leg-a; stub_touch leg-b; stub_touch leg-off
: >"$GW_LOG"
n=0
while [ "$n" -lt 40 ]; do
  n=$((n + 1))
  req_so "a26b-$n"
done
assert_eq "A26b all forty decisions answered" "$(log_count)" "40"
assert_eq "A26b a 3:1 config splits 30:10 over forty decisions" \
  "$(so_routes)" "jev-a=30 jev-b=10 "
assert_eq "A26b both live legs were dialled" \
  "$(dials leg-a):$(dials leg-b)" "30:10"
assert_eq "A26b the disabled leg was never dialled" "$(dials leg-off)" "0"
assert_absent "A26b the disabled leg never appears as a route" "$GW_LOG" "jev-off"

echo
echo "=== A26c: /admin/config publishes the flag and the shares"
assert_eq "A26c the config read is 200" \
  "$(admin_get "$RUN/a26-config.json" /admin/config)" "200"
assert_eq "A26c the flag is published" \
  "$(jq -r '.systemone_balance' "$RUN/a26-config.json")" "true"
assert_eq "A26c the shares are published" \
  "$(jq -r '[.systemone[].weight] | join(",")' "$RUN/a26-config.json")" "3,1,1000"
assert_eq "A26c the disabled leg is reported off" \
  "$(jq -r '[.systemone[] | select(.name=="jev-off") | .enabled] | .[0]' "$RUN/a26-config.json")" "false"
assert_absent "A26c no part of the disabled leg's userinfo is printed" \
  "$RUN/a26-config.json" "s3cret"
assert_absent "A26c no userinfo form is printed at all" \
  "$RUN/a26-config.json" "user:"
# §5.4 after F1j: a credential hides the authority with it, because a credential
# is shaped like a host and every rule that kept the survivor printed one. The
# two clean legs prove the rest of the page still carries its hosts.
assert_present "A26c a credential leg prints no host" \
  "$RUN/a26-config.json" 'http://<redacted>'
assert_absent "A26c not the port either" \
  "$RUN/a26-config.json" "$off_port/provider/v1"
assert_present "A26c a clean leg still prints its host" \
  "$RUN/a26-config.json" "$(jq -r '.legs[0].base_url' "$GW_CFG")"

kill_stubs
finish
