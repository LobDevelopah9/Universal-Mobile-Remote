# Changelog

## 0.1.0: Phase 1 (Roku + Android TV)

### Works
- **Architecture:** `TVDriver` actor protocol; capability-driven UI; ordered
  fire-and-forget `CommandQueue`; `KeepAlive` with heartbeat, 0.5 s → 30 s backoff, and
  reconnect on Wi-Fi path change and on foreground.
- **Discovery** without the multicast entitlement: Bonjour (`_androidtvremote2._tcp`), a
  parallel /24 TCP sweep of known ports with fingerprinting, and manual IP entry. Results
  are deduplicated by serial, MAC or address. SSDP is built in but off unless
  `ENABLE_MULTICAST=YES`.
- **Roku (ECP):** keys including key-down/up long press, live text (`Lit_`), app grid
  with icons, app launch, volume/power on Roku TVs, and a clear message when *Control by
  mobile apps* blocks commands.
- **Android TV / Google TV (Remote v2):** Keychain-held RSA client identity with a
  self-signed certificate, code pairing with local typo detection, TLS remote session with
  the TV's certificate pinned after pairing, keys with long press, IME text, and app
  deep links.
- **UI:** "Find your TV" live list; per-platform pairing; touchpad (swipe to step, tap
  to select) with a D-pad toggle; Back/Home/Play-Pause, media, volume, mute, power and
  keyboard, each shown only when supported; Apps tab; device switcher; Settings
  (haptics, sensitivity, appearance, rename, forget, re-pair, add by IP); dark-first;
  landscape layout; VoiceOver labels and actions.
- **Demo TV** (`MockTVDriver`) so the whole app runs in the simulator.
- **Tests:** Android TV pairing secret and every message encoding compared byte-for-byte
  with fixtures captured from `androidtvremote2`; varint framing; RSA key parsing; Roku
  key mapping, `Lit_` encoding and XML parsing; discovery merge and subnet math;
  backoff, touchpad and text-diff logic; storage; Roku integration against
  `tools/fake_tv/roku_ecp.py`; `RemoteViewModel` against the mock driver.
- **Tooling:** XcodeGen spec, GitHub Actions macOS CI, privacy manifest, no analytics.

### Known limitations
- Not yet verified on real Roku or Android TV hardware. Use the README checklists.
- SSDP needs Apple's multicast entitlement (paid membership). Without it, Roku is found
  by the subnet sweep, which only covers the phone's own /24.
- Android TV can't list installed apps; the Apps tab shows a fixed set of common deep links.
- Android TV text input replaces the focused field's content. If the TV's field already
  had text when the keyboard opened, the first keystroke may overwrite it.
- Android TV voice search isn't implemented.
- Native touchpad events aren't sent to any real platform yet (Roku and Android TV take
  D-pad steps). This arrives with Apple TV in Phase 4.
- No app icon artwork yet.
- Free Apple ID signing: installs expire after 7 days.
