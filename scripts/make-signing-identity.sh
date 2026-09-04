#!/usr/bin/env bash
# Create a stable, local, self-signed code-signing identity for development builds.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) is a hash of the binary,
# so it changes on every build — and macOS binds Accessibility, Microphone and
# Keychain grants to that signature. The result is that every rebuild silently
# invalidates every permission, leaving a switch in System Settings that looks on
# while pointing at a binary that no longer exists. That is the single most
# time-wasting failure mode in developing a macOS app that needs permissions.
#
# A self-signed certificate kept in the login keychain gives a *stable* identity, so
# the grants survive rebuilds. It is not a Developer ID and cannot be distributed —
# see docs/PACKAGING.md for that — it exists purely so the machine you develop on
# stops asking.
set -euo pipefail

NAME="${RANT_SIGNING_IDENTITY:-Rant Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "already have a signing identity: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no

[ dn ]
CN = Rant Local Signing

[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null

# macOS's Security framework cannot read a PKCS#12 written with OpenSSL 3's default
# algorithms — it fails with "MAC verification failed", which reads like a wrong
# password and is not. The legacy PBE triple is what it understands.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout pass:rant -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> importing into the login keychain"
# -A lets any application use the key without a prompt. That is the point: the whole
# reason for this identity is to stop macOS asking on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P rant -A -T /usr/bin/codesign >/dev/null

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "==> ready: builds will now sign as \"$NAME\""
  echo "    Permissions you grant will survive a rebuild."
else
  echo "==> the certificate imported but macOS does not list it as a valid signing"
  echo "    identity yet. Builds will fall back to ad-hoc signing, which still works"
  echo "    but loses its permissions on every rebuild."
  exit 1
fi
