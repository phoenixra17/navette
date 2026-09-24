#!/bin/zsh
# Compile Navette et assemble Navette.app (signature ad hoc).
# Usage : scripts/build-app.sh [--install]   (--install copie l'app dans /Applications)
# Version : NAVETTE_VERSION (ex. 0.2.0) et NAVETTE_BUILD (entier croissant), fixées par la CI.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${NAVETTE_VERSION:-0.1.0}
BUILD=${NAVETTE_BUILD:-1}

# Binaire universel : Mac Apple Silicon et Intel.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
APP=build/Navette.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $ARCHS --show-bin-path)/Navette" "$APP/Contents/MacOS/Navette"
cp Resources/Navette.icns "$APP/Contents/Resources/Navette.icns" # régénérer : swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>fr.soufiane.navette</string>
  <key>CFBundleName</key><string>Navette</string>
  <key>CFBundleDisplayName</key><string>Navette</string>
  <key>CFBundleExecutable</key><string>Navette</string>
  <key>CFBundleIconFile</key><string>Navette</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>fr.soufiane.navette</string>
    <key>CFBundleURLSchemes</key><array><string>navette</string></array>
  </dict></array>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Navette se connecte à votre serveur sur le réseau local pour partager le presse-papier avec votre téléphone.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Navette se connecte en Bluetooth à votre téléphone pour lui demander d’activer son point d’accès.</string>
  <key>NSLocationUsageDescription</key>
  <string>macOS n’indique le nom des réseaux Wi-Fi qu’aux apps autorisées : Navette en a besoin pour se connecter au point d’accès de votre téléphone. Votre position n’est ni utilisée ni transmise.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>macOS n’indique le nom des réseaux Wi-Fi qu’aux apps autorisées : Navette en a besoin pour se connecter au point d’accès de votre téléphone. Votre position n’est ni utilisée ni transmise.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Navette lit l’adresse de l’onglet actif de votre navigateur pour l’ouvrir sur votre téléphone.</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Bouton du Centre de contrôle (extension WidgetKit, projet Xcode généré par XcodeGen).
( cd Controls && xcodegen generate --quiet \
  && xcodebuild -project NavetteControls.xcodeproj -scheme NavetteControls -configuration Release \
       -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet )
mkdir -p "$APP/Contents/PlugIns"
cp -R Controls/build/Build/Products/Release/NavetteControls.appex "$APP/Contents/PlugIns/"
for key value in CFBundleShortVersionString "$VERSION" CFBundleVersion "$BUILD"; do
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP/Contents/PlugIns/NavetteControls.appex/Contents/Info.plist"
done
codesign --force --sign - --entitlements Controls/NavetteControls.entitlements "$APP/Contents/PlugIns/NavetteControls.appex"

codesign --force --sign - "$APP"
echo "✓ $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Navette || true
  rm -rf /Applications/Navette.app
  cp -R "$APP" /Applications/
  echo "✓ installée dans /Applications — lancez-la avec : open /Applications/Navette.app"
fi
