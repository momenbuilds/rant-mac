#!/usr/bin/env bash
# Photograph the Rant Bar as macOS actually draws it.
#
# The off-screen gallery (scripts/bar-gallery.sh) checks layout, spacing and colour,
# and cannot check the one thing that most decides whether this looks like a system
# surface: `NSVisualEffectView` samples the desktop behind the window, and
# `ImageRenderer` has no desktop. So the material has to be reviewed from a real screen
# capture of the real panel.
#
# Uses the app's demo mode, which cycles the recorder through its states over a
# backdrop. The backdrop itself stays off here: the material samples what is behind the
# window, so covering the desktop would hide the one thing this capture exists to show.
set -euo pipefail
cd "$(dirname "$0")/.."

# Defaults outside the repository on purpose. These are photographs of whoever runs
# this — their wallpaper, their open windows, their messages. The synthetic gallery is
# what belongs in version control; a real screen capture is for looking at once.
out="${1:-$HOME/Desktop/rant-bar-live}"
mkdir -p "$out"

pkill -f "Rant Dev" 2>/dev/null || true
sleep 1

defaults write dev.rant.mac.dev rant-demo-overlay -bool YES
open -a "/Applications/Rant Dev.app"
trap 'defaults delete dev.rant.mac.dev rant-demo-overlay 2>/dev/null || true; pkill -f "Rant Dev" 2>/dev/null || true' EXIT

# Where the bar sits: bottom centre of the main display, with generous margins.
# Read from NSScreen rather than parsed out of system_profiler, which reports pixels
# and made the region miss the display entirely on a Retina Mac.
read -r sw sh < <(swift scripts/support/screen-size.swift)
rect="$(( sw / 2 - 260 )),$(( sh - 300 )),520,170"

# The demo loops idle → listening → working → success. Sampling across one loop
# catches the states without having to synchronise with it.
sleep 4
for shot in 1 2 3 4 5 6; do
  screencapture -x -R"$rect" "$out/live-$shot.png"
  sleep 1.4
done

echo "wrote $out/live-*.png"
