#!/bin/sh
# shellcheck disable=SC2034  # the sentinels, deadlines and tolerances below are read by the case scripts
# kori v1 acceptance harness. POSIX sh. Source it, do not run it.
#
#   KORI_BIN=./apps/api/src/kori sh acceptance/run-all.sh
#
# Every fixture is local: a stub on 127.0.0.1, a locally closed port, or an
# unroutable address. No case reads a real provider, so no case depends on the
# Go quota or on any live model answer (SPEC-gateway-nim.md §9).
#
# Nothing here is pinned to this machine: the binary is KORI_BIN, the ports are
# aliases resolved to free ones per run, and everything a run writes lands in one
# temp directory that a green run removes.
#
# Four couplings to the build are deliberately isolated, each in one place:
#   write_config()         the fixture config file  (OPEN-2)
#   gw_start()             the binary's CLI flags   (OPEN-3)
#   admin_json()           how /admin/state is fetched (D7)
#   admin_token_fixture()  the admin gate's token file and header (DEC-20)
# Nothing else in the suite knows a path, a flag name or a config key name.

ACC_DIR=${ACC_DIR:-$(cd "$(dirname "$0")" && pwd)}
# Everything a run writes lives in this one directory and goes away with it, so
# a run leaves the tree exactly as it found it. RUN_KEEP=1 keeps it on a green
# run when you want the artifacts.
RUN=${RUN:-$(mktemp -d "${TMPDIR:-/tmp}/kori-acc-XXXXXX")}
mkdir -p "$RUN"
RUN_KEEP=${RUN_KEEP:-0}

# The binary comes from KORI_BIN (what ./task nim and CI set), then GW_BIN, then
# the build product in this checkout. No case has a path baked in.
GW_BIN=${GW_BIN:-${KORI_BIN:-$ACC_DIR/../apps/api/src/kori}}
export GW_BIN
GW_HOST=${GW_HOST:-127.0.0.1}
GW_PORT=${GW_PORT:-4011}
GW_URL=${GW_URL:-http://$GW_HOST:$GW_PORT}
GW_CFG=${GW_CFG:-$RUN/kori-acceptance.json}
GW_LOG=${GW_LOG:-$RUN/gateway.jsonl}

# Values the gateway must never write to the log (D6, SPEC §5).
SENTINEL_CLIENT="sk-acc-SENTINEL-client-key"
SENTINEL_LEG="acc-SENTINEL-session"
SENTINEL_PROMPT="SENTINEL-PROMPT-do-not-log"
# A credential value planted in the fixture config, so /admin/config can be
# shown to redact what it was given (DASHBOARD-surface.md §5.4).
SENTINEL_CFG_SECRET="sk-acc-SENTINEL-config-credential"

# D2 deadlines, milliseconds.
D2_CONNECT_MS=2000
D2_TLS_MS=3000
D2_HDR_STREAM_MS=15000
# D-2: the streaming first-byte window is a floor plus a slope on the outbound
# body. The floor is what a short prompt still gets, which is why A3b measures it.
D2_HDR_STREAM_SLOPE_MS_PER_KIB=100
D2_HDR_STREAM_MAX_MS=60000
D2_HDR_NONSTREAM_MS=90000
D2_CHUNK_IDLE_MS=120000
D2_TOTAL_NONSTREAM_MS=300000

# Named tolerances (see ACCEPTANCE-v1.md, "Tolerances").
TOL_CONNECT_OVER_MS=600
TOL_CONNECT_UNDER_MS=400
TOL_TLS_OVER_MS=1000
TOL_TLS_UNDER_MS=200
TOL_HDR_STREAM_OVER_MS=2500
TOL_HDR_STREAM_UNDER_MS=1500
TOL_HDR_NONSTREAM_OVER_MS=5000
TOL_HDR_NONSTREAM_UNDER_MS=1500
TOL_COOLDOWN_S=5

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }
note() { printf 'note  %s\n' "$1"; }

finish() {
  if [ "$FAILED" -eq 0 ]; then
    printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
  else
    printf '\n%d passed, %d failed  (artifacts kept: %s)\n' "$PASSED" "$FAILED" "$RUN"
  fi
  [ "$FAILED" -eq 0 ] || exit 1
}

# One exit path: whatever a case left running is killed, and a green run takes its
# temp directory with it. A red run keeps the directory and finish() named it.
harness_exit() {
  if [ -f "$RUN/pids" ]; then
    while read -r _exit_pid; do kill "$_exit_pid" 2>/dev/null; done <"$RUN/pids"
    : >"$RUN/pids"
  fi
  if [ "$FAILED" -eq 0 ] && [ "$RUN_KEEP" != "1" ]; then rm -rf "$RUN"; fi
}
trap harness_exit EXIT

assert_eq() { # label actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$3] got [$2]"; fi
}

assert_ne() { # label actual forbidden
  if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "must not be [$3]"; fi
}

assert_between() { # label value lo hi
  awk -v v="$2" -v lo="$3" -v hi="$4" -v l="$1" 'BEGIN {
    if (v == "" ) { printf "FAIL  %s :: empty value\n", l; exit 1 }
    if (v + 0 < lo || v + 0 > hi) { printf "FAIL  %s :: %s not in [%s, %s]\n", l, v, lo, hi; exit 1 }
    printf "PASS  %s :: %s in [%s, %s]\n", l, v, lo, hi
  }' && PASSED=$((PASSED + 1)) || FAILED=$((FAILED + 1))
}

assert_absent() { # label file-or-log needle
  if grep -q -- "$3" "$2" 2>/dev/null; then fail "$1" "found [$3] in $2"; else pass "$1"; fi
}

assert_present() { # label file needle
  if grep -q -- "$3" "$2" 2>/dev/null; then pass "$1"; else fail "$1" "missing [$3] in $2"; fi
}

assert_cmp() { # label actual-file expected-file
  if cmp -s "$2" "$3"; then pass "$1"; else
    fail "$1" "bytes differ: $(cmp "$2" "$3" 2>&1 | head -1)"
  fi
}

# ------------------------------------------------------------------- ports ---
# A case names a port as a stable alias (18081, 18091, 4011). The number it
# actually binds is a free port the kernel hands out for this run, kept in
# $RUN/port-<alias>. Two runs back to back therefore never want the same number:
# a fixed port was what made a3 flake, because gw_stop's 0.2 s is not a promise
# that the previous listener has released it.

free_port() {
  python3 - "$RUN/ports-used" <<'PY'
import socket, sys
used_path = sys.argv[1]
try:
    used = set(int(x) for x in open(used_path).read().split())
except OSError:
    used = set()
for _ in range(50):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    finally:
        s.close()
    if port not in used:
        with open(used_path, "a") as fh:
            fh.write("%d\n" % port)
        print(port)
        sys.exit(0)
sys.exit(1)
PY
}

port_of() { # port_of <alias> -> the free port this run binds for that alias
  _port_alias=$1
  _port_file="$RUN/port-$_port_alias"
  if [ ! -f "$_port_file" ]; then
    _port_value=$(free_port) || return 1
    printf '%s' "$_port_value" >"$_port_file"
  fi
  cat "$_port_file"
}

file_mode() { # file_mode <path> -> the permission bits as octal, on BSD and GNU
  case $(uname -s) in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

# ---------------------------------------------------------------- fixtures ---

wait_tcp() { # port [tries]
  python3 - "$1" "${2:-100}" <<'PY'
import socket, sys, time
port, tries = int(sys.argv[1]), int(sys.argv[2])
for _ in range(tries):
    s = socket.socket(); s.settimeout(0.3)
    try:
        s.connect(("127.0.0.1", port)); s.close(); sys.exit(0)
    except OSError:
        time.sleep(0.05)
    finally:
        s.close()
sys.exit(1)
PY
}

expect_closed() { # port-alias
  python3 - "$(port_of "$1")" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(); s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", port)); sys.exit(1)
except ConnectionRefusedError:
    sys.exit(0)
except OSError:
    sys.exit(0)
finally:
    s.close()
PY
}

stub() { # stub <label> <port-alias> <mode> [extra stub args...]
  label=$1; mode=$3; port=$(port_of "$2"); shift 3
  : >"$RUN/$label.count"
  ( python3 "$ACC_DIR/stub.py" --port "$port" --mode "$mode" \
      --count-file "$RUN/$label.count" --capture-file "$RUN/$label.req" "$@" \
      >>"$RUN/stub-$label.log" 2>&1 &
    echo "$!" >>"$RUN/pids"
    echo "$!" >"$RUN/$label.pid" )
  wait_tcp "$port" 200 || { fail "stub $label" "did not listen on $port"; return 1; }
  stub_touch "$label"
  note "stub $label mode=$mode port=$port"
}

stub_kill() { # stub_kill <label> [port-alias]  -> frees the port before the next stub binds it
  if [ -f "$RUN/$1.pid" ]; then
    kill "$(cat "$RUN/$1.pid")" 2>/dev/null
    rm -f "$RUN/$1.pid"
  fi
  [ -n "${2:-}" ] || return 0
  i=0
  while [ $i -lt 100 ]; do
    expect_closed "$2" && return 0
    i=$((i + 1)); sleep 0.05
  done
  fail "stub_kill $1" "port $2 still open"
}

stub_touch() { # label  -> reset the dial counter so a case counts its own dials
  : >"$RUN/$1.count"
}

dials() { # label  -> how many times that leg was dialled since the reset
  if [ -f "$RUN/$1.count" ]; then wc -l <"$RUN/$1.count" | tr -d ' '; else echo 0; fi
}

kill_stubs() {
  if [ -f "$RUN/pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null; done <"$RUN/pids"
    : >"$RUN/pids"
  fi
}

write_config() { # write_config "name|base_url|api_key|header:value[|role[|weight[|model[|retries[|api_keys]]]]]" ...
  # D12: `balance` (top level) and per-leg `role` and `weight` are written only when
  # a case asks for them, so A1 to A10 keep the fixture shape they were proved on and
  # A11 is the one block that carries the new keys. GW_BALANCE=true turns balancing on.
  #
  # A13 adds two more optional trailing fields, both of which stay absent unless a
  # case names them: `retries` (an integer) and `api_keys` (comma-separated).
  #
  # Every leg's port is an alias: allocate it here whether or not a stub will bind
  # it, so a leg the case leaves dead points at a port that is really free.
  : >"$RUN/cfg-specs"
  for _cfg_spec in "$@"; do
    _cfg_alias=$(printf '%s' "$_cfg_spec" | awk -F'|' '{print $2}' \
      | sed -n 's|.*://[^:/]*:\([0-9][0-9]*\).*|\1|p')
    if [ -n "$_cfg_alias" ]; then
      _cfg_real=$(port_of "$_cfg_alias")
      _cfg_spec=$(printf '%s' "$_cfg_spec" | sed "s|:$_cfg_alias/|:$_cfg_real/|")
    fi
    printf '%s\n' "$_cfg_spec" >>"$RUN/cfg-specs"
  done
  set --
  while IFS= read -r _cfg_line; do set -- "$@" "$_cfg_line"; done <"$RUN/cfg-specs"
  python3 - "$GW_CFG" "$GW_HOST" "$GW_PORT" "$GW_LOG" "${GW_BALANCE:-}" "$@" <<'PY'
import json, sys
path, host, port, log, balance, *legs = sys.argv[1:]
cfg = {
    "listen": {"host": host, "port": int(port)},
    "log": {"path": log},
    "legs": [],
}
if balance:
    cfg["balance"] = balance in ("1", "true", "yes")
for spec in legs:
    parts = spec.split("|")
    leg = {"name": parts[0], "base_url": parts[1], "api_key": parts[2], "headers": {}}
    if len(parts) > 3 and parts[3]:
        k, v = parts[3].split(":", 1)
        leg["headers"][k] = v
    if len(parts) > 4 and parts[4]:
        leg["role"] = parts[4]
    if len(parts) > 5 and parts[5]:
        leg["weight"] = int(parts[5])
    if len(parts) > 6 and parts[6]:
        leg["model"] = parts[6]
    if len(parts) > 7 and parts[7]:
        leg["retries"] = int(parts[7])
    if len(parts) > 8 and parts[8]:
        leg["api_keys"] = [k for k in parts[8].split(",") if k]
        del leg["api_key"]
    cfg["legs"].append(leg)
json.dump(cfg, open(path, "w"), indent=2)
PY
  chmod 600 "$GW_CFG"
}

# DEC-20: the admin surface reads its shared token from the file named by
# KORI_ADMIN_TOKEN_FILE. `gw_start` writes one fixed test value into $RUN and
# points the binary at it, so every case that reads /admin/state keeps working
# now that the path is gated, and no case has to know the header format.
#
# A case that wants the fail-closed path (file missing → 404) sets
# ADMIN_TOKEN_FILE to a path it never creates together with ADMIN_TOKEN_WRITE=0.
ADMIN_TOKEN_VALUE="acc-TEST-admin-token-SENTINEL-do-not-log"
ADMIN_COOKIE_NAME="kori_admin"

admin_token_path() { printf '%s' "${ADMIN_TOKEN_FILE:-$RUN/admin.token}"; }

admin_token_write() { # write the fixture token file: mode 0600, one trailing newline (the gate trims it)
  _atp=$(admin_token_path)
  printf '%s\n' "$ADMIN_TOKEN_VALUE" >"$_atp"
  chmod 600 "$_atp"
}

admin_token_header() { printf 'Authorization: Bearer %s' "$ADMIN_TOKEN_VALUE"; }

# A log the dashboard can page over with no request going anywhere. Called before
# gw_start(), so the file is already its full length when the binary opens it.
seed_log() { # seed_log <count> [route] [status]
  python3 - "$GW_LOG" "${1:-60}" "${2:-leg-b}" "${3:-200}" <<'PY'
import datetime, json, sys
path, count, route, status = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
rows = []
for i in range(count):
    rows.append({
        "ts": (now - datetime.timedelta(seconds=count - 1 - i)).isoformat(),
        "route": route, "status": status, "latency_ms": 100 + i,
        "tokens_in": 10, "tokens_out": 5, "failover_from": "",
        "failover_reason": "", "stream": False,
    })
with open(path, "w") as fh:
    for row in rows:
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
}

gw_start() {
  if [ ! -x "$GW_BIN" ]; then fail "gw_start" "no executable at $GW_BIN"; return 1; fi
  # DEC-20: one fixture token file per run, written here so a case never has to.
  # ADMIN_TOKEN_WRITE=0 leaves the path absent, which is the fail-closed case.
  if [ "${ADMIN_TOKEN_WRITE:-1}" = "1" ]; then admin_token_write; fi
  # A fresh port on every start. gw_stop's 0.2 s is not a promise that the last
  # listener has released the old number, and a3 starts the gateway three times.
  GW_PORT=$(free_port) || { fail "gw_start" "no free port on loopback"; return 1; }
  GW_URL="http://$GW_HOST:$GW_PORT"
  # --port overrides listen.port; keep the config honest about which port it is,
  # so /admin/config reports the listener that is really up (A10e reads it).
  python3 - "$GW_CFG" "$GW_PORT" <<'PY'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
cfg = json.load(open(path))
cfg.setdefault("listen", {})["port"] = port
json.dump(cfg, open(path, "w"), indent=2)
PY
  # GW_FSIZE_BLOCKS caps how large any file this process writes may grow, which is
  # how a18 makes a log write fail on purpose: a write past the limit comes back
  # short. The signal is ignored first, or the kernel would kill the gateway
  # instead of letting write(2) answer. Both are inherited by the exec.
  ( if [ -n "${GW_FSIZE_BLOCKS:-}" ]; then
      trap '' XFSZ
      ulimit -f "$GW_FSIZE_BLOCKS" || fail "gw_start" "cannot set a file size limit"
    fi
    KORI_ADMIN_TOKEN_FILE=$(admin_token_path) \
    "$GW_BIN" --config "$GW_CFG" --port "$GW_PORT" >>"$RUN/gateway.log" 2>&1 &
    echo "$!" >>"$RUN/pids" )
  gw_wait_ready || { fail "gw_start" "no answer from $GW_URL/healthz"; return 1; }
  note "gateway up on $GW_URL"
}

gw_wait_ready() {
  # /healthz is the one path the admin gate never covers, so readiness does not
  # depend on the token fixture being right.
  i=0
  while [ $i -lt 200 ]; do
    if curl -sS -o /dev/null --max-time 1 "$GW_URL/healthz" 2>/dev/null; then return 0; fi
    i=$((i + 1)); sleep 0.05
  done
  return 1
}

gw_stop() {
  if [ -f "$RUN/pids" ]; then
    while read -r p; do kill "$p" 2>/dev/null; done <"$RUN/pids"
    : >"$RUN/pids"
  fi
  sleep 0.2
}

admin_json() { # admin_json <outfile>
  # DEC-20: /admin/state is gated. The suite always presents the fixture token,
  # so an admin case tests the surface behind the gate, not the gate itself.
  curl -sS -o "$1" -w '%{http_code}' --max-time 5 \
    -H "$(admin_token_header)" "$GW_URL/admin/state"
}

# The dashboard's other two reads are `/admin/log` and `/admin/config`. Their
# field-level shapes come from DASHBOARD-surface.md §5, not from a numbered
# decision yet (D11 is pending), so the readers below are the one place a shape
# change touches (OPEN-10).
admin_get() { # admin_get <outfile> <path-with-query> -> http code
  curl -sS -o "$1" -w '%{http_code}' --max-time 5 \
    -H "$(admin_token_header)" "$GW_URL$2"
}

admin_code() { # admin_code <path> -> http code, body discarded
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "$(admin_token_header)" "$GW_URL$1"
}

# A write with no body still declares one: without Content-Length (and without
# chunked framing) the HTTP layer answers 411 before the handler runs, as nginx
# does. ACCEPTANCE-v1.md records that as a deviation; A8b and A10f send this.
# The token is presented so the case proves the method rule, not the gate.
admin_post_code() { # admin_post_code <path> -> http code of a POST, body discarded
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H "$(admin_token_header)" \
    -H 'Content-Length: 0' "$GW_URL$1"
}

admin_post_allow() { # admin_post_allow <path> -> the Allow header of a refused POST
  curl -sS -o /dev/null -D - --max-time 5 -X POST \
    -H "$(admin_token_header)" \
    -H 'Content-Length: 0' "$GW_URL$1" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1) == "allow:" { $1 = ""; sub(/^ /, ""); print }'
}

# Ungated reads are requested without a token on purpose, so a case can prove a
# surface stays open (/healthz) and that the gate does not cover it.
open_code() { # open_code <path> -> http code with no credential at all
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$GW_URL$1"
}

# ---------------------------------------------------------------- the gate ---
# DEC-20 readers. A case asks these instead of building curl lines, so the
# header name, the cookie name and the login path each live in this one block.
gate_code() { # gate_code <method> <path> [curl args...] -> http code, body discarded
  _gc_method=$1; _gc_path=$2; shift 2
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X "$_gc_method" \
    -H 'Content-Length: 0' "$@" "$GW_URL$_gc_path"
}

gate_gen() { # gate_gen <outfile> <path> [curl args...] -> http code; headers in <outfile>.head
  _gg_out=$1; _gg_path=$2; shift 2
  curl -sS -o "$_gg_out" -D "$_gg_out.head" -w '%{http_code}' --max-time 5 \
    -H 'Content-Length: 0' "$@" "$GW_URL$_gg_path"
}

gate_header() { # gate_header <head-file> <name> -> every value of that header, comma-joined
  tr -d '\r' <"$1" | awk -v want="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" \
    'index(tolower($1), want ":") == 1 { sub(/^[^:]*: */, ""); if (out != "") out = out ", "; out = out $0 }
     END { print out }'
}

gate_cookie_value() { # gate_cookie_value <head-file> -> the kori_admin value a Set-Cookie set
  tr -d '\r' <"$1" | awk -v n="$ADMIN_COOKIE_NAME" '
    index(tolower($1), "set-cookie:") == 1 {
      sub(/^[^:]*: */, ""); split($0, parts, ";")
      split(parts[1], pair, "=")
      if (pair[1] == n) { print pair[2]; exit }
    }'
}

gate_login() { # gate_login <outfile> <token> -> http code of a session login
  _gl_out=$1; _gl_token=$2
  curl -sS -o "$_gl_out" -D "$_gl_out.head" -w '%{http_code}' --max-time 5 \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "{\"token\":\"$_gl_token\"}" "$GW_URL/session/login"
}

gate_logout() { # gate_logout <outfile> <cookie> -> http code of a session logout
  _lo_out=$1; _lo_cookie=$2
  curl -sS -o "$_lo_out" -D "$_lo_out.head" -w '%{http_code}' --max-time 5 \
    -X POST -H 'Content-Length: 0' --cookie "$ADMIN_COOKIE_NAME=$_lo_cookie" \
    "$GW_URL/session/logout"
}

# The 404 the contract names for a gateway with no token: not an auth answer at
# all, the standard not-found body.
assert_not_found_body() { # label json-or-body-file
  body=$(cat "$2" 2>/dev/null)
  case "$body" in
    *not_found*|*"not found"*|"") pass "$1" ;;
    *) fail "$1" "a 404 should carry the standard not-found body, got [$body]" ;;
  esac
}

# /admin/state shape is not fixed by D7. These helpers find the per-leg objects
# wherever they are nested, so a change of shape touches this one block (OPEN-3).
ADMIN_LEGS_JQ='[paths(objects) as $p
  | getpath($p)
  | select(type=="object" and has("state") and has("cooling_until") and has("last_failure_class"))
  | {key: (.name // ($p | map(tostring) | last)), o: .}]'

admin_legs() { jq "$ADMIN_LEGS_JQ" "$1"; }
admin_count() { jq "$ADMIN_LEGS_JQ"' | map(select(.o.state==$s)) | length' --arg s "$2" "$1"; }
admin_cooling_keys() { jq -r "$ADMIN_LEGS_JQ"' | map(select(.o.state=="cooling") | .key) | @csv' "$1"; }
admin_field() { jq -r "$ADMIN_LEGS_JQ"' | map(select(.key==$k) | .o[$f]) | .[0]' --arg k "$2" --arg f "$3" "$1"; }

cooling_delta_s() { # seconds from now until an ISO-8601 timestamp, or a word when unusable
  python3 - "$1" <<'PY'
import datetime, sys
raw = sys.argv[1]
try:
    d = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
except Exception:
    print("unparsable"); sys.exit(0)
if d.tzinfo is None:
    print("no-offset"); sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
print(round((d - now).total_seconds()))
PY
}

gw_restart() { gw_stop; sleep 0.3; gw_start; }

# D9 point 5 and 6: the page carries one window of two counters (availability and
# capacity), both counting requests under the class of the first failover, plus a
# last-20 event list. Key names are still OPEN-3; these readers match on the words,
# not on exact spelling.
WINDOW_JQ='[paths(objects) as $p
  | getpath($p)
  | select((keys | map(ascii_downcase | test("avail")) | any)
           and (keys | map(ascii_downcase | test("capac")) | any))][0] // {}'

EVENTS_JQ='[paths(arrays) as $p
  | getpath($p)
  | select((length > 0) and (length <= 20)
           and (all(.[]; type == "object"
                          and (has("ts") or has("time") or has("at")))))][0] // []'

window_counter() { # window_counter <admin-file> <avail|capac>
  jq -r --arg c "$2" "$WINDOW_JQ"'
    | to_entries
    | map(select(.key | ascii_downcase | test($c)))
    | .[0].value // "absent"' "$1"
}

window_delta() { # window_delta <before-file> <after-file> <avail|capac>
  awk -v a="$(window_counter "$1" "$3")" -v b="$(window_counter "$2" "$3")" 'BEGIN {
    if (a == "absent" || b == "absent") { print "absent"; exit }
    print b - a
  }'
}

window_events() { jq -c "$EVENTS_JQ" "$1"; }

window_event_hits() { # window_event_hits <admin-file> <token> -> events naming that token
  jq -r --arg t "$2" "$EVENTS_JQ"' | map(select(tostring | contains($t))) | length' "$1"
}

# /admin/log readers (OPEN-10). `rows` is the only array the endpoint promises;
# everything else is read by key and reported as "absent" rather than guessed.
ADMIN_LOG_ROWS_JQ='.rows // []'

log_rows() { jq -c "$ADMIN_LOG_ROWS_JQ" "$1"; }
log_row_count() { jq -r "($ADMIN_LOG_ROWS_JQ) | length" "$1"; }
log_row() { # log_row <json-file> <index> <key, leading dot optional>
  k=${3#.}
  jq -r --argjson i "${2:-0}" --arg k "$k" "($ADMIN_LOG_ROWS_JQ) | .[\$i] | .[\$k]" "$1"
}
log_meta() { jq -r ".[\"$2\"] // \"absent\"" "$1"; }
log_scan() { jq -r ".scan[\"$2\"] // \"absent\"" "$1"; }

# One line each, so selftest.sh can prove every one of them fires both ways.
assert_log_page_fits() { # label json-file expected-limit
  f=$2; want=$3
  n=$(log_row_count "$f" 2>/dev/null)
  lim=$(log_meta "$f" limit)
  case "$n" in ''|*[!0-9]*) fail "$1" "rows is not an array of known length"; return;; esac
  [ "$lim" = "absent" ] && { fail "$1" "the response carries no limit"; return; }
  [ "$n" -le "$want" ] || { fail "$1" "$n rows for a page asked for $want"; return; }
  [ "$n" -le "$lim" ] || { fail "$1" "$n rows exceeds the limit it reports ($lim)"; return; }
  [ "$lim" = "$want" ] || { fail "$1" "limit reports $lim, asked $want"; return; }
  pass "$1"
}

assert_tail_scan() { # label json-file expected-limit  (D8: a page is a tail)
  f=$2; lim=$3
  total=$(jq -r '.file.lines // "absent"' "$f" 2>/dev/null)
  scanned=$(log_scan "$f" lines_scanned)
  case "$total$scanned" in
    *[!0-9]*) fail "$1" "file.lines or scan.lines_scanned is missing"; return;;
  esac
  if [ "$total" -gt "$lim" ] && [ "$scanned" -ge "$total" ]; then
    fail "$1" "$total lines in the file, $scanned scanned for a $lim-row page"
  else
    pass "$1"
  fi
}

assert_no_credential() { # label json-file secret [fragment-length, default 12]
  f=$2; s=$3; n=${4:-12}
  if [ -n "$s" ] && grep -qF -- "$s" "$f"; then
    fail "$1" "the full credential value is in the payload"; return
  fi
  frag=$(printf '%s' "$s" | cut -c1-"$n")
  if [ -z "$frag" ] || [ "$frag" = "$s" ]; then pass "$1"; return; fi
  if grep -qF -- "$frag" "$f"; then
    fail "$1" "a fragment of the credential is in the payload: $frag"; return
  fi
  pass "$1"
}


# ---------------------------------------------------------------- requests ---

# req <name> <body-file> [extra curl args...]
# Sets: $RUN/<name>.code (http code), $RUN/<name>.time (seconds), $RUN/<name>.body, $RUN/<name>.head
req() {
  name=$1; body=$2; shift 2
  curl -sS -D "$RUN/$name.head" -o "$RUN/$name.body" -w '%{http_code} %{time_total}' \
    --max-time 400 -X POST "$GW_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H 'Expect:' \
    -H "Authorization: Bearer $SENTINEL_CLIENT" \
    --data-binary "@$body" "$@" >"$RUN/$name.code" 2>"$RUN/$name.err" || true
  note "req $name http=$(cut -d' ' -f1 "$RUN/$name.code") t=$(cut -d' ' -f2 "$RUN/$name.code")"
}

http_code() { cut -d' ' -f1 "$RUN/$1.code"; }
http_time() { cut -d' ' -f2 "$RUN/$1.code"; }

# --------------------------------------------------------------------- log ---

log_count() { if [ -f "$GW_LOG" ]; then wc -l <"$GW_LOG" | tr -d ' '; else echo 0; fi; }

log_line() { # log_line [n-th-from-last, default 1]
  tail -n "${1:-1}" "$GW_LOG" | head -n 1
}

lg() { log_line "${2:-1}" | jq -r "$1" 2>/dev/null; }

# The last n lines as one array, so a split or a count is one jq call over the
# window a case just produced. `tail_jq 10 '[.[] | select(.failover_from!="")] | length'`
# is the shape A11 uses to say "no line in these ten carries a failover".
tail_jq() { # tail_jq <n> <filter over an array>
  if [ -f "$GW_LOG" ]; then tail -n "$1" "$GW_LOG" | jq -s -r "$2"; else echo "[]"; fi
}

route_count() { # route_count <n> <route> -> how many of the last n lines that leg served
  if [ -f "$GW_LOG" ]; then
    tail -n "$1" "$GW_LOG" | jq -s -r --arg r "$2" '[.[] | select(.route == $r)] | length'
  else
    echo 0
  fi
}

LOG_KEYS='["ts","route","status","latency_ms","tokens_in","tokens_out","failover_from","failover_reason","stream"]'

assert_log_keys() { # label
  # The nine-key contract is the first nine keys, in order. The optional tail
  # (alias, effort_clamped, cost_usd, prompt_kib, header_ms, legs_cooling,
  # retry_after_s) may follow, exactly as `alias` and `cost_usd` always could.
  got=$(log_line | jq -c 'keys_unsorted[0:9]' 2>/dev/null)
  assert_eq "$1 key order" "$got" "$LOG_KEYS"
}

assert_ts() { # label [n-th-from-last]
  ts=$(lg '.ts' "${2:-1}")
  if printf '%s' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'; then
    pass "$1 ts is ISO-8601 with offset: $ts"
  else
    fail "$1 ts" "not ISO-8601 with offset: [$ts]"
  fi
}

assert_log() { # label jq-path expected
  got=$(lg "$2")
  assert_eq "$1 ($2)" "$got" "$3"
}

assert_log_null() { # label jq-path
  got=$(log_line | jq -r "($2) == null" 2>/dev/null)
  assert_eq "$1 ($2) is null" "$got" "true"
}

assert_one_line() { # label count-before
  now=$(log_count)
  assert_eq "$1 exactly one log line" "$now" "$(($2 + 1))"
}

# --------------------------------------------------------------- raw bytes ---

capture_body() { # capture_body <capture-file> <out-file>
  python3 - "$1" "$2" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
head, sep, body = raw.partition(b"\r\n\r\n")
open(sys.argv[2], "wb").write(body)
PY
}

sse_data_count() { awk '/^data: /{n++} END{print n+0}' "$1"; }
sse_done_count() { awk '/\[DONE\]/{n++} END{print n+0}' "$1"; }

sse_chunks() { # SSE payloads that are completion chunks, so an error payload is not counted
  python3 - "$1" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1], "rb").read().decode("utf-8", "replace").splitlines():
    if not line.startswith("data: ") or line.strip() == "data: [DONE]":
        continue
    try:
        if json.loads(line[6:]).get("object") == "chat.completion.chunk":
            n += 1
    except ValueError:
        pass
print(n)
PY
}

sse_error_events() { # count SSE events that carry an error
  python3 - "$1" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
n = 0
for block in raw.split("\n\n"):
    block = block.strip()
    if not block:
        continue
    first = block.splitlines()[0]
    if first.startswith("event: error") or (first.startswith("data:") and '"error"' in first):
        n += 1
print(n)
PY
}
