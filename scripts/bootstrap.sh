#!/usr/bin/env bash
# Check the toolchain a contributor needs. Reports what is missing; installs nothing
# without being asked.
set -uo pipefail
cd "$(dirname "$0")/.."
missing=0

check() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-12s %s\n' "$1" "$(eval "$2" 2>/dev/null | head -1)"
  else
    printf '  \033[31m✗\033[0m %-12s missing — %s\n' "$1" "$3"
    missing=1
  fi
}

echo "Rant toolchain"
check swift     'swift --version'                      "install Xcode"
check xcodebuild 'xcodebuild -version'                 "install Xcode"
check xcodegen  'xcodegen --version'                   "brew install xcodegen"
check git       'git --version'                        "install git"

echo
if [ "$missing" -eq 0 ]; then
  echo "All set. Next: bash scripts/check.sh"
else
  echo "Install what is marked above, then run this again."
  exit 1
fi
