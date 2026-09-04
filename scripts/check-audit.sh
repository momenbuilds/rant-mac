#!/usr/bin/env bash
# Guard: every capability row in the competitor matrix must resolve to a verdict.
# A capability row is a 6-cell row (name | W | V | B | S | verdict).
set -euo pipefail
cd "$(dirname "$0")/.."
f=docs/COMPETITOR_AUDIT.md
test -f "$f" || { echo "missing $f"; exit 1; }
rows=$(grep -cE '^\|[^|]+\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|$' "$f" | tr -d ' ')
bad=$(grep -nE '^\|[^|]+\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|[^|]*\|$' "$f" \
      | grep -vE 'MATCH|BEAT|INTENTIONALLY_SKIP|Capability|:?-{2,}' || true)
if [ -n "$bad" ]; then
  echo "FAIL: capability rows without a verdict:"; echo "$bad"; exit 1
fi
skips=$(grep -c 'INTENTIONALLY_SKIP' "$f" || true)
echo "audit OK — $rows capability rows, $skips intentional skips, 0 silent omissions"
