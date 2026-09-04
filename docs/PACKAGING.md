# Packaging and distribution

## What works today

```bash
bash scripts/dev-build.sh                 # Debug → /Applications/Rant Dev.app
CONFIG=Release bash scripts/dev-build.sh  # Release → /Applications/Rant.app
```

Both are **ad-hoc signed** (`codesign --sign -`). That is enough to run on the machine
that built it and enough for Accessibility grants to stick to a stable bundle identity,
which is the thing that actually matters during development.

## What is missing for public distribution

Ad-hoc signed builds cannot be distributed: Gatekeeper will refuse them on another
Mac, and telling people to right-click → Open is teaching them a habit that will
eventually get them hurt.

To ship publicly you need, in order:

1. **An Apple Developer Program membership** ($99/year) — nothing below is possible
   without it.
2. **A Developer ID Application certificate**, created in Xcode or on the developer
   portal.
3. **Hardened runtime** — already enabled in `project.yml`.
4. **Notarisation** — upload to Apple, wait for the automated scan, receive a ticket.
5. **Stapling** — attach the ticket to the bundle so it validates offline.

None of this is blocking product development, and none of it is faked. When a
certificate exists, the steps are:

```bash
# 1. Sign with the real identity
codesign --force --deep --options runtime --timestamp \
  --entitlements App/Rant/Rant.entitlements \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  "/Applications/Rant.app"

# 2. Notarise
ditto -c -k --keepParent "/Applications/Rant.app" Rant.zip
xcrun notarytool submit Rant.zip \
  --keychain-profile "rant-notary" --wait

# 3. Staple
xcrun stapler staple "/Applications/Rant.app"
xcrun stapler validate "/Applications/Rant.app"

# 4. Verify the way Gatekeeper will
spctl --assess --verbose=4 --type execute "/Applications/Rant.app"
```

Store the notary credentials once with:

```bash
xcrun notarytool store-credentials rant-notary \
  --apple-id you@example.com --team-id TEAMID --password APP-SPECIFIC-PASSWORD
```

## A note on the sandbox

Rant is deliberately **not** sandboxed, and `App/Rant/Rant.entitlements` says why in
full. A sandboxed app cannot install a `CGEventTap`, cannot read another
application's Accessibility tree, and cannot synthesise a keystroke into another app.
Those three capabilities *are* the product.

The honest consequence: Rant runs with the same privileges as any other app you
launch, it cannot be distributed on the Mac App Store, and the mitigation on offer is
that the code is open for you to read. See `docs/THREAT_MODEL.md`.

## Automatic updates

Not implemented, and deliberately so. An updater that cannot verify signatures is a
remote code execution feature. Once a Developer ID exists, Sparkle with EdDSA
signatures is the intended route — tracked in `TASKS.md`.
