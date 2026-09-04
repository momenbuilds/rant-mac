#!/usr/bin/env bash
# Build Rant and install it at a stable path, then launch it.
#
# Why a stable path matters more than it sounds: macOS ties Accessibility and
# Microphone grants to a bundle's identity *and its location on disk*. Run the app
# from DerivedData and every rebuild looks like a different app, so your permissions
# silently stop applying and you spend an afternoon debugging an event tap that was
# never broken. Install it once, here, and the grant sticks.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
APP_NAME="Rant Dev"
[ "$CONFIG" = "Release" ] && APP_NAME="Rant"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  echo "note: /Applications is not writable, installing to $DEST instead"
fi
TARGET="$DEST/$APP_NAME.app"

echo "==> regenerating the Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
xcodegen generate >/dev/null

echo "==> building ($CONFIG)"
DERIVED=".build/xcode"
xcodebuild \
  -project Rant.xcodeproj \
  -scheme Rant \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | grep -E "error:|warning:|BUILD" || true

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "build produced no app at $BUILT"; exit 1; }

# Quit a running copy so we are not copying over a live bundle.
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1

echo "==> installing to $TARGET"
rm -rf "$TARGET"
cp -R "$BUILT" "$TARGET"

# Ad-hoc sign so the bundle has a stable identity. Without this the TCC database
# keys the grant to a hash that changes on every build, which brings back exactly the
# problem the stable path was meant to solve.
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - \
  --entitlements App/Rant/Rant.entitlements \
  "$TARGET" 2>/dev/null || codesign --force --deep --sign - "$TARGET"

# The signature changes on every build, and macOS binds Accessibility grants to it.
# Clearing the stale entry here means the app is never left in the state that wastes
# the most time: a switch that looks on, pointing at a binary that no longer exists.
if [ "${RESET_TCC:-1}" = "1" ]; then
  BUNDLE_ID=$(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo "")
  if [ -n "$BUNDLE_ID" ]; then
    echo "==> clearing the stale Accessibility grant for $BUNDLE_ID"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
fi

echo "==> launching"
open "$TARGET"

cat <<NOTE

Installed: $TARGET
Bundle id: $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo unknown)

Rebuilding changes the app's signature, and macOS ties Accessibility to that
signature — so the grant from the previous build no longer applies and the switch in
System Settings points at a binary that no longer exists. This script clears it for
you; grant it once more after the last build you intend to make. (Set RESET_TCC=0 to
skip that.)

If macOS asks for your login password when Rant reads your API key, that is the old
file keychain noticing the app's signature changed. Rant now stores new keys in the
data-protection keychain, which has no per-binary access list and does not ask again —
but a key saved by an older build still lives in the file keychain. Re-saving it once
in Settings → Speech moves it across and stops the prompts.

If the dictation key does nothing, macOS has probably kept an old grant for a
previous build. Reset it and grant again:

  tccutil reset Accessibility $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo dev.rant.mac.dev)
  tccutil reset Microphone    $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null || echo dev.rant.mac.dev)

then reopen Rant and walk through onboarding again.
NOTE
