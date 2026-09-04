#!/usr/bin/env bash
# The definition of green. CI runs this same script.
#
# A check that cannot run in this environment prints SKIP and is reported as SKIP in
# the summary. A skip is never counted as a pass — that is the whole point of having
# this file rather than a list of commands in a README.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0; skip=0
results=()

run() {
  local name="$1"; shift
  printf '\033[1m==> %s\033[0m\n' "$name"
  if "$@"; then
    results+=("PASS  $name"); pass=$((pass+1))
  else
    results+=("FAIL  $name"); fail=$((fail+1))
  fi
  echo
}

skip_check() {
  printf '\033[33m==> %s — SKIP (%s)\033[0m\n\n' "$1" "$2"
  results+=("SKIP  $1 ($2)")
  skip=$((skip+1))
}

# --- 1. Engine builds with no warnings -------------------------------------------
check_build() {
  local output
  output=$(swift build 2>&1)
  echo "$output" | grep -E "error:" && return 1
  local warnings
  warnings=$(echo "$output" | grep -c "warning:")
  if [ "$warnings" -gt 0 ]; then
    echo "$output" | grep "warning:" | head -20
    echo "engine build produced $warnings warnings"
    return 1
  fi
  echo "engine builds clean"
}
run "engine build (warnings are failures)" check_build

# --- 2. Unit tests ----------------------------------------------------------------
check_tests() {
  local output
  output=$(swift test 2>&1)
  echo "$output" | grep -E "Executed [0-9]+ tests" | tail -1
  ! echo "$output" | grep -qE ", with [1-9][0-9]* failures?"
}
run "unit tests" check_tests

# --- 3. Competitor audit has no silent omissions ----------------------------------
run "competitor audit completeness" bash scripts/check-audit.sh

# --- 4. No secrets committed ------------------------------------------------------
check_secrets() {
  local hits
  hits=$(grep -rInE '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})' \
    --include='*.swift' --include='*.sh' --include='*.yml' --include='*.plist' --include='*.md' \
    --exclude-dir='.claude' --exclude-dir='.build' . \
    2>/dev/null | grep -v 'SecretRedactor.swift' | grep -v 'check.sh' \
    | grep -v 'not-a-real-key' || true)
  if [ -n "$hits" ]; then echo "possible secret committed:"; echo "$hits"; return 1; fi
  echo "no key-shaped strings in tracked source"
  # A fixture that must *look* like a key (the redaction tests need one) declares
  # itself with a `not-a-real-key` comment on the same line. That keeps the exemption
  # explicit and greppable rather than exempting a whole directory, which is how a
  # real key eventually gets committed to a test file.
}
run "no committed secrets" check_secrets

# --- 5. Network hosts match the documentation -------------------------------------
# docs/NETWORK_BEHAVIOR.md claims to list every request the app can make. This keeps
# that claim honest: any host literal in the engine must appear in that document.
check_hosts() {
  local undocumented=""
  for host in $(grep -rhoE 'https?://[a-zA-Z0-9.-]+' Sources/ | sed -E 's|https?://||' | sort -u); do
    case "$host" in
      localhost|127.0.0.1|example.invalid|0.0.0.0) continue ;;
    esac
    grep -q "$host" docs/NETWORK_BEHAVIOR.md || undocumented="$undocumented $host"
  done
  if [ -n "$undocumented" ]; then
    echo "hosts in Sources/ that docs/NETWORK_BEHAVIOR.md does not mention:$undocumented"
    return 1
  fi
  echo "every outbound host is documented"
}
run "network behaviour documented" check_hosts

# --- 6. No SwiftUI in the engine --------------------------------------------------
check_layering() {
  if grep -rl "import SwiftUI" Sources/ 2>/dev/null | grep -q .; then
    echo "RantCore must not import SwiftUI:"; grep -rl "import SwiftUI" Sources/; return 1
  fi
  echo "engine has no UI dependency"
}
run "engine/app layering" check_layering

# --- 7. Application builds --------------------------------------------------------
check_app() {
  if ! command -v xcodegen >/dev/null 2>&1; then return 2; fi
  xcodegen generate >/dev/null 2>&1
  xcodebuild -project Rant.xcodeproj -scheme Rant -configuration Debug \
    -derivedDataPath .build/xcode build 2>&1 | grep -E "error:|BUILD" | sort -u
  # xcodebuild's exit code is the one that matters, not grep's.
  return "${PIPESTATUS[0]}"
}
if command -v xcodegen >/dev/null 2>&1 && command -v xcodebuild >/dev/null 2>&1; then
  run "application build" check_app
else
  skip_check "application build" "xcodegen or xcodebuild not available"
fi

# --- 8. UI tests ------------------------------------------------------------------
# Onboarding, navigation, CRUD and settings persistence. Global text injection is
# NOT covered here and never will be — see docs/SMOKE_TEST.md for why.
check_ui() {
  bash scripts/ui-test.sh | tail -3
  return "${PIPESTATUS[0]}"
}
# Opt-in, not default. XCUITest drives the real cursor and takes over the machine for
# two minutes, so running it on every check makes the machine unusable while you work.
# CI sets RUN_UI_TESTS=1; a developer runs `bash scripts/ui-test.sh` when they mean to.
if [ "${RUN_UI_TESTS:-0}" != "1" ]; then
  skip_check "XCUITest suite" "opt-in — run: RUN_UI_TESTS=1 bash scripts/check.sh"
elif command -v xcodebuild >/dev/null 2>&1; then
  run "XCUITest suite" check_ui
else
  skip_check "XCUITest suite" "xcodebuild not available"
fi

# --- 9. Manual coverage is stated, not pretended -----------------------------------
skip_check "global text injection" "cannot be honestly automated — see docs/SMOKE_TEST.md"

# --- Summary ----------------------------------------------------------------------
printf '\033[1mSummary\033[0m\n'
for line in "${results[@]}"; do
  case "$line" in
    PASS*) printf '  \033[32m%s\033[0m\n' "$line" ;;
    FAIL*) printf '  \033[31m%s\033[0m\n' "$line" ;;
    SKIP*) printf '  \033[33m%s\033[0m\n' "$line" ;;
  esac
done
printf '\n  %d passed, %d failed, %d skipped\n\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
