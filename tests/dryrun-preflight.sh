#!/usr/bin/env bash
# dryrun-preflight.sh — exercises ops/scripts/preflight.sh against a fake host.
#
# Why this exists: preflight.sh is the only thing that decides whether the first deploy on
# qouver1 may start, and it reads the host through a dozen external commands. A check that
# silently passes because a command is missing is worse than no check, so every FAIL branch and
# the one WARN branch that must not block a deploy are driven here.
#
# What is real: bash, the script under test, git (a real clone), stat, chmod.
# What is stubbed: getenforce, loginctl, podman, ss, pgrep, df, caddy, flock.
#
# Usage: bash tests/dryrun-preflight.sh        (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
PREFLIGHT="$KIT/ops/scripts/preflight.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-preflight.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# ── stubs, all reading their answer from the environment ─────────────────────
BIN="$ROOT/bin"
mkdir -p "$BIN"

cat >"$BIN/getenforce" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_GETENFORCE:-Enforcing}"
STUB

cat >"$BIN/loginctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LINGER:-yes}"
STUB

cat >"$BIN/quadlet" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

cat >"$BIN/podman" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'podman version 4.9.4\n' ;;
  info)
    case "$*" in
      *Rootless*) printf '%s\n' "${FAKE_ROOTLESS:-true}" ;;
      *GraphRoot*) printf '%s\n' "${FAKE_GRAPH_ROOT:-/var/home/deploy/.local/share/containers/storage}" ;;
      *) printf '{}\n' ;;
    esac
    ;;
  ps)
    [ "${FAKE_OURS:-0}" = "1" ] && printf 'kori-api\n'
    ;;
esac
exit 0
STUB

# The port probe: one listener line only when the scenario says the port is taken.
cat >"$BIN/ss" <<'STUB'
#!/usr/bin/env bash
printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
[ "${FAKE_PORT_BUSY:-0}" = "1" ] && printf 'LISTEN 0 4096 0.0.0.0:8787 0.0.0.0:*\n'
exit 0
STUB

cat >"$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
[ "${FAKE_BUILD:-0}" = "1" ] || exit 1
printf '4242 podman build -t localhost/kori:local /srv/qouver/apps/kori/src\n'
exit 0
STUB

cat >"$BIN/df" <<'STUB'
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/vda4 104857600 1048576 %s 40%% /\n' "${FAKE_FREE_KIB:-104857600}"
exit 0
STUB

cat >"$BIN/caddy" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  version) printf 'v2.8.4 h1:q3pe0wpBj1OcHFZ3nPWYROlsRnX65H0TpCX5sASX6WA=\n' ;;
  list-modules)
    printf 'http.handlers.reverse_proxy\nhttp.handlers.file_server\n'
    [ "${FAKE_RL:-1}" = "1" ] && printf 'http.handlers.rate_limit\n'
    ;;
esac
exit 0
STUB

# flock only has to answer the non-blocking probe the script makes on fd 8.
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
exit "${FAKE_FLOCK_RC:-0}"
STUB

cat >"$BIN/restorecon" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# cosign is a deploy hard-requirement (verify_signature). Stubbed so the harness does not depend on
# the laptop having it; the missing-cosign scenario moves this file out of PATH instead of faking
# an exit code, because `command -v` is what the script actually asks.
cat >"$BIN/cosign" <<'STUB'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"${SMOKE_STATE:-/dev/null}"
exit 0
STUB

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# ── a fake app dir: real git clone, env file, unit path ─────────────────────
APP_DIR="$ROOT/app"
ORIGIN="$ROOT/origin.git"
mkdir -p "$APP_DIR/env"
git init --bare --quiet "$ORIGIN"
git clone --quiet "$ORIGIN" "$APP_DIR/src" 2>/dev/null
printf '# kori\n' >"$APP_DIR/src/README.md"
git -C "$APP_DIR/src" add -A
git -C "$APP_DIR/src" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "init"
git -C "$APP_DIR/src" remote set-url origin "https://github.com/hidaydev/kori.git"

QUADLET="$ROOT/quadlet"
printf '#!/usr/bin/env bash\nexit 0\n' >"$QUADLET"
chmod +x "$QUADLET"

export KORI_APP_DIR="$APP_DIR"
export KORI_SERVICE="kori-api"
export KORI_PORT="8787"
export KORI_MIN_FREE_GIB="5"
export KORI_QUADLET_BIN="$QUADLET"
export FAKE_GRAPH_ROOT="$ROOT/graphroot"
mkdir -p "$FAKE_GRAPH_ROOT"

# Every scenario starts from a healthy host and spoils exactly one thing.
reset_host() {
  rm -f "$APP_DIR/env/kori-prod.env"
  printf 'KORI_EDGE_TOKEN=%s\n' "${FAKE_TOKEN:-dryrun-token}" >"$APP_DIR/env/kori-prod.env"
  chmod 600 "$APP_DIR/env/kori-prod.env"
  unset FAKE_GETENFORCE FAKE_LINGER FAKE_ROOTLESS FAKE_PORT_BUSY FAKE_OURS \
    FAKE_BUILD FAKE_FREE_KIB FAKE_RL FAKE_FLOCK_RC
  export KORI_QUADLET_BIN="$QUADLET"
}

run() { bash "$PREFLIGHT" >"$ROOT/out.txt" 2>&1; echo $?; }

# ── scenario 1: healthy host, ready to deploy ───────────────────────────────
reset_host
rc="$(run)"
[ "$rc" = "0" ] && pass "clean host exits 0" || fail "clean host exited $rc: $(tail -3 "$ROOT/out.txt")"
grep -q '^RESULT: ready' "$ROOT/out.txt" && pass "clean host says ready" \
  || fail "clean host verdict wrong: $(grep '^RESULT' "$ROOT/out.txt")"
grep -q "^PASS  port 8787 .*free" "$ROOT/out.txt" && pass "port reported free" || fail "port not reported free"
grep -q '^PASS  build slot' "$ROOT/out.txt" && pass "build slot reported free" || fail "build slot not checked"
grep -q 'http.handlers.rate_limit' "$ROOT/out.txt" && pass "rate limit module detected" \
  || fail "rate limit module not detected"
grep -q '^FAIL' "$ROOT/out.txt" && fail "clean host produced a FAIL line" || pass "no FAIL line on a clean host"

# ── scenario 2: port 8787 taken by something else ──────────────────────────
reset_host
export FAKE_PORT_BUSY=1
rc="$(run)"
[ "$rc" = "1" ] && pass "foreign listener exits 1" || fail "foreign listener exited $rc"
grep -q '^FAIL  port 8787 .*in use by something else' "$ROOT/out.txt" \
  && pass "foreign listener named as the blocker" || fail "foreign listener not reported"

# ── scenario 3: the port is ours (kori already deployed) ───────────────────
reset_host
export FAKE_PORT_BUSY=1 FAKE_OURS=1
rc="$(run)"
[ "$rc" = "0" ] && pass "our own listener is not a blocker" || fail "our own listener exited $rc"
grep -q '^PASS  port 8787 .*held by kori-api' "$ROOT/out.txt" \
  && pass "our own listener recognised" || fail "our own listener not recognised"

# ── scenario 4: caddy without the rate limit module must WARN, not block ───
reset_host
export FAKE_RL=0
rc="$(run)"
[ "$rc" = "0" ] && pass "missing ratelimit module does not block" || fail "missing ratelimit blocked with $rc"
grep -q '^WARN  caddy .*without http.handlers.rate_limit' "$ROOT/out.txt" \
  && pass "missing module reported as WARN" || fail "missing module not reported"
grep -q 'Cloudflare per-IP rule in place' "$ROOT/out.txt" \
  && pass "interim path named in the verdict" || fail "interim path not named"

# ── scenario 5: env file too permissive ────────────────────────────────────
reset_host
chmod 644 "$APP_DIR/env/kori-prod.env"
rc="$(run)"
[ "$rc" = "1" ] && pass "env file mode 644 exits 1" || fail "env file mode 644 exited $rc"
grep -q '^FAIL  env file .*must be 600' "$ROOT/out.txt" && pass "env mode named as the blocker" \
  || fail "env mode not reported"

# ── scenario 6: env file missing ───────────────────────────────────────────
reset_host
rm -f "$APP_DIR/env/kori-prod.env"
rc="$(run)"
[ "$rc" = "1" ] && pass "missing env file exits 1" || fail "missing env file exited $rc"
grep -q '^FAIL  env file .*missing' "$ROOT/out.txt" && pass "missing env file reported" \
  || fail "missing env file not reported"

# ── scenario 7: the token is never printed ─────────────────────────────────
reset_host
export FAKE_TOKEN="sup3r-s3cret-edge-token"
rc="$(run)"
grep -q 'sup3r-s3cret-edge-token' "$ROOT/out.txt" \
  && fail "preflight printed the edge token" || pass "edge token never printed"
unset FAKE_TOKEN

# ── scenario 8: another build is running ───────────────────────────────────
reset_host
export FAKE_BUILD=1
rc="$(run)"
[ "$rc" = "1" ] && pass "concurrent build exits 1" || fail "concurrent build exited $rc"
grep -q '^FAIL  build slot .*already running' "$ROOT/out.txt" && pass "concurrent build named" \
  || fail "concurrent build not reported"

# ── scenario 9: another deploy holds the lock ──────────────────────────────
reset_host
export FAKE_FLOCK_RC=1
rc="$(run)"
[ "$rc" = "1" ] && pass "held lock exits 1" || fail "held lock exited $rc"
grep -q '^FAIL  deploy lock .*held by another deploy' "$ROOT/out.txt" \
  && pass "held lock named" || fail "held lock not reported"

# ── scenario 10: disk below the floor ──────────────────────────────────────
reset_host
export FAKE_FREE_KIB=2097152     # 2 GiB
rc="$(run)"
[ "$rc" = "1" ] && pass "low disk exits 1" || fail "low disk exited $rc"
grep -q '^FAIL  disk .*2 GiB free' "$ROOT/out.txt" && pass "low disk quantified" \
  || fail "low disk not quantified"

# ── scenario 11: no lingering, unit dies at logout ─────────────────────────
reset_host
export FAKE_LINGER=no
rc="$(run)"
[ "$rc" = "1" ] && pass "linger off exits 1" || fail "linger off exited $rc"
grep -q '^FAIL  linger .*loginctl enable-linger' "$ROOT/out.txt" && pass "linger fix named" \
  || fail "linger fix not named"

# ── scenario 12: podman is rootful ─────────────────────────────────────────
reset_host
export FAKE_ROOTLESS=false
rc="$(run)"
[ "$rc" = "1" ] && pass "rootful podman exits 1" || fail "rootful podman exited $rc"
grep -q '^FAIL  podman .*rootless=false' "$ROOT/out.txt" && pass "rootful podman named" \
  || fail "rootful podman not reported"

# ── scenario 13: quadlet generator absent ──────────────────────────────────
reset_host
export KORI_QUADLET_BIN="$ROOT/no-such-quadlet"
rc="$(run)"
[ "$rc" = "1" ] && pass "missing quadlet exits 1" || fail "missing quadlet exited $rc"
grep -q '^FAIL  quadlet ' "$ROOT/out.txt" && pass "missing quadlet named" || fail "missing quadlet not reported"

# ── scenario 14: not a git checkout ────────────────────────────────────────
reset_host
mv "$APP_DIR/src" "$ROOT/src.bak"
rc="$(run)"
[ "$rc" = "1" ] && pass "missing checkout exits 1" || fail "missing checkout exited $rc"
grep -q '^FAIL  checkout ' "$ROOT/out.txt" && pass "missing checkout named" || fail "missing checkout not reported"
mv "$ROOT/src.bak" "$APP_DIR/src"

# ── scenario 15: SELinux permissive is a WARN, not a blocker ───────────────
reset_host
export FAKE_GETENFORCE=Permissive
rc="$(run)"
[ "$rc" = "0" ] && pass "permissive selinux does not block" || fail "permissive selinux blocked with $rc"
grep -q '^WARN  selinux ' "$ROOT/out.txt" && pass "permissive selinux warned" || fail "permissive selinux not warned"

# ── scenario 16: cosign missing -> FAIL, not a deploy that dies at step 5 ──
# deploy-vps.sh calls `cosign verify` before it tags :local. Without the binary the deploy burns the
# 45x20s registry window first and then aborts on the host's only slot, which is exactly the fact
# preflight is supposed to surface from a laptop.
reset_host
mv "$BIN/cosign" "$BIN/cosign.hidden"
# The laptop has a real cosign in /opt/homebrew/bin, so hiding the stub is not enough: run this
# scenario with a PATH that holds the stubs and the system dirs only.
SAVED_PATH="$PATH"
PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
rc="$(run)"
PATH="$SAVED_PATH"
mv "$BIN/cosign.hidden" "$BIN/cosign"
[ "$rc" = "1" ] && pass "missing cosign exits 1 ($rc)" || fail "missing cosign exited $rc"
grep -q '^FAIL  tools .*cosign' "$ROOT/out.txt" && pass "cosign is named as the blocker" \
  || fail "cosign not named: $(grep '^FAIL' "$ROOT/out.txt" | head -3)"

# A clean host still passes with the stub present, so the new requirement cannot red the baseline.
reset_host
rc="$(run)"
[ "$rc" = "0" ] && pass "cosign present keeps the clean host green" || fail "cosign stub reddened the clean host"

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
