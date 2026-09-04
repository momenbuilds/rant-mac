#!/usr/bin/env bash
# Build and install Rant from source.
#
#   curl -fsSL https://raw.githubusercontent.com/momenweb/rant-mac/main/scripts/install.sh | bash
#
# Builds locally rather than downloading a binary, because without a Developer ID
# certificate a downloaded build is refused by Gatekeeper — and teaching people to
# right-click → Open, or to strip the quarantine flag, is teaching a habit that will
# eventually get them hurt. A build you made yourself needs none of that.
set -euo pipefail

REPO="https://github.com/momenweb/rant-mac.git"
DIR="${RANT_DIR:-$HOME/.rant-src}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Rant is a macOS application."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "Rant needs macOS 14 or later (you have $(sw_vers -productVersion))."

say "checking the toolchain"
command -v git >/dev/null || die "git is missing. Install the Xcode command line tools: xcode-select --install"
command -v xcodebuild >/dev/null || die "Xcode is missing. Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -version >/dev/null 2>&1 || die "xcodebuild cannot run. Try: sudo xcode-select -s /Applications/Xcode.app"

if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || die "xcodegen is missing and Homebrew is not installed. Install Homebrew from https://brew.sh, then re-run this."
  say "installing xcodegen"
  brew install xcodegen
fi

if [ -d "$DIR/.git" ]; then
  say "updating the source in $DIR"
  git -C "$DIR" pull --ff-only
else
  say "cloning into $DIR"
  git clone --depth 1 "$REPO" "$DIR"
fi

cd "$DIR"
say "building (this takes a couple of minutes the first time)"
CONFIG=Release bash scripts/dev-build.sh

cat <<'NOTE'

Rant is installed in /Applications and running.

Next, in the app:
  1. Grant Microphone and Accessibility when it asks. Both are explained on screen.
  2. Paste an AssemblyAI key (Settings → Speech), or choose Local only to stay offline.
  3. Hold your dictation key and talk.

To update later:  cd ~/.rant-src && git pull && CONFIG=Release bash scripts/dev-build.sh
NOTE
