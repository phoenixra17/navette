# Navette

**Make an Android phone work with a Mac the way an iPhone does.**
Universal clipboard, notifications with quick reply, instant hotspot, “ring my phone”, links that
jump between devices — end-to-end encrypted, straight from one device to the other over Wi-Fi or
Bluetooth, with no server in between.

> 🇫🇷 [Lire en français](README.fr.md)

> **Status: early preview.** Navette started as a personal tool for a MacBook and a Galaxy S24 Ultra.
> It is used every day on that setup but has not been tested widely yet. This repository is public
> to find out whether it is useful to others before turning it into a proper app — **your feedback
> is the point** (see [Feedback](#feedback)).

## What it does

| | Mac ↔ Android |
|---|---|
| **Clipboard** | Copy on the Mac, paste on the phone — automatically. Copy on the phone, paste on the Mac — automatically too, after a one-time setup (see [limits](#honest-limits)). Text and images (screenshots, “Copy image”). |
| **Notifications** | Phone notifications appear on the Mac with the app's icon. **Reply** to WhatsApp, Messages… from the Mac notification. Dismissing on one side dismisses on the other. |
| **Instant hotspot** | One click on the Mac (menu bar, or a **Control Center button** on macOS 26) turns on the phone's hotspot — even when the Mac has no internet — and switches the Mac's Wi-Fi to it. Optionally automatic when the Mac loses internet. *Samsung only* (uses Modes & Routines). |
| **Phone status** | Battery, network (5G/4G) and signal bars in the Mac menu, like an iPhone in the Wi-Fi menu. Low-battery alert. |
| **Ring my phone** | Rings at full volume, even in silent mode. |
| **Handoff-style links** | Phone: *Share › Open on Mac*. Mac: send the current Safari/Chrome/Arc/Brave/Edge tab, or a copied link, to the phone. |
| **Files** | Any file or folder, either way. Mac: drop it on the menu bar icon, *Services › Send to phone (Navette)* in the Finder, or the menu. Phone: *Share › File to Mac*. Received files land in Downloads. Fast over Wi-Fi (40 MB/s on the phone's 5 GHz hotspot); over Bluetooth, up to 2 MB. |
| **History** | The last 10 items exchanged, in the Mac menu (memory only, never written to disk). |

## How it works

```
Mac app (Swift, menu bar)                      Android app (Kotlin)
  watches the clipboard                          foreground service
  shows notifications                            notification listener, share targets, tile
        ⇅ Wi-Fi (same network, or the Mac on the phone's hotspot) — or Bluetooth ⇅
```

- **End-to-end encryption.** A 256-bit secret is created on the Mac and handed to the phone by QR
  code. Everything is encrypted with AES-256-GCM before leaving a device, and both devices prove
  they hold the secret before exchanging anything.
- **Direct, no server.** When the Mac and the phone share a network — same Wi-Fi, or the Mac on the
  phone's hotspot — the Mac finds the phone (Bonjour) and talks to it directly, with or without
  internet. With no shared network, they fall back to **Bluetooth** (text is instant, images are
  slow). Nothing goes through a third-party server.
- Password-manager items (marked *concealed* on macOS, *sensitive* on Android) are never sent.

Details: [PROTOCOL.md](PROTOCOL.md).

## Honest limits

- **Android forbids reading the clipboard in the background** (since Android 10). To send phone
  copies automatically, Navette uses the same workaround as KDE Connect: a one-time `adb` command
  lets it read system logs. Android 13+ then asks you to allow log access **again after every
  restart of the app** (phone reboot, update). Without it, sending from the phone takes one
  gesture: Quick Settings tile, notification button, text selection menu, or Share.
- **The devices must be near each other**: on the same Wi-Fi network, the Mac on the phone's
  hotspot, or within Bluetooth range. There is no remote mode.
- **Instant hotspot relies on a Samsung routine**, because Android lets no app turn the hotspot on.
  Navette on the phone posts a notification that triggers it.
- **Not signed by Apple, not on the Play Store.** You download the apps from
  [Releases](https://github.com/phoenixra17/navette/releases/latest) (or build them) and open them
  by hand: Gatekeeper and Play Protect will warn you.
- Tested on a MacBook with macOS 26 and a Galaxy S24 Ultra with Android 16 / One UI.
  Requires Android 14+ and macOS 14+ (macOS 26 for the Control Center button).

## Install

The apps' interface is in **French** for now; menu labels are quoted as they appear.

**Quickest:** download `Navette-…-mac.zip` and `Navette-….apk` from the
[latest release](https://github.com/phoenixra17/navette/releases/latest) — its page explains how to
open them — then pair the phone as described below. To build from source, follow steps 1–2.

### 1. Mac

Requirements: Xcode, and `brew install xcodegen` (for the Control Center button).

```bash
cd mac && scripts/build-app.sh --install && open /Applications/Navette.app
```

Allow Bluetooth,
notifications and location when asked — location only because macOS hides Wi-Fi network names
from apps without it; your position is neither used nor sent.

### 2. Android

Build with a JDK 17+ (Android Studio's works): `cd android && ./gradlew assembleRelease`, then
install `app/build/outputs/apk/release/app-release.apk`. Open Navette › **Scanner le code du Mac**
and scan the QR code shown by the Mac (menu ⇄ › *Appairer le téléphone…*), then follow the in-app
checklist: notification access, background battery use, Quick Settings tile. If you open a
`navette://pair` link instead of scanning, check that the verification code matches the one under
the Mac's QR code.

**If Google Play Protect blocks the APK** (“App blocked to protect your device”, with only an OK
button): Play Protect refuses sideloaded apps that ask for sensitive access such as notifications.
Either install it from a computer with USB debugging on:

```bash
adb install --user 0 Navette-0.2.0.apk
```

or temporarily turn off *Play Store › your profile › Play Protect › ⚙ › Scan apps with Play
Protect*, install the APK, then turn it back on.

**Optional — automatic sending from the phone:** enable USB debugging, plug the phone into the Mac,
run `android/scripts/activer-auto.sh`, then accept the log-access prompt in Navette.

**Optional — instant hotspot (Samsung):** pair the Mac and the phone over Bluetooth, then create a
routine: **If** *Notification received › Navette*, with the keyword `demandé par le Mac`, **Then**
*Mobile Hotspot › On*. (Avoid the *Bluetooth device › your Mac › Connected* trigger: Navette's
Bluetooth link counts as a connection, and the hotspot would turn on whenever the Mac loses its
Wi-Fi.) Click the phone in the Mac menu; the first time, Navette asks for the
hotspot password and keeps it in your keychain.

## Feedback

This is why the repository is public. Please [open an issue](../../issues/new/choose) and tell me:

- which features you would actually use, and what is missing (an English interface?);
- your devices (Mac / macOS version, phone / Android version) and what did or didn't work;
- whether you would want a polished version — app-store install — and whether you would pay
  for it.

## Development

| | |
|---|---|
| Mac | `cd mac && swift test` · `scripts/build-app.sh` |
| Android | `cd android && ./gradlew testDebugUnitTest assembleRelease` |

The two apps share test vectors for the encryption. Code comments are in French.

Mac builds are signed ad hoc, so macOS asks again for Bluetooth, Location… after each rebuild. Run
`mac/scripts/create-signing-cert.sh` once: it creates a local signing certificate in your login
keychain, which `build-app.sh` then uses, and macOS keeps the permissions across rebuilds.

## License

[AGPL-3.0](LICENSE). Please read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request.
