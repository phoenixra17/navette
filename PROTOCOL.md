# Navette — protocol and implementation notes

## Keys

A 256-bit secret is generated on the Mac and shared with the phone through the pairing QR code
(`navette://pair?u=<relay address>&s=<secret>`). Three values are derived with HMAC-SHA256:

| Derivation | Known by | Purpose |
|---|---|---|
| `navette/auth/v1` → token | Mac, phone, **relay** | authenticates devices to the relay (`Authorization: Bearer`) |
| `navette/enc/v1` → AES key | Mac, phone | encrypts content (AES-256-GCM) |
| `navette/fingerprint/v1` → 6-digit code | Mac, phone | shown on both screens when pairing, so a forged pairing link is spotted |

**Protocol v2.** The associated data of each message is `navette/v2|<sender>|<id>`, where the
sender is `mac` or `phone`: a message sent back to its own sender (by the relay, for example) does
not decrypt. Every payload carries `t`, the sender's clock in milliseconds; messages received live
are dropped if `t` is more than 5 minutes away from the receiver's clock or if their id was already
seen (`ReplayGuard`). `GET /api/clip/last` is only applied if it is newer than the last clip
received. So the relay can neither read, forge, redirect nor replay messages; it can still drop or
delay them. v1 and v2 devices cannot talk to each other: update the Mac and the phone together.

`server/tests/protocol.js` is the reference implementation; the Swift and Kotlin test suites decrypt
vectors it produced.

## Rooms

The relay routes by token: devices that present the same token share a room and only see each
other's messages. The relay keys rooms by the SHA-256 of the token and never stores the token.

- **Private mode** (`NAVETTE_TOKEN=<token>[,<token>…]`): only the listed tokens are accepted.
- **Open mode** (`NAVETTE_OPEN=1`): any well-formed token (43 base64url characters) opens its own
  room, so one relay can serve many users who never register. Limits keep it in check, all
  configurable through environment variables:

| Variable | Default | Limit |
|---|---|---|
| `NAVETTE_MAX_BYTES` | 16 MB | size of one message |
| `NAVETTE_MAX_ROOMS` | 1000 | rooms in memory (503 beyond) |
| `NAVETTE_MAX_DEVICES` | 8 | devices per room (403 beyond; a known device can always reconnect) |
| `NAVETTE_RATE_MESSAGES` / `NAVETTE_RATE_MB` | 300 / 100 MB | per room and per minute (HTTP 429; dropped over WebSocket) |
| `NAVETTE_STORE_MB` | 256 MB | memory for all “last clipboard items”; the oldest are forgotten first |
| `NAVETTE_LAST_HOURS` | 24 | how long a room's last clipboard item is kept |

`GET /api/health` returns `{"ok": true, "open": <bool>}`. In open mode, the log names rooms by the
first six hex digits of their key and does not log individual messages (`NAVETTE_VERBOSE=1` does).

## Messages

Each message is relayed as `{type: "clip", id, iv, data, ephemeral?}` over WebSocket (`/ws`) or
`POST /api/clip`. Devices identify themselves with `X-Navette-Device`; a message goes to every
other device. Decrypted, `kind` tells what it carries:

| `kind` | Direction | Fields |
|---|---|---|
| `text` | ⇄ | `text` |
| `image` | ⇄ | `mime` (image/png, image/jpeg), `data` (base64) — over 3 MB, resized to 2560 px and sent as JPEG |
| `notif` | phone → Mac | `key`, `pkg`, `app`, `title`, `text`, `canReply`, `icon` (PNG, base64) |
| `notif-removed` | phone → Mac | `key` |
| `notif-dismiss` | Mac → phone | `key` |
| `reply` / `reply-result` | Mac → phone / phone → Mac | `key`, `text` / `key`, `ok` |
| `battery` | phone → Mac | `level`, `charging`, `net` (5G, 4G…), `signal` (0–4) |
| `sync` | Mac → phone | (the phone answers with `battery`) |
| `ring` / `ring-stop` | Mac → phone | |
| `url` | ⇄ | `url` (http/https only) |

Everything except `text` and `image` is sent with `ephemeral: true`: the relay forwards it but does
not keep it as the “last clipboard item” served by `GET /api/clip/last`. Unknown kinds are ignored,
so one app can be updated before the other.

## Automatic sending from Android

Android 10+ blocks background clipboard reads. Navette works around it like KDE Connect:

1. **Detection.** Navette registers a clipboard listener. Android refuses to notify it but logs
   `Denying clipboard access to <package>` on every copy. With `READ_LOGS` (granted once via
   `adb`), Navette reads that line from `logcat`.
2. **Reading.** A transparent activity comes to the foreground for a fraction of a second, reads
   the clipboard and closes; the current app keeps the focus. Android 15+ only allows a background
   app to start an activity if it holds “display over other apps” *and* shows an overlay window,
   so Navette adds a 1-pixel, non-touchable overlay for the launch.

Android 13+ asks the user to approve log access for each new `logcat` process and refuses it
outright when the app is in the background (e.g. after a reboot). Navette probes whether it can
see system logs (by starting a non-existent service, which the system logs) and, if not, shows
“auto-send paused — tap to re-enable”.

## Instant hotspot

Android lets no third-party app turn the hotspot on; a Samsung Modes & Routines routine can,
triggered by “Bluetooth device connected”. A bare Bluetooth link does not count as connected
on Android, so the Mac opens a Hands-Free Profile service-level connection (RFCOMM to the phone's
`0x111F` service, then `AT+BRSF`, `AT+CIND=?`, `AT+CIND?`, `AT+CMER`) and closes it after
15 seconds. No audio is ever set up.

The Mac then **scans** for the hotspot network (a scan does not drop the current Wi-Fi) and joins
it once visible, using CoreWLAN with a password kept in the user's keychain — the one macOS
remembers is in the System keychain, which apps cannot read without admin rights. Reading
network names requires Location permission since macOS 14.

The Control Center button (`mac/Controls`) is a sandboxed WidgetKit extension that opens
`navette://point-acces`; the app handles it like a click in its menu.

Diagnostics: `~/Library/Logs/Navette.log` on the Mac.
