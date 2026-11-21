#!/bin/sh
# A19 — the log page never scans past its budget, and says so (2026-11-21).
#
#   a19a  a page that would need more than the budget spends exactly the budget
#   a19b  the answer says the budget was exhausted, and that older lines remain
#   a19c  the same file, a page that fits, is not reported as exhausted
#
# D8: a page is a tail, never the whole file. `LogScanBudget` is 5,000 lines, and
# `scan.budget_exhausted` is the only way an operator learns the page stopped
# before it ran out of file. Nothing drove it there before this case.
set -u
ACC_DIR=$(cd "$(dirname "$0")" && pwd)
. "$ACC_DIR/lib.sh"

# 6,000 lines is 1,000 past the budget, so a page asking for 4,901 skipped lines
# cannot be filled inside it. Every seeded line matches, which is the expensive
# case: a scan that keeps finding rows never reaches its `done` early.
seed_log 6000 leg-b 200
write_config "leg-a|http://127.0.0.1:18095/v1|key-leg-a|" \
             "leg-b|http://192.0.2.1:9/v1|key-leg-b|"
gw_start

assert_eq "A19 the file is 6,000 lines before any request" "$(log_count)" "6000"

# `log_scan` maps a missing key to "absent" through jq's `//`, which also swallows
# a legitimate `false`. This case grades both answers, so it reads the flag raw.
scan_flag() { jq -r '.scan.budget_exhausted' "$1" 2>/dev/null; }

echo
echo "=== A19a: a page that cannot be filled inside the budget stops at the budget"
assert_eq "A19a /admin/log?limit=200&offset=4900 answers 200" \
  "$(admin_get "$RUN/a19-big.json" '/admin/log?limit=200&offset=4900')" "200"
assert_eq "A19a the budget is published with the answer" \
  "$(log_scan "$RUN/a19-big.json" budget)" "5000"
assert_eq "A19a exactly the budget was scanned, not more" \
  "$(log_scan "$RUN/a19-big.json" lines_scanned)" "5000"
assert_log_page_fits "A19a the page still fits the limit it reports" \
  "$RUN/a19-big.json" 200
# Matched lines 4,901..5,000 are the only ones the scan could reach.
assert_eq "A19a the page carries what the budget reached" \
  "$(log_row_count "$RUN/a19-big.json")" "100"

echo
echo "=== A19b: the answer admits it stopped early"
assert_eq "A19b budget_exhausted is true" \
  "$(scan_flag "$RUN/a19-big.json")" "true"
assert_eq "A19b older lines are reported behind the page" \
  "$(log_meta "$RUN/a19-big.json" more_older)" "true"
assert_eq "A19b the source is a tail, never the whole file" \
  "$(log_meta "$RUN/a19-big.json" source)" "tail"

echo
echo "=== A19c: the same file, a page that fits, is not exhausted"
# Without this half, a flag that is simply always true would pass A19a and A19b.
assert_eq "A19c /admin/log?limit=50&offset=0 answers 200" \
  "$(admin_get "$RUN/a19-small.json" '/admin/log?limit=50&offset=0')" "200"
assert_eq "A19c budget_exhausted is false" \
  "$(scan_flag "$RUN/a19-small.json")" "false"
assert_eq "A19c a 50-row page cost about 51 lines, not 5,000" \
  "$([ "$(log_scan "$RUN/a19-small.json" lines_scanned)" -le 55 ] \
     && echo within || echo over)" "within"
assert_eq "A19c the page is full" \
  "$(log_row_count "$RUN/a19-small.json")" "50"
assert_eq "A19c there are still older lines behind it" \
  "$(log_meta "$RUN/a19-small.json" more_older)" "true"

finish
