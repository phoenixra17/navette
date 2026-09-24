# Navette

**Make an Android phone work with a Mac the way an iPhone does.**
Universal clipboard, notifications with quick reply, instant hotspot, “ring my phone”, links that
jump between devices — end-to-end encrypted, through a small relay you host yourself.

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
| **History** | The last 10 items exchanged, in the Mac menu (memory only, never written to disk). |

## How it works

```
Mac app (Swift, menu bar)                Android app (Kotlin)
  watches the clipboard                    foreground service
  shows notifications                      notification listener, share targets, tile
          ⇅ WebSocket                               ⇅ WebSocket / HTTP
                 Relay (Node.js, Docker) — only sees encrypted blobs
```

- **End-to-end encryption.** A 256-bit secret is created on the Mac and handed to the phone by QR
  code. Everything is encrypted with AES-256-GCM before leaving a device. The relay only knows an
  access token derived one-way from the secret: it can neither read nor alter anything.
- **A public test relay** is available while Navette is in preview, so you can try it without
  hosting anything (see [Install](#install)). Or **host your own** on any machine both devices can
  reach: a NAS, a Raspberry Pi, a small VPS.
- Password-manager items (marked *concealed* on macOS, *sensitive* on Android) are never sent.

Details: [PROTOCOL.md](PROTOCOL.md).

## Honest limits

- **Android forbids reading the clipboard in the background** (since Android 10). To send phone
  copies automatically, Navette uses the same workaround as KDE Connect: a one-time `adb` command
  lets it read system logs. Android 13+ then asks you to allow log access **again after every
  restart of the app** (phone reboot, update). Without it, sending from the phone takes one
  gesture: Quick Settings tile, notification button, text selection menu, or Share.
- **Instant hotspot relies on a Samsung routine**, because Android lets no app turn the hotspot on.
  The Mac briefly connects to the phone as a Bluetooth hands-free device to trigger it.
- **Not signed by Apple, not on the Play Store.** You download the apps from
  [Releases](https://github.com/phoenixra17/navette/releases/latest) (or build them) and open them
  by hand: Gatekeeper and Play Protect will warn you.
- Tested on a MacBook with macOS 26 and a Galaxy S24 Ultra with Android 16 / One UI.
  Requires Android 14+ and macOS 14+ (macOS 26 for the Control Center button).

## Install

The apps' interface is in **French** for now; menu labels are quoted as they appear.

**Quickest:** download `Navette-…-mac.zip` and `Navette-….apk` from the
[latest release](https://github.com/phoenixra17/navette/releases/latest) — its page explains how to
open them — then enter the test relay and pair the phone as described below. To build from source,
follow steps 1–3.

### 1. Mac

Requirements: Xcode, and `brew install xcodegen` (for the Control Center button).

```bash
cd mac && scripts/build-app.sh --install && open /Applications/Navette.app
```

On first launch, enter the relay address — to try Navette, the public test relay:

```
https://navette.yourpediatricsurgeon.com
```

and skip step 2. Allow Bluetooth,
notifications and location when asked — location only because macOS hides Wi-Fi network names
from apps without it; your position is neither used nor sent.

### 2. Your own relay (optional)

Use **Copier le jeton du serveur** (copy the server token) in the Mac menu, then:

```bash
cd server
printf 'NAVETTE_TOKEN=%s\nTZ=Europe/Paris\n' 'PASTE_THE_TOKEN_HERE' > .env && chmod 600 .env
docker compose up -d --build
curl http://localhost:3200/api/health   # → {"ok":true,"open":false}
```

Then set the Mac's **Adresse du serveur…** (server address) to your relay, e.g.
`http://192.168.1.10:3200`, or its [Tailscale](https://tailscale.com) address to reach it from
anywhere, 4G included. The menu bar icon turns from “!” to connected within seconds.

**Sharing one relay.** With `NAVETTE_OPEN=1` instead of `NAVETTE_TOKEN`, the relay accepts any
Navette pair: each one gets its own room and cannot see the others (see [PROTOCOL.md](PROTOCOL.md#rooms)
for the limits). Exposed through a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
or any HTTPS reverse proxy, it lets friends or testers use Navette without hosting anything or
installing Tailscale: they enter `https://your-relay.example.com` on first launch.

### 3. Android

Build with a JDK 17+ (Android Studio's works): `cd android && ./gradlew assembleRelease`, then
install `app/build/outputs/apk/release/app-release.apk`. Open Navette › **Scanner le code du Mac**
and scan the QR code shown by the Mac (menu ⇄ › *Appairer le téléphone…*), then follow the in-app
checklist: notification access, background battery use, Quick Settings tile.

**Optional — automatic sending from the phone:** enable USB debugging, plug the phone into the Mac,
run `android/scripts/activer-auto.sh`, then accept the log-access prompt in Navette.

**Optional — instant hotspot (Samsung):** pair the Mac and the phone over Bluetooth, then create a
routine: **If** *Bluetooth device › your Mac › Connected*, **Then** *Mobile Hotspot › On*, with
*Keep routine until: Always*. Click the phone in the Mac menu; the first time, Navette asks for the
hotspot password and keeps it in your keychain.

## Feedback

This is why the repository is public. Please [open an issue](../../issues/new/choose) and tell me:

- which features you would actually use, and what is missing (an English interface?);
- your devices (Mac / macOS version, phone / Android version) and what did or didn't work;
- whether you would want a polished version — app-store install, no self-hosted relay — and
  whether you would pay for it.

## About the test relay

It is run by the author on a home server, on a best-effort basis: it may be down at times, and
it may go away once Navette becomes an app. It only ever sees encrypted data (it cannot read your
clipboard or notifications) and keeps nothing on disk; it does see IP addresses and when devices
connect. Each pair of devices has its own room; limits apply (see [PROTOCOL.md](PROTOCOL.md#rooms)).
If you'd rather not depend on it, host your own relay (step 2).

## Development

| | |
|---|---|
| Relay | `cd server && npm test` |
| Mac | `cd mac && swift test` · `scripts/build-app.sh` |
| Android | `cd android && ./gradlew testDebugUnitTest assembleRelease` |

The three implementations share test vectors for the encryption. Code comments are in French.

## License

[AGPL-3.0](LICENSE). Please read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request.
