#!/usr/bin/env bash
# Draw every state of the Rant Bar to PNG, for visual review.
#
# Several of the bar's states are awkward to reach on purpose: an error needs a
# failure, hands-free needs a double tap, the expanded state needs five seconds of
# talking, and hover needs a pointer. Driving a real dictation to look at each one is
# slow and, for the error case, requires breaking something.
#
# `ImageRenderer` draws the same view the app ships, off-screen, so what you review is
# what users get — and the output is identical on every run, which makes a visual
# change reviewable as a diff.
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-docs/assets/rant-bar}"
mkdir -p "$out"

echo "==> building"
xcodegen generate >/dev/null
xcodebuild -project Rant.xcodeproj -scheme Rant -configuration Debug \
  -derivedDataPath .build/xcode build >/dev/null

echo "==> rendering to $out"
".build/xcode/Build/Products/Debug/Rant Dev.app/Contents/MacOS/Rant Dev" \
  -rant-render-bar-gallery "$PWD/$out"

ls -1 "$out"
