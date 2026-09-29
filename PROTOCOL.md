# Navette — protocol and implementation notes

## Keys

A 256-bit secret is generated on the Mac and shared with the phone through the pairing QR code
(`navette://pair?s=<secret>`). Values are derived with HMAC-SHA256:

| Derivation | Known by | Purpose |
|---|---|---|
| `navette/enc/v1` → AES key | Mac, phone | encrypts content (AES-256-GCM) |
| `navette/fingerprint/v1` → 6-digit code | Mac, phone | shown on both screens when pairing, so a forged pairing link is spotted |

**Protocol v2.** The associated data of each message is `navette/v2|<sender>|<id>`, where the
sender is `mac` or `phone`: a message sent back to its own sender does not decrypt. Every payload
carries `t`, the sender's clock in milliseconds; messages are dropped if `t` is more than 5 minutes
away from the receiver's clock or if their id was already seen (`ReplayGuard`). v1 and v2 devices
cannot talk to each other: update the Mac and the phone together.

The Swift and Kotlin test suites share reference vectors, so both implementations stay identical.

## Messages

Each message travels as `{type: "clip", id, iv, data, ephemeral?}` over the [local
link](#local-link) or the [Bluetooth link](#bluetooth-link). Decrypted, `kind` tells what it
carries:

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
| `hotspot` / `hotspot-ok` | Mac → phone / phone → Mac | see [Instant hotspot](#instant-hotspot) |
| `url` | ⇄ | `url` (http/https only) |
| `file` / `file-end` / `file-ack` / `file-cancel` | ⇄ | see [Files](#files) |

Everything except `text` and `image` is sent with `ephemeral: true`. Unknown kinds are ignored, so
one app can be updated before the other.

## Files

Any file (a folder is zipped by the Mac first) travels as a series of `file` chunks, each one
encrypted on its own in the [binary format](#binary-chunks), so neither side ever holds the whole
file in memory. Control messages are ordinary JSON messages.

| `kind` | From | Fields |
|---|---|---|
| `file` | sender | binary chunk: metadata `fid` (transfer id), `name`, `size`, `mime` (optional), `off` (byte offset), then the raw bytes |
| `file-end` | sender | `fid`, `name`, `size`, `n` (attempt number) — everything was sent |
| `file-ack` | receiver | `fid`, `missing` (list of `[start, end)` byte ranges not received; empty = complete), `n` (echoed) |
| `file-cancel` | either | `fid` — the sender cancelled, or the receiver gave up (bad chunk, disk, 120 s without news) |

- **Pacing.** The Mac keeps at most 4 chunks in flight (read, sealed or being written): with a single
  one, the pipe empties between chunks and a hotspot link drops from 40 MB/s to 2.5 MB/s. Android
  writes each chunk into its socket, whose kernel buffer does the same job. Memory stays bounded
  either way.
- **Chunks** are 512 KB over Wi-Fi, 32 KB over Bluetooth (so a frame passes well within
  the 40 s link timeout, even over GATT). Each carries its offset: the order of arrival does not
  matter. The receiver merges the byte ranges it has, so overlapping chunks of different sizes
  (the route, hence the chunk size, can change mid-transfer) are counted once.
- **Acknowledgment.** A link can die silently: writes into a dead TCP connection succeed until the
  Mac notices, up to 40 s later. So after the last chunk the sender sends `file-end` over the same
  path, and the receiver answers `file-ack` with the ranges it lacks; the sender resends them (the
  message router falls back to another link) and asks again, up to 10 rounds, 4 `file-end` attempts
  of 20 s each. An ack whose `n` does not match the latest `file-end` is stale (chunks were still on
  their way) and ignored, unless it says complete. The receiver also sends an empty `file-ack` as
  soon as it has every byte. Only then does the sender report success.
- **Routes.** Wi-Fi for any size (4 GB at most); without it, Bluetooth up to 2 MB (about
  50 KB/s). The route is chosen again for every chunk and every `file-end`: a Wi-Fi link lost
  mid-transfer gives way to Bluetooth, a Wi-Fi link that comes back takes over. With no route at
  all, the sender waits up to 40 s. A file too large for the available links is refused before
  sending.
- **Received files** are assembled in a cache folder, then moved to `~/Downloads` on the Mac (`name
  2.ext` if taken) or copied to `Download/Navette` on Android (MediaStore). The name is sanitised on
  both sides: no path, no leading dot, no control character.

## Binary chunks

File chunks skip base64, which would otherwise add 78 % (base64 of a JSON payload holding base64).

- **Plaintext:** 4-byte big-endian length, the metadata as UTF-8 JSON (with `t`, like any payload),
  then the raw bytes. Encrypted with AES-256-GCM like other messages, but with associated data
  `navette/v2b|<sender>|<id>`, so a chunk never decrypts as a JSON message nor the other way round.
- **Direct links** (Wi-Fi, Bluetooth) carry it in a binary frame: the high bit of the 4-byte frame
  length is set, and the body is a 2-byte big-endian header length, a JSON header `{id, iv}` (iv in
  base64), then ciphertext ‖ tag. Each side announces that it reads binary frames with `bin: 1` in
  its `hello`; without it, chunks go as JSON clips.

Measured between a MacBook and a Galaxy S24: 1.00 byte on the wire per byte of file over the direct
link (1.8 with base64); 200 MB in about 5 s Mac → phone and 3 s phone → Mac over the phone's 5 GHz
hotspot; 1 MB in 18–20 s over Bluetooth (34–41 s before). Both test suites share a reference
vector.

## Local link

When both devices share a network, they talk directly over TCP.

- **The phone listens** on TCP port 3201 (any free port if taken) and advertises `_navette._tcp`
  over Bonjour/mDNS, with a TXT record `id` = the first 6 bytes, in hex, of
  HMAC(secret, `navette/local-id/v1`): the Mac only connects to its own phone.
- **The Mac connects**, trying in order: `NAVETTE_LOCAL=host:port` (debugging), Bonjour results,
  then its gateway (on the phone's hotspot, the phone itself).
  It retries with backoff (2 s → 60 s) and at once on wake or network change.
- **Framing:** 4-byte big-endian length, then UTF-8 JSON (or a [binary chunk](#binary-chunks) when the
  length's high bit is set). At most 4 KB per frame before authentication, 24 MB after.
- **Handshake**, with `localKey` = HMAC(secret, `navette/local/v1`) and
  `proof(role) = base64(HMAC-SHA256(localKey, "navette/local/v1|<role>|<macNonce>|<phoneNonce>"))`:

  1. Mac → `{type: "hello", v: 1, nonce: <macNonce>}` (16 random bytes, base64)
  2. phone → `{type: "hello", v: 1, nonce: <phoneNonce>, proof: proof("phone")}`
  3. Mac checks it, → `{type: "auth", proof: proof("mac")}`
  4. phone checks it, → `{type: "ready"}`

  A device that does not hold the secret gets nothing but a closed connection. The phone accepts
  at most four handshakes at once and one authenticated Mac (the newest replaces the previous).
- **Then** `{type: "clip", id, iv, data, ephemeral?}` messages, encrypted end to end and checked by
  `ReplayGuard`, plus `ping`/`pong` every 15 s (the Mac drops the link after 40 s of silence).

Both test suites share reference vectors for the handshake proofs.

## Bluetooth link

When there is no Wi-Fi link (no shared network), the same framed stream, handshake and messages run
over Bluetooth Low Energy, so the devices still talk with no network at all.

- **The phone** runs a GATT server with service `8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a10` and
  advertises it. It also listens on an L2CAP connection-oriented channel (insecure: no Bluetooth
  pairing, the handshake authenticates) and publishes its PSM in `…4a13` (read, 2 bytes big-endian).
  Android requires the *Nearby devices* permission (`BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`).
- **The Mac** scans for that service only while the Wi-Fi link is down, connects, reads the PSM and
  opens the L2CAP channel: a plain byte stream both ways. If there is no PSM or the channel fails, it
  falls back to GATT: `…4a11` (*to phone*, write without response, CoreBluetooth flow control) and
  `…4a12` (*to Mac*, notify; one notification at a time, at most 512 bytes — Android's attribute
  limit — waiting for `onNotificationSent`). Then the handshake; a phone that fails it (another
  secret) is skipped for 10 minutes.
- **Connection interval.** macOS picks 30 ms, which caps throughput. For the length of a session the
  phone opens a GATT *client* connection to the Mac over the same link, only to call
  `requestConnectionPriority(HIGH)`: macOS accepts 15 ms.
- Android does not always drop the link when the phone ends a session, so a phone that receives
  anything but `hello` as a first frame answers `{type: "reset"}` and the Mac starts over. The Mac
  also reconnects when the phone's service changes (app restarted) or after 40 s without news
  (pings every 15 s).
- **Throughput** measured between a MacBook and a Galaxy S24, L2CAP at 15 ms: about 50 KB/s each
  way (GATT at 30 ms: 24 KB/s Mac → phone, 5 KB/s phone → Mac).
- Once established, the link **counts as a connected device for Samsung routines** (checked on a
  Galaxy S24, One UI 8): a routine triggered by “Bluetooth device › Mac connected” fires on the next
  Bluetooth event of the phone, e.g. whenever the Mac loses its Wi-Fi link and falls back to
  Bluetooth. Hence the notification trigger for the hotspot below.

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

Android lets no third-party app turn the hotspot on; a Samsung Modes & Routines routine can.
Its trigger is **“Notification received” › Navette › keyword “demandé par le Mac”**: the Mac sends
`hotspot` over any link (Wi-Fi or Bluetooth; without a shared network, Bluetooth), the
phone posts the notification “Point d’accès demandé par le Mac” (15 s) and answers `hotspot-ok`.

A “Bluetooth device › Mac connected” trigger would also fire on Navette's Bluetooth link (see
above). It remains the fallback when no link answers within 8 s: a bare Bluetooth link does not
count as connected, so the Mac opens a Hands-Free Profile service-level connection (RFCOMM to the
phone's `0x111F` service, then `AT+BRSF`, `AT+CIND=?`, `AT+CIND?`, `AT+CMER`) and closes it after
15 seconds. No audio is ever set up.

The Mac then **scans** for the hotspot network (a scan does not drop the current Wi-Fi) and joins
it once visible, using CoreWLAN with a password kept in the user's keychain — the one macOS
remembers is in the System keychain, which apps cannot read without admin rights. Reading
network names requires Location permission since macOS 14.

The Control Center button (`mac/Controls`) is a sandboxed WidgetKit extension that opens
`navette://point-acces`; the app handles it like a click in its menu.

Diagnostics: `~/Library/Logs/Navette.log` on the Mac.
