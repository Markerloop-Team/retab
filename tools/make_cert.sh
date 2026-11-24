#!/bin/zsh
# Makes a local code-signing certificate, "Retab Dev", so that macOS sees every rebuild of Retab as
# the same app and Accessibility and Screen Recording stay granted.
#
# The certificate lives in a keychain of its own, ~/Library/Keychains/retab-dev.keychain-db, with a
# password that is no secret (it is right here): the key signs builds on this Mac only and is trusted
# by nobody else. Keeping it apart from your login keychain is what lets the build sign without
# macOS asking for your password. To undo: `security delete-keychain` that file.
set -euo pipefail
KEYCHAIN="$HOME/Library/Keychains/retab-dev.keychain-db"
PASS=retab-dev
if [[ -f "$KEYCHAIN" ]]; then echo "Already there: $KEYCHAIN"; exit 0; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/c.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Retab Dev
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -config "$WORK/c.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "Retab Dev" -out "$WORK/id.p12" -passout pass:$PASS
security create-keychain -p $PASS "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # never locks by itself
security unlock-keychain -p $PASS "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P $PASS -T /usr/bin/codesign >/dev/null
# codesign finds a certificate only in the keychains macOS searches; add this one to the list.
# One path per line, so that a path with a space in it stays one path.
existing=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')}")
if (( ! ${existing[(Ie)$KEYCHAIN]} )); then
  security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"
fi
# Without this, macOS asks for the keychain password each time the key is used.
security set-key-partition-list -S apple-tool:,apple: -s -k $PASS "$KEYCHAIN" >/dev/null
echo "Made \"Retab Dev\" in $KEYCHAIN. Run ./build.sh again."
