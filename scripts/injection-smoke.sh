#!/usr/bin/env bash
# Prove that Rant's text actually lands in another application.
#
# Opens a scratch document in TextEdit, runs the real injector at it, and reads the
# result back out through Accessibility. This is the one check a fake cannot stand in
# for: `InjectionTests` proves the injector's decisions, and only this proves the text
# arrives.
#
# TextEdit on purpose, and nothing else. Verifying insertion means writing into a
# running application, and a stray paste into Slack sends a message.
#
# Needs the Accessibility grant for whatever runs this — your terminal, usually.
# System Settings → Privacy & Security → Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> opening TextEdit and injecting"
RANT_INJECTION_SMOKE=1 swift test --filter InjectionSmokeTests 2>&1 |
  grep -E "injection outcome:|focused field now reads:|Executed [0-9]+ test|error:|skipped"
