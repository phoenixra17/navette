#!/bin/zsh
# Active l'envoi automatique Android → Mac (à faire une seule fois, téléphone branché en USB
# avec le débogage USB autorisé). Les autorisations survivent aux redémarrages ; à refaire
# seulement après une désinstallation de Navette.
set -euo pipefail
ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PKG=fr.soufiane.navette

echo "En attente du téléphone… (acceptez « Autoriser le débogage USB » sur l’écran du S24)"
"$ADB" wait-for-device
"$ADB" shell pm list packages --user 0 | grep -q "$PKG" || { echo "Navette n’est pas installée sur ce téléphone."; exit 1; }

"$ADB" shell pm grant --user 0 "$PKG" android.permission.READ_LOGS
"$ADB" shell appops set --user 0 "$PKG" SYSTEM_ALERT_WINDOW allow
# Les autorisations ne s'appliquent qu'au prochain démarrage de l'app.
"$ADB" shell am force-stop --user 0 "$PKG"
"$ADB" shell am start --user 0 -n "$PKG/.MainActivity" >/dev/null

echo "✓ Envoi automatique activé. Vous pouvez débrancher le téléphone."
