#!/bin/zsh
# One-time: creates a local self-signed code-signing identity "Sidekick Dev" in your login keychain,
# so macOS permission grants (TCC) survive rebuilds. Then clears Sidekick's stale permission entries.
set -e
NAME="Sidekick Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ '$NAME' signing identity already exists"
else
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout pass:sidekick
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P sidekick -T /usr/bin/codesign
  rm -rf "$TMP"
  echo "✓ created '$NAME' signing identity"
fi

echo "resetting Sidekick's old permission entries…"
pkill -x Sidekick 2>/dev/null || true
for svc in Accessibility ScreenCapture Microphone ListenEvent AppleEvents; do
  tccutil reset "$svc" com.mayankyadav.sidekick >/dev/null 2>&1 || true
done
echo "✓ done — now run: ./build.sh install && open /Applications/Sidekick.app"
