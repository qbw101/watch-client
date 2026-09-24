# Douyin Watch Assistant · Huawei WATCH 5 Client

> 中文: [README.md](README.md)

A native HarmonyOS wearable app (ArkTS + ArkUI) that lets you read and send Douyin
(Chinese TikTok) direct messages from a Huawei watch. Built for round displays, with
support for the rotating crown and smart gestures. The transport is a **custom binary
frame protocol** (deliberately *not* HTTP) over a raw TCP connection to the companion
server [`watch-bridge`](https://github.com/qbw101/watch-bridge).

**The watch never talks to Douyin directly.** Every Douyin action is performed by a
long-running browser on your computer; the watch is only a power-efficient, more
comfortable remote control. Both devices must therefore be on the same Wi-Fi, and both
the service window and the browser window on the computer must stay open.

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Build and Install](#build-and-install)
- [First Run](#first-run)
- [Round-Screen Layout](#round-screen-layout)
- [Crown and Gestures](#crown-and-gestures)
- [Wire Protocol](#wire-protocol)
- [Troubleshooting](#troubleshooting)
- [Project Layout](#project-layout)
- [Known Limitations](#known-limitations)
- [Disclaimer](#disclaimer)
- [License](#license)

## Features

| Feature | Notes |
| --- | --- |
| Conversation list | Which conversations appear is decided by the server's `config.json`; a top pill shows readiness |
| Reading messages | Opening a conversation subscribes to server pushes; bytes only move when content changes |
| Sending text | Card-based input (a bottom-anchored inline input box gets clipped on a round screen, hence the centered sheet) |
| Sending native stickers | Sticker grid, including the custom stickers you saved inside Douyin |
| Quick phrases | Locally stored canned replies, one tap to fill in |
| Settings | Computer address, access token, haptics toggle |
| Crown scrolling | Both the list and the chat history scroll with the rotating crown |
| Smart gestures | Pinch to confirm; inside the reply sheet it becomes "crown to move the highlight, pinch to enter" |

## Architecture

```
┌──────────────────────────────┐
│ Huawei WATCH 5 (this project)│
│  raw TCP + binary frames     │
│  X25519 handshake + AES-GCM  │
└───────────────┬──────────────┘
                │ LAN TCP (default 8787)
┌───────────────▼──────────────┐
│ Computer: watch-bridge       │
│  scripts/watch_server.py     │
│    └─ bridge/tcp_server.py   │
│         └─ headful Chromium ──► Douyin DMs
└──────────────────────────────┘
```

Why not HTTP: tunnel providers classify traffic by application protocol, so an HTTP
tunnel requires a registered domain or a non-mainland exit node. A custom binary
protocol shows no HTTP signature, so it can use a mainland TCP tunnel. A long-lived
connection also makes server-initiated push natural, which removes the old 2-second
polling loop on the watch — every poll rebuilt the connection and carried a full set of
headers, while the vast majority of results were "nothing changed". Waking the radio for
nothing is a silent battery killer on a watch.

## Requirements

| Item | Notes |
| --- | --- |
| DevEco Studio | 5.1.0 Release or newer (the wearable template for Watch 5 is complete from this version) |
| Huawei developer account | Real-name verification required; sign in inside DevEco to use automatic signing, no manual certificates needed |
| HarmonyOS SDK | API 12 or newer; this project is configured for `6.0.0(20)` |
| Watch | HUAWEI WATCH 5, switched to **full-feature mode** (apps cannot be installed in ultra-long-battery mode) |
| Network | Watch and computer on the same Wi-Fi |
| Companion server | [`watch-bridge`](https://github.com/qbw101/watch-bridge) — the watch app cannot run on its own |

> The signing material referenced in `build-profile.json5` is a **local path**. On a new
> machine you must run automatic signing again (see below). Without signing the artifact
> is `-unsigned.hap`, which can never be installed on a real device (error
> `9568320 / no signature file`).

## Build and Install

### Prepare the watch (once)

1. On the watch press the top button → **Settings** → tap the device name → **About**
2. Find **Software version** and tap it **7 times quickly**; "You are now in developer mode!" appears
3. Back → **Settings → System → Developer options**, enable **HDC debugging** and **Wi-Fi debugging**
   (Wi-Fi debugging shows an address like `192.168.1.23:44322` — note it down)
4. Increase the screen-off timeout — **Wi-Fi debugging disconnects once the screen turns off**

### With DevEco Studio

**The order matters**: automatic signing writes the UDID of the *currently connected*
device into the profile, so you must **connect the watch first, then configure signing**.

1. DevEco Studio → **File → Open**, pick this directory, wait for the first Sync
2. **Tools → IP Connection**, enter the watch's `IP:port` (the watch asks you to trust the device)
3. Confirm your watch appears in the device dropdown. **If it does not, fix the connection first**
4. **File → Project Structure → Project → Signing Configs**
   - Tick **Automatically generate signature** (HarmonyOS projects also need **Support HarmonyOS**)
   - If not signed in, **Sign In** with your real-name-verified Huawei account
   - The material paths get filled in automatically → **Apply → OK**
5. **Build → Clean Project**, then **Run 'entry'**

### From the command line

```bash
unset NODE_OPTIONS                       # see Troubleshooting: some shims break the build
export DEVECO_SDK_HOME="<DevEco install dir>/sdk"

"<DevEco install dir>/tools/hvigor/bin/hvigorw.bat" \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

The artifact lands in `entry/build/default/outputs/default/`. **If the filename still
contains `unsigned`, it is not signed** and installation will fail with `9568320`:

```bash
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

To check whether signing actually ran, look at the duration of the `SignHap` step:
a real signing takes ~2 seconds, while `1 ms` means it was a no-op (followed by
`No signingConfig found for product default`).

## First Run

Start the server on your computer first (see [`watch-bridge`](https://github.com/qbw101/watch-bridge)). On its
very first start it opens a local configuration page showing the **computer address** and
the **access token**.

Open "Douyin Assistant" on the watch and fill in:

| Field | Value |
| --- | --- |
| Computer address | `192.168.1.10:8787` (the port may be omitted, it defaults to 8787; an `http://` prefix is accepted too) |
| Access token | The string from the configuration page (generated on first start, 8 hex digits) |

Both values are persisted locally on the watch (`preferences`) and reused next time.
To change them, tap **设** (Settings) in the top-right corner of the list screen.

The address field is deliberately forgiving: the port is optional, `http://` / `tcp://`
prefixes are stripped, and any trailing path, query string or slash is discarded — so
pasting straight from the browser address bar will not produce a "bad format" error.

## Round-Screen Layout

The WATCH 5 has a **466×466 px = 233×233 vp** round display; the four corners are
physically nonexistent. Instead of guessing with padding, this project uses geometric
constraints (`entry/src/main/ets/common/Geometry.ets`):

```
With radius r, anything farther than r from the center is invisible.
How wide the content column may be is decided by the "row", not the "content band":
  row height r×0.37, top reaches r×0.51 above center, bottom reaches r×0.545 below
  extreme point √(0.71² + 0.545²) = 0.896r < r  →  a 1.42r column still fits
```

| Element | Formula | On WATCH 5 |
| --- | --- | --- |
| Content column width | `r × 1.42` | 165 vp |
| Top pill | `r × 1.36` × `r × 0.285` | 158 × 33 |
| Content band | top at `50% - r×0.70`, height `r × 1.42` | y35–200 |
| Round button | diameter `r × 0.40`, top at `50% + r×0.575` | 47, y183 |
| Body font size | `r × 0.105` | 12.2 vp |

Two traps worth remembering:

- **The pill is intentionally narrower than the content column.** Its top edge sits
  `r×0.775` from the center, where the circle is only `1.264r` wide; using `1.36r` trims
  about 5.6 vp at each end — and because those ends are already arcs, the cut is invisible.
- **Column width and content-band height constrain each other**: a `1.42r` column means the
  band must not exceed roughly `1.42r` in height, or the corners poke outside the circle.
  Change one and you must recompute the other.

`r` is not hard-coded to 233: the page measures the root container via `onAreaChange` and
replaces the whole `WatchGeometry` object, so the emulator (different resolutions) and
other round watches work as-is.

**To adjust sizes, change the coefficients in `Geometry.ets` only** — never scatter magic
numbers around the page.

## Crown and Gestures

### Rotating crown

Crown events are **delivered only to the currently focused component** (API 18+, Wearable
devices only):

```ts
SomeComponent()
  .focusable(true)
  .id('someId')
  .digitalCrownSensitivity(CrownSensitivity.MEDIUM)
  .onDigitalCrown((event: CrownEvent) => { /* event.degree is a relative rotation angle */ })
```

Constraints and pitfalls:

| Item | Finding |
| --- | --- |
| Delivery target | Only the **focused** component. `List` / `Scroll` / `Grid` / `Slider` / `Swiper` support crown scrolling natively, but must be focused first |
| Do not rely on `defaultFocus(true)` | It only applies when the page is **first created**; this app's list is built after the status response arrives, long past that moment. Request focus explicitly with `focusController.requestFocus(id)` once the list exists |
| Focus activation | `getFocusController().activate(true, false)` is a prerequisite for `requestFocus`; without it the call fails silently |
| The chat page is special | Message bubbles are not focusable, so the `Scroll` never gets focus. The crown handler therefore lives on the **root container**, which forwards rotation by calling `scroller.scrollBy()` |
| `hitTestBehavior(None)` trap | Such a node **cannot take focus**. The "lay down an invisible full-screen catcher" trick does not work |
| Never set `focusable(false)` on the root container | It breaks the focus chain and kills both the crown and smart gestures |

To check whether it is wired up, look at the node's `focused` attribute in
`uitest dumpLayout` — no need to actually turn the crown.

### Smart gestures

Pinch-to-confirm works by the system delivering a `KEYCODE_ENTER` (2054) to the
**focused component**. Your options must therefore be focusable, or a container that
receives the event must handle it instead.

The reply sheet uses the standard wearable interaction — **crown to move the highlight,
pinch to enter**:

| Action | Behaviour |
| --- | --- |
| Open the reply sheet | "Sticker" is highlighted by default, highlight reset to the top |
| Turn the crown | Moves the highlight between the three items (after a fixed rotation, since the crown is a continuous value) |
| Pinch | Enters the highlighted item |
| Pinch inside a sub-page | Returns one level up |

### Back and dismiss

| Gesture | Behaviour |
| --- | --- |
| Swipe right from the left edge | Go back one level (horizontal `PanGesture` on the root container via `parallelGesture`) |
| Swipe down on the first screen of the reply sheet | Dismiss the sheet (the gesture lives on the full-screen black backdrop behind it) |

## Wire Protocol

See the [protocol section in `watch-bridge`](https://github.com/qbw101/watch-bridge#wire-protocol). Summary:

- Fixed 8-byte header, big-endian: payload length(4) / frame type(1) / request id(2) / flags(1)
- Types: `HELLO` `REQ` `RES` `IMAGE` `PING` `PONG`
- On an encrypted channel the payload gets an extra AEAD layer (X25519 key exchange +
  AES-256-GCM); the header stays in plaintext
- TCP is a byte stream: **never assume "one callback = one frame"**. Everything received
  goes into `FrameParser` first and is sliced into frames there (coalesced and split
  packets are both absorbed at that point)
- Encryption must be **serial**: the nonce is a direction prefix plus a counter, so
  concurrent sends will collide

The watch-side implementation lives under `service/`: `BridgeLink` (connection and
reconnect), `WireCrypto` (handshake and AEAD), `BridgeSession` (wraps frames into callable
methods such as `status()` / `messages()` / `sendMessage()`), `ImageCache` (thumbnail
cache) and `CryptoDiag` (handshake failure diagnostics).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Install Failed: code:9568320 error: no signature file` | Not signed. Follow "Build and Install". **Key order: connect the watch first, then enable automatic signing** |
| Automatic signing ticked but the artifact is still `-unsigned.hap` | Signing did not reach the target. Check that `products[0]` in the root `build-profile.json5` has `"signingConfig": "default"` |
| Automatic signing hangs or fails | Check in order: (1) the computer clock differs from Beijing time; (2) the Huawei account is not real-name verified; (3) the network cannot reach Huawei's servers |
| Cannot install after switching to a new watch/device | The profile lacks the new device's UDID. **Connect the new device first**, then re-run automatic signing |
| The build crashes with an opaque error | If `NODE_OPTIONS` is set (common with safe-delete shims), hvigor crashes in a way that looks like its own bug. `unset NODE_OPTIONS` and rebuild |
| "Cannot reach the computer" | The service is not running, or you are on a different subnet. Check that the service window is still open |
| "Computer not found: check the IP in the address" | The IP changed — re-enter it via **设** on the list screen |
| "Invalid token" | Token mismatch. The current one is on the server's configuration page (also mirrored to `artifacts/watch_token.txt`) |
| Windows Firewall prompt | On first run, allow python.exe on private networks, otherwise the watch cannot connect |
| Debugging drops after a while | Wi-Fi debugging disconnects when the screen turns off. `hdc list targets` then shows `[Empty]` and every command reports `need connect-key` (**while still exiting with code 0**). Run `hdc shell power-shell wakeup` to wake the screen, then `hdc tconn <IP:port>` |
| Turning the crown does nothing | Crown events only go to the focused component; see "Crown and Gestures". Quick check: the node's `focused` in `uitest dumpLayout` |
| A round button renders as a plain dot with no icon | Icons use Chinese characters or system symbols. Font coverage is limited — do not use glyphs like `✎` / `⟳` / `⚙`, they render blank |
| The input placeholder is cut off mid-sentence | `TextInput` placeholder text needs its own `.placeholderFont({ size })`; `.fontSize()` alone leaves it at the system default |
| The keyboard covers the whole screen | The watch soft keyboard is full-screen. The card automatically collapses its title and sticker grid, leaving only the input and the button |
| Opening a chat shows no history | Read the list area: `正在读取聊天记录…` means loading, a "tap to retry" hint means the read failed, `这个会话还没有消息` means it is genuinely empty |
| Sending takes several seconds | Expected. The server watches the bubble to confirm delivery (minimum 2-second observation window); that is the correctness guarantee against false success |
| All sticker thumbnails are blank | First verify the server's image endpoint in a desktop browser; if it does not return an image, that entry simply has no thumbnail |

## Project Layout

```
watch-client/
├── AppScope/
│   ├── app.json5                       bundleName / version / icons
│   └── resources/base/media/app_icon.png
├── build-profile.json5                 compatible/target SDK, signing config
├── entry/src/main/
│   ├── module.json5                    deviceTypes: ["wearable"], INTERNET / VIBRATE
│   ├── ets/
│   │   ├── common/
│   │   │   ├── Protocol.ets            frame encoding + streaming frame parser
│   │   │   ├── Endpoint.ets            parsing (and forgiving handling) of "host[:port]"
│   │   │   ├── Geometry.ets            round-screen geometry (single source of dimensions)
│   │   │   ├── Palette.ets             colors (single source of every color value)
│   │   │   ├── Haptics.ets             haptic feedback
│   │   │   ├── Types.ets               data models mirroring the server JSON
│   │   │   └── WatchPrefs.ets          persistence for address / token / toggles
│   │   ├── service/
│   │   │   ├── BridgeLink.ets          TCP connection, reconnect, keepalive
│   │   │   ├── WireCrypto.ets          X25519 handshake + AES-256-GCM
│   │   │   ├── BridgeSession.ets       wraps frames into callable business methods
│   │   │   ├── ImageCache.ets          sticker thumbnail cache
│   │   │   ├── CryptoDiag.ets          handshake failure diagnostics
│   │   │   └── BridgeError.ets         error types and user-readable messages
│   │   ├── view/                       message bubble / friend row / sticker cell
│   │   ├── entryability/EntryAbility.ets
│   │   └── pages/Index.ets             main page: config / loading / list / chat / composer
│   └── resources/
├── tools/                              developer helper scripts (see below)
├── ui-demo/index.html                  plain HTML design mock (check sizes here first)
└── attic/                              archived early work (HTTP client, old icons)
```

Helper scripts under `tools/`:

| Script | Purpose |
| --- | --- |
| `check_project.py` | Static pre-flight: resource references, page paths, bracket balance |
| `make_icons.py` | Generates icon PNGs (standard library only, no Pillow) |
| `shot.sh` / `tap.sh` | On-device inspection: capture a screenshot and the widget tree together |
| `flat.py` | Flattens the widget tree into lines for easier hierarchy reading |
| `measure_icon.py` | Measures the bright-pixel centroid of an icon in a screenshot |
| `tcp_probe.py` | Talks to the bridge service directly from the computer |

`shot.sh` / `tap.sh` need a "watch address": they read `tools/.device` first (a local
file, not committed), then the `WATCH_DEV` environment variable, and fall back to a
sample value. Write it once locally:

```bash
echo "192.168.1.23:43235" > tools/.device
```

> ⚠️ **Never drive the UI with `uitest uiInput drag` / `swipe`**: it has been observed to
> inject click events, which can trigger unexpected buttons (and has deleted data).
> To verify scrolling, prefer key events — a focused scroll container responds to
> `uiInput keyEvent` — or ask a human to swipe.

## Known Limitations

| Limitation | Notes |
| --- | --- |
| Depends on the companion server | The watch app cannot run standalone; `watch-bridge` must be running |
| Conversation count | Determined by the server's `config.json`; selecting many makes a long list |
| Message images are downscaled on demand | The server compresses to the configured edge length before sending; larger is slower |
| Custom stickers are addressed by index | They have no names inside Douyin's panel, so they are located as "tab N, item M"; adding or removing stickers shifts those indices and requires a rescan |
| Crown sensitivity is a constant | Pixels per degree is a constant in `Index.ets` and can be tuned |
| Plaintext HTTP is deprecated | The old HTTP version is archived in `attic/http-v0/` and no longer maintained |

## Disclaimer

- This project is intended for **personal study and research only**. Do not use it commercially, and do not use it in any way that violates Douyin's user agreement or terms of service.
- Automating a Douyin account carries the risk of rate-limiting, feature restrictions, or outright bans. Assess the risk yourself and accept the consequences.
- The author accepts no responsibility for any outcome of using this project, including but not limited to account loss, data loss, or legal disputes.
- Comply with the laws of your jurisdiction. This project comes with no warranty of any kind.

## License

This project is released under the [GNU General Public License v3.0](LICENSE), copyright 仇博文 (qbw).

```
Douyin Watch Client  Copyright (C) 2026  仇博文 (qbw)
```

You are free to use, modify, and redistribute this project, but **any derivative work must also be released under GPL-3.0** with the original copyright notice preserved. This project comes with no warranty.
