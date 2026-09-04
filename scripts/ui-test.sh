#!/usr/bin/env bash
# The XCUITest suite.
#
# Deliberately scoped: it covers onboarding, navigation, the CRUD screens and
# settings persistence. It does NOT try to drive global text injection into another
# application — that needs real Accessibility permissions and a real microphone, and
# a test that fails for reasons unrelated to the change is a test people delete.
# That work is a manual matrix in docs/SMOKE_TEST.md.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

xcodebuild \
  -project Rant.xcodeproj \
  -scheme Rant \
  -configuration Debug \
  -derivedDataPath .build/xcode \
  -only-testing:RantUITests/OnboardingUITests \
  test 2>&1 | grep -E "Test Case .*(passed|failed)|Executed [0-9]+ test|error:|TEST (SUCCEEDED|FAILED)"

exit "${PIPESTATUS[0]}"
