# Remote

A universal iOS remote for network-connected TVs and streaming boxes, written in SwiftUI.
It is a personal project and is **not affiliated with, endorsed by, or sponsored by** any
TV or streaming-device maker. Product names are used only to describe compatibility.

| Platform | Status | Pairing |
|---|---|---|
| Roku (ECP) | ✅ Phase 1 | none |
| Android TV / Google TV (Remote v2) | ✅ Phase 1 | 6-character code shown on the TV |
| Samsung Tizen, LG webOS, Sony Bravia, Vizio SmartCast | Phase 2 | on-TV prompt / PIN |
| Fire TV (ADB over Wi-Fi) | Phase 3 | on-TV prompt |
| Apple TV (Companion protocol) | Phase 4 | 4-digit PIN |

iPhones have no IR blaster, so only TVs that can be controlled over the network are in scope.

## Requirements

- **Xcode 26** or later (Swift 6.2). iOS 17+ deployment target.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- To regenerate protobuf sources: `brew install swift-protobuf`
- Python 3.11+ for the fake-TV servers and fixture generator (only for development).

## Setup

```bash
xcodegen generate
open Remote.xcodeproj
```

1. Select the **Remote** target → Signing & Capabilities → choose your team. A free
   Personal Team works; installs from a free team expire after 7 days and need re-running
   from Xcode.
2. Change the bundle ID in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`, default
   `com.example.remote`) if it collides, then re-run `xcodegen generate`.
3. Run on an iPhone on the same Wi-Fi as your TV. The first launch asks for Local Network
   access; it's required.

### Install without a Mac (Windows)

CI builds an unsigned `Remote.ipa` on every push. Sideloading re-signs it with your Apple ID.

1. Open the latest green run under **Actions** on GitHub and download the **Remote-ipa**
   artifact. Unzip it to get `Remote.ipa`.
2. Install the non-Microsoft-Store versions of **iTunes** and **iCloud** from apple.com.
   Windows needs them to talk to the iPhone.
3. Install [Sideloadly](https://sideloadly.io). Plug in the iPhone, trust the computer,
   drop `Remote.ipa` in, enter your Apple ID, and press Start.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** (iOS 16+) and
   restart. Then open **Settings → General → VPN & Device Management** and trust your Apple ID.
5. Launch Remote and allow **Local Network** access.

With a free Apple ID the app expires after 7 days. Re-run step 3 to renew it, or use
AltStore, which refreshes over Wi-Fi.

The **Demo TV** (simulated, no network) appears in simulator and Debug builds, or in any
build launched with `-mockTV`, so the whole UI can be tried without hardware.

## Entitlements and permissions

| What | Why | Needs Apple approval? |
|---|---|---|
| `NSLocalNetworkUsageDescription` | Every LAN connection | No |
| `NSBonjourServices` | Must list each Bonjour type browsed (`_androidtvremote2._tcp` now; `_companion-link._tcp`, `_airplay._tcp`, `_amzn-wplay._tcp`, `_googlecast._tcp` reserved for later phases) | No |
| `com.apple.developer.networking.multicast` | SSDP discovery (raw UDP multicast) | **Yes**, request at <https://developer.apple.com/contact/request/networking-multicast>. Needs a paid membership. |

The app works **without** the multicast entitlement. Discovery falls back through:

1. **Bonjour** (`NWBrowser`) for platforms that advertise a service (Android TV).
2. **Subnet sweep**: parallel TCP connects (64 at a time, 350 ms timeout) to known
   ports across the phone's /24 (8060 Roku, 6466 Android TV). Hits are fingerprinted, e.g.
   Roku's `/query/device-info` gives its name, serial and MAC. A sweep takes about 2–3 s.
3. **Manual IP entry** in "Add by IP address".

If Apple grants the entitlement, set `ENABLE_MULTICAST: "YES"` and
`REMOTE_ENTITLEMENTS: Config/Remote-Multicast.entitlements` in `project.yml`. SSDP then
runs alongside the other sources.

## Architecture

```
App/                     SwiftUI app (UI only)
  Model/                 AppModel (routing, sessions), RemoteViewModel, settings, haptics
  Features/              Discovery, Pairing, Remote, Apps, Settings
Packages/RemoteKit/      Swift package, iOS 17 + macOS 14 (so tests run with `swift test`)
  RemoteCore             TVDriver protocol, models, DriverError, CommandQueue, KeepAlive
  RemoteDiscovery        DiscoveryService = Bonjour + subnet probe + SSDP, deduplicated
  RemoteStorage          SwiftData saved devices, Keychain credentials
  RemoteDrivers          Roku, AndroidTV, Mock drivers; DriverFactory; PlatformFingerprint
  Protos/                Vendored .proto schemas (generated Swift is committed)
tools/fake_tv/           Python fake TVs for integration tests
tools/fixtures/          Captures protocol fixtures from reference implementations
```

- **One protocol, many drivers.** Every platform implements the `TVDriver` actor protocol.
  The UI rebuilds itself from the driver's `TVCapabilities` and never shows a button the
  TV can't handle.
- **Zero-lag input.** Button handlers fire a haptic and make a synchronous
  `CommandQueue.enqueue`. One consumer task drains commands to the driver in order, so
  fast taps can't reorder the way they could with a `Task` per press. Errors only reach
  the UI when the user has to do something. Transient drops show a quiet
  "Reconnecting…".
- **KeepAlive** per session: platform heartbeat, reconnect with backoff
  (0.5 s → 30 s), an immediate retry on Wi-Fi path changes (`NWPathMonitor`), and on
  returning to the foreground.
- **Secrets** (pairing data, the Android TV client key and certificate) live in Keychain
  with `AfterFirstUnlockThisDeviceOnly`. Saved-device metadata lives in SwiftData.
- No analytics and no third-party UI. A privacy manifest is in `App/Supporting/PrivacyInfo.xcprivacy`.

## Protocol notes

### Roku: External Control Protocol
- HTTP on port 8060, no pairing. `POST /keypress|keydown|keyup/{Key}`, `POST /launch/{id}`,
  `GET /query/apps`, `GET /query/icon/{id}`, `GET /query/device-info`.
- Text is sent one character at a time as `Lit_<percent-encoded UTF-8>`.
- HTTP 403 means **Settings → System → Advanced system settings → Control by mobile apps**
  is set to *Limited* or *Disabled*. The app says so and explains how to fix it.
- Volume, mute and power are offered only when device-info reports `is-tv=true`; sticks get
  power (via HDMI-CEC) but no volume.

### Android TV / Google TV: Remote Service protocol v2
- Reimplemented from [`androidtvremote2`](https://github.com/tronikos/androidtvremote2)
  (Apache-2.0). Its `.proto` schemas are vendored with attribution.
- The client identity is an RSA-2048 key generated in Keychain plus a self-signed X.509
  certificate (built with Apple's swift-certificates). It's shared by all Android TVs.
- **Pairing (TLS :6467, Polo):** PairingRequest → Options (hex, 6 symbols, input role) →
  Configuration → TV shows a code →
  `secret = SHA-256(clientN ‖ clientE ‖ serverN ‖ serverE ‖ code[1…2])`, where `code[0]` must
  equal `secret[0]`. That lets the app reject a mistyped code before sending anything.
- **Remote (TLS :6466):** answer RemoteConfigure and RemoteSetActive with the feature mask,
  answer pings, then RemoteKeyInject (SHORT / START_LONG / END_LONG), app links, and IME
  batch edits for text. The TV's certificate is pinned (SHA-256) on the first connect
  after pairing. A mismatch later means the TV was reset, and the app asks to pair again.
- The protocol can't list installed apps, so the Apps tab offers common deep links.

## Development

```bash
# Package tests (macOS host). The Roku integration suite runs when FAKE_ROKU_PORT is set.
python3 tools/fake_tv/roku_ecp.py --port 8060 &
cd Packages/RemoteKit && FAKE_ROKU_PORT=8060 swift test

# App build + tests on a simulator
xcodegen generate && scripts/ci-app.sh

# Regenerate protobuf Swift after editing Packages/RemoteKit/Protos
scripts/gen-protos.sh

# Re-capture Android TV fixtures from the reference implementation
uv run tools/fixtures/gen_androidtv_fixtures.py
```

CI (`.github/workflows/ci.yml`, macOS runner) does all of the above on every push. It
also fails if the committed protobuf sources are stale.

## Real-device checklists

### Roku
- [ ] Appears in "Find your TV" within ~3 s of opening it, with its real name.
- [ ] Tap → lands on the remote with no pairing step; status dot turns green.
- [ ] Arrows, OK, Back, Home respond immediately; holding an arrow auto-repeats.
- [ ] Holding OK on a tile triggers the long-press action.
- [ ] Touchpad swipes move one tile per step; a tap selects.
- [ ] Keyboard: open a search screen, type "stranger": letters appear live; deleting works.
- [ ] Apps tab shows icons; tapping one launches it.
- [ ] Roku TV only: volume ±, mute and power work. A stick shows no volume buttons.
- [ ] Set *Control by mobile apps* to *Limited*, press a key: the banner explains the fix.
- [ ] Turn Wi-Fi off and on: "Reconnecting…", then it works again without any action.

### Android TV / Google TV
- [ ] Appears by name (Bonjour) in "Find your TV".
- [ ] Tap → the TV shows a 6-character code; entering it lands on the remote.
- [ ] A deliberately wrong code shows "That code doesn't match…" and lets you retype.
- [ ] Force-quit and relaunch: reconnects automatically **without** pairing again.
- [ ] Arrows, OK, Back, Home, play/pause, volume, mute and power work.
- [ ] Keyboard into a search field: text appears and deleting works.
- [ ] Apps: YouTube launches through its deep link.
- [ ] Leave the remote idle for 2 minutes, then press a key: it still works.
- [ ] Toggle Wi-Fi: reconnects silently.
- [ ] Clear the TV's "Android TV Remote Service" data: the app asks to pair again.

## License

MIT for this repository's code. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for vendored schemas and reference projects.
