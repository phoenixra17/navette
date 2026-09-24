# Navette

**Faire fonctionner un téléphone Android avec un Mac comme un iPhone.**
Presse-papier universel, notifications avec réponse rapide, point d'accès instantané, « faire
sonner mon téléphone », liens qui passent d'un appareil à l'autre — chiffré de bout en bout, via
un petit relais que vous hébergez vous-même.

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
| **Historique** | Les 10 derniers éléments échangés, dans le menu du Mac (en mémoire seulement, jamais écrits sur disque). |

## Fonctionnement

```
App Mac (Swift, barre des menus)         App Android (Kotlin)
  surveille le presse-papier               service de premier plan
  affiche les notifications                lecture des notifications, partage, tuile
          ⇅ WebSocket                               ⇅ WebSocket / HTTP
            Relais (Node.js, Docker) — ne voit que des données chiffrées
```

- **Chiffrement de bout en bout.** Un secret de 256 bits est créé sur le Mac et transmis au
  téléphone par QR code. Tout est chiffré en AES-256-GCM avant de quitter un appareil. Le relais ne
  connaît qu'un jeton d'accès dérivé du secret à sens unique : il ne peut ni lire ni modifier.
- **Un relais de test public** est disponible pendant l'aperçu, pour essayer sans rien héberger
  (voir [Installation](#installation)). Ou **hébergez le vôtre** sur une machine joignable par les
  deux appareils : NAS, Raspberry Pi, petit serveur.
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
- **Le point d'accès instantané passe par une routine Samsung**, car Android ne laisse aucune app
  l'allumer. Le Mac se connecte brièvement au téléphone comme kit mains-libres Bluetooth pour la
  déclencher.
- **Ni signé par Apple, ni sur le Play Store.** Vous compilez l'app Mac vous-même (signature
  locale) et installez l'APK à la main. Gatekeeper et Play Protect afficheront un avertissement.
- Testé sur un MacBook sous macOS 26 et un Galaxy S24 Ultra sous Android 16 / One UI.
  Nécessite Android 14+ et macOS 14+ (macOS 26 pour le bouton du Centre de contrôle).

## Installation

### 1. Mac

Prérequis : Xcode, et `brew install xcodegen` (pour le bouton du Centre de contrôle).

```bash
cd mac && scripts/build-app.sh --install && open /Applications/Navette.app
```

Au premier lancement, indiquez l'adresse du relais ; pour essayer Navette, le relais de test public :

```
https://navette.yourpediatricsurgeon.com
```

et passez l'étape 2. Acceptez le Bluetooth, les
notifications et la localisation : la localisation uniquement parce que macOS cache le nom des
réseaux Wi-Fi aux apps qui ne l'ont pas ; votre position n'est ni utilisée ni envoyée.

### 2. Votre propre relais (facultatif)

Dans le menu du Mac, **Copier le jeton du serveur**, puis :

```bash
cd server
printf 'NAVETTE_TOKEN=%s\nTZ=Europe/Paris\n' 'COLLEZ_LE_JETON_ICI' > .env && chmod 600 .env
docker compose up -d --build
curl http://localhost:3200/api/health   # → {"ok":true,"open":false}
```

Réglez ensuite **Adresse du serveur…** dans le menu du Mac sur votre relais, par ex.
`http://192.168.1.10:3200`, ou son adresse [Tailscale](https://tailscale.com) pour le joindre de
partout, 4G comprise. L'icône de la barre des menus passe de « ! » à connectée en quelques secondes.

**Partager un relais.** Avec `NAVETTE_OPEN=1` à la place de `NAVETTE_TOKEN`, le relais accepte
n'importe quelle paire Navette : chacune a son salon et ne voit pas les autres (limites dans
[PROTOCOL.md](PROTOCOL.md#rooms)). Exposé par un [tunnel Cloudflare](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
ou tout proxy HTTPS, il permet à des proches ou des testeurs d'utiliser Navette sans rien héberger
ni installer Tailscale : ils saisissent `https://votre-relais.exemple.com` au premier lancement.

### 3. Android

Compilez avec un JDK 17+ (celui d'Android Studio convient) : `cd android && ./gradlew assembleRelease`,
puis installez `app/build/outputs/apk/release/app-release.apk`. Ouvrez Navette › **Scanner le code
du Mac** (menu ⇄ du Mac › *Appairer le téléphone…*), puis suivez les étapes de l'écran : accès aux
notifications, batterie en arrière-plan, tuile des réglages rapides.

**Facultatif — envoi automatique depuis le téléphone :** activez le débogage USB, branchez le
téléphone au Mac, lancez `android/scripts/activer-auto.sh`, puis acceptez l'accès aux journaux
dans Navette.

**Facultatif — point d'accès instantané (Samsung) :** appairez le Mac et le téléphone en Bluetooth,
puis créez une routine : **Si** *Appareil Bluetooth › votre Mac › Connecté*, **Alors** *Point d'accès
mobile › Activé*, avec *Conserver la routine jusqu'au : Toujours*. Cliquez sur le téléphone dans le
menu du Mac ; la première fois, Navette demande le mot de passe du point d'accès et le garde dans
votre trousseau.

## Votre avis

C'est la raison d'être de ce dépôt public. [Ouvrez un ticket](../../issues/new/choose) pour me dire :

- quelles fonctions vous utiliseriez vraiment, et ce qui manque ;
- vos appareils (Mac / version de macOS, téléphone / version d'Android) et ce qui a marché ou non ;
- si une version aboutie vous intéresserait — installation depuis les stores, sans relais à
  héberger — et si vous seriez prêt à la payer.

## À propos du relais de test

Il tourne sur un serveur personnel de l'auteur, sans garantie : il peut être indisponible par
moments, et disparaître quand Navette deviendra une application. Il ne voit que des données
chiffrées (il ne peut lire ni votre presse-papier ni vos notifications) et n'écrit rien sur disque ;
il voit en revanche les adresses IP et les heures de connexion. Chaque paire d'appareils a son
salon ; des limites s'appliquent (voir [PROTOCOL.md](PROTOCOL.md#rooms)). Pour ne pas en dépendre,
hébergez votre relais (étape 2).

## Développement

| | |
|---|---|
| Relais | `cd server && npm test` |
| Mac | `cd mac && swift test` · `scripts/build-app.sh` |
| Android | `cd android && ./gradlew testDebugUnitTest assembleRelease` |

Les trois implémentations partagent des vecteurs de test pour le chiffrement.

## Licence

[AGPL-3.0](LICENSE). Merci de lire [CONTRIBUTING.md](CONTRIBUTING.md) avant de proposer une modification.
