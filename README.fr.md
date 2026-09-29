# Navette

**Faire fonctionner un téléphone Android avec un Mac comme un iPhone.**
Presse-papier universel, notifications avec réponse rapide, point d'accès instantané, « faire
sonner mon téléphone », liens qui passent d'un appareil à l'autre — chiffré de bout en bout,
directement d'un appareil à l'autre en Wi-Fi ou en Bluetooth, sans serveur intermédiaire.

> 🇬🇧 [Read in English](README.md)

> **État : aperçu.** Navette est né comme un outil personnel pour un MacBook et un Galaxy S24 Ultra.
> Il sert tous les jours sur cette configuration mais n'a pas encore été beaucoup testé ailleurs.
> Ce dépôt est public pour savoir s'il est utile à d'autres avant d'en faire une vraie application :
> **votre avis est l'objectif** (voir [Votre avis](#votre-avis)).

## Ce que ça fait

| | Mac ↔ Android |
|---|---|
| **Presse-papier** | Copiez sur le Mac, collez sur le téléphone, automatiquement. Copiez sur le téléphone, collez sur le Mac, automatiquement aussi après une configuration unique (voir les [limites](#limites-honnêtes)). Texte et images (captures, « Copier l'image »). |
| **Notifications** | Les notifications du téléphone s'affichent sur le Mac avec l'icône de l'app. **Répondez** à WhatsApp, Messages… depuis la notification du Mac. Effacer d'un côté efface de l'autre. |
| **Point d'accès instantané** | Un clic sur le Mac (barre des menus, ou **bouton du Centre de contrôle** sous macOS 26) allume le point d'accès du téléphone — même sans internet sur le Mac — et y connecte le Wi-Fi du Mac. En option, automatiquement quand le Mac perd internet. *Samsung uniquement* (Modes et routines). |
| **État du téléphone** | Batterie, réseau (5G/4G) et barres de signal dans le menu du Mac, comme un iPhone dans le menu Wi-Fi. Alerte de batterie faible. |
| **Faire sonner** | Sonnerie au maximum, même en mode silencieux. |
| **Liens façon Handoff** | Téléphone : *Partager › Ouvrir sur le Mac*. Mac : envoyer l'onglet Safari/Chrome/Arc/Brave/Edge actif, ou un lien copié, au téléphone. |
| **Fichiers** | N'importe quel fichier ou dossier, dans les deux sens. Mac : déposez-le sur l'icône de la barre des menus, *Services › Envoyer au téléphone (Navette)* dans le Finder, ou le menu. Téléphone : *Partager › Fichier vers le Mac*. Les fichiers reçus arrivent dans Téléchargements. Rapide en Wi-Fi (40 Mo/s sur le point d'accès 5 GHz du téléphone) ; en Bluetooth, 2 Mo au plus. |
| **Historique** | Les 10 derniers éléments échangés, dans le menu du Mac (en mémoire seulement, jamais écrits sur disque). |

## Fonctionnement

```
App Mac (Swift, barre des menus)                App Android (Kotlin)
  surveille le presse-papier                      service de premier plan
  affiche les notifications                       lecture des notifications, partage, tuile
      ⇅ Wi-Fi (même réseau, ou Mac sur le point d'accès du téléphone) — ou Bluetooth ⇅
```

- **Chiffrement de bout en bout.** Un secret de 256 bits est créé sur le Mac et transmis au
  téléphone par QR code. Tout est chiffré en AES-256-GCM avant de quitter un appareil, et les deux
  appareils prouvent qu'ils détiennent le secret avant tout échange.
- **En direct, sans serveur.** Quand le Mac et le téléphone partagent un réseau — même Wi-Fi, ou Mac
  sur le point d'accès du téléphone — le Mac trouve le téléphone (Bonjour) et lui parle en direct,
  avec ou sans internet. Sans réseau commun, ils passent par le **Bluetooth** (texte instantané,
  images lentes). Rien ne transite par un serveur tiers.
- Les éléments des gestionnaires de mots de passe (marqués *confidentiels* sur macOS, *sensibles*
  sur Android) ne sont jamais envoyés.

Détails : [PROTOCOL.md](PROTOCOL.md) (en anglais).

## Limites honnêtes

- **Android interdit de lire le presse-papier en arrière-plan** (depuis Android 10). Pour envoyer
  automatiquement les copies du téléphone, Navette utilise le même contournement que KDE Connect :
  une commande `adb`, une seule fois, lui permet de lire les journaux système. Android 13+ redemande
  alors l'accès aux journaux **après chaque redémarrage de l'app** (redémarrage du téléphone, mise
  à jour). Sans cela, l'envoi depuis le téléphone demande un geste : tuile des réglages rapides,
  bouton de la notification, menu de sélection de texte ou Partager.
- **Les appareils doivent être proches** : sur le même Wi-Fi, Mac sur le point d'accès du
  téléphone, ou à portée de Bluetooth. Pas d'usage à distance.
- **Le point d'accès instantané passe par une routine Samsung**, car Android ne laisse aucune app
  l'allumer. Navette l'y déclenche en affichant une notification sur le téléphone.
- **Ni signé par Apple, ni sur le Play Store.** Vous téléchargez les apps depuis les
  [Releases](https://github.com/phoenixra17/navette/releases/latest) (ou les compilez) et les ouvrez
  à la main : Gatekeeper et Play Protect afficheront un avertissement.
- Testé sur un MacBook sous macOS 26 et un Galaxy S24 Ultra sous Android 16 / One UI.
  Nécessite Android 14+ et macOS 14+ (macOS 26 pour le bouton du Centre de contrôle).

## Installation

**Le plus rapide :** téléchargez `Navette-…-mac.zip` et `Navette-….apk` depuis la
[dernière version](https://github.com/phoenixra17/navette/releases/latest) — sa page explique
comment les ouvrir — puis appairez le téléphone comme ci-dessous. Pour compiler vous-même, suivez
les étapes 1 et 2.

### 1. Mac

Prérequis : Xcode, et `brew install xcodegen` (pour le bouton du Centre de contrôle).

```bash
cd mac && scripts/build-app.sh --install && open /Applications/Navette.app
```

Acceptez le Bluetooth, les
notifications et la localisation : la localisation uniquement parce que macOS cache le nom des
réseaux Wi-Fi aux apps qui ne l'ont pas ; votre position n'est ni utilisée ni envoyée.

### 2. Android

Compilez avec un JDK 17+ (celui d'Android Studio convient) : `cd android && ./gradlew assembleRelease`,
puis installez `app/build/outputs/apk/release/app-release.apk`. Ouvrez Navette › **Scanner le code
du Mac** (menu ⇄ du Mac › *Appairer le téléphone…*), puis suivez les étapes de l'écran : accès aux
notifications, batterie en arrière-plan, tuile des réglages rapides. Si vous ouvrez un lien
`navette://pair` au lieu de scanner, vérifiez que le code de vérification est celui affiché sous le
QR code du Mac.

**Si Google Play Protect bloque l'APK** (« Appli bloquée pour protéger votre appareil », avec un
seul bouton OK) : Play Protect refuse les apps installées hors Play Store qui demandent des accès
sensibles comme les notifications. Installez-la depuis un ordinateur, débogage USB activé :

```bash
adb install --user 0 Navette-0.2.0.apk
```

ou désactivez temporairement *Play Store › votre profil › Play Protect › ⚙ › Analyser les applis
avec Play Protect*, installez l'APK, puis réactivez-la.

**Facultatif — envoi automatique depuis le téléphone :** activez le débogage USB, branchez le
téléphone au Mac, lancez `android/scripts/activer-auto.sh`, puis acceptez l'accès aux journaux
dans Navette.

**Facultatif — point d'accès instantané (Samsung) :** appairez le Mac et le téléphone en Bluetooth,
puis créez une routine : **Si** *Notification reçue › Navette*, avec le mot-clé `demandé par le Mac`,
**Alors** *Point d'accès mobile › Activé*. (Évitez la condition *Appareil Bluetooth › votre Mac ›
Connecté* : la liaison Bluetooth de Navette compte comme une connexion, et le point d'accès
s'allumerait dès que le Mac perd son Wi-Fi.) Cliquez sur le téléphone dans le
menu du Mac ; la première fois, Navette demande le mot de passe du point d'accès et le garde dans
votre trousseau.

## Votre avis

C'est la raison d'être de ce dépôt public. [Ouvrez un ticket](../../issues/new/choose) pour me dire :

- quelles fonctions vous utiliseriez vraiment, et ce qui manque ;
- vos appareils (Mac / version de macOS, téléphone / version d'Android) et ce qui a marché ou non ;
- si une version aboutie vous intéresserait — installation depuis les stores — et si vous seriez
  prêt à la payer.

## Développement

| | |
|---|---|
| Mac | `cd mac && swift test` · `scripts/build-app.sh` |
| Android | `cd android && ./gradlew testDebugUnitTest assembleRelease` |

Les deux apps partagent des vecteurs de test pour le chiffrement.

L'app Mac est signée ad hoc : macOS redemande le Bluetooth, la localisation… après chaque
recompilation. Lancez une fois `mac/scripts/create-signing-cert.sh` : il crée un certificat de
signature local dans votre trousseau de session, que `build-app.sh` utilise ensuite, et macOS garde
les autorisations d'une compilation à l'autre.

## Licence

[AGPL-3.0](LICENSE). Merci de lire [CONTRIBUTING.md](CONTRIBUTING.md) avant de proposer une modification.
