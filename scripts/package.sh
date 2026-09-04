#!/usr/bin/env bash
# Build a Release copy of Rant and wrap it as a .zip and a .dmg in dist/.
#
# What this script will not do is pretend the result is distributable. Without a
# Developer ID certificate the bundle is ad-hoc signed, and an ad-hoc signed app is
# refused by Gatekeeper on every Mac except the one that built it. That is a fact
# about macOS, not a warning to be softened, so the script says it plainly at the end
# and says it again in dist/README.txt next to the artefacts — because the artefact
# is the thing that gets handed to someone, not the terminal output.
#
# If a Developer ID Application certificate *is* in the keychain the script finds it,
# uses it, and says so. Notarisation is still a separate step and is not attempted
# here; docs/PACKAGING.md has the commands.
#
# Everything is written under dist/. Nothing outside dist/ is ever removed, and the
# script is safe to run twice in a row.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Rant"
CONFIG="Release"
DIST="dist"
DERIVED=".build/xcode-release"
VOLUME_NAME="Rant"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen"; exit 1; }
command -v xcodebuild >/dev/null || { echo "xcodebuild is required: install Xcode"; exit 1; }

# --- 1. Find a signing identity ---------------------------------------------------
# `security find-identity` lists what the keychain can actually sign with today. An
# expired or revoked certificate does not appear in the -v (valid only) output, which
# is why this asks the keychain rather than reading a name out of a config file.
IDENTITY=""
IDENTITY_KIND="ad-hoc"
if IDENTITY_LINE=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1); then
  IDENTITY=$(echo "$IDENTITY_LINE" | sed -E 's/.*"(.*)".*/\1/')
  [ -n "$IDENTITY" ] && IDENTITY_KIND="Developer ID"
fi

if [ "$IDENTITY_KIND" = "Developer ID" ]; then
  echo "==> signing identity: $IDENTITY"
else
  echo "==> signing identity: none found, falling back to ad-hoc (see the note at the end)"
fi

# --- 2. Build ---------------------------------------------------------------------
echo "==> regenerating the Xcode project"
xcodegen generate >/dev/null

echo "==> building ($CONFIG)"
# The project signs ad-hoc by default so a contributor with no Apple account can
# build. When a real identity exists we override it here rather than editing
# project.yml, so a checkout is never left carrying somebody's team id.
BUILD_ARGS=(
  -project "$APP_NAME.xcodeproj"
  -scheme "$APP_NAME"
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED"
)
if [ "$IDENTITY_KIND" = "Developer ID" ]; then
  BUILD_ARGS+=(CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual)
fi
xcodebuild "${BUILD_ARGS[@]}" build 2>&1 | grep -E "error:|BUILD" || true

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "build produced no app at $BUILT"; exit 1; }

VERSION=$(defaults read "$(cd "$(dirname "$BUILT")" && pwd)/$APP_NAME.app/Contents/Info" \
  CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
BASENAME="$APP_NAME-$VERSION"

# --- 3. Stage a clean copy --------------------------------------------------------
# Staged rather than signed in place, so a re-run always starts from the build output
# and never re-signs an already-signed bundle (which succeeds, but hides whether the
# signature came from this run).
mkdir -p "$DIST"
STAGE="$DIST/.stage"
rm -rf "$STAGE"                     # inside dist/ only — see the header
mkdir -p "$STAGE"
cp -R "$BUILT" "$STAGE/$APP_NAME.app"
TARGET="$STAGE/$APP_NAME.app"

echo "==> signing ($IDENTITY_KIND)"
if [ "$IDENTITY_KIND" = "Developer ID" ]; then
  # --options runtime is what notarisation requires; the entitlements file explains
  # why this app is not sandboxed.
  codesign --force --deep --options runtime --timestamp \
    --entitlements App/Rant/Rant.entitlements \
    --sign "$IDENTITY" "$TARGET"
else
  codesign --force --deep --sign - \
    --entitlements App/Rant/Rant.entitlements "$TARGET" 2>/dev/null \
    || codesign --force --deep --sign - "$TARGET"
fi
codesign --verify --strict --verbose=2 "$TARGET" 2>&1 | tail -2

# --- 4. Zip -----------------------------------------------------------------------
# ditto rather than zip: it is the only archiver that preserves the symlinks and
# extended attributes a signed bundle needs, and the one Apple's own notarisation
# instructions use. A bundle zipped with `zip -r` can arrive with a broken signature.
ZIP="$DIST/$BASENAME.zip"
echo "==> writing $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$TARGET" "$ZIP"

# --- 5. Disk image ----------------------------------------------------------------
DMG="$DIST/$BASENAME.dmg"
echo "==> writing $DMG"
rm -f "$DMG"
DMG_ROOT="$STAGE/dmg"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$TARGET" "$DMG_ROOT/$APP_NAME.app"
# The Applications symlink is the whole user interface of a .dmg: it turns "install"
# into one drag. Without it people run the app from the mounted image, where it has
# no writable container and every permission grant is keyed to a path that vanishes.
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$DMG_ROOT" \
  -ov -format UDZO "$DMG"
rm -rf "$DMG_ROOT"

# --- 6. Checksums -----------------------------------------------------------------
# Written to a file as well as printed, because a checksum that only ever existed in
# somebody's scrollback cannot be checked by the person downloading the artefact.
SUMS="$DIST/$BASENAME.sha256"
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" ) > "$SUMS"

# --- 7. Say what this is, and what it is not --------------------------------------
if [ "$IDENTITY_KIND" = "Developer ID" ]; then
  GATEKEEPER_NOTE=$(cat <<'NOTE'
Signed with a Developer ID Application certificate, which is necessary but not
sufficient. These artefacts are NOT notarised, so on another Mac Gatekeeper will
still refuse them on first launch. To finish the job:

  xcrun notarytool submit dist/<artefact> --keychain-profile "rant-notary" --wait
  xcrun stapler staple "dist/<the .app inside>"
  spctl --assess --verbose=4 --type execute "<app>"

See docs/PACKAGING.md for storing the notary credentials.
NOTE
)
else
  GATEKEEPER_NOTE=$(cat <<'NOTE'
These artefacts are AD-HOC SIGNED and cannot be distributed.

On any Mac other than the one that built them, Gatekeeper will refuse to open the
app — "Rant is damaged and can't be opened" or "cannot be opened because the
developer cannot be verified". That is correct behaviour and there is no flag here
that fixes it. Telling people to right-click → Open, or to run `xattr -d
com.apple.quarantine`, teaches a habit that will eventually get them hurt, so this
script does not suggest it.

What is missing, in order:

  1. An Apple Developer Program membership ($99/year).
  2. A Developer ID Application certificate in the keychain. This script detects one
     automatically and will use it on the next run.
  3. Notarisation — upload to Apple, wait for the scan, receive a ticket.
  4. Stapling — attach the ticket so the app validates offline.

Hardened runtime is already enabled in project.yml, so steps 3 and 4 become possible
the moment step 2 exists. docs/PACKAGING.md has the exact commands.

Until then these artefacts are good for one thing: installing on this machine, or
handing to someone who will build from source and can check the checksum against
their own build.
NOTE
)
fi

cat > "$DIST/README.txt" <<EOF
$APP_NAME $VERSION
Built $(date -u '+%Y-%m-%d %H:%M UTC') · $CONFIG · signed $IDENTITY_KIND

$(cat "$SUMS")

$GATEKEEPER_NOTE
EOF

rm -rf "$STAGE"

echo
echo "Artefacts in $DIST:"
sed 's/^/  /' "$SUMS"
echo
echo "$GATEKEEPER_NOTE"
echo
echo "(The same note is in $DIST/README.txt, so it travels with the files.)"
