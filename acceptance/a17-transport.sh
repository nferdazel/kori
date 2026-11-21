#!/bin/sh
# A17 — the transport limits an unauthenticated caller meets (2026-11-21 audit).
#
#   a17a  a caller body over 8 MiB is refused on the declared length, before any
#         byte is buffered, and the process's memory does not move
#   a17b  a half-sent request is refused at the 30 s read timeout instead of held
#   a17c  every JSON read carries no-store and nosniff
#   a17d  a HEAD answers the headers and no body
#
# The first two are what stop an anonymous caller from turning the container's
# 512M budget into an OOM kill, or from holding a connection open for ever.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

gw_stop; stub_kill leg-a 18091
stub leg-a 18091 ok
write_config "leg-a|http://127.0.0.1:18091/v1|key-leg-a|"
gw_start

gw_pid() { pgrep -f -- "--config $GW_CFG" | head -n 1; }
rss_kb() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }

echo
echo "=== A17a: a body over the cap is a 413 on the declared length"
pid=$(gw_pid)
before=$(rss_kb "$pid")
# 30 MiB: just under the old 32 MiB cap, so this is the size that used to be
# buffered whole and only then rejected. The declared Content-Length is what the
# library checks, before a byte of it is read.
head -c 31457280 /dev/zero | tr '\0' 'x' >"$RUN/a17-big.bin"
assert_eq "A17a a 30 MiB login body is 413" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
       -H 'Content-Type: application/json' --data-binary "@$RUN/a17-big.bin" \
       "$GW_URL/session/login")" "413"
# The read never happened, so the heap never grew by the body. 60 MB of slack is
# generous against a 30 MB body and narrow against the ~190 MB the old cap cost.
after=$(rss_kb "$pid")
grew=$(( after - before ))
assert_eq "A17a the process did not buffer the refused body" \
  "$([ "$grew" -lt 60000 ] && echo held || echo grew-"$grew"-kB)" "held"
rm -f "$RUN/a17-big.bin"
# The same route still answers a legal body, so the cap is a limit, not a wall.
printf '{"token":"%s"}' "$ADMIN_TOKEN_VALUE" >"$RUN/a17-small.json"
assert_eq "A17a a legal login body still answers 204" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
       -H 'Content-Type: application/json' --data-binary "@$RUN/a17-small.json" \
       "$GW_URL/session/login")" "204"

echo
echo "=== A17b: a half-sent request is refused at the read timeout"
# The request line arrives, the headers never do. Before ReadTimeoutMs this held
# the connection and its buffers for as long as the client kept the socket open.
outcome=$(python3 - "$GW_HOST" "$GW_PORT" <<'PY'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
s = socket.create_connection((host, port), timeout=5)
s.sendall(b"GET /healthz HTTP/1.1\r\nHost: forged\r\n")
s.settimeout(45)
start = time.time()
try:
    data = s.recv(4096)
except socket.timeout:
    print("held"); sys.exit(0)
elapsed = int(time.time() - start)
print("answered-%d" % elapsed if data else "closed-%d" % elapsed)
PY
)
case "$outcome" in
  answered-*|closed-*)
    pass "A17b the socket did not stay held"
    secs=$(printf '%s' "$outcome" | cut -d- -f2)
    assert_eq "A17b it was released inside the 30 s read timeout" \
      "$([ "$secs" -le 40 ] && echo in-time || echo late)" "in-time"
    ;;
  held) fail "A17b the socket did not stay held" "still held after 45 s" ;;
  *)    fail "A17b the socket did not stay held" "unusable probe [$outcome]" ;;
esac

echo
echo "=== A17c: every JSON read is no-store and nosniff"
for path in /healthz /admin/state /admin/config /admin/log /v1/models /metrics; do
  gate_gen "$RUN/a17-h.body" "$path" -H "$(admin_token_header)" >/dev/null
  assert_eq "A17c $path carries Cache-Control: no-store" \
    "$(gate_header "$RUN/a17-h.body.head" cache-control)" "no-store"
  assert_eq "A17c $path carries X-Content-Type-Options: nosniff" \
    "$(gate_header "$RUN/a17-h.body.head" x-content-type-options)" "nosniff"
done

echo
echo "=== A17d: a HEAD answers the headers and no body"
# curl --head writes the response headers into -o, so `wc -c` on that file
# measures headers, not body. Read the wire instead: one request, then count the
# bytes after the blank line. `Connection: close` makes the read end.
raw_probe() { # raw_probe <method> <path> [extra header line] -> raw response on stdout
  python3 - "$GW_HOST" "$GW_PORT" "$1" "$2" "${3:-}" <<'PY'
import socket, sys
host, port, method, path, extra = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
s = socket.create_connection((host, port), timeout=5)
req = "%s %s HTTP/1.1\r\nHost: probe\r\nConnection: close\r\n" % (method, path)
if extra:
    req += extra + "\r\n"
s.sendall((req + "\r\n").encode())
s.settimeout(5)
chunks = []
try:
    while True:
        data = s.recv(65536)
        if not data:
            break
        chunks.append(data)
except socket.timeout:
    pass
s.close()
sys.stdout.buffer.write(b"".join(chunks))
PY
}
raw_clen() { tr -d '\r' <"$1" | awk 'tolower($1)=="content-length:"{print $2; exit}'; }
raw_body_bytes() {
  python3 - "$1" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
head, sep, body = raw.partition(b"\r\n\r\n")
print(len(body) if sep else -1)
PY
}

raw_probe GET /healthz >"$RUN/a17-get.raw"
raw_probe HEAD /healthz >"$RUN/a17-head.raw"
get_len=$(raw_clen "$RUN/a17-get.raw")
head_len=$(raw_clen "$RUN/a17-head.raw")
assert_ne "A17d the GET declares its own length" "$get_len" ""
assert_eq "A17d HEAD reports the length a GET would answer" "$head_len" "$get_len"
assert_eq "A17d HEAD /healthz returns no body" "$(raw_body_bytes "$RUN/a17-head.raw")" "0"
raw_probe HEAD /v1/models "$(admin_token_header)" >"$RUN/a17-models.raw"
assert_eq "A17d HEAD /v1/models returns no body" "$(raw_body_bytes "$RUN/a17-models.raw")" "0"
assert_ne "A17d HEAD /v1/models still declares its length" "$(raw_clen "$RUN/a17-models.raw")" ""

kill_stubs
finish
