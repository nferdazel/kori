#!/bin/sh
# phase2-metrics.sh — the phase 2 prompt-size measurement, from the log kori already writes.
#
# Reads a kori requests.jsonl (the append-only one-line-per-request log) and prints, for each
# prompt-size bucket, how many requests landed there and the p50/p90/p99 of prompt_kib and
# header_ms. Lines written before 0.10.5 carry neither field and are skipped; the count is
# printed, so an empty table is never mistaken for a clean one.
#
# Percentiles are nearest-rank: p is the ceil(p * n)-th value of the sorted sample, so every
# number printed is a value that was actually observed.
#
# usage: tools/phase2-metrics.sh <requests.jsonl>
#
# The numbers this feeds (base, slope, cap in timeouts.header_ms_stream_*) stay untouched
# until 48 hours of lines carry the new fields.
set -eu

log=${1:-}
if [ -z "$log" ]; then
  printf 'usage: %s <requests.jsonl>\n' "$0" >&2
  exit 2
fi
[ -f "$log" ] || { printf 'no such log: %s\n' "$log" >&2; exit 2; }

awk '
function field(line, key,   i, s) {
  i = index(line, "\"" key "\":")
  if (i == 0) return ""
  s = substr(line, i + length(key) + 3)
  if (match(s, /^-?[0-9]+/) != 1) return ""
  return substr(s, 1, RLENGTH)
}
function bucket(kib) {
  if (kib <= 32) return 0
  if (kib <= 128) return 1
  if (kib <= 512) return 2
  return 3
}
function pct(a, b, m, q,   rank) {
  if (m == 0) return "-"
  rank = int(q * m + 0.999999)
  if (rank < 1) rank = 1
  if (rank > m) rank = m
  return a[b, rank]
}
# shortcut: insertion sort, fine for a few thousand lines per bucket; past that,
# pipe the two columns through `sort -n` instead.
function sortBucket(a, b, m,   i, j, v) {
  for (i = 2; i <= m; i++) {
    v = a[b, i]; j = i - 1
    while (j >= 1 && a[b, j] > v) { a[b, j + 1] = a[b, j]; j-- }
    a[b, j + 1] = v
  }
}
BEGIN {
  label[0] = "<=32"; label[1] = "33-128"; label[2] = "129-512"; label[3] = ">512"
}
{
  pk = field($0, "prompt_kib")
  hm = field($0, "header_ms")
  if (pk == "" || hm == "") { skipped++; next }
  b = bucket(pk + 0)
  count[b]++
  kib[b, count[b]] = pk + 0
  ms[b, count[b]] = hm + 0
  if (index($0, "\"failover_reason\":\"header_timeout\"") > 0) {
    timeouts[b]++
    timeouts_all++
  }
}
END {
  printf "%-9s %6s %8s %8s %8s %9s %9s %9s\n",
    "bucket", "n", "kib_p50", "kib_p90", "kib_p99", "ms_p50", "ms_p90", "ms_p99"
  for (b = 0; b < 4; b++) {
    m = count[b]
    sortBucket(kib, b, m)
    sortBucket(ms, b, m)
    printf "%-9s %6d %8s %8s %8s %9s %9s %9s\n", label[b], m,
      pct(kib, b, m, 0.50), pct(kib, b, m, 0.90), pct(kib, b, m, 0.99),
      pct(ms, b, m, 0.50), pct(ms, b, m, 0.90), pct(ms, b, m, 0.99)
  }
  measured = NR - skipped
  printf "\nlines read %d, skipped without prompt_kib/header_ms %d\n", NR, skipped + 0
  # Where the header deadline actually bit. A header_timeout is the one failure the
  # base/slope/cap numbers exist to reduce, so its shape by body size is the second
  # half of the measurement: a timeout only in the big buckets says the slope is
  # short, a timeout in <=32 says the base is.
  printf "\nheader_timeout %d of %d measured", timeouts_all + 0, measured + 0
  if (measured > 0) printf " (%.1f%%)", 100.0 * timeouts_all / measured
  printf "\n"
  for (b = 0; b < 4; b++) {
    n = timeouts[b] + 0
    if (count[b] + 0 > 0) {
      printf "  %-9s %4d of %4d (%5.1f%%)\n", label[b], n, count[b],
        100.0 * n / count[b]
    } else {
      printf "  %-9s %4d of %4d\n", label[b], n, 0
    }
  }
}
' "$log"
