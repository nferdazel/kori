#!/bin/sh
# Dry run for tools/phase2-metrics.sh: fixed input, fixed table. Proves the buckets, the
# nearest-rank percentiles and the skipped count on lines this repository can carry now,
# without waiting for 48 hours of production log.
set -eu
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Two short requests, one 33-128 KiB, one over 512 KiB, and one line from before 0.10.5.
# The 64 KiB line failed its first leg's header deadline, so the timeout section has
# one row in 33-128 and none elsewhere.
cat >"$tmp/requests.jsonl" <<'EOF'
{"ts":"t","route":"a","status":200,"latency_ms":900,"tokens_in":1,"tokens_out":1,"failover_from":"","failover_reason":"","stream":false,"prompt_kib":8,"header_ms":120}
{"ts":"t","route":"a","status":200,"latency_ms":900,"tokens_in":1,"tokens_out":1,"failover_from":"","failover_reason":"","stream":false,"prompt_kib":9,"header_ms":140}
{"ts":"t","route":"b","status":200,"latency_ms":900,"tokens_in":1,"tokens_out":1,"failover_from":"a","failover_reason":"header_timeout","stream":false,"prompt_kib":64,"header_ms":800}
{"ts":"t","route":"a","status":200,"latency_ms":900,"tokens_in":1,"tokens_out":1,"failover_from":"","failover_reason":"","stream":false,"prompt_kib":600,"header_ms":9000}
{"ts":"t","route":"a","status":200,"latency_ms":900,"tokens_in":null,"tokens_out":null,"failover_from":"","failover_reason":"","stream":false}
EOF

out=$(sh tools/phase2-metrics.sh "$tmp/requests.jsonl")
printf '%s\n' "$out"

fail=0
expect() {
  printf '%s\n' "$out" | grep -qF "$1" || { echo "FAIL  missing: $1" >&2; fail=1; }
}

expect "<=32           2        8        9        9       120       140       140"
expect "33-128         1       64       64       64       800       800       800"
expect "129-512        0        -        -        -         -         -         -"
expect ">512           1      600      600      600      9000      9000      9000"
expect "lines read 5, skipped without prompt_kib/header_ms 1"

# DEC-26 follow-through: the header-timeout distribution, so a timeout that only
# happens on big bodies (slope too short) reads differently from one on small ones
# (base too short). One timeout, in the 33-128 bucket.
expect "header_timeout 1 of 4 measured (25.0%)"
expect "  33-128       1 of    1 (100.0%)"
expect "  <=32         0 of    2 (  0.0%)"
expect "  >512         0 of    1 (  0.0%)"

# A missing file is an error, not an empty table.
if sh tools/phase2-metrics.sh "$tmp/absent.jsonl" >/dev/null 2>&1; then
  echo "FAIL  a missing log exited 0" >&2
  fail=1
fi

[ "$fail" = 0 ] && echo "phase2 dryrun: ok"
exit "$fail"
