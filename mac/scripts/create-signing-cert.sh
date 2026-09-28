#!/bin/zsh
# Crée le certificat « Navette (signature locale) » dans le trousseau de session, une fois par Mac.
# build-app.sh signe alors avec lui : macOS garde les autorisations de l'app (Bluetooth, localisation…)
# d'une compilation à l'autre, au lieu de les redemander comme avec une signature ad hoc.
# La clé privée ne quitte pas le trousseau ; seul codesign peut s'en servir.
set -euo pipefail
NAME="Navette (signature locale)"
if security find-identity -p codesigning | grep -qF "\"$NAME\""; then
  echo "✓ « $NAME » existe déjà"
  exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# /usr/bin/openssl (LibreSSL) produit un .p12 que « security import » sait lire.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "✓ « $NAME » créé. Recompilez avec scripts/build-app.sh : macOS redemandera les autorisations une dernière fois."
