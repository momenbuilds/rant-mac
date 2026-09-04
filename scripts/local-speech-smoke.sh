#!/usr/bin/env bash
# Prove that this Mac can turn speech into text with no network.
#
# Generates real speech with `say`, converts it to the 16 kHz mono PCM Rant records at,
# and runs it through the same on-device recogniser the app uses. This is the one check
# that a fake cannot stand in for: `AppleSpeechTests` proves the provider refuses
# correctly, and only this proves the machine can actually do the work.
#
# Needs the Speech Recognition grant. macOS asks the first time; if it was refused,
# System Settings → Privacy & Security → Speech Recognition.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

phrase="${1:-the quick brown fox jumps over the lazy dog}"
echo "==> speaking: $phrase"
say -o "$work/speech.aiff" "$phrase"
afconvert -f WAVE -d LEI16@16000 -c 1 "$work/speech.aiff" "$work/speech.wav"

echo "==> transcribing on device"
RANT_LOCAL_SMOKE=1 RANT_LOCAL_SMOKE_WAV="$work/speech.wav" \
  swift test --filter LocalTranscriptionSmokeTests 2>&1 |
  grep -E "on-device transcript:|Executed [0-9]+ test|error:|skipped"
