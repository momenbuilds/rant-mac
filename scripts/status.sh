#!/usr/bin/env bash
# Rant status — the at-a-glance view of the project.
set -uo pipefail
cd "$(dirname "$0")/.."

total=$(grep -cE '^- \[[ x~!]\] RANT-' TASKS.md)
done_=$(grep -cE '^- \[x\] RANT-' TASKS.md)
active=$(grep -cE '^- \[~\] RANT-' TASKS.md)
blocked=$(grep -cE '^- \[!\] RANT-' TASKS.md)

printf '\n\033[1mRant — project status\033[0m\n'
printf '  tasks      %s/%s complete, %s active, %s blocked\n' "$done_" "$total" "$active" "$blocked"

if [ "$active" -gt 0 ]; then
  printf '\n\033[1mActive\033[0m\n'
  grep -E '^- \[~\] RANT-' TASKS.md | sed 's/^- \[~\] /  /'
fi
if [ "$blocked" -gt 0 ]; then
  printf '\n\033[1mBlocked\033[0m\n'
  grep -E '^- \[!\] RANT-' TASKS.md | sed 's/^- \[!\] /  /'
fi

printf '\n\033[1mNext up\033[0m\n'
grep -E '^- \[ \] RANT-' TASKS.md | head -3 | sed 's/^- \[ \] /  /'

printf '\n\033[1mBuild\033[0m\n'
if [ -d .build ]; then
  printf '  SwiftPM build dir present\n'
else
  printf '  SwiftPM not built yet (run: swift build)\n'
fi
for p in "/Applications/Rant Dev.app" "$HOME/Applications/Rant Dev.app"; do
  [ -d "$p" ] && printf '  dev app installed: %s\n' "$p"
done

printf '\n  see PROGRESS.md for the full narrative\n\n'
