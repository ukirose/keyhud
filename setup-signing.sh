#!/bin/bash
# One-time: create a self-signed code-signing identity for local development.
#
# Why: TCC (Accessibility, Input Monitoring) binds a grant to a code signature. An
# ad-hoc signature's designated requirement is its cdhash, which changes on every
# build — so every rebuild silently revokes the grants and the app goes deaf. A
# self-signed certificate gives a stable identity, so the grants survive rebuilds.
#
# Two things about the PKCS#12 hand-off are not obvious, and both were verified by
# reproducing the failure on this machine (2026-08-02):
#   - Apple's `security import` cannot read an empty-password PKCS#12. It reports
#     "MAC verification failed ... (wrong password?)", which reads like the password
#     is wrong when the real problem is that there isn't one.
#   - OpenSSL 3 defaults to AES-256-CBC / SHA-256 for the bundle, which `security
#     import` also rejects with the same message. The legacy 3DES/SHA1 encoding is
#     what Apple's Security framework accepts.
# The password below is transient: the bundle lives in a temp dir that is deleted on
# exit, and from then on the private key is protected by the keychain itself.
#
# This touches your login keychain and its trust settings, so it is yours to run, not
# mine. It is local-only: the certificate never leaves this machine, is not a CA for
# anything else, and can be removed in Keychain Access at any time.
set -euo pipefail

NAME="KeyHUD Dev"
PASS="keyhud-transient"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists — nothing to do"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

echo "==> 1/4  generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/dev.key" -out "$TMP/dev.crt" \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

echo "==> 2/4  packaging with the legacy encoding security(1) can read"
openssl pkcs12 -export -out "$TMP/dev.p12" \
  -inkey "$TMP/dev.key" -in "$TMP/dev.crt" -passout "pass:$PASS" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "==> 3/4  importing into the login keychain"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -A

echo "==> 4/4  marking it trusted for code signing"
echo "         (macOS will ask for your login password — this is the step that needs it)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/dev.crt"

echo
if security find-identity -v -p codesigning | grep "$NAME"; then
  echo
  echo "done. rebuilds will now keep their Accessibility / Input Monitoring grants."
else
  echo "FAILED — the certificate imported but is not usable for signing."
  echo "build.sh will fall back to ad-hoc signing, which still works; you will just"
  echo "have to re-grant permissions after each rebuild."
  exit 1
fi
