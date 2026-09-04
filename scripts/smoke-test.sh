#!/usr/bin/env bash
# Walks through docs/SMOKE_TEST.md interactively and writes a dated result file.
#
# This exists because pretending a brittle UI test covers global text injection is
# worse than admitting a person has to check it. The checklist is the deliverable.
set -uo pipefail
cd "$(dirname "$0")/.."

RESULTS="docs/smoke-results"
mkdir -p "$RESULTS"
STAMP="$(date +%Y-%m-%d-%H%M)"
OUT="$RESULTS/$STAMP.md"

{
  echo "# Smoke test — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo 'not a git repo')"
  echo "- macOS: $(sw_vers -productVersion) ($(uname -m))"
  echo "- app: ${APP:-/Applications/Rant Dev.app}"
  echo
} > "$OUT"

echo "Recording to $OUT"
echo "For each item: y = pass, n = fail, s = skip. Anything else is treated as a note."
echo

section=""
while IFS= read -r line; do
  case "$line" in
    "## "*)
      section="${line#\#\# }"
      printf '\n\033[1m%s\033[0m\n' "$section"
      echo "" >> "$OUT"; echo "## $section" >> "$OUT"; echo "" >> "$OUT"
      ;;
    "- [ ] "*)
      item="${line#- \[ \] }"
      printf '  %s\n  [y/n/s] > ' "$item"
      read -r answer </dev/tty
      case "$answer" in
        y|Y) echo "- [x] $item" >> "$OUT" ;;
        n|N)
          printf '  what happened? > '
          read -r note </dev/tty
          echo "- [ ] **FAILED** $item — $note" >> "$OUT"
          ;;
        s|S) echo "- [ ] SKIPPED $item" >> "$OUT" ;;
        *)   echo "- [ ] $item — $answer" >> "$OUT" ;;
      esac
      ;;
  esac
done < docs/SMOKE_TEST.md

failures=$(grep -c 'FAILED' "$OUT" || true)
skipped=$(grep -c 'SKIPPED' "$OUT" || true)
printf '\n\033[1mDone.\033[0m %s failures, %s skipped — %s\n' "$failures" "$skipped" "$OUT"
echo "Please update docs/APP_COMPATIBILITY.md with anything you learned about a specific app."
