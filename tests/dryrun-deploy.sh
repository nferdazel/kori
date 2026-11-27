#!/usr/bin/env bash
# dryrun-deploy.sh — exercises ops/scripts/deploy-vps.sh end to end on a workstation.
#
# Why this exists: the deploy script's control flow (ref guard -> flock -> git sync -> pull ->
# revision label -> cosign -> :prev retag -> restart -> health gate -> auto-rollback ->
# .deployed_rev) has never been run. Syntax checking proves nothing about the rollback branch,
# and qouver1 is Dimas's slot.
#
# What is real here: bash, the script under test, git (a local bare "origin" and a real clone).
# What is stubbed: podman, cosign, systemctl, curl, sudo, restorecon, flock, sleep. The stubs keep
# state in $ROOT/state so tag history is inspectable afterwards.
#
# It does NOT prove the image builds, that the registry serves it, or that a unit loads. It
# proves the script does what the contract says on every path it can take.
#
# Usage: bash tests/dryrun-deploy.sh        (exit 0 = all scenarios passed)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
DEPLOY="$KIT/ops/scripts/deploy-vps.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kori-dryrun.XXXXXX")"
FAILS=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# ── stubs ────────────────────────────────────────────────────────────────────
BIN="$ROOT/bin"
STATE="$ROOT/state"
mkdir -p "$BIN" "$STATE"
: >"$STATE/tags"
: >"$STATE/calls.log"

cat >"$BIN/podman" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'podman %s\n' "$*" >>"$S/calls.log"
case "$1" in
  pull)
    # ok       : the registry serves the image for this commit
    # notbuilt : CI legitimately pushed nothing for this commit
    # error    : registry down / 502 / expired token — must NOT be read as "not built"
    case "${FAKE_PULL:-ok}" in
      ok) printf 'stub pull ok\n'; exit 0 ;;
      notbuilt) printf 'Error: manifest unknown\n' >&2; exit 125 ;;
      late)
        # The tag shows up on pull number FAKE_PULL_LATE+1: the gate and the image job finish
        # after the webhook already reached the host. Missing tag, then success.
        limit="${FAKE_PULL_LATE:-2}"
        n="$(cat "$S/pull_count" 2>/dev/null || printf 0)"
        n=$((n + 1))
        printf '%s\n' "$n" >"$S/pull_count"
        if [ "$n" -le "$limit" ]; then printf 'Error: manifest unknown\n' >&2; exit 125; fi
        printf 'stub pull ok\n'
        exit 0
        ;;
      *) printf 'Error: received unexpected HTTP status: 502 Bad Gateway\n' >&2; exit 125 ;;
    esac
    ;;
  inspect)
    # The label the image claims. The harness passes the sha the host should compare against,
    # so a mismatch is a scenario and not a coincidence.
    printf '%s\n' "${FAKE_REV:-}"
    exit 0
    ;;
  image)
    if [ "${2:-}" = "inspect" ]; then
      # The bytes just pulled claim this digest. The host must verify and tag the digest, not the
      # mutable sha-<7> tag, so the harness reports one and scenario 3b asserts it is what moved
      # :local. FAKE_REPO_DIGESTS replays the shape measured on qouver1, where one digest is
      # recorded under both the registry and localhost.
      if [ -n "${FAKE_REPO_DIGESTS:-}" ]; then
        printf '%s\n' "$FAKE_REPO_DIGESTS"
      else
        printf '%s@sha256:%s\n' "${5%%:*}" "${FAKE_DIGEST:-$(printf 'a%.0s' {1..64})}"
      fi
      exit 0
    fi
    [ "${2:-}" = "exists" ] || exit 0
    grep -qxF "${3##*:}" "$S/tags" 2>/dev/null && exit 0 || exit 1
    ;;
  manifest)
    # podman manifest inspect <ref>: the document the registry serves for the tag, pretty-printed
    # like the real command. Which digest the host tags :local from is decided by this document —
    # its mediaType says whether it is an index, and its children say which RepoDigests entry is
    # the leftover index. One value per line matters: pulled_digest reads the first mediaType line,
    # so a single-line document would hand it a child's mediaType instead of the index's.
    # Answering nothing here made every pull path abort as "reports no digest".
    case "${FAKE_MANIFEST:-index}" in
      index|docker-list)
        if [ "${FAKE_MANIFEST:-index}" = "docker-list" ]; then
          TOP="application/vnd.docker.distribution.manifest.list.v2+json"
          CHILD="application/vnd.docker.distribution.manifest.v2+json"
        else
          TOP="application/vnd.oci.image.index.v1+json"
          CHILD="application/vnd.oci.image.manifest.v1+json"
        fi
        cat <<EOF
{
    "schemaVersion": 2,
    "mediaType": "$TOP",
    "manifests": [
        {
            "mediaType": "$CHILD",
            "digest": "sha256:$(printf 'b%.0s' {1..64})",
            "size": 1873,
            "platform": {
                "architecture": "amd64",
                "os": "linux"
            }
        },
        {
            "mediaType": "$CHILD",
            "digest": "sha256:$(printf 'c%.0s' {1..64})",
            "size": 1873,
            "platform": {
                "architecture": "arm64",
                "os": "linux"
            }
        }
    ]
}
EOF
        ;;
      image-manifest)
        # A bare image manifest carries a config and layers, no child manifests: there is no
        # signed index to select, so the host must abort instead of guessing.
        cat <<EOF
{
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": "sha256:$(printf 'd%.0s' {1..64})",
        "size": 14718
    },
    "layers": [
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "digest": "sha256:$(printf 'e%.0s' {1..64})",
            "size": 6144
        }
    ]
}
EOF
        ;;
      *) printf 'stub manifest: unknown FAKE_MANIFEST %s\n' "$FAKE_MANIFEST" >&2; exit 125 ;;
    esac
    exit 0
    ;;
  tag)
    printf '%s\n' "${3##*:}" >>"$S/tags"
    # Rolling :prev back onto :local is the moment the old image is serving again.
    case "${2##*:}" in prev) : >"$S/rolled_back" ;; esac
    ;;
  images)
    sort -u "$S/tags"
    ;;
  *)
    exit 0
    ;;
esac
STUB

# cosign verify: keyless signature check against this repo's workflow identity.
cat >"$BIN/cosign" <<'STUB'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
[ "${FAKE_COSIGN:-ok}" = "ok" ] && exit 0 || exit 1
STUB

cat >"$BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'systemctl %s\n' "$*" >>"$S/calls.log"
# FAKE_SYSTEMCTL_RENDER: what systemd answers for the unit's LoadState after the daemon-reload.
# The deploy asks before it restarts, because a unit systemd will not load takes the service
# down while the old container keeps serving. A stub that answers nothing reads as a failed
# render, which is why every scenario here used to look like one.
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show" ]; then
  # No default on purpose: a scenario that expects the unit to render says so. Answering
  # "loaded" when nobody asked made an unset variable read as a passing gate.
  printf '%s\n' "${FAKE_SYSTEMCTL_RENDER-}"
  exit 0
fi
# FAKE_SYSTEMCTL_CADDY: only caddy refuses to restart, so the edge path is what is under test
# while every kori-api restart stays green.
#   once : the first caddy restart fails, the retry after the restore succeeds
#   fail : every caddy restart fails
if [ "${FAKE_SYSTEMCTL_CADDY:-ok}" != "ok" ] && [ "${1:-}" = "restart" ] && [ "${2:-}" = "caddy" ]; then
  n=$(( $(cat "$S/caddy_restarts" 2>/dev/null || printf 0) + 1 ))
  printf '%s\n' "$n" >"$S/caddy_restarts"
  case "${FAKE_SYSTEMCTL_CADDY}" in
    fail) exit 1 ;;
    once) [ "$n" -eq 1 ] && exit 1 || exit 0 ;;
  esac
fi
exit 0
STUB

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
S="${PODMAN_STATE:?}"
printf 'curl %s\n' "$*" >>"$S/calls.log"
# Two callers share this stub: the deploy's wait_healthy (exit code only) and smoke.sh, which
# parses /healthz as JSON and reads a status code for the gated admin surface.
# ok      : always healthy
# recover : the new image is sick, the old one (:prev) is fine once it is back in service
# nonjson : answers 200 with a body that is not JSON -> health green, smoke red
# fail    : nothing is healthy, not even the rollback
code_only=0; hdr=""; url=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w) code_only=1; shift 2 ;;
    -H) hdr="$2"; shift 2 ;;
    -K|--config) cfg="$2"; shift 2 ;;
    -o|--max-time|-s|-f|-S) shift 2 2>/dev/null || shift 1 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$cfg" = "-" ]; then
  while IFS= read -r cline; do
    case "$cline" in
      header*=*) hdr="${cline#*\"}"; hdr="${hdr%\"*}" ;;
    esac
  done
fi
healthy() {
  case "${FAKE_CURL:-ok}" in
    ok) return 0 ;;
    recover) [ -f "$S/rolled_back" ] && return 0 || return 1 ;;
    nonjson) return 0 ;;
    *) return 1 ;;
  esac
}
case "$url" in
  */admin/state|*/metrics)
    # Gated surface (DEC-20). No token configured in this harness, so the honest answer is 404.
    if [ "$hdr" = "Authorization: Bearer ${KORI_ADMIN_TOKEN:-}" ] && [ -n "${KORI_ADMIN_TOKEN:-}" ]; then
      [ "$code_only" = "1" ] && { printf '200'; exit 0; }
      printf '{}\n'; exit 0
    fi
    [ "$code_only" = "1" ] && { printf '404'; exit 0; }
    printf '{"error":{"type":"not_found","message":"no such path"}}\n'; exit 0 ;;
esac
# FAKE_HEALTH_DOWN=1: liveness is down while the gated path still answers a refusal. A deploy
# gate that borrowed /admin/state would read the 404 as trouble but a health gate that borrowed it
# as "any answer" would read its 401 the wrong way; either way this scenario is what proves the
# gate is on /healthz and nowhere else.
[ "${FAKE_HEALTH_DOWN:-0}" = "1" ] && exit 7
healthy || exit 7
case "${FAKE_CURL:-ok}" in
  nonjson) printf 'not json\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
STUB

# smoke.sh reads the publish address with `ss` and the log size with GNU `stat -c`. Neither is
# macOS-native, and the deploy harness runs on the workstation, so both are stubbed here the same
# way dryrun-smoke.sh stubs them.
cat >"$BIN/ss" <<'STUB'
#!/usr/bin/env bash
printf 'ss %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
printf 'State  Recv-Q  Send-Q  Local Address:Port\nLISTEN 0 4096 127.0.0.1:8787 0.0.0.0:*\n'
STUB

cat >"$BIN/stat" <<'STUB'
#!/usr/bin/env bash
printf 'stat %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
f="${3:-${2:-}}"
[ -f "$f" ] && wc -c <"$f" | tr -d ' ' || printf '0\n'
STUB

cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
"$@"
STUB

cat >"$BIN/restorecon" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

# caddy validate: the deploy validates the rendered block before restarting the service.
# FAKE_CADDY=invalid makes the block unadaptable, the way a site-block `servers` directive was on
# 2026-11-16 — the real binary answers with the offending line, which is why the deploy masks the
# token before logging anything it prints.
cat >"$BIN/caddy" <<'STUB'
#!/usr/bin/env bash
printf 'caddy %s\n' "$*" >>"${PODMAN_STATE:?}/calls.log"
if [ "${FAKE_CADDY:-ok}" = "invalid" ]; then
  printf '{"level":"error","msg":"adapting config using caddyfile: site.caddy:46: unrecognized directive: servers"}\n' >&2
  # An adapt error quotes the offending line, and one of those lines carries the bearer. Printing
  # it here is what makes the masking assertion below prove anything: without it the test passes
  # whether or not the deploy masks.
  grep -h 'Bearer' "${KORI_APP_DIR:?}/caddy/site.caddy" >&2 2>/dev/null || true
  exit 1
fi
printf 'Valid configuration\n'
exit 0
STUB

# flock is not on macOS; here it only needs to succeed, but it records how it was called: the
# deploy must ask it to wait (-w), not to skip (-n), or a push that lands mid-deploy is dropped.
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
[ -n "${PODMAN_STATE:-}" ] && printf 'flock %s\n' "$*" >>"$PODMAN_STATE/flock_calls.log"
exit 0
STUB

# The health gate polls with sleep; do not actually wait.
cat >"$BIN/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export PODMAN_STATE="$STATE"

# ── a real git origin holding the kit, plus a real clone ─────────────────────
ORIGIN="$ROOT/origin.git"
WORK="$ROOT/work"
APP_DIR="$ROOT/app"
UNIT_DIR="$ROOT/units"
mkdir -p "$UNIT_DIR"

git init --bare --quiet "$ORIGIN"
git clone --quiet "$ORIGIN" "$WORK" 2>/dev/null
cp -R "$KIT/ops" "$KIT/tools" "$WORK/"
mkdir -p "$WORK/apps/web/dist" "$WORK/apps/api/src"
cp "$KIT/apps/api/Dockerfile" "$WORK/apps/api/Dockerfile"
printf 'placeholder\n' >"$WORK/apps/web/dist/index.html"
printf '# kori\n' >"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "ops kit"
git -C "$WORK" push --quiet origin HEAD:main

mkdir -p "$APP_DIR/env"
git clone --quiet "$ORIGIN" "$APP_DIR/src"
git -C "$APP_DIR/src" checkout --quiet main
printf 'KORI_EDGE_TOKEN=dryrun-token\n' >"$APP_DIR/env/kori-prod.env"

export KORI_APP_DIR="$APP_DIR"
export KORI_UNIT_DIR="$UNIT_DIR"
export KORI_SERVICE="kori-api"
export KORI_IMAGE="localhost/kori"
export KORI_HEALTH_GATE_SECONDS=4

reset_state() {
  : >"$STATE/tags"
  : >"$STATE/calls.log"
  rm -f "$STATE/rolled_back" "$STATE/pull_count" "$STATE/caddy_restarts" "$STATE/flock_calls.log"
  rm -f "$APP_DIR/.deployed_rev" "$APP_DIR/logs/deploy.log" "$APP_DIR/logs/smoke.log"
  # smoke.sh requires an append-only request log with a JSON last line. The gateway writes it in
  # production; here the harness owns it, so every scenario starts from the same one line.
  mkdir -p "$APP_DIR/logs"
  printf '{"ts":"2026-11-16T07:00:00Z","route":"leg-a","status":200,"latency_ms":42,"stream":false,"tokens_in":11,"tokens_out":7,"failover_from":"","failover_reason":"","model":"flash"}\n' \
    >"$APP_DIR/logs/requests.jsonl"
  unset FAKE_MANIFEST FAKE_REPO_DIGESTS FAKE_CADDY
  # Set, not defaulted in the stub: the baseline every scenario starts from is a unit that
  # renders, and a scenario that wants the failure says so. Leaving it unset must read as a
  # failed render (the fail-closed direction), never as a passing gate.
  export FAKE_SYSTEMCTL_RENDER=loaded
}

run() { bash "$DEPLOY" kori "$@" >"$ROOT/out.txt" 2>&1; echo $?; }

head_sha() { git -C "$WORK" rev-parse HEAD; }
head_short() { printf '%.7s' "$(head_sha)"; }
sha_ref() { printf 'ghcr.io/nferdazel/kori-api:sha-%s' "$(head_short)"; }

# The image this commit built, claimed by the label, signed by this repo's workflow.
happy_image() {
  FAKE_REV="$(head_sha)"
  export FAKE_REV
  export FAKE_PULL=ok FAKE_COSIGN=ok
}

restarts() { grep -c 'systemctl --user restart kori-api' "$STATE/calls.log" || true; }

# ── scenario 1: wrong ref is ignored, no pull, no restart ────────────────────
reset_state
rc="$(run refs/heads/dev)"
[ "$rc" = "0" ] && pass "wrong ref exits 0" || fail "wrong ref exited $rc"
grep -q "Deploy ignored: ref 'refs/heads/dev' is not refs/heads/main" "$ROOT/out.txt" \
  && pass "wrong ref prints the ignore line" || fail "wrong ref message missing"
[ ! -s "$STATE/calls.log" ] && pass "wrong ref touched no podman/systemctl" \
  || fail "wrong ref still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 2: empty ref is ignored (fail-closed, not fail-open) ────────────
reset_state
rc="$(run "")"
[ "$rc" = "0" ] && pass "empty ref exits 0" || fail "empty ref exited $rc"
[ ! -s "$STATE/calls.log" ] && pass "empty ref touched no podman/systemctl" \
  || fail "empty ref still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 3: happy path — pull, verify, tag :local, restart ───────────────
reset_state
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "happy path exits 0" || fail "happy path exited $rc: $(tail -3 "$ROOT/out.txt")"
[ -f "$APP_DIR/.deployed_rev" ] && pass ".deployed_rev written: $(cat "$APP_DIR/.deployed_rev")" \
  || fail ".deployed_rev missing"
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$(head_sha)" ] \
  && pass ".deployed_rev is the full commit sha" || fail ".deployed_rev is not the full sha"
grep -qxF 'local' "$STATE/tags" && pass "image tagged :local" || fail "no :local tag"
[ -f "$UNIT_DIR/kori-api.container" ] && pass "unit installed to KORI_UNIT_DIR" || fail "unit not installed"
[ -f "$APP_DIR/caddy/site.caddy" ] && pass "edge block rendered" || fail "edge block not rendered"
grep -q 'dryrun-token' "$APP_DIR/caddy/site.caddy" && pass "edge token substituted" \
  || fail "edge token not substituted"
# The host/00 shared header snippet. Every other site block on qouver1 imports it; kori's did not,
# so the origin answered with no HSTS and no X-Frame-Options at all (measured 2026-11-21). Both
# blocks need it: ai is the API door and dash is the page a browser loads.
imports="$(grep -c '^	import security' "$APP_DIR/caddy/site.caddy" || true)"
[ "$imports" = "2" ] && pass "both site blocks import the shared header snippet" \
  || fail "expected import security in both blocks, found $imports"
grep -q 'systemctl --user restart kori-api' "$STATE/calls.log" && pass "service restarted" \
  || fail "service never restarted"
grep -q 'sudo systemctl restart caddy' "$STATE/calls.log" && pass "caddy restarted" \
  || fail "caddy never restarted"

# ── scenario 3a: the health gate probes /healthz, and the gate is really exercised ─
# DEC-20 moved the admin surface behind a token, so /admin/state answers 404 to a probe that
# carries none. If the deploy still probed it, every deploy would fail its gate and roll back.
# Two assertions: the probe path itself, and a host whose liveness is down while the gated path
# still answers — a run that passed here would have been reading the wrong endpoint.
[ "$(grep -c 'curl -fsS --max-time 3 http://127.0.0.1:8787/healthz' "$STATE/calls.log")" -ge 1 ] \
  && pass "the health gate probes /healthz, not the gated admin path" \
  || fail "the health gate did not probe /healthz: $(grep '^curl' "$STATE/calls.log" | head -3)"
grep -q 'curl -fsS --max-time 3 http://127\.0\.0\.1:8787/admin/state' "$STATE/calls.log" \
  && fail "the health gate probed /admin/state, which answers 404 without a token" \
  || pass "the health gate never probes /admin/state (smoke's own 404 assertion is a separate call)"
# The default in the script itself, not only in the env file: an operator who sets nothing must
# still land on the open endpoint.
grep -qF 'HEALTH_URL="${KORI_HEALTH_URL:-http://127.0.0.1:8787/healthz}"' "$DEPLOY" \
  && pass "KORI_HEALTH_URL defaults to /healthz" \
  || fail "KORI_HEALTH_URL does not default to /healthz"

# ── scenario 3a2: liveness down while the gated path answers -> rollback, not a pass ─
# The inverse of the case above. If the gate read the admin surface, a 404/401 there could be
# mistaken for an answer; here liveness is the only thing failing, and the deploy must roll back.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_HEALTH_DOWN=1
rc="$(run refs/heads/main)"
unset FAKE_HEALTH_DOWN
[ "$rc" != "0" ] && pass "dead liveness with a live admin path rolls back ($rc)" \
  || fail "a dead /healthz was read as healthy"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written with liveness down" \
  || pass "no .deployed_rev with liveness down"

# ── scenario 3a3: the readiness probe is installed and it watches /healthz ──
# `Restart=always` reacts to a process that exits; nothing watched a process that stays up and
# stops answering, and OnFailure on kori-api itself only fires when the unit fails (its alert unit
# had no journal entries at all on qouver1, 2026-11-21). The probe is a separate unit so a wedged
# gateway pages on its own, and it must probe the open path: /admin/state answers 404 without a
# token, so a probe there would page on every correctly configured host.
# The units land in KORI_SYSTEMD_DIR, not KORI_UNIT_DIR: the latter is the quadlet directory, and
# systemd answers LoadState=not-found for a timer placed there (measured 2026-11-21).
reset_state
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "deploy with the readiness probe exits 0" || fail "probe deploy exited $rc"
export KORI_SYSTEMD_DIR="$ROOT/user-units"
mkdir -p "$KORI_SYSTEMD_DIR"
reset_state
rc="$(run refs/heads/main)"
[ -f "$KORI_SYSTEMD_DIR/kori-readyz.service" ] && pass "kori-readyz.service installed as a user unit" \
  || fail "kori-readyz.service not installed into KORI_SYSTEMD_DIR"
[ -f "$KORI_SYSTEMD_DIR/kori-readyz.timer" ] && pass "kori-readyz.timer installed as a user unit" \
  || fail "kori-readyz.timer not installed into KORI_SYSTEMD_DIR"
[ -f "$UNIT_DIR/kori-readyz.timer" ] \
  && fail "the timer was installed in the quadlet directory, where systemd cannot see it" \
  || pass "the timer is not in the quadlet directory"
grep -q 'enable --now kori-readyz.timer' "$STATE/calls.log" \
  && pass "the timer is enabled, not just written" \
  || fail "the timer was installed but never enabled: $(grep '^systemctl' "$STATE/calls.log" | tr '\n' ' ')"
grep -q '/healthz' "$KORI_SYSTEMD_DIR/kori-readyz.service" && pass "the probe asks /healthz" \
  || fail "the probe does not ask /healthz: $(grep ExecStart "$KORI_SYSTEMD_DIR/kori-readyz.service")"
grep -q '^ExecStart=.*/admin/' "$KORI_SYSTEMD_DIR/kori-readyz.service" \
  && fail "the probe asks a gated path; it would page on a healthy host" \
  || pass "the probe never borrows the gated admin surface"
grep -q 'OnFailure=alert@%N.service' "$KORI_SYSTEMD_DIR/kori-readyz.service" \
  && pass "a failed probe pages through the host alert sink" \
  || fail "the probe carries no OnFailure, so a failure is silent"
# An unchanged probe must not be reinstalled: rewriting the unit restarts nothing today but leaves
# a diff and a daemon-reload on every deploy.
before="$(cksum <"$KORI_SYSTEMD_DIR/kori-readyz.service")"
rc="$(run refs/heads/main)"
[ "$(cksum <"$KORI_SYSTEMD_DIR/kori-readyz.service")" = "$before" ] \
  && pass "an unchanged probe unit is left alone" \
  || fail "the probe unit was rewritten for an identical file"
unset KORI_SYSTEMD_DIR

# ── scenario 3b: the pulled tag is the sha of the commit that was checked out ─
grep -qxF "podman pull $(sha_ref)" "$STATE/calls.log" && pass "pulled $(sha_ref)" \
  || fail "did not pull $(sha_ref): $(grep '^podman pull' "$STATE/calls.log")"
grep -q 'podman inspect -f {{ index .Labels "org.opencontainers.image.revision" }}' "$STATE/calls.log" \
  && pass "revision label read from the pulled image" || fail "revision label never read"
grep -q 'cosign verify' "$STATE/calls.log" && pass "signature verified" || fail "cosign never ran"
grep -qF -- '--certificate-identity-regexp ^https://github.com/nferdazel/kori/' "$STATE/calls.log" \
  && pass "signature pinned to this repo's workflow identity" \
  || fail "cosign identity not pinned to this repo"
grep -qxF "podman rmi $(sha_ref)" "$STATE/calls.log" && pass "sha tag removed after retag" \
  || fail "sha tag left behind: $(grep '^podman rmi' "$STATE/calls.log")"
# The tag is only a filename: verification and the :local tag must use the digest the pulled
# bytes report, so a tag moved between pull and verify cannot reach the running container.
DIGEST_REF="ghcr.io/nferdazel/kori-api@sha256:$(printf 'a%.0s' {1..64})"
grep -qF "cosign verify $DIGEST_REF" "$STATE/calls.log" && pass "signature verified on the digest" \
  || fail "cosign did not verify the digest: $(grep '^cosign' "$STATE/calls.log")"
grep -qxF "podman tag $DIGEST_REF localhost/kori:local" "$STATE/calls.log" \
  && pass ":local tagged from the digest, not from the tag" \
  || fail ":local not tagged from the digest: $(grep '^podman tag' "$STATE/calls.log")"

# ── scenario 3c: one digest under two repository names is one candidate ─────
# Measured on qouver1, 2026-11-16: once the image is also tagged :local, the same digest is
# recorded as both ghcr.io/...@sha256:X and localhost/...@sha256:X. Counting lines instead of
# distinct digests makes that read as two non-children, pulled_digest returns empty and a
# redeploy of an unchanged commit aborts as "reports no digest". Remove the dedup and this fails.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=ok
DUP_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
FAKE_REPO_DIGESTS="ghcr.io/nferdazel/kori-api@$DUP_DIGEST
localhost/kori@$DUP_DIGEST"
export FAKE_REPO_DIGESTS
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "one digest under two repo names still deploys" \
  || fail "duplicate RepoDigests exited $rc: $(tail -2 "$APP_DIR/logs/deploy.log")"
grep -qxF "podman tag ghcr.io/nferdazel/kori-api@$DUP_DIGEST localhost/kori:local" "$STATE/calls.log" \
  && pass "deduped candidate tagged :local once" \
  || fail "duplicate digests were not resolved to one index: $(grep '^podman tag' "$STATE/calls.log")"
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$(head_sha)" ] \
  && pass "deduped redeploy moved .deployed_rev" || fail "deduped redeploy never completed"

# ── scenario 3d: a bare image manifest is not a signed index -> abort ───────
# An image manifest has no children to subtract, so there is no index digest to verify. The host
# must fail closed rather than present the per-arch digest as the signed one.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=ok FAKE_MANIFEST=image-manifest
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "bare image manifest exits non-zero ($rc)" \
  || fail "bare image manifest exited 0"
grep -q "reports no digest" "$APP_DIR/logs/deploy.log" && pass "unknown shape aborts loudly" \
  || fail "unknown shape message missing: $(tail -2 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "unknown shape left the container running" \
  || fail "unknown shape restarted the service"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written for an unknown shape" \
  || pass "unknown shape did not move .deployed_rev"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "unknown shape moved no tag" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"
grep -q '^cosign' "$STATE/calls.log" && fail "cosign ran without a digest" \
  || pass "cosign never ran without a digest"

# ── scenario 3e: a docker manifest list is accepted like an OCI index ───────
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=ok FAKE_MANIFEST=docker-list
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "docker manifest list deploys" \
  || fail "docker manifest list exited $rc: $(tail -2 "$APP_DIR/logs/deploy.log")"
grep -qxF "podman tag ghcr.io/nferdazel/kori-api@$DUP_DIGEST localhost/kori:local" "$STATE/calls.log" \
  && pass "docker manifest list tagged the index :local" \
  || fail "docker manifest list did not tag the index: $(grep '^podman tag' "$STATE/calls.log")"
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$(head_sha)" ] \
  && pass "docker manifest list moved .deployed_rev" || fail "docker manifest list never completed"

# ── scenario 3f: the config mount is a writable directory, created 0700 ────
# A single-file :ro bind is what made every OAuth rotation vanish at the next container restart:
# the refresh writes a temp in the same directory and renames it over the config, which a file
# bind cannot take. The unit must mount the directory rw and the deploy must create it.
reset_state
rm -rf "${APP_DIR:?}/etc"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "config-dir deploy exits 0" \
  || fail "config-dir deploy exited $rc: $(tail -3 "$ROOT/out.txt")"
UNIT_LIVE="$UNIT_DIR/kori-api.container"
grep -qxF 'Volume=/srv/qouver/apps/kori/etc:/etc/kori:rw,Z' "$UNIT_LIVE" \
  && pass "unit mounts the config directory rw with a private label" \
  || fail "unit mount line: $(grep '^Volume=' "$UNIT_LIVE" | tr '\n' ' ')"
grep -q 'config.json:/etc/kori/config.json' "$UNIT_LIVE" \
  && fail "unit still single-file mounts config.json" || pass "no single-file config bind"
[ -d "$APP_DIR/etc" ] && pass "deploy created the config directory" || fail "config directory missing"
[ -n "$(find "$APP_DIR/etc" -maxdepth 0 -perm 0700 2>/dev/null)" ] \
  && pass "config directory is 0700" || fail "config directory mode is not 0700"
# The gate is what stops a later unit edit from undoing the mount, so it must name the old shape.
grep -qF 'config\.json:/etc/kori/config\.json' "$DEPLOY" \
  && pass "the hardening gate refuses a single-file config bind" \
  || fail "the gate no longer names the single-file bind"

# ── scenario 3g: the edge token never reaches argv or a world-readable file ─
# The token used to go through `sed`, so it sat in an argv any user on the host could read with
# `ps`, and the redirect created the temp at the shell umask (0644). Both are assertions now.
reset_state
rm -rf "${APP_DIR:?}/caddy"
# An older deploy could have left the log at 0644; the script has to narrow it on every run, not
# only set the mode when it creates the file.
mkdir -p "$APP_DIR/logs"
printf 'old run\n' >"$APP_DIR/logs/deploy.log"
chmod 0644 "$APP_DIR/logs/deploy.log"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "edge render exits 0" || fail "edge render exited $rc"
RENDERED="$APP_DIR/caddy/site.caddy"
[ -n "$(find "$RENDERED" -maxdepth 0 -perm 0640 2>/dev/null)" ] \
  && pass "rendered edge block is 0640" || fail "rendered edge block mode is not 0640"
leftovers="$(find "$APP_DIR/caddy" -mindepth 1 -maxdepth 1 ! -name site.caddy -print 2>/dev/null)"
[ -z "$leftovers" ] && pass "no temp file left in caddy/" || fail "leftovers in caddy/: $leftovers"
[ -n "$(find "$APP_DIR/logs/deploy.log" -maxdepth 0 -perm 0600 2>/dev/null)" ] \
  && pass "deploy log is 0600, so a journal line carrying a credential is not world-readable" \
  || fail "deploy log mode is not 0600"
[ -n "$(find "$APP_DIR/logs/smoke.log" -maxdepth 0 -perm 0600 2>/dev/null)" ] \
  && pass "smoke log is 0600 like the deploy log" \
  || fail "smoke log mode is $(stat -f '%Lp' "$APP_DIR/logs/smoke.log" 2>/dev/null || stat -c '%a' "$APP_DIR/logs/smoke.log" 2>/dev/null)"
grep -q 'old run' "$APP_DIR/logs/deploy.log" \
  && pass "a log left at 0644 by an older deploy is narrowed in place, not replaced" \
  || fail "deploy log was replaced instead of narrowed: $(head -2 "$APP_DIR/logs/deploy.log")"
grep -qE '^[[:space:]]*cp -p .*RENDERED' "$DEPLOY" \
  && fail "the caddy backup still uses cp -p, which needs caddy group membership" \
  || pass "the caddy backup does not depend on the deploy user's group membership"
grep -q 'Bearer dryrun-token' "$RENDERED" && pass "bearer line carries the rendered token" \
  || fail "bearer line not rendered: $(grep -n 'no_bearer' "$RENDERED" | head -2)"
# `servers` is a global option in Caddy, not a site-block directive. Written inside the site block
# it fails at adapt time and takes every site on the host down with the restart (2026-11-16).
grep -qE '^[[:space:]]*servers[[:space:]]*\{' "$KIT/ops/caddy/Caddyfile.kori.example" \
  && fail "the edge template carries a site-block 'servers' directive" \
  || pass "the edge template has no site-block 'servers' directive"
# An external process carrying the token in argv is the bug; a shell builtin substitution is not.
TOKEN_ARGV="$(grep -nE '^[^#]*\b(sed|awk|printf)\b[^#]*\$\{?KORI_EDGE_TOKEN' "$DEPLOY" || true)"
[ -z "$TOKEN_ARGV" ] && pass "no sed/awk/printf line carries the edge token" \
  || fail "an external command carries the token: $TOKEN_ARGV"
grep -qE '^[[:space:]]*umask 077' "$DEPLOY" && pass "the render runs under umask 077" \
  || fail "no umask 077 before the render"

# ── scenario 3h: a caddy that rejects the block fails the deploy, old block back ─
# Caddy cannot load the new block: every site on the host goes down if this is only a WARN. The
# deploy must restore the block that was serving, restart once more, and exit non-zero before the
# app is touched.
reset_state
mkdir -p "$APP_DIR/caddy"
printf '# previous block that was serving\n' >"$APP_DIR/caddy/site.caddy"
chmod 0640 "$APP_DIR/caddy/site.caddy"
PREV_SUM="$(cksum <"$APP_DIR/caddy/site.caddy")"
happy_image
export FAKE_CURL=ok FAKE_SYSTEMCTL_CADDY=once
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "caddy rejection exits non-zero ($rc)" || fail "caddy rejection exited 0"
grep -q 'caddy rejected the rendered block' "$APP_DIR/logs/deploy.log" \
  && pass "caddy rejection is named in the deploy log" \
  || fail "caddy rejection not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(cksum <"$APP_DIR/caddy/site.caddy")" = "$PREV_SUM" ] \
  && pass "previous edge block restored byte-identical" \
  || fail "previous edge block not restored: $(cat "$APP_DIR/caddy/site.caddy")"
grep -q 'REJECTED at the edge' "$APP_DIR/logs/deploy.log" \
  && pass "restore retry is reported" \
  || fail "restore retry not reported: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "caddy rejection restarted no kori-api" \
  || fail "caddy rejection still restarted kori-api"

# ── scenario 3i: caddy down and no previous block -> remove the file, exit non-zero ─
# The first deploy on a host has nothing to restore. The last state Caddy loaded is "no file at
# this path", so the unloadable block is removed and the deploy fails loudly.
reset_state
rm -rf "${APP_DIR:?}/caddy"
happy_image
export FAKE_CURL=ok FAKE_SYSTEMCTL_CADDY=fail
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "dead caddy exits non-zero ($rc)" || fail "dead caddy exited 0"
grep -q 'public edge is down, human needed' "$APP_DIR/logs/deploy.log" \
  && pass "dead caddy is reported as an edge outage" \
  || fail "edge outage not reported: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ -f "$APP_DIR/caddy/site.caddy" ] && fail "dead caddy left the unloadable block in place" \
  || pass "dead caddy removed the unloadable block"
unset FAKE_SYSTEMCTL_CADDY

# ── scenario 3j: a run that dies after the backup leaves no token copy behind ─
# The backup is a copy of the rendered block, so it carries the edge token; only the exit trap
# removes it when the run dies between the backup and the restart.
reset_state
mkdir -p "$APP_DIR/caddy"
printf '# previous block that was serving\n' >"$APP_DIR/caddy/site.caddy"
chmod 0640 "$APP_DIR/caddy/site.caddy"
# The commit needs a non-ops path too, or the script stops at the ops-only branch before the edge
# render is ever reached.
git -C "$WORK" rm --quiet ops/caddy/Caddyfile.kori.example
printf 'placeholder 2\n' >"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "drop edge template"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "missing edge template exits non-zero ($rc)" \
  || fail "missing edge template exited 0"
grep -q 'edge template missing' "$APP_DIR/logs/deploy.log" \
  && pass "missing edge template is named in the deploy log" \
  || fail "missing edge template not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
leftovers="$(find "$APP_DIR/caddy" -mindepth 1 -maxdepth 1 ! -name site.caddy -print 2>/dev/null)"
[ -z "$leftovers" ] && pass "no token-bearing backup left behind after a die" \
  || fail "backup left behind after a die: $leftovers"
# Put the kit back, so the scenarios after this one deploy the same tree.
git -C "$WORK" checkout --quiet HEAD~1 -- ops/caddy/Caddyfile.kori.example apps/api/src/kori.nim
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "restore edge template"
git -C "$WORK" push --quiet origin HEAD:main

# ── scenario 3k: a block that does not validate never reaches the restart ────
# `caddy validate` runs against the rendered block before the service is touched, so a syntax
# error costs zero downtime: the previous block goes back, caddy is not restarted, and the app is
# not touched either. Without this the host serves every site through a Caddy that refuses to
# start (measured 2026-11-16).
reset_state
mkdir -p "$APP_DIR/caddy"
printf '# previous block that was serving\n' >"$APP_DIR/caddy/site.caddy"
chmod 0640 "$APP_DIR/caddy/site.caddy"
PREV_SUM="$(cksum <"$APP_DIR/caddy/site.caddy")"
happy_image
export FAKE_CURL=ok FAKE_CADDY=invalid
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unvalidatable block exits non-zero ($rc)" \
  || fail "unvalidatable block exited 0"
grep -q 'does not validate' "$APP_DIR/logs/deploy.log" \
  && pass "the validation failure is named in the deploy log" \
  || fail "validation failure not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(cksum <"$APP_DIR/caddy/site.caddy")" = "$PREV_SUM" ] \
  && pass "previous edge block restored byte-identical on a validation failure" \
  || fail "previous edge block not restored: $(cat "$APP_DIR/caddy/site.caddy")"
grep -q 'systemctl restart caddy' "$STATE/calls.log" \
  && fail "caddy was restarted with a block that does not validate" \
  || pass "caddy was not restarted with a block that does not validate"
[ "$(restarts)" = "0" ] && pass "validation failure restarted no kori-api" \
  || fail "validation failure still restarted kori-api"
grep -q 'dryrun-token' "$APP_DIR/logs/deploy.log" \
  && fail "the validation log leaked the edge token" \
  || pass "the validation output is logged with the token masked"
# No previous block to restore: the file must still exist. /etc/caddy/Caddyfile imports it
# unconditionally, and a missing import target makes Caddy refuse to start on the next restart.
reset_state
happy_image
rm -f "$APP_DIR/caddy/site.caddy"
export FAKE_CURL=ok FAKE_CADDY=invalid
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "validation failure without a previous block exits non-zero ($rc)" \
  || fail "validation failure without a previous block exited 0"
[ -f "$APP_DIR/caddy/site.caddy" ] \
  && pass "a withdrawn block leaves the import target in place" \
  || fail "validation failure removed site.caddy, the import target is now dangling"
grep -q 'Bearer' "$APP_DIR/caddy/site.caddy" \
  && fail "the withdrawn block still carries the bearer" \
  || pass "the withdrawn block carries no bearer"
unset FAKE_CADDY

# ── scenario 4: a redeploy rotates :local to :prev ──────────────────────────
reset_state
printf 'local\n' >"$STATE/tags"   # pretend a previous deploy is running
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "redeploy exits 0" || fail "redeploy exited $rc"
grep -qxF 'prev' "$STATE/tags" && pass ":prev retag happened" || fail ":prev missing: $(tr '\n' ' ' <"$STATE/tags")"
first_tag="$(grep -E '^podman tag' "$STATE/calls.log" | head -1)"
[ "$first_tag" = "podman tag localhost/kori:local localhost/kori:prev" ] \
  && pass "retag runs first" || fail "first tag call was: $first_tag"
# The pull is what proves the image before any tag moves, so it must come first of all.
first_op="$(grep -E '^podman (pull|tag|build)' "$STATE/calls.log" | head -1)"
case "$first_op" in
  "podman pull "*) pass "pull precedes every tag move" ;;
  *) fail "first podman op was: $first_op" ;;
esac

# ── scenario 5: no commit-SHA tag survives in the image store ───────────────
sha_tags="$(grep -E '^[0-9a-f]{7,40}$' "$STATE/tags" || true)"
[ -z "$sha_tags" ] && pass "no commit-SHA tag in the image store" || fail "SHA tags found: $sha_tags"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local prev " ] \
  && pass "retained tags are exactly :local and :prev" \
  || fail "retained tags: $(sort -u "$STATE/tags" | tr '\n' ' ')"

# ── scenario 6: revision label mismatch -> die, nothing touched ────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=ok FAKE_COSIGN=ok FAKE_CURL=ok
export FAKE_REV="0000000000000000000000000000000000000000"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "revision mismatch exits non-zero ($rc)" || fail "revision mismatch exited 0"
grep -q 'says revision' "$APP_DIR/logs/deploy.log" && pass "mismatch names the two revisions" \
  || fail "mismatch not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "mismatch never restarted the service" || fail "mismatch restarted the service"
grep -q 'cosign' "$STATE/calls.log" && fail "cosign ran on an unverified-revision image" \
  || pass "cosign skipped when the revision is wrong"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "tags untouched by the mismatch" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written for a rejected image" \
  || pass "rejected image did not move .deployed_rev"

# ── scenario 7: cosign failure -> die, nothing touched ─────────────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=ok FAKE_CURL=ok FAKE_COSIGN=fail
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unsigned image exits non-zero ($rc)" || fail "unsigned image exited 0"
grep -q 'cosign verify failed' "$APP_DIR/logs/deploy.log" && pass "signature failure logged" \
  || fail "signature failure not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "unsigned image never restarted the service" \
  || fail "unsigned image restarted the service"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "tags untouched by the signature failure" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"
export FAKE_COSIGN=ok

# ── scenario 8: registry 502 -> die (not "not built") ──────────────────────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=error FAKE_COSIGN=ok FAKE_CURL=ok
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "registry 502 exits non-zero ($rc)" || fail "registry 502 exited 0"
grep -q "registry pull failed and this is NOT 'not built'" "$APP_DIR/logs/deploy.log" \
  && pass "502 is not read as 'not built'" || fail "502 message missing: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "502 never restarted the service" || fail "502 restarted the service"

# ── scenario 9: no image for this commit -> keep the running container ─────
reset_state
printf 'local\n' >"$STATE/tags"
export FAKE_PULL=notbuilt FAKE_COSIGN=ok FAKE_CURL=ok
FAKE_REV="$(head_sha)"
export FAKE_REV
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "not-built exits 0" || fail "not-built exited $rc"
grep -q 'no image for' "$APP_DIR/logs/deploy.log" && pass "not-built says so" \
  || fail "not-built message missing: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "not-built left the container running" || fail "not-built restarted the service"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written when nothing was deployed" \
  || pass "not-built did not move .deployed_rev"
[ "$(sort -u "$STATE/tags" | tr '\n' ' ')" = "local " ] && pass "not-built left the tags alone" \
  || fail "tags moved: $(sort -u "$STATE/tags" | tr '\n' ' ')"

# ── scenario 9b: image appears after the gate finishes -> deploy, not a no-op ─
# The webhook reaches the host before CI has pushed the tag. Reading the first "manifest
# unknown" as "this commit built nothing" is exactly the race that left sds one revision behind.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_PULL=late FAKE_PULL_LATE=2 FAKE_CURL=ok
export KORI_IMAGE_WAIT_ATTEMPTS=5
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "late image exits 0" || fail "late image exited $rc: $(tail -3 "$ROOT/out.txt")"
grep -q 'not in the registry yet' "$APP_DIR/logs/deploy.log" \
  && pass "waited for the tag instead of reading it as not built" \
  || fail "no wait line in the log: $(tail -3 "$APP_DIR/logs/deploy.log")"
pulls="$(grep -c "^podman pull $(sha_ref)" "$STATE/calls.log" || true)"
[ "$pulls" = "3" ] && pass "three pulls: two misses, then the tag" \
  || fail "expected 3 pull attempts, saw $pulls"
[ "$(cat "$APP_DIR/.deployed_rev" 2>/dev/null)" = "$(head_sha)" ] \
  && pass "late image was deployed, not skipped" || fail "late image never moved .deployed_rev"

# ── scenario 9c: the tag never appears -> keep the container, name the window ─
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_PULL=late FAKE_PULL_LATE=99 FAKE_CURL=ok
export KORI_IMAGE_WAIT_ATTEMPTS=2
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "exhausted wait exits 0" || fail "exhausted wait exited $rc"
grep -q 'no image for .* after 2 attempts' "$APP_DIR/logs/deploy.log" \
  && pass "not-built message names the attempt count" \
  || fail "attempt count missing: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "exhausted wait left the container running" \
  || fail "exhausted wait restarted the service"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written when no image ever came" \
  || pass "exhausted wait did not move .deployed_rev"
unset KORI_IMAGE_WAIT_ATTEMPTS

# ── scenario 10: health gate red -> rollback to :prev, deploy rejected ─────
reset_state
printf 'local\n' >"$STATE/tags"     # a good image already serving
happy_image
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif \
  commit --quiet --allow-empty -m "bad build"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
export FAKE_CURL=recover
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unhealthy deploy exits non-zero ($rc)" || fail "unhealthy deploy exited 0"
grep -q 'health gate failed' "$APP_DIR/logs/deploy.log" && pass "health gate logged as failed" \
  || fail "health gate failure not logged"
grep -q 'rollback to :prev healthy (image only); deploy of' "$APP_DIR/logs/deploy.log" && pass "rollback to :prev succeeded" \
  || fail "no successful rollback line: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "2" ] && pass "restarted twice: new image, then :prev" \
  || fail "expected 2 restarts, saw $(restarts)"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev was written for a rejected deploy" \
  || pass "rejected deploy did not move .deployed_rev"

# ── scenario 10b: health green, smoke red -> same rollback as an unhealthy box ─
# The smoke gate is new in this diff. A container that answers /admin/state with a body the log
# reader cannot parse is not a deploy, even though wait_healthy is satisfied (it reads the exit
# code only). Without this scenario the smoke branch could rot into dead code.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=nonjson
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "smoke failure exits non-zero ($rc)" || fail "smoke failure exited 0"
grep -q 'health gate passed but smoke failed' "$APP_DIR/logs/deploy.log" \
  && pass "smoke failure is named apart from the health gate" \
  || fail "smoke failure not named: $(tail -3 "$APP_DIR/logs/deploy.log")"
grep -q 'body is not JSON' "$APP_DIR/logs/deploy.log" \
  && pass "smoke's reason is in the deploy log" \
  || fail "deploy log does not carry smoke's reason: $(tail -4 "$APP_DIR/logs/deploy.log")"
grep -q 'rollback to :prev healthy (image only); deploy of' "$APP_DIR/logs/deploy.log" \
  && pass "smoke failure rolled back to :prev" \
  || fail "no rollback after smoke failure: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written for a smoke-rejected deploy" \
  || pass "smoke-rejected deploy did not move .deployed_rev"
unset FAKE_CURL

# ── scenario 11: both images sick -> no false comfort, exit non-zero ───────
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_CURL=fail
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "double failure exits non-zero ($rc)" || fail "double failure exited 0"
grep -q 'the :prev image is not healthy either' "$APP_DIR/logs/deploy.log" && pass "double failure says a human is needed" \
  || fail "double failure not reported: $(tail -2 "$APP_DIR/logs/deploy.log")"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written after double failure" \
  || pass "no .deployed_rev after double failure"

# ── scenario 12: another deploy holds the lock -> wait, then refuse ────────
reset_state
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
# -w <seconds> <fd>: the wait expires, the lock is still held
exit 1
STUB
chmod +x "$BIN/flock"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "busy lock exits non-zero ($rc)" || fail "busy lock exited 0"
grep -q 'lock still held' "$APP_DIR/logs/deploy.log" && pass "busy lock says so" \
  || fail "busy lock message missing"
[ ! -s "$STATE/calls.log" ] && pass "busy lock ran no podman/systemctl" \
  || fail "busy lock still ran: $(tr '\n' ' ' <"$STATE/calls.log")"

# ── scenario 13: env file missing -> die before git sync ───────────────────
reset_state
cat >"$BIN/flock" <<'STUB'
#!/usr/bin/env bash
[ -n "${PODMAN_STATE:-}" ] && printf 'flock %s\n' "$*" >>"$PODMAN_STATE/flock_calls.log"
exit 0
STUB
chmod +x "$BIN/flock"
mv "$APP_DIR/env/kori-prod.env" "$ROOT/env.bak"
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "missing env file exits non-zero ($rc)" || fail "missing env file exited 0"
grep -q 'env file missing' "$APP_DIR/logs/deploy.log" && pass "missing env file says so" \
  || fail "missing env message missing"
grep -q 'podman pull' "$STATE/calls.log" && fail "pulled without an env file" \
  || pass "no pull without an env file"
mv "$ROOT/env.bak" "$APP_DIR/env/kori-prod.env"

# ── scenario 15: a unit systemd will not load is never restarted into ───────
reset_state
printf 'local\n' >"$STATE/tags"
# The render gate only runs when the unit changed this deploy; without a live unit the staged one
# is installed, which is the path a first deploy takes.
rm -f "$UNIT_DIR/kori-api.container"
export FAKE_CURL=ok
happy_image
export FAKE_SYSTEMCTL_RENDER=not-found
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "unrenderable unit exits non-zero ($rc)" || fail "unrenderable unit exited 0"
grep -q 'does not render' "$APP_DIR/logs/deploy.log" \
  && pass "the failed render is named in the deploy log" \
  || fail "render failure not named: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" = "0" ] && pass "never restarted into a unit that does not render" \
  || fail "restarted into a unit that does not render"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written for an unrenderable unit" \
  || pass "unrenderable unit did not move .deployed_rev"
unset FAKE_SYSTEMCTL_RENDER

# ── scenario 14: the host never builds ─────────────────────────────────────
builds="$(grep -c 'podman build' "$DEPLOY" || true)"
[ "$builds" = "0" ] && pass "deploy script contains no 'podman build'" \
  || fail "deploy script still builds on the host ($builds match(es))"

# ── scenario 16: the lock waits, so a queued push still deploys ────────────
reset_state
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "queued deploy exits 0" || fail "queued deploy exited $rc"
grep -qE '^flock -w [0-9]+ 9$' "$STATE/flock_calls.log" 2>/dev/null \
  && pass "lock taken with -w (waits), not -n (skips)" \
  || fail "lock not taken with a bounded wait: $(cat "$STATE/flock_calls.log" 2>/dev/null)"
# The wait has to outlast the runs queued ahead of this one, and the longest those can take is
# spent polling the registry for an image CI has not published yet. Two such windows plus slack
# is the floor, and it is computed from the script's own defaults: a hardcoded number here passed
# while a raised window and an unchanged lock were still wrong together (Galih, 2026-11-27).
lock_wait="$(sed -n 's/^flock -w \([0-9][0-9]*\) 9$/\1/p' "$STATE/flock_calls.log" 2>/dev/null | head -1)"
# The numeric default of a tunable as the script writes it, covering `export NAME=`, a bare
# `NAME=60` and the `${KORI_NAME:-60}` form the script actually uses. A parse that finds nothing
# must not degrade to 0: the floor then collapsed to 600 and a hardcoded 640 s lock passed while
# the window was 120 (Galih, 2026-11-27). An unreadable tunable is a FAIL here, never a zero.
script_default() { # script_default <NAME>
  local raw
  raw="$(sed -n -E "s/^(export[[:space:]]+)?$1=//p" "$DEPLOY" | head -1)"
  case "$raw" in
    *':-'*) raw="${raw#*:-}"; raw="${raw%%\}*}" ;;
  esac
  printf '%s\n' "$raw" | tr -cd '0-9'
}
script_attempts="$(script_default IMAGE_WAIT_ATTEMPTS)"
script_interval="$(script_default IMAGE_WAIT_INTERVAL)"
if [ -z "$script_attempts" ] || [ -z "$script_interval" ]; then
  fail "could not read IMAGE_WAIT_ATTEMPTS/IMAGE_WAIT_INTERVAL from $DEPLOY (attempts='${script_attempts}', interval='${script_interval}'); the lock floor was not computed"
else
  lock_floor=$(( script_attempts * script_interval * 2 + 600 ))
  [ "${lock_wait:-0}" -ge "$lock_floor" ] \
    && pass "lock wait (${lock_wait}s) covers two image windows plus slack (${lock_floor}s)" \
    || fail "lock wait ${lock_wait:-0}s is below the two-window floor ${lock_floor}s (${script_attempts} x ${script_interval} s)"
fi
# The floor is computed from the knob declaration, so the loop that actually waits has to consume
# those same knobs, once and verbatim. A substring grep for the sleep line was beaten three ways
# while the suite stayed green: the text parked in a comment with the real sleep doubled, the loop
# bound widened to $((IMAGE_WAIT_ATTEMPTS * 2)), and IMAGE_WAIT_INTERVAL reassigned inside the loop
# (Galih, 2026-11-27). Every line is anchored now and each knob is assigned once, so any change to
# the real window has to move the declaration this floor is computed from.
wait_sleep='^[[:space:]]+sleep "\$IMAGE_WAIT_INTERVAL"[[:space:]]*$'
wait_bound='^[[:space:]]*\[ "\$attempt" -lt "\$IMAGE_WAIT_ATTEMPTS" \] \|\| return 1[[:space:]]*$'
wait_step='^[[:space:]]*attempt=\$\(\(attempt \+ 1\)\)[[:space:]]*$'
grep -qE "$wait_sleep" "$DEPLOY" \
  && pass "the image wait loop sleeps exactly IMAGE_WAIT_INTERVAL per attempt (anchored)" \
  || fail "no line sleeps exactly IMAGE_WAIT_INTERVAL; the lock floor no longer describes the window"
grep -qE "$wait_bound" "$DEPLOY" \
  && pass "the image wait loop stops at exactly IMAGE_WAIT_ATTEMPTS attempts (anchored)" \
  || fail "the image wait loop bound no longer compares attempt against IMAGE_WAIT_ATTEMPTS verbatim"
grep -qE "$wait_step" "$DEPLOY" \
  && pass "the image wait loop counts one attempt per poll (anchored)" \
  || fail "the image wait loop no longer increments attempt by one per poll"
# A knob reassigned anywhere — including inside the loop, where a rebind of IMAGE_WAIT_INTERVAL
# doubles the real delay while every line above still reads correct — makes the floor a lie. The
# count is taken over the whole file, so an indented or exported second assignment is caught too.
# The KORI_-prefixed read on the right-hand side is deliberately not matched: only a real
# assignment to the knob itself counts.
for knob in IMAGE_WAIT_ATTEMPTS IMAGE_WAIT_INTERVAL; do
  knob_assignments="$(grep -cE "(^|[^A-Za-z0-9_])${knob}=" "$DEPLOY" || true)"
  [ "$knob_assignments" = "1" ] \
    && pass "$knob is assigned once, where the floor reads it" \
    || fail "$knob is assigned $knob_assignments time(s); a second assignment moves the window without moving the floor"
done
FIRST_REV="$(cat "$APP_DIR/.deployed_rev")"
# A second push lands while the first deploy holds the lock. Its run must deploy that commit, not
# drop it: this is the 2026-11-18 drift (098e29b on the host, f76887a on main) reproduced.
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet --allow-empty -m "second push"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "follow-up push deploys ($rc)" || fail "follow-up push exited $rc"
[ "$(cat "$APP_DIR/.deployed_rev")" = "$(head_sha)" ] \
  && pass "host revision catches up to main after the queue" \
  || fail "host still behind main: $(cat "$APP_DIR/.deployed_rev") vs $(head_sha)"
[ "$FIRST_REV" != "$(head_sha)" ] && pass "the two runs deployed different commits" \
  || fail "harness did not move main between the runs"

# ── scenario 16b: the lock lives in the app dir at 0600, never in /tmp ──────
# Galih, 2026-11-19: /tmp is world-writable, so a lock file there can be pre-created by any local
# user before the deploy opens it. The app directory belongs to the deploy user, which is where
# sds and qouver already keep theirs. Asserted on the file the run actually made.
[ -f "$APP_DIR/.deploy.lock" ] && pass "lock file is $APP_DIR/.deploy.lock" \
  || fail "no lock file in the app dir: $(ls -a "$APP_DIR" | tr '\n' ' ')"
[ -n "$(find "$APP_DIR/.deploy.lock" -maxdepth 0 -perm 0600 2>/dev/null)" ] \
  && pass "lock file is 0600" \
  || fail "lock file mode is $(stat -c %a "$APP_DIR/.deploy.lock" 2>/dev/null || stat -f %Lp "$APP_DIR/.deploy.lock" 2>/dev/null)"
grep -qF '/tmp/deploy-' "$DEPLOY" \
  && fail "deploy script still references a /tmp lock path" \
  || pass "no /tmp lock path left in the deploy script"
grep -qF 'LOCK_FILE="$APP_DIR/.deploy.lock"' "$DEPLOY" \
  && pass "the lock path is derived from the app dir" \
  || fail "the lock path is not derived from the app dir"
# preflight probes the same lock; a deploy that moved and a preflight that did not would report
# "free" for a lock nobody takes.
grep -qF 'LOCK_FILE="$APP_DIR/.deploy.lock"' "$KIT/ops/scripts/preflight.sh" \
  && pass "preflight probes the same lock path" \
  || fail "preflight still probes a different lock path"

# ── scenario 16c: a lock file this user does not control is refused ─────────
# The point of moving out of /tmp was pre-creation. A symlink at the new path is the same attack
# with a friendlier directory, so the script must refuse rather than lock a name it does not own.
reset_state
rm -f "$APP_DIR/.deploy.lock"
ln -s /tmp/kori-lock-target "$APP_DIR/.deploy.lock"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "a symlinked lock file exits non-zero ($rc)" \
  || fail "a symlinked lock file was accepted"
grep -q 'refusing to take a lock someone else controls' "$APP_DIR/logs/deploy.log" \
  && pass "the refused lock is named in the deploy log" \
  || fail "the refused lock is not named: $(tail -2 "$APP_DIR/logs/deploy.log")"
grep -q '^podman pull' "$STATE/calls.log" && fail "pulled with an untrusted lock" \
  || pass "nothing was pulled with an untrusted lock"
rm -f "$APP_DIR/.deploy.lock"

# ── scenario 16d: the env file's window override is honoured, not shadowed ──
# 0.10.9 read IMAGE_WAIT_ATTEMPTS above the `. "$ENV_FILE"` sourcing, so a value documented as
# tunable in kori-prod.env was silently ignored while the same knob in the caller's environment
# still worked (Galih, 2026-11-27). The attempt count is in the give-up line, so it says which one
# the script actually used: 1 here is the env file's value, 60 would be the default.
reset_state
printf 'local\n' >"$STATE/tags"
happy_image
export FAKE_PULL=late FAKE_PULL_LATE=99 FAKE_CURL=ok
printf 'KORI_EDGE_TOKEN=dryrun-token\nKORI_IMAGE_WAIT_ATTEMPTS=1\n' >"$APP_DIR/env/kori-prod.env"
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "env-file window override run exits 0 ($rc)" || fail "env-file window override exited $rc: $(tail -3 "$ROOT/out.txt")"
grep -q 'no image for .* after 1 attempts' "$APP_DIR/logs/deploy.log" \
  && pass "kori-prod.env's KORI_IMAGE_WAIT_ATTEMPTS reached the wait loop" \
  || fail "env-file window override ignored: $(grep -o 'after [0-9]* attempts' "$APP_DIR/logs/deploy.log" | tail -1)"
rb_lock="$(sed -n 's/^flock -w \([0-9][0-9]*\) 9$/\1/p' "$STATE/flock_calls.log" 2>/dev/null | head -1)"
if [ -z "$script_interval" ]; then
  fail "IMAGE_WAIT_INTERVAL unreadable from $DEPLOY; the expected lock for a 1-attempt window cannot be computed"
else
  expected_lock=$(( 1 * script_interval * 2 + 600 ))
  [ "${rb_lock:-0}" = "$expected_lock" ] \
    && pass "the lock timeout follows the overridden window (${rb_lock}s = ${expected_lock}s), not the default" \
    || fail "lock timeout ${rb_lock:-0}s did not follow the overridden window (expected ${expected_lock}s)"
fi
unset FAKE_PULL FAKE_PULL_LATE
printf 'KORI_EDGE_TOKEN=dryrun-token\n' >"$APP_DIR/env/kori-prod.env"

# ── scenario 17: the self-update re-exec keeps the lock, does not re-take it ─
# The script copies itself and re-execs when the repo copy differs. That exec must inherit the
# held lock: re-acquiring would close fd 9, drop it for a moment, and a queued run could take it
# while this one waits its whole timeout. Proof: the run publishes a new script copy and flock is
# still called exactly once.
reset_state
happy_image
export FAKE_CURL=ok
printf '\n# harness: force the self-update path\n' >>"$WORK/ops/scripts/deploy-vps.sh"
# A non-ops path too, or the run stops at the ops-only branch before it ever pulls an image and
# there is no .deployed_rev to compare.
printf '# harness: image-bearing change\n' >>"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "tweak deploy script"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "self-update run exits 0 ($rc)" || fail "self-update run exited $rc: $(tail -3 "$ROOT/out.txt")"
grep -q 're-executing the updated deploy-vps.sh' "$APP_DIR/logs/deploy.log" \
  && pass "the run did take the self-update path" || fail "self-update never happened"
flock_calls="$(grep -c '^flock ' "$STATE/flock_calls.log" 2>/dev/null || true)"
[ "$flock_calls" = "1" ] && pass "lock taken once across the re-exec, not dropped and retaken" \
  || fail "flock called $flock_calls time(s) across the re-exec"
[ "$(cat "$APP_DIR/.deployed_rev")" = "$(head_sha)" ] && pass "self-update run deployed its commit" \
  || fail "self-update run did not deploy: $(cat "$APP_DIR/.deployed_rev") vs $(head_sha)"
# Every helper in ops/scripts, not a hand-kept pair: on 2026-11-20 the host copy of
# contract-check.sh was 379 lines behind the repo and kori-config.sh had never been installed,
# because the sync loop only named smoke.sh and rollback.sh. Nothing failed while it aged.
missing_helpers=""
for f in "$WORK"/ops/scripts/*.sh; do
  name="$(basename "$f")"
  [ "$name" = "deploy-vps.sh" ] && continue
  cmp -s "$f" "$APP_DIR/scripts/$name" || missing_helpers="$missing_helpers $name"
done
[ -z "$missing_helpers" ] && pass "every ops/scripts helper reached the app dir" \
  || fail "helpers not synced:$missing_helpers"

# ── scenario 18: a queued run that finds its commit already live does nothing ─
# Three pushes during one deploy means three queued handlers. The first one deploys the newest
# commit; the others re-read main and find the same revision. Retagging :local into :prev and
# restarting for identical bytes would burn the rollback slot, so they must stop.
reset_state
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "first run deploys ($rc)" || fail "first run exited $rc"
deployed="$(cat "$APP_DIR/.deployed_rev")"
: >"$STATE/calls.log"
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "duplicate revision exits 0 ($rc)" || fail "duplicate revision exited $rc"
grep -q 'already running' "$APP_DIR/logs/deploy.log" && pass "duplicate revision says so" \
  || fail "duplicate revision message missing: $(tail -2 "$APP_DIR/logs/deploy.log")"
grep -q '^podman pull' "$STATE/calls.log" && fail "duplicate revision pulled an image" \
  || pass "duplicate revision pulled nothing"
[ "$(restarts)" = "0" ] && pass "duplicate revision restarted nothing" \
  || fail "duplicate revision restarted the service"
[ "$(cat "$APP_DIR/.deployed_rev")" = "$deployed" ] && pass "duplicate revision kept .deployed_rev" \
  || fail "duplicate revision moved .deployed_rev"

# ── scenario 19: the smoke gate cannot run -> refuse, do not pass ──────────
# run_smoke used to `return 0` when scripts/smoke.sh was absent, so the one gate that proves the
# release was not a release gate that passed — the deploy reached .deployed_rev with nothing
# behind it. The helper sync copies every ops/scripts/*.sh, so a file missing from the repo is
# missing from the app dir too, which is exactly the real shape.
reset_state
printf 'local\nprev\n' >"$STATE/tags"
git -C "$WORK" rm --quiet ops/scripts/smoke.sh
# A non-ops path too, or the run stops at the ops-only branch before it ever pulls an image.
printf '# harness: missing smoke gate\n' >>"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "drop smoke"
git -C "$WORK" push --quiet origin HEAD:main
rm -f "$APP_DIR/scripts/smoke.sh"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" != "0" ] && pass "a deploy without smoke.sh exits non-zero ($rc)" \
  || fail "a missing smoke gate passed the deploy"
grep -q 'smoke gate cannot run' "$APP_DIR/logs/deploy.log" \
  && pass "the missing smoke gate is an ERROR in the deploy log" \
  || fail "missing smoke gate not logged: $(tail -3 "$APP_DIR/logs/deploy.log")"
grep -q 'health gate passed but smoke failed' "$APP_DIR/logs/deploy.log" \
  && pass "the missing gate takes the same rollback path" \
  || fail "the missing gate did not reach the rollback path: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(restarts)" -ge 2 ] && pass "restarted twice: new image, then :prev" \
  || fail "expected a rollback restart, saw $(restarts)"
[ -f "$APP_DIR/.deployed_rev" ] && fail ".deployed_rev written without a smoke gate" \
  || pass "no .deployed_rev without a smoke gate"
# Put the kit back, so the scenarios after this one deploy the same tree.
git -C "$WORK" checkout --quiet HEAD~1 -- ops/scripts/smoke.sh
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "restore smoke"
git -C "$WORK" push --quiet origin HEAD:main
unset FAKE_CURL

# ── scenario 20: an empty edge token is announced, the old block is not clobbered ──
# The render sits under `if [ -n "$KORI_EDGE_TOKEN" ]`, which is right (a host can be edge-less),
# but the else branch was silent. The block on disk keeps the last bearer rendered, so "the edge was
# not touched" has to be a line in the deploy log or the next reader assumes it was re-rendered.
reset_state
mkdir -p "$APP_DIR/caddy"
printf '# block from an earlier deploy\n' >"$APP_DIR/caddy/site.caddy"
chmod 0640 "$APP_DIR/caddy/site.caddy"
PREV_EDGE_SUM="$(cksum <"$APP_DIR/caddy/site.caddy")"
printf 'KORI_EDGE_TOKEN=\n' >"$APP_DIR/env/kori-prod.env"
# A non-ops path too, or the ops-only branch stops the run before the edge section.
printf '# harness: empty edge token\n' >>"$WORK/apps/api/src/kori.nim"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=arif@kori.local -c user.name=Arif commit --quiet -m "empty edge token"
git -C "$WORK" push --quiet origin HEAD:main
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "a deploy with an empty edge token still deploys ($rc)" \
  || fail "a deploy with an empty edge token exited $rc: $(tail -3 "$ROOT/out.txt")"
grep -q 'KORI_EDGE_TOKEN is empty; the ai.qouver.com' "$APP_DIR/logs/deploy.log" \
  && pass "the empty edge token is announced in the deploy log" \
  || fail "the empty edge token is silent: $(tail -3 "$APP_DIR/logs/deploy.log")"
[ "$(cksum <"$APP_DIR/caddy/site.caddy")" = "$PREV_EDGE_SUM" ] \
  && pass "the previous edge block is left untouched" \
  || fail "the edge block changed without a token"
[ -f "$APP_DIR/.deployed_rev" ] && pass "an edge-less deploy still records its revision" \
  || fail "an edge-less deploy recorded nothing"
unset FAKE_CURL

# ── scenario 3l: an unchanged edge block does not restart caddy ─────────────
# Caddy's unit sets TimeoutStopSec=5s, so `systemctl restart caddy` SIGKILLs it and cuts every
# stream in flight. The deploy restarted it on every run regardless, because the render always
# rewrote the file: qouver1's journal carried four `Failed with result 'timeout'` lines by
# 2026-11-21 for a block that had barely changed. An identical render must be a no-op.
reset_state
# Scenario 20 above leaves an empty edge token on purpose; this one needs a real one.
printf 'KORI_EDGE_TOKEN=dryrun-token\n' >"$APP_DIR/env/kori-prod.env"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "first deploy with an edge block exits 0" || fail "first edge deploy exited $rc"
[ -f "$APP_DIR/caddy/site.caddy" ] && pass "the first deploy renders the block" \
  || fail "the first deploy rendered nothing"
: >"$STATE/calls.log"
# The second run must get past the "already at this revision" stop to reach the render at all.
export KORI_FORCE_DEPLOY=1
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "redeploy with an identical block exits 0" || fail "identical redeploy exited $rc"
grep -q 'sudo systemctl restart caddy' "$STATE/calls.log" \
  && fail "caddy was restarted for a byte-identical block" \
  || pass "an unchanged edge block does not restart caddy"
grep -q 'edge block unchanged' "$APP_DIR/logs/deploy.log" \
  && pass "the skip is announced in the deploy log" \
  || fail "the skip is silent: $(tail -3 "$APP_DIR/logs/deploy.log")"
leaked="$(find "$APP_DIR/caddy" -mindepth 1 -maxdepth 1 ! -name site.caddy -print 2>/dev/null)"
[ -z "$leaked" ] && pass "a skipped render leaves no token-bearing backup" \
  || fail "a skipped render left a backup behind: $leaked"

# ── scenario 3m: a rotated edge token still restarts caddy ─────────────────
# The comparison is on the rendered bytes, so the skip above must not become a way to keep serving
# a bearer nobody chose.
reset_state
printf 'KORI_EDGE_TOKEN=rotated-dryrun-token\n' >"$APP_DIR/env/kori-prod.env"
happy_image
export FAKE_CURL=ok
rc="$(run refs/heads/main)"
[ "$rc" = "0" ] && pass "a token rotation deploys ($rc)" || fail "a token rotation exited $rc"
unset KORI_FORCE_DEPLOY
grep -q 'sudo systemctl restart caddy' "$STATE/calls.log" \
  && pass "a rotated token restarts caddy" || fail "a rotated token did not reach caddy"
grep -q 'rotated-dryrun-token' "$APP_DIR/caddy/site.caddy" \
  && pass "the new bearer is in the rendered block" || fail "the block still carries the old bearer"
printf 'KORI_EDGE_TOKEN=dryrun-token\n' >"$APP_DIR/env/kori-prod.env"

printf '\n%s\n' "artifacts: $ROOT"
if [ "$FAILS" -eq 0 ]; then
  printf 'RESULT: all scenarios passed\n'
  exit 0
fi
printf 'RESULT: %s check(s) failed\n' "$FAILS"
exit 1
