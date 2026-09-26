#!/bin/zsh
# Creates a self-signed code-signing identity in the login keychain so local
# builds keep the same code identity and macOS privacy grants survive rebuilds.
set -euo pipefail

name="${KITH_LOCAL_IDENTITY:-Kith Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$keychain" | grep -Fq "\"$name\""; then
    echo "Signing identity \"$name\" already exists."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
password="$(uuidgen)"

cat > "$work/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.conf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -passout "pass:$password" -out "$work/identity.p12"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null

echo "Created signing identity \"$name\"."
echo "scripts/build-app.sh now signs with it. Grant Accessibility to the rebuilt Kith once."
